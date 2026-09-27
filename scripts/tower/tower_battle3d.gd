extends Node3D
## Althar's Keep — Tower: runtime root for SCENE 01.
##
## Owns the simulation built from `scenario_tower.gd`, ticks it, drains
## its events into views and the HUD, and routes input. The rules live in
## the SHARED `sim/` (vendored from Althar's Keep) — this file contains no
## rules of its own and touches the simulation only through its public
## API.
##
## SCENE 01 loop: prepare -> start group -> enemies walk the road ->
## combat -> loot -> wave cleared -> recover/repair -> next group.

const Scenario = preload("res://scenario_tower.gd")
const Battle = preload("res://sim/battle.gd")
const Combat = preload("res://sim/combat.gd")
const Fireball = preload("res://sim/fireball.gd")
const Blizzard = preload("res://sim/blizzard.gd")
const Hex = preload("res://sim/hex.gd")
const Progress = preload("res://sim/progress.gd")

const EnvScene = preload("res://scripts/tower/tower_env3d.gd")
const ActorView = preload("res://scripts/tower/tower_actor_view.gd")

const HOP_TIME := 0.28
const KEEP_ID := "keep"

const SPELL_SLOTS := {
	KEY_1: "fireball",
	KEY_2: "lightning",
	KEY_3: "blizzard",
}

var sim
var views := {}
var env: Node3D
var cam: Camera3D

var armed := ""
var paused := false
var hops: Array = []
var _proj: MeshInstance3D
var _proj_light: OmniLight3D
var _elapsed := 0.0
var _shot_at: Array = []
var _log: Array = []
var _flash := 0.0
var _banner := ""
var _banner_t := 0.0
var _auto_wave := false

var _hud: CanvasLayer
var _l_title: Label
var _l_wave: Label
var _l_hint: Label
var _l_log: Label
var _l_banner: Label
var _l_party: Label
var _bar: ProgressBar
var _l_keep: Label


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	env = EnvScene.new()
	add_child(env)
	cam = get_viewport().get_camera_3d()

	sim = Battle.create(Scenario, Callable(Scenario, "build_roster"))

	for id in sim.actor_order:
		var v = ActorView.new()
		add_child(v)
		v.bind(sim.actors[id], sim.actors[id].faction == "friendly")
		views[id] = v

	_build_projectile()
	_build_hud()

	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			var spec := a.get_slice("=", 1)
			var file := "/tmp/tower_shot.png"
			if spec.contains(":"):
				file = spec.get_slice(":", 1)
				spec = spec.get_slice(":", 0)
			_shot_at.append({t = spec.to_float(), file = file})
		elif a == "--dump":
			_dump_placements()
		elif a == "--autowave":
			_auto_wave = true

	_say("SCENE 01 — The Defensive Front")
	_say("WAVE %d — %s" % [sim.group_index, _wave_text()])
	_say("1 fireball · 2 lightning · 3 blizzard · space pause · N next wave")
	_refresh_hud()


func _wave_text() -> String:
	var parts: Array = []
	for k in Scenario.wave_for(sim.group_index):
		parts.append("%d %s" % [Scenario.wave_for(sim.group_index)[k], k])
	return ", ".join(parts)


## --dump: where every actor is, in both spaces, and whether the view
## lifted it onto its structure. Placement bugs are otherwise invisible
## behind masonry.
func _dump_placements() -> void:
	print("DUMP  id                    faction   hex        col   y     view")
	for id in sim.actor_order:
		var a = sim.actors[id]
		var v = views[id]
		print("DUMP  %-21s %-9s %-10s %4d  %4.1f  (%.1f, %.1f, %.1f)" % [
			id, a.faction, a.hex, 2 * a.hex.x + a.hex.y, v.position.y,
			v.position.x, v.position.y, v.position.z])
	var k = sim.structures.get(KEEP_ID)
	if k != null:
		print("DUMP  KEEP %s integrity %d/%d  %s" % [k.hex,
			k.integrity, k.max_integrity, k.state()])


## ---- presentation builders -----------------------------------------

func _build_projectile() -> void:
	_proj = MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = 0.32
	s.height = 0.64
	_proj.mesh = s
	var m := StandardMaterial3D.new()
	m.albedo_color = Scenario.FIREBALL.color
	m.emission_enabled = true
	m.emission = Scenario.FIREBALL.color
	m.emission_energy_multiplier = 3.0
	_proj.material_override = m
	_proj.visible = false
	add_child(_proj)

	_proj_light = OmniLight3D.new()
	_proj_light.light_color = Scenario.FIREBALL.color
	_proj_light.light_energy = 4.5
	_proj_light.omni_range = 13.0
	_proj_light.visible = false
	add_child(_proj_light)


