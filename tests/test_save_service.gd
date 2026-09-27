extends RefCounted
## SaveService coverage: versioned slots, the autosave file, the active
## slot index, the between-waves guard, corruption/schema versioning —
## and an EXACT round-trip of a real Scenario battle: heroes' pools,
## inventory, the Keep's Integrity, and a generated wave's individuals
## (ids, rolled max_lp, alive flags, hexes, corpse loot).
##
## The service is pointed at a fresh /tmp directory through its
## constructor arg — nothing here ever touches user://.

const SaveService = preload("res://scripts/save_service.gd")
const Scenario = preload("res://scenario_tower.gd")
const Battle = preload("res://sim/battle.gd")
const Items = preload("res://sim/items.gd")

const DIR := "/tmp/tower_test_saves"


func _wipe(dir: String) -> void:
	if DirAccess.dir_exists_absolute(dir):
		var da := DirAccess.open(dir)
		for f in da.get_files():
			da.remove(f)
		DirAccess.remove_absolute(dir)


func _enemy_map(sim) -> Dictionary:
	var out := {}
	for id in sim.actor_order:
		var a = sim.actors[id]
		if a.faction == "enemy":
			out[id] = a
	return out


func _assert_enemies_equal(t, expect: Dictionary, got: Dictionary,
		label: String) -> void:
	var got_ids := got.keys()
	var expect_ids := expect.keys()
	got_ids.sort()
	expect_ids.sort()
	t.eq(got_ids, expect_ids,
		"%s: restored enemy id set matches" % label)
	for id in expect:
		if not got.has(id):
			continue
		var e = expect[id]
		var g = got[id]
		t.eq(g.max_lp, e.max_lp, "%s: %s rolled max_lp" % [label, id])
		t.eq(g.alive, e.alive, "%s: %s alive" % [label, id])
		t.eq(g.hex, e.hex, "%s: %s hex" % [label, id])
		# JSON turns ints into floats and StringName keys into Strings —
		# compare the loot's VALUES, not the dictionaries' types
		t.eq(int(g.loot.get("gold", -1)), int(e.loot.get("gold", -1)),
			"%s: %s corpse gold" % [label, id])
		t.eq(String(g.loot.get("item", "")), String(e.loot.get("item", "")),
			"%s: %s corpse item" % [label, id])
		t.eq(g.loot_available, e.loot_available,
			"%s: %s loot_available" % [label, id])


## A wave-2 battle in a deterministic between-waves state: one dead,
## looted skeleton, one enemy walked a step, wounded heroes, spent MP,
## gold and a held item, and the Keep damaged. `encounter_done` is left
## true so the slot writes are legal.
func _dirty_wave2_battle():
	var sim = Battle.create(Scenario, Callable(Scenario, "build_roster"))
	sim.encounter_done = true
	sim.next_group()                       # wave 2, new generated ids
	var foes: Array = sim.living_enemies()
	var dead = foes[0]
	dead.apply_damage(999)
	dead.loot = {gold = 7, item = "Bone Charm"}
	dead.loot_available = true
	# a survivor partway down the road — position must round-trip
	var mover = foes[1]
	var step: Vector2i = mover.hex + Vector2i(-1, 0)
	if sim.hex_free(step):
		mover.hex = step
	sim.actors.warrior.lp -= 5
	sim.actors.warrior.ap -= 3
	sim.actors.wizard.mp -= 4
	sim.inventory.gold = 137
	Items.add(sim.inventory, "Rusty Sword", 1)
	sim.structures["keep"].apply_damage(40)
	sim.encounter_done = true
	return sim


