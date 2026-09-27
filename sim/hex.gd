extends RefCounted
## Axial-coordinate hex math (pointy-top layout, squashed Y for isometry).
## All functions are static; hexes are Vector2i(q, r).

# Six neighbor directions in fixed order (used for deterministic tiebreaks).
const DIRECTIONS := [
	Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1),
]

static func neighbor(h: Vector2i, dir: int) -> Vector2i:
	return h + DIRECTIONS[dir % 6]

static func distance(a: Vector2i, b: Vector2i) -> int:
	var d := a - b
	return int((abs(d.x) + abs(d.y) + abs(d.x + d.y)) / 2)

## All hexes exactly `radius` steps from center (6*radius of them).
static func ring(center: Vector2i, radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if radius == 0:
		out.append(center)
		return out
	var h := center + DIRECTIONS[4] * radius
	for i in 6:
		for j in radius:
			out.append(h)
			h = neighbor(h, i)
	return out

## All hexes within `radius` of center inclusive.
static func range(center: Vector2i, radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for q in range(-radius, radius + 1):
		for r in range(maxi(-radius, -q - radius), mini(radius, -q + radius) + 1):
			out.append(center + Vector2i(q, r))
	return out

## Axial -> world position (px). Pointy-top with squashed Y.
static func to_world(h: Vector2i, size: float, squash: float) -> Vector2:
	return Vector2(
		size * sqrt(3.0) * (h.x + h.y * 0.5),
		size * 1.5 * h.y * squash)

## World position -> nearest axial hex (cube rounding).
static func to_coord(x: float, y: float, size: float, squash: float) -> Vector2i:
	var rf := y / (size * 1.5 * squash)
	var qf := x / (size * sqrt(3.0)) - rf * 0.5
	var sf := -qf - rf
	var qi := roundi(qf)
	var ri := roundi(rf)
	var si := roundi(sf)
	var dq := absf(qi - qf)
	var dr := absf(ri - rf)
	var ds := absi(si) - absf(sf)
	if dq > dr and dq > absf(si - sf):
		qi = -ri - si
	elif dr > absf(si - sf):
		ri = -qi - si
	return Vector2i(qi, ri)
