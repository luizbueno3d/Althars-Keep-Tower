extends RefCounted
## Central benchmark tuning. All gameplay values live here.
const Hex = preload("res://sim/hex.gd")
## MANUAL OWNERSHIP TEST VALUES:
##   - Fireball projectile speed -> FIREBALL.speed (below)
##   - Fireball visual color     -> FIREBALL.color (below)
##   - Skeleton A Perception     -> ACTORS[1].perception (below)

const SEED := 12345

# Axial hex grid — Hex Field Expansion: radius 30 around an
# east-shifted centre gives a ~150 x 80 m field (~2800 cells) —
# the keep occupies the west third, the open field reaches deep
# east so enemies are SEEN coming. Hex size is unchanged.
const GRID_CENTER := Vector2i(4, 0)
const GRID_RADIUS := 30
const HEX_SIZE := 48.0      # center -> corner, world px (x0.03 = 1.44 m)
const HEX_SQUASH := 0.62    # vertical squash for the isometric look
const WORLD_SCALE := 0.03   # sim px -> world metres (shared with battle3d)

# Actors. INITIAL PLAYTEST VALUES — melee fields are first-pass numbers,
# not balance. `ai`: "" inert · "advance" enemies close and strike ·
# "defend"/"brawl" heroes engage enemies inside `engage` hexes (reserve
# heroes only strike adjacent enemies until deployed).
const ACTORS := [
	{
		id = "wizard", display_name = "Wizard", faction = "friendly",
		# CANONICAL Level-1 pools (Resource Model 0.2): not a
		# frontline body (12 LP), less physical endurance than the
		# martial heroes (16 AP), a deep magical reserve (20 MP —
		# spellcasters normally run MP > AP). Authored, not derived.
		lp = 12, ap = 16, mp = 20, perception = 0, dodge = 0,
		defense = 3,
		# CANONICAL Level-1 attributes (Character Foundations 0.2):
		# near-mortal Magic, exceptional mind and command presence,
		# honest physical floor — a commander, not a body.
		attributes = {str = 45, dex = 65, agi = 55, con = 55,
			int = 92, cha = 80, mag = 96},
		# CANON baseline: a competent Level-1 spellcaster's learned
		# Spellcasting is +10 (README §22). The "magic" bonus pool
		# feeds from MAG via the Table M bands below (+3 at MAG 96).
		learned = {spellcasting = 10},
		hex = Vector2i(-4, 1),
		# he stands on the battlement — out of melee reach even though
		# his sim hex sits on a field cell at the wall base
		elevated = true,
	},
	# Character 02 — the Warrior: disciplined frontline holding the gate
	# approach (hex ~(-3,1) sits in front of the wall entrance). High
	# defense + the shield-block reaction; tight leash — he intercepts
	# what enters his zone and returns to his anchor.
	{
		id = "warrior", display_name = "Warrior", faction = "friendly",
		lp = 16, ap = 14, perception = 2, dodge = 1,
		# CANONICAL Level-1 attributes (Character Foundations 0.2):
		# peaks at AGI/CON — the reflexive, enduring defender.
		attributes = {str = 75, dex = 78, agi = 85, con = 88,
			int = 60, cha = 65, mag = 10},
		attack = 5, defense = 6, shield = 7, weapon = "sword",
		attack_range = 1, ai = "defend", leash = 4,
		act_cd = 1.8, move_cd = 1.3,
		hex = Vector2i(-3, 1),
	},
	# Character 03 — the Barbarian: aggressive local interception at the
	# muster point beside the gate. Wider leash than the Warrior — he
	# pushes forward inside his responsibility but still holds an area.
	{
		id = "barbarian", display_name = "Barbarian", faction = "friendly",
		lp = 15, ap = 12, perception = 3, dodge = 2,
		# CANONICAL Level-1 attributes (Character Foundations 0.2):
		# near-mortal STR — the offensive breaker.
		attributes = {str = 93, dex = 70, agi = 65, con = 82,
			int = 45, cha = 55, mag = 5},
		attack = 7, defense = 3, block = 0, weapon = "axe",
		attack_range = 1, ai = "brawl", leash = 6,
		act_cd = 1.7, move_cd = 1.2,
		deployed = false,
		hex = Vector2i(-3, 3),
	},
	# Character 04 — the Archer: human ranged specialist holding a
	# firing lane behind the frontline (docs/characters/04_archer).
	# She does not brawl: ai "shoot" looses real arrows (draw ->
	# release -> flight -> pierce impact) and kites contact rather
	# than closing. Wide leash — her zone is a field of fire.
	# Attributes/learned values are AUTHORED Level-1 integration
	# values, not rolled and not yet balanced.
	{
		id = "archer", display_name = "Archer", faction = "friendly",
		lp = 12, ap = 16, perception = 5, dodge = 3,
		attributes = {str = 55, dex = 92, agi = 88, con = 65,
			int = 72, cha = 70, mag = 10},
		learned = {attack = 10, defense = 8, resistance = 6},
		weapon = "bow", attack_range = 8, ai = "shoot", leash = 8,
		act_cd = 2.6, move_cd = 1.0,
		hex = Vector2i(-4, 3),
	},
	# Character 05 — the Healer (Playable Party 0.5): arcane support
	# mage, autonomous triage behind the frontline (docs/characters/
	# 05_healer/CARD.md). Deep MP reserve like Althar's; modest body —
	# he preserves the party rather than breaking enemies himself.
	# Pools/attributes are authored PROVISIONAL Level-1 values pending
	# the production card's numeric pass.
	{
		id = "healer", display_name = "Healer", faction = "friendly",
		lp = 13, ap = 15, mp = 22, perception = 3, dodge = 2,
		attributes = {str = 55, dex = 68, agi = 62, con = 70,
			int = 84, cha = 78, mag = 88},
		learned = {spellcasting = 9},
		# his kit — Support.cast only works spells the caster owns
		spells = ["heal", "resurrect", "haste", "aegis"],
		attack = 2, defense = 4, weapon = "1d4",
		attack_range = 1, ai = "mend", leash = 5,
		act_cd = 2.0, move_cd = 1.2,
		hex = Vector2i(-4, 4),
	},
	{
		id = "skeleton_a", display_name = "Skeleton A", faction = "enemy",
		lp = 8, ap = 8, perception = 3, dodge = 2,
		attack = 10, attack_var = "1d5-1", defense = 2, weapon = "claws",
		attack_range = 1, ai = "advance", act_cd = 2.4, move_cd = 1.5,
		hex = Vector2i(18, 0),
	},
	{
		id = "skeleton_b", display_name = "Skeleton B", faction = "enemy",
		lp = 8, ap = 8, perception = 6, dodge = 4,
		attack = 10, attack_var = "1d5-1", defense = 2, weapon = "claws",
		attack_range = 1, ai = "advance", act_cd = 2.4, move_cd = 1.5,
		hex = Vector2i(20, -3),
	},
	{
		id = "skeleton_c", display_name = "Skeleton C", faction = "enemy",
		lp = 8, ap = 8, perception = 9, dodge = 6,
		attack = 10, attack_var = "1d5-1", defense = 2, weapon = "claws",
		attack_range = 1, ai = "advance", act_cd = 2.4, move_cd = 1.5,
		hex = Vector2i(21, 2),
	},
	# Benchmark 0.2: more bodies for the visual battlefield.
	{
		id = "skeleton_d", display_name = "Skeleton D", faction = "enemy",
		lp = 8, ap = 8, perception = 4, dodge = 3,
		attack = 10, attack_var = "1d5-1", defense = 2, weapon = "claws",
		attack_range = 1, ai = "advance", act_cd = 2.4, move_cd = 1.5,
		hex = Vector2i(23, -2),
	},
	{
		id = "skeleton_e", display_name = "Skeleton E", faction = "enemy",
		lp = 8, ap = 8, perception = 7, dodge = 5,
		attack = 10, attack_var = "1d5-1", defense = 2, weapon = "claws",
		attack_range = 1, ai = "advance", act_cd = 2.4, move_cd = 1.5,
		hex = Vector2i(19, -5),
	},
	{
		id = "skeleton_f", display_name = "Skeleton F", faction = "enemy",
		lp = 8, ap = 8, perception = 5, dodge = 4,
		attack = 10, attack_var = "1d5-1", defense = 2, weapon = "claws",
		attack_range = 1, ai = "advance", act_cd = 2.4, move_cd = 1.5,
		hex = Vector2i(22, 3),
	},
]

