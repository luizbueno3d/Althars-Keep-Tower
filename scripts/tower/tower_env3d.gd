extends Node3D
## Scene 01 environment — the low-poly defensive front.
##
## Composition follows the Kingdom Rush reference's SPATIAL HIERARCHY,
## not its artwork: a substantial Keep anchoring the LEFT, one broad
## winding dirt road carrying enemies in from the far UPPER-RIGHT, an
## open fighting area, chokepoints, and two defensive towers at the
## reference's catapult positions.
##
## Presentation only. The battlefield's OCCUPANCY comes from
## `scenario_tower.cell_blocked`; this file only draws it. Every position
## here is derived from the scenario's own geometry so the picture cannot
## drift from the rules.

const D := "res://assets/dungeon/"

const ROAD_Y := 0.03
const GROUND_Y := -0.02

var torch_lights: Array = []

var _scn
var _hex


func _ready() -> void:
	_scn = load("res://scenario_tower.gd")
	_hex = load("res://sim/hex.gd")
	_build_sky()
	_build_ground()
	_build_road()
	_build_keep()
	_build_towers()
	_build_dressing()
	_build_camera()


## ---- shared helpers -------------------------------------------------

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

func _cyl(r: float, h: float, pos: Vector3, m: Material,
		segs := 12, top := -1.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = r if top < 0.0 else top
	c.bottom_radius = r
	c.height = h
	c.radial_segments = segs
	mi.mesh = c
	mi.position = pos
	mi.material_override = m
	add_child(mi)
	return mi

func _mat(c: Color, rough := 0.95) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m

func _torch(pos: Vector3) -> void:
	_prop("torch_lit", pos)
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.58, 0.22)
	l.light_energy = 3.2
	l.omni_range = 12.0
	l.omni_attenuation = 1.4
	l.shadow_enabled = false
	l.position = pos + Vector3(0, 0.7, 0)
	l.set_meta("base_e", 3.2)
	add_child(l)
	torch_lights.append(l)

## World position of a hex, including its elevation.
func hex_pos(h: Vector2i) -> Vector3:
	var p: Vector2 = _hex.to_world(h, _scn.HEX_SIZE, _scn.HEX_SQUASH)
	var y := 0.0
	if _scn.wall_kind(h) == 1:
		y = _scn.TOWER_H
	elif _scn.wall_kind(h) == 2:
		y = _scn.KEEP_TOP_H
	return Vector3(p.x * _scn.WORLD_SCALE, y, p.y * _scn.WORLD_SCALE)


## ---- the world ------------------------------------------------------

func _build_sky() -> void:
	var we := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.05, 0.08, 0.19)
	mat.sky_horizon_color = Color(0.13, 0.19, 0.32)
	mat.ground_bottom_color = Color(0.03, 0.04, 0.08)
	mat.ground_horizon_color = Color(0.09, 0.13, 0.24)
	sky.sky_material = mat
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 1.45
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	e.tonemap_exposure = 1.62
	e.glow_enabled = true
	e.glow_intensity = 0.45
	e.fog_enabled = true
	e.fog_light_color = Color(0.08, 0.11, 0.19)
	e.fog_density = 0.0022
	we.environment = e
	add_child(we)

	var moon := DirectionalLight3D.new()
	moon.light_color = Color(0.64, 0.72, 0.97)
	moon.light_energy = 1.9
	moon.shadow_enabled = true
	moon.rotation_degrees = Vector3(-48, -38, 0)
	add_child(moon)

func _build_ground() -> void:
	var g := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(170, 120)
	g.mesh = pm
	g.position = Vector3(14.0, GROUND_Y, 0.0)
	# dark forest floor: everything off the road is wilderness
	g.material_override = _mat(Color(0.10, 0.13, 0.11))
	add_child(g)

## The road is drawn FROM the scenario's own segments, so the picture and
## the walkable cells are the same object.
##
## Built from Godot primitives — a PlaneMesh per segment plus a flat
## cylinder at every joint — rather than a hand-rolled triangle strip.
## Hand-built strips get two things wrong at this shape: an offset ribbon
## self-intersects at the sharp bends the route deliberately has, and
## per-vertex normals plus winding are easy to get subtly inverted, which
## shows up as unlit black patches. Primitives have correct normals and
## cannot fold. Overlap is harmless: same opaque material.
func _build_road() -> void:
	var road_mat := _mat(Color(0.46, 0.37, 0.25))

	for seg in _scn.ROAD:
		var a: Vector2 = seg.a
		var b: Vector2 = seg.b
		var w: float = seg.w
		var d := b - a
		var length := d.length()
		if length < 0.001:
			continue
		# PlaneMesh spans local X by size.x and local Z by size.y, and
		# faces +Y. Rotate so local +X follows the segment direction.
		var plane := PlaneMesh.new()
		plane.size = Vector2(length, w * 2.0)
		var mi := MeshInstance3D.new()
		mi.mesh = plane
		mi.material_override = road_mat
		mi.position = Vector3((a.x + b.x) * 0.5, ROAD_Y,
			(a.y + b.y) * 0.5)
		mi.rotation.y = atan2(-d.y, d.x)
		add_child(mi)

		for p in [a, b]:
			var disc := CylinderMesh.new()
			disc.top_radius = w
			disc.bottom_radius = w
			disc.height = 0.02
			disc.radial_segments = 16
			var di := MeshInstance3D.new()
			di.mesh = disc
			di.material_override = road_mat
			di.position = Vector3(p.x, ROAD_Y, p.y)
			add_child(di)

