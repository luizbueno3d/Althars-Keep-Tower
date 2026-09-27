extends Node3D
## Althar's Keep — Tower: runtime root for SCENE 01.
##
## Owns the simulation built from `scenario_tower.gd`, ticks it, drains
## its events into views and the HUD, and routes input. The rules live in
## the SHARED `sim/` (vendored from Althar's Keep) — this file contains no
## rules of its own and touches the simulation only through its public
## API.
##
## INPUT MODEL: every pointer gesture (mouse AND touch) is normalised
## into a semantic pick and fed to `scripts/tower/input/command_state.gd`
## — the tested state machine. This file only resolves picks against the
## 3D scene and executes the intents the state machine returns.
##
## SCENE 01 loop: prepare -> start group -> enemies walk the road ->
## combat -> loot -> wave cleared -> recover/repair -> next group.

const Scenario = preload("res://scenario_tower.gd")
const Battle = preload("res://sim/battle.gd")
const Combat = preload("res://sim/combat.gd")
const Fireball = preload("res://sim/fireball.gd")
const Blizzard = preload("res://sim/blizzard.gd")
const Support = preload("res://sim/support.gd")
const Teleport = preload("res://sim/teleport.gd")
const Targeting = preload("res://sim/targeting.gd")
const Hex = preload("res://sim/hex.gd")
const Progress = preload("res://sim/progress.gd")

const EnvScene = preload("res://scripts/tower/tower_env3d.gd")
const ActorView = preload("res://scripts/tower/tower_actor_view.gd")
const CommandState = preload("res://scripts/tower/input/command_state.gd")

const HOP_TIME := 0.28
const KEEP_ID := "keep"
const SETTINGS_FILE := "user://settings.cfg"

## Camera rig: a fixed view direction; the player pans the look-at
## anchor on the ground and zooms the camera along the view axis.
const CAM_TARGET0 := Vector3(12.0, 0.0, 0.0)
const CAM_DIST0 := 81.0
const CAM_DIST_MIN := 34.0          # zoomed IN limit (whole view stays)
const CAM_DIST_MAX := 81.0          # zoom-OUT limit = current framing
const CAM_ANCHOR_MIN := Vector2(-14.0, -26.0)
const CAM_ANCHOR_MAX := Vector2(58.0, 32.0)

const TAP_MAX_DIST := 14.0          # px — a tap vs a drag
const TAP_MAX_TIME := 0.35          # s
const PICK_RADIUS := 52.0           # px — generous for fat fingers

## Landmark hexes for the flight-time measurement (road positions).
const MEASURE_POINTS := [
	{name = "keep approach", at = Vector2(-2.0, 0.0)},
	{name = "mid road", at = Vector2(26.0, -8.0)},
	{name = "spawn", at = Vector2(50.0, 14.0)},
]

var sim
var views := {}
var env: Node3D
var cam: Camera3D
var state: CommandState

var paused := false
var hops: Array = []
var _proj: MeshInstance3D
var _proj_light: OmniLight3D
var _disc: MeshInstance3D
var _elapsed := 0.0
var _shot_at: Array = []
var _log: Array = []
var _flash := 0.0
var _banner := ""
var _banner_t := 0.0
var _auto_wave := false
var _smoke := false
var _poses := false
var _script: Array = []             # scheduled smoke/pose actions
var _script_i := 0
var _intents: Array = []            # smoke: intent types seen
var _cast_t0 := -1.0
var _handed := "right"
var _devlog := false
var _force_handed := ""
var _bar_col: VBoxContainer
var _title_box: VBoxContainer

# gesture tracking
var _lmb_down := -1.0
var _lmb_pos := Vector2.ZERO
var _rmb_down := -1.0
var _rmb_pos := Vector2.ZERO
var _panning := false
var _touches := {}                  # touch index -> last pos
var _touch_t0 := {}                 # touch index -> press time
var _pinch_d := -1.0
var _cam_anchor := CAM_TARGET0
var _cam_dist := CAM_DIST0
var _cam_dir := Vector3.ZERO
var _hover_gp: Variant = null       # last ground point under the pointer

var _hud: CanvasLayer
var _l_title: Label
var _l_wave: Label
var _l_hint: Label
var _l_log: Label
var _l_banner: Label
var _bar: ProgressBar
var _l_keep: Label
var _b_pause: Button
var _b_cancel: Button
var _bar_box: HBoxContainer
var _portraits: VBoxContainer
var _portrait_btns := {}
var _ability_btns: Array = []
var _ability_ids: Array = []
var _inspect_panel: PanelContainer
var _l_inspect: Label
var _loot_panel: PanelContainer
var _l_loot: Label
var _loot_id := ""
var _pause_overlay: ColorRect
var _b_handed: Button


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	env = EnvScene.new()
	add_child(env)
	cam = get_viewport().get_camera_3d()

	_cam_dir = (cam.position - CAM_TARGET0).normalized()

	sim = Battle.create(Scenario, Callable(Scenario, "build_roster"))
	state = CommandState.new()

	for id in sim.actor_order:
		var v = ActorView.new()
		add_child(v)
		v.bind(sim.actors[id], sim.actors[id].faction == "friendly")
		views[id] = v

	# early flag pass: layout/devlog flags must land before the HUD builds
	for a in OS.get_cmdline_user_args():
		match a:
			"--devlog": _devlog = true
			"--left": _force_handed = "left"
			"--right": _force_handed = "right"
			"--input-smoke": _smoke = true
			"--poses": _poses = true
	_load_settings()
	if _force_handed != "":
		_handed = _force_handed
	if _smoke:
		_handed = "right"          # smoke always runs right-handed
	_build_projectile()
	_build_disc()
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
		elif a == "--input-smoke":
			_smoke = true
		elif a == "--poses":
			_poses = true
		elif a == "--measure":
			_measure_flight_times()

	_say("SCENE 01 — The Defensive Front")
	_say("WAVE %d — %s" % [sim.group_index, _wave_text()])
	_refresh_hud()
	if _smoke:
		_plan_smoke()
	elif _poses:
		_plan_poses()


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


