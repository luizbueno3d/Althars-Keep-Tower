extends RefCounted
## Blizzard simulation: the persistent half of the storm spell.
##
## cast() goes through sim/fireball.gd but with instant=true the storm
## is CONJURED at the target area after a short onset — it is never a
## travelling projectile. On landing a zone joins battle.zones. update()
## then pulses each zone: every living enemy inside takes cold damage
## and loses AP — the storm is a place to escape, not a hit to dodge.
##
## Each tick also accumulates "cold" exposure in actor.effects. Nothing
## consumes it yet; it is the socket for the future Frozen threshold.
##
## Emits standard damage/death/loot events plus zone/zone_end markers so
## presentation can show and remove the storm.

const Hex = preload("res://sim/hex.gd")
const Dice = preload("res://sim/dice.gd")
const Loot = preload("res://sim/loot.gd")
const Damage = preload("res://sim/damage.gd")
const Progress = preload("res://sim/progress.gd")

static func update(battle, dt: float) -> void:
	for i in range(battle.zones.size() - 1, -1, -1):
		var z = battle.zones[i]
		z.left -= dt
		z.t += dt
		if z.t >= z.spell.tick:
			z.t -= z.spell.tick
			_tick(battle, z)
		if z.left <= 0.0:
			battle.emit({ type = "zone_end", target = z.target })
			battle.zones.remove_at(i)

static func _tick(battle, z) -> void:
	for id in battle.actor_order:
		var a = battle.actors[id]
		if not a.alive:
			continue
		if Hex.distance(a.hex, z.target) > z.spell.aoe_radius:
			continue
		a.ap = maxi(0, a.ap - z.spell.ap_drain)
		a.effects["cold"] = a.effects.get("cold", 0) + 1
		var packet := Damage.roll_packet(battle, z.spell.tick_damage, "cold")
		var before: int = a.lp
		var ap_before: int = a.ap
		# storm damage is resisted magic too: the victim's Resistance
		# opposes the original casting total each tick
		var res: Dictionary = Damage.apply_magical(
			battle, a, packet, z.get("cast_total", 0))
		battle.emit({ type = "damage", actor = a, ring = -1,
			zone = true, components = packet,
			roll = Damage.merged_roll(packet),
			severity = res.severity,
			resist_check = res.check,
			lp_before = before, lp_after = a.lp,
			ap_before = ap_before, ap_after = a.ap })
		var caster = battle.actors.get(z.get("caster_id", ""))
		if caster != null:
			Progress.award(battle, caster, res.xp, "contribution",
			{kind = "damage", target = a.id,
				spell = z.spell.get("display_name", "")})
		if not res.died:
			battle.emit({ type = "hp", actor = a })
		else:
			battle.emit({ type = "death", actor = a })
			if a.faction == "enemy":
				a.loot = Loot.roll(battle.rng, battle.config.LOOT)
				a.loot_available = true
				battle.emit({ type = "loot", actor = a, loot = a.loot })
