extends RefCounted
## Althar's Keep — Tower: SCENE 01, "The Defensive Front".
##
## A SCENARIO module supplies only what describes a battlefield: the grid,
## the roster and their spawn hexes, the terrain occupancy rule, the
## elevation rule, the defended structures and the wave table. Everything
## that is a RULE — melee DCs, weapon dice, spell blocks, progression,
## Table M, items — is re-exported by reference from the shared
## `sim/config.gd` below, so this scenario can never drift from Althar's
## Keep's rules. (Contrast Althar's Keep's own `scripts/cfg_proof.gd`,
## a hand-copied table that has already gone stale.)
##
## SPATIAL COMPOSITION (inspired by, not copied from, the Kingdom Rush
## reference): the Keep anchors the LEFT edge, enemies enter from the far
## UPPER-RIGHT, and one broad winding road carries them through an open
## fighting area, a chokepoint, and a final approach to the gate.
##
## Geometry note: `col(h) = 2*h.x + h.y` is proportional to world X
## (x = col * HEX_SIZE * sqrt(3)/2 * WORLD_SCALE), which is why the keep
## uses the same expression for its wall band and keep column.

const Shared = preload("res://sim/config.gd")
const Hex = preload("res://sim/hex.gd")
const Enemy = preload("res://sim/enemy.gd")

## ---- SHARED RULES (references, never copies) ----------------------
const PROGRESSION := Shared.PROGRESSION
const MELEE := Shared.MELEE
const CRITICALS := Shared.CRITICALS
const WEAPONS := Shared.WEAPONS
const BOW := Shared.BOW
const FEEDBACK := Shared.FEEDBACK
const SPELLS := Shared.SPELLS
const SPELL_REACTION := Shared.SPELL_REACTION
const FIREBALL := Shared.FIREBALL
const LIGHTNING := Shared.LIGHTNING
const BLIZZARD := Shared.BLIZZARD
const METEOR := Shared.METEOR
const TELEPORT := Shared.TELEPORT
const HEAL := Shared.HEAL
const RESURRECTION := Shared.RESURRECTION
const HASTE := Shared.HASTE
const AEGIS := Shared.AEGIS
const HEALER_SPELLS := Shared.HEALER_SPELLS
const ITEMS := Shared.ITEMS
const BELT_SLOTS := Shared.BELT_SLOTS
const ENCOUNTER_XP := Shared.ENCOUNTER_XP
const LOOT := Shared.LOOT
const HEX_SIZE := Shared.HEX_SIZE
const HEX_SQUASH := Shared.HEX_SQUASH
const WORLD_SCALE := Shared.WORLD_SCALE

const SEED := 20260927

## Althar commands from the Keep top and sees the whole front; his
## effective spell range covers the battlefield (user decision — an
## actor-level override, not a generic elevation rule).
const ALTHAR_SPELL_RANGE := 99

## ---- SCENE: grid ---------------------------------------------------
const GRID_CENTER := Vector2i(16, 0)
const GRID_RADIUS := 24

## ---- SCENE: the Keep (left edge) -----------------------------------
## Everything at or west of this column is the Keep's mass. The Keep TOP
## is a small walkable, elevated platform carved out of it — Althar's
## command post.
const KEEP_FACE_COL := -5
const KEEP_TOP_COLS := [-8, -7, -6]   # walkable battlement, r == 0

## ---- SCENE: the road -----------------------------------------------
## One authored route: broad, winding, and the ONLY way through — off-road
## terrain is cliff and forest, so the road enforces the path without a
## path-following system (`Combat._step` flood-fills walkable cells, so
## marching enemies follow it for free).
##
## Segment widths vary: wide where the road should read as an open
## fighting area, narrow at the chokepoints.
const ROAD := [
	{a = Vector2(50.0, 14.0), b = Vector2(38.0, 2.0),   w = 3.6},  # entry
	{a = Vector2(38.0, 2.0),  b = Vector2(26.0, -8.0),  w = 4.2},  # OPEN AREA
	{a = Vector2(26.0, -8.0), b = Vector2(14.0, 2.0),   w = 3.4},  # mid route
	{a = Vector2(14.0, 2.0),  b = Vector2(4.0, -6.0),   w = 3.6},  # chokepoint
	{a = Vector2(4.0, -6.0),  b = Vector2(-5.0, 0.0),   w = 3.8},  # final run
]

## ---- SCENE: the towers ---------------------------------------------
## The Archer and the Healer each hold a dedicated elevated platform, at
## the reference's two catapult positions: mid-route and upper-mid. A
## tower has NO structural HP — its survival is the hero standing on it.
const TOWERS := {
	archer = Vector2i(13, -10),   # lower-mid, south of the mid route
	healer = Vector2i(4, 7),      # upper-mid, north of the mid route
}

