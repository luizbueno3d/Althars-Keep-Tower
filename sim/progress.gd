extends RefCounted
## Character Progression 0.1 (root README §22).
##
## The heroes begin exceptional — progression records experience and
## development, never generic stat inflation:
##
##   - `xp_lifetime` only grows; it derives the Level via configurable
##     thresholds. `xp_available` is the spendable pool — spending it
##     never reduces Lifetime XP or Level.
##   - `attrs` holds the seven core attributes (str/dex/agi/con/int/
##     cha/mag) on the ~1-100 human scale. Starting values are authored
##     design awaiting human approval — none are invented here.
##   - Level Up fires the advancement sequence: AP roll (endurance
##     grows), then the d100 Attribute Advancement Check. LP is
##     untouched — Level never grants LP.
##   - `skills` / `abilities` / `spell_prog` are storage containers for
##     the spend-XP layer; no catalogue is invented.
##   - `learned` holds trainable combat values (Spellcasting, Attack,
##     Defense, Resistance). `bonuses` holds named modifier pools fed
##     by attributes later — LEARNED VALUE + BONUSES = EFFECTIVE
##     VALUE, and the parts stay separately inspectable.
##
## Pure sim: no Node APIs; all rolls through the injected rng.

const Dice = preload("res://sim/dice.gd")

var level := 1
var xp_lifetime := 0      # never decreases; determines Level
var xp_available := 0     # spendable pool for skills/abilities/spells
var attrs := {}           # "str".."mag" -> int (1-100+ scale)
var learned := {}         # "spellcasting"/"attack"/... -> learned int
var start := {}           # the hero's AUTHORED learned baselines —
                          # copy of `learned` at creation; the training
                          # ceiling keys off it so a hero who starts
                          # above the archetype baseline (the Archer's
                          # +10 Attack) can still develop
var bonuses := {}         # "magic"/... -> int (attribute-fed later)
var temp := {}            # value name -> temporary modifier (enchant-
                          # ments, buffs, debuffs) — never rewrites the
                          # learned value; expiry is a future system
var skills := {}          # skill id -> rank (development layer)
var abilities := []       # learned ability ids
var spell_prog := {}      # spell id -> progression state
var history := []         # resolved Level-Up records — plain data
                          # only, built for future serialization
var pending_attr_choice = null   # d100=100 awaiting player pick:
                          # {level, d100, eligible[]}. While set,
                          # later queued Level-Ups do NOT process —
                          # no advancement roll may be skipped.
var _pending_hist = null  # history entry the pending choice updates
                          # (in-memory ref; not serialized)
var rig_d100 := -1        # debug: >0 forces the next advancement d100
                          # (acceptance driver rigs a natural 100)

## Build progression state from an actor config entry. Optional keys:
## `attributes` (authored dict), `xp_lifetime`, `xp_available`,
## `level`, `learned`, `bonuses`, `skills`, `abilities`, `spell_prog`.
static func create(d: Dictionary) -> RefCounted:
	var p = (load("res://sim/progress.gd") as GDScript).new()
	p.attrs = d.get("attributes", {}).duplicate()
	p.xp_lifetime = d.get("xp_lifetime", 0)
	p.xp_available = d.get("xp_available", 0)
	p.learned = d.get("learned", {}).duplicate()
	p.start = p.learned.duplicate()
	p.bonuses = d.get("bonuses", {}).duplicate()
	p.skills = d.get("skills", {}).duplicate()
	p.abilities = d.get("abilities", []).duplicate()
	p.spell_prog = d.get("spell_prog", {}).duplicate()
	p.level = d.get("level", 1)
	return p

func attr(name: String) -> int:
	return attrs.get(name, 0)

## XP earned: both pools grow together.
func add_xp(n: int) -> void:
	if n <= 0:
		return
	xp_lifetime += n
	xp_available += n

## Spend from the available pool only. Returns false (and spends
## nothing) when the pool cannot cover the cost.
func spend_xp(cost: int) -> bool:
	if cost < 0 or cost > xp_available:
		return false
	xp_available -= cost
	return true