## Projectile flight time is the shared sim's own distance/speed — the
## same numbers drive the view, so this table is the sim's truth.
func _measure_flight_times() -> void:
	var wh: Vector2i = sim.actors["wizard"].hex
	var wp: Vector2 = Hex.to_world(wh, Scenario.HEX_SIZE,
		Scenario.HEX_SQUASH)
	print("MEASURE  caster wizard at %s (world %.0f,%.0f px)" % [wh,
		wp.x, wp.y])
	for m in MEASURE_POINTS:
		var h := Hex.to_coord(m.at.x / Scenario.WORLD_SCALE,
			m.at.y / Scenario.WORLD_SCALE, Scenario.HEX_SIZE,
			Scenario.HEX_SQUASH)
		var hp: Vector2 = Hex.to_world(h, Scenario.HEX_SIZE,
			Scenario.HEX_SQUASH)
		var d: float = wp.distance_to(hp)
		print("MEASURE  %-14s hex %-9s %.0f px | fireball %.2fs | meteor %.2fs" % [
			m.name, h, d, d / Scenario.FIREBALL.speed,
			d / Scenario.METEOR.speed])


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


## Translucent danger-radius disc: follows the cursor while a GROUND
## spell is armed (desktop hover) and sits at the committed impact point
## during flight (both devices). Radius = aoe in world metres.
func _build_disc() -> void:
	_disc = MeshInstance3D.new()
	var dm := CylinderMesh.new()
	dm.height = 0.05
	dm.radial_segments = 48
	dm.top_radius = 1.0
	dm.bottom_radius = 1.0
	_disc.mesh = dm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.45, 0.15, 0.28)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.4, 0.1)
	m.emission_energy_multiplier = 1.1
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_disc.material_override = m
	_disc.visible = false
	add_child(_disc)


func _aoe_radius_m(spec: Dictionary) -> float:
	var hex_m: float = Hex.to_world(Vector2i(1, 0), Scenario.HEX_SIZE,
		Scenario.HEX_SQUASH).length() * Scenario.WORLD_SCALE
	return (float(spec.get("aoe_radius", 1)) + 0.5) * hex_m


## ---- HUD ------------------------------------------------------------

func _build_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_hud)

	# title/status block — sits on the side OPPOSITE the pause corner
	_title_box = VBoxContainer.new()
	_title_box.custom_minimum_size = Vector2(280, 0)
	_hud.add_child(_title_box)
	_l_title = Label.new()
	_l_title.text = "ALTHAR'S KEEP — TOWER"
	_style_label(_l_title, 20)
	_title_box.add_child(_l_title)
	_l_wave = Label.new()
	_style_label(_l_wave, 15)
	_title_box.add_child(_l_wave)

	# Keep Integrity — top-centre, owned by the whole UI
	var ki := VBoxContainer.new()
	ki.custom_minimum_size = Vector2(360, 0)
	ki.alignment = BoxContainer.ALIGNMENT_CENTER
	ki.grow_horizontal = Control.GROW_DIRECTION_BOTH
	ki.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP,
		Control.PRESET_MODE_MINSIZE, 10)
	_hud.add_child(ki)
	_l_keep = Label.new()
	_l_keep.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_style_label(_l_keep, 15)
	ki.add_child(_l_keep)
	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(360, 14)
	_bar.show_percentage = false
	_bar.max_value = 100.0
	ki.add_child(_bar)

	# hero portraits — tappable, side opposite the action bar
	_portraits = VBoxContainer.new()
	_portraits.custom_minimum_size = Vector2(150, 0)
	_hud.add_child(_portraits)
	for id in ["wizard", "warrior", "barbarian", "archer", "healer"]:
		var b := Button.new()
		b.custom_minimum_size = Vector2(150, 54)
		b.text = "%s" % sim.actors[id].display_name
		var hero_id: String = id
		b.pressed.connect(_on_portrait.bind(hero_id))
		_portraits.add_child(b)
		_portrait_btns[id] = b

	# contextual action bar + the big CANCEL X in one bottom-corner
	# column; the hint line rides just above the bar on its own side
	_bar_col = VBoxContainer.new()
	_bar_col.add_theme_constant_override("separation", 8)
	_hud.add_child(_bar_col)
	_l_hint = Label.new()
	_style_label(_l_hint, 16)
	_l_hint.modulate = Color(1.0, 0.8, 0.4)
	_l_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_l_hint.size_flags_horizontal = Control.SIZE_SHRINK_END
	_l_hint.custom_minimum_size = Vector2(560, 0)
	_l_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_bar_col.add_child(_l_hint)
	_bar_box = HBoxContainer.new()
	_bar_box.add_theme_constant_override("separation", 10)
	_bar_box.size_flags_horizontal = Control.SIZE_SHRINK_END
	_bar_col.add_child(_bar_box)
	for i in 5:
		var b := Button.new()
		b.custom_minimum_size = Vector2(104, 72)
		b.visible = false
		var slot := i
		b.pressed.connect(_arm_slot.bind(slot))
		_bar_box.add_child(b)
		_ability_btns.append(b)
	_b_cancel = Button.new()
	_b_cancel.text = "✕"
	_b_cancel.custom_minimum_size = Vector2(72, 72)
	_b_cancel.add_theme_font_size_override("font_size", 40)
	_b_cancel.add_theme_color_override("font_color", Color(1, 0.25, 0.2))
	_b_cancel.visible = false
	_b_cancel.pressed.connect(_on_cancel_btn)
	_bar_box.add_child(_b_cancel)

	# pause — top corner on the dominant-hand side
	_b_pause = Button.new()
	_b_pause.text = "❚❚"
	_b_pause.custom_minimum_size = Vector2(64, 52)
	_b_pause.pressed.connect(_on_pause_btn)
	_hud.add_child(_b_pause)

	# dev log overlay — hidden unless --devlog
	_l_log = Label.new()
	_l_log.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	_l_log.position = Vector2(180, 300)
	_style_label(_l_log, 13)
	_l_log.modulate = Color(0.86, 0.88, 0.82, 0.92)
	_l_log.visible = _devlog
	_hud.add_child(_l_log)

	_l_banner = Label.new()
	_l_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_l_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_l_banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP,
		Control.PRESET_MODE_MINSIZE, 90)
	_style_label(_l_banner, 34)
	_l_banner.modulate = Color(1.0, 0.86, 0.45)
	_hud.add_child(_l_banner)

	_build_inspect()
	_build_loot()
	_build_pause_overlay()
	_apply_layout()
	_refresh_bar()


