extends RefCounted
## A defended structure — the Keep.
##
## Its pool is INTEGRITY, deliberately NOT LP: LP belongs to living
## characters. The Keep is masonry, not a creature, and calling its pool
## LP would be a lie the rest of the rules would then have to live with.
##
## Damage arrives through the SAME typed packet pipeline creatures use:
## `sim/damage.gd` already reads `.resist` and `.armor` off whatever it
## is handed, so a structure folds typed damage exactly like an actor
## does. Material response is therefore a DATA question, not a special
## case in combat — which is what makes fire/impact/cold matter against
## masonry later without new code.
##
## MVP scope: one Integrity pool and a derived state label. No gates, no
## per-section walls, no repairs, no materials beyond a name — the
## architecture is here so those can arrive without a rewrite.

## Derived from the integrity fraction. Presentation reads this.
const STATES := ["INTACT", "DAMAGED", "HEAVILY_DAMAGED", "BREACHED"]

var id: String
var display_name: String
var hex: Vector2i
var max_integrity: int
var integrity: int
var material := "stone"
var resist := {}      # damage type -> multiplier (same shape as actor.resist)
var armor := {}       # {lp = flat} — mitigates the injury path only
var alive := true

static func create(d: Dictionary) -> RefCounted:
	var s = (load("res://sim/structure.gd") as GDScript).new()
	s.id = d.id
	s.display_name = d.get("display_name", d.id)
	s.hex = d.hex
	s.max_integrity = int(d.get("integrity", 100))
	s.integrity = s.max_integrity
	s.material = d.get("material", "stone")
	s.resist = d.get("resist", {}).duplicate()
	s.armor = d.get("armor", {}).duplicate()
	return s

## Apply ALREADY-EFFECTIVE damage (resist folded, armor subtracted by the
## caller via sim/damage.gd). Returns true if this blow broke it.
func apply_damage(n: int) -> bool:
	if not alive:
		return false
	integrity -= maxi(0, n)
	if integrity <= 0:
		integrity = 0
		alive = false
		return true
	return false

func fraction() -> float:
	return float(integrity) / float(maxi(1, max_integrity))

## Restore up to `n` Integrity, capped at max. Returns the amount actually
## restored. Who does the restoring — and with what — is a scenario
## question; the Keep workers of the Scene 01 spec are the intended
## source, and this is the hook they will use.
func repair(n: int) -> int:
	if n <= 0 or not alive:
		return 0
	var before := integrity
	integrity = mini(max_integrity, integrity + n)
	return integrity - before

func state() -> String:
	var f := fraction()
	if f <= 0.0:
		return "BREACHED"
	if f <= 0.25:
		return "HEAVILY_DAMAGED"
	if f <= 0.60:
		return "DAMAGED"
	return "INTACT"

func to_dict() -> Dictionary:
	return {integrity = integrity, max_integrity = max_integrity,
		alive = alive}

func apply_dict(d: Dictionary) -> void:
	integrity = int(d.get("integrity", integrity))
	max_integrity = int(d.get("max_integrity", max_integrity))
	alive = bool(d.get("alive", alive))
