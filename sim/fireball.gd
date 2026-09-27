extends RefCounted
## Fireball simulation: a real temporal event, not an instant resolver.
##
## cast_at()   -> GROUND-targeted entry point: aims at a battlefield
##                POSITION — any in-grid hex is legal (empty ground,
##                an ally's hex, an enemy's hex; friendly fire is
##                intentional).
## cast()      -> actor-targeted entry point: ENEMY-mode spells require
##                a living enemy; GROUND-mode spells accept any living
##                actor and aim at its current hex.
## Both launch the same projectile that advances through world space
## over ~1-2 s.
## update(dt)  -> moves the projectile; when impact is imminent, each living
##                ACTOR inside the danger region rolls Perception — actors
##                sharing the caster's faction get the canonical
##                friendly-source bonus (they heard the warning); those who
##                pass (and have AP) roll Dodge and may move to a safer hex
##                BEFORE impact; at arrival the blast damages actors by
##                their FINAL hex distance from the target.
##
## Everything produces events on battle.events; presentation drains them.

const Hex = preload("res://sim/hex.gd")
const Dice = preload("res://sim/dice.gd")
const Checks = preload("res://sim/checks.gd")
const Dodge = preload("res://sim/dodge.gd")
const Loot = preload("res://sim/loot.gd")
const Damage = preload("res://sim/damage.gd")
const Progress = preload("res://sim/progress.gd")
const Targeting = preload("res://sim/targeting.gd")

## Blast ring for a hex vs the target (0 = center). >aoe_radius = safe.
static func ring_of(spell: Dictionary, target: Vector2i, h: Vector2i) -> Variant:
	var d := Hex.distance(h, target)
	if d > spell.aoe_radius:
		return null
	return d

static func _in_danger(battle, actor, target: Vector2i, spell: Dictionary) -> bool:
	return actor.alive and ring_of(spell, target, actor.hex) != null

## Ground-targeted cast: aims spell_id at battlefield POSITION
## `target_hex` — any in-grid hex is legal. Returns true on success,
## false + reason on rejection. battle.fireball is the single
## in-flight projectile slot.
static func cast_at(battle, caster_id: String, target_hex: Vector2i,
		spell_id := "fireball") -> Array:
	var cfg: Dictionary = battle.config.SPELLS[spell_id]
	var caster = battle.actors[caster_id]
	assert(caster != null and caster.alive, "cast_at: bad caster")
	if battle.fireball != null:
		return [false, "busy"]
	if not Targeting.is_ground(cfg):
		return [false, "wrong_targeting"]
	if not battle.hex_in_grid(target_hex):
		return [false, "off_grid"]
	if Hex.distance(caster.hex, target_hex) > Targeting.range_of(caster, cfg):
		return [false, "out_of_range"]
	return _launch(battle, caster, target_hex, spell_id, cfg)

## Actor-targeted cast: resolves `target_id` by the spell's declared
## targeting mode — ENEMY spells still require a living enemy;
## GROUND spells accept any living actor and aim at its current hex
## (a fireball may now be aimed at the Warrior's hex). Returns
## true on success, false + reason on rejection.
static func cast(battle, caster_id: String, target_id: String,
		spell_id := "fireball") -> Array:
	var cfg: Dictionary = battle.config.SPELLS[spell_id]
	var caster = battle.actors[caster_id]
	assert(caster != null and caster.alive, "cast: bad caster")
	if battle.fireball != null:
		return [false, "busy"]
	var target = battle.actors.get(target_id)
	if target == null or not target.alive:
		return [false, "bad_target"]
	var mode := Targeting.mode_of(cfg)
	if mode == Targeting.ENEMY and target.faction != "enemy":
		return [false, "bad_target"]
	if mode != Targeting.ENEMY and mode != Targeting.GROUND:
		return [false, "wrong_targeting"]
	var target_hex: Vector2i = target.hex
	if not battle.hex_in_grid(target_hex):
		return [false, "off_grid"]
	if Hex.distance(caster.hex, target_hex) > Targeting.range_of(caster, cfg):
		return [false, "out_of_range"]
	return _launch(battle, caster, target_hex, spell_id, cfg)