func _build_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_hud)

	_l_title = _mk_label(Vector2(22, 14), 22)
	_l_title.text = "ALTHAR'S KEEP — TOWER"
	_l_wave = _mk_label(Vector2(22, 44), 17)

	_l_keep = _mk_label(Vector2(22, 76), 15)
	_bar = ProgressBar.new()
	_bar.position = Vector2(22, 98)
	_bar.size = Vector2(240, 14)
	_bar.show_percentage = false
	_bar.max_value = 100.0
	_hud.add_child(_bar)

	_l_party = _mk_label(Vector2(22, 130), 14)
	_l_log = _mk_label(Vector2(22, 640), 14)
	_l_log.modulate = Color(0.86, 0.88, 0.82, 0.92)
	_l_hint = _mk_label(Vector2(22, 748), 16)
	_l_banner = _mk_label(Vector2(430, 90), 34)
	_l_banner.modulate = Color(1.0, 0.86, 0.45)


func _mk_label(pos: Vector2, size: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(0.93, 0.91, 0.86))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 5)
	_hud.add_child(l)
	return l


## ---- input ----------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				_toggle_pause()
				return
			KEY_ESCAPE:
				_arm("")
				return
			KEY_N:
				_next_wave()
				return
		if SPELL_SLOTS.has(event.keycode):
			_arm(SPELL_SLOTS[event.keycode])
			return
	if paused:
		return
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if armed != "":
			_try_cast(event.position)
		return
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_arm("")


func _toggle_pause() -> void:
	paused = not paused
	_say("PAUSED" if paused else "RESUMED")


func _arm(spell: String) -> void:
	armed = spell
	if spell == "":
		_l_hint.text = ""
		return
	var w = sim.actors["wizard"]
	_l_hint.text = "%s armed — click an enemy   (MP %d/%d)" % [
		Scenario.SPELLS[spell].display_name, w.mp, w.max_mp]


func _enemy_at(screen: Vector2) -> Variant:
	var ro := cam.project_ray_origin(screen)
	var rd := cam.project_ray_normal(screen)
	var hit = Plane(Vector3.UP, 0.0).intersects_ray(ro, rd)
	if hit == null:
		return null
	var p: Vector3 = hit
	var h := Hex.to_coord(p.x / Scenario.WORLD_SCALE,
		p.z / Scenario.WORLD_SCALE, Scenario.HEX_SIZE,
		Scenario.HEX_SQUASH)
	for id in sim.actor_order:
		var a = sim.actors[id]
		if a.alive and a.faction == "enemy" and a.hex == h:
			return a
	return null


func _try_cast(screen: Vector2) -> void:
	var target = _enemy_at(screen)
	if target == null:
		_l_hint.text = "no enemy on that ground"
		return
	var res: Array = Fireball.cast(sim, "wizard", target.id, armed)
	if res[0]:
		_say("%s -> %s" % [Scenario.SPELLS[armed].display_name,
			target.display_name])
		_arm("")
	else:
		_l_hint.text = "cast rejected — %s" % res[1]


func _next_wave() -> void:
	if not sim.encounter_done:
		return
	sim.next_group()
	# Keep workers (spec §16): a placeholder repair allowance between
	# waves. PROVISIONAL — no workers, no economy, and NOT a refill of
	# hero LP/AP/MP (the canonical rules do not refill those).
	var k = sim.structures.get(KEEP_ID)
	if k != null and Scenario.KEEP_REPAIR_PER_WAVE > 0:
		var n: int = k.repair(Scenario.KEEP_REPAIR_PER_WAVE)
		if n > 0:
			_say("workers shore up the Keep (+%d integrity)" % n)
	for id in sim.actor_order:
		var v = views.get(id)
		if v == null:
			v = ActorView.new()
			add_child(v)
			v.bind(sim.actors[id], sim.actors[id].faction == "friendly")
			views[id] = v
		else:
			v.bind(sim.actors[id], sim.actors[id].faction == "friendly")
	_banner = "WAVE %d" % sim.group_index
	_banner_t = 2.5
	_say("WAVE %d — %s" % [sim.group_index, _wave_text()])
	_refresh_hud()


## ---- tick -----------------------------------------------------------

func _process(dt: float) -> void:
	_elapsed += dt
	for i in range(_shot_at.size() - 1, -1, -1):
		if _elapsed >= _shot_at[i].t:
			_take_shot(_shot_at[i].file)
			_shot_at.remove_at(i)

	_flash = maxf(0.0, _flash - dt)
	_banner_t = maxf(0.0, _banner_t - dt)
	for i in range(hops.size() - 1, -1, -1):
		var hop = hops[i]
		hop.t += dt / HOP_TIME
		if hop.t >= 1.0:
			hop.node.position = hop.to
			hops.remove_at(i)
		else:
			hop.node.position = hop.from.lerp(hop.to, hop.t)

	if paused or sim.defense_lost:
		return

	Fireball.update(sim, dt)
	Blizzard.update(sim, dt)
	Combat.update(sim, dt)

	_sync_projectile()
	for id in sim.actor_order:
		views[id].refresh()
	_handle_events()
	_refresh_hud()

	if _auto_wave and sim.encounter_done and _banner_t <= 0.0:
		_next_wave()


