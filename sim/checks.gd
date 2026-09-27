extends RefCounted
## Ability checks: 1d20 + modifier vs DC. Full calculation is preserved.

## Returns {die, modifier, total, dc, passed, crit, fumble}.
## `crit`/`fumble` expose the RAW natural die (20 / 1) independently
## of the modified total — each check type (attack, block, cast,
## resistance) decides what a natural means for it (README §22+).
static func d20(rng, modifier: int, dc: int) -> Dictionary:
	var die: int = rng.randi_range(1, 20)
	var total: int = die + modifier
	return { die = die, modifier = modifier, total = total, dc = dc,
		passed = total >= dc, crit = die == 20, fumble = die == 1 }

## "1d20(19) + 3 = 22  DC 14  PASS"
static func describe(c: Dictionary) -> String:
	return "1d20(%d) + %d = %d  DC %d  %s" % [
		c.die, c.modifier, c.total, c.dc, "PASS" if c.passed else "FAIL"]
