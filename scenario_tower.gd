extends RefCounted
## Althar's Keep — Tower: the tower scenario.
##
## A SCENARIO module supplies only the things that describe a battlefield:
## the grid, the roster and their spawn hexes, the terrain occupancy rule,
## the elevation rule, and the loot/wave rewards. Everything that is a
## RULE — melee DCs, regen rates, weapon dice, spell blocks, progression
## tables, Table M, item definitions — is re-exported by reference from
## the shared `sim/config.gd` below.
##
## Why re-export instead of copying (the `scripts/cfg_proof.gd` mistake):
## a hand-copied rule table silently goes stale — cfg_proof.gd already
## disagrees with the live config on Fireball dice, learned ceilings and
## the support-spell roster. `const X := Shared.X` is a compile-time
## reference to the SAME value, so this scenario can never drift from
## Althar's Keep's rules. The two games share one rules engine, one
## tuning surface, one bug fix.
##
## Geometry note: `col(h) = 2*h.x + h.y` is proportional to world X
## (x = col * HEX_SIZE * sqrt(3)/2 * WORLD_SCALE), which is why the keep
## uses the same expression for its wall band and keep column. The
## corridor below is therefore a straight east-west band in world space.

const Shared = preload("res://sim/config.gd")
const Hex = preload("res://sim/hex.gd")

## ---- SHARED RULES (references, never copies) ----------------------
const PROGRESSION := Shared.PROGRESSION
const MELEE := Shared.MELEE
const CRITICALS := Shared.CRITICALS
const WEAPONS := Shared.WEAPONS
const BOW := Shared.BOW
const FEEDBACK := Shared.FEEDBACK
const SPELLS := Shared.SPELLS
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

## Hex -> world mapping is shared so both games place actors identically.
const HEX_SIZE := Shared.HEX_SIZE
const HEX_SQUASH := Shared.HEX_SQUASH
const WORLD_SCALE := Shared.WORLD_SCALE

## ---- SCENARIO: corridor geometry -----------------------------------
const SEED := 12345

const GRID_CENTER := Vector2i(5, 0)
const GRID_RADIUS := 13

const TOWER_FACE_COL := -8     # col <= -8  -> the tower's mass
const WALL_COL := -7           # col == -7  -> battlement walk (elevated)
const CORRIDOR_HALF_R := 5     # |r| > 5    -> cliff walls
const CORRIDOR_END_COL := 30   # col > 30   -> the far treeline

## The tower as a place, not yet as a damageable object. Phase 4 turns
## this into a simulated Structure (README §48); nothing reads it yet
## beyond presentation framing.
const TOWER := {
	name = "The Gate Tower",
	face_col = TOWER_FACE_COL,
	walk_col = WALL_COL,
	# Height of the battlement walk in metres — the top of the KayKit
	# wall piece the curtain is built from. Presentation reads it to
	# stand posted actors on the walk rather than inside the masonry;
	# simulation ignores it (elevation is `wall_kind`, not a height).
	walk_h = 4.0,
	# INTACT -> DAMAGED -> HEAVILY DAMAGED -> BREACHED (README §48).
	# Not simulated yet — declared so the presentation can already be
	# built against the real shape.
	states = ["INTACT", "DAMAGED", "HEAVILY_DAMAGED", "BREACHED"],
}

## ---- SCENARIO: cover in the corridor -------------------------------
## KayKit Dungeon props (CC0) — the same low-poly language the frozen
## 0.2 build used, not the cinematic `assets/nature` photogrammetry.
## Kept clear of every spawn hex and the gate line: a prop that landed
## on a spawn would make the roster unplaceable. `pos` is world metres.
const FIELD_PROPS := [
	{kind = "barrier", pos = Vector3(6.0, 0, 3.0), rot = 0.3,
		line = 2.2, blocks = 0.8},
	{kind = "rubble_large", pos = Vector3(9.5, 0, -3.5), rot = -0.5,
		blocks = 1.0},
	{kind = "trunk_large_A", pos = Vector3(12.0, 0, 2.5), rot = 0.4,
		blocks = 1.0},
	{kind = "box_large", pos = Vector3(19.0, 0, -2.0), rot = 0.2,
		blocks = 0.9},
]

## Whole-cell occupancy: a cell is occupied when it is inside the tower
## mass, outside the corridor (cliff), or beyond the treeline. Occupied
## cells stay in `valid` — they are real hexes with something in them
## (the Hex Integrity rule).
static func cell_blocked(h: Vector2i) -> bool:
	var col: int = 2 * h.x + h.y
	if col <= TOWER_FACE_COL:
		return true
	if col > CORRIDOR_END_COL:
		return true
	if absi(h.y) > CORRIDOR_HALF_R:
		return true
	for p in FIELD_PROPS:
		var pr: float = p.get("blocks", 0.0)
		if pr <= 0.0:
			continue
		var c := Hex.to_world(h, HEX_SIZE, HEX_SQUASH) * WORLD_SCALE
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

