extends RefCounted
## Teleport (gameplay pass 0.1): Althar repositions a friendly hero —
## the commander spell. Validation and the state change live here;
## presentation only renders events.
##
## One cast path covers REPOSITION (deployed hero -> new hex) and
## DEPLOY (reserve hero -> field, sets `deployed`). EXTRACT can later
## reuse the same entry point with a reserve-side destination.

const Hex = preload("res://sim/hex.gd")
const Cfg = preload("res://sim/config.gd")
const Targeting = preload("res://sim/targeting.gd")

## Friendly living actors Althar may relocate (everyone but himself).
static func valid_sources(battle, caster_id: String) -> Array:
	var out := []
	for id in battle.actor_order:
		var a = battle.actors[id]
		if a.alive and a.faction == "friendly" and a.id != caster_id:
			out.append(a.id)
	return out

## Free in-grid hexes within the spell's reach of the caster.
static func valid_dests(battle, caster) -> Array:
	var out := []
	for h in battle.valid.keys():
		if Hex.distance(caster.hex, h) <= Targeting.range_of(caster,
				Cfg.TELEPORT) \
				and battle.hex_free(h):
			out.append(h)
	return out

## Returns [ok, reason]. Deterministic: every check runs before the
## cast, so a valid command always executes and an invalid one costs
## nothing. A successful cast reassigns the hero's defensive anchor to
## the destination — teleport IS the "defend here" order.
static func cast(battle, caster_id: String, source_id: String,
		dest: Vector2i) -> Array:
	var t = Cfg.TELEPORT
	var c = battle.actors.get(caster_id)
	if c == null or not c.alive:
		return [false, "the caster is down"]
	var s = battle.actors.get(source_id)
	if s == null:
		return [false, "no such hero"]
	if not s.alive:
		return [false, "%s is down" % s.display_name]
	if s.faction != "friendly" or s.id == caster_id:
		return [false, "not a friendly hero"]
	if not battle.hex_in_grid(dest):
		return [false, "beyond the field"]
	if Hex.distance(c.hex, dest) > Targeting.range_of(c, t):
		return [false, "beyond his reach"]
	if not battle.hex_free(dest):
		return [false, "the hex is occupied"]
	# EXHAUSTED does not lock the command (Playable Loop 0.4): the
	# AP cost clamps at 0 rather than refusing the order.
	c.ap = maxi(0, c.ap - t.ap_cost)
	c.exert = Cfg.MELEE.rest_delay   # casting is exertion
	var from: Vector2i = s.hex
	s.hex = dest
	s.deployed = true
	s.participated = true   # entered the battlefield -> shares
	                        # Encounter XP (README §22)
	s.anchor = dest
	battle.emit({type = "teleport", actor = s.id, from = from,
		to = dest})
	return [true, "teleported"]