## ---- SCENE: the defended structure ---------------------------------
## MVP: one Integrity pool (see sim/structure.gd). Material resistances
## are deliberately EMPTY — no canonical masonry table exists yet, so the
## gap is left visible rather than invented. PROVISIONAL integrity.
const STRUCTURES := [
	{
		id = "keep", display_name = "Althar's Keep",
		hex = Vector2i(-3, 1),
		integrity = 200,
		material = "stone",
		armor = {lp = 1},
		resist = {},
	},
]
const KEEP_ID := "keep"

## Keep workers (spec §16): a placeholder repair allowance, applied
## between waves by the orchestrator. PROVISIONAL — no worker simulation,
## no economy. 0 would mean "no repair at all".
const KEEP_REPAIR_PER_WAVE := 25

## Presentation heights (metres) of the two elevated levels. Scene data,
## not rules: the simulation's elevation is `wall_kind` (a LEVEL, not a
## height). Both the environment and the actor view read these so a hero
## always stands ON the structure it occupies rather than inside it.
const TOWER_H := 4.4
const KEEP_TOP_H := 6.2

## ---- occupancy ------------------------------------------------------

static func _keep_top(h: Vector2i) -> bool:
	return h.y == 0 and (2 * h.x + h.y) in KEEP_TOP_COLS

static func _is_tower(h: Vector2i) -> bool:
	return h == TOWERS.archer or h == TOWERS.healer

## Whole-cell occupancy (Hex Integrity): a cell is occupied when it lies
## inside the Keep's mass, or off the road. Occupied cells stay in
## `valid` — they are real hexes with something in them.
static func cell_blocked(h: Vector2i) -> bool:
	if _is_tower(h) or _keep_top(h):
		return false                    # the two towers and the Keep top
	if 2 * h.x + h.y <= KEEP_FACE_COL:
		return true                     # the Keep's mass
	if _on_road(h):
		return false
	for p in FIELD_PROPS:
		var pr: float = p.get("blocks", 0.0)
		if pr <= 0.0:
			continue                    # decorative dressing only
		if _near_prop(h, p, pr):
			return true
	return true                         # cliff / forest

static func _near_prop(h: Vector2i, p: Dictionary, pr: float) -> bool:
	var c := Hex.to_world(h, HEX_SIZE, HEX_SQUASH) * WORLD_SCALE
	var pp := Vector2(p.pos.x, p.pos.z)
	var lin: float = p.get("line", 0.0)
	if lin > 0.0:
		var dir := Vector2(cos(p.get("rot", 0.0)), -sin(p.get("rot", 0.0)))
		var rel := c - pp
		var t := clampf(rel.dot(dir), -lin * 0.5, lin * 0.5)
		return (rel - dir * t).length() <= pr
	return c.distance_to(pp) <= pr

## Distance from a cell's centre to the road centreline, in metres.
static func road_distance(h: Vector2i) -> float:
	var c := Hex.to_world(h, HEX_SIZE, HEX_SQUASH) * WORLD_SCALE
	var best := 1.0e9
	for seg in ROAD:
		var a: Vector2 = seg.a
		var b: Vector2 = seg.b
		var ab := b - a
		var len2 := ab.length_squared()
		var t := 0.0 if len2 <= 0.0 else clampf((c - a).dot(ab) / len2,
			0.0, 1.0)
		best = minf(best, c.distance_to(a + ab * t))
	return best

static func _on_road(h: Vector2i) -> bool:
	var c := Hex.to_world(h, HEX_SIZE, HEX_SQUASH) * WORLD_SCALE
	for seg in ROAD:
		var a: Vector2 = seg.a
		var b: Vector2 = seg.b
		var ab := b - a
		var len2 := ab.length_squared()
		var t := 0.0 if len2 <= 0.0 else clampf((c - a).dot(ab) / len2,
			0.0, 1.0)
		if c.distance_to(a + ab * t) <= float(seg.w):
			return true
	return false

## Elevation: the two tower platforms (1) and the Keep top (2). Melee and
## movement never cross levels — a posted hero cannot be reached from the
## ground and cannot strike down into it.
static func wall_kind(h: Vector2i) -> int:
	if _keep_top(h):
		return 2
	if _is_tower(h):
		return 1
	return 0