## Melee resolution (sim/combat.gd). INITIAL PLAYTEST VALUES.
const MELEE := {
	attack_dc_base = 10,   # flat attack threshold: 1d20 + eff.attack vs 10
	defense_dc = 12,       # active defense: 1d20 + eff.defense vs 12
	ap_attack = 1,         # AP spent per strike
	# AP defense consequence is the WEAPON-SHOCK model (README §5):
	# a hit drains AP by its effective damage whether defended or
	# not; a successful defense converts the LP injury into AP
	# shock; a critical defense (natural 20) avoids all of it.
	# Full Defensive Stance (successful defense halves AP shock) is
	# canonical but DEFERRED — no stance system exists yet.
	# CANONICAL (Playable Loop 0.4): AP recovers only through genuine
	# REST — +1 AP every `ap_regen` seconds once `rest_delay` seconds
	# have passed without exertion. Striking, moving, casting,
	# dodging — and being struck at (combat pressure) — all mark the
	# rest clock, so an engaged fighter does not regenerate. The
	# Foundations 0.2 "defending is not exertion" carve-out is
	# SUPERSEDED: exhaustion no longer disables offense, so the
	# mutual-exhaustion deadlock it prevented cannot occur — an
	# EXHAUSTED (AP 0) actor still attacks and defends.
	# `mp_regen`: MP-bearing actors (Althar, Healer) regenerate
	# +1 MP every `mp_regen` seconds CONTINUOUSLY — during battle,
	# unaffected by exertion or the rest clock.
	rest_delay = 4.0,
	ap_regen = 3.0,
	mp_regen = 3.0,
}

## Presentation-facing thresholds — data-driven so the danger cue is
## a tunable, not a magic number buried in a view (Playable Loop 0.4).
const FEEDBACK := {
	# a hero at LP <= ceil(max_lp * critical_lp_frac) is in CRITICAL
	# CONDITION: red battlefield warning + important notification
	critical_lp_frac = 0.25,
}

## Spell reaction tuning (0.5): actors sharing the caster's faction
## get this bonus on the Perception check against his blast — they
## heard the warning ("FIREBALL!"). PROVISIONAL balance value; it is
## ONLY a Perception bonus — Dodge DC, AP cost and damage are
## unchanged for allies (friendly fire is intentional).
const SPELL_REACTION := {
	friendly_source_perception_bonus = 4,
}

