extends RefCounted
## Market rules — the peddler's ledger. Pure sim: no Node APIs, and
## no rolls (prices are deterministic; there is nothing to roll).
##
## An item's `value` (ITEMS[].value) is its honest gold worth.
## Buying costs full value; selling pays floor(value *
## MARKET.sell_ratio) — the peddler's margin is the missing half.
## What the market SELLS is scenario data: `cfg.MARKET_STOCK`, an
## Array of item names. A scenario without one (Althar's Keep
## today) has no stock — buy refuses everything, sell still works.

const Items = preload("res://sim/items.gd")

## Item names the market offers; absent/empty -> no stock at all.
static func stock(cfg) -> Array:
	var s = cfg.get("MARKET_STOCK")
	return s if s is Array else []

## Buy one unit of `name` from the market's stock. Full validation
## before a coin moves. Returns [true] or [false, reason].
static func buy(battle, name: String) -> Array:
	if not Items.known(battle.config, name):
		return [false, "unknown item"]
	if not (name in stock(battle.config)):
		return [false, "not stocked"]
	var price := Items.value_of(battle.config, name)
	if battle.inventory.gold < price:
		return [false, "cannot afford"]
	battle.inventory.gold -= price
	Items.add(battle.inventory, name, 1)
	battle.emit({type = "market_buy", item = name,
		gold = battle.inventory.gold})
	return [true]

## What the peddler pays for `name`: floor(value * sell_ratio).
static func sell_price(cfg, name: String) -> int:
	var m = cfg.get("MARKET")
	var ratio := 0.5
	if m is Dictionary:
		ratio = float(m.get("sell_ratio", 0.5))
	return int(floor(float(Items.value_of(cfg, name)) * ratio))

## Sell one unit of `name` out of the pack. A unit that is WORN is
## not in the pack — gear must be unequipped before it can be sold.
## Returns [true] or [false, reason].
static func sell(battle, name: String) -> Array:
	if Items.count(battle.inventory, name) <= 0:
		return [false, "none held"]
	Items.take_one(battle.inventory, name)
	if Items.count(battle.inventory, name) <= 0:
		# the last unit is gone — belt slots naming it clear, same
		# as a consumed stack
		Items._prune_belts(battle, name)
	battle.inventory.gold += sell_price(battle.config, name)
	battle.emit({type = "market_sell", item = name,
		gold = battle.inventory.gold})
	return [true]