func _mk_label(pos: Vector2, size: int) -> Label:
	var l := Label.new()
	l.position = pos
	_style_label(l, size)
	_hud.add_child(l)
	return l


func _style_label(l: Label, size: int) -> void:
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(0.93, 0.91, 0.86))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 5)


func _build_inspect() -> void:
	_inspect_panel = PanelContainer.new()
	_inspect_panel.visible = false
	_inspect_panel.position = Vector2(190, 120)
	_inspect_panel.custom_minimum_size = Vector2(300, 0)
	var vb := VBoxContainer.new()
	_inspect_panel.add_child(vb)
	_l_inspect = Label.new()
	_style_label(_l_inspect, 14)
	vb.add_child(_l_inspect)
	var close := Button.new()
	close.text = "Close"
	close.pressed.connect(_close_inspect)
	vb.add_child(close)
	_hud.add_child(_inspect_panel)


func _build_loot() -> void:
	_loot_panel = PanelContainer.new()
	_loot_panel.visible = false
	var vb := VBoxContainer.new()
	_loot_panel.add_child(vb)
	_l_loot = Label.new()
	_style_label(_l_loot, 16)
	vb.add_child(_l_loot)
	var row := HBoxContainer.new()
	vb.add_child(row)
	var take := Button.new()
	take.text = "TAKE ALL"
	take.custom_minimum_size = Vector2(130, 48)
	take.pressed.connect(_take_loot)
	row.add_child(take)
	var close := Button.new()
	close.text = "Close"
	close.custom_minimum_size = Vector2(90, 48)
	close.pressed.connect(_close_loot)
	row.add_child(close)
	_loot_panel.set_anchors_preset(Control.PRESET_CENTER)
	_hud.add_child(_loot_panel)


func _build_pause_overlay() -> void:
	_pause_overlay = ColorRect.new()
	_pause_overlay.color = Color(0, 0, 0, 0.55)
	_pause_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause_overlay.visible = false
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_CENTER)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 16)
	_pause_overlay.add_child(vb)
	var t := Label.new()
	t.text = "PAUSED"
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_style_label(t, 40)
	vb.add_child(t)
	_b_handed = Button.new()
	_b_handed.custom_minimum_size = Vector2(300, 56)
	_b_handed.pressed.connect(_toggle_handedness)
	vb.add_child(_b_handed)
	_hud.add_child(_pause_overlay)


## ---- handedness (one layout, mirrored anchors) -----------------------

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_FILE) == OK:
		_handed = str(cfg.get_value("controls", "handedness", "right"))
	if _handed != "left":
		_handed = "right"


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("controls", "handedness", _handed)
	cfg.save(SETTINGS_FILE)


func _toggle_handedness() -> void:
	_handed = "left" if _handed == "right" else "right"
	_save_settings()
	_apply_layout()
	_say("controls: %s-handed" % _handed)


