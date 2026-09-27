extends RefCounted
## A combatant: stats, position, life state, corpse loot.

const Progress = preload("res://sim/progress.gd")
const Dice = preload("res://sim/dice.gd")

var id: String
var display_name: String
var faction: String
var lp: int
var max_lp: int
var ap: int
var max_ap: int
var mp := 0            # Magic Points — spellcasting energy, a pool
var max_mp := 0        # SEPARATE from AP. max_mp <= 0 = no MP pool
                       # (non-spellcasters never carry fake mana)
var exert := 0.0       # seconds of remaining recent exertion — AP
                       # rest recovery only accrues at exert == 0
var perception: int
var dodge: int
var hex: Vector2i
var alive := true
var loot := {}            # set on death
var loot_available := false
var resist := {}          # damage type -> multiplier (empty = x1.0 everything);
                          # doubles as creature susceptibility for physical
                          # types (slash/pierce/impact) — README §22
var armor := {}           # LP mitigation: {lp = n, types = {type -> extra}};
                          # armor protects bodily injury, not AP shock
var effects := {}         # status accumulators, e.g. {"cold": 3} -> Frozen later

# Combatant fields (melee milestone). All optional in config entries:
var attack := 0           # d20 modifier on the attack roll
var defense := 0          # base Defense — feeds the active defense roll
var shield := 0           # shield bonus to effective Defense (0 = no shield)
var weapon := "1d4"       # damage dice on a successful hit
var attack_range := 1     # hex reach of the melee strike
var ai := ""              # "" inert, "defend"/"brawl" heroes, "advance" enemies
var leash := 4            # heroes: defensive radius around `anchor`
var anchor := Vector2i.ZERO  # assigned defensive position (defaults to spawn)
var act_cd := 1.8         # seconds between attack attempts
var move_cd := 1.2        # seconds between hex steps
var cd := 0.0             # live cooldown (sim clock)
var regen_t := 0.0        # AP regen accumulator (sim clock)
var mp_regen_t := 0.0     # MP regen accumulator — continuous, not
                          # gated by exertion (Playable Loop 0.4)
var exh_announced := false # true while the "entered EXHAUSTED" event
                          # has fired but AP has not yet recovered —
                          # transition notification, never per-action
var crit_announced := false # same one-shot pattern for CRITICAL
                          # CONDITION (friendly LP at the threshold)
var level_unseen := false # an applied Level-Up the player has not yet
                          # acknowledged — the rail badge rides this
                          # until that hero's sheet is inspected;
                          # persisted so it survives save/load
var deployed := true      # reserve heroes stand at the muster point until deployed
var participated := false # entered the battlefield at least once —
                          # gates shared Encounter XP; death does not
                          # revoke it (README §22)
var elevated := false     # posted above the field (the wizard on the
                          # battlement) — melee level 1 regardless of hex
var progress              # sim/progress.gd — XP, Level, attributes,
                          # learned development (always present)

# Playable Party 0.5 — command + support-spell state.
var focus_id := ""        # explicit player target order: heroes chase
                          # this enemy instead of the zone default;
                          # cleared when the target dies/disengages
var focus_stall := 0      # consecutive failed steps toward the focus
                          # mark — at COMMAND.focus_stall_limit the
                          # order is dropped as unreachable (0.5)
var objective_id := ""    # assault objective for ai="march": the id of a
                          # STRUCTURE this actor advances on (the Keep).
                          # Empty -> the actor uses its ordinary
                          # hostility-based goal. Set by the scenario,
                          # never by combat.
var spells: Array = []    # support-spell ids this actor owns — the
                          # healer's kit; Support.cast refuses spells
                          # the caster does not know
var spell_range := 0      # >0 overrides every spell's `range` for this
                          # caster (Tower: Althar reaches the whole
                          # battlefield); 0 = the spell's own range
var heal_cd := 0.0        # Heal cooldown remaining — ACTIVE gameplay
                          # seconds (ticks in the live sim loop only)
var resur_cd := 0.0       # Resurrection cooldown — 20 min of active,
                          # unpaused gameplay; belongs to the caster
