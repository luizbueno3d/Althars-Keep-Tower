extends Node3D
## Althar's Keep — Tower: runtime root.
##
## PHASE 0 SCAFFOLD. Owns the simulation built from `scenario_tower.gd`,
## ticks it, drains its events into views, and routes input. The rules
## live in the SHARED `sim/` (symlinked from Althar's Keep) — this file
## contains no rules of its own and never writes to the simulation
## except through its public API.
##
## Deliberately thin: Phase 1 builds the real low-poly battlefield and
## the shared UI kit. What exists here is the smallest thing that proves
## a second game runs on the shared engine, on screen.

const Scenario = preload("res://scenario_tower.gd")
const Battle = preload("res://sim/battle.gd")
const Combat = preload("res://sim/combat.gd")
const Fireball = preload("res://sim/fireball.gd")
const Blizzard = preload("res://sim/blizzard.gd")
const Hex = preload("res://sim/hex.gd")
const Dice = preload("res://sim/dice.gd")

const EnvScene = preload("res://scripts/tower/tower_env3d.gd")
const ActorView = preload("res://scripts/tower/tower_actor_view.gd")

const HOP_TIME := 0.28

## Slot -> spell id. Only the damaging spells are wired in Phase 0;
## Teleport needs a source/destination UI and belongs to Phase 2.
const SPELL_SLOTS := {
	KEY_1: "fireball",
	KEY_2: "lightning",
	KEY_3: "blizzard",
}

var sim
var views := {}
var env: Node3D
var cam: Camera3D

var armed := ""            # spell id currently targeting, or ""
var paused := false
var hops: Array = []

var _proj: MeshInstance3D
var _proj_light: OmniLight3D
var _elapsed := 0.0
var _shot_at: Array = []
var _log: Array = []
var _flash := 0.0

var _hud: CanvasLayer
var _l_title: Label
var _l_status: Label
var _l_hint: Label
var _l_log: Label


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	env = EnvScene.new()
	add_child(env)
	cam = get_viewport().get_camera_3d()

	sim = Battle.create(Scenario)

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

	_say("READY — %s: %d defenders, %d attackers" % [
		Scenario.TOWER.name, _count("friendly"), _count("enemy")])
	_say("1 fireball · 2 lightning · 3 blizzard · space pause")


func _count(faction: String) -> int:
	var n := 0
	for id in sim.actor_order:
		if sim.actors[id].faction == faction:
			n += 1
	return n


## --dump: print where every actor is, in both spaces, and whether the
## view lifted it onto the walk. Placement bugs are otherwise invisible
## behind masonry.
func _dump_placements() -> void:
	print("DUMP  id           faction   hex        col   sim_y  view_pos")
	for id in sim.actor_order:
		var a = sim.actors[id]
		var v = views[id]
		print("DUMP  %-12s %-9s %-10s %4d  %5.1f  (%.1f, %.1f, %.1f)" % [
			id, a.faction, a.hex, 2 * a.hex.x + a.hex.y,
			Scenario.TOWER.walk_h if a.elevated else 0.0,
			v.position.x, v.position.y, v.position.z])


## ---- presentation builders -----------------------------------------

func _build_projectile() -> void:
	_proj = MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = 0.30
	s.height = 0.60
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
	_proj_light.light_energy = 4.0
	_proj_light.omni_range = 12.0
	_proj_light.visible = false
	add_child(_proj_light)


func _build_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_hud)

	_l_title = _mk_label(Vector2(20, 16), 22)
	_l_title.text = "ALTHAR'S KEEP — TOWER"
	_l_status = _mk_label(Vector2(20, 46), 17)
	_l_hint = _mk_label(Vector2(20, 700), 17)
	_l_log = _mk_label(Vector2(20, 540), 15)
	_l_log.modulate = Color(0.85, 0.87, 0.8, 0.9)


func _mk_label(pos: Vector2, size: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(0.93, 0.91, 0.86))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("outline_size", 5)
	_hud.add_child(l)
	return l


## ---- input ----------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:
			_toggle_pause()
			return
		if event.keycode == KEY_ESCAPE:
			_arm("")
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
	var cost: int = Scenario.SPELLS[spell].mp_cost
	var w = sim.actors["wizard"]
	_l_hint.text = "%s armed — click an enemy   (MP %d/%d)" % [
		Scenario.SPELLS[spell].display_name, w.mp, w.max_mp]


## Screen point -> the living enemy standing on that hex.
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


## ---- tick -----------------------------------------------------------

func _process(dt: float) -> void:
	_elapsed += dt
	for i in range(_shot_at.size() - 1, -1, -1):
		if _elapsed >= _shot_at[i].t:
			_take_shot(_shot_at[i].file)
			_shot_at.remove_at(i)

	_flash = maxf(0.0, _flash - dt)
	for i in range(hops.size() - 1, -1, -1):
		var hop = hops[i]
		hop.t += dt / HOP_TIME
		if hop.t >= 1.0:
			hop.node.position = hop.to
			hops.remove_at(i)
		else:
			hop.node.position = hop.from.lerp(hop.to, hop.t)

	if paused:
		return

	Fireball.update(sim, dt)
	Blizzard.update(sim, dt)
	Combat.update(sim, dt)

	_sync_projectile()
	for id in sim.actor_order:
		views[id].refresh()
	_handle_events()
	_refresh_status()


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
		lerpf(9.0, 1.0, frac) + sin(frac * PI) * 1.2,
		fb.pos.y * Scenario.WORLD_SCALE)
	_proj.position = pos
	_proj_light.position = pos


func _refresh_status() -> void:
	if _flash > 0.0:
		return
	var living := 0
	for id in sim.actor_order:
		var a = sim.actors[id]
		if a.alive and a.faction == "friendly":
			living += 1
	var w = sim.actors["wizard"]
	_l_status.text = "wave %d   defenders %d   MP %d/%d   %s" % [
		sim.group_index, living, w.mp, w.max_mp,
		"PAUSED" if paused else ""]


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
				_say("IMPACT at %s" % e.target)
			"damage":
				_say("%s takes %d" % [e.actor.display_name,
					e.get("lp_before", 0) - e.get("lp_after", 0)])
			"death":
				_say("%s falls" % e.actor.display_name)
			"level_up":
				_say("LEVEL UP — %s" % e.actor.display_name)
			"encounter_end":
				_say("WAVE %d CLEARED" % e.group)
			"loot":
				_say("%s drops loot" % e.actor.display_name)
			_:
				pass


func _hex_pos(h: Vector2i) -> Vector3:
	var p: Vector2 = Hex.to_world(h, Scenario.HEX_SIZE,
		Scenario.HEX_SQUASH)
	return Vector3(p.x * Scenario.WORLD_SCALE, 0.0,
		p.y * Scenario.WORLD_SCALE)


func _say(line: String) -> void:
	print("TOWERLOG ", line)
	_log.append(line)
	while _log.size() > 8:
		_log.pop_front()
	if _l_log != null:
		_l_log.text = "\n".join(_log)


func _take_shot(path: String) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	_say("SHOT saved " + path)
