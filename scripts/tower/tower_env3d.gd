extends Node3D
## Tower environment — the low-poly defensive front (README §50).
##
## One approach corridor: the gate tower at the west end, cliffs north
## and south, the treeline east. Built from KayKit Dungeon CC0 pieces
## plus simple procedural geometry, in the frozen 0.2 art language —
## deliberately NOT the cinematic PBR fortress.
##
## Presentation only. The battlefield's OCCUPANCY comes from
## `scenario_tower.cell_blocked`; this file only draws it.

const D := "res://assets/dungeon/"

var torch_lights: Array = []

var _scn
var _hex

func _ready() -> void:
	_scn = load("res://scenario_tower.gd")
	_hex = load("res://sim/hex.gd")
	_build_sky()
	_build_ground()
	_build_tower()
	_build_battlement()
	_build_cliffs()
	_build_field_props()
	_build_camera()


## ---- hex <-> world (must match the simulation's mapping) -----------
func col_x(col: float) -> float:
	return col * _scn.HEX_SIZE * sqrt(3.0) * 0.5 * _scn.WORLD_SCALE

func row_z(r: float) -> float:
	return r * _scn.HEX_SIZE * 1.5 * _scn.HEX_SQUASH * _scn.WORLD_SCALE

func hex_pos(h: Vector2i) -> Vector3:
	var p: Vector2 = _hex.to_world(h, _scn.HEX_SIZE, _scn.HEX_SQUASH)
	return Vector3(p.x * _scn.WORLD_SCALE, 0.0, p.y * _scn.WORLD_SCALE)


## ---- shared builders ----------------------------------------------

func _prop(name: String, pos: Vector3, rot_y := 0.0, s := 1.0) -> Node3D:
	var path := D + name + ".glb"
	if not ResourceLoader.exists(path):
		return Node3D.new()
	var p: Node3D = load(path).instantiate()
	p.position = pos
	p.rotation.y = rot_y
	p.scale = Vector3.ONE * s
	add_child(p)
	return p

func _box(size: Vector3, pos: Vector3, m: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = m
	add_child(mi)
	return mi

func _mat(c: Color, rough := 0.95) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m

func _unlit(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	return m

func _torch(pos: Vector3) -> void:
	_prop("torch_lit", pos)
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.58, 0.22)
	l.light_energy = 3.0
	l.omni_range = 11.0
	l.omni_attenuation = 1.4
	l.shadow_enabled = false
	l.position = pos + Vector3(0, 0.7, 0)
	l.set_meta("base_e", 3.0)
	add_child(l)
	torch_lights.append(l)


## ---- the world -----------------------------------------------------

func _build_sky() -> void:
	var we := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.04, 0.07, 0.18)
	mat.sky_horizon_color = Color(0.11, 0.16, 0.30)
	mat.ground_bottom_color = Color(0.02, 0.03, 0.07)
	mat.ground_horizon_color = Color(0.08, 0.11, 0.22)
	sky.sky_material = mat
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 1.20
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	e.tonemap_exposure = 1.55
	e.glow_enabled = true
	e.glow_intensity = 0.5
	e.fog_enabled = true
	e.fog_light_color = Color(0.07, 0.10, 0.18)
	e.fog_density = 0.003
	we.environment = e
	add_child(we)

	var moon := DirectionalLight3D.new()
	moon.light_color = Color(0.62, 0.70, 0.96)
	moon.light_energy = 1.75
	moon.shadow_enabled = true
	moon.rotation_degrees = Vector3(-52, -34, 0)
	add_child(moon)

func _build_ground() -> void:
	var x0 := col_x(_scn.TOWER_FACE_COL)
	var x1 := col_x(_scn.CORRIDOR_END_COL)
	var half := row_z(_scn.CORRIDOR_HALF_R + 1)

	# outer ground (cliff tops / background)
	var outer := MeshInstance3D.new()
	var op := PlaneMesh.new()
	op.size = Vector2(150, 110)
	outer.mesh = op
	outer.position = Vector3((x0 + x1) * 0.5, -0.02, 0)
	outer.material_override = _mat(Color(0.07, 0.08, 0.09))
	add_child(outer)

	# the corridor floor, slightly proud so the walkable band reads
	var floor_mi := MeshInstance3D.new()
	var fm := PlaneMesh.new()
	fm.size = Vector2(x1 - x0 + 6.0, half * 2.0)
	floor_mi.mesh = fm
	floor_mi.position = Vector3((x0 + x1) * 0.5, 0.0, 0)
	floor_mi.material_override = _mat(Color(0.26, 0.27, 0.20))
	add_child(floor_mi)