## Lifetime XP required to reach Level `lv` (1-based; Level 1 = 0).
## The authored table covers Levels 1-6; beyond it the PROVISIONAL
## curve extrapolates the table's own accelerating deltas
## (+100,+150,+250,+400,+500 -> +600,+700,...) so a Level 10 hero —
## which canonical design already discusses — is reachable. A table
## boundary is a data edge, never a designed maximum Level.
func level_xp_for(lv: int, cfg = null) -> int:
	var steps: Array = _level_xp(cfg)
	if lv <= steps.size():
		return int(steps[lv - 1])
	var val: int = int(steps[-1])
	var step: int = 100
	if steps.size() > 1:
		step = int(steps[-1]) - int(steps[-2])
	for l in range(steps.size() + 1, lv + 1):
		step += 100
		val += step
	return val

## Level for a Lifetime XP total under the configured thresholds
## (index i = Level i+1). Unbounded: XP past the table keeps
## advancing the Level along the provisional curve.
func level_for(xp: int, cfg = null) -> int:
	var lv := 1
	while xp >= level_xp_for(lv + 1, cfg):
		lv += 1
	return lv

func _level_xp(cfg) -> Array:
	if cfg != null and "level_xp" in cfg.PROGRESSION:
		return cfg.PROGRESSION.level_xp
	return [0]

## XP threshold for the NEXT Level — always defined, since the curve
## extrapolates past the authored table.
func next_level_xp(cfg) -> int:
	return level_xp_for(level + 1, cfg)

## Levels earned but not yet applied.
func pending_levels(cfg) -> int:
	return level_for(xp_lifetime, cfg) - level

## One Level-Up advancement event (CANONICAL — recovered rule):
## EVERY Level transition gets exactly one d100 Attribute Advancement
## roll — there is no odd/even rule and no skipped transition.
## Sequence: AP advancement roll -> d100 -> table row -> d6 -> record.
## A natural 100 parks the attribute half as a pending player choice
## (the Level itself is already a fact and records immediately).
func level_up(actor, rng, cfg) -> Dictionary:
	var p = cfg.PROGRESSION
	var ap_roll: Dictionary = Dice.roll(rng, p.ap_advance)
	actor.max_ap += ap_roll.total
	var old_level := level
	level += 1
	var d100: Dictionary = Dice.roll(rng, "1d100")
	if rig_d100 > 0:
		# deterministic acceptance hook (--rigd100): the die is
		# still recorded as a real roll; only the face is forced
		d100.total = rig_d100
		rig_d100 = -1
	var adv := _advancement_roll(d100.total, rng, p)
	var ev := {
		old_level = old_level,
		level = level,
		ap_roll = ap_roll,
		ap_gain = ap_roll.total,
		advancement = adv,
	}
	_record_level_up(actor, ev)
	return ev

## Resolve the d100 against the advancement table. `result` values:
## "none" (1-79), "advance" (mapped attribute +d6), "unmapped"
## (historical attribute with no modern mapping yet — recorded,
## nothing rises), "at_cap", "choice_required" (100 -> player picks).
func _advancement_roll(n: int, rng, p) -> Dictionary:
	var adv := {d100 = n, result = "none", name = "", attr = "",
		d6 = null, old_value = 0, new_value = 0,
		choice_required = false, eligible = [], capped = false}
	if n >= 100:
		var elig := _eligible_attrs(p)
		if elig.is_empty():
			adv.result = "at_cap"
			return adv
		adv.result = "choice_required"
		adv.choice_required = true
		adv.eligible = elig
		pending_attr_choice = {level = level, d100 = n,
			eligible = elig}
		return adv
	for row in p.attr_advance:
		if n >= row.lo and n <= row.hi:
			adv.name = row.name
			if row.attr == null:
				adv.result = "unmapped"   # mapping gate — documented,
				return adv                # never silently folded in
			adv.attr = row.attr
			return _apply_advancement(adv, row.attr, rng, p)
	return adv