## Player command tuning (Playable Party 0.5): a focus order the
## hero can never reach is dropped after `focus_stall_limit` failed
## steps instead of stalling him forever — he returns to autonomy
## with a "command_dropped" event. PROVISIONAL count.
const COMMAND := {
	focus_stall_limit = 6,
}

## Encounter XP (README §22): a fixed pool shared equally among
## allied heroes who entered the battlefield during the encounter.
## PROVISIONAL value — sized so clearing the six-skeleton group is a
## visible but modest award vs the ~120 XP of contribution damage.
const ENCOUNTER_XP := 30

## Weapons are data (README — Combat 0.3). Each entry carries identity,
## the damage roll and its physical damage type; reach/critical profile/
## armor interaction are future fields. PROVISIONAL table — dice are the
## values the roster already used, no balancing claimed.
const WEAPONS := {
	"sword": {display_name = "Sword", damage = "1d6",
		dmg_type = "slash"},
	"axe":   {display_name = "Axe", damage = "1d8",
		dmg_type = "slash"},
	"claws": {display_name = "Claws", damage = "1d4",
		dmg_type = "slash"},
	# PROVISIONAL Level-1 bow damage — no canonical value exists yet;
	# sword-parity 1d6 chosen conservatively. Pierce, not slash.
	"bow":   {display_name = "Bow", damage = "1d6",
		dmg_type = "pierce"},
	# Tower-scenario creature weapons. Authored here rather than in the
	# scenario because WEAPONS is a shared rule table and `_weapon_spec`
	# falls back to a bare dice expression — an unknown weapon name would
	# reach Dice.roll and assert. PROVISIONAL values.
	"club":  {display_name = "Club", damage = "1d8",
		dmg_type = "impact"},
	"knife": {display_name = "Knife", damage = "1d4",
		dmg_type = "pierce"},
}

## Bow shot pacing (sim/combat.gd "shoot" autonomy): an arrow spends
## `draw_t` seconds nocked (Draw/Aim clips), then flies `fly_per_hex`
## seconds per hex to the hex its target occupied AT RELEASE — a
## moving mark can walk out of the shot. PROVISIONAL values.
const BOW := {
	draw_t = 0.9,
	fly_per_hex = 0.11,
}

## Physical damage types: slash / pierce / impact. `impact` doubles as
## the blunt category — do not add a redundant "blunt". Magic types
## (fire/cold/electrical) live alongside in the same packet/resist
## architecture.

## Criticals (canonical baseline): natural 20 on an Attack -> critical
## hit; resolved attack damage x2 and Contribution XP x2 on the single
## meaningful damage number. Natural 1 -> critical miss. Consequence
## tables (injuries, fumbles) are UNRESOLVED — hooks only.
const CRITICALS := {
	damage_mult = 2,
	xp_mult = 2,
}

## Teleport (sim/teleport.gd): Althar repositions a friendly hero —
## the hero-positioning spell (root README §11). Deterministic by
## design: a valid command always executes — the interesting decision
## is WHO / WHERE / WHEN, not whether the weave slips. The same cast
## path covers REPOSITION (deployed hero) and DEPLOY (reserve hero ->
## field), and a successful cast reassigns the hero's defensive anchor
## to the destination: "defend HERE".
const TELEPORT := {
	display_name = "Teleport I",
	targeting = "hero_destination",   # a hero plus a destination hex
	kind = "blink",
	range = 8,           # hexes from the caster to the destination
	ap_cost = 3,         # Althar's AP per relocation
	color = Color(0.55, 0.65, 1.0, 1.0),
}

## Battlement posts: in-grid hexes whose ground projection lies on the
## curtain-wall band are elevated destinations — 2q+r in WALL_BAND maps
## onto the walkway (x ~ -12.5 / -11.2 world m). The rows spanning the
## gate opening stand on the gatehouse lintel instead of the wall-walk.
## Melee and movement never cross elevation: a posted hero is a safe
## staging spot — he holds there until Althar repositions him, but he
## cannot strike down and ground enemies cannot strike up.
const WALL_BAND := [-10, -9]     # 2q+r columns projecting onto the walk
const WALL_GATE_R := [0, 1, 2, 3] # r rows above the gate lintel

## 0 = field, 1 = battlement walk, 2 = gatehouse lintel.
static func wall_kind(h: Vector2i) -> int:
	if not (h.x * 2 + h.y) in WALL_BAND:
		return 0
	return 2 if h.y in WALL_GATE_R else 1

