extends RefCounted
## Procedural low-poly bodies for the five heroes.
##
## Built from Godot primitives rather than sculpted assets: cheap to
## iterate, trivially re-colourable, and consistent with the stylized
## low-poly direction. The job here is SILHOUETTE and ROLE READABILITY at
## tactical camera distance — not character art. Each hero is
## distinguishable by shape and palette alone:
##
##   Wizard     tall pointed hat + robe + glowing staff orb (violet)
##   Warrior    boxy plate + kite shield + sword (steel / stronghold blue)
##   Barbarian  widest build, bare skin + fur, greataxe raised (earth tones)
##   Archer     slim + hood + bow arc + quiver (forest green)
##   Healer     cream robe + circlet + symbol staff (ivory / gold)
##
## Everything is parented so the whole body can be tipped over on death,
## and so `tower_actor_view` can sway it when there is no AnimationPlayer.

const SKIN := Color(0.80, 0.62, 0.48)
const STEEL := Color(0.46, 0.49, 0.55)
const WOOD := Color(0.36, 0.26, 0.16)
const LEATHER := Color(0.34, 0.25, 0.17)

## Humanoid height in metres — the same scale the KayKit bodies sit at.
const H := 1.9

static func build(id: String) -> Node3D:
	match id:
		"wizard": return _wizard()
		"warrior": return _warrior()
		"barbarian": return _barbarian()
		"archer": return _archer()
		"healer": return _healer()
	return _warrior()


## ---- primitive helpers ----------------------------------------------

static func _mat(c: Color, rough := 0.9, metal := 0.0,
		emission := Color(0, 0, 0, 0)) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	if emission.a > 0.0:
		m.emission_enabled = true
		m.emission = emission
		m.emission_energy_multiplier = 2.2
	return m