func _apply_layout() -> void:
	var right := _handed == "right"
	# All placement is anchor-driven so it survives canvas_items/expand
	# and any window size — no computed absolute positions. Grow
	# directions are set explicitly: edge/corner containers must grow
	# INWARD, away from their anchor side.
	_title_box.set_anchors_and_offsets_preset(
		Control.PRESET_TOP_LEFT if right else Control.PRESET_TOP_RIGHT,
		Control.PRESET_MODE_MINSIZE, 10)
	_title_box.grow_horizontal = Control.GROW_DIRECTION_END if right \
		else Control.GROW_DIRECTION_BEGIN
	_l_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if right \
		else HORIZONTAL_ALIGNMENT_RIGHT
	_l_wave.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if right \
		else HORIZONTAL_ALIGNMENT_RIGHT
	_portraits.set_anchors_and_offsets_preset(
		Control.PRESET_CENTER_LEFT if right else Control.PRESET_CENTER_RIGHT,
		Control.PRESET_MODE_MINSIZE, 12)
	_portraits.grow_horizontal = Control.GROW_DIRECTION_END if right \
		else Control.GROW_DIRECTION_BEGIN
	_portraits.grow_vertical = Control.GROW_DIRECTION_BOTH
	# action bar column (hint above bar): bottom corner on the
	# dominant-hand side; CANCEL X at the outer thumb edge of the row
	_bar_col.set_anchors_and_offsets_preset(
		Control.PRESET_BOTTOM_RIGHT if right else Control.PRESET_BOTTOM_LEFT,
		Control.PRESET_MODE_MINSIZE, 14)
	_bar_col.grow_horizontal = Control.GROW_DIRECTION_BEGIN if right \
		else Control.GROW_DIRECTION_END
	_bar_col.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_bar_box.move_child(_b_cancel,
		_bar_box.get_child_count() - 1 if right else 0)
	_l_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if right \
		else HORIZONTAL_ALIGNMENT_LEFT
	_l_hint.size_flags_horizontal = Control.SIZE_SHRINK_END if right \
		else Control.SIZE_SHRINK_BEGIN
	_b_pause.set_anchors_and_offsets_preset(
		Control.PRESET_TOP_RIGHT if right else Control.PRESET_TOP_LEFT,
		Control.PRESET_MODE_MINSIZE, 10)
	_b_pause.grow_horizontal = Control.GROW_DIRECTION_BEGIN if right \
		else Control.GROW_DIRECTION_END
	if _b_handed != null:
		_b_handed.text = "Controls: %s-handed" % _handed.capitalize()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		_apply_layout()


## ---- pick & intents --------------------------------------------------

## Screen-space pick: nearest actor (alive OR dead) by screen distance,
## then the ground hex. Dead enemies with loot are "corpse", dead
## friendlies are "fallen".
func _pick_at(screen: Vector2) -> Dictionary:
	var best = null
	var best_d := PICK_RADIUS
	for id in sim.actor_order:
		var a = sim.actors[id]
		var v = views[id]
		var wp: Vector3 = v.position + Vector3(0, 1.1, 0)
		if cam.is_position_behind(wp):
			continue
		var d := cam.unproject_position(wp).distance_to(screen)
		if d < best_d:
			best_d = d
			best = a
	if best != null:
		if best.alive:
			return {kind = "enemy" if best.faction == "enemy" \
				else "friendly", id = best.id, hex = best.hex}
		if best.faction == "enemy" and best.loot_available:
			return {kind = "corpse", id = best.id, hex = best.hex}
		if best.faction == "friendly":
			return {kind = "fallen", id = best.id, hex = best.hex}
		# dead enemy, nothing to loot — the hex is what matters
		return {kind = "ground", id = "", hex = best.hex}
	var gp: Variant = _ground_at(screen)
	if gp == null:
		return {kind = "none", id = "", hex = Vector2i.ZERO}
	var h := Hex.to_coord(gp.x / Scenario.WORLD_SCALE,
		gp.z / Scenario.WORLD_SCALE, Scenario.HEX_SIZE,
		Scenario.HEX_SQUASH)
	if sim.hex_in_grid(h):
		return {kind = "ground", id = "", hex = h}
	return {kind = "none", id = "", hex = h}


func _ground_at(screen: Vector2) -> Variant:
	var ro := cam.project_ray_origin(screen)
	var rd := cam.project_ray_normal(screen)
	return Plane(Vector3.UP, 0.0).intersects_ray(ro, rd)


func _log_intent(i: Dictionary) -> void:
	if _smoke:
		print("INTENT ", i)
		_intents.append(str(i.type))
	else:
		_say("intent %s" % i.type)


