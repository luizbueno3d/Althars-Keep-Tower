extends SceneTree
## Phase 0 acceptance probe for Althar's Keep — Tower.
##   tools/probe.sh
##
## Proves, headlessly and deterministically, that:
##   1. the SHARED rules engine loads from this project (no local copy),
##   2. the tower scenario satisfies the config contract the sim needs,
##   3. the corridor geometry is sound and no actor spawns in an obstacle,
##   4. the shared rule tables are the LIVE ones (not a stale copy),
##   5. the real combat clock walks the enemy group down the corridor.

var _fail := 0

func _check(ok: bool, label: String, detail := "") -> void:
	if ok:
		print("  ok    %s%s" % [label, ("  — " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL  %s%s" % [label, ("  — " + detail) if detail else ""])

func _init() -> void:
	var Shared = load("res://sim/config.gd")
	var Scenario = load("res://scenario_tower.gd")
	var Battle = load("res://sim/battle.gd")
	var Combat = load("res://sim/combat.gd")
	var Hex = load("res://sim/hex.gd")

	print("\n== 1. shared rules engine ==")
	_check(Shared != null, "sim/config.gd loads through the symlink")
	_check(Scenario != null, "scenario_tower.gd loads")

	print("\n== 2. config contract the sim reads ==")
	for k in ["ACTORS", "SEED", "GRID_CENTER", "GRID_RADIUS", "MELEE",
			"PROGRESSION", "SPELLS", "WEAPONS", "CRITICALS",
			"ENCOUNTER_XP", "LOOT", "HEX_SIZE", "HEX_SQUASH"]:
		_check(Scenario.get(k) != null, "scenario.%s" % k)
	_check(Scenario.wall_kind(Vector2i(0, 0)) is int, "scenario.wall_kind()")
	_check(Scenario.cell_blocked(Vector2i(0, 0)) is bool, "scenario.cell_blocked()")

	print("\n== 3. shared tables are the LIVE ones, not a stale copy ==")
	_check(Scenario.MELEE == Shared.MELEE, "MELEE is the same object")
	_check(Scenario.PROGRESSION == Shared.PROGRESSION, "PROGRESSION is the same object")
	_check(Scenario.SPELLS == Shared.SPELLS, "SPELLS is the same object")
	_check(Scenario.FIREBALL.damage == Shared.FIREBALL.damage,
		"Fireball dice match the live config",
		"%s" % Scenario.FIREBALL.damage)
	_check(Scenario.PROGRESSION.learned["attack"].ceiling
		== Shared.PROGRESSION.learned["attack"].ceiling,
		"learned ceilings match (cfg_proof.gd is already stale here)",
		"%s" % Scenario.PROGRESSION.learned["attack"].ceiling)
	_check(Scenario.HEALER_SPELLS.size() == 4,
		"support-spell kit present", "%s" % [Scenario.HEALER_SPELLS])

	print("\n== 4. build the tower battle ==")
	var b = Battle.create(Scenario)
	_check(b.actor_order.size() == Scenario.ACTORS.size(),
		"every actor placed", "%d actors" % b.actor_order.size())
	_check(b.valid.size() > 0, "grid built", "%d cells" % b.valid.size())
	_check(b.obstacles.size() > 0, "occupancy applied",
		"%d occupied cells" % b.obstacles.size())
	_check(b.wall.size() > 0, "elevation applied",
		"%d elevated cells" % b.wall.size())

	print("\n== 5. corridor geometry ==")
	var corridor := 0
	for h in b.valid:
		if not b.obstacles.has(h):
			corridor += 1
	_check(corridor > 0, "walkable corridor cells", "%d" % corridor)
	# the corridor must be a band: nothing walkable beyond the treeline
	# or past the cliff walls
	var stray := 0
	for h in b.valid:
		if b.obstacles.has(h):
			continue
		if 2 * h.x + h.y > Scenario.CORRIDOR_END_COL \
				or absi(h.y) > Scenario.CORRIDOR_HALF_R:
			stray += 1
	_check(stray == 0, "no walkable cell escapes the corridor",
		"%d strays" % stray)

	print("\n== 6. every spawn hex is free ==")
	var bad := 0
	for id in b.actor_order:
		var a = b.actors[id]
		if b.obstacles.has(a.hex) or not b.hex_in_grid(a.hex):
			bad += 1
			print("      spawn blocked: %s at %s" % [id, a.hex])
	_check(bad == 0, "no actor spawns inside an obstacle or off-grid")

	print("\n== 7. the tower posts are elevated ==")
	for id in ["wizard", "archer"]:
		var a = b.actors[id]
		_check(b.is_wall(a.hex), "%s posted on the battlement" % id,
			"wall_kind %d at %s" % [b.wall_kind(a.hex), a.hex])
	var w = b.actors["warrior"]
	_check(not b.is_wall(w.hex), "Warrior holds the ground at the gate")

	print("\n== 8. the enemy group walks the corridor ==")
	var start_col := {}
	for id in b.actor_order:
		var a = b.actors[id]
		if a.faction == "enemy":
			start_col[id] = 2 * a.hex.x + a.hex.y
	var t := 0.0
	var closest := 999          # closest the enemy line ever got, sampled live
	var first_contact := -1.0
	while t < 90.0:
		Combat.update(b, 0.05)
		t += 0.05
		for id in b.actor_order:
			var a = b.actors[id]
			if a.faction != "enemy" or not a.alive:
				continue
			closest = mini(closest, 2 * a.hex.x + a.hex.y)
			if first_contact < 0.0:
				for fid in b.actor_order:
					var f = b.actors[fid]
					if f.faction == "friendly" and f.alive \
							and Hex.distance(f.hex, a.hex) <= 1:
						first_contact = t
	var advanced := 0
	for id in start_col:
		var a = b.actors[id]
		if not a.alive:
			advanced += 1
			continue
		if 2 * a.hex.x + a.hex.y < int(start_col[id]):
			advanced += 1
	_check(advanced > 0, "enemies closed on the tower",
		"%d of %d advanced or died" % [advanced, start_col.size()])
	print("      enemy start col=%s  closest col reached=%s  first contact=%s" % [
		start_col.values().max(),
		closest if closest < 999 else "n/a",
		"%.1fs" % first_contact if first_contact >= 0.0 else "none"])
	_check(closest < int(start_col.values().max()),
		"the enemy line actually moved west",
		"col %d -> %d" % [start_col.values().max(), closest])
	_check(not b.living_enemies().is_empty() or b.encounter_done,
		"encounter state is coherent",
		"living=%d done=%s" % [b.living_enemies().size(),
			b.encounter_done])

	print("\n== 9. sim stays pure (no engine deps in sim/) ==")
	var gd := DirAccess.open("res://sim")
	var pure := true
	if gd == null:
		pure = false
	else:
		for f in gd.get_files():
			if not f.ends_with(".gd"):
				continue
			var src := FileAccess.get_file_as_string("res://sim/" + f)
			for pat in ["extends Node", "get_tree()", "SceneTree.new",
					"preload(\"res://scripts"]:
				if pat in src:
					pure = false
					print("      engine dependency in sim/%s: %s" % [f, pat])
	_check(pure, "no sim/ module extends Node or touches the SceneTree")

	print("")
	if _fail == 0:
		print("PROBE OK — the shared rules engine runs the tower scenario.")
		quit(0)
	else:
		print("PROBE FAILED — %d check(s) failed." % _fail)
		quit(1)
