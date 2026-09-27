# DESIGN DECISIONS — Althar's Keep, Tower Game

A chronological log of the directives and decisions that shaped this
project. Each entry records the decision, its rationale (when stated),
and its status. README.md documents *what is implemented*; this file
documents *what was decided and why*. When a decision is superseded,
the entry stays — update the status, never delete the history.

---

## 2026-09-27 — Foundations

**The game is a tactical stronghold defense, not a population RTS.**
Five individually named, simulated heroes defend the Keep. The player
is Althar the Wizard commanding from the Keep top — the intended feel:
*"I am the Wizard commanding the defense of my stronghold while a
small group of real, individually simulated heroes fights a visible,
dangerous battle below me."* No workers-as-army, no battalions, no
mass control.

**The Tower game is a separate project reusing the canonical rules
engine.** The original Althar's Keep runtime (`benchmarks/godot`) is
preserved untouched; the shared `sim/` is vendored byte-for-byte with
a SHA-256 manifest and drift check (`tools/sync-rules.sh`). Tower-only
policy (scenario, stock, waves) lives in `scenario_tower.gd`; *rules*
live in the shared engine.

**Inspect history before architecture.** The frozen `benchmark-0.2`
build is the minimum visual quality floor. The Scene 01 primitive
blockout is engineering evidence only — the human visual gate rejected
it as final art (primitive Keep, blobby road, scattered props, weak
tower identity). A real visual pass is deferred until composition is
accepted; it must reach at least the frozen build's quality (KayKit
dungeon-kit walls, real character meshes, purposeful props, warm
torch/cool moonlight lighting, fog).

## 2026-09-27 — Control and input (implemented)

**Althar is the default hero.** Tapping a hero selects him; tapping
bare ground returns control to Althar. Heroes fight autonomously; the
player directs, not puppets.

**Warrior and Barbarian take direct attack orders** (`command_focus`).
The order survives closer enemies, drops on death or after
`COMMAND.focus_stall_limit` (6, PROVISIONAL) unreachable steps, and
autonomous AI always resumes afterward.

**Every targeting tap while a spell is armed is a targeting attempt —
never a selection, never loot.** Only explicit Cancel leaves targeting.
No hidden auto-cancels, no input-layer ally protection.

**Mouse and touch are first-class**: tap = pick, drag = pan,
pinch/wheel = zoom, right-click = secondary convenience. Landscape
orientation; the HUD mirrors left/right handedness (dominant thumb
reaches the action bar), persisted in `user://settings.cfg`. No
touch→mouse emulation.

## 2026-09-27 — Spell identity (implemented, speeds PROVISIONAL)

Every spell declares a targeting mode (`sim/targeting.gd`):

| Spell | Mode | Flight |
|---|---|---|
| Fireball | **ground** — any hex, allies included | physical projectile, moderate speed, **leading matters** |
| Lightning | **enemy** — one living enemy | extremely fast |
| Blizzard | **ground** | none — conjured zone |
| Meteor | **ground** | heavy, telegraphed; slower than Fireball acceptable |
| Teleport | **hero_destination** — hero, then hex | — |
| Heal/Haste/Aegis | ally_alive | — |
| Resurrection | ally_dead | — |

**Friendly fire is intentional.** A ground spell aimed at a hero's hex
hits him. Projectiles do not home — a moving target walks out of the
blast.

**Friendly Perception bonus (PROVISIONAL +4):** allies of the caster
get a Perception bonus against his blast — *they heard the warning*.
It is only a Perception bonus: Dodge DC, AP cost and damage are
unchanged; a failed or immobile ally is hit normally.

**Althar's spell range covers the whole battlefield** (`spell_range=99`
override on the actor; other casters keep each spell's authored range).

**Speeds are provisional pending human play-test.** Flight times at
launch: Keep approach 0.4s, mid-road 2.5s, spawn 4.4s (Fireball 450
px/s; Meteor 350 px/s). Range ≠ speed — do not tune from the table
alone; the play-test list (near/mid/max-range casts, leading movers,
friendly near-misses) gates any change.

## 2026-09-27 — Saves (implemented: between waves)

**Target: save at any moment — shipped in stages.** Now: six manual
slots + autosave + versioned envelopes + atomic writes + corrupt/
newer-schema files marked UNREADABLE and never overwritten. Writes are
refused mid-wave (`between_waves`) because in-flight spells, zones and
arrows do not serialize yet; a wrong save is never written silently.

**Generated individuals persist.** A save records each wave enemy's
spawn dict; reload rebuilds the same rolled individuals, corpses and
loot included — never re-rolled.

Storage is `user://saves/` (portable across desktop and mobile).
`--nosave` / `TOWER_SAVE_DIR` isolate dev runs; the canonical save is
never touched. Cloud saves are deferred until the local layer is stable.

## 2026-09-27 — Economy and enemies (rules implemented)

**Gold is the currency** (`inventory.gold`). Items carry `value`;
market sells at `floor(value × 0.5)` — PROVISIONAL. Equipment wears
onto heroes through class-gated slots (`usable_by`); a grounded
medieval kit — "no +9000 flaming shoulder pad of infinity". Market
stock is scenario data.

**Enemies have no player-style Levels.** An enemy is archetype +
variant + ±20% seeded individual roll + tier + `threat`. Threat is a
read-only budget score (PROBE reports per-wave threat). Known flag:
wave 6's goblin swarm (10) under-reads wave 5's Ogre push (33) under
provisional values — revisit after play-test, not by arithmetic.

**No "×10 everything" scaling.** Difficulty grows through qualitative
variety: new archetypes, elites, bosses, threat budgets — not larger
numbers on the same creature.

## Deferred (explicit, do not silently start)

- Mid-wave saves (needs projectile/zone serialization)
- Large item catalog, aspirational-tier gear, special arrows
- Hero special abilities beyond spells; Archer special-arrow bar
- Elites/bosses, the L50–100 progression curve
- Workers, destructible towers, Keep upgrade economy
- Behavioral personality settings (self-preserving/altruistic)
- Cloud saves
- The full low-poly visual pass to benchmark-0.2 quality —
  **gated on human composition review**