## Shared tail of both entry points: a legitimate attempt — target
## resolved, on grid, in range — commits the MP, rolls the
## Spellcasting check and the shown damage dice, and starts flight
## toward `target_hex`.
static func _launch(battle, caster, target_hex: Vector2i,
		spell_id: String, cfg: Dictionary) -> Array:
	# MP — the spellcasting resource, separate from AP (physical
	# endurance). Every spell declares `mp_cost`; the pool must cover
	# it before the weave is even attempted. Non-spellcasters have
	# max_mp 0 and can never satisfy a cost. Validation failures
	# (busy/off-grid/out-of-range/insufficient MP) spend NOTHING —
	# no legitimate attempt occurred.
	var mp_cost: int = cfg.get("mp_cost", 0)
	if mp_cost > 0 and caster.mp < mp_cost:
		battle.emit({type = "mp_low", actor = caster.id,
			spell = spell_id, cost = mp_cost, mp = caster.mp})
		return [false, "not enough MP"]

	# CANONICAL (Resource Model 0.2): once a legitimate casting
	# attempt begins the MP cost is COMMITTED — spent before the
	# Spellcasting roll and kept on failure. The magical effort was
	# still made. MP can never go negative (validated above).
	caster.mp -= mp_cost
	caster.exert = battle.config.MELEE.rest_delay   # casting is exertion

	# SPELLCASTING CHECK (README §22, canonical):
	#   1d20 + effective Spellcasting >= cast_dc (20).
	# Success grants permission for the spell to be produced — the
	# physical projectile/zone then proceeds exactly as before.
	# Failure means the weave never forms: no projectile, and the
	# committed MP is NOT refunded.
	var eff: Dictionary = caster.progress.effective(
		"spellcasting", battle.config)
	var chk: Dictionary = Checks.d20(battle.rng, eff.total,
		battle.config.PROGRESSION.cast_dc)
	battle.emit({type = "spellcasting", caster = caster, spell = cfg,
		check = chk, learned = eff.learned, bonuses = eff.bonuses,
		effective = eff.total, mp_cost = mp_cost, mp = caster.mp})
	if not chk.passed:
		return [false, "cast_failed"]

	var size: float = battle.config.HEX_SIZE
	var squash: float = battle.config.HEX_SQUASH
	var fx := Hex.to_world(caster.hex, size, squash)
	var tx := Hex.to_world(target_hex, size, squash)
	var roll := Dice.roll(battle.rng, cfg.damage)

	var instant: bool = cfg.get("instant", false)
	battle.fireball = {
		spell = cfg,
		caster_id = caster.id,
		target = target_hex,
		from = fx,
		to = tx,
		# conjured spells (Blizzard) materialise at the target — no travel
		pos = tx if instant else fx,
		instant = instant,
		onset = cfg.get("onset", 0.0),   # gather time before it exists
		distance = fx.distance_to(tx),
		shown_roll = roll,
		cast_total = chk.total,   # resisted targets oppose this total
		perceived = {},     # actor id -> true once Perception resolved
		arrived = false,
	}
	battle.emit({ type = "cast", caster = caster, target = target_hex,
		spell = cfg, targeting = Targeting.mode_of(cfg),
		mp_cost = mp_cost, mp = caster.mp })
	battle.emit({ type = "roll", label = cfg.display_name, roll = roll })
	return [true]

## Perception -> optional Dodge for one actor in the danger region.
## `bonus`/`friendly_source` describe the friendly-source Perception
## bonus (0.5): allies of the caster heard the warning — it is ONLY
## a Perception bonus; Dodge DC, AP cost and blast damage are
## unchanged for them.
static func _resolve_perception(battle, a, spell: Dictionary,
		bonus: int, friendly_source: bool) -> void:
	battle.fireball.perceived[a.id] = true
	var check := Checks.d20(battle.rng, a.perception + bonus,
		spell.perception_dc)
	battle.emit({ type = "perception", actor = a, check = check,
		bonus = bonus, friendly_source = friendly_source })
	if not check.passed:
		return

	# EXHAUSTED does not disable the dodge (Playable Loop 0.4): a
	# perceiving actor dives whether or not the AP cost can be paid —
	# the cost clamps at 0, never goes negative.
	a.ap = maxi(0, a.ap - spell.dodge_ap_cost)
	a.exert = battle.config.MELEE.rest_delay   # dodging is exertion
	var dcheck := Checks.d20(battle.rng, a.dodge, spell.dodge_dc)
	if not dcheck.passed:
		battle.emit({ type = "dodge", actor = a, check = dcheck, moved = false })
		return
	var fb = battle.fireball
	var dest = Dodge.choose_hex(a.hex,
		func(h): return battle.hex_free(h),
		func(h):
			var r = ring_of(spell, fb.target, h)
			# expected damage: outside the blast = 0 (best), center = worst
			return (spell.aoe_radius - r + 1) if r != null else 0)
	var from: Vector2i = a.hex
	if dest != null:
		a.hex = dest
	battle.emit({ type = "dodge", actor = a, check = dcheck,
		moved = dest != null, from = from, to = dest })

