extends RefCounted
## Versioned save slots for Althar's Keep — Tower (between-wave saving).
##
## Pure infrastructure: no Node/SceneTree APIs — FileAccess, DirAccess
## and Time only. No rules live here; the sim serializes itself through
## `battle.to_dict()` / `battle.apply_save()`.
##
## Storage layout under the save directory (default `user://saves/`):
##   slot_1.json .. slot_6.json   manual slots
##   autosave.json               written when a wave clears
##   index.json                  {active_slot, updated}
##
## An envelope is:
##   {schema, scene, saved_at, group_index,
##    party = {hero_id -> {level, xp_available, name}},
##    battle = sim.to_dict()}
##
## Writes are atomic — temp file then rename — so a crash mid-write can
## never corrupt the slot (the canonical save_store.gd discipline).
##
## This milestone saves BETWEEN WAVES only: every write refuses with
## "between_waves" while a group is in flight (`not sim.encounter_done`)
## rather than silently producing a mid-wave save the loader cannot
## honour yet (in-flight spells/zones do not serialize).
##
## Dev/test isolation: `SaveService.new(dir_path)` points the whole
## directory elsewhere; falling back to the TOWER_SAVE_DIR env var.
## `--nosave` constructs the service with `enabled = false` — every
## write is skipped and nothing on disk is touched.

const SCHEMA := 1
const SCENE_ID := "tower_scene01"
const SLOT_COUNT := 6
const AUTOSAVE := "autosave"

var enabled := true
var _dir := ""


func _init(dir_path := "", p_enabled := true) -> void:
	enabled = p_enabled
	if dir_path != "":
		_dir = dir_path
	else:
		var env := OS.get_environment("TOWER_SAVE_DIR")
		_dir = env if env != "" else "user://saves"


func slot_names() -> Array:
	var out: Array = []
	for i in SLOT_COUNT:
		out.append("slot_%d" % (i + 1))
	return out


func _path(name: String) -> String:
	return "%s/%s.json" % [_dir, name]


func _index_path() -> String:
	return "%s/index.json" % _dir


func _ensure_dir() -> void:
	if not DirAccess.dir_exists_absolute(_dir):
		DirAccess.make_dir_recursive_absolute(_dir)


## ---- listing -----------------------------------------------------

## One row per manual slot: {name, empty, schema, saved_at, wave,
## party_text, corrupt}. The autosave is deliberately NOT a row — the
## LOAD modal offers it separately through slot_info().
func list_slots() -> Array:
	var out: Array = []
	for name in slot_names():
		out.append(slot_info(name))
	return out


## Metadata for one slot file without restoring anything. Missing file
## -> {empty = true}; unparseable / foreign-schema file -> {corrupt}
## (never deleted, never overwritten by a LIST).
func slot_info(name: String) -> Dictionary:
	var row := {name = name, empty = false, schema = 0,
		saved_at = 0, wave = 0, party_text = "", corrupt = false}
	if not FileAccess.file_exists(_path(name)):
		row.empty = true
		return row
	var data: Dictionary = _read_file(name)
	if data.is_empty():
		row.corrupt = true
		return row
	row.schema = int(data.get("schema", 0))
	row.saved_at = int(data.get("saved_at", 0))
	row.wave = int(data.get("group_index", 0))
	row.party_text = _party_text(data.get("party", {}))
	return row


func _party_text(party) -> String:
	if not party is Dictionary or party.is_empty():
		return ""
	var names: Array = []
	for id in party:
		var p: Dictionary = party[id]
		names.append("%s Lv%d" % [String(p.get("name", id)),
			int(p.get("level", 1))])
	return ", ".join(names)


func _read_file(name: String) -> Dictionary:
	var f := FileAccess.open(_path(name), FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return {}
	if int(parsed.get("schema", 0)) > SCHEMA:
		# a newer game wrote this — never touch it
		return {}
	return parsed


## Any save at all (manual slot or autosave) — drives the boot modal.
func has_saves() -> bool:
	if not enabled:
		return false
	if FileAccess.file_exists(_path(AUTOSAVE)):
		return true
	for name in slot_names():
		if FileAccess.file_exists(_path(name)):
			return true
	return false


## Newest VALID save for boot CONTINUE: manual slots and the autosave,
## by saved_at. Corrupt/foreign-schema files are skipped. Returns the
## slot name or "" when nothing valid exists.
func latest_valid() -> String:
	var best := ""
	var best_at := -1
	for name in slot_names() + [AUTOSAVE]:
		var row := slot_info(name)
		if row.empty or row.corrupt or row.schema <= 0:
			continue
		if int(row.saved_at) > best_at:
			best_at = int(row.saved_at)
			best = name
	return best


## ---- writing -------------------------------------------------------

func _write(name: String, sim) -> Array:
	if not enabled:
		return [false, "nosave"]
	if not sim.encounter_done:
		# BETWEEN WAVES only — a mid-wave save would capture a battle
		# with in-flight spells/zones that do not serialize
		return [false, "between_waves"]
	var party := {}
	for id in sim.actor_order:
		var a = sim.actors[id]
		if a.faction != "friendly":
			continue
		party[id] = {level = a.progress.level,
			xp_available = a.progress.xp_available,
			name = a.display_name}
	var envelope := {
		schema = SCHEMA,
		scene = SCENE_ID,
		saved_at = int(Time.get_unix_time_from_system()),
		group_index = sim.group_index,
		party = party,
		battle = sim.to_dict(),
	}
	_ensure_dir()
	var tmp := _path(name) + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return [false, "cannot_write"]
	f.store_string(JSON.stringify(envelope))
	f.close()
	if DirAccess.rename_absolute(tmp, _path(name)) != OK:
		return [false, "cannot_write"]
	return [true, ""]


## Manual slot write. Returns [ok, reason].
func save(name: String, sim) -> Array:
	if not (name in slot_names()):
		return [false, "no_such_slot"]
	return _write(name, sim)


## The autosave — same envelope, never listed as a manual slot.
func autosave(sim) -> Array:
	return _write(AUTOSAVE, sim)


## Cmd+S: writes the ACTIVE slot. Returns [ok, reason] — "no_active_slot"
## when the player has never picked one (the caller opens the save
## modal instead).
func quick_save(sim) -> Array:
	var a := active()
	if a == "":
		return [false, "no_active_slot"]
	return _write(a, sim)


## ---- loading ------------------------------------------------------

## Returns [Dictionary, ""] on success or [{}, reason] — "missing" when
## the slot file is absent, "unreadable" when it is not a save dict or
## its schema is newer than this build knows (never deleted).
func load_slot(name: String) -> Array:
	if not FileAccess.file_exists(_path(name)):
		return [{}, "missing"]
	var data := _read_file(name)
	if data.is_empty():
		return [{}, "unreadable"]
	if not (data.get("battle") is Dictionary):
		return [{}, "unreadable"]
	return [data, ""]


## ---- active slot (index.json) --------------------------------------

func set_active(name: String) -> void:
	if not enabled:
		return
	_ensure_dir()
	var idx := {active_slot = name,
		updated = int(Time.get_unix_time_from_system())}
	var tmp := _index_path() + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(idx))
	f.close()
	DirAccess.rename_absolute(tmp, _index_path())


func active() -> String:
	if not FileAccess.file_exists(_index_path()):
		return ""
	var f := FileAccess.open(_index_path(), FileAccess.READ)
	if f == null:
		return ""
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return ""
	return String(parsed.get("active_slot", ""))
