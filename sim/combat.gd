extends RefCounted
## Melee resolution + combatant autonomy (gameplay pass 0.1).
##
## Deterministic: all rolls through battle.rng. Pure sim — emits
## structured events, presentation renders them.
##
## Autonomy model (defensive-anchor version):
##   - every actor with `ai` != "" ticks a cooldown;
##   - if a hostile is inside `attack_range` -> strike;
##   - "advance" enemies march on the keep's defenders;
##   - heroes ("defend"/"brawl") hold an assigned DEFENSIVE ZONE —
##     the hexes within `leash` of their `anchor`. They intercept
##     hostiles inside the zone, never chase outside it, and return
##     toward the anchor when the zone is clear. Teleport reassigns
##     the anchor: it is literally the "defend HERE" order.
##   - the zone model assumes nothing about how threats arrive —
##     a future ranged enemy standing outside every leash simply
##     leaves the heroes holding while the player decides.

const Hex = preload("res://sim/hex.gd")
const Dice = preload("res://sim/dice.gd")
const Checks = preload("res://sim/checks.gd")
const Damage = preload("res://sim/damage.gd")
const Loot = preload("res://sim/loot.gd")
const Progress = preload("res://sim/progress.gd")
const Support = preload("res://sim/support.gd")
const Cfg = preload("res://sim/config.gd")

static func update(battle, dt: float) -> void:
	for id in battle.actor_order:
		var a = battle.actors[id]
		# CRITICAL CONDITION (friendly heroes): LP at or below the
		# configured fraction — a state transition warning, not a
		# per-frame siren. Checked before the alive gate so dying
		# clears the warning instead of latching it on a corpse.
		if a.faction == "friendly":
			var crit: bool = a.alive and a.lp > 0 \
				and a.lp <= int(ceil(
					a.max_lp * Cfg.FEEDBACK.critical_lp_frac))
			if crit and not a.crit_announced:
				a.crit_announced = true
				battle.emit({type = "critical", actor = a.id})
			elif not crit and a.crit_announced:
				a.crit_announced = false
				battle.emit({type = "critical_end", actor = a.id})
		if not a.alive:
			continue
		# Timed status effects + support-spell cooldowns (Playable
		# Party 0.5) tick here — inside the live sim loop, for the
		# living only. Pause, death, save and quit all freeze these
		# clocks; Resurrection's 20 minutes is ACTIVE gameplay time.
		_tick_effects(battle, a, dt)
		a.heal_cd = maxf(0.0, a.heal_cd - dt)
		var resur_was: float = a.resur_cd
		a.resur_cd = maxf(0.0, a.resur_cd - dt)
		if resur_was > 0.0 and a.resur_cd <= 0.0:
			battle.emit({type = "resur_ready", actor = a.id})
		# CANONICAL AP recovery (Playable Loop 0.4): only genuine
		# rest restores AP — +1 AP per ap_regen seconds after
		# rest_delay quiet seconds. Any strenuous act (strike, step,
		# cast, dodge) AND being struck at (combat pressure) marks
		# the rest clock. AP caps at max_ap — never at current LP.
		a.exert = maxf(0.0, a.exert - dt)
		if a.exert <= 0.0:
			a.regen_t += dt
			if a.regen_t >= Cfg.MELEE.ap_regen:
				a.regen_t -= Cfg.MELEE.ap_regen
				a.ap = mini(a.ap + 1, a.max_ap)
		else:
			a.regen_t = 0.0
		# CANONICAL MP recovery (Playable Loop 0.4): MP-bearing
		# actors regenerate +1 MP per mp_regen seconds CONTINUOUSLY
		# — during battle, unaffected by the exertion clock. The
		# accumulator resets only at the cap so post-spend recovery
		# starts cleanly. Applies to Althar now; the Healer inherits
		# the rule when activated.
		if a.has_mp():
			if a.mp >= a.max_mp:
				a.mp_regen_t = 0.0
			else:
				a.mp_regen_t += dt
				while a.mp_regen_t >= Cfg.MELEE.mp_regen \
						and a.mp < a.max_mp:
					a.mp_regen_t -= Cfg.MELEE.mp_regen
					a.mp += 1
		# EXHAUSTED is a state transition, not an action lock: the
		# event fires once on entering AP 0 and re-arms on recovery
		# — never per attempt (Playable Loop 0.4).
		if a.ap <= 0:
			if not a.exh_announced:
				a.exh_announced = true
				battle.emit({type = "exhausted", actor = a.id})
		elif a.exh_announced:
			a.exh_announced = false
		if a.ai == "":
			continue
		a.cd = maxf(0.0, a.cd - dt)
		if a.cd <= 0.0:
			_act(battle, a)
	# arrows in flight tick on the same sim clock — draw, release,
	# travel, impact. A loosed arrow resolves even if its archer fell.
	_tick_arrows(battle, dt)
	# encounter boundary: last enemy down -> group complete. Encounter
	# XP is shared by participating allies; dead participants still
	# share (README §22). NEXT GROUP respawns from battle.gd.
	if not battle.encounter_done and battle.living_enemies().is_empty():
		battle.encounter_done = true
		battle.emit({type = "encounter_end", group = battle.group_index})
		var pool: int = battle.config.ENCOUNTER_XP
		if pool > 0:
			Progress.award_encounter(battle, pool,
				{group = battle.group_index})
	# DEFENCE LOST: every defended structure has fallen. The sim only
	# records the fact — what the scenario does about it (stop, offer a
	# restart, let the run continue) is presentation's business.
	if not battle.defense_lost and not battle.structure_order.is_empty() \
			and battle.living_structures().is_empty():
		battle.defense_lost = true
		battle.emit({type = "defense_lost"})