## Character Progression 0.2 (root README §22, sim/progress.gd).
## Values marked PROVISIONAL are tuning placeholders — the open design
## questions in §22 are intentionally unanswered. Keys marked CANON
## encode accepted baseline rules.
const PROGRESSION := {
	# Lifetime-XP thresholds; index i is the XP for Level i+1. A Level
	# records accumulated experience — it grants no blanket stats.
	# PROVISIONAL. Past the table Progress.level_xp_for() extrapolates
	# (engineering infrastructure only, NOT canon — README §22.4);
	# the table edge is never a Level cap.
	level_xp = [0, 100, 250, 500, 900, 1400],
	# Level-Up AP advancement roll — endurance grows, LP never does.
	# PROVISIONAL die — not established canon; the final rule should
	# weigh Level/CON/STR/archetype (README §22.9).
	ap_advance = "1d3",
	# Attribute Advancement (CANONICAL — Progression 0.3 closure):
	# EVERY Level-Up rolls 1d100; there is no odd/even rule. Entries
	# are ranges checked in order. This is the Althar's Keep
	# adaptation of the recovered tabletop table onto the seven
	# fundamental attributes — the original table is preserved as
	# historical evidence in docs/PROGRESSION_0_3.md. Total
	# advancement probability stays 21% per Level-Up.
	# d100 = 100 -> the PLAYER chooses ANY of the seven, then
	# attr_advance_die applies. Eligible = attrs below attr_cap.
	attr_advance = [
		{lo = 98, hi = 99, name = "Strength",     attr = "str"},
		{lo = 96, hi = 97, name = "Dexterity",    attr = "dex"},
		{lo = 94, hi = 95, name = "Constitution", attr = "con"},
		{lo = 92, hi = 93, name = "Intelligence", attr = "int"},
		{lo = 90, hi = 91, name = "Magic",        attr = "mag"},
		{lo = 88, hi = 89, name = "Charisma",     attr = "cha"},
		{lo = 86, hi = 87, name = "Agility",      attr = "agi"},
		{lo = 84, hi = 85, name = "Strength",     attr = "str"},
		{lo = 82, hi = 83, name = "Dexterity",    attr = "dex"},
		{lo = 80, hi = 81, name = "Agility",      attr = "agi"},
	],
	attr_advance_die = "1d6",
	# CANON: all seven fundamental attributes are eligible on a
	# natural 100. A future exceptional-100 reward is DEFERRED.
	attr_candidates_all = ["str", "dex", "agi", "con", "int", "cha",
		"mag"],
	# PROVISIONAL cap: advancement clamps at 100 — the >100
	# (supernatural) rule is UNRESOLVED, this just prevents silent
	# overflow until canon decides.
	attr_cap = 100,
	# CANON: Spellcasting check — 1d20 + effective Spellcasting >= 20.
	cast_dc = 20,
	# Magic resolution: the target's Resistance check opposes the
	# successful casting total. A tie goes to `resist_tie` —
	# "defender" (>= wins) or "caster" (> wins). PROVISIONAL choice.
	resist_tie = "defender",
	# Resisted (light) magic damage: half of the effective damage goes
	# to AP. Rounding for odd totals — PROVISIONAL documented choice.
	light_rounding = "floor",
	# Learned combat values: learned + bonuses = effective.
	# `bonuses` names the bonus pools feeding each value; pools
	# listed in `attr_pools` derive from the character's attributes
	# via the Table M bands below, others read the `bonuses` dict
	# (equipment/situational, future). `ceiling` = "even": start +
	# floor(Level/2) — canonical for Spellcasting THROUGH LEVEL 10
	# (matches the historical L2/4/6/8/10 cadence); beyond L10 it is
	# UNDER REVIEW (historical reference slows to L15/L20 — root
	# README §22.21/§22.26). PROVISIONAL (0.5): the same even-rule
	# ceiling now governs attack/defense/resistance so development
	# is usable — this CONTRADICTS the doctrine's milestone cadence
	# for Defense/Resistance and is not a design ruling for Attack.
	learned = {
		"spellcasting": {start = 10, bonuses = ["magic"],
			ceiling = "even"},
		"attack":       {start = 0, bonuses = ["dex"],
			ceiling = "even"},
		"defense":      {start = 0, bonuses = ["agi"],
			ceiling = "even"},
		"resistance":   {start = 0, bonuses = [], ceiling = "even"},
	},
	# CANONICAL (Character Foundations 0.2 — "Table M",
	# MIDGARD-inspired): attribute -> derived-bonus threshold bands.
	# `attr_pools` maps a bonus-pool name to the attribute feeding
	# it and which band table applies; "magic" is the deliberately
	# steeper column (MAG 96 -> +3). Values outside every band
	# (0 / >100) yield 0 — the >100 rule is DEFERRED.
	attr_pools = {
		"dex":   {attr = "dex", table = "attr_band_standard"},
		"agi":   {attr = "agi", table = "attr_band_standard"},
		"magic": {attr = "mag", table = "attr_band_magic"},
	},
	attr_band_standard = [[1, 20, -1], [21, 80, 0], [81, 95, 1],
		[96, 100, 2]],
	attr_band_magic = [[1, 20, -2], [21, 40, -1], [41, 60, 0],
		[61, 80, 1], [81, 95, 2], [96, 100, 3]],
	# XP cost to raise a learned value N-1 -> N. Escalating by design
	# (good -> excellent -> extraordinary costs ever more). THE TABLE
	# IS PROVISIONAL — not canon, replaced by real design later.
	learned_costs = {
		# Rank 10 entry: casters who begin BELOW the +10 baseline
		# (the Healer starts at +9) still buy the same ranks — the
		# curve extends down to 50, keeping one shared table.
		"spellcasting": {10: 50, 11: 100, 12: 150, 13: 200, 14: 250,
			15: 300},
		# PROVISIONAL (0.5): no canonical cost table exists for the
		# combat values — open decision 0.5-4. This shallow curve is a
		# placeholder so spending is real, NOT a design ruling. The
		# 50/rank curve now runs to 15 so heroes who START above the
		# baseline (the Archer's authored +10/+8/+6) keep a real next
		# rank instead of dead-ending at "no cost rule".
		"attack":     {1: 50, 2: 100, 3: 150, 4: 200, 5: 250,
			6: 300, 7: 350, 8: 400, 9: 450, 10: 500, 11: 550,
			12: 600, 13: 650, 14: 700, 15: 750},
		"defense":    {1: 50, 2: 100, 3: 150, 4: 200, 5: 250,
			6: 300, 7: 350, 8: 400, 9: 450, 10: 500, 11: 550,
			12: 600, 13: 650, 14: 700, 15: 750},
		"resistance": {1: 50, 2: 100, 3: 150, 4: 200, 5: 250,
			6: 300, 7: 350, 8: 400, 9: 450, 10: 500, 11: 550,
			12: 600, 13: 650, 14: 700, 15: 750},
	},
}

