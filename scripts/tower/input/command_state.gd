extends RefCounted
## Tower input state machine — the testable core of the command and
## spell-targeting model. PURE: no Node/Input/SceneTree APIs.
## Presentation resolves taps into picks and executes the intents
## this machine returns; device mapping (mouse/touch/keys) is a
## separate layer.
##
## A pick is a Dictionary: {kind = "enemy"|"friendly"|"corpse"|"ground"|
## "none", id = actor id or "", hex = Vector2i}. "corpse" is a dead
## actor carrying loot; "none" is off the battlefield.
##
## Every method returns ONE intent Dictionary with a `type`:
##   none · select{id} · deselect · inspect{id} · open_loot{id}
##   command_attack{hero,target} · cast_ground{caster,ability,hex}
##   cast_actor{caster,ability,target} · armed{caster,ability}
##   cancelled{ability} · reject{reason} · paused · resumed
##   modal_closed{name}

enum Mode { NORMAL, HERO_SELECTED, ABILITY_ARMED }

const DEFAULT_HERO := "wizard"
const T_GROUND := "ground"
const T_ENEMY := "enemy"

var mode := Mode.NORMAL
var selected := DEFAULT_HERO    # the ACTIVE hero; DEFAULT_HERO in NORMAL
var armed := ""                 # ability id while ABILITY_ARMED
var armed_by := ""              # caster (the active hero when armed)
var armed_mode := ""            # Targeting mode string of the ability
var _prev_mode := Mode.NORMAL   # restored on cancel / resolved
var paused := false             # ORTHOGONAL — never alters mode/selection
var modal := ""                 # "", "loot", "menu", "save" — orthogonal
var commandable: Array          # heroes that take a direct attack order

func _init(p_commandable: Array = ["warrior", "barbarian"]) -> void:
	commandable = p_commandable

func active_hero() -> String:
	return selected

func _select(id: String) -> Dictionary:
	mode = Mode.HERO_SELECTED
	selected = id
	return {type = "select", id = id}

func _deselect() -> Dictionary:
	mode = Mode.NORMAL
	selected = DEFAULT_HERO
	return {type = "deselect"}

func _disarm() -> void:
	mode = _prev_mode
	armed = ""
	armed_by = ""
	armed_mode = ""

## Left click / tap.
func primary(pick: Dictionary) -> Dictionary:
	if modal != "":
		return {type = "reject", reason = "modal"}
	match mode:
		Mode.ABILITY_ARMED:
			# EVERY tap is a targeting attempt — never selects,
			# never opens loot. The state stays armed until
			# presentation calls resolved(ok).
			match armed_mode:
				T_GROUND:
					# friendly fire is intentional: a friendly,
					# enemy or corpse hex all take the cast
					if pick.kind == "none":
						return {type = "reject", reason = "off_field"}
					return {type = "cast_ground", caster = armed_by,
						ability = armed, hex = pick.hex}
				T_ENEMY:
					if pick.kind == "enemy":
						return {type = "cast_actor",
							caster = armed_by, ability = armed,
							target = pick.id}
					return {type = "reject", reason = "choose_enemy"}
			return {type = "reject", reason = "unsupported_targeting"}
		Mode.NORMAL:
			match pick.kind:
				"friendly":
					if pick.id == DEFAULT_HERO:
						return {type = "none"}
					return _select(pick.id)
				"enemy":
					return {type = "inspect", id = pick.id}
				"corpse":
					return {type = "open_loot", id = pick.id}
		Mode.HERO_SELECTED:
			match pick.kind:
				"enemy":
					if selected in commandable:
						return {type = "command_attack",
							hero = selected, target = pick.id}
					return {type = "inspect", id = pick.id}
				"friendly":
					if pick.id == selected:
						return {type = "none"}
					if pick.id == DEFAULT_HERO:
						return _deselect()
					return _select(pick.id)
				"corpse":
					return {type = "open_loot", id = pick.id}
				_:
					return _deselect()
	return {type = "none"}

## Desktop right-click convenience (touch never needs it).
func secondary(pick: Dictionary) -> Dictionary:
	if mode == Mode.ABILITY_ARMED:
		return cancel()
	if mode == Mode.HERO_SELECTED and pick.kind == "enemy" \
			and selected in commandable:
		return {type = "command_attack", hero = selected,
			target = pick.id}
	return {type = "none"}

## Arm a spell/ability for targeting. Re-arming the same ability
## toggles it back off (acts as cancel).
func arm(ability_id: String, targeting_mode: String) -> Dictionary:
	if modal != "":
		return {type = "reject", reason = "modal"}
	if mode == Mode.ABILITY_ARMED and armed == ability_id:
		return cancel()
	if mode != Mode.ABILITY_ARMED:
		_prev_mode = mode
	armed_by = active_hero()
	armed_mode = targeting_mode
	armed = ability_id
	mode = Mode.ABILITY_ARMED
	return {type = "armed", caster = armed_by, ability = armed}

## Presentation reports whether the cast actually happened.
## ok -> disarm back to the previous mode (selection preserved);
## not ok -> stay armed so the player can pick again.
func resolved(ok: bool) -> Dictionary:
	if ok:
		_disarm()
	return {type = "none"}

## Cancel priority: open modal first, then the armed ability,
## then the hero selection.
func cancel() -> Dictionary:
	if modal != "":
		var m := modal
		modal = ""
		return {type = "modal_closed", name = m}
	if mode == Mode.ABILITY_ARMED:
		var a := armed
		_disarm()
		return {type = "cancelled", ability = a}
	if mode == Mode.HERO_SELECTED:
		return _deselect()
	return {type = "none"}

## Pause is orthogonal: orders issued during pause resolve on resume.
func toggle_pause() -> Dictionary:
	paused = not paused
	return {type = "paused" if paused else "resumed"}

func open_modal(name: String) -> Dictionary:
	modal = name
	return {type = "none"}

func close_modal() -> Dictionary:
	if modal == "":
		return {type = "none"}
	var m := modal
	modal = ""
	return {type = "modal_closed", name = m}

## A hero left the field (died, recalled): his armed spell dies with
## him and a dead hero's selection returns to the default hero.
func hero_lost(id: String) -> Dictionary:
	if mode == Mode.ABILITY_ARMED and armed_by == id:
		_disarm()
	if selected == id:
		mode = Mode.NORMAL
		selected = DEFAULT_HERO
		return {type = "deselect"}
	return {type = "none"}