func run(t) -> void:
	_wipe(DIR)
	var svc = SaveService.new(DIR)
	var sim = Battle.create(Scenario, Callable(Scenario, "build_roster"))

	# ---- the between-waves guard ------------------------------------
	var res: Array = svc.save("slot_1", sim)
	t.check(not res[0], "mid-wave save is refused")
	t.eq(res[1], "between_waves", "refusal reason is between_waves")
	res = svc.autosave(sim)
	t.check(not res[0] and res[1] == "between_waves",
		"mid-wave autosave refused with between_waves")
	res = svc.quick_save(sim)
	t.check(not res[0] and res[1] == "no_active_slot",
		"quick_save with no active slot -> no_active_slot")
	svc.set_active("slot_3")
	res = svc.quick_save(sim)
	t.check(not res[0] and res[1] == "between_waves",
		"mid-wave quick_save refused even with an active slot")
	svc.set_active("")

	# ---- a real between-waves save ----------------------------------
	sim = _dirty_wave2_battle()
	var expect_enemies := _enemy_map(sim)
	res = svc.save("slot_1", sim)
	t.check(res[0] == true, "between-waves save to slot_1 succeeds")
	t.check(FileAccess.file_exists(DIR + "/slot_1.json"),
		"slot_1.json exists")
	t.check(not FileAccess.file_exists(DIR + "/autosave.json"),
		"a manual save does not write autosave.json")

	# ---- listing -----------------------------------------------------
	var rows: Array = svc.list_slots()
	t.eq(rows.size(), 6, "six manual slot rows")
	t.eq(rows[0].name, "slot_1", "first row is slot_1")
	t.check(not rows[0].empty, "slot_1 row is occupied")
	t.eq(rows[0].schema, 1, "row reports schema 1")
	t.eq(rows[0].wave, 2, "row reports the wave")
	t.check(String(rows[0].party_text).contains("Althar"),
		"row party text names Althar")
	t.check(rows[1].empty, "slot_2 row is empty")

	# ---- load restores the battle EXACTLY ----------------------------
	var loaded: Array = svc.load_slot("slot_1")
	t.check(not loaded[0].is_empty(), "slot_1 loads")
	t.eq(String(loaded[0].get("scene", "")), "tower_scene01",
		"envelope names the tower scene")
	var party: Dictionary = loaded[0].get("party", {})
	t.check(party.has("wizard"), "party entry for the wizard")
	t.eq(int(party.wizard.get("level", -1)), sim.actors.wizard.progress.level,
		"party records the wizard's level")
	var fresh = Battle.create(Scenario, Callable(Scenario, "build_roster"))
	fresh.apply_save(loaded[0].battle)
	t.eq(fresh.group_index, 2, "group_index restored (wave 2)")
	t.eq(fresh.structures["keep"].integrity,
		sim.structures["keep"].integrity, "keep integrity restored")
	t.eq(fresh.actors.warrior.lp, sim.actors.warrior.lp,
		"warrior lp restored")
	t.eq(fresh.actors.warrior.ap, sim.actors.warrior.ap,
		"warrior ap restored")
	t.eq(fresh.actors.wizard.mp, sim.actors.wizard.mp,
		"wizard mp restored")
	t.eq(fresh.inventory.gold, 137, "inventory gold restored")
	t.eq(Items.count(fresh.inventory, "Rusty Sword"), 1,
		"held item restored")
	_assert_enemies_equal(t, expect_enemies, _enemy_map(fresh), "load")

	# ---- save -> load -> save -> load, twice ------------------------
	var b2 = Battle.create(Scenario, Callable(Scenario, "build_roster"))
	b2.apply_save(loaded[0].battle)
	res = svc.save("slot_2", b2)
	t.check(res[0] == true, "re-saving a loaded battle is legal")
	var loaded2: Array = svc.load_slot("slot_2")
	var b3 = Battle.create(Scenario, Callable(Scenario, "build_roster"))
	b3.apply_save(loaded2[0].battle)
	t.eq(b3.group_index, 2, "second round-trip keeps the wave")
	_assert_enemies_equal(t, expect_enemies, _enemy_map(b3),
		"second round-trip")

	# ---- active slot + quick_save ------------------------------------
	svc.set_active("slot_2")
	t.eq(svc.active(), "slot_2", "index.json records the active slot")
	res = svc.quick_save(sim)
	t.check(res[0] == true, "quick_save writes the active slot")

	# ---- autosave is its own file ------------------------------------
	res = svc.autosave(sim)
	t.check(res[0] == true, "autosave succeeds between waves")
	t.check(FileAccess.file_exists(DIR + "/autosave.json"),
		"autosave.json written")
	t.check(svc.latest_valid() != "",
		"latest_valid finds a save for boot CONTINUE")
	var auto: Array = svc.load_slot("autosave")
	t.check(not auto[0].is_empty(), "the autosave loads like a slot")

	# ---- corrupt and foreign files -----------------------------------
	var bad := FileAccess.open(DIR + "/slot_4.json", FileAccess.WRITE)
	bad.store_string("this is { not json")
	bad.close()
	var row := svc.slot_info("slot_4")
	t.check(row.corrupt, "unparseable slot flagged corrupt")
	t.check(not row.empty, "corrupt slot is not 'empty'")
	res = svc.load_slot("slot_4")
	t.check(res[0].is_empty() and res[1] == "unreadable",
		"corrupt slot loads as unreadable")
	var future := FileAccess.open(DIR + "/slot_5.json", FileAccess.WRITE)
	future.store_string(JSON.stringify({schema = 999, battle = {}}))
	future.close()
	t.check(svc.slot_info("slot_5").corrupt,
		"newer schema flagged corrupt, not loaded")
	res = svc.load_slot("slot_5")
	t.check(res[0].is_empty() and res[1] == "unreadable",
		"schema 999 -> unreadable")
	res = svc.load_slot("slot_6")
	t.check(res[0].is_empty() and res[1] == "missing",
		"never-written slot -> missing")

	# ---- --nosave: the service exists but touches nothing -------------
	var dead_dir := DIR + "_disabled"
	_wipe(dead_dir)
	var nosv = SaveService.new(dead_dir, false)
	t.check(not nosv.enabled, "nosave service reports disabled")
	res = nosv.save("slot_1", sim)
	t.check(not res[0], "disabled service refuses to write")
	t.check(not nosv.has_saves(), "disabled service has no saves")
	nosv.autosave(sim)
	nosv.set_active("slot_1")
	t.check(not DirAccess.dir_exists_absolute(dead_dir),
		"disabled service never creates its directory")

	_wipe(DIR)
