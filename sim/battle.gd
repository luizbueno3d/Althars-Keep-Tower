extends RefCounted
## Battle state: actors, valid hexes, seeded RNG, event queue, inventory.
## Emits structured events; presentation drains them.

const Actor = preload("res://sim/actor.gd")
const Hex = preload("res://sim/hex.gd")
const Items = preload("res://sim/items.gd")
const Structure = preload("res://sim/structure.gd")

var config                   # sim/config.gd class (constants via it)
var rng                      # RandomNumberGenerator (or a scripted fake in tests)
var actors := {}             # id -> Actor
var actor_order: Array[String] = []
var valid := {}              # Vector2i -> true (in-grid hexes)
var wall := {}               # Vector2i -> Cfg.wall_kind (elevated posts)
var fireball = null          # active spell projectile state or null
var arrows: Array = []       # physical arrows in flight — draw ->
                             # release -> travel -> impact (combat.gd)
var arrow_seq := 0           # id source for in-flight arrows
var zones: Array = []        # persistent spell zones (Blizzard storm)
var events: Array = []       # pending events for presentation
var inventory := { gold = 0, items = [] }
var group_index := 1           # continuous-play encounter counter
var encounter_done := false    # set by combat.gd when the last
                               # enemy of the group falls
var obstacles := {}            # Vector2i -> true: prop blockers —
                               # real obstacles the dressing layer
                               # plants on the field (Cfg.FIELD_
                               # BLOCKERS). Gate movement/placement
                               # only; spells still fly over them.
var control_id := "wizard"     # Playable Party 0.5: the hero the
                               # player currently commands. The sim
                               # never branches on this — it only
                               # records who orders come from so a
                               # future player→hero mapping could
                               # assign controllers without
                               # rewriting combat.
## Defended structures (the Keep). A scenario may author them; a battle
## with none behaves exactly as before. Integrity is separate from LP by
## design — see sim/structure.gd.
var structures := {}           # id -> Structure
var structure_order: Array[String] = []
var defense_lost := false      # a defended structure reached 0 Integrity
var roster_builder := Callable()  # optional Callable(rng, group) that
                               # GENERATES a roster per group. Unset =
                               # author `config.ACTORS` (Althar's Keep).
## Measurement seam reserved for future candidate-rule studies
## (tests/foundations_exp.gd pattern). The 0.1 study's keys were
## resolved in Character Foundations 0.2: def_nat1_fail and
## def_no_exert are now canonical rules in sim/combat.gd, the
## flat exh_defense penalty was REJECTED (dead-zone cliff), and
## exh_move_mult was dropped. Currently no consumers — production
## scenarios never set this.
var experiment := {}

## Build a fresh deterministic battle from the config class.
## `roster_builder` is an optional Callable(rng) -> Array[Dictionary] that
## lets a scenario GENERATE its roster instead of authoring it flat —
## enemy archetypes expanded into individuals with per-spawn rolls.
## Opt-in: an authored scenario (Althar's Keep) passes nothing and its
## `cfg.ACTORS` is used verbatim, exactly as before.
static func create(cfg, roster_builder := Callable()) -> RefCounted:
	var b = (load("res://sim/battle.gd") as GDScript).new()
	b.config = cfg
	b.rng = RandomNumberGenerator.new()
	b.rng.seed = cfg.SEED
	for h in Hex.range(cfg.GRID_CENTER, cfg.GRID_RADIUS):
		b.valid[h] = true
		var wk: int = cfg.wall_kind(h)
		if wk > 0:
			b.wall[h] = wk
		# Hex Integrity: whole cells only — a prop/keep footprint
		# occupying a cell's centre makes it an occupied cell, never
		# a fractional or deleted one.
		if cfg.cell_blocked(h):
			b.obstacles[h] = true
	# A scenario either GENERATES its roster (a builder) or authors it
	# flat in `ACTORS`. A generating scenario need not define ACTORS at
	# all, so it is only read on the authored path.
	var roster: Array = []
	if roster_builder.is_valid():
		b.roster_builder = roster_builder
		roster = roster_builder.call(b.rng, b.group_index)
	else:
		roster = cfg.ACTORS
	for d in roster:
		var a = Actor.create(d, b.rng)   # seeded: bounded individual
		                               # variation is deterministic
		b.actors[a.id] = a
		b.actor_order.append(a.id)
	for d in cfg.STRUCTURES:
		var s = Structure.create(d)
		b.structures[s.id] = s
		b.structure_order.append(s.id)
	return b

func emit(e: Dictionary) -> void:
	events.append(e)

func drain_events() -> Array:
	var out := events
	events = []
	return out

func hex_in_grid(h: Vector2i) -> bool:
	return valid.has(h)

## Elevated battlement post (walk or gate lintel). Elevation gates
## melee and movement; teleport ignores it.
func is_wall(h: Vector2i) -> bool:
	return wall.has(h)