## Execute ONE intent returned by the state machine.
func _execute(i: Dictionary) -> void:
	_log_intent(i)
	match String(i.get("type", "none")):
		"select":
			_select(i.id)
		"deselect":
			_select("")
		"inspect":
			_show_inspect(i.id)
		"open_loot":
			_open_loot(i.id)
		"command_attack":
			var ok: bool = sim.command_focus(i.hero, i.target)
			_say("%s ordered to attack %s" % [i.hero, i.target] \
				if ok else "%s cannot reach that order" % i.hero)
		"cast_ground":
			var res: Array = Fireball.cast_at(sim, i.caster, i.hex,
				i.ability)
			_log_intent(state.resolved(bool(res[0])))
			if res[0]:
				_on_cast_started()
			else:
				_l_hint.text = "cast rejected — %s" % res[1]
			_refresh_bar()
		"cast_actor":
			var spec: Dictionary = Scenario.SPELLS[i.ability]
			var mode := Targeting.mode_of(spec)
			var res: Array
			if mode == "ally_alive" or mode == "ally_dead":
				res = Support.cast(sim, i.caster, i.ability, i.target)
			else:
				res = Fireball.cast(sim, i.caster, i.target, i.ability)
			_log_intent(state.resolved(bool(res[0])))
			if res[0]:
				_on_cast_started()
			else:
				_l_hint.text = "cast rejected — %s" % res[1]
			_refresh_bar()
		"teleport_source":
			_l_hint.text = "Teleport %s — tap a destination" % i.id
		"cast_teleport":
			var res: Array = Teleport.cast(sim, i.caster, i.source,
				i.hex)
			_log_intent(state.resolved(bool(res[0])))
			if res[0]:
				_say("TELEPORT %s" % i.source)
			else:
				_l_hint.text = "teleport rejected — %s" % res[1]
			_refresh_bar()
		"armed":
			var spec: Dictionary = Scenario.SPELLS[i.ability]
			var c = sim.actors.get(i.caster)
			var mp := "  MP %d/%d" % [c.mp, c.max_mp] if c != null \
				and c.has_mp() else ""
			_l_hint.text = "%s — %s%s" % [spec.display_name,
				_targeting_hint(Targeting.mode_of(spec)), mp]
			_refresh_bar()
		"cancelled":
			_l_hint.text = ""
			_refresh_bar()
		"reject":
			_l_hint.text = _reject_text(str(i.reason))
		"paused":
			paused = true
			_pause_overlay.visible = true
			_say("PAUSED")
		"resumed":
			paused = false
			_pause_overlay.visible = false
			_say("RESUMED")
		"modal_closed":
			_close_modal_views()


func _targeting_hint(mode: String) -> String:
	match mode:
		"ground": return "tap the battlefield"
		"enemy": return "tap an enemy"
		"ally_alive": return "tap a hero"
		"ally_dead": return "tap a fallen hero"
		"hero_destination": return "tap a hero, then a destination"
	return ""


func _reject_text(reason: String) -> String:
	match reason:
		"modal": return "close the panel first"
		"choose_enemy": return "that spell needs an ENEMY"
		"choose_ally": return "that spell needs a hero"
		"choose_fallen": return "that spell needs a FALLEN hero"
		"choose_hero": return "choose a hero to teleport"
		"off_field": return "off the battlefield"
		"unsupported_targeting": return "targeting not supported yet"
	return reason


func _select(id: String) -> void:
	for k in views:
		views[k].set_selected(k == id and id != "")
	for k in _portrait_btns:
		_portrait_btns[k].modulate = Color(1.0, 0.85, 0.4) if k == id \
			and id != "" else Color(1, 1, 1)
	_refresh_bar()


func _show_inspect(id: String) -> void:
	var a = sim.actors.get(id)
	if a == null:
		return
	var archetype := id
	var us := id.rfind("_")
	if us > 0:
		archetype = id.substr(0, us)
	var lines: Array = []
	lines.append("%s   (%s)" % [a.display_name, archetype])
	lines.append("faction %s   %s" % [a.faction,
		"alive" if a.alive else "dead"])
	lines.append("LP %d/%d   AP %d/%d%s" % [a.lp, a.max_lp, a.ap,
		a.max_ap, "   MP %d/%d" % [a.mp, a.max_mp] if a.has_mp() else ""])
	lines.append("Perception %d   Dodge %d   weapon %s   range %d" % [
		a.perception, a.dodge, a.weapon, a.attack_range])
	var armor := "none"
	if not a.armor.is_empty():
		armor = str(a.armor)
	lines.append("armor: %s" % armor)
	if a.resist.is_empty():
		lines.append("resist: none (x1.0 all)")
	else:
		for tpe in a.resist:
			var m: float = a.resist[tpe]
			lines.append("  %-10s x%.2f  (%s)" % [tpe, m,
				"SUSCEPTIBLE" if m > 1.0 else "resistant"])
	if a.focus_id != "":
		lines.append("focus order: %s" % a.focus_id)
	_l_inspect.text = "\n".join(lines)
	_inspect_panel.visible = true


func _close_inspect() -> void:
	_inspect_panel.visible = false


func _open_loot(id: String) -> void:
	var a = sim.actors.get(id)
	if a == null:
		return
	_loot_id = id
	var gold := int(a.loot.get("gold", 0))
	var item := str(a.loot.get("item", "nothing"))
	_l_loot.text = "%s\n  %d gold\n  %s" % [a.display_name, gold, item]
	_loot_panel.visible = true
	state.open_modal("loot")


func _take_loot() -> void:
	sim.take_loot(_loot_id)
	_say("loot taken")
	_close_loot()


func _close_loot() -> void:
	_loot_panel.visible = false
	if state.modal == "loot":
		_execute(state.cancel())


func _close_modal_views() -> void:
	_loot_panel.visible = false
	_inspect_panel.visible = false


func _on_cast_started() -> void:
	if sim.fireball != null:
		_cast_t0 = _elapsed
	_l_hint.text = ""