func _eligible_attrs(p) -> Array:
	var out: Array = []
	for a2 in p.attr_candidates_all:
		if attrs.get(a2, 0) < p.attr_cap:
			out.append(a2)
	return out

## Roll the d6 and apply the increase to `attr`, clamped at the
## provisional cap. The d6 always rolls on a mapped hit so the dice
## stay visible even when the cap eats the gain.
func _apply_advancement(adv: Dictionary, attr: String, rng, p) -> Dictionary:
	adv.d6 = Dice.roll(rng, p.attr_advance_die)
	adv.old_value = attrs.get(attr, 0)
	var new_val: int = adv.old_value + adv.d6.total
	if new_val > p.attr_cap:
		new_val = p.attr_cap
		adv.capped = true
	attrs[attr] = new_val
	adv.new_value = new_val
	adv.result = "advance" if new_val > adv.old_value else "at_cap"
	return adv

## Structured history record — plain data only, built to serialize
## cleanly for the future persistent-state layer (README §22).
func _record_level_up(actor, ev: Dictionary) -> void:
	var entry := {
		character = actor.id,
		old_level = ev.old_level,
		new_level = ev.level,
		lifetime_xp = xp_lifetime,
		ap_roll = ev.ap_roll.duplicate(),
		attribute_roll = ev.advancement.duplicate(true),
	}
	history.append(entry)
	if pending_attr_choice != null:
		_pending_hist = entry

## Player resolves a pending d100=100 choice. Validates against the
## eligible list, rolls the d6, applies, and completes the pending
## history entry. Returns {ok, reason, advancement}.
func resolve_attr_choice(actor, rng, cfg, attr: String) -> Dictionary:
	if pending_attr_choice == null:
		return {ok = false, reason = "no_pending"}
	if attr not in pending_attr_choice.eligible:
		return {ok = false, reason = "invalid_choice",
			eligible = pending_attr_choice.eligible}
	var adv := {d100 = pending_attr_choice.d100, result = "none",
		name = attr, attr = attr, d6 = null,
		old_value = 0, new_value = 0,
		choice_required = true,
		eligible = pending_attr_choice.eligible, capped = false}
	adv = _apply_advancement(adv, attr, rng, cfg.PROGRESSION)
	if _pending_hist != null:
		_pending_hist.attribute_roll = adv.duplicate(true)
	pending_attr_choice = null
	_pending_hist = null
	return {ok = true, advancement = adv}

## Apply every earned Level (multi-Level crossings resolve in order).
## Stops at a pending player choice — later Level-Ups queue behind
## it until the choice resolves; no d100 is ever skipped.
func check_level_ups(actor, rng, cfg) -> Array:
	var out := []
	while pending_levels(cfg) > 0 and pending_attr_choice == null:
		out.append(level_up(actor, rng, cfg))
	return out

## Persistable shape (README §18): progression state separate from
## runtime lp/ap, which live on the actor itself.
func to_dict() -> Dictionary:
	return {
		level = level,
		xp_lifetime = xp_lifetime,
		xp_available = xp_available,
		attributes = attrs.duplicate(),
		learned = learned.duplicate(),
		start = start.duplicate(),
		bonuses = bonuses.duplicate(),
		temp = temp.duplicate(),
		skills = skills.duplicate(),
		abilities = abilities.duplicate(),
		spell_prog = spell_prog.duplicate(),
		history = history.duplicate(true),
		pending_attr_choice = pending_attr_choice.duplicate(true) \
			if pending_attr_choice != null else null,
	}