func _build_keep() -> void:
	var stone := _mat(Color(0.34, 0.33, 0.36))
	var dark := _mat(Color(0.25, 0.25, 0.29))
	var x_face: float = _scn.HEX_SIZE * sqrt(3.0) * 0.5 \
		* _scn.WORLD_SCALE * float(_scn.KEEP_FACE_COL)

	# the Keep's mass — a substantial block anchoring the left edge
	_box(Vector3(20.0, 9.0, 30.0), Vector3(x_face - 8.5, 4.5, 0.0), dark)
	_box(Vector3(19.0, 2.0, 29.0), Vector3(x_face - 8.5, 10.0, 0.0), stone)

	# the keep tower rising behind the command platform
	_cyl(4.2, 20.0, Vector3(x_face - 9.0, 10.0, -7.0), stone, 14, 3.8)
	for i in 12:
		var a := TAU * float(i) / 12.0
		_box(Vector3(1.1, 1.4, 1.1), Vector3(
			x_face - 9.0 + cos(a) * 4.0, 21.0, -7.0 + sin(a) * 4.0), stone)

	# Althar's command platform: the walkable Keep top
	var top_x: float = _scn.HEX_SIZE * sqrt(3.0) * 0.5 * _scn.WORLD_SCALE
	var mid := Vector3(0.0, _scn.KEEP_TOP_H - 0.5, 0.0)
	for c in _scn.KEEP_TOP_COLS:
		mid.x += top_x * float(c)
	mid.x /= float(_scn.KEEP_TOP_COLS.size())
	_box(Vector3(6.0, 1.0, 5.0), mid, stone)
	# battlements along the platform's field edge
	for i in 5:
		_box(Vector3(1.0, 1.3, 1.0),
			Vector3(mid.x + 3.2, _scn.KEEP_TOP_H + 0.6, -2.0 + i * 1.0), dark)

	# the gate the road runs into
	_box(Vector3(3.0, 6.0, 5.0), Vector3(x_face + 0.6, 3.0, 0.0),
		_mat(Color(0.13, 0.10, 0.07)))
	_prop("wall_endcap", Vector3(x_face + 0.4, 0, -3.6), PI * 0.5)
	_prop("wall_endcap", Vector3(x_face + 0.4, 0, 3.6), PI * 0.5)
	_torch(Vector3(x_face + 2.4, 5.6, -2.4))
	_torch(Vector3(x_face + 2.4, 5.6, 2.4))

func _build_towers() -> void:
	var stone := _mat(Color(0.36, 0.34, 0.37))
	var wood := _mat(Color(0.30, 0.22, 0.14))
	var defs := [
		{hex = _scn.TOWERS.archer, label = "Archer"},
		{hex = _scn.TOWERS.healer, label = "Healer"},
	]
	for d in defs:
		var base: Vector3 = hex_pos(d.hex)
		_cyl(1.5, _scn.TOWER_H, Vector3(base.x, _scn.TOWER_H * 0.5, base.z),
			stone, 10, 1.25)
		# platform deck the hero stands on
		_cyl(1.9, 0.35, Vector3(base.x, _scn.TOWER_H - 0.1, base.z), wood, 10)
		for i in 8:
			var a := TAU * float(i) / 8.0
			_box(Vector3(0.35, 0.7, 0.35), Vector3(
				base.x + cos(a) * 1.7, _scn.TOWER_H + 0.35,
				base.z + sin(a) * 1.7), wood)
		_torch(Vector3(base.x + 1.5, _scn.TOWER_H - 0.6, base.z))

func _build_dressing() -> void:
	for p in _scn.FIELD_PROPS:
		_prop(p.kind, p.pos, p.get("rot", 0.0), p.get("scale", 1.0))
	# wilderness silhouette: tree clumps off the road, on both flanks
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 60:
		var x := rng.randf_range(-6.0, 52.0)
		var z := rng.randf_range(-19.0, 19.0)
		var h: Vector2i = _hex.to_coord(x / _scn.WORLD_SCALE,
			z / _scn.WORLD_SCALE, _scn.HEX_SIZE, _scn.HEX_SQUASH)
		# well clear of the road: a prop whose cell centre is just off
		# the road can still render inside the drawn ribbon, which reads
		# as an obstacle standing on the route
		if _scn.cell_blocked(h) == false or _scn.wall_kind(h) != 0:
			continue
		if _scn.road_distance(h) < 7.0:
			continue
		var s := rng.randf_range(0.9, 1.8)
		var kind := "trunk_large_A" if i % 3 else "rubble_large"
		_prop(kind, Vector3(x, 0.0, z), rng.randf_range(0.0, TAU), s)

func _build_camera() -> void:
	var cam := Camera3D.new()
	cam.position = Vector3(29.0, 54.0, 60.0)
	cam.fov = 50.0
	add_child(cam)
	cam.look_at(Vector3(12.0, 0.0, 0.0))
	cam.make_current()

func _process(_dt: float) -> void:
	for i in torch_lights.size():
		var l: OmniLight3D = torch_lights[i]
		var base: float = l.get_meta("base_e")
		l.light_energy = base \
			+ sin(Time.get_ticks_msec() * 0.011 + i * 1.7) * 0.4 \
			+ sin(Time.get_ticks_msec() * 0.031 + i) * 0.18