## ---- input layer -----------------------------------------------------
## Device events are normalised here: a quick press-release pair (mouse
## OR touch) is a primary tap; right-click release is a secondary;
## drags pan; wheel / pinch / magnify zoom. Keyboard goes through named
## InputMap actions. Emitted gestures feed the state machine.

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.is_action_pressed("pause"):
			_execute(state.toggle_pause())
			return
		if event.is_action_pressed("cancel"):
			_execute(state.cancel())
			return
		if event.is_action_pressed("next_wave"):
			_next_wave()
			return
		if event.is_action_pressed("quick_save"):
			_l_hint.text = "Save slots arrive in the next milestone"
			return
		for n in 5:
			if event.is_action_pressed("ability_%d" % (n + 1)):
				_arm_slot(n)
				return
		return
	if event is InputEventMouseButton:
		_on_mouse_button(event)
		return
	if event is InputEventMouseMotion:
		_on_mouse_motion(event)
		return
	if event is InputEventScreenTouch:
		_on_screen_touch(event)
		return
	if event is InputEventScreenDrag:
		_on_screen_drag(event)
		return
	if event is InputEventMagnifyGesture:
		_zoom(1.0 / event.factor)


func _arm_slot(n: int) -> void:
	var hero := state.active_hero()
	var kit: Array = Scenario.HERO_ABILITIES.get(hero, [])
	var spell := ""
	if n < kit.size():
		spell = kit[n]
	elif n == 4 and hero == "wizard":
		spell = "meteor"           # experimental: key 5 only
	if spell == "":
		_l_hint.text = "%s has no ability in slot %d" % [hero, n + 1]
		return
	_execute(state.arm(spell,
		Targeting.mode_of(Scenario.SPELLS[spell])))


func _on_mouse_button(e: InputEventMouseButton) -> void:
	match e.button_index:
		MOUSE_BUTTON_LEFT:
			if e.pressed:
				_lmb_down = _elapsed
				_lmb_pos = e.position
			elif _lmb_down >= 0.0:
				if _elapsed - _lmb_down <= TAP_MAX_TIME \
						and e.position.distance_to(_lmb_pos) \
						<= TAP_MAX_DIST:
					_execute(state.primary(_pick_at(e.position)))
				_lmb_down = -1.0
		MOUSE_BUTTON_RIGHT:
			if e.pressed:
				_rmb_down = _elapsed
				_rmb_pos = e.position
				_panning = true
			else:
				if _elapsed - _rmb_down <= TAP_MAX_TIME \
						and e.position.distance_to(_rmb_pos) \
						<= TAP_MAX_DIST:
					_execute(state.secondary(_pick_at(e.position)))
				_rmb_down = -1.0
				_panning = false
		MOUSE_BUTTON_MIDDLE:
			_panning = e.pressed
		MOUSE_BUTTON_WHEEL_UP:
			if e.pressed:
				_zoom(0.9)
		MOUSE_BUTTON_WHEEL_DOWN:
			if e.pressed:
				_zoom(1.1)


func _on_mouse_motion(e: InputEventMouseMotion) -> void:
	_hover_gp = _ground_at(e.position)
	if _panning or _lmb_down >= 0.0:
		_pan(e.relative)


func _on_screen_touch(e: InputEventScreenTouch) -> void:
	if e.pressed:
		_touches[e.index] = e.position
		_touch_t0[e.index] = _elapsed
		if _touches.size() == 2:
			var keys := _touches.keys()
			_pinch_d = _touches[keys[0]].distance_to(_touches[keys[1]])
		return
	# release: single-finger quick tap -> primary
	if _touches.has(e.index):
		var p0: Vector2 = _touches[e.index]
		var t0: float = _touch_t0.get(e.index, 0.0)
		if _touches.size() == 1 and _elapsed - t0 <= TAP_MAX_TIME \
				and e.position.distance_to(p0) <= TAP_MAX_DIST:
			_execute(state.primary(_pick_at(e.position)))
	_touches.erase(e.index)
	_touch_t0.erase(e.index)
	if _touches.size() < 2:
		_pinch_d = -1.0


func _on_screen_drag(e: InputEventScreenDrag) -> void:
	if _touches.size() >= 2:
		_touches[e.index] = e.position
		var keys := _touches.keys()
		var d: float = _touches[keys[0]].distance_to(_touches[keys[1]])
		if _pinch_d > 0.0:
			_zoom(_pinch_d / d)
		_pinch_d = d
	elif _touches.size() == 1:
		_touches[e.index] = e.position
		_pan(e.relative)


## Pan = move the look-at anchor on the ground plane; zoom = move the
## camera along its fixed view axis. Both are clamped so the whole
## battlefield can never be lost.
func _pan(delta: Vector2) -> void:
	var scale := _cam_dist / 900.0
	_cam_anchor += Vector3(-delta.x, 0, -delta.y) * scale
	_cam_anchor.x = clampf(_cam_anchor.x, CAM_ANCHOR_MIN.x,
		CAM_ANCHOR_MAX.x)
	_cam_anchor.z = clampf(_cam_anchor.z, CAM_ANCHOR_MIN.y,
		CAM_ANCHOR_MAX.y)
	_update_cam()


func _zoom(factor: float) -> void:
	_cam_dist = clampf(_cam_dist * factor, CAM_DIST_MIN, CAM_DIST_MAX)
	_update_cam()


func _update_cam() -> void:
	cam.position = _cam_anchor + _cam_dir * _cam_dist
	cam.look_at(_cam_anchor, Vector3.UP)


func _on_portrait(id: String) -> void:
	var a = sim.actors.get(id)
	if a == null:
		return
	var kind := "friendly" if a.alive else "fallen"
	_execute(state.primary({kind = kind, id = id, hex = a.hex}))


func _on_cancel_btn() -> void:
	_execute(state.cancel())