static func _explode(battle) -> void:
	var fb = battle.fireball
	var spell: Dictionary = fb.spell
	battle.emit({ type = "explosion", target = fb.target })
	if spell.get("kind") == "storm":
		# Blizzard: no landing damage — deploy the persistent zone.
		# t starts at the tick period so the first pulse lands at once.
		battle.zones.append({ spell = spell, target = fb.target,
			left = spell.duration, t = spell.tick,
			cast_total = fb.cast_total, caster_id = fb.caster_id })
		battle.emit({ type = "zone", target = fb.target, spell = spell })
		fb.arrived = true
		battle.fireball = null
		return
	for id in battle.actor_order:
		var a = battle.actors[id]
		if a.alive:
			var ring = ring_of(spell, fb.target, a.hex)
			if ring != null:
				var packet := Damage.roll_packet(battle, spell.ring_damage[ring],
					spell.get("dmg_type", "physical"))
				# CANON (0.5): a ring may carry a minimum final damage
				# — Fireball's outer ring is 1d6-1 floored at 1, so
				# the blast edge still burns. Dice are preserved for
				# the log; only the total is lifted, flagged so the
				# chronicle can say "min 1".
				var floor_map: Dictionary = spell.get("ring_floor", {})
				if floor_map.has(ring):
					for t in packet:
						var f: int = int(floor_map[ring])
						if packet[t].total < f:
							packet[t].total = f
							packet[t].floored = f
				var before: int = a.lp
				var ap_before: int = a.ap
				if spell.get("ap_drain"):
					a.ap = maxi(0, a.ap - spell.ap_drain)
				# resisted damaging magic: Resistance check vs the
				# casting total -> LIGHT (half -> AP) or HEAVY
				# (full -> LP and AP)
				var res: Dictionary = Damage.apply_magical(
					battle, a, packet, fb.cast_total)
				battle.emit({ type = "damage", actor = a, ring = ring,
					components = packet,
					roll = Damage.merged_roll(packet),
					severity = res.severity,
					resist_check = res.check,
					lp_before = before, lp_after = a.lp,
					ap_before = ap_before, ap_after = a.ap })
				# Contribution XP: the meaningful damage result — a
				# heavy hit counts once (LP+AP is NOT double-counted),
				# a light hit counts its AP wound.
				Progress.award(battle, battle.actors[fb.caster_id],
					res.xp, "contribution",
					{kind = "damage", target = a.id,
						spell = spell.get("display_name", "")})
				if not res.died:
					battle.emit({ type = "hp", actor = a })
				else:
					battle.emit({ type = "death", actor = a })
					if a.faction == "enemy":
						a.loot = Loot.roll(battle.rng, battle.config.LOOT)
						a.loot_available = true
						battle.emit({ type = "loot", actor = a, loot = a.loot })
	fb.arrived = true
	battle.fireball = null

## Advance the projectile; trigger Perception for danger-region enemies once
## impact is close; explode on arrival. Call with scaled dt (0 when paused).
static func update(battle, dt: float) -> void:
	var fb = battle.fireball
	if fb == null or fb.arrived:
		return

	var remaining: float = fb.pos.distance_to(fb.to)
	# Conjured spells are already at the target — "time to impact" is the
	# remaining gather (onset), which doubles as the dodge window.
	var t_impact: float = fb.get("onset", 0.0) if fb.get("instant") \
		else remaining / fb.spell.speed

	if t_impact <= fb.spell.perceive_time:
		# every LIVING actor in the danger region may spot the incoming
		# blast (0.5): allies of the caster get the friendly-source
		# Perception bonus — they knew the weave was coming. A passed
		# ally still needs the Dodge; a failed ally is hit normally.
		var caster = battle.actors.get(fb.caster_id)
		var fbonus: int = battle.config.SPELL_REACTION \
			.friendly_source_perception_bonus
		for id in battle.actor_order:
			var a = battle.actors[id]
			if not a.alive or fb.perceived.has(a.id):
				continue
			if not _in_danger(battle, a, fb.target, fb.spell):
				continue
			var friendly: bool = caster != null \
				and a.faction == caster.faction
			_resolve_perception(battle, a, fb.spell,
				fbonus if friendly else 0, friendly)

	if fb.get("instant"):
		# No travel — count down the gather, then the effect lands.
		fb.onset -= dt
		if fb.onset <= 0.0:
			_explode(battle)
		return

	var step: float = fb.spell.speed * dt
	if step >= remaining:
		fb.pos = fb.to
		_explode(battle)
		return
	fb.pos += (fb.to - fb.pos).normalized() * step
