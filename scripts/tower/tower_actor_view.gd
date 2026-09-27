extends Node3D
## Tower actor view — one 3D body per simulated actor.
##
## PHASE 0 SCOPE: the Wizard and the skeletons use the real KayKit CC0
## low-poly GLBs (the frozen 0.2 art language). The four martial heroes
## have no low-poly body yet — KayKit's Adventurers pack was licensed
## into Althar's Keep but only its Mage survived — so they render as
## deliberate placeholder figures. Phase 2 replaces them.
##
## This view is presentation only: it reads actor state and never writes
## to the simulation.

const SCALE := 1.0

const WIZARD_GLB := "res://assets/characters/Mage.glb"
const SKELETON_GLB := "res://assets/characters/Skeleton_Minion.glb"

## KayKit clips are consistent across the packs.
const IDLE := ["Idle", "idle"]
const WALK := ["Walking_A", "Walk", "walk", "Running_A"]
const DEATH := ["Death_A", "Death", "death"]
const ATTACK := ["1H_Melee_Attack_Chop", "Attack", "attack"]
const CAST := ["Spellcasting", "Spellcast_Shoot", "Cast"]

## Hero placeholder palette — reads the role at a glance until the real
## low-poly bodies arrive. Enemy bodies are the GLB's own material.
const HERO_TINT := {
	"wizard": Color(0.42, 0.36, 0.78),
	"warrior": Color(0.36, 0.47, 0.72),
	"barbarian": Color(0.72, 0.42, 0.28),
	"archer": Color(0.34, 0.60, 0.42),
	"healer": Color(0.86, 0.82, 0.68),
}

var actor
var friendly := false

var label: Label3D
var _model: Node3D
var _anim: AnimationPlayer
var _rest := ""
var _placeheld := false
var _last_hex := Vector2i(9999, 9999)


func _ready() -> void:
	label = Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0, 2.15, 0)
	label.font_size = 44
	label.outline_size = 9
	label.modulate = Color(0.92, 0.90, 0.84, 0.95)
	add_child(label)


func bind(a, is_friendly: bool) -> void:
	actor = a
	friendly = is_friendly
	label.text = a.display_name
	label.modulate = Color(0.94, 0.90, 0.72, 0.95) if friendly \
		else Color(0.88, 0.84, 0.80, 0.85)

	if _model == null:
		_model = _build_body(a)
		add_child(_model)
		_anim = _model.find_child("*AnimationPlayer*", true, false)
		_rest = _find_anim(IDLE)
		if _anim != null and _rest != "":
			_anim.get_animation(_rest).loop_mode = Animation.LOOP_LINEAR
			_anim.play(_rest)
			_anim.seek(randf() * 2.0, true)   # desync the group's idles
	_place(a.hex)


## Position only when the hex actually changed, so a view can be polled
## every frame cheaply.
func _place(h: Vector2i) -> void:
	if h == _last_hex:
		return
	_last_hex = h
	position = _hex_world(h)


func refresh() -> void:
	if actor == null:
		return
	_place(actor.hex)
	if not actor.alive:
		died()


func died() -> void:
	var clip := _find_anim(DEATH)
	if _anim != null and clip != "":
		_anim.play(clip)
		_anim.seek(0.0, true)
	# tip a placeholder over so a corpse still reads as a corpse
	if _placeheld:
		rotation.z = PI * 0.42
	label.modulate.a = 0.35


## ---- bodies -------------------------------------------------------

func _build_body(a) -> Node3D:
	if a.id == "wizard":
		var n := _load_glb(WIZARD_GLB)
		if n != null:
			return n
	elif a.faction == "enemy":
		var n := _load_glb(SKELETON_GLB)
		if n != null:
			return n
	return _placeholder(a)


## A deliberate, readable stand-in — a tinted low-poly figure — until the
## hero bodies exist. Not an attempt at art.
func _placeholder(a) -> Node3D:
	_placeheld = true
	var root := Node3D.new()
	var tint: Color = HERO_TINT.get(a.id, Color(0.6, 0.6, 0.6))

	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.34
	cap.height = 1.35
	body.mesh = cap
	body.position = Vector3(0, 0.85, 0)
	body.material_override = _mat(tint)
	root.add_child(body)

	var head := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.26
	sph.height = 0.52
	head.mesh = sph
	head.position = Vector3(0, 1.72, 0)
	head.material_override = _mat(tint.lightened(0.15))
	root.add_child(head)

	return root


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.85
	return m


func _load_glb(path: String) -> Node3D:
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_file(path, st) != OK:
		push_warning("tower: could not load " + path)
		return null
	var n: Node3D = doc.generate_scene(st)
	n.scale = Vector3.ONE * SCALE
	return n


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
	# An actor posted on the battlement stands ON the walk, not inside
	# the masonry. The simulation's elevation is `wall_kind` (a level,
	# not a height); this is the presentation's matching lift.
	var y := 0.0
	if actor != null and (actor.elevated or Scenario.wall_kind(h) > 0):
		y = Scenario.TOWER.walk_h
	return Vector3(p.x * Scenario.WORLD_SCALE, y,
		p.y * Scenario.WORLD_SCALE)