## ---- SCENE: the five heroes ----------------------------------------
## Same people, same authored Level-1 values as Althar's Keep. Only
## `hex`, `deployed`, `elevated` and the defensive anchor are scenario
## data. Althar commands from the Keep top; the Archer and Healer hold
## their towers; the Warrior and Barbarian hold the road.
const HEROES := [
	{
		id = "wizard", display_name = "Althar", faction = "friendly",
		lp = 12, ap = 16, mp = 20, perception = 0, dodge = 0,
		defense = 3,
		attributes = {str = 45, dex = 65, agi = 55, con = 55,
			int = 92, cha = 80, mag = 96},
		learned = {spellcasting = 10},
		spell_range = ALTHAR_SPELL_RANGE,
		hex = Vector2i(-3, 0),          # col -6 — the Keep top
		elevated = true,
	},
	{
		id = "warrior", display_name = "Warrior", faction = "friendly",
		lp = 16, ap = 14, perception = 2, dodge = 1,
		attributes = {str = 75, dex = 78, agi = 85, con = 88,
			int = 60, cha = 65, mag = 10},
		attack = 5, defense = 6, shield = 7, weapon = "sword",
		attack_range = 1, ai = "defend", leash = 4,
		act_cd = 1.8, move_cd = 1.3,
		hex = Vector2i(2, -2),          # the last bend before the gate
	},
	{
		id = "barbarian", display_name = "Barbarian", faction = "friendly",
		lp = 15, ap = 12, perception = 3, dodge = 2,
		attributes = {str = 93, dex = 70, agi = 65, con = 82,
			int = 45, cha = 55, mag = 5},
		attack = 7, defense = 3, block = 0, weapon = "axe",
		attack_range = 1, ai = "brawl", leash = 5,
		act_cd = 1.7, move_cd = 1.2,
		hex = Vector2i(12, -4),         # mid-route, forward of the Warrior
	},
	{
		id = "archer", display_name = "Archer", faction = "friendly",
		lp = 12, ap = 16, perception = 5, dodge = 3,
		attributes = {str = 55, dex = 92, agi = 88, con = 65,
			int = 72, cha = 70, mag = 10},
		learned = {attack = 10, defense = 8, resistance = 6},
		weapon = "bow", attack_range = 8, ai = "shoot", leash = 8,
		act_cd = 2.6, move_cd = 1.0,
		hex = TOWERS.archer,            # mid-route firing tower
		elevated = true,
	},
	{
		id = "healer", display_name = "Healer", faction = "friendly",
		lp = 13, ap = 15, mp = 22, perception = 3, dodge = 2,
		attributes = {str = 55, dex = 68, agi = 62, con = 70,
			int = 84, cha = 78, mag = 88},
		learned = {spellcasting = 9},
		spells = ["heal", "resurrect", "haste", "aegis"],
		attack = 2, defense = 4, weapon = "1d4",
		attack_range = 1, ai = "mend", leash = 5,
		act_cd = 2.0, move_cd = 1.2,
		hex = TOWERS.healer,            # upper-mid support tower
		elevated = true,
	},
]

## ---- SCENE: hero action bar -----------------------------------------
## Which abilities each hero exposes on the contextual action bar, in
## slot order (keys 1-5). The targeting MODE of each ability comes from
## `Targeting.mode_of(SPELLS[id])`. Meteor stays off the bar
## (experimental) but key 5 arms it for testing.
const HERO_ABILITIES := {
	wizard = ["fireball", "lightning", "blizzard", "teleport"],
	healer = HEALER_SPELLS,
	warrior = [],
	barbarian = [],
	archer = [],
}

## ---- SCENE: enemy spawn --------------------------------------------
## The far end of the road, upper-right. Individuals are dealt these in
## order; they are all on the road.
const SPAWN_HEXES := [
	Vector2i(15, 10), Vector2i(15, 9), Vector2i(16, 10),
	Vector2i(14, 10), Vector2i(14, 9), Vector2i(16, 9),
	Vector2i(15, 11), Vector2i(14, 11),
]

## ---- ENEMY ARCHETYPES ----------------------------------------------
## BASE stats. Every individual gets a bounded ±20% roll on its INNATE
## stats (pools, attributes, Perception) at spawn, fixed for life —
## see sim/enemy.gd. Equipment is discrete and never scaled.
##
## Distinct tiers are their OWN archetypes, never a high-rolled Skeleton.
##
## Susceptibility (spec §7): exposed bone takes ~20% LESS from pierce —
## an arrow passes between ribs rather than through tissue. This is a
## creature property, not extra armor, and it applies to ANY pierce
## source, not just the Archer.
const VARIATION := 0.20
const SKELETON_RESIST := {pierce = 0.80}