## Restore serialized progression state (Playable Loop 0.4 saves).
func apply_dict(d: Dictionary) -> void:
	level = d.get("level", level)
	xp_lifetime = d.get("xp_lifetime", xp_lifetime)
	xp_available = d.get("xp_available", xp_available)
	attrs = d.get("attributes", {}).duplicate()
	learned = d.get("learned", {}).duplicate()
	# saves predate `start`: fall back to the created baselines
	start = d.get("start", start.duplicate()).duplicate()
	bonuses = d.get("bonuses", {}).duplicate()
	temp = d.get("temp", {}).duplicate()
	skills = d.get("skills", {}).duplicate()
	abilities = d.get("abilities", []).duplicate()
	spell_prog = d.get("spell_prog", {}).duplicate()
	history = d.get("history", []).duplicate(true)
	pending_attr_choice = d.get("pending_attr_choice", null)
	if pending_attr_choice is Dictionary:
		pending_attr_choice = pending_attr_choice.duplicate(true)
		_pending_hist = history.back() if not history.is_empty() \
			else null

# ---------------- LEARNED VALUES + BONUSES ----------------
# Canon (README §22): EFFECTIVE = LEARNED + BONUSES, kept separately
# inspectable. The learned value is purchased deliberately with
# Available XP; bonuses come from attributes/equipment later.

func learned_value(name: String) -> int:
	return learned.get(name, 0)

func bonus_value(name: String) -> int:
	return bonuses.get(name, 0)

## {learned, bonuses:{name:int}, temp:int, total} — the full
## breakdown a visible-dice panel needs. Only the bonus pools mapped
## to this learned value in config contribute; `temp` adds
## temporary enchantment/buff modifiers keyed by the value name.
func effective(name: String, cfg) -> Dictionary:
	var parts := {}
	var total: int = learned_value(name)
	var spec: Dictionary = _learned_spec(name, cfg)
	for b in spec.get("bonuses", []):
		parts[b] = _pool_value(b, cfg)
		total += parts[b]
	var t: int = temp.get(name, 0)
	return {learned = learned_value(name), bonuses = parts,
		temp = t, total = total + t}

## A bonus pool's current value. Pools listed in
## PROGRESSION.attr_pools are attribute-derived — Table M bands
## looked up live against `attrs`, so attribute advancement moves
## the bonus automatically (Character Foundations 0.2). Any other
## pool reads the `bonuses` dict (equipment/situational — future).
func _pool_value(name: String, cfg) -> int:
	if cfg == null:
		return bonus_value(name)
	var spec: Dictionary = cfg.PROGRESSION.get("attr_pools", {}) \
		.get(name, {})
	if spec.is_empty():
		return bonus_value(name)
	var v: int = attrs.get(spec.attr, 0)
	for band in cfg.PROGRESSION.get(spec.table, []):
		if v >= band[0] and v <= band[1]:
			return band[2]
	return 0   # 0 / >100 -> no bonus (>100 rule DEFERRED)

## Just the progression-layer delta over an actor's authored base:
## learned + mapped bonuses + temporary modifiers.
func modifier(name: String, cfg = null) -> int:
	return effective(name, cfg).total

func _learned_spec(name: String, cfg) -> Dictionary:
	if cfg != null:
		return cfg.PROGRESSION.learned.get(name, {})
	return {}

## Highest trainable learned value at the current Level.
## "even" ceiling (canonical for Spellcasting through L10, under
## review beyond; PROVISIONAL for the combat values): start + floor(L/2),
## where `start` is the higher of the archetype baseline and THIS
## hero's authored start — the Archer begins at Attack +10 by design
## and is not blocked by the baseline-0 combat-value ceiling.
## "none" = ceiling rules unresolved -> the value cannot be trained.
func max_learned(name: String, cfg) -> int:
	var spec: Dictionary = _learned_spec(name, cfg)
	var base: int = maxi(spec.get("start", 0), start.get(name, 0))
	match spec.get("ceiling", "none"):
		"even":
			return base + level / 2
	return base

## XP price for a learned value's destination rank. Defined ranks
## come from the provisional table; past it the table's own
## 50-XP-per-rank slope continues so development never dead-ends.
## -1 only when the value has no cost table at all.
static func learned_cost(cfg, name: String, rank: int) -> int:
	var costs: Dictionary = cfg.PROGRESSION.learned_costs.get(name, {})
	if costs.has(rank):
		return int(costs[rank])
	if costs.is_empty():
		return -1
	var top: int = 0
	for k in costs.keys():
		top = maxi(top, int(k))
	return int(costs[top]) + 50 * (rank - top)