const FIREBALL := {
	display_name = "Fireball I",
	# CANONICAL (0.5): `targeting` is the spell's declared targeting
	# mode (sim/targeting.gd) — ground-targeted spells hit whatever
	# stands inside the blast, allies included.
	targeting = "ground",
	mp_cost = 3,          # PROVISIONAL — spell MP costs are unmeasured
	dmg_type = "fire",     # identity: burning + explosive magic
	damage = "2d6",        # shown to the player at cast time
	range = 10,            # hexes from caster
	speed = 450.0,         # world px/s -> ~1-2 s over a typical cast
	aoe_radius = 2,        # blast covers center + rings 1..2
	# CANON (0.5 update): damage dice per victim by FINAL hex
	# distance — inner 2d6, middle 1d6+1, outer 1d6-1 with a
	# minimum of 1 final damage (ring_floor catches a rolled 0).
	ring_damage = { 0: "2d6", 1: "1d6+1", 2: "1d6-1" },
	ring_floor = { 2: 1 },
	# enemies in the danger region get Perception when impact is this
	# many seconds away
	perceive_time = 0.9,
	perception_dc = 14,    # 1d20 + Perception >= DC
	dodge_dc = 15,         # 1d20 + Dodge >= DC
	dodge_ap_cost = 1,
	# presentation color of the projectile
	color = Color(1.0, 0.55, 0.15, 1.0),
}

## Lightning: the fast precision strike. Single hex, near-instant travel,
## almost no dodge window — mechanically different from Fireball's slow
## lobbed blast (root README "Initial Spell Set": fast/immediate strike).
const LIGHTNING := {
	display_name = "Lightning I",
	targeting = "enemy",    # CANONICAL: bolt binds one enemy combatant
	mp_cost = 2,          # PROVISIONAL
	kind = "bolt",          # presentation: instant arc, not a comet
	dmg_type = "electrical",
	damage = "4d6",         # shown to the player at cast time
	range = 10,
	speed = 15000.0,        # ~0.15 s over a typical cast
	aoe_radius = 0,         # the target hex only
	ring_damage = { 0: "4d6" },
	ap_drain = 2,           # the shock disrupts: hit targets lose 2 AP
	perceive_time = 0.2,    # split-second warning
	perception_dc = 16,
	dodge_dc = 17,
	dodge_ap_cost = 1,
	color = Color(0.55, 0.75, 1.0, 1.0),
}

## Blizzard: ground-targeted conjuration (Storm Gust style). The storm
## is NOT thrown — the Wizard picks an area and the blizzard materialises
## there after a short gather (the "onset" doubles as the dodge window).
## Then the zone ticks cold damage + AP drain on everyone inside, and
## cold exposure accumulates toward a future Frozen state.
const BLIZZARD := {
	display_name = "Blizzard I",
	targeting = "ground",   # CANONICAL: the storm is conjured on a hex
	mp_cost = 4,          # PROVISIONAL
	kind = "storm",          # deploys a persistent zone, no projectile
	instant = true,          # conjured at the target, never travels
	onset = 0.8,             # gather time before the storm exists
	dmg_type = "cold",
	damage = "1d6",
	range = 10,
	aoe_radius = 2,
	ring_damage = { 0: "1d6", 1: "1d6", 2: "1d6" },   # unused: zone ticks
	perceive_time = 0.7,     # enemies spot the gathering storm
	perception_dc = 14,
	dodge_dc = 15,
	dodge_ap_cost = 1,
	duration = 6.0,          # seconds of storm
	tick = 1.0,              # seconds between zone pulses
	tick_damage = "1d3",     # cold damage per enemy per tick
	ap_drain = 1,            # AP lost per tick (the cold slows you)
	color = Color(0.65, 0.85, 1.0, 1.0),
}

## Meteor: IMPACT first, HEAT second. A massive object strikes — most of
## each ring's damage is physical impact, the rest is fire/heat. A fire-
## resistant creature still gets crushed; that is the point of the
## multi-component packet (sim/damage.gd).
const METEOR := {
	display_name = "Meteor I",
	targeting = "ground",   # CANONICAL: the rock falls on a hex
	mp_cost = 6,          # PROVISIONAL
	kind = "comet",
	blast_scale = 2.2,       # presentation: explosion size multiplier
	damage = "6d6",
	range = 10,
	speed = 350.0,           # heavy, slow fall
	aoe_radius = 3,
	ring_damage = {
		0: { impact = "4d6", fire = "2d6" },
		1: { impact = "3d6", fire = "1d6" },
		2: { impact = "2d6", fire = "1d6" },
		3: { impact = "1d6" },
	},
	perceive_time = 0.6,
	perception_dc = 16,
	dodge_dc = 18,
	dodge_ap_cost = 2,
	color = Color(1.0, 0.42, 0.1, 1.0),
}

