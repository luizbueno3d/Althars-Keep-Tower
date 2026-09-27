extends RefCounted
## Damage packets: a hit is typed components {type: Dice roll}, never a
## bare LP number. Fireball is mostly "fire", Meteor is "impact" major
## + "fire" secondary, Lightning is "electrical", Blizzard ticks "cold".
## Creatures (and later terrain/structures) can answer each type
## differently via the actor's resist table — currently empty, meaning
## x1.0: the socket exists, no resistance system is installed yet.
##
## spec forms in config:  "3d6"                    -> {dmg_type: roll}
##                        {impact="4d6", fire="2d6"} -> rolled per component

const Dice = preload("res://sim/dice.gd")
const Checks = preload("res://sim/checks.gd")

static func roll_packet(battle, spec, default_type := "physical") -> Dictionary:
	var out := {}
	if spec is String:
		out[default_type] = Dice.roll(battle.rng, spec)
	elif spec is Dictionary:
		for t in spec:
			out[t] = Dice.roll(battle.rng, spec[t])
	return out

static func merged_roll(packet: Dictionary) -> Dictionary:
	## Compatibility view: a single pseudo-roll for logs, the dice
	## panel and existing tests. Single-component packets pass through.
	if packet.size() == 1:
		return packet.values()[0]
	var dice := []
	var total := 0
	for t in packet:
		dice.append_array(packet[t].dice)
		total += packet[t].total
	return { count = dice.size(), size = 6, dice = dice, total = total }

## Effective damage of a packet against an actor: each component
## folded through the typed resist table. This is the pre-clamp
## number — overkill still counts its full value for Contribution XP
## (README §22).
static func packet_total(actor, packet: Dictionary) -> int:
	var total := 0
	for t in packet:
		var m: float = actor.resist.get(t, 1.0)
		total += int(round(packet[t].total * m))
	return total

## Fold each component through the actor's resist table, then apply.
## Returns true if the hit killed the actor.
static func apply(_battle, actor, packet: Dictionary) -> bool:
	return actor.apply_damage(packet_total(actor, packet))

## Multiply every component's rolled total (critical hits). The
## original dice are preserved in the payload for display.
static func scale_packet(packet: Dictionary, mult: int) -> void:
	for t in packet:
		packet[t].total *= mult

## ARMOR (README §22 — Combat 0.3): armor primarily protects bodily
## injury — it mitigates the LP path only, never the AP shock.
## Data form: {lp = flat, types = {dmg_type: extra}} — e.g. plate
## caring more about slashes than impact is a future table, not
## invented here.
static func armor_mitigation(actor, packet: Dictionary) -> int:
	var m: int = actor.armor.get("lp", 0)
	var types: Dictionary = actor.armor.get("types", {})
	for t in packet:
		m += types.get(t, 0)
	return m

## RESISTED DAMAGING MAGIC (README §22): the target's Resistance check
## opposes the successful casting total.
##   - pass  -> LIGHT effect:  half effective damage -> AP, 0 -> LP
##   - fail  -> HEAVY effect:  full effective damage -> LP AND AP
## The tie rule (`resist_tie`) and halving rule (`light_rounding`)
## are configured — both are provisional until frozen by design.
## Returns the full resolution payload for events and XP accounting:
## {check, severity, effective, lp_loss, ap_loss, xp, died}.
## `xp` is the meaningful contribution number: a heavy hit counts its
## LP+AP injury once (not doubled); a light hit counts the AP wound.
static func apply_magical(battle, actor, packet: Dictionary,
		cast_total: int) -> Dictionary:
	var prog: Dictionary = battle.config.PROGRESSION
	var eff: int = packet_total(actor, packet)
	var res_mod := 0
	if actor.progress != null:
		res_mod = actor.progress.effective("resistance",
			battle.config).total
	# tie goes to the configured side: "caster" needs the defender to
	# beat the casting total outright; "defender" lets equality pass
	var dc: int = cast_total + (1 if prog.resist_tie == "caster" else 0)
	var chk: Dictionary = Checks.d20(battle.rng, res_mod, dc)
	var light: bool = chk.passed
	var half: int = (eff / 2 if prog.light_rounding == "floor"
		else int(ceil(eff / 2.0)))
	var lp_loss: int = 0 if light else eff
	var ap_loss: int = half if light else eff
	actor.ap = maxi(0, actor.ap - ap_loss)
	var died: bool = actor.apply_damage(lp_loss)
	return {
		check = chk,
		severity = "light" if light else "heavy",
		effective = eff,
		lp_loss = lp_loss,
		ap_loss = ap_loss,
		xp = half if light else eff,
		died = died,
	}