func wall_kind(h: Vector2i) -> int:
	return wall.get(h, 0)

## Free for movement: in grid, not a prop blocker, and no living
## actor occupies it. Corpses do not block; obstacles always do.
func hex_free(h: Vector2i) -> bool:
	if not hex_in_grid(h) or obstacles.has(h):
		return false
	for id in actor_order:
		var a = actors[id]
		if a.alive and a.hex == h:
			return false
	return true

## Reachable hex set for a ground actor — a flood fill through
## hex_free cells that never crosses elevation, so the answer is
## exactly the component of the field the actor can walk to. This
## is the honest answer to "which ground is navigable": decorative
## open ground is reachable, walls/props/water never are.
## Used by player move orders; AI steps still use the local greedy
## rule (which obeys the same constraints by construction).
func reachable_from(a) -> Dictionary:
	if a == null or not a.alive:
		return {}
	var elevated_start: bool = is_wall(a.hex)
	var seen := {a.hex: true}
	var frontier: Array = [a.hex]
	while not frontier.is_empty():
		var h: Vector2i = frontier.pop_back()
		for d in Hex.DIRECTIONS:
			var n: Vector2i = h + d
			if seen.has(n) or not hex_free(n):
				continue
			if is_wall(n) != elevated_start:
				continue
			seen[n] = true
			frontier.append(n)
	seen.erase(a.hex)
	return seen

# ---------------- PLAYER COMMANDS (Playable Party 0.5) ----------------
# Tactical orders for a living friendly hero. The order is INPUT
# INTO the normal AI — command_move reassigns the defensive anchor
# and command_focus marks a target; the existing autonomous combat
# loop still walks, engages, strikes and defends. This is the solo
# party-control architecture: it commands people, not a cursor.

## Order `id` to relocate his defensive anchor to hex `h`.
## The destination must be reachable for THAT actor right now
## (reachable_from) — a rejected click answers false for feedback.
func command_move(id: String, h: Vector2i) -> bool:
	var a = actors.get(id)
	if a == null or not a.alive or a.faction != "friendly":
		return false
	if not reachable_from(a).has(h):
		return false
	a.anchor = h
	a.focus_id = ""
	a.focus_stall = 0
	emit({type = "command", actor = a.id, kind = "move", to = h})
	return true

## Order `id` to engage `target_id` — an explicit kill order that
## overrides the defensive zone until the mark dies.
func command_focus(id: String, target_id: String) -> bool:
	var a = actors.get(id)
	var t = actors.get(target_id)
	if a == null or not a.alive or a.faction != "friendly":
		return false
	if t == null or not t.alive or t.faction == a.faction:
		return false
	a.focus_id = target_id
	a.focus_stall = 0
	emit({type = "command", actor = a.id, kind = "focus",
		target = target_id})
	return true

func living_enemies() -> Array:
	var out := []
	for id in actor_order:
		var a = actors[id]
		if a.alive and a.faction == "enemy":
			out.append(a)
	return out

## The living defended structure standing on `h`, or null. A structure
## occupies its hex the way an actor does — attackers stop adjacent.
func structure_at(h: Vector2i):
	for id in structure_order:
		var s = structures[id]
		if s.alive and s.hex == h:
			return s
	return null

func living_structures() -> Array:
	var out := []
	for id in structure_order:
		if structures[id].alive:
			out.append(structures[id])
	return out

## NEXT GROUP — continuous-play encounter loop (NOT a reset):
## respawns every configured enemy as a fresh individual at its
## authored spawn hex. Friendly actors are completely untouched —
## LP/AP/MP, XP pools, Level, attributes, learned values, history
## and inventory all persist across groups. Nothing is refilled.
## `participated` resets per encounter: deployed heroes are on the
## field again; reserves share nothing unless they deploy.
## Returns false while the current group still lives.
func next_group() -> bool:
	if not encounter_done:
		return false
	group_index += 1
	if roster_builder.is_valid():
		# A GENERATED roster: the next wave is a new set of individuals
		# with new ids, so the previous wave's corpses leave the field.
		for id in actor_order.duplicate():
			if actors[id].faction == "enemy":
				actors.erase(id)
				actor_order.erase(id)
		for d in roster_builder.call(rng, group_index):
			if String(d.get("faction", "")) != "enemy":
				continue
			var a = Actor.create(d, rng)
			actors[a.id] = a
			actor_order.append(a.id)
	else:
		for d in config.ACTORS:
			if d.faction != "enemy":
				continue
			var a = Actor.create(d, rng)   # fresh archetype variation
			actors[a.id] = a               # replaces the corpse/object
	for id in actor_order:
		var a = actors[id]
		if a.faction == "friendly":
			a.participated = a.deployed
	arrows = []                # the field resets — nothing mid-flight
	encounter_done = false
	emit({type = "next_group", group = group_index})
	return true

