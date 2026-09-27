# Althar's Keep — Tower

*Tower game of Althar the wizard and his mates — low poly.*

A parallel **tower-defence** game built on the *same simulation DNA* as
**Althar's Keep**. Same heroes, same rules, same progression — a
different battlefield, a different objective, and the earlier stylized
low-poly art direction.

This is **not** a replacement for Althar's Keep and it does not modify
it. Althar's Keep keeps its own development, its own saves, its own
branch and its own cinematic visual work.

---

## The one rule that matters

> **The rules engine is never forked.**

`sim/` is a **symlink** to `../benchmarks/godot/sim`. There is exactly
one copy of the rules in this workspace. A bug fixed in melee
resolution, a rebalance of Fireball, a change to the progression
tables — all of it lands in both games at once, and neither can drift.

```
Althar's Keep - Tower game/
├── sim -> ../benchmarks/godot/sim     SHARED rules engine (symlink)
├── scenario_tower.gd                  this game's battlefield
├── scripts/tower/                     this game's presentation
├── assets/                            KayKit CC0 low-poly (copied)
├── scenes/tower.tscn
└── tools/
```

### How the shared rules stay shared

`sim/*.gd` reads its *universal* rule tables from the shared
`sim/config.gd` (`MELEE`, `BOW`, `CRITICALS`, `FEEDBACK`, `SPELLS`,
`TELEPORT`, `PROGRESSION`, `WEAPONS`, `ITEMS`, `BELT_SLOTS`), and reads
*scenario* data from whatever config class it was handed —
`Battle.create(cfg)`.

`scenario_tower.gd` therefore **re-exports** the shared tables by
compile-time reference:

```gdscript
const Shared = preload("res://sim/config.gd")
const MELEE := Shared.MELEE          # the SAME object, not a copy
const PROGRESSION := Shared.PROGRESSION
```

and defines only what actually differs: the grid, the roster and their
spawn hexes, the terrain occupancy rule, the elevation rule, the cover
props, the loot and wave rewards.

**Do not hand-copy a rule table into this project.** `Althar's Keep`
already contains one example of that mistake — `scripts/cfg_proof.gd`
is a 210-line duplicate that has since gone stale (its learned ceilings
say `"none"` where the live config says `"even"`, its Fireball rolls
`3d6` where the live one rolls `2d6`, and it has no support spells at
all). `tools/probe.sh` asserts against this: it checks that the shared
tables are the *same objects*, not equal copies.

---

## Running

```bash
tools/import.sh     # once per fresh clone — headless game runs cannot import GLBs
tools/run.sh        # play
tools/dev-run.sh    # dev launcher (isolated save slot, once saves exist)
tools/probe.sh      # headless acceptance probe for the tower scenario
tools/test.sh       # probe + the shared rules suite (Althar's Keep's)
```

In game: `1` fireball · `2` lightning · `3` blizzard · `space` pause ·
`esc`/right-click cancel targeting. Click an enemy to cast.

Useful flags (after `--`): `--shot=SEC:FILE` capture, `--dump` print
every actor's placement.

---

## Phase 0 status — what is real and what is not

Delivered:

- the shared rules engine running from this project (proven headless),
- `scenario_tower.gd` — a corridor battlefield: gate tower west, cliffs
  north and south, treeline east, one defensive front (README §50),
- a runnable low-poly scene: KayKit gate tower, battlement curtain,
  torches, cover props, KayKit chibi skeletons advancing the corridor,
- the Wizard and Archer posted on the battlement, Warrior at the gate,
  Barbarian in reserve, Healer behind the line,
- Fireball / Lightning / Blizzard castable at a clicked enemy.

**Deliberately not done yet** (see the phase plan below):

- **The four martial heroes have no low-poly body.** KayKit's
  Adventurers pack was licensed into Althar's Keep but only its `Mage`
  survived; the Warrior / Barbarian / Archer / Healer render as
  deliberately tinted placeholder figures. Phase 2.
- **The tower is scenery, not a simulation object.** `TOWER.states` is
  declared but nothing reads it. Enemies target *heroes*, not the
  tower. There is no defeat condition, no breach, no repair, no wave
  composition. Phases 3–4.
- No save/load, no inventory UI, no party rail, no character sheet.
  The shared UI kit is not yet wired (Phase 1).

---

## Phase plan

| Phase | Contents |
|---|---|
| **0 — isolation & scaffold** | *(done)* safety commit of Althar's Keep, this project, the shared-rules mechanism, the tower scenario, a runnable scene, the acceptance probe |
| **1 — playable tower battlefield** | real low-poly environment, hex overlay, the shared UI kit (party rail, chronicle, spell bar), camera control |
| **2 — five heroes** | real low-poly bodies for Warrior / Barbarian / Archer / Healer; direct command, Teleport deployment |
| **3 — enemies + differentiated damage** | Skeleton Archer, Skeleton Warrior, Ogre; the susceptibility matrix; wave composition |
| **4 — progression & continuous loop** | `Structure` (the tower as a damageable object), `assault` AI, breach changes traversal, defeat condition, between-wave repair, save/load |
| **5 — polish** | VFX, framing, feedback, balance, docs |

---

## Hard rules for agents working here

1. **Never fork the rules.** `sim/` is shared by symlink. If a change
   needs to be in the rules, it belongs in Althar's Keep's `sim/` and
   must keep *its* suite green — `../benchmarks/godot/tools/test.sh`
   (3582 assertions at the time of writing).
2. **Never edit files under `sim/` from here without running the shared
   suite.** You are editing Althar's Keep's rules engine.
3. **Presentation only in `scripts/tower/`.** No rules, no balance.
4. **Never write to `assets/characters03/`** — that is Althar's Keep's
   cinematic character pipeline. This game is low-poly.
5. **Deterministic randomness.** All rolls go through `battle.rng`.
6. **Configurable values** live in `scenario_tower.gd` (scenario) or
   the shared `sim/config.gd` (rules) — never inline in a view.
7. **Run `tools/test.sh` before reporting done** — it covers both the
   tower scenario and the shared rules.
8. **Never claim human/visual verification you did not perform.**
   Headless probes prove logic; screenshots are evidence, not
   acceptance.

---

## Known findings recorded during Phase 0

- **`deployed` does not mean "inert".** In the shared sim, `deployed`
  gates only healer triage and encounter-XP participation
  (`sim/combat.gd:215`, `sim/battle.gd:187`). A reserve hero still
  engages anything that enters his leash. Althar's Keep's own config
  comment ("reserve heroes only strike adjacent enemies until
  deployed") is stale — it only *looks* true there because that field
  is large. The tower scenario gives the reserve a short leash instead
  of changing shared behaviour.
- **GDScript cannot shadow a parent's constant.** `extends` +
  redefining `GRID_RADIUS` is a parse error ("already exists in parent
  class"), and compile-time member access through a path-based
  `extends` fails outright. Composition (`const X := Shared.X`) is the
  working pattern.
- **Godot's importer writes `.import` files next to assets**, so asset
  directories are **copied** here rather than symlinked — a symlinked
  `assets/` would have let this project rewrite Althar's Keep's import
  metadata. `sim/` is symlinked safely because `.gd` files are loaded
  directly and their `.uid` files already exist.

---

## Not yet under version control

This folder is not a git repository. Because `sim/` is a symlink into
Althar's Keep's repo, a commit here would not contain the rules — worth
deciding deliberately before `git init` (options: track the symlink and
document the dependency, or switch `sim/` to a generated copy with a
hash manifest).