func _on_pause_btn() -> void:
	_execute(state.toggle_pause())


## ---- tick -----------------------------------------------------------

func _process(dt: float) -> void:
	_elapsed += dt
	for i in range(_shot_at.size() - 1, -1, -1):
		if _elapsed >= _shot_at[i].t:
			_take_shot(_shot_at[i].file)
			_shot_at.remove_at(i)

	_run_script()

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
		_update_disc()
		return

	Fireball.update(sim, dt)
	Blizzard.update(sim, dt)
	Combat.update(sim, dt)

	_sync_projectile()
	_update_disc()
	_update_target_highlights()
	for id in sim.actor_order:
		views[id].refresh()
	_handle_events()
	_refresh_hud()

	if _auto_wave and sim.encounter_done and _banner_t <= 0.0:
		_next_wave()


## Danger disc: while a GROUND spell is armed it follows the pointer;
## while a projectile is in flight it sits at the committed impact hex.
func _update_disc() -> void:
	var shown := false
	var fb = sim.fireball
	if fb != null:
		var c: Vector2 = Hex.to_world(fb.target, Scenario.HEX_SIZE,
			Scenario.HEX_SQUASH)
		_disc.position = Vector3(c.x * Scenario.WORLD_SCALE, 0.12,
			c.y * Scenario.WORLD_SCALE)
		_disc.scale = Vector3.ONE * _aoe_radius_m(fb.spell)
		shown = true
	elif state.armed != "" and state.armed_mode == Targeting.GROUND:
		var gp: Variant = _hover_gp
		if gp == null:
			gp = _ground_at(get_viewport().get_mouse_position())
		if gp != null:
			_disc.position = Vector3(gp.x, 0.10, gp.z)
			_disc.scale = Vector3.ONE \
				* _aoe_radius_m(Scenario.SPELLS[state.armed])
			shown = true
	_disc.visible = shown


## While an ENEMY-mode spell is armed, every living enemy glows — the
## legal-target read that replaces the old hex hover.
func _update_target_highlights() -> void:
	var hot := state.armed_mode == Targeting.ENEMY
	for id in sim.actor_order:
		var a = sim.actors[id]
		views[id].set_targeted(
			hot and a.alive and a.faction == "enemy")


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
	for id in _portrait_btns:
		var a = sim.actors.get(id)
		if a == null:
			continue
		var st := "FALLEN"
		if a.alive:
			st = "LP %d/%d" % [a.lp, a.max_lp]
			if a.lp <= int(ceil(a.max_lp * 0.25)):
				st += " !"
		_portrait_btns[id].text = "%s\n%s" % [a.display_name, st]
	_l_banner.text = _banner if _banner_t > 0.0 else ""


## Contextual action bar — driven by Scenario.HERO_ABILITIES for the
## ACTIVE hero. Heroes with no kit get their name + a one-line hint.
func _refresh_bar() -> void:
	var hero := state.active_hero()
	var kit: Array = Scenario.HERO_ABILITIES.get(hero, [])
	_ability_ids = kit
	for n in _ability_btns.size():
		var b: Button = _ability_btns[n]
		if n < kit.size():
			var spell: String = kit[n]
			var spec: Dictionary = Scenario.SPELLS[spell]
			b.visible = true
			b.text = "%d  %s" % [n + 1, spec.display_name]
			b.disabled = false
			b.modulate = Color(1.0, 0.6, 0.3) if state.armed == spell \
				else Color(1, 1, 1)
		else:
			b.visible = false
	if kit.is_empty():
		var a = sim.actors.get(hero)
		var hint := "tap an enemy to order an attack"
		if not (hero in state.commandable):
			hint = "no abilities"
		_l_hint.text = "%s — %s" % [
			a.display_name if a != null else hero, hint]
	_b_cancel.visible = state.armed != ""


## ---- events ----------------------------------------------------------

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
				if _cast_t0 >= 0.0:
					var ft := _elapsed - _cast_t0
					_say("flight %.2fs" % ft)
					_cast_t0 = -1.0
			"damage":
				pass
			"death":
				_say("%s falls" % e.actor.display_name)
				if e.actor.faction == "friendly":
					_execute(state.hero_lost(e.actor.id))
				if e.actor.id == _loot_id:
					_close_loot()
			"arrow_release":
				pass
			"command_dropped":
				_say("%s's order dropped — %s" % [e.actor, e.reason])
				_l_hint.text = "%s cannot reach that target" % e.actor
			"level_up":
				_banner = "%s REACHED LEVEL %d" % [e.actor.display_name,
					e.actor.progress.level]
				_banner_t = 2.5
				_say("LEVEL UP — %s" % e.actor.display_name)
			"encounter_end":
				_banner = "WAVE %d CLEARED" % e.group
				_banner_t = 3.0
				_say("WAVE %d CLEARED — press N for the next group" \
					% e.group)
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
			"loot_taken":
				pass
			"next_group":
				pass
			_:
				pass


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
	_refresh_bar()


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
	if _devlog:
		print("RECTS  bar=", _bar_col.get_global_rect(),
			" cancel=", _b_cancel.get_global_rect(),
			" portraits=", _portraits.get_global_rect(),
			" pause=", _b_pause.get_global_rect(),
			" vp=", get_viewport().get_visible_rect().size)


## ---- scripted drivers (--input-smoke, --poses) ------------------------