## Elevation: the battlement walk is level 1. Melee and movement never
## cross levels, so a posted archer or the Wizard cannot be reached from
## the ground and cannot strike down into it.
static func wall_kind(h: Vector2i) -> int:
	return 1 if (2 * h.x + h.y) == WALL_COL else 0

## ---- SCENARIO: the roster ------------------------------------------
## Five heroes hold the tower end; the first enemy group walks in from
## the treeline. Pools/attributes/learned values are the SAME authored
## Level-1 values Althar's Keep uses — the heroes are the same people.
## Only `hex`, `anchor`, `deployed` and `elevated` are scenario data.
const ACTORS := [
	{
		id = "wizard", display_name = "Althar", faction = "friendly",
		lp = 12, ap = 16, mp = 20, perception = 0, dodge = 0,
		defense = 3,
		attributes = {str = 45, dex = 65, agi = 55, con = 55,
			int = 92, cha = 80, mag = 96},
		learned = {spellcasting = 10},
		hex = Vector2i(-4, 1),          # col -7 — on the battlement
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
		hex = Vector2i(-2, 1),          # the gate approach
	},
	{
		id = "barbarian", display_name = "Barbarian", faction = "friendly",
		lp = 15, ap = 12, perception = 3, dodge = 2,
		attributes = {str = 93, dex = 70, agi = 65, con = 82,
			int = 45, cha = 55, mag = 5},
		attack = 7, defense = 3, block = 0, weapon = "axe",
		attack_range = 1, ai = "brawl", leash = 2,
		act_cd = 1.7, move_cd = 1.2,
		# In reserve behind the gate. NOTE: in the shared sim `deployed`
		# gates only healer triage and encounter XP — it does NOT stop a
		# hero engaging. A reserve therefore still fights anything that
		# reaches his leash, so his leash is deliberately short: he is
		# the last line until Teleport commits him forward.
		deployed = false,
		hex = Vector2i(1, -1),
	},
	{
		id = "archer", display_name = "Archer", faction = "friendly",
		lp = 12, ap = 16, perception = 5, dodge = 3,
		attributes = {str = 55, dex = 92, agi = 88, con = 65,
			int = 72, cha = 70, mag = 10},
		learned = {attack = 10, defense = 8, resistance = 6},
		weapon = "bow", attack_range = 8, ai = "shoot", leash = 8,
		act_cd = 2.6, move_cd = 1.0,
		hex = Vector2i(-5, 3),          # col -7 — the tower's firing post
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
		hex = Vector2i(-1, 3),
	},
	{
		id = "skeleton_a", display_name = "Skeleton A", faction = "enemy",
		lp = 8, ap = 8, perception = 3, dodge = 2,
		attack = 10, attack_var = "1d5-1", defense = 2, weapon = "claws",
		attack_range = 1, ai = "advance", act_cd = 2.4, move_cd = 1.5,
		hex = Vector2i(13, 0),
	},
	{
		id = "skeleton_b", display_name = "Skeleton B", faction = "enemy",
		lp = 8, ap = 8, perception = 6, dodge = 4,
		attack = 10, attack_var = "1d5-1", defense = 2, weapon = "claws",
		attack_range = 1, ai = "advance", act_cd = 2.4, move_cd = 1.5,
		hex = Vector2i(13, -1),
	},
	{
		id = "skeleton_c", display_name = "Skeleton C", faction = "enemy",
		lp = 8, ap = 8, perception = 9, dodge = 6,
		attack = 10, attack_var = "1d5-1", defense = 2, weapon = "claws",
		attack_range = 1, ai = "advance", act_cd = 2.4, move_cd = 1.5,
		hex = Vector2i(14, 0),
	},
	{
		id = "skeleton_d", display_name = "Skeleton D", faction = "enemy",
		lp = 8, ap = 8, perception = 4, dodge = 3,
		attack = 10, attack_var = "1d5-1", defense = 2, weapon = "claws",
		attack_range = 1, ai = "advance", act_cd = 2.4, move_cd = 1.5,
		hex = Vector2i(14, -2),
	},
	{
		id = "skeleton_e", display_name = "Skeleton E", faction = "enemy",
		lp = 8, ap = 8, perception = 7, dodge = 5,
		attack = 10, attack_var = "1d5-1", defense = 2, weapon = "claws",
		attack_range = 1, ai = "advance", act_cd = 2.4, move_cd = 1.5,
		hex = Vector2i(13, 2),
	},
	{
		id = "skeleton_f", display_name = "Skeleton F", faction = "enemy",
		lp = 8, ap = 8, perception = 5, dodge = 4,
		attack = 10, attack_var = "1d5-1", defense = 2, weapon = "claws",
		attack_range = 1, ai = "advance", act_cd = 2.4, move_cd = 1.5,
		hex = Vector2i(12, 3),
	},
]

## ---- SCENARIO: rewards ---------------------------------------------
const ENCOUNTER_XP := Shared.ENCOUNTER_XP
const LOOT := Shared.LOOT