var last_absorbed := 0    # transient: LP an Aegis barrier soaked in
                          # the most recent apply_damage (not saved)

# Inventory 0.1 — the hero's belt: BELT_SLOTS quick-item slots
# holding item NAMES that reference the shared inventory stack
# ("" = empty). Quick-use applies the item to the wearer.
var belt: Array = []

# Equipment: `equipment` maps slot name -> worn item name. The worn
# piece's modifiers are BAKED into the ordinary fields above
# (weapon/attack/defense/shield/armor) at equip time and persist with
# them — nothing re-derives on load. `equipment_stowed` records the
# field values a worn piece DISPLACED (today: only `weapon`, which is
# a replacement not a bonus) so unequip reverses exactly after a
# save/load. `hero_class` is the eligibility key items' `usable_by`
# lists test — "" means "no class", which matches nothing.
var equipment := {}
var equipment_stowed := {}
var hero_class := ""

# Generated-actor identity (roster scenarios such as the Tower):
# `archetype` is the ENEMY_ARCHETYPES key, `variant` the archetype's
# variant label, `threat` its authored danger rating — all stamped by
# Enemy.build_wave; authored actors carry the defaults. `spawn` is a
# JSON-safe copy of the whole creation dict kept only when the dict
# was flagged `_roster` (a generated individual, not an authored
# entry) — it lets apply_save rebuild wave actors whose ids a fresh
# battle does not know.
var archetype := ""
var variant := ""
var threat := 0
var spawn := {}

static func create(d: Dictionary, rng = null) -> RefCounted:
	var a = (load("res://sim/actor.gd") as GDScript).new()
	a.id = d.id
	a.display_name = d.display_name
	a.faction = d.faction
	a.lp = d.lp
	a.max_lp = d.lp
	a.ap = d.ap
	a.max_ap = d.ap
	a.perception = d.perception
	a.dodge = d.dodge
	a.hex = d.hex
	a.attack = d.get("attack", 0)
	# archetype base + bounded INDIVIDUAL variation, rolled once at
	# spawn and fixed for the actor's life (README — enemy archetypes)
	if d.has("attack_var") and rng != null:
		a.attack += Dice.roll(rng, d.attack_var).total
	a.resist = d.get("resist", {}).duplicate()
	a.armor = d.get("armor", {}).duplicate()
	a.defense = d.get("defense", 0)
	a.shield = d.get("shield", d.get("block", 0))
	a.weapon = d.get("weapon", "1d4")
	a.attack_range = d.get("attack_range", 1)
	a.ai = d.get("ai", "")
	a.leash = d.get("leash", 4)
	a.anchor = d.get("anchor", a.hex)
	a.act_cd = d.get("act_cd", 1.8)
	a.move_cd = d.get("move_cd", 1.2)
	a.mp = d.get("mp", 0)
	a.max_mp = a.mp
	a.deployed = d.get("deployed", true)
	a.participated = a.deployed
	a.elevated = d.get("elevated", false)
	a.spells = d.get("spells", []).duplicate()
	a.spell_range = d.get("spell_range", 0)
	a.objective_id = d.get("objective_id", "")
	a.hero_class = d.get("hero_class", "")
	a.archetype = d.get("archetype", "")
	a.variant = d.get("variant", "")
	a.threat = int(d.get("threat", 0))
	var Cfg = load("res://sim/config.gd")
	for i in range(Cfg.BELT_SLOTS):
		a.belt.append("")
	a.progress = Progress.create(d)
	if d.get("_roster", false):
		# a generated individual keeps its creation dict so a save can
		# rebuild it in a battle whose fresh wave has other ids —
		# engine value types (hex/anchor Vector2i) cannot survive
		# JSON, so the copy is scrubbed to plain arrays
		a.spawn = _json_safe(d)
	return a

