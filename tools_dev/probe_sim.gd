extends SceneTree
## Scene 01 acceptance probe for Althar's Keep — Tower.
##   tools/probe.sh
##
## Headless, deterministic. Proves the scene is a REAL tower-defence
## battlefield before any art polish:
##   1. the shared rules engine loads and is in sync,
##   2. the scenario satisfies the config contract the sim reads,
##   3. the road is one connected route from the spawn to the Keep,
##   4. every hero and every enemy spawn is placeable,
##   5. the two towers are off-road, walkable and elevated,
##   6. waves change composition and individuals really vary,
##   7. an enemy group walks the road and damages the Keep's Integrity.

var _fail := 0

func _check(ok: bool, label: String) -> void:
	if ok:
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)

func _info(label: String, value) -> void:
	print("        %-34s %s" % [label, str(value)])

func _init() -> void:
	var Shared = load("res://sim/config.gd")
	var S = load("res://scenario_tower.gd")
	var Battle = load("res://sim/battle.gd")
	var Combat = load("res://sim/combat.gd")
	var Hex = load("res://sim/hex.gd")

	print("\n== 1. shared rules engine ==")
	_check(Shared != null, "sim/config.gd loads")
	_check(S != null, "scenario_tower.gd loads")
	_check(S.MELEE == Shared.MELEE, "MELEE is the same object (not a copy)")
	_check(S.PROGRESSION == Shared.PROGRESSION, "PROGRESSION is the same object")
	_check(S.SPELLS == Shared.SPELLS, "SPELLS is the same object")

	print("\n== 2. config contract ==")
	for k in ["HEROES", "SEED", "GRID_CENTER", "GRID_RADIUS",
			"MELEE", "PROGRESSION", "SPELLS", "WEAPONS", "CRITICALS",
			"ENCOUNTER_XP", "LOOT", "HEX_SIZE", "HEX_SQUASH",
			"STRUCTURES", "ROAD", "TOWERS", "ENEMY_ARCHETYPES",
			"WAVES", "FIELD_PROPS"]:
		_check(S.get(k) != null, "scenario.%s" % k)
	_check(S.wall_kind(Vector2i.ZERO) is int, "scenario.wall_kind()")
	_check(S.cell_blocked(Vector2i.ZERO) is bool, "scenario.cell_blocked()")
	_check(S.build_roster(_seeded(), 1) is Array, "scenario.build_roster()")

	print("\n== 3. build the battle through the roster builder ==")
	var b = Battle.create(S, Callable(S, "build_roster"))
	var heroes := 0
	var enemies := 0
	for id in b.actor_order:
		if b.actors[id].faction == "friendly":
			heroes += 1
		else:
			enemies += 1
	_info("heroes", heroes)
	_info("enemies (wave 1)", enemies)
	_info("grid cells", b.valid.size())
	_info("occupied cells", b.obstacles.size())
	_info("elevated cells", b.wall.size())
	_check(heroes == 5, "all five heroes are on the field")
	_check(enemies == S.wave_for(1).values().reduce(
		func(a, c): return a + int(c), 0), "wave 1 composition is complete")
	_check(b.structures.size() == 1, "the Keep exists as a structure")
	_check(not b.actors.has("keep"), "the Keep is not an actor")

	print("\n== 4. every spawn is placeable ==")
	var blocked := 0
	for id in b.actor_order:
		var a = b.actors[id]
		if b.obstacles.has(a.hex) or not b.hex_in_grid(a.hex):
			blocked += 1
			print("        BLOCKED: %s at %s" % [id, a.hex])
	_check(blocked == 0, "no actor spawns inside an obstacle or off-grid")

	print("\n== 5. the Keep top and the two towers ==")
	var wiz = b.actors["wizard"]
	var arc = b.actors["archer"]
	var hea = b.actors["healer"]
	_check(b.is_wall(wiz.hex), "Althar stands on the Keep top")
	_check(b.wall_kind(wiz.hex) == 2, "the Keep top is its own level")
	_check(b.is_wall(arc.hex), "the Archer stands on her tower")
	_check(b.is_wall(hea.hex), "the Healer stands on his tower")
	_check(not S._on_road(arc.hex), "the Archer tower is off the road")
	_check(not S._on_road(hea.hex), "the Healer tower is off the road")
	var war = b.actors["warrior"]
	var bar = b.actors["barbarian"]
	_check(S._on_road(war.hex), "the Warrior holds the road")
	_check(S._on_road(bar.hex), "the Barbarian holds the road")
	_check(not b.is_wall(war.hex) and not b.is_wall(bar.hex),
		"the ground heroes are on the ground, not on towers")
	_info("Archer tower", "%s  road distance %.1f m" % [arc.hex,
		S.road_distance(arc.hex)])
	_info("Healer tower", "%s  road distance %.1f m" % [hea.hex,
		S.road_distance(hea.hex)])

	print("\n== 6. the road is ONE connected route ==")
	# flood the walkable ground from the first spawn hex
	var start: Vector2i = S.SPAWN_HEXES[0]
	var keep_hex: Vector2i = b.structures["keep"].hex
	var seen := {start: true}
	var frontier: Array = [start]
	while not frontier.is_empty():
		var h: Vector2i = frontier.pop_back()
		for d in Hex.DIRECTIONS:
			var n: Vector2i = h + d
			if seen.has(n) or not b.hex_free(n):
				continue
			if b.is_wall(n):
				continue          # ground route only
			seen[n] = true
			frontier.append(n)
	_info("road cells reachable from spawn", seen.size())
	_check(seen.size() > 100, "the road is a substantial route")
	var adjacent := 0
	for d in Hex.DIRECTIONS:
		if seen.has(keep_hex + d):
			adjacent += 1
	_check(adjacent > 0,
		"the road reaches a cell adjacent to the Keep (%d of 6)" % adjacent)
	var spawn_on_road := 0
	for h in S.SPAWN_HEXES:
		if S._on_road(h):
			spawn_on_road += 1
	_check(spawn_on_road == S.SPAWN_HEXES.size(),
		"every enemy spawn hex is on the road")

	print("\n== 7. waves change, individuals vary ==")
	for g in [1, 2, 3, 4, 5, 6, 8]:
		_info("wave %d" % g, S.wave_for(g))
	_check(S.wave_for(1) != S.wave_for(4),
		"wave 4 asks a different question than wave 1")
	var w1 = S.build_roster(_seeded(), 1)
	var w2 = S.build_roster(_seeded(), 1)
	_check(w1.size() == w2.size(), "the same wave has the same size")
	var lps := {}
	for e in w1:
		if String(e.get("faction", "")) == "enemy":
			lps[e.lp] = true
	_info("distinct skeleton LP rolls", lps.keys())
	_check(lps.size() > 1,
		"individuals from one archetype roll different pools")
	var pierce_ok := true
	for e in w1:
		if String(e.get("id", "")).begins_with("skeleton") \
				and float(e.get("resist", {}).get("pierce", 1.0)) != 0.80:
			pierce_ok = false
	_check(pierce_ok, "skeletons carry the pierce response (0.80)")

	print("\n== 8. the group walks the road ==")
	var keep = b.structures["keep"]
	var full: int = keep.integrity
	var start_col := {}
	for id in b.actor_order:
		var a = b.actors[id]
		if a.faction == "enemy":
			start_col[id] = 2 * a.hex.x + a.hex.y
	var t := 0.0
	var closest := 999
	var contact := -1.0
	while t < 240.0:
		Combat.update(b, 0.05)
		t += 0.05
		for id in b.actor_order:
			var a = b.actors[id]
			if a.faction != "enemy" or not a.alive:
				continue
			closest = mini(closest, 2 * a.hex.x + a.hex.y)
			if contact < 0.0 and Hex.distance(a.hex, keep.hex) <= 1:
				contact = t
	_info("enemy start col", start_col.values().max())
	_info("closest col reached", closest)
	_info("surviving enemies", b.living_enemies().size())
	_check(closest < 20, "the enemy line advanced a long way down the road")
	# NOTE: this is the DEFENDED run. Whether the wave reaches the Keep is
	# a balance question, not a correctness one — wave 1 being stopped by
	# the Warrior is the defence working. The mechanism itself is proven
	# below on an undefended run.

	print("\n== 9. the assault mechanism (undefended run) ==")
	# Same scene, heroes removed: enemies must reach the Keep, damage its
	# INTEGRITY, and be able to break it. This isolates the mechanism from
	# whether the current balance lets a given wave through.
	var b2 = Battle.create(S, Callable(S, "build_roster"))
	for id in b2.actor_order.duplicate():
		if b2.actors[id].faction == "friendly":
			b2.actors.erase(id)
			b2.actor_order.erase(id)
	var k2 = b2.structures["keep"]
	var k2_full: int = k2.integrity
	var t2 := 0.0
	var hit_t := -1.0
	var lost := false
	while t2 < 400.0 and k2.alive:
		Combat.update(b2, 0.05)
		t2 += 0.05
		for e in b2.drain_events():
			if e.type == "structure_hit" and hit_t < 0.0:
				hit_t = t2
			if e.type == "structure_lost":
				lost = true
	_info("first Keep hit", "%.1fs" % hit_t if hit_t >= 0 else "never")
	_info("Keep integrity", "%d / %d" % [k2.integrity, k2_full])
	_info("Keep state", k2.state())
	_check(hit_t >= 0.0, "an unopposed enemy reaches the Keep and strikes it")
	_check(k2.integrity < k2_full, "Keep Integrity decreases when struck")
	_check(lost, "the Keep can be broken (structure_lost fires)")
	_check(b2.defense_lost, "breaking the Keep records the defence as lost")
	_check(k2.state() == "BREACHED", "a broken Keep reads BREACHED")

	print("\n== 10. sim stays pure ==")
	var gd := DirAccess.open("res://sim")
	var pure := true
	if gd != null:
		for f in gd.get_files():
			if not f.ends_with(".gd"):
				continue
			var src := FileAccess.get_file_as_string("res://sim/" + f)
			for pat in ["extends Node", "get_tree()", "SceneTree.new",
					"preload(\"res://scripts"]:
				if pat in src:
					pure = false
					print("        engine dependency in sim/%s: %s" % [f, pat])
	_check(pure, "no sim/ module extends Node or touches the SceneTree")

	print("")
	if _fail == 0:
		print("PROBE OK — Scene 01 is a real tower-defence battlefield.")
		quit(0)
	else:
		print("PROBE FAILED — %d check(s) failed." % _fail)
		quit(1)

func _seeded() -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = 4242
	return r