func _screen_of(id: String) -> Vector2:
	var v = views[id]
	return cam.unproject_position(v.position + Vector3(0, 1.1, 0))


func _screen_of_hex(h: Vector2i) -> Vector2:
	return cam.unproject_position(_hex_pos(h))


func _tap(screen: Vector2, touch := false) -> void:
	# feed the REAL input path — both device classes exercise it
	if touch:
		var dn := InputEventScreenTouch.new()
		dn.index = 0
		dn.pressed = true
		dn.position = screen
		Input.parse_input_event(dn)
		var up := InputEventScreenTouch.new()
		up.index = 0
		up.pressed = false
		up.position = screen
		Input.parse_input_event(up)
	else:
		var dn := InputEventMouseButton.new()
		dn.button_index = MOUSE_BUTTON_LEFT
		dn.pressed = true
		dn.position = screen
		Input.parse_input_event(dn)
		var up := InputEventMouseButton.new()
		up.button_index = MOUSE_BUTTON_LEFT
		up.pressed = false
		up.position = screen
		Input.parse_input_event(up)


func _key(action: String, code: Key) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = code
	e.keycode = code
	e.pressed = true
	Input.parse_input_event(e)


func _plan_smoke() -> void:
	var far := _far_road_hex()
	var clear := _clear_ground_screen()
	_script = [
		{t = 0.6, do = func(): _tap(_screen_of("warrior"), true)},
		{t = 1.2, do = func():
			var e0 = sim.living_enemies()[0]
			_tap(_screen_of(e0.id))},
		{t = 1.9, do = func(): _tap(clear, true)},
		{t = 2.6, do = func(): _key("ability_1", KEY_1)},
		{t = 3.3, do = func(): _tap(_screen_of("warrior"))},
		{t = 4.2, do = func(): _key("ability_2", KEY_2)},
		{t = 4.9, do = func(): _tap(clear, true)},
		{t = 5.6, do = func():
			_tap(_b_cancel.get_global_rect().get_center())},
		{t = 6.3, do = func(): _key("ability_1", KEY_1)},
		{t = 7.0, do = func(): _tap(_screen_of_hex(far))},
		{t = 7.6, do = _smoke_verdict},
	]


## A screen point that resolves to a "ground" pick: on an in-grid hex,
## well inside the viewport, and far (in px) from every actor.
func _clear_ground_screen() -> Vector2:
	var vp := get_viewport().get_visible_rect().size
	for h in sim.valid:
		if not h is Vector2i:
			continue
		var hp: Vector2i = h
		if not sim.hex_in_grid(hp):
			continue
		var sp := _screen_of_hex(hp)
		if sp.x < 60.0 or sp.y < 80.0 \
				or sp.x > vp.x - 60.0 or sp.y > vp.y - 60.0:
			continue
		var near := false
		for id in sim.actor_order:
			if _screen_of(id).distance_to(sp) < 140.0:
				near = true
				break
		if not near:
			return sp
	return Vector2(640, 400)


func _far_road_hex() -> Vector2i:
	# the road's first spawn hex — the farthest sensible ground target
	return Scenario.SPAWN_HEXES[0]


func _smoke_verdict() -> void:
	var want := ["select", "command_attack", "deselect", "armed",
		"cast_ground", "armed", "reject", "cancelled", "armed",
		"cast_ground"]
	var got: Array = _intents.filter(
		func(s): return s != "none" and s != "inspect")
	var bad := -1
	for i in want.size():
		if i >= got.size() or got[i] != want[i]:
			bad = i
			break
	if bad < 0 and got.size() == want.size():
		print("INPUT SMOKE OK")
	else:
		print("INPUT SMOKE FAIL at step %d — expected %s, got %s" % [
			bad, want, got])


func _plan_poses() -> void:
	_script = [
		# Warrior selected (ring + portrait highlight)
		{t = 0.5, do = func():
			_execute(state.primary(
				{kind = "friendly", id = "warrior",
					hex = sim.actors["warrior"].hex}))},
		# back to Althar, then Fireball armed + hover disc over the road
		{t = 2.2, do = func():
			_execute(state.primary({kind = "ground", id = "",
				hex = Vector2i(8, -2)}))},
		{t = 2.6, do = func():
			_arm_slot(0)
			_hover_gp = _hex_pos(Vector2i(8, -2))},
		# cast at mid-road — flight visible with the impact disc;
		# retry a failed Spellcasting weave a couple of times
		{t = 4.5, do = _pose_cast},
		{t = 5.0, do = _pose_cast},
		{t = 5.5, do = _pose_cast},
		{t = 6.0, do = _pose_cast},
		# Lightning armed — enemies highlighted
		{t = 8.5, do = func(): _arm_slot(1)},
		# paused overlay with the handedness toggle
		{t = 11.0, do = func(): _execute(state.toggle_pause())},
		# left-handed layout
		{t = 13.0, do = _toggle_handedness},
	]


func _pose_cast() -> void:
	if state.armed != "fireball":
		_arm_slot(0)
	if state.armed == "fireball":
		_execute(state.primary({kind = "ground", id = "",
			hex = Vector2i(10, -4)}))


func _run_script() -> void:
	while _script_i < _script.size() \
			and _elapsed >= float(_script[_script_i].t):
		_script[_script_i].do.call()
		_script_i += 1