## Deep-copy into JSON-safe data: Vector2i/Vector2/Vector3i/Vector3/
## Color collapse to plain number arrays; Dictionaries and Arrays are
## scrubbed recursively. Scalars pass through unchanged.
static func _json_safe(v):
	if v is Vector2i or v is Vector2:
		return [v.x, v.y]
	if v is Vector3i or v is Vector3:
		return [v.x, v.y, v.z]
	if v is Color:
		return [v.r, v.g, v.b, v.a]
	if v is Dictionary:
		var out := {}
		for k in v:
			out[k] = _json_safe(v[k])
		return out
	if v is Array:
		var arr: Array = []
		for e in v:
			arr.append(_json_safe(e))
		return arr
	return v

## Apply damage; returns true if this damage killed the actor.
## AEGIS (Playable Party 0.5): while `effects.aegis` carries a pool,
## bodily injury drains the barrier before touching LP — the shield
## breaks when its pool empties. AP shock is unaffected: Aegis
## guards the body, not the wind.
func apply_damage(n: int) -> bool:
	last_absorbed = 0
	if n > 0:
		var ag = effects.get("aegis")
		if ag is Dictionary and int(ag.get("pool", 0)) > 0:
			var soaked: int = mini(int(ag.pool), n)
			ag.pool = int(ag.pool) - soaked
			n -= soaked
			last_absorbed = soaked
			if int(ag.pool) <= 0:
				effects.erase("aegis")
	lp -= n
	if lp <= 0 and alive:
		alive = false
		return true
	return false

## True while this actor carries a Magic Points pool (spellcasters
## only — Althar, the Healer). Non-spellcasters have max_mp 0 and
## can never satisfy an mp_cost.
func has_mp() -> bool:
	return max_mp > 0

## CANONICAL healing: a heal of N restores up to N LP AND up to N AP
## — the pools cap independently, and surplus in one does NOT
## convert into the other. Healing never restores MP (magical energy
## is a separate resource; MP restoration needs an explicit design).
## Returns {lp, ap} actually restored — Contribution XP counts the
## LP number only, no XP for overhealing or for AP (README §22).
func heal(n: int) -> Dictionary:
	var lp_r: int = mini(maxi(n, 0), max_lp - lp)
	lp += lp_r
	var ap_r: int = mini(maxi(n, 0), max_ap - ap)
	ap += ap_r
	return {lp = lp_r, ap = ap_r}

## EXHAUSTED: AP 0 is a state, not a death sentence (README §22).
## CANONICAL (Playable Loop 0.4): an exhausted actor still acquires
## targets, moves, attacks, defends and dodges — AP costs clamp at 0
## rather than blocking the action. The final Exhausted penalty
## design (e.g. Attack/Defense modifiers) is DEFERRED.
func is_exhausted() -> bool:
	return alive and ap <= 0

## HASTE (Playable Party 0.5): cooldown multiplier for this actor's
## action/move cadence. effects.haste = {t = seconds left, mult}.
## 1.0 outside the effect — the scheduler multiplies every cd it
## assigns by this, so a hasted hero genuinely acts faster without
## touching authored stats.
func cadence_mult() -> float:
	var e = effects.get("haste")
	if e is Dictionary:
		return maxf(0.2, float(e.get("mult", 1.0)))
	return 1.0

# ---------------- SAVE/LOAD (Playable Loop 0.4) ----------------
# Plain-data serialization — no Node/SceneTree state. Identity
# fields (id, display_name, faction) come from the config entry;
# everything below is live run state worth persisting.