static func _act(battle, a) -> void:
	var targets := _hostiles(battle, a)
	if a.ai == "shoot":
		# ranged autonomy is its own path — the archer never takes
		# the melee strike branch (her `attack_range` is bow reach)
		_act_shoot(battle, a, targets)
		return
	var reach = _nearest_within(a, targets, a.attack_range)
	if reach != null and _melee_level(battle, reach) != _melee_level(battle, a):
		# melee never crosses elevation — a posted hero cannot strike
		# down and ground enemies cannot strike up
		reach = null
	if reach != null:
		_strike(battle, a, reach)
		a.cd = a.act_cd * a.cadence_mult()
		return
	# ASSAULT (tower defence): march on the assigned structure and break
	# it. Heroes are fought only when they physically block the way — the
	# adjacent-strike branch above — so a marching enemy resumes its
	# advance the moment the road is clear again. It never ghosts through
	# a defender, and it never chases one off the route.
	if a.ai == "march":
		_assault(battle, a)
		return
	var goal = null
	if a.ai == "advance":
		# enemies march on the keep — nearest living defender
		goal = _nearest_within(a, targets, 99)
	else:
		# heroes: an explicit player order overrides zone behavior —
		# engage the marked enemy anywhere on the field (0.5)
		var fo = _focus(battle, a)
		if fo != null:
			goal = fo
		elif a.ai == "mend":
			# Healer triage — heal/close on the most-wounded ally;
			# falls through to anchor discipline when nobody needs him
			if _mend(battle, a):
				return
		elif a.ai == "defend" or a.ai == "brawl":
			# defenders intercept hostiles inside their zone
			goal = _nearest_in_zone(battle, a, targets, a.leash)
		if goal == null and a.hex != a.anchor:
			# zone clear — drift back to the assigned position
			if _step(battle, a, a.anchor):
				a.cd = a.move_cd * a.cadence_mult()
			else:
				a.cd = a.move_cd * 0.5 * a.cadence_mult()
			return
	if goal == null:
		a.cd = a.move_cd * 0.5 * a.cadence_mult()
		return
	if _step(battle, a, goal.hex):
		a.cd = a.move_cd * a.cadence_mult()
	else:
		a.cd = a.move_cd * 0.5 * a.cadence_mult()

## Explicit player order (Playable Party 0.5): the hero chases this
## enemy anywhere — leash no longer binds him. The order clears
## itself when the mark dies or can no longer be fought.
static func _focus(battle, a):
	if a.focus_id == "":
		return null
	var fo = battle.actors.get(a.focus_id)
	if fo == null or not fo.alive or fo.faction == a.faction:
		a.focus_id = ""
		return null
	return fo