## Healer spell kit 0.1 (Playable Party 0.5, sim/support.gd).
## kind = "blessing": actor-targeted support, NOT damage packets —
## the shared cast path still applies the canonical Spellcasting
## check (1d20 + effective >= cast_dc) with MP committed on the
## attempt. `target` selects the valid actor set:
## "ally_alive" living friendly heroes, "ally_dead" fallen ones.
## FROZEN rules (user spec 0.5): Heal restores up to 4 LP AND 4 AP
## (pools cap independently, no MP), costs 3 AP + 2 MP, 3 s cooldown.
## Resurrection: target returns at exactly 1 LP / 0 AP / MP kept,
## 1200 s (20 min) of ACTIVE gameplay cooldown — a failed casting
## roll does not start it. All four costs/durations marked
## PROVISIONAL are balance-TBD, not canon.
const HEAL := {
	display_name = "Heal I",
	kind = "blessing", target = "ally_alive", targeting = "ally_alive",
	range = 10,           # CANON (0.5): RANGED working — the Healer
	                      # mends across the field like Althar's own
	                      # ranged magic, no bedside walk required
	mp_cost = 2,          # FROZEN
	ap_cost = 0,          # CANON (0.5): spellwork draws on MP alone —
	                      # the Healer's endurance stays his own
	heal = 4,             # FROZEN — up to 4 LP and 4 AP, capped apart
	cooldown = 3.0,       # FROZEN — active gameplay seconds
	color = Color(1.0, 0.84, 0.45, 1.0),   # warm amber restorative
}

const RESURRECTION := {
	display_name = "Resurrection I",
	kind = "blessing", target = "ally_dead", targeting = "ally_dead",
	range = 1,            # CANON (0.5): PROXIMITY working — the
	                      # Healer must stand beside the fallen;
	                      # a far corpse answers "out_of_range" and
	                      # he has to walk there first
	mp_cost = 10,         # PROVISIONAL — major working, deep cost
	ap_cost = 0,
	cooldown = 1200.0,    # FROZEN — 20 min ACTIVE gameplay time
	revive_lp = 1,        # FROZEN — returns barely alive
	color = Color(1.0, 0.93, 0.6, 1.0),
}

const HASTE := {
	display_name = "Haste I",
	kind = "blessing", target = "ally_alive", targeting = "ally_alive",
	range = 6,
	mp_cost = 3,          # PROVISIONAL
	ap_cost = 0,
	duration = 12.0,      # PROVISIONAL — active gameplay seconds
	cadence = 0.5,        # PROVISIONAL: action/move cooldowns halve
	                      # -> roughly double strike/step tempo
	color = Color(0.55, 0.85, 0.95, 1.0),
}

const AEGIS := {
	display_name = "Aegis I",
	kind = "blessing", target = "ally_alive", targeting = "ally_alive",
	range = 6,
	mp_cost = 4,          # PROVISIONAL
	ap_cost = 0,
	duration = 15.0,      # PROVISIONAL — active gameplay seconds
	pool = 8,             # PROVISIONAL: barrier soaks up to 8 LP
	                      # of bodily injury, then breaks early
	color = Color(0.7, 0.85, 1.0, 1.0),
}