func to_dict() -> Dictionary:
	var out := {
		lp = lp, max_lp = max_lp, ap = ap, max_ap = max_ap,
		mp = mp, max_mp = max_mp,
		hex = [hex.x, hex.y], anchor = [anchor.x, anchor.y],
		alive = alive, deployed = deployed,
		participated = participated, elevated = elevated,
		level_unseen = level_unseen,
		exert = exert, regen_t = regen_t, mp_regen_t = mp_regen_t,
		exh_announced = exh_announced, crit_announced = crit_announced,
		effects = effects.duplicate(true),
		loot = loot.duplicate(), loot_available = loot_available,
		attack = attack, defense = defense, shield = shield,
		weapon = weapon, attack_range = attack_range,
		perception = perception, dodge = dodge,
		resist = resist.duplicate(), armor = armor.duplicate(true),
		ai = ai, leash = leash, act_cd = act_cd, move_cd = move_cd,
		cd = cd,
		focus_id = focus_id, focus_stall = focus_stall,
		spell_range = spell_range,
		heal_cd = heal_cd, resur_cd = resur_cd,
		objective_id = objective_id,
		spells = spells.duplicate(), belt = belt.duplicate(),
		hero_class = hero_class,
		equipment = equipment.duplicate(),
		equipment_stowed = equipment_stowed.duplicate(true),
		archetype = archetype, variant = variant, threat = threat,
		progress = progress.to_dict() if progress != null else {},
	}
	if not spawn.is_empty():
		# the rebuild recipe a generated-actor save rests on —
		# already JSON-safe by construction
		out.spawn = spawn.duplicate(true)
	return out

## Overlay saved run state onto an actor built from its config entry.
func apply_dict(d: Dictionary) -> void:
	lp = d.get("lp", lp)
	max_lp = d.get("max_lp", max_lp)
	ap = d.get("ap", ap)
	max_ap = d.get("max_ap", max_ap)
	mp = d.get("mp", mp)
	max_mp = d.get("max_mp", max_mp)
	if d.has("hex"):
		hex = Vector2i(d.hex[0], d.hex[1])
	if d.has("anchor"):
		anchor = Vector2i(d.anchor[0], d.anchor[1])
	alive = d.get("alive", alive)
	deployed = d.get("deployed", deployed)
	participated = d.get("participated", participated)
	elevated = d.get("elevated", elevated)
	level_unseen = d.get("level_unseen", level_unseen)
	exert = d.get("exert", exert)
	regen_t = d.get("regen_t", regen_t)
	mp_regen_t = d.get("mp_regen_t", mp_regen_t)
	exh_announced = d.get("exh_announced", exh_announced)
	crit_announced = d.get("crit_announced", crit_announced)
	effects = d.get("effects", {}).duplicate(true)
	loot = d.get("loot", {}).duplicate()
	loot_available = d.get("loot_available", loot_available)
	attack = d.get("attack", attack)   # archetype variation included
	defense = d.get("defense", defense)
	shield = d.get("shield", shield)
	weapon = d.get("weapon", weapon)
	attack_range = d.get("attack_range", attack_range)
	perception = d.get("perception", perception)
	dodge = d.get("dodge", dodge)
	resist = d.get("resist", {}).duplicate()
	armor = d.get("armor", {}).duplicate(true)
	ai = d.get("ai", ai)
	leash = d.get("leash", leash)
	act_cd = d.get("act_cd", act_cd)
	move_cd = d.get("move_cd", move_cd)
	cd = d.get("cd", cd)
	focus_id = d.get("focus_id", focus_id)
	focus_stall = d.get("focus_stall", focus_stall)
	spell_range = d.get("spell_range", spell_range)
	objective_id = d.get("objective_id", objective_id)
	heal_cd = d.get("heal_cd", heal_cd)
	resur_cd = d.get("resur_cd", resur_cd)
	if d.has("spells"):
		spells = d.spells.duplicate()
	if d.has("belt"):
		# pad/truncate to the configured band so old saves and rule
		# changes both degrade safely
		var Cfg = load("res://sim/config.gd")
		belt = d.belt.duplicate()
		belt.resize(Cfg.BELT_SLOTS)
		for i in range(belt.size()):
			if belt[i] == null:
				belt[i] = ""
	hero_class = d.get("hero_class", hero_class)
	equipment = d.get("equipment", {}).duplicate()
	equipment_stowed = d.get("equipment_stowed", {}).duplicate(true)
	archetype = d.get("archetype", archetype)
	variant = d.get("variant", variant)
	threat = int(d.get("threat", threat))
	# NOTE: `spawn` is deliberately NOT read here — an actor restored
	# from its spawn copy already carries it from create(); overlaying
	# it again would only alias the save's copy.
	if progress != null and d.get("progress") is Dictionary:
		progress.apply_dict(d.progress)