## ASSAULT autonomy (tower defence): advance on the structure named by
## `a.objective_id` and break it. There is no path-following system —
## `_step` already flood-fills walkable cells to find the first step of a
## shortest walkable route, so an AUTHORED ROAD (terrain occupancy) is
## followed for free. Enemies reach the gate by walking the road because
## the road is the only way through.
static func _assault(battle, a) -> void:
	var st = battle.structures.get(a.objective_id)
	if st == null or not st.alive:
		# objective already broken or unknown — hold position
		a.cd = a.move_cd * 0.5 * a.cadence_mult()
		return
	if Hex.distance(a.hex, st.hex) <= a.attack_range:
		_strike_structure(battle, a, st)
		a.cd = a.act_cd * a.cadence_mult()
		return
	if _step(battle, a, st.hex):
		a.cd = a.move_cd * a.cadence_mult()
	else:
		a.cd = a.move_cd * 0.5 * a.cadence_mult()

## Strike a structure. The weapon's typed packet is folded through the
## structure's own resist table and armor by the SAME sim/damage.gd the
## creatures use — a structure is just another thing that can be handed a
## packet, so fire/cold/impact against masonry is a data question rather
## than a special case here.
static func _strike_structure(battle, a, st) -> void:
	a.ap = maxi(0, a.ap - Cfg.MELEE.ap_attack)
	a.exert = Cfg.MELEE.rest_delay
	var packet: Dictionary = Damage.roll_packet(battle,
		_weapon_spec(battle, a), "physical")
	var eff: int = maxi(0, Damage.packet_total(st, packet)
		- Damage.armor_mitigation(st, packet))
	var was: String = st.state()
	var broke: bool = st.apply_damage(eff)
	battle.emit({type = "structure_hit", actor = a.id,
		structure = st.id, roll = Damage.merged_roll(packet),
		effective = eff, integrity = st.integrity,
		max_integrity = st.max_integrity})
	if st.state() != was:
		battle.emit({type = "structure_state", structure = st.id,
			state = st.state(), integrity = st.integrity})
	if broke:
		battle.emit({type = "structure_lost", structure = st.id})

## Healer autonomy (Playable Party 0.5): deterministic triage —
## the most-wounded living ally worth a Heal. In range with MP and
## the cooldown ready: cast through the SAME Support.cast path the
## player uses (real check, real MP spend). Out of range: close the
## distance. RESURRECTION is never cast autonomously — it is an
## explicit player command on a 20-minute cooldown.
## Returns true when the healer acted (or chose to hold) this tick.
static func _mend(battle, a) -> bool:
	var t = _triage(battle, a)
	if t == null:
		return false
	var spec: Dictionary = Cfg.SPELLS["heal"]
	var d := Hex.distance(a.hex, t.hex)
	if d > int(spec.range):
		if _step(battle, a, t.hex):
			a.cd = a.move_cd * a.cadence_mult()
		else:
			a.cd = a.move_cd * 0.5 * a.cadence_mult()
		return true
	if a.heal_cd <= 0.0 and a.mp >= int(spec.mp_cost) \
			and a.ap >= int(spec.get("ap_cost", 0)):
		Support.cast(battle, a.id, "heal", t.id)
		# a failed weave still counts as this tick's action — the
		# MP was committed
		a.cd = a.act_cd * a.cadence_mult()
	else:
		# casualty in reach but resources/cooldown gate — hold the
		# position next to him rather than drifting away
		a.cd = a.move_cd * 0.5 * a.cadence_mult()
	return true

## The ally a Heal can most meaningfully help: living, deployed,
## and actually needing it (LP short of max OR winded past half AP).
## Lowest LP fraction wins; ties resolve by actor_order — the healer
## counts himself (self-preservation is the card's first rule).
static func _triage(battle, a):
	var best = null
	var best_frac := 1.0
	for id in battle.actor_order:
		var b = battle.actors[id]
		if b.faction != "friendly" or not b.alive or not b.deployed:
			continue
		if b.lp >= b.max_lp and b.ap > b.max_ap / 2:
			continue
		var frac := float(b.lp) / float(maxi(1, b.max_lp))
		if frac < best_frac:
			best_frac = frac
			best = b
	return best