func _build_tower() -> void:
	var x_face := col_x(_scn.TOWER_FACE_COL)
	var stone := _mat(Color(0.30, 0.30, 0.33))
	var dark := _mat(Color(0.24, 0.24, 0.27))

	# the tower mass west of the face
	_box(Vector3(13.0, 10.0, 20.0), Vector3(x_face - 6.5, 5.0, 0.0), dark)

	# the gate tower itself — a cylinder with a crenellated crown
	var tw := 3.6
	var th := 15.0
	var tower := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = tw
	cyl.bottom_radius = tw * 1.12
	cyl.height = th
	cyl.radial_segments = 14
	tower.mesh = cyl
	tower.position = Vector3(x_face - 1.0, th * 0.5, 0.0)
	tower.material_override = stone
	add_child(tower)

	var crown := MeshInstance3D.new()
	var cc := CylinderMesh.new()
	cc.top_radius = tw + 0.7
	cc.bottom_radius = tw + 0.7
	cc.height = 0.8
	cc.radial_segments = 14
	crown.mesh = cc
	crown.position = Vector3(x_face - 1.0, th + 0.4, 0.0)
	crown.material_override = dark
	add_child(crown)

	# crenellations
	for i in 12:
		var a := TAU * float(i) / 12.0
		_box(Vector3(0.9, 1.2, 0.9),
			Vector3(x_face - 1.0 + cos(a) * (tw + 0.3),
				th + 1.4, sin(a) * (tw + 0.3)), stone)

	# gate opening + door
	_box(Vector3(3.0, 5.0, 4.4),
		Vector3(x_face + 0.4, 2.5, 0.0), _mat(Color(0.13, 0.10, 0.07)))
	_prop("wall_endcap", Vector3(x_face + 0.2, 0, -3.4), PI * 0.5)
	_prop("wall_endcap", Vector3(x_face + 0.2, 0, 3.4), PI * 0.5)

func _build_battlement() -> void:
	# KayKit wall pieces run the curtain along the battlement column
	var x_wall := col_x(_scn.WALL_COL)
	var half := row_z(_scn.CORRIDOR_HALF_R + 0.6)
	var seg := 4.0
	var n := int(ceil((half * 2.0) / seg))
	for i in n:
		var z := -half + seg * 0.5 + i * seg
		_prop("wall", Vector3(x_wall, 0, z), PI * 0.5)
	# light the tower end so the defenders posted on the walk read
	var walk: float = _scn.TOWER.walk_h
	_torch(Vector3(x_wall + 0.7, walk + 0.6, -5.5))
	_torch(Vector3(x_wall + 0.7, walk + 0.6, 0.0))
	_torch(Vector3(x_wall + 0.7, walk + 0.6, 5.5))
	_torch(Vector3(x_wall + 1.4, 0.0, -3.0))
	_torch(Vector3(x_wall + 1.4, 0.0, 3.0))

func _build_cliffs() -> void:
	# impassable geography north and south (README §50) — the corridor
	# is the single defensive front
	var rock := _mat(Color(0.16, 0.16, 0.18))
	var x0 := col_x(_scn.TOWER_FACE_COL)
	var x1 := col_x(_scn.CORRIDOR_END_COL)
	var z := row_z(_scn.CORRIDOR_HALF_R) + 2.2
	var mid := (x0 + x1) * 0.5
	var len_x := x1 - x0 + 10.0
	for s in [-1.0, 1.0]:
		_box(Vector3(len_x, 7.0, 4.0), Vector3(mid, 3.5, s * z), rock)
	# treeline closing the east end
	_box(Vector3(4.0, 8.0, 30.0),
		Vector3(x1 + 3.5, 4.0, 0.0), _mat(Color(0.08, 0.11, 0.08)))

func _build_field_props() -> void:
	for p in _scn.FIELD_PROPS:
		var rot: float = p.get("rot", 0.0)
		var s: float = p.get("scale", 1.0)
		_prop(p.kind, p.pos, rot, s)

func _build_camera() -> void:
	var cam := Camera3D.new()
	# elevated three-quarter view down the corridor: the tower reads at
	# the west end, the whole approach and the treeline stay in frame
	cam.position = Vector3(31.0, 41.0, 35.0)
	cam.fov = 50.0
	add_child(cam)
	cam.look_at(Vector3(8.0, 0.0, 0.0))
	cam.make_current()

func _process(_dt: float) -> void:
	for i in torch_lights.size():
		var l: OmniLight3D = torch_lights[i]
		var base: float = l.get_meta("base_e")
		l.light_energy = base \
			+ sin(Time.get_ticks_msec() * 0.011 + i * 1.7) * 0.4 \
			+ sin(Time.get_ticks_msec() * 0.031 + i) * 0.18
