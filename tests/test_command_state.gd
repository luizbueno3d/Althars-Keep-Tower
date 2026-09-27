extends RefCounted
## Command/targeting state machine coverage: selection, ability arming,
## ground vs enemy targeting rules, pause/modal orthogonality — plus two
## sim-integration proofs on the real tower battle (focus command
## overrides AI choice; a dead mark returns the hero to autonomy).

const CommandState = preload("res://scripts/tower/input/command_state.gd")
const Scenario = preload("res://scenario_tower.gd")
const Battle = preload("res://sim/battle.gd")
const Combat = preload("res://sim/combat.gd")
const Hex = preload("res://sim/hex.gd")

func _pick(kind: String, id := "", hex := Vector2i.ZERO) -> Dictionary:
	return {kind = kind, id = id, hex = hex}

func _of(events: Array, type: String) -> Array:
	return events.filter(func(e): return e.type == type)

func run(t) -> void:
	# 1. no explicit selection -> the active hero is the wizard
	var cs = CommandState.new()
	t.eq(cs.active_hero(), "wizard", "default active hero is the wizard")
	t.eq(cs.mode, CommandState.Mode.NORMAL, "starts in NORMAL")

	# 2. tapping the Warrior selects him
	var r: Dictionary = cs.primary(_pick("friendly", "warrior"))
	t.eq(r.type, "select", "tapping the Warrior selects him")
	t.eq(cs.active_hero(), "warrior", "warrior is the active hero")

	# 3. selected Warrior + tap an enemy -> direct attack order
	r = cs.primary(_pick("enemy", "skeleton_a"))
	t.eq(r.type, "command_attack", "warrior + enemy -> attack order")
	t.eq(r.hero, "warrior", "order carries the commander")
	t.eq(r.target, "skeleton_a", "order carries the mark")

	# 4. selecting the Barbarian switches the active hero
	r = cs.primary(_pick("friendly", "barbarian"))
	t.eq(r.type, "select", "tapping another hero re-selects")
	t.eq(cs.active_hero(), "barbarian", "barbarian is now active")

	# 5. tap open ground -> deselect, active hero back to wizard
	r = cs.primary(_pick("ground", "", Vector2i(3, 0)))
	t.eq(r.type, "deselect", "tap on bare ground deselects")
	t.eq(cs.active_hero(), "wizard", "active hero falls back to wizard")
	t.eq(cs.mode, CommandState.Mode.NORMAL, "mode back to NORMAL")

	# 6. arm a ground spell -> ABILITY_ARMED on the active hero
	r = cs.arm("fireball", "ground")
	t.eq(r.type, "armed", "arming fireball enters targeting")
	t.eq(r.caster, "wizard", "the armed caster is the active hero")
	t.eq(cs.mode, CommandState.Mode.ABILITY_ARMED, "mode ABILITY_ARMED")

	# 7. ground-armed tap on a FRIENDLY casts at his hex — friendly
	#    fire is intentional; the active hero does NOT switch
	r = cs.primary(_pick("friendly", "warrior", Vector2i(-3, 1)))
	t.eq(r.type, "cast_ground", "armed tap on a hero casts at his hex")
	t.eq(r.hex, Vector2i(-3, 1), "cast targets the picked hex")
	t.eq(cs.active_hero(), "wizard", "armed tap never re-selects")

	# 8. cancel exits targeting with a cancelled intent
	r = cs.cancel()
	t.eq(r.type, "cancelled", "cancel exits targeting")
	t.eq(r.ability, "fireball", "cancelled names the ability")
	t.eq(cs.mode, CommandState.Mode.NORMAL, "disarmed to previous mode")

	# 9. after cancel a Warrior tap selects normally again
	r = cs.primary(_pick("friendly", "warrior"))
	t.eq(r.type, "select", "post-cancel tap selects normally")

	# 10. ENEMY spell + tap a friendly -> choose_enemy, stays armed
	cs.primary(_pick("ground", "", Vector2i.ZERO))  # deselect first
	cs.arm("lightning", "enemy")
	r = cs.primary(_pick("friendly", "warrior"))
	t.eq(r.type, "reject", "enemy spell refuses a friendly pick")
	t.eq(r.reason, "choose_enemy", "rejection asks for an enemy")
	t.eq(cs.mode, CommandState.Mode.ABILITY_ARMED, "still armed")
	cs.cancel()

	# 11. a corpse tapped while GROUND-armed is a cast, not loot
	cs.arm("fireball", "ground")
	r = cs.primary(_pick("corpse", "skeleton_b", Vector2i(4, 1)))
	t.eq(r.type, "cast_ground", "corpse hex is a legal ground target")
	t.eq(r.hex, Vector2i(4, 1), "cast lands on the corpse's hex")
	cs.cancel()

	# 12. resolved(false) keeps the spell armed; resolved(true)
	#     returns to the previous mode
	cs.arm("fireball", "ground")
	cs.resolved(false)
	t.eq(cs.mode, CommandState.Mode.ABILITY_ARMED,
		"a rejected cast keeps the spell armed")
	cs.primary(_pick("ground", "", Vector2i(1, 0)))
	cs.resolved(true)
	t.eq(cs.mode, CommandState.Mode.NORMAL,
		"a landed cast disarms to the previous mode")
	t.eq(cs.armed, "", "armed ability cleared")

	# 13. arming the same ability twice toggles it off
	cs.arm("fireball", "ground")
	r = cs.arm("fireball", "ground")
	t.eq(r.type, "cancelled", "re-arming the same spell cancels")
	t.eq(cs.mode, CommandState.Mode.NORMAL, "toggle-off disarms")

	# 14. pause is orthogonal: mode/selected/armed preserved, and
	#     taps still resolve while paused (pause-and-command)
	cs.primary(_pick("friendly", "warrior"))
	cs.arm("blizzard", "ground")
	t.eq(cs.toggle_pause().type, "paused", "pause flips the flag")
	t.eq(cs.mode, CommandState.Mode.ABILITY_ARMED,
		"pause keeps the armed state")
	t.eq(cs.active_hero(), "warrior", "pause keeps the selection")
	r = cs.primary(_pick("ground", "", Vector2i(5, 0)))
	t.eq(r.type, "cast_ground", "orders still resolve while paused")
	cs.resolved(true)
	t.eq(cs.mode, CommandState.Mode.HERO_SELECTED,
		"resolved during pause returns to selection")
	t.eq(cs.toggle_pause().type, "resumed", "resume flips back")
	cs.cancel()

	# 15. a modal blocks primary; cancel closes the modal first
	cs.open_modal("loot")
	r = cs.primary(_pick("enemy", "skeleton_a"))
	t.eq(r.type, "reject", "modal blocks primary taps")
	t.eq(r.reason, "modal", "rejection names the modal")
	r = cs.cancel()
	t.eq(r.type, "modal_closed", "cancel closes the modal first")
	t.eq(r.name, "loot", "closed modal identified")

	# 16. the selected hero falling hands command back to the wizard
	cs.primary(_pick("friendly", "warrior"))
	r = cs.hero_lost("warrior")
	t.eq(r.type, "deselect", "losing the selected hero deselects")
	t.eq(cs.active_hero(), "wizard", "command returns to the wizard")

	# 17. the Archer is not commandable: enemy tap inspects instead
	cs.primary(_pick("friendly", "archer"))
	r = cs.primary(_pick("enemy", "skeleton_c"))
	t.eq(r.type, "inspect", "archer + enemy -> inspect, not an order")

	# 18. arming from HERO_SELECTED then cancelling returns there
	cs.primary(_pick("ground", "", Vector2i.ZERO))
	cs.primary(_pick("friendly", "warrior"))
	cs.arm("fireball", "ground")
	cs.cancel()
	t.eq(cs.mode, CommandState.Mode.HERO_SELECTED,
		"cancel restores the pre-arm selection")
	t.eq(cs.active_hero(), "warrior", "warrior still selected")

	# right-click convenience: commandable hero + enemy -> attack
	cs.primary(_pick("friendly", "barbarian"))
	r = cs.secondary(_pick("enemy", "skeleton_a"))
	t.eq(r.type, "command_attack", "secondary orders an attack too")
	cs.primary(_pick("ground", "", Vector2i.ZERO))

	# ally_alive (heal): friendly pick casts, others reject
	cs.primary(_pick("friendly", "healer"))
	cs.arm("heal", "ally_alive")
	r = cs.primary(_pick("enemy", "skeleton_a"))
	t.eq(r.type, "reject", "ally_alive armed + enemy rejects")
	t.eq(r.reason, "choose_ally", "rejection asks for an ally")
	t.eq(cs.armed, "heal", "still armed after reject")
	r = cs.primary(_pick("friendly", "warrior"))
	t.eq(r.type, "cast_actor", "ally_alive + friendly -> cast_actor")
	t.eq(r.caster, "healer", "the healer is the caster")
	t.eq(r.target, "warrior", "target carried through")
	cs.cancel()

	# ally_dead (resurrect): only a fallen hero is legal
	cs.arm("resurrect", "ally_dead")
	r = cs.primary(_pick("friendly", "warrior"))
	t.eq(r.type, "reject", "ally_dead + living ally rejects")
	t.eq(r.reason, "choose_fallen", "rejection asks for the fallen")
	r = cs.primary(_pick("fallen", "barbarian", Vector2i(3, 0)))
	t.eq(r.type, "cast_actor", "ally_dead + fallen -> cast_actor")
	t.eq(r.target, "barbarian", "fallen target carried")
	cs.cancel()

	# hero_destination (Teleport) is a two-tap flow
	cs.primary(_pick("ground", "", Vector2i.ZERO))   # deselect -> wizard
	cs.arm("teleport", "hero_destination")
	r = cs.primary(_pick("enemy", "skeleton_a"))
	t.eq(r.type, "reject", "teleport first tap on enemy rejects")
	t.eq(r.reason, "choose_hero", "rejection asks for a hero")
	r = cs.primary(_pick("friendly", "wizard"))
	t.eq(r.reason, "choose_hero", "caster himself is not a source")
	r = cs.primary(_pick("friendly", "warrior"))
	t.eq(r.type, "teleport_source", "hero first tap stores the source")
	t.eq(r.id, "warrior", "source id carried")
	t.eq(cs.mode, CommandState.Mode.ABILITY_ARMED, "still armed")
	t.eq(cs.tp_source, "warrior", "tp_source stored")
	r = cs.primary(_pick("ground", "", Vector2i(7, 1)))
	t.eq(r.type, "cast_teleport", "second tap -> cast_teleport")
	t.eq(r.caster, "wizard", "caster is the armer")
	t.eq(r.source, "warrior", "source carried")
	t.eq(r.hex, Vector2i(7, 1), "destination hex carried")
	cs.resolved(true)
	t.eq(cs.tp_source, "", "resolved clears the teleport source")
	t.eq(cs.mode, CommandState.Mode.NORMAL, "resolved disarms")

	# cancel mid-teleport clears the stored source
	cs.arm("teleport", "hero_destination")
	cs.primary(_pick("friendly", "warrior"))
	r = cs.cancel()
	t.eq(r.type, "cancelled", "cancel exits mid-teleport")
	t.eq(cs.tp_source, "", "cancel clears the teleport source")

	# a fallen hero is inspectable but not selectable
	r = cs.primary(_pick("fallen", "warrior", Vector2i(1, 0)))
	t.eq(r.type, "inspect", "fallen hero tap -> inspect (NORMAL)")
	cs.primary(_pick("friendly", "barbarian"))
	r = cs.primary(_pick("fallen", "warrior", Vector2i(1, 0)))
	t.eq(r.type, "inspect", "fallen tap while selected -> inspect")
	t.eq(cs.selected, "barbarian", "selection kept on fallen tap")
	cs.primary(_pick("ground", "", Vector2i.ZERO))

	# ============ SIM INTEGRATION (real tower battle) ============
	# (a) a direct focus order overrides the AI's ordinary target
	#     choice: the Warrior chases the FARTHEST enemy even though
	#     another is closer
	var b = Battle.create(Scenario, Callable(Scenario, "build_roster"))
	var war = b.actors.warrior
	# only the ordered hero moves on his own; the rest hold still so
	# the mark survives long enough for the assertion
	for id in b.actor_order:
		var a = b.actors[id]
		if a.faction == "friendly" and a.id != "warrior":
			a.ai = ""
	for i in 30:
		Combat.update(b, 0.1)
	b.drain_events()
	var foes: Array = b.living_enemies()
	t.check(foes.size() >= 2, "at least two enemies are alive")
	var mark = null
	var far_d := -1
	for e in foes:
		var d := Hex.distance(war.hex, e.hex)
		if d > far_d:
			far_d = d
			mark = e
	var nearer: Array = foes.filter(func(e): return e != mark \
		and Hex.distance(war.hex, e.hex) < far_d)
	t.check(nearer.size() > 0, "a closer alternative mark exists")
	t.check(b.command_focus("warrior", mark.id), "focus order accepted")
	var d_before: int = Hex.distance(war.hex, mark.hex)
	var struck := false
	for i in 60:                    # ~6 s of sim
		Combat.update(b, 0.1)
		for e in b.drain_events():
			if e.get("type") == "strike" and e.get("attacker") == "warrior" \
					and e.get("defender") == mark.id:
				struck = true
		if not mark.alive or struck:
			break
	t.eq(war.focus_id, mark.id, "the order holds while the mark lives")
	t.check(struck or Hex.distance(war.hex, mark.hex) < d_before,
		"he closed on the FARTHEST mark (or struck it)")

	# (b) the mark dies -> focus clears -> autonomous behaviour
	#     resumes (drift back to anchor or engage an in-leash foe)
	if war.focus_id != "":
		mark.alive = false
		war.cd = 0.0
		Combat.update(b, 0.1)
	t.eq(war.focus_id, "", "mark's death clears the focus order")
	var d_anchor0: int = Hex.distance(war.hex, war.anchor)
	var resumed := false
	for i in 120:                   # ~12 s to re-engage or return
		Combat.update(b, 0.1)
		for e in b.drain_events():
			if e.get("type") == "strike" and e.get("attacker") == "warrior":
				resumed = true
		if resumed or Hex.distance(war.hex, war.anchor) < d_anchor0:
			break
	t.check(resumed or Hex.distance(war.hex, war.anchor) < d_anchor0,
		"autonomy resumed: re-engaged or heading back to anchor")