## Timed status effects (Playable Party 0.5): entries shaped
## {t = seconds remaining, ...} count down on the live sim clock.
## Expiry emits status_end so presentation drops the status ring.
static func _tick_effects(battle, a, dt: float) -> void:
	for k in a.effects.keys():
		var e = a.effects[k]
		if not (e is Dictionary) or not e.has("t"):
			continue
		e.t = float(e.t) - dt
		if e.t <= 0.0:
			a.effects.erase(k)
			battle.emit({type = "status_end", actor = a.id, fx = k})

## Hostiles inside the hero's defensive zone: within `leash` of the
## anchor, nearest to the hero. The hero's own position does not widen
## the zone — threats outside it are ignored.
static func _nearest_in_zone(battle, a, targets: Array, leash: int):
	var best = null
	var best_d := 1 << 30
	for b in targets:
		if Hex.distance(a.anchor, b.hex) > leash:
			continue
		# ignore threats at another elevation — unreachable anyway
		if _melee_level(battle, b) != _melee_level(battle, a):
			continue
		var d := Hex.distance(a.hex, b.hex)
		if d < best_d:
			best_d = d
			best = b
	return best

## Melee reach level: battlement hexes and posted actors (the wizard)
## are level 1, everyone else 0. Strikes and engagement never cross it.
static func _melee_level(battle, a) -> int:
	return 1 if a.elevated or battle.is_wall(a.hex) else 0

static func _hostiles(battle, a) -> Array:
	var out := []
	for id in battle.actor_order:
		var b = battle.actors[id]
		if b.alive and b.faction != a.faction:
			out.append(b)
	return out

static func _nearest_within(a, targets: Array, radius: int):
	var best = null
	var best_d := 1 << 30
	for b in targets:
		var d := Hex.distance(a.hex, b.hex)
		if d <= radius and d < best_d:
			best_d = d
			best = b
	return best

## Follow a shortest walkable route. A local distance-reducing choice
## can lead into a prop cul-de-sac and oscillate with a route-around
## fallback, so each step must use the same route criterion.
static func _step(battle, a, goal: Vector2i) -> bool:
	if battle.is_wall(goal) != battle.is_wall(a.hex):
		return false
	# An actor occupies a combat goal, so reach an adjacent free hex;
	# an unoccupied command anchor must be reached exactly.
	var reach := 0 if battle.hex_free(goal) else 1
	var queue: Array[Vector2i] = [a.hex]
	var first_step := {a.hex: a.hex}
	var index := 0
	while index < queue.size():
		var current: Vector2i = queue[index]
		index += 1
		for dir in Hex.DIRECTIONS:
			var h: Vector2i = current + dir
			if first_step.has(h) or not battle.hex_free(h):
				continue
			if battle.is_wall(h) != battle.is_wall(a.hex):
				continue
			first_step[h] = h if current == a.hex else first_step[current]
			if Hex.distance(h, goal) <= reach:
				_enter_hex(battle, a, first_step[h])
				return true
			queue.append(h)
	return false

## Resolve a weapon's combat data into a damage spec for
## Damage.roll_packet: named weapons come from the WEAPONS table;
## a bare dice expression falls back to generic "physical".
static func _weapon_spec(battle, a) -> Dictionary:
	var w = battle.config.WEAPONS.get(a.weapon, null)
	if w == null:
		return {"physical": a.weapon}
	return {w.get("dmg_type", "physical"): w.damage}

