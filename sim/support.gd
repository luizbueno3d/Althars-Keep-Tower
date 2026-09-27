extends RefCounted
## Healer spell kit 0.1 (Playable Party 0.5): four actor-targeted
## support workings — HEAL, RESURRECTION, HASTE, AEGIS.
##
## They follow the same canonical casting contract as the damage kit:
## a legitimate attempt COMMITS the MP cost before the Spellcasting
## check (1d20 + effective >= cast_dc) decides whether the weave
## forms; a failed roll keeps the MP and starts NO cooldown. Spells
## draw on MP — the arcane pool — not AP; an `ap_cost` row exists in
## config but every support spell sets it to 0 (CANON 0.5).
##
## Cooldowns count ACTIVE GAMEPLAY seconds: Combat.update ticks them
## only inside the live sim loop, so pause / save / quit / modal
## freezes can never advance or reset the clock. Resurrection's
## 20-minute cooldown starts on a SUCCESSFUL cast only.
##
## Pure sim: no Node APIs; all rolls through battle.rng.

const Hex = preload("res://sim/hex.gd")
const Checks = preload("res://sim/checks.gd")
const Progress = preload("res://sim/progress.gd")
const Targeting = preload("res://sim/targeting.gd")

## Spell ids this path owns (config blocks live in Cfg.SPELLS).
const KIT := ["heal", "resurrect", "haste", "aegis"]

static func is_support(spell_id: String) -> bool:
	return spell_id in KIT

## Actor ids the spell may target right now, in stable actor_order.
## "ally_alive" = living deployed friendly heroes (the caster may
## work on himself); "ally_dead" = ANY friendly corpse whose state
## still exists — the reserve flag does not matter to a corpse: he
## fell on the field and lies where he fell (a saved dead reserve
## must still be raisable).
static func valid_targets(battle, caster_id: String,
		spell_id: String) -> Array:
	var spec: Dictionary = battle.config.SPELLS[spell_id]
	var want_dead: bool = spec.get("target") == "ally_dead"
	var out := []
	for id in battle.actor_order:
		var a = battle.actors[id]
		if a.faction != "friendly":
			continue
		if id == caster_id and want_dead:
			continue
		if want_dead:
			if not a.alive and battle.hex_in_grid(a.hex):
				out.append(id)
		elif a.alive and a.deployed:
			out.append(id)
	return out

## Remaining active-play cooldown for `spell_id` on `caster`
## (0 when ready). Resurrection owns resur_cd; Heal owns heal_cd;
## Haste/Aegis have no cooldown fields — recast refreshes the effect.
static func cd_left(caster, spell_id: String) -> float:
	match spell_id:
		"heal":      return caster.heal_cd
		"resurrect": return caster.resur_cd
	return 0.0

## Cast a support spell at actor `target_id`. Returns [true] on a
## successful weave, [false, reason, ...] otherwise — mirroring
## Fireball.cast's contract. Reasons: bad_caster, bad_target,
## out_of_range, cooldown(+seconds), "not enough MP", cast_failed,
## no_room (resurrection found nowhere to stand the returned hero).
static func cast(battle, caster_id: String, spell_id: String,
		target_id: String) -> Array:
	var spec: Dictionary = battle.config.SPELLS[spell_id]
	var caster = battle.actors.get(caster_id)
	var target = battle.actors.get(target_id)
	if caster == null or not caster.alive or not caster.has_mp() \
			or spell_id not in caster.spells:
		return [false, "bad_caster"]
	if target == null or target.faction != "friendly" \
			or target_id not in valid_targets(battle, caster_id,
				spell_id):
		return [false, "bad_target"]
	if Hex.distance(caster.hex, target.hex) \
			> Targeting.range_of(caster, spec):
		return [false, "out_of_range"]

	var left := cd_left(caster, spell_id)
	if left > 0.0:
		return [false, "cooldown", left]

	# Resurrection needs somewhere for the returned hero to stand —
	# check BEFORE committing MP so an impossible raise never costs.
	var revive_hex: Variant = null
	if spell_id == "resurrect":
		revive_hex = _nearest_free(battle, target.hex)
		if revive_hex == null:
			return [false, "no_room"]

	var mp_cost: int = spec.get("mp_cost", 0)
	if mp_cost > 0 and caster.mp < mp_cost:
		battle.emit({type = "mp_low", actor = caster.id,
			spell = spell_id, cost = mp_cost, mp = caster.mp})
		return [false, "not enough MP"]

	# Commit resources — the effort was genuinely made.
	caster.mp -= mp_cost
	caster.ap = maxi(0, caster.ap - int(spec.get("ap_cost", 0)))
	caster.exert = battle.config.MELEE.rest_delay   # casting is exertion

	# Canonical Spellcasting check — same d20 + effective vs cast_dc
	# as the damage kit. MP stays spent on failure; cooldowns do NOT
	# start on failure (the working never happened).
	var eff: Dictionary = caster.progress.effective(
		"spellcasting", battle.config)
	var chk: Dictionary = Checks.d20(battle.rng, eff.total,
		battle.config.PROGRESSION.cast_dc)
	battle.emit({type = "spellcasting", caster = caster, spell = spec,
		check = chk, learned = eff.learned, bonuses = eff.bonuses,
		effective = eff.total, mp_cost = mp_cost, mp = caster.mp})
	if not chk.passed:
		return [false, "cast_failed"]

	battle.emit({type = "support_cast", caster = caster,
		target = target, spell = spec})
	match spell_id:
		"heal":
			var r: Dictionary = target.heal(int(spec.heal))
			caster.heal_cd = float(spec.cooldown)
			battle.emit({type = "heal", caster = caster,
				target = target, lp = r.lp, ap = r.ap})
			# Contribution XP: 1 per actual LP restored — never for
			# overheal, never for AP (canon).
			Progress.award(battle, caster, r.lp, "contribution",
				{kind = "healing", target = target.id})
		"resurrect":
			caster.resur_cd = float(spec.cooldown)   # 20 min — success only
			target.hex = revive_hex
			target.alive = true
			target.deployed = true    # he stands on the field again
			target.lp = int(spec.revive_lp)          # FROZEN: exactly 1
			target.ap = 0                            # FROZEN: spent
			# MP is whatever the hero died with — no free energy.
			target.exert = 0.0
			target.regen_t = 0.0
			target.mp_regen_t = 0.0
			target.effects = {}          # a fresh return, no old status
			target.focus_id = ""
			target.exh_announced = false # 0 AP -> exhausted warning re-arms
			target.crit_announced = false # 1 LP -> critical warning re-arms
			target.cd = 1.0              # a breath before acting again
			battle.emit({type = "resurrect", caster = caster,
				target = target})
		"haste":
			target.effects["haste"] = {t = float(spec.duration),
				mult = float(spec.cadence)}
			battle.emit({type = "status_start", actor = target,
				fx = "haste", caster = caster})
		"aegis":
			target.effects["aegis"] = {t = float(spec.duration),
				pool = int(spec.pool)}
			battle.emit({type = "status_start", actor = target,
				fx = "aegis", caster = caster})
	return [true]

## The corpse hex if free, else the nearest free hex within 3 rings
## (deterministic: lowest distance wins, scan order settles ties).
static func _nearest_free(battle, c: Vector2i) -> Variant:
	var best: Variant = null
	var bd := 99
	for h in Hex.range(c, 3):
		if battle.hex_free(h):
			var d := Hex.distance(c, h)
			if d < bd:
				bd = d
				best = h
	return best
