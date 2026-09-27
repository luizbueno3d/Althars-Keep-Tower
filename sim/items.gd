extends RefCounted
## Inventory & items (Inventory 0.1 — Playable Party 0.5).
##
## The party inventory is a shared pack: {gold, items} where items
## is an Array of {name, qty} stacks. Loot stacks by name — a fifth
## Small Potion joins the pile, not a new row.
##
## Consumables run the same contract as support spells: the item is
## NEVER consumed before a valid target is confirmed — validation
## runs first, the decrement is the last thing that happens.
## Effects are plain resource work (restore_lp / restore_ap) —
## pools cap independently at their max, nothing overheals.
##
## Belt slots (Cfg.BELT_SLOTS, PROVISIONAL 3) live on the actor and
## hold item NAMES pointing at the shared stack — a hero's belt is
## "what he can reach without rummaging". Quick-use applies the
## item to the belt's owner; an emptied stack clears every slot
## that referenced it.
##
## Pure sim: no Node APIs; all rolls (none today) would go through
## battle.rng.

static func def_of(cfg, name: String) -> Dictionary:
	return cfg.ITEMS.get(name, {})

static func known(cfg, name: String) -> bool:
	return cfg.ITEMS.has(name)

## Total units of `name` in the shared inventory.
static func count(inv: Dictionary, name: String) -> int:
	var n := 0
	for s in inv.items:
		if s.get("name") == name:
			n += int(s.get("qty", 0))
	return n

## Add `qty` units — merges into an existing stack.
static func add(inv: Dictionary, name: String, qty := 1) -> void:
	for s in inv.items:
		if s.get("name") == name:
			s.qty = int(s.qty) + qty
			return
	inv.items.append({name = name, qty = qty})

## Remove exactly one unit; drops the stack at zero. Returns false
## if none was held — callers must not call this speculatively.
static func take_one(inv: Dictionary, name: String) -> bool:
	for i in inv.items.size():
		var s: Dictionary = inv.items[i]
		if s.get("name") == name and int(s.qty) > 0:
			s.qty = int(s.qty) - 1
			if s.qty <= 0:
				inv.items.remove_at(i)
			return true
	return false

static func is_consumable(cfg, name: String) -> bool:
	return def_of(cfg, name).get("kind") == "consumable"

## Actor ids a party-targeted consumable may be used on:
## living friendly heroes — the field is not required (a reserve
## hero can be fed a potion between groups). Stable actor_order.
static func valid_targets(battle, name: String) -> Array:
	var d := def_of(battle.config, name)
	if d.get("target") != "ally_alive":
		return []
	var out := []
	for id in battle.actor_order:
		var a = battle.actors[id]
		if a.faction == "friendly" and a.alive:
			out.append(id)
	return out

## Apply one unit of `name` to `target_id`. Full validation BEFORE
## anything is consumed — [false, reason] costs nothing.
## Returns [true, {lp, ap}] of what was actually restored.
static func use(battle, name: String, target_id: String) -> Array:
	var d := def_of(battle.config, name)
	if d.is_empty():
		return [false, "unknown item"]
	if d.get("kind") != "consumable":
		return [false, "cannot be used"]
	if count(battle.inventory, name) <= 0:
		return [false, "none left"]
	var t = battle.actors.get(target_id)
	if t == null or not t.alive or t.faction != "friendly":
		return [false, "not a living hero"]
	var eff: Dictionary = d.get("effect", {})
	var res := {lp = 0, ap = 0}
	match eff.get("type"):
		"restore_lp":
			res.lp = mini(maxi(int(eff.amount), 0), t.max_lp - t.lp)
			t.lp += res.lp
		"restore_ap":
			res.ap = mini(maxi(int(eff.amount), 0), t.max_ap - t.ap)
			t.ap += res.ap
		_:
			return [false, "no use rule"]
	take_one(battle.inventory, name)
	if count(battle.inventory, name) <= 0:
		_prune_belts(battle, name)
	battle.emit({type = "item_use", item = name, actor = t,
		lp = res.lp, ap = res.ap})
	return [true, res]

# ---------------- belt ----------------

## First free belt slot index, or -1 when the band is full.
static func belt_free_slot(actor) -> int:
	for i in range(actor.belt.size()):
		if String(actor.belt[i]) == "":
			return i
	return -1

## Put `name` on the actor's belt. Requires a held stack and a free
## slot; assigning does NOT consume the unit.
static func belt_assign(battle, actor_id: String, name: String) -> Array:
	var a = battle.actors.get(actor_id)
	if a == null or a.faction != "friendly":
		return [false, "no such hero"]
	if not is_consumable(battle.config, name):
		return [false, "only consumables ride the belt"]
	if count(battle.inventory, name) <= 0:
		return [false, "none held"]
	var slot := belt_free_slot(a)
	if slot < 0:
		return [false, "belt is full"]
	if name in a.belt:
		return [false, "already on his belt"]
	a.belt[slot] = name
	battle.emit({type = "belt_assign", actor = a, item = name,
		slot = slot})
	return [true, slot]

static func belt_unassign(battle, actor_id: String, slot: int) -> void:
	var a = battle.actors.get(actor_id)
	if a == null or slot < 0 or slot >= a.belt.size():
		return
	a.belt[slot] = ""

## Quick-use: the belted item on its owner. Same validation as a
## targeted use — a dead or invalid wearer consumes nothing.
static func belt_use(battle, actor_id: String, slot: int) -> Array:
	var a = battle.actors.get(actor_id)
	if a == null or slot < 0 or slot >= a.belt.size():
		return [false, "no such slot"]
	var name := String(a.belt[slot])
	if name == "":
		return [false, "empty slot"]
	return use(battle, name, actor_id)

## Every belt slot naming `name` empties — the last unit is gone.
static func _prune_belts(battle, name: String) -> void:
	for id in battle.actor_order:
		var a = battle.actors[id]
		for i in range(a.belt.size()):
			if String(a.belt[i]) == name:
				a.belt[i] = ""