## Ranged autonomy ("shoot"): acquire a mark inside the defensive
## zone — the most EXPOSED hostile (lowest LP fraction, nearest wins
## ties) — and loose real arrows at it. She never volunteers for
## melee: contact within 1 hex is answered with a kite step, not a
## strike. A player focus order overrides zone selection; anchors,
## leashes and Teleport repositioning all keep working unchanged.
static func _act_shoot(battle, a, targets: Array) -> void:
	var goal = _focus(battle, a)
	if goal == null:
		# contact threat on her level -> step off, then shoot
		var adj = _nearest_within(a,
			_melee_threats(battle, a, targets), 1)
		if adj != null and _step_away(battle, a, adj):
			a.cd = a.move_cd * a.cadence_mult()
			return
		goal = _mark_in_zone(battle, a, targets)
	if goal != null:
		var d := Hex.distance(a.hex, goal.hex)
		if d <= a.attack_range:
			_loose(battle, a, goal)
			a.cd = a.act_cd * a.cadence_mult()
			return
		if _step(battle, a, goal.hex):
			# reposition into range — she closes on distant marks but
			# never trades for contact (kite already handled that)
			a.cd = a.move_cd * a.cadence_mult()
			return
		a.cd = a.move_cd * 0.5 * a.cadence_mult()
		return
	if a.hex != a.anchor and _step(battle, a, a.anchor):
		a.cd = a.move_cd * a.cadence_mult()
		return
	a.cd = a.move_cd * 0.5 * a.cadence_mult()

## Hostiles on this actor's melee level — the ones that can actually
## grab the archer; arrows themselves ignore elevation.
static func _melee_threats(battle, a, targets: Array) -> Array:
	var out := []
	for b in targets:
		if _melee_level(battle, b) == _melee_level(battle, a):
			out.append(b)
	return out

## The archer's mark: hostiles inside her zone (leash of the anchor),
## preferring the most EXPOSED — lowest LP fraction first, nearest
## breaks ties. No elevation gate: arrows fly.
static func _mark_in_zone(battle, a, targets: Array):
	var best = null
	var best_frac := 2.0
	var best_d := 1 << 30
	for b in targets:
		if Hex.distance(a.anchor, b.hex) > a.leash:
			continue
		var frac := float(b.lp) / float(maxi(1, b.max_lp))
		var d := Hex.distance(a.hex, b.hex)
		if frac < best_frac or (frac == best_frac and d < best_d):
			best_frac = frac
			best_d = d
			best = b
	return best

## Kite step: move to the free adjacent hex that puts the most ground
## between her and `threat` (ties prefer the anchor side). Returns
## false when no step increases the distance — she shoots instead.
static func _step_away(battle, a, threat) -> bool:
	var cur := Hex.distance(a.hex, threat.hex)
	var best_h = null
	var best_d := cur
	var best_anchor := 1 << 30
	for dir in Hex.DIRECTIONS:
		var h: Vector2i = a.hex + dir
		if not battle.hex_free(h):
			continue
		if battle.is_wall(h) != battle.is_wall(a.hex):
			continue
		var d := Hex.distance(h, threat.hex)
		var da := Hex.distance(h, a.anchor)
		if d > best_d or (d == best_d and da < best_anchor):
			best_d = d
			best_h = h
			best_anchor = da
	if best_h == null:
		return false
	_enter_hex(battle, a, best_h)
	return true

## Enter a hex: position, exertion, move event. Shared tail of the
## greedy step and the kite step.
static func _enter_hex(battle, a, h: Vector2i) -> void:
	var from: Vector2i = a.hex
	a.hex = h
	a.exert = Cfg.MELEE.rest_delay   # movement is exertion
	battle.emit({type = "move", actor = a.id, from = from, to = h,
		dur = a.move_cd})   # presentation tween fills the step cadence

## The draw: spend the shot's exertion up front and park the arrow in
## the draw phase. The release — and its world position snapshot —
## happens when the timer empties, so a mark that moves mid-draw is
## aimed at where he IS at release, then the shot is committed.
static func _loose(battle, a, d) -> void:
	a.ap = maxi(0, a.ap - Cfg.MELEE.ap_attack)
	a.exert = Cfg.MELEE.rest_delay
	d.exert = Cfg.MELEE.rest_delay
	battle.arrow_seq += 1
	battle.arrows.append({
		id = battle.arrow_seq, shooter = a.id, target = d.id,
		from = a.hex, to = d.hex,
		phase = "draw", t = Cfg.BOW.draw_t, dur = 0.0})
	battle.emit({type = "bow_draw", actor = a.id, target = d.id,
		dur = Cfg.BOW.draw_t})