## Field objects (Hex Integrity): the spatial model is HEX = whole
## spatial cell, OBJECT = physical thing occupying it, STATE =
## intact/damaged/... — traversability and targetability are
## consequences. env3d renders this same list, so the visual object
## and the occupied cells can never drift apart.
## kind = env3d dresser id ("pine"/"palisade"/"campfire"/"torch" or an
## assets/nature prop name); pos = world metres; `blocks` = footprint
## radius in metres — a cell is occupied when its CENTRE lies inside
## the footprint, or inside `blocks` of a `line`-metre segment through
## `pos` rotated by `rot` (elongated props). A prop overlapping only a
## cell's edge leaves it whole and walkable — whole cells, never
## fractions. Occupied cells stay in-grid: they gate movement and
## deployment (hex_free), never spell targeting (hex_in_grid).
const FIELD_PROPS := [
	# field obstacles: rocks + scattered cover near the party line
	{kind = "boulder_01", pos = Vector3(2, 0, -6), rot = 0.3,
		scale = 1.15, blocks = 1.0},
	{kind = "boulder_01", pos = Vector3(6, 0, 3), rot = -0.5,
		scale = 0.9, blocks = 0.8},
	{kind = "wooden_crate_01", pos = Vector3(9, 0, -8), rot = 1.2,
		blocks = 0.8},
	{kind = "wooden_crate_01", pos = Vector3(4, 0, 8), rot = 0.7,
		blocks = 0.8},
	{kind = "tree_stump_01", pos = Vector3(-7, 0, -8), rot = 0.4,
		blocks = 0.9},
	{kind = "dead_tree_trunk", pos = Vector3(12, 0, -9), rot = 0.4,
		blocks = 1.0},
	{kind = "palisade", pos = Vector3(15, 0, -7), rot = 0.5,
		line = 4.2, blocks = 0.7},
	{kind = "palisade", pos = Vector3(16, 0, 6), rot = -0.4,
		line = 4.2, blocks = 0.7},
	{kind = "campfire", pos = Vector3(7, 0, -4), blocks = 0.9},
	{kind = "torch", pos = Vector3(0, 0, -10)},
	{kind = "torch", pos = Vector3(11, 0, 5)},
	# east approach dressing (Battlefield 0.1) — sparse cover
	# marching east so the approach reads as a real route
	{kind = "boulder_01", pos = Vector3(24, 0, -4), rot = 0.9,
		scale = 1.3, blocks = 1.2},
	{kind = "boulder_01", pos = Vector3(30, 0, 7), rot = -0.6,
		scale = 1.0, blocks = 0.9},
	{kind = "tree_stump_01", pos = Vector3(27, 0, 3), rot = 0.2,
		blocks = 0.9},
	{kind = "dead_tree_trunk", pos = Vector3(36, 0, -7), rot = 1.1,
		blocks = 1.0},
	{kind = "dead_tree_trunk", pos = Vector3(44, 0, 5), rot = -0.3,
		scale = 1.2, blocks = 1.1},
	{kind = "palisade", pos = Vector3(25, 0, -10), rot = 0.9,
		line = 4.2, blocks = 0.7},
	{kind = "palisade", pos = Vector3(33, 0, 11), rot = -0.2,
		line = 4.2, blocks = 0.7},
	{kind = "palisade", pos = Vector3(41, 0, -3), rot = 0.4,
		line = 4.2, blocks = 0.7},
	{kind = "campfire", pos = Vector3(38, 0, -2), blocks = 0.9},
	{kind = "torch", pos = Vector3(22, 0, -12)},
	{kind = "torch", pos = Vector3(34, 0, 8)},
	{kind = "torch", pos = Vector3(48, 0, -6)},
	# east approach torches — the expanded field stays lit to the
	# treeline instead of reading as a dark void
	{kind = "torch", pos = Vector3(58, 0, -8)},
	{kind = "torch", pos = Vector3(66, 0, 10)},
	# supplies at the wall base
	{kind = "wooden_crate_01", pos = Vector3(-10.1, 0, 8.5), rot = 0.4,
		blocks = 0.8},
	{kind = "wooden_crate_01", pos = Vector3(-10.3, 0, 9.4), rot = -0.3,
		scale = 0.85, blocks = 0.8},
	{kind = "wine_barrel_01", pos = Vector3(-10.0, 0, 10.6), rot = 0.9,
		blocks = 0.8},
	{kind = "wooden_bucket_01", pos = Vector3(-10.5, 0, 7.6),
		blocks = 0.6},
	{kind = "wooden_ladder", pos = Vector3(-10.7, 0, 11.8),
		rot = -1.5708, blocks = 0.8},
	{kind = "wooden_lantern_01", pos = Vector3(-10.2, 0, 7.0),
		blocks = 0.6},
	# rock mass on the field (the twin behind the keep stays dressing)
	{kind = "boulder_01", pos = Vector3(26, 0, -12), rot = 0.9,
		scale = 2.6, blocks = 2.3},
	# ---- on-field pines: flank woods + the east treeline the enemy
	# emerges from. A pine's lowest boughs reach ~1 m off the ground —
	# impassable — so the canopy footprint occupies its cells.
	{kind = "pine", pos = Vector3(22, 0, -14), scale = 2.2,
		blocks = 3.3},
	{kind = "pine", pos = Vector3(25, 0, -7), scale = 1.9,
		blocks = 2.9},
	{kind = "pine", pos = Vector3(28, 0, 1), scale = 2.5,
		blocks = 3.8},
	{kind = "pine", pos = Vector3(26, 0, 8), scale = 2.0,
		blocks = 3.0},
	{kind = "pine", pos = Vector3(23, 0, 14), scale = 2.2,
		blocks = 3.3},
	{kind = "pine", pos = Vector3(16, 0, 21), scale = 1.8,
		blocks = 2.7},
	{kind = "pine", pos = Vector3(5, 0, -23), scale = 2.0,
		blocks = 3.0},
	{kind = "pine", pos = Vector3(-4, 0, -24), scale = 1.7,
		blocks = 2.6},
	{kind = "pine", pos = Vector3(10, 0, -22), scale = 1.9,
		blocks = 2.9},
	{kind = "pine", pos = Vector3(19, 0, 20), scale = 1.6,
		blocks = 2.4},
	{kind = "pine", pos = Vector3(29, 0, -5), scale = 1.7,
		blocks = 2.6},
	{kind = "pine", pos = Vector3(27, 0, 15), scale = 1.9,
		blocks = 2.9},
	{kind = "pine", pos = Vector3(31, 0, 7), scale = 2.2,
		blocks = 3.3},
	{kind = "pine", pos = Vector3(34, 0, -18), scale = 2.1,
		blocks = 3.2},
	{kind = "pine", pos = Vector3(40, 0, -22), scale = 2.4,
		blocks = 3.6},
	{kind = "pine", pos = Vector3(48, 0, -20), scale = 1.9,
		blocks = 2.9},
	{kind = "pine", pos = Vector3(57, 0, -23), scale = 2.2,
		blocks = 3.3},
	{kind = "pine", pos = Vector3(66, 0, -19), scale = 2.0,
		blocks = 3.0},
	{kind = "pine", pos = Vector3(74, 0, -14), scale = 2.3,
		blocks = 3.5},
	{kind = "pine", pos = Vector3(34, 0, 20), scale = 2.0,
		blocks = 3.0},
	{kind = "pine", pos = Vector3(42, 0, 24), scale = 2.3,
		blocks = 3.5},
	{kind = "pine", pos = Vector3(51, 0, 21), scale = 1.8,
		blocks = 2.7},
	{kind = "pine", pos = Vector3(60, 0, 25), scale = 2.2,
		blocks = 3.3},
	{kind = "pine", pos = Vector3(70, 0, 19), scale = 1.9,
		blocks = 2.9},
	{kind = "pine", pos = Vector3(76, 0, 12), scale = 2.1,
		blocks = 3.2},
	{kind = "pine", pos = Vector3(68, 0, -2), scale = 2.4,
		blocks = 3.6},
	{kind = "pine", pos = Vector3(72, 0, 6), scale = 2.0,
		blocks = 3.0},
	{kind = "pine", pos = Vector3(75, 0, -7), scale = 1.8,
		blocks = 2.7},
]