func _sync_projectile() -> void:
	var fb = sim.fireball
	if fb == null:
		_proj.visible = false
		_proj_light.visible = false
		return
	_proj.visible = true
	_proj_light.visible = true
	var frac: float = 1.0 - fb.pos.distance_to(fb.to) \
		/ maxf(fb.distance, 0.001)
	var pos := Vector3(fb.pos.x * Scenario.WORLD_SCALE,
		lerpf(Scenario.KEEP_TOP_H, 1.2, frac) + sin(frac * PI) * 1.4,
		fb.pos.y * Scenario.WORLD_SCALE)
	_proj.position = pos
	_proj_light.position = pos


func _refresh_hud() -> void:
	var k = sim.structures.get(KEEP_ID)
	if k != null:
		_l_keep.text = "KEEP INTEGRITY   %d / %d   %s" % [
			k.integrity, k.max_integrity, k.state()]
		_bar.value = k.fraction() * 100.0
	var w = sim.actors["wizard"]
	_l_wave.text = "wave %d   enemies %d   MP %d/%d%s" % [
		sim.group_index, sim.living_enemies().size(), w.mp, w.max_mp,
		"   PAUSED" if paused else ""]
	var lines: Array = []
	for id in ["wizard", "warrior", "barbarian", "archer", "healer"]:
		var a = sim.actors.get(id)
		if a == null:
			continue
		var state := "OK"
		if not a.alive:
			state = "FALLEN"
		elif a.lp <= int(ceil(a.max_lp * 0.25)):
			state = "CRITICAL"
		elif a.ap <= 0:
			state = "EXHAUSTED"
		var mp := "  MP %d/%d" % [a.mp, a.max_mp] if a.has_mp() else ""
		lines.append("%-10s LP %2d/%-2d  AP %2d/%-2d%s   %s" % [
			a.display_name, a.lp, a.max_lp, a.ap, a.max_ap, mp, state])
	_l_party.text = "\n".join(lines)
	_l_banner.text = _banner if _banner_t > 0.0 else ""


## ---- events ---------------------------------------------------------

func _handle_events() -> void:
	for e in sim.drain_events():
		match e.type:
			"move":
				hops.append({node = views[e.actor],
					from = _hex_pos(e.from), to = _hex_pos(e.to),
					t = 0.0})
			"cast":
				_say("CAST %s" % e.spell.display_name)
			"explosion":
				_flash = 0.25
			"damage":
				pass
			"death":
				_say("%s falls" % e.actor.display_name)
			"arrow_release":
				pass
			"level_up":
				_banner = "%s REACHED LEVEL %d" % [e.actor.display_name,
					e.actor.progress.level]
				_banner_t = 2.5
				_say("LEVEL UP — %s" % e.actor.display_name)
			"encounter_end":
				_banner = "WAVE %d CLEARED" % e.group
				_banner_t = 3.0
				_say("WAVE %d CLEARED — press N for the next group" % e.group)
			"structure_hit":
				_flash = 0.18
			"structure_state":
				_say("THE KEEP IS %s (%d integrity)" % [e.state,
					e.integrity])
			"structure_lost":
				_banner = "THE KEEP HAS FALLEN"
				_banner_t = 99.0
				_say("THE KEEP HAS FALLEN — defence lost")
			"defense_lost":
				_banner = "DEFENCE LOST"
				_banner_t = 99.0
			"loot":
				_say("%s drops loot" % e.actor.display_name)
			"next_group":
				pass
			_:
				pass


func _hex_pos(h: Vector2i) -> Vector3:
	var p: Vector2 = Hex.to_world(h, Scenario.HEX_SIZE,
		Scenario.HEX_SQUASH)
	var y := 0.0
	match Scenario.wall_kind(h):
		1: y = Scenario.TOWER_H
		2: y = Scenario.KEEP_TOP_H
	return Vector3(p.x * Scenario.WORLD_SCALE, y,
		p.y * Scenario.WORLD_SCALE)


func _say(line: String) -> void:
	print("TOWERLOG ", line)
	_log.append(line)
	while _log.size() > 9:
		_log.pop_front()
	if _l_log != null:
		_l_log.text = "\n".join(_log)


func _take_shot(path: String) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	_say("SHOT saved " + path)