## Arrow clocks on the sim tick: draw -> release (aim point snapshots
## the target's CURRENT hex) -> flight -> impact resolution. A dead
## archer never releases; a released arrow always lands.
static func _tick_arrows(battle, dt: float) -> void:
	for i in range(battle.arrows.size() - 1, -1, -1):
		var ar: Dictionary = battle.arrows[i]
		ar.t = float(ar.t) - dt
		if ar.t > 0.0:
			continue
		if ar.phase == "draw":
			var sh = battle.actors.get(ar.shooter)
			var tgt = battle.actors.get(ar.target)
			if sh == null or not sh.alive:
				battle.arrows.remove_at(i)
				continue
			if tgt != null and tgt.alive:
				ar.to = tgt.hex
			ar.phase = "fly"
			ar.dur = maxf(0.08,
				Hex.distance(ar.from, ar.to) * Cfg.BOW.fly_per_hex)
			ar.t = ar.dur
			battle.emit({type = "arrow_release", arrow = ar.id,
				actor = ar.shooter, from = ar.from, to = ar.to,
				dur = ar.dur})
		else:
			battle.arrows.remove_at(i)
			_arrow_impact(battle, ar)

## The arrow reaches its hex: any living hostile of the shooter on
## that hex takes the hit through the SAME physical pipeline a melee
## strike uses (attack check -> active defense -> pierce packet ->
## armor -> XP -> death/loot). Empty hex = a real miss — no faked
## instant damage.
static func _arrow_impact(battle, ar: Dictionary) -> void:
	var sh = battle.actors.get(ar.shooter)
	var victim = null
	if sh != null:
		for id in battle.actor_order:
			var b = battle.actors[id]
			if b.alive and b.hex == ar.to and b.faction != sh.faction:
				victim = b
				break
	if victim == null:
		battle.emit({type = "arrow_miss", arrow = ar.id,
			shooter = ar.shooter, hex = ar.to})
		return
	_resolve_hit(battle, sh, victim, true, int(ar.id))

## One melee strike — the physical combat pipeline (README, Combat 0.3):
##   ATTACK CHECK: d20 + effective Attack vs the flat attack
##     threshold (MELEE.attack_dc_base). Natural 20 always hits
##     (CRITICAL); natural 1 is a CRITICAL MISS and always misses.
##   -> ACTIVE DEFENSE: exactly ONE defensive resolution — the
##     defender rolls d20 + effective Defense vs defense_dc, where
##     effective Defense = learned/authored defense + shield bonus
##     + mapped bonuses + temporary modifiers. There is no separate
##     static-defense DC stacked in front of it — the old
##     "10 + Defense" gate is superseded (README §5, Combat 0.3
##     defense correction). An EXHAUSTED (AP 0) defender still
##     attempts the defense.
##   -> natural 20 on the defense roll = CRITICAL DEFENSE: the
##     attack is fully avoided — 0 AP, 0 LP.
##   -> defense passed: full effective damage -> AP, 0 -> LP.
##   -> defense failed: effective damage -> AP AND -> LP before
##     armor (armor mitigates LP only).
##   -> weapon packet -> attack-crit x2 -> susceptibility -> armor
##   -> Contribution XP once on the meaningful damage (x2 on crit);
##      ordinary enemies never earn it.
static func _strike(battle, a, d) -> void:
	# EXHAUSTED (AP 0) does not disable offense (Playable Loop 0.4):
	# an exhausted fighter still strikes — the AP cost clamps at 0
	# rather than blocking the action, and AP never goes negative.
	a.ap = maxi(0, a.ap - Cfg.MELEE.ap_attack)
	a.exert = Cfg.MELEE.rest_delay   # striking is exertion
	d.exert = Cfg.MELEE.rest_delay   # being struck at is combat
		# pressure — an engaged defender is not resting (supersedes
		# the Foundations 0.2 "defense is free" carve-out, which
		# existed to break the exhaustion deadlock that
		# exhausted-still-fights now prevents structurally)
	_resolve_hit(battle, a, d, false, 0)