## Defended structures (Keep Integrity — `sim/structure.gd`). Althar's
## Keep authors none: its battle is heroes versus a field of enemies, and
## an empty list keeps `Battle.create` on exactly its previous path. The
## tower scenario supplies a Keep here.
const STRUCTURES := []

## The keep occupies whole cells too: everything west of the wall's
## field face is keep interior (2q+r <= KEEP_CELL_COL), and the two
## towers bulge east of the face — their footprints occupy the cells
## their centres land in (x, z, radius in metres).
const KEEP_CELL_COL := -11
const KEEP_MASSES := [
	Vector3(-12.0, -14.8, 3.6),
	Vector3(-12.0, 17.5, 3.0),
]

## Whole-cell occupancy test (Hex Integrity): a cell is occupied when
## it lies inside the keep or a field object's footprint. Occupied
## cells remain in `valid` — they are real hexes with a thing in them.
static func cell_blocked(h: Vector2i) -> bool:
	if 2 * h.x + h.y <= KEEP_CELL_COL:
		return true
	var c := Hex.to_world(h, HEX_SIZE, HEX_SQUASH) * WORLD_SCALE
	for m in KEEP_MASSES:
		if c.distance_to(Vector2(m.x, m.y)) <= m.z:
			return true
	for p in FIELD_PROPS:
		var pr: float = p.get("blocks", 0.0)
		if pr <= 0.0:
			continue
		var pp := Vector2(p.pos.x, p.pos.z)
		var lin: float = p.get("line", 0.0)
		if lin > 0.0:
			var dir := Vector2(cos(p.get("rot", 0.0)),
				-sin(p.get("rot", 0.0)))
			var rel := c - pp
			var t := clampf(rel.dot(dir), -lin * 0.5, lin * 0.5)
			if (rel - dir * t).length() <= pr:
				return true
		elif c.distance_to(pp) <= pr:
			return true
	return false

## Spellbook: slot id -> config block. The orchestrator picks by id.
const SPELLS := {
	"fireball": FIREBALL,
	"lightning": LIGHTNING,
	"blizzard": BLIZZARD,
	"meteor": METEOR,
	"teleport": TELEPORT,
	"heal": HEAL,
	"resurrect": RESURRECTION,
	"haste": HASTE,
	"aegis": AEGIS,
}

## Healer's hotbar (Playable Party 0.5): his four support workings in
## kit order — slots 5-9 stay empty like Althar's unlearned pages.
const HEALER_SPELLS := ["heal", "resurrect", "haste", "aegis"]

# Primitive loot table for dead skeletons.
const LOOT := {
	gold_min = 5, gold_max = 15,
	items = ["Rusty Sword", "Bone Charm", "Small Potion",
		"Potion of Vigor", "Old Coin"],
}

## ITEM DEFINITIONS (Inventory 0.1 — Playable Party 0.5).
## Every lootable name maps here. kind: "consumable" gets a USE
## flow; "equipment"/"trinket" are honest cargo until their systems
## exist (no equip/sell rules yet). Consumable effects are
## PROVISIONAL — no canonical potion rule existed; the numbers
## mirror the scale of Heal I (up to 4 per pool) pending design.
## effect.type: "restore_lp" | "restore_ap" — pools cap
## independently at their max; "target" picks the valid set the
## same way support spells do ("ally_alive").
## icon: {color, mark} renders a placeholder chip now; `icon_tex`
## is the hook for real art later — a set path wins over the chip.
const ITEMS := {
	"Small Potion": {
		kind = "consumable", target = "ally_alive",
		effect = {type = "restore_lp", amount = 4},   # PROVISIONAL
		desc = "A draught of red glass. Knits flesh — restores "
			+ "up to 4 LP.",
		icon = {color = Color(0.72, 0.25, 0.28), mark = "P"},
	},
	"Potion of Vigor": {
		kind = "consumable", target = "ally_alive",
		effect = {type = "restore_ap", amount = 4},   # PROVISIONAL
		desc = "Bitter green tonic. Steadies the limbs — restores "
			+ "up to 4 AP.",
		icon = {color = Color(0.3, 0.55, 0.35), mark = "V"},
	},
	"Rusty Sword": {
		kind = "equipment",
		desc = "Notched blade, pitted edge. There is no equipment "
			+ "system yet — it is cargo.",
		icon = {color = Color(0.55, 0.5, 0.42), mark = "S"},
	},
	"Bone Charm": {
		kind = "trinket",
		desc = "A knucklebone on a cord. Worth something to someone, "
			+ "somewhere.",
		icon = {color = Color(0.78, 0.75, 0.66), mark = "B"},
	},
	"Old Coin": {
		kind = "trinket",
		desc = "Tarnished, pre-war mint. A collector's coin, not "
			+ "currency here.",
		icon = {color = Color(0.72, 0.6, 0.3), mark = "C"},
	},
}

## BELT / QUICK ITEMS (Inventory 0.1): each hero carries a small
## band of immediately reachable consumables. PROVISIONAL slot
## count — no canonical belt rule exists; 3 reads right at this
## scale. Belt slots hold an item NAME referencing the shared
## inventory stack — using a belt slot uses one unit on the hero
## himself (party inventory decrements; empty stacks clear the
## slot everywhere).
const BELT_SLOTS := 3
