extends RefCounted
## Dice expressions: "NdS" or "NdS+M" / "NdS-M" (e.g. "3d6", "1d20+6").
## Individual die results are preserved for tabletop transparency.

## Roll an expression. rng is a RandomNumberGenerator.
## Returns {count, size, plus, dice:Array[int], total:int}
static func roll(rng, expr: String) -> Dictionary:
	var count := 1
	var size := 0
	var plus := 0
	var main := expr
	var sign_pos := main.find("+")
	if sign_pos == -1:
		sign_pos = main.find("-", 1)
	if sign_pos != -1:
		plus = int(main.substr(sign_pos))
		main = main.substr(0, sign_pos)
	var parts := main.split("d")
	if parts.size() == 2 and parts[1].is_valid_int():
		count = int(parts[0]) if parts[0] != "" else 1
		size = int(parts[1])
	assert(size > 0, "dice.roll: bad expression '%s'" % expr)
	var dice: Array[int] = []
	for i in count:
		dice.append(rng.randi_range(1, size))
	var total := plus
	for d in dice:
		total += d
	return { count = count, size = size, plus = plus, dice = dice, total = total }

## "3d6 -> [2,5,5] = 12"
static func describe(r: Dictionary) -> String:
	var expr := "%dd%d" % [r.count, r.size]
	if r.plus > 0:
		expr += "+%d" % r.plus
	elif r.plus < 0:
		expr += "%d" % r.plus
	return "%s -> [%s] = %d" % [expr, ", ".join(r.dice.map(func(d): return str(d))), r.total]