## Shared hit resolution — melee strikes and arrow impacts run the
## identical physical pipeline: attack check vs attack_dc_base ->
## ONE active defense roll -> weapon packet -> crit x2 -> armor ->
## LP/AP consequences -> Contribution XP -> death/loot. `ranged`
## marks the event so presentation plays the shot, not a swing;
## `arrow_id` ties the resolution to the arrow in flight.
static func _resolve_hit(battle, a, d, ranged: bool,
		arrow_id: int) -> void:
	var atk_mod: int = a.attack + a.progress.modifier("attack",
		battle.config)
	var chk: Dictionary = Checks.d20(battle.rng, atk_mod,
		Cfg.MELEE.attack_dc_base)
	var ev := {
		type = "strike",
		attacker = a.id,
		defender = d.id,
		check = chk,
		weapon = a.weapon,
		ranged = ranged,
		arrow = arrow_id,
		crit = chk.crit,        # natural 20 — always a hit
		fumble = chk.fumble,    # natural 1  — always a miss
		hit = chk.passed or chk.crit,
		defended = false,
		defense_crit = false,
	}
	if chk.fumble:
		ev.hit = false
		# critical-miss consequence hook — the fumble table is an
		# open design question; the payload reserves the slot
		ev.fumble_consequence = null
	if ev.hit:
		# the ONE active defensive resolution: learned/authored
		# Defense + shield bonus + progression modifiers. No AP
		# requirement — an EXHAUSTED defender still rolls
		# (Character Foundations 0.2: no flat exhausted penalty;
		# the defense is what keeps him standing).
		var def_mod: int = (d.defense + d.shield
			+ d.progress.modifier("defense", battle.config))
		var dchk: Dictionary = Checks.d20(
			battle.rng, def_mod, Cfg.MELEE.defense_dc)
		# CANONICAL (Foundations 0.2): a natural 1 on the Defense
		# roll is an automatic failure — symmetric with attack
		# fumbles; the normal failed-defense pipeline follows.
		if dchk.fumble:
			dchk.passed = false
		ev.defense_check = dchk
		ev.defense_crit = dchk.crit
		ev.defended = dchk.passed
		var pkt := Damage.roll_packet(battle, _weapon_spec(battle, a))
		if chk.crit:
			Damage.scale_packet(pkt, battle.config.CRITICALS.damage_mult)
		var eff: int = Damage.packet_total(d, pkt)
		var armor: int = Damage.armor_mitigation(d, pkt)
		# consequences per the canonical rule:
		#   critical defense -> 0 AP / 0 LP
		#   defended         -> eff AP / 0 LP   (full, never halved)
		#   landed           -> eff AP / (eff - armor) LP
		var lp_loss: int = (0 if ev.defended
			else maxi(0, eff - armor))
		var ap_shock: int = 0 if ev.defense_crit else eff
		var ap_before: int = d.ap
		d.ap = maxi(0, d.ap - ap_shock)
		d.apply_damage(lp_loss)
		# Aegis soak (Playable Party 0.5): the barrier ate LP before
		# the body did — report it, and announce when it breaks
		ev.aegis_absorbed = d.last_absorbed
		if d.last_absorbed > 0 and not d.effects.has("aegis"):
			battle.emit({type = "status_end", actor = d.id, fx = "aegis"})
		ev.packet = pkt
		ev.effective = eff
		ev.armor = armor
		ev.lp_loss = lp_loss
		ev.ap_loss = ap_before - d.ap
		ev.resolution = ("critical_defense" if ev.defense_crit
			else "defended" if ev.defended else "landed")
		ev.crit_consequence = null   # critical-injury table: open
		ev.lp = d.lp
		var xp_mult: int = (battle.config.CRITICALS.xp_mult
			if chk.crit else 1)
		var meaningful: int = 0 if ev.defense_crit else eff
		Progress.award(battle, a, meaningful * xp_mult,
			"contribution", {kind = "damage", target = d.id,
				crit = chk.crit})
	battle.emit(ev)
	if ev.hit and not ev.defended and not d.alive:
		battle.emit({type = "death", actor = d})
		if d.faction == "enemy":
			d.loot = Loot.roll(battle.rng, battle.config.LOOT)
			d.loot_available = true
			battle.emit({type = "loot", actor = d, loot = d.loot})
