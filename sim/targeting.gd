extends RefCounted
## Spell TARGETING MODES (canonical, Playable Party 0.5): every spell
## declares an explicit targeting mode — WHO or WHAT the player picks.
##
##   GROUND            a battlefield position (any in-grid hex —
##                     allies inside the effect ARE hit; friendly
##                     fire is intentional)
##   ENEMY             one living enemy actor
##   ALLY_ALIVE        a living friendly hero (support spells)
##   ALLY_DEAD         a fallen friendly hero (Resurrection)
##   SELF              the caster himself (reserved)
##   HERO_DESTINATION  a hero plus a destination hex (Teleport)
##
## Spells that predate the field keep a legacy `target` key naming the
## valid actor set; `mode_of` reads `targeting` first, then `target`,
## then defaults to ENEMY — so every spec answers a mode.
const GROUND := "ground"
const ENEMY := "enemy"
const ALLY_ALIVE := "ally_alive"
const ALLY_DEAD := "ally_dead"
const SELF := "self"
const HERO_DESTINATION := "hero_destination"

static func mode_of(spec: Dictionary) -> String:
	return spec.get("targeting", spec.get("target", ENEMY))

static func is_ground(spec: Dictionary) -> bool:
	return mode_of(spec) == GROUND

## A caster's effective reach for a spell: an actor with
## `spell_range > 0` overrides the spell's own `range` (Tower:
## Althar reaches the whole battlefield). 0 = the spell's value.
static func range_of(caster, spec: Dictionary) -> int:
	if caster.spell_range > 0:
		return caster.spell_range
	return int(spec.get("range", 0))