# ---------------- SAVE/LOAD (Playable Loop 0.4) ----------------
## Plain-data run state for the local save file. Actors serialize by
## id; transient presentation state (views, tweens, event queue,
## in-flight projectile/zones) is deliberately NOT persisted — a save
## resumes actors on their hexes with no spell mid-flight.

func to_dict() -> Dictionary:
	var saved := {}
	for id in actor_order:
		saved[id] = actors[id].to_dict()
	var out := {
		version = 1,
		group_index = group_index,
		encounter_done = encounter_done,
		control_id = control_id,
		defense_lost = defense_lost,
		inventory = {gold = inventory.gold,
			items = inventory.items.duplicate()},
		actors = saved,
	}
	var st := {}
	for id in structure_order:
		st[id] = structures[id].to_dict()
	out.structures = st
	# RNG state is optional — FakeRng in tests has none
	if rng is RandomNumberGenerator:
		out.rng = {seed = rng.seed, state = rng.state}
	return out

## Overlay a saved run onto this battle (built fresh from config so
## authored fields stay authoritative). Unknown/missing ids are
## skipped — forward-safe against roster changes.
func apply_save(data: Dictionary) -> void:
	group_index = int(data.get("group_index", group_index))
	encounter_done = bool(data.get("encounter_done", encounter_done))
	var inv: Dictionary = data.get("inventory", {})
	inventory.gold = int(inv.get("gold", 0))
	inventory.items = []
	for it in inv.get("items", []):
		# migrate pre-Inventory-0.1 saves: items were bare name
		# strings; stacks are {name, qty} now
		if it is String:
			Items.add(inventory, it, 1)
		elif it is Dictionary and it.has("name"):
			Items.add(inventory, String(it.name),
				int(it.get("qty", 1)))
	var saved_actors: Dictionary = data.get("actors", {})
	for id in actor_order:
		if saved_actors.has(id):
			actors[id].apply_dict(saved_actors[id])
	if roster_builder.is_valid():
		# GENERATED roster: wave individuals carry wave-specific ids,
		# so the fresh wave this battle spawned is NOT the roster the
		# save describes — the saved actors are. Rebuild every saved
		# enemy the fresh field lacks from its recorded `spawn` dict
		# (saved dicts carry no faction of their own — the spawn's
		# does), then drop every fresh enemy the save does not know.
		# Saved corpses keep their loot: they are IN saved_actors, so
		# they are rebuilt/overlaid like anyone else.
		# the append order is SORTED ids: a save dict's iteration
		# order is not roster order (a JSON round-trip sorts keys),
		# and actor_order feeds act/strike order — keep it stable
		var missing: Array = []
		for sid in saved_actors:
			if actors.has(sid):
				continue
			var sp: Dictionary = saved_actors[sid].get("spawn", {})
			if String(sp.get("faction", "")) == "enemy":
				missing.append(sid)
		missing.sort()
		for sid in missing:
			var svd: Dictionary = saved_actors[sid]
			var rd: Dictionary = svd.spawn.duplicate(true)
			for k in ["hex", "anchor"]:
				# engine vectors were scrubbed to [x, y] on the way
				# into the save — put them back before create()
				if rd.get(k) is Array and rd[k].size() >= 2:
					rd[k] = Vector2i(int(rd[k][0]), int(rd[k][1]))
			var a = Actor.create(rd, rng)
			a.apply_dict(svd)
			actors[a.id] = a
			actor_order.append(a.id)
		for id in actor_order.duplicate():
			if actors[id].faction == "enemy" \
					and not saved_actors.has(id):
				actors.erase(id)
				actor_order.erase(id)
	defense_lost = bool(data.get("defense_lost", defense_lost))
	var saved_st: Dictionary = data.get("structures", {})
	for id in structure_order:
		if saved_st.has(id):
			structures[id].apply_dict(saved_st[id])
	var rs: Dictionary = data.get("rng", {})
	if rng is RandomNumberGenerator and not rs.is_empty():
		rng.seed = int(rs.get("seed", rng.seed))
		rng.state = int(rs.get("state", rng.state))
	# restore the controlled hero — only if that hero is still a
	# living friendly; a dead controlled hero hands command back
	# to Althar rather than leaving the player possessing a corpse
	control_id = "wizard"
	var saved_ctrl := String(data.get("control_id", "wizard"))
	var ca = actors.get(saved_ctrl)
	if ca != null and ca.alive and ca.faction == "friendly":
		control_id = saved_ctrl
	# never resume mid-flight effects
	fireball = null
	zones = []
	arrows = []
	events = []

## TAKE ALL on a corpse; emits loot_taken. No-op if nothing to take.
func take_loot(actor_id: String) -> void:
	var a = actors.get(actor_id)
	if a == null or not a.loot_available:
		return
	inventory.gold += a.loot.gold
	Items.add(inventory, a.loot.item, 1)   # stacks by name
	a.loot_available = false
	emit({ type = "loot_taken", actor = a, loot = a.loot })
