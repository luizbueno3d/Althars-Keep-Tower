extends RefCounted
## Dodge destination selection: the deliberately simple deterministic AI.
## Picks the free adjacent hex with the lowest expected damage; only moves
## if strictly safer. Ties broken by the fixed order of Hex.DIRECTIONS.

const Hex = preload("res://sim/hex.gd")

## is_free: Callable(Vector2i) -> bool
## expected_damage: Callable(Vector2i) -> int   (LOWER is safer)
## Returns Vector2i destination, or null when no strictly-safer neighbor.
static func choose_hex(from: Vector2i, is_free: Callable,
		expected_damage: Callable) -> Variant:
	var current: int = expected_damage.call(from)
	var best: Variant = null
	var best_dmg := current
	for i in 6:
		var cand := Hex.neighbor(from, i)
		if is_free.call(cand):
			var d: int = expected_damage.call(cand)
			if d < best_dmg:
				best = cand
				best_dmg = d
	return best