const ENEMY_ARCHETYPES := {
	"skeleton": {
		display_name = "Skeleton", faction = "enemy",
		lp = 10, ap = 8, perception = 3, dodge = 2,
		attack = 10, defense = 2, weapon = "claws",
		attack_range = 1, ai = "march",
		act_cd = 2.4, move_cd = 1.5,
		resist = SKELETON_RESIST,
		variation = VARIATION,
	},
	"skeleton_archer": {
		display_name = "Skeleton Archer", faction = "enemy",
		lp = 9, ap = 8, perception = 6, dodge = 3,
		attack = 8, defense = 2, weapon = "bow",
		attack_range = 8, ai = "shoot", leash = 9,
		act_cd = 2.8, move_cd = 1.4,
		resist = SKELETON_RESIST,
		variation = VARIATION,
	},
	"skeleton_warrior": {
		display_name = "Skeleton Warrior", faction = "enemy",
		lp = 14, ap = 10, perception = 3, dodge = 1,
		attack = 11, defense = 4, weapon = "sword",
		attack_range = 1, ai = "march",
		act_cd = 2.6, move_cd = 1.6,
		armor = {lp = 2},
		# plate conducts; armor eats impact; bone still shrugs at cold
		resist = {pierce = 0.80, electrical = 1.5, impact = 0.75},
		variation = VARIATION,
	},
	"ogre": {
		display_name = "Ogre", faction = "enemy",
		lp = 26, ap = 14, perception = 2, dodge = 0,
		attack = 14, defense = 3, weapon = "club",
		attack_range = 1, ai = "march",
		act_cd = 3.2, move_cd = 2.0,
		armor = {lp = 3},
		# living mass: burns; shrugs off impact. Ranged weapons are
		# effective against it through its POOR DODGE and its size, not
		# through an invented damage bonus.
		resist = {fire = 1.25, impact = 0.5},
		variation = VARIATION,
	},
	"goblin": {
		display_name = "Goblin", faction = "enemy",
		lp = 6, ap = 10, perception = 8, dodge = 7,
		attack = 7, defense = 1, weapon = "knife",
		attack_range = 1, ai = "march",
		act_cd = 1.6, move_cd = 0.9,
		resist = {},
		variation = VARIATION,
	},
}

## ---- WAVES ----------------------------------------------------------
## Composition per group. PROVISIONAL — the point is that each wave asks a
## different tactical question rather than raising a number.
const WAVES := [
	{skeleton = 4},
	{skeleton = 4, skeleton_archer = 1},
	{skeleton = 3, skeleton_warrior = 2},
	{skeleton = 4, skeleton_archer = 2, ogre = 1},
	{skeleton = 4, skeleton_warrior = 2, skeleton_archer = 1, ogre = 1},
	{goblin = 6, skeleton = 2},
]

## Group N -> composition. Past the authored table the last wave repeats
## with one more Skeleton per group — the encounter never dead-ends, and
## the escalation stays visible rather than hidden in a multiplier.
static func wave_for(group: int) -> Dictionary:
	var i: int = clampi(group - 1, 0, WAVES.size() - 1)
	var comp: Dictionary = WAVES[i].duplicate()
	if group > WAVES.size():
		comp["skeleton"] = int(comp.get("skeleton", 0)) \
			+ (group - WAVES.size())
	return comp

## Build the full roster for one group: the five heroes (identical every
## group — they are the same people) plus this wave's individuals.
static func build_roster(rng, group := 1) -> Array:
	var out: Array = HEROES.duplicate(true)
	for id in out:
		id.objective_id = ""
	out.append_array(
		Enemy.build_wave(ENEMY_ARCHETYPES, wave_for(group), rng,
			SPAWN_HEXES, group))
	for e in out:
		if String(e.get("faction", "")) == "enemy":
			e.objective_id = KEEP_ID
	return out

## ---- dressing --------------------------------------------------------
## Purely decorative: every entry has no `blocks`, so it changes no
## occupancy. Off-road cells are cliff and forest anyway; these are the
## rocks and timber that make that read.
const FIELD_PROPS := [
	{kind = "rubble_large", pos = Vector3(44.0, 0, 18.0), rot = 0.4},
	{kind = "rubble_half", pos = Vector3(33.0, 0, -16.0), rot = 1.1},
	{kind = "trunk_large_A", pos = Vector3(24.0, 0, 16.0), rot = 0.2},
	{kind = "trunk_large_A", pos = Vector3(9.0, 0, 17.0), rot = 1.4},
	{kind = "box_stacked", pos = Vector3(-1.0, 0, -14.0), rot = 0.7},
	{kind = "barrel_large", pos = Vector3(-3.0, 0, 14.0), rot = 0.3},
	{kind = "keg", pos = Vector3(20.0, 0, -16.0), rot = 1.0},
	{kind = "crates_stacked", pos = Vector3(30.0, 0, 14.0), rot = 0.5},
]