static func _box(p: Node3D, size: Vector3, pos: Vector3, c: Color,
		rot := Vector3.ZERO, metal := 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.position = pos
	mi.rotation = rot
	mi.material_override = _mat(c, 0.85, metal)
	p.add_child(mi)
	return mi

static func _cyl(p: Node3D, r0: float, r1: float, h: float, pos: Vector3,
		c: Color, segs := 10, metal := 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.bottom_radius = r0
	cm.top_radius = r1
	cm.height = h
	cm.radial_segments = segs
	mi.mesh = cm
	mi.position = pos
	mi.material_override = _mat(c, 0.85, metal)
	p.add_child(mi)
	return mi

static func _ball(p: Node3D, r: float, pos: Vector3, c: Color,
		emission := Color(0, 0, 0, 0)) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	mi.mesh = s
	mi.position = pos
	mi.material_override = _mat(c, 0.7, 0.0, emission)
	p.add_child(mi)
	return mi

## Shared legs + arms so every body has a consistent humanoid frame.
static func _limbs(p: Node3D, c: Color, arm_c := Color(0, 0, 0, 0),
		leg_c := Color(0, 0, 0, 0)) -> void:
	var ac: Color = arm_c if arm_c.a > 0.0 else c
	var lc: Color = leg_c if leg_c.a > 0.0 else c
	for sx in [-1.0, 1.0]:
		_box(p, Vector3(0.22, 0.82, 0.24), Vector3(sx * 0.17, 0.41, 0.0), lc)
		_box(p, Vector3(0.17, 0.60, 0.19), Vector3(sx * 0.42, 1.20, 0.0), ac)

static func _head(p: Node3D, y: float, c: Color, r := 0.17) -> MeshInstance3D:
	return _ball(p, r, Vector3(0.0, y, 0.0), c)

## A held weapon pivots on the right hand by default.
static func _hand(p: Node3D, side := 1.0) -> Node3D:
	var n := Node3D.new()
	n.position = Vector3(side * 0.46, 1.10, 0.06)
	p.add_child(n)
	return n


## ---- the five heroes -------------------------------------------------

static func _wizard() -> Node3D:
	var p := Node3D.new()
	var robe := Color(0.27, 0.23, 0.54)
	var trim := Color(0.76, 0.63, 0.29)
	_cyl(p, 0.34, 0.20, 1.30, Vector3(0, 0.65, 0), robe, 10)
	_cyl(p, 0.36, 0.30, 0.22, Vector3(0, 1.32, 0), trim, 10)
	_box(p, Vector3(0.50, 0.62, 0.30), Vector3(0, 1.20, 0), robe)
	# mantle
	_cyl(p, 0.34, 0.14, 0.30, Vector3(0, 1.52, 0), robe, 10)
	# pointed wide-brim hat — the silhouette that reads at distance
	_cyl(p, 0.40, 0.40, 0.05, Vector3(0, 1.72, 0), robe, 12)
	_cyl(p, 0.22, 0.0, 0.46, Vector3(0, 1.96, 0), robe, 10)
	# beard
	_cyl(p, 0.13, 0.0, 0.26, Vector3(0, 1.62, 0.10),
		Color(0.82, 0.82, 0.80), 8)
	_ball(p, 0.15, Vector3(0, 1.80, 0.0), SKIN)
	# staff with a glowing orb
	var staff := _hand(p, 1.0)
	_cyl(staff, 0.035, 0.035, 1.55, Vector3(0, 0.10, 0), WOOD, 6)
	_ball(staff, 0.13, Vector3(0, 0.92, 0), Color(0.68, 0.50, 1.0),
		Color(0.55, 0.35, 1.0))
	var l := OmniLight3D.new()
	l.light_color = Color(0.62, 0.42, 1.0)
	l.light_energy = 2.4
	l.omni_range = 6.0
	l.position = Vector3(0, 0.92, 0)
	staff.add_child(l)
	return p


static func _warrior() -> Node3D:
	var p := Node3D.new()
	var plate := STEEL
	var tabard := Color(0.24, 0.34, 0.60)
	_limbs(p, plate, plate, Color(0.38, 0.41, 0.47))
	_box(p, Vector3(0.66, 0.68, 0.36), Vector3(0, 1.22, 0), plate)
	_box(p, Vector3(0.40, 0.62, 0.38), Vector3(0, 1.24, 0.02), tabard)
	# pauldrons
	for sx in [-1.0, 1.0]:
		_box(p, Vector3(0.22, 0.20, 0.34), Vector3(sx * 0.40, 1.48, 0),
			plate)
	# helm with a nose guard
	_box(p, Vector3(0.34, 0.32, 0.34), Vector3(0, 1.80, 0), plate)
	_box(p, Vector3(0.05, 0.26, 0.06), Vector3(0, 1.78, 0.17),
		Color(0.30, 0.32, 0.37))
	# sword, raised
	var sw := _hand(p, 1.0)
	_box(sw, Vector3(0.05, 0.86, 0.14), Vector3(0, 0.42, 0), STEEL, 
		Vector3.ZERO, 0.7)
	_box(sw, Vector3(0.22, 0.05, 0.06), Vector3(0, 0.02, 0), WOOD)
	# kite shield on the other side
	var sh := _hand(p, -1.0)
	_box(sh, Vector3(0.46, 0.62, 0.07), Vector3(0, 0.10, 0.10), tabard)
	_box(sh, Vector3(0.10, 0.62, 0.09), Vector3(0, 0.10, 0.11), plate)
	return p


static func _barbarian() -> Node3D:
	var p := Node3D.new()
	var fur := Color(0.42, 0.31, 0.22)
	_limbs(p, SKIN, SKIN, LEATHER)
	# broad bare torso — the widest silhouette in the party
	_box(p, Vector3(0.78, 0.66, 0.38), Vector3(0, 1.24, 0), SKIN)
	_box(p, Vector3(0.62, 0.22, 0.36), Vector3(0, 1.02, 0), LEATHER)
	# fur mantle over the shoulders
	_cyl(p, 0.44, 0.30, 0.24, Vector3(0, 1.56, 0), fur, 10)
	_head(p, 1.82, SKIN, 0.18)
	_cyl(p, 0.20, 0.20, 0.14, Vector3(0, 1.92, 0), fur, 8)
	# greataxe, raised overhead
	var ax := _hand(p, 1.0)
	ax.position = Vector3(0.42, 1.30, 0.10)
	_cyl(ax, 0.045, 0.045, 1.70, Vector3(0, 0.30, 0), WOOD, 6)
	_box(ax, Vector3(0.10, 0.40, 0.34), Vector3(0, 1.05, 0.20), STEEL, 
		Vector3.ZERO, 0.6)
	_box(ax, Vector3(0.12, 0.16, 0.20), Vector3(0, 1.05, -0.06), STEEL)
	return p


static func _archer() -> Node3D:
	var p := Node3D.new()
	var leather := Color(0.30, 0.40, 0.29)
	var hood := Color(0.22, 0.32, 0.25)
	_limbs(p, leather, leather, Color(0.26, 0.30, 0.24))
	_box(p, Vector3(0.52, 0.66, 0.30), Vector3(0, 1.22, 0), leather)
	# hood — a slim cone, not the Wizard's wide brim
	_cyl(p, 0.24, 0.03, 0.36, Vector3(0, 1.86, 0), hood, 9)
	_ball(p, 0.15, Vector3(0, 1.74, 0), SKIN)
	# quiver on the back
	_cyl(p, 0.09, 0.09, 0.52, Vector3(-0.16, 1.30, -0.24), LEATHER, 7)
	# bow in the left hand: three limbs + a string
	var bow := _hand(p, -1.0)
	bow.position = Vector3(-0.46, 1.05, 0.12)
	_box(bow, Vector3(0.045, 0.42, 0.045), Vector3(0, 0.26, 0), WOOD,
		Vector3(0, 0, -0.22))
	_box(bow, Vector3(0.045, 0.42, 0.045), Vector3(0, -0.26, 0), WOOD,
		Vector3(0, 0, 0.22))
	_box(bow, Vector3(0.05, 0.14, 0.05), Vector3(0, 0.0, 0.02), LEATHER)
	_box(bow, Vector3(0.012, 0.98, 0.012), Vector3(0.06, 0.0, 0.0),
		Color(0.85, 0.85, 0.82))
	return p


static func _healer() -> Node3D:
	var p := Node3D.new()
	var robe := Color(0.87, 0.83, 0.71)
	var trim := Color(0.80, 0.66, 0.32)
	_cyl(p, 0.32, 0.19, 1.34, Vector3(0, 0.67, 0), robe, 10)
	_box(p, Vector3(0.48, 0.60, 0.28), Vector3(0, 1.22, 0), robe)
	_box(p, Vector3(0.22, 0.58, 0.30), Vector3(0, 1.24, 0.02), trim)
	_head(p, 1.78, Color(0.62, 0.46, 0.34), 0.17)
	# circlet
	_cyl(p, 0.18, 0.18, 0.05, Vector3(0, 1.90, 0), trim, 10)
	# short grey beard — mature, and distinct from the Wizard's
	_cyl(p, 0.12, 0.0, 0.20, Vector3(0, 1.64, 0.09),
		Color(0.72, 0.72, 0.70), 8)
	# staff with a symbol
	var st := _hand(p, 1.0)
	_cyl(st, 0.033, 0.033, 1.45, Vector3(0, 0.05, 0), WOOD, 6)
	_box(st, Vector3(0.22, 0.22, 0.05), Vector3(0, 0.80, 0), trim)
	_box(st, Vector3(0.07, 0.30, 0.07), Vector3(0, 0.80, 0), robe)
	return p
