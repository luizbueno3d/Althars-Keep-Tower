extends RefCounted
## Enemy archetypes -> individual actors.
##
##     ARCHETYPE + VARIANT + INDIVIDUAL ROLL + EQUIPMENT = ACTUAL ACTOR
##
## An archetype authors BASE stats. Every individual spawned from it gets
## a bounded, integer-rounded variation representing natural individual
## difference — rolled ONCE at spawn through the battle's seeded rng and
## fixed for that actor's life. Nothing is re-rolled mid-combat.
##
## Variation is OPT-IN per archetype via the `variation` key, defaulting
## to 0.0 (off), so scenarios that author flat actors — Althar's Keep's
## `sim/config.gd` — are completely unaffected.
##
## Only INNATE creature stats take the roll (pools, attributes,
## Perception). Equipment is DISCRETE: a sword is a sword, a shield is a
## shield. Do not scale gear from this — equipment quality would be a
## separate, explicit system.
##
## All results are INTEGERS. A base-10 Skeleton with variation 0.20
## spawns at 8, 9, 10, 11 or 12 max LP — never 10.4.
##
## Archetype must stay more important than the roll: a ±20% Skeleton is
## still a Skeleton and can never roll into being a Skeleton Warrior.
## Distinct tiers (Warrior / Archer / Mage) are their OWN archetypes.

const Dice = preload("res://sim/dice.gd")

## Innate keys that take the individual roll when the archetype has them.
const VARY_KEYS := ["lp", "ap", "perception"]

## Bounded integer variation of one base value.
##   vary_int(10, 0.20, rng) -> 8..12
##   vary_int(50, 0.20, rng) -> 40..60
static func vary_int(base: int, variation: float, rng) -> int:
	if variation <= 0.0 or base == 0:
		return base
	var f := absf(variation)
	var lo := int(round(float(base) * (1.0 - f)))
	var hi := int(round(float(base) * (1.0 + f)))
	if base > 0:
		lo = maxi(1, lo)
		hi = maxi(lo, hi)
	else:
		lo = mini(lo, hi)
		hi = maxi(lo, hi)
	return rng.randi_range(lo, hi)

## Derive a variant archetype from a base one. Used for tiers that share
## most of a creature's body but are their own archetype — never for
## "a normal Skeleton that rolled high".
static func variant(base: Dictionary, over: Dictionary) -> Dictionary:
	var d: Dictionary = base.duplicate(true)
	for k in over:
		d[k] = over[k]
	return d

## Build ONE individual actor dict from an archetype.
## `id`, `hex` and `name` override whatever the archetype carries, so a
## single archetype can produce a whole group of named individuals.
static func spawn(archetype: Dictionary, rng, id: String,
		hex: Vector2i, name := "") -> Dictionary:
	var d: Dictionary = archetype.duplicate(true)
	d.id = id
	d.hex = hex
	if name != "":
		d.display_name = name
	var v: float = float(archetype.get("variation", 0.0))
	if v > 0.0:
		for k in VARY_KEYS:
			if d.has(k):
				d[k] = vary_int(int(d[k]), v, rng)
		if archetype.has("attributes"):
			var attrs: Dictionary = archetype.attributes.duplicate()
			for a in attrs:
				attrs[a] = vary_int(int(attrs[a]), v, rng)
			d.attributes = attrs
	return d

## Expand a wave composition into actor dicts.
##   composition: {archetype_id -> count},  archetypes: the table
##   hexes: the spawn hexes, consumed in order
## Names individuals "Skeleton A", "Skeleton B", ... within each
## archetype, and suffixes the id so two archetypes never collide.
static func build_wave(archetypes: Dictionary, composition: Dictionary,
		rng, hexes: Array, wave := 1) -> Array:
	var out: Array = []
	var letters := "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	for aid in composition:
		if not archetypes.has(aid):
			continue
		var base: Dictionary = archetypes[aid]
		var n: int = int(composition[aid])
		for i in n:
			var hex: Vector2i = hexes[out.size() % hexes.size()] \
				if not hexes.is_empty() else Vector2i.ZERO
			var label: String = base.get("display_name", aid)
			var nm := "%s %s" % [label, letters[i % letters.length()]] \
				if n > 1 else label
			out.append(spawn(base, rng,
				"%s_w%d_%d" % [aid, wave, i], hex, nm))
	return out