## Purchase the next +1 of a learned value with Available XP.
## Respects the Level-dependent training ceiling and the configured
## escalating cost table. Returns {ok, reason, cost, learned, cap}.
func purchase_learned(name: String, cfg) -> Dictionary:
	var cur: int = learned_value(name)
	var cap: int = max_learned(name, cfg)
	if cur >= cap:
		return {ok = false, reason = "ceiling", learned = cur,
			cap = cap}
	var cost: int = learned_cost(cfg, name, cur + 1)
	if cost < 0:
		return {ok = false, reason = "no_cost_rule", learned = cur,
			cap = cap}
	if not spend_xp(cost):
		return {ok = false, reason = "xp", cost = cost,
			learned = cur, cap = cap}
	learned[name] = cur + 1
	return {ok = true, cost = cost, learned = cur + 1, cap = cap}

# ---------------- XP AWARDS ----------------
# Source-agnostic entry point (README §22): combat, encounters and
# objectives all feed XP through here. Any award resolves pending
# Level-Ups since Level derives from Lifetime XP.
# Ordinary enemies do NOT accumulate player-style progression XP —
# their capability comes from archetype/variation/equipment/effects,
# not the XP economy (README §22, Combat Foundation 0.3).

static func award(battle, actor, amount: int, source: String,
		context := {}) -> void:
	if amount <= 0 or actor == null or actor.progress == null \
			or actor.faction != "friendly":
		return
	actor.progress.add_xp(amount)
	var ev := {type = "xp", actor = actor.id, amount = amount,
		source = source}
	if not context.is_empty():
		ev.context = context
	battle.emit(ev)
	for lu in _run_level_ups(battle, actor):
		battle.emit(lu)

## Level-Up sequence for every pending level -> level_up events.
## Any applied level raises the hero's persistent `level_unseen`
## marker — the party rail carries it until the player inspects
## that hero's sheet (and it survives save/load unacknowledged).
static func _run_level_ups(battle, actor) -> Array:
	var out := []
	for lu in actor.progress.check_level_ups(
			actor, battle.rng, battle.config):
		actor.level_unseen = true
		out.append({type = "level_up", actor = actor.id,
			old_level = lu.old_level, level = lu.level,
			ap_roll = lu.ap_roll, ap_gain = lu.ap_gain,
			advancement = lu.advancement})
	return out

## Resolve a pending d100=100 player choice, emit its event, then
## drain any Level-Ups that queued behind the decision (each gets
## its own d100 — the queue resumes in order).
static func resolve_advancement_choice(battle, actor, attr: String) -> Array:
	var res: Dictionary = actor.progress.resolve_attr_choice(
		actor, battle.rng, battle.config, attr)
	if not res.get("ok", false):
		return [res]
	var out := [{type = "advancement_resolved", actor = actor.id,
		advancement = res.advancement}]
	battle.emit(out[0])
	for lu in _run_level_ups(battle, actor):
		out.append(lu)
		battle.emit(out[-1])
	return out

## Encounter XP (README §22): a shared pool divided equally among
## PARTICIPATING allies — friendly actors who entered the battlefield
## at any point. Death does not remove participation; a hero who
## stayed in reserve the whole encounter receives nothing.
static func award_encounter(battle, total: int, context := {}) -> void:
	var parts: Array = []
	for id in battle.actor_order:
		var a = battle.actors[id]
		if a.faction == "friendly" and a.participated:
			parts.append(a)
	if parts.is_empty():
		return
	var share: int = total / parts.size()   # equal split, floor
	for a in parts:
		var ctx := context.duplicate()
		ctx.pool = total
		ctx.participants = parts.size()
		award(battle, a, share, "encounter", ctx)
