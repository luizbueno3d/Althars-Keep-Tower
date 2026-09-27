extends Node3D
## Tower actor view — one 3D body per simulated actor.
##
## Heroes are PROCEDURAL low-poly bodies (scripts/tower/hero_bodies.gd):
## cheap to iterate and consistent with the stylized direction. Enemies
## use the KayKit CC0 low-poly GLBs — chibi skeletons whose oversized
## helmets read well at tactical distance.
##
## Presentation only: this view reads actor state and never writes to the
## simulation.

const Bodies = preload("res://scripts/tower/hero_bodies.gd")

const SKELETON_GLB := "res://assets/characters/Skeleton_Minion.glb"

const IDLE := ["Idle", "idle"]
const DEATH := ["Death_A", "Death", "death"]

var actor
var friendly := false

var label: Label3D
var _ring: MeshInstance3D
var _model: Node3D
var _anim: AnimationPlayer
var _rest := ""
var _procedural := false
var _last_hex := Vector2i(9999, 9999)
var _last_lp := -1
var _sway := 0.0
var _dead := false


func _ready() -> void:
	# Ground marker: at full-scene framing a 1.9 m body is only a few
	# pixels tall, so each actor also carries a flat coloured disc under
	# its feet. Side is readable from the colour before any model detail
	# resolves.
	_ring = MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 1.05
	disc.bottom_radius = 1.05
	disc.height = 0.04
	disc.radial_segments = 16
	_ring.mesh = disc
	_ring.position = Vector3(0, 0.03, 0)
	add_child(_ring)

	label = Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0, 2.55, 0)
	label.font_size = 56
	label.outline_size = 9
	label.modulate = Color(0.92, 0.90, 0.84, 0.95)
	add_child(label)


func bind(a, is_friendly: bool) -> void:
	actor = a
	friendly = is_friendly
	_dead = false
	rotation.z = 0.0
	_last_lp = -1

	var rc := Color(0.35, 0.85, 0.45) if friendly else Color(0.85, 0.30, 0.25)
	var rm := StandardMaterial3D.new()
	rm.albedo_color = Color(rc.r, rc.g, rc.b, 0.85)
	rm.emission_enabled = true
	rm.emission = rc
	rm.emission_energy_multiplier = 0.5
	rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring.material_override = rm
	_ring.visible = true

	if _model == null:
		_model = _build_body(a)
		add_child(_model)
		_anim = _model.find_child("*AnimationPlayer*", true, false)
		_rest = _find_anim(IDLE)
		if _anim != null and _rest != "":
			_anim.get_animation(_rest).loop_mode = Animation.LOOP_LINEAR
			_anim.play(_rest)
			_anim.seek(randf() * 2.0, true)   # desync the group's idles
	# enemies watch the Keep; the party faces the field
	if _anim != null:
		_model.rotation.y = -PI * 0.25 if friendly else PI * 0.75
	_place(a.hex)
	_refresh_label()


func _build_body(a) -> Node3D:
	if a.faction == "friendly":
		_procedural = true
		return Bodies.build(a.id)
	var n := _load_glb(SKELETON_GLB)
	if n != null:
		return n
	_procedural = true
	return Bodies.build("warrior")


## Position only when the hex actually changed, so the view can be polled
## every frame cheaply. Posted actors stand ON their structure.
func _place(h: Vector2i) -> void:
	if h == _last_hex:
		return
	_last_hex = h
	position = _hex_world(h)


func refresh() -> void:
	if actor == null:
		return
	_place(actor.hex)
	if actor.lp != _last_lp:
		_last_lp = actor.lp
		_refresh_label()
	if not actor.alive and not _dead:
		died()


func _refresh_label() -> void:
	if actor == null:
		return
	if friendly:
		label.text = actor.display_name
		label.modulate = Color(0.95, 0.92, 0.74, 0.95)
	else:
		label.text = "%s  %d/%d" % [actor.display_name, actor.lp,
			actor.max_lp]
		label.modulate = Color(0.90, 0.86, 0.82, 0.90)


func died() -> void:
	_dead = true
	if _ring != null:
		_ring.visible = false
	var clip := _find_anim(DEATH)
	if _anim != null and clip != "":
		_anim.play(clip)
		_anim.seek(0.0, true)
	elif _procedural:
		# a procedural body has no death clip — tip it over so a corpse
		# still reads as a corpse
		rotation.z = PI * 0.42
	label.modulate.a = 0.30


## Procedural bodies have no AnimationPlayer, so they get a cheap idle
## sway here: enough that a standing group does not look frozen.
func _process(dt: float) -> void:
	if _procedural and _model != null and actor != null and actor.alive:
		_sway += dt
		_model.position.y = sin(_sway * 2.1) * 0.035
		_model.rotation.z = sin(_sway * 1.3) * 0.03
	if _dead and label != null:
		label.modulate.a = maxf(0.0, label.modulate.a - dt * 0.25)


func _load_glb(path: String) -> Node3D:
	if not ResourceLoader.exists(path):
		return null
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_file(path, st) != OK:
		return null
	return doc.generate_scene(st)


func _find_anim(names: Array) -> String:
	if _anim == null:
		return ""
	for n in names:
		if _anim.has_animation(n):
			return n
	return ""


func _hex_world(h: Vector2i) -> Vector3:
	var Scenario = load("res://scenario_tower.gd")
	var Hex = load("res://sim/hex.gd")
	var p: Vector2 = Hex.to_world(h, Scenario.HEX_SIZE, Scenario.HEX_SQUASH)
	# elevation is a LEVEL in the sim and a HEIGHT in the picture; the
	# scenario owns both so they cannot disagree
	var y := 0.0
	match Scenario.wall_kind(h):
		1: y = Scenario.TOWER_H
		2: y = Scenario.KEEP_TOP_H
	return Vector3(p.x * Scenario.WORLD_SCALE, y,
		p.y * Scenario.WORLD_SCALE)
