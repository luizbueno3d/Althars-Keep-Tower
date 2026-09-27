extends RefCounted
## Primitive corpse loot for the benchmark.

## cfg: Config.LOOT. Returns {gold:int, item:String}
static func roll(rng, cfg: Dictionary) -> Dictionary:
	return {
		gold = rng.randi_range(cfg.gold_min, cfg.gold_max),
		item = cfg.items[rng.randi_range(0, cfg.items.size() - 1)],
	}
