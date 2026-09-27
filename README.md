# Althar's Keep — Tower

*Tower game of Althar the wizard and his mates — low poly.*

A parallel **tower-defence** game built on the *same simulation DNA* as
**Althar's Keep**. Same heroes, same rules, same progression — a
different battlefield, a different objective, and the earlier stylized
low-poly art direction.

This is **not** a replacement for Althar's Keep and it does not modify
it. Althar's Keep keeps its own development, its own saves, its own
branch and its own cinematic visual work.

> **This is not Kingdom Rush with Althar's Keep graphics.** It is
> Althar's Keep reorganized into a tower-defence battlefield. The RPG
> rules remain the point: the heroes are individuals, the arrows are
> physical, the spells are tactical, damage types matter, equipment
> matters, levelling matters, loot matters, pause matters, and the Keep
> is something you are actually defending.

---

## 1. The one rule that matters

> **The rules engine is never forked.**

`sim/` is a byte-identical generated copy of Althar's Keep's `sim/`,
recorded in a SHA-256 manifest. `tools/sync-rules.sh` regenerates it;
`--check` detects drift; **`tools/test.sh` runs the check first**, so a
tower change cannot be reported done while the rules are out of sync.
Althar's Keep's own suite (3811 assertions) runs as part of this
project's test entry point.

```
Althar's Keep - Tower game/
├── sim/                        VENDORED rules engine (+ MANIFEST)
├── scenario_tower.gd           Scene 01: this game's battlefield
├── scripts/tower/              this game's presentation
├── assets/                     KayKit CC0 low-poly
├── scenes/tower.tscn
└── tools/
```

`scenario_tower.gd` **re-exports** the shared tables by compile-time
reference:

```gdscript
const Shared = preload("res://sim/config.gd")
const MELEE := Shared.MELEE          # the SAME object, not a copy
const PROGRESSION := Shared.PROGRESSION
```

and defines only what actually differs — grid, roster, spawn hexes,
terrain occupancy, elevation, defended structures, the road, the wave
table, enemy archetypes.

**Do not hand-copy a rule table into this project.** Althar's Keep
already contains one example of that mistake: `scripts/cfg_proof.gd` is
a 210-line duplicate that has since gone stale (learned ceilings say
`"none"` where the live config says `"even"`; Fireball rolls `3d6` where
the live one rolls `2d6`; no support spells at all).

---

## 2. Running

```bash
tools/import.sh     # once per fresh clone — headless game runs cannot import GLBs
tools/run.sh        # play (real save directory: user://saves/)
tools/dev-run.sh    # dev launcher — --nosave + TOWER_SAVE_DIR=user://saves_dev
tools/probe.sh      # headless Scene 01 acceptance probe (incl. wave threat table)
tools/test.sh       # rules sync + probe + tower suite + Althar's Keep's own suite
tools/sync-rules.sh # regenerate sim/ from Althar's Keep
```

In game: `1–5` arm the selected hero's abilities · tap an enemy to
target / order an attack · `space` pause (RESUME / SAVE / LOAD /
MARKET / handedness) · `N` next wave · `esc`/right-click cancel ·
`Cmd/Ctrl+S` quick save to the active slot. Mouse and touch are both
first-class.

Debug flags (after `--`): `--shot=SEC:FILE` capture · `--dump` print
every actor's placement and the Keep's Integrity · `--autowave`
auto-advance waves · `--nosave` never touches save files ·
`--input-smoke` scripted input self-test · `--poses` screenshot poses ·
`--save-smoke` scripted save→quit→continue verification.

---

## 3. SCENE 01 — "The Defensive Front"

One scene, one level, one principal enemy route. **Make this one scene
playable and good before thinking about additional levels.** No
campaign, no level selector, no branching maps, no procedural maps, no
second entrance, no tower-building economy.

### 3.1 Composition

Spatial composition takes inspiration from the Kingdom Rush reference's
*map structure* — not its artwork, characters, buildings or geometry.

```
        ALTHAR'S KEEP                                    ENEMY SPAWN
        (LEFT / LEFT-UPPER)                              (FAR UPPER-RIGHT)
              ↑                                                 ↓
        final approach  ←  chokepoint  ←  OPEN FIGHTING AREA  ←  entry
              ↑                    ↑
        HEALER TOWER          ARCHER TOWER
        (upper-mid)           (lower-mid)
```

- The **Keep** anchors the LEFT edge and feels substantial. It is the
  objective.
- Enemies enter from the FAR RIGHT and follow **one broad winding dirt
  road** — gentle bends, not a board-game line.
- The road passes through an **open fighting area**, two **chokepoints**,
  and a **final approach** to the gate.
- The road is visually obvious because it is the only walkable ground:
  everything off it is cliff and forest (README §50, the single
  defensive front).
- No artificial symmetry. It reads as a believable medieval approach
  road that happens to create interesting tactical spaces.

### 3.2 The Keep — KEEP INTEGRITY

The Keep is a **simulation object**, not scenery (`sim/structure.gd`).

Its pool is **Integrity**, deliberately *not* LP — LP belongs to living
characters. Enemies that survive the heroes reach the Keep and attack
it; at 0 Integrity the defence is lost.

```
KEEP INTEGRITY   200 / 200   INTACT
```

States derive from the fraction: `INTACT → DAMAGED →
HEAVILY_DAMAGED → BREACHED`.

Damage arrives through the **same typed packet pipeline creatures use** —
`sim/damage.gd` already reads `.resist` and `.armor` off whatever it is
handed, so masonry resistance is a data question rather than a special
case in combat.

MVP scope: one pool, one derived state label, a repair hook. **No**
gates, wall sections, destruction, materials beyond a name, or upgrade
tree. The architecture is here so those arrive without a rewrite.

### 3.3 Althar — the Keep top

Althar stands **on top of the Keep** (elevated, level 2). He is the
primary player-controlled hero; the player controls his spells. He is
*not* redesigned — LP, AP, MP, attributes, Spellcasting, progression,
Level, XP, resistances and the current spell architecture are all
Althar's Keep's, unchanged.

Spells keep their identities and are **not flattened** into generic
tower-defence abilities:

| Slot | Spell | Identity |
|---|---|---|
| 1 | **Fireball** | physical projectile, FIRE/HEAT explosion, AoE, slow and telegraphed |
| 2 | **Lightning** | very fast electrical strike, single target, AP drain |
| 3 | **Blizzard** | persistent ground-targeted CONTROL zone, cold ticks, AP drain |
| 4 | **Teleport** | tactical hero repositioning — two taps: hero, then destination |

Damage and resistance resolution remains Althar's Keep's — casting check
vs DC 20, MP committed on the attempt, the successful casting total as
the victims' Resistance DC, then Perception → Dodge → Resistance.

Targeting is **explicit per spell** (`sim/targeting.gd` modes): Fireball
and Blizzard are *ground* casts — any hex is legal, friendlies included
(**friendly fire is intentional**) — Lightning is *enemy*-targeted,
Heal/Haste/Aegis are *ally_alive*, Resurrection is *ally_dead*, Teleport
is *hero_destination*. Althar's `spell_range` override covers the whole
battlefield. The Fireball is a real projectile: travel time toward the
committed point, and on approach every actor in the blast rolls
Perception — allies of the caster get the configurable friendly-source
bonus (`SPELL_REACTION.friendly_source_perception_bonus`: they heard
the warning) — then Dodge, possibly stepping clear before impact.

### 3.4 The Archer tower

The Archer gets a **dedicated elevated tower at the lower-mid defensive
position** (the reference's lower catapult). She physically occupies it.

She is **not a generic tower gun** — she remains the actual Archer hero:
her real stats, Level, XP, LP/AP, Attack/Defense, physical bow, the
Draw → Aim → Release cycle, real arrows, projectile travel, real misses,
target selection and progression. Her elevated position gives her wide
coverage of the route; her range, targeting and physical arrows remain
meaningful, and arrows do **not** magically hit everything.

Because she is posted on a wall cell, the movement rules keep her there:
she cannot step down into the field and ground enemies cannot reach her.

### 3.5 The Healer tower

The Healer gets the **upper-mid tower** (the reference's other catapult).

He remains an actual character, not a healing building: LP, AP, MP,
Spellcasting, the existing triage AI, progression. He automatically
monitors allies and heals through the same `Support.cast` path the
player uses.

He **can and does heal himself** — the existing triage already considers
him, and self-preservation falls out of "lowest LP fraction first". The
full personality system (self-preserving / balanced / altruistic) is
**not** built yet.

### 3.6 The Warrior and the Barbarian

Both stay **on the ground**, on the road, at different engagement areas.

- **Warrior** — holds the last bend before the gate. HOLD / PROTECT /
  BLOCK: shield, armor, high Defense, active Defense, tight leash. He
  visibly intercepts enemies rather than being an invisible damage
  radius.
- **Barbarian** — mid-route, forward of the Warrior. INTERCEPT / BREAK:
  aggressive frontline, wider leash, engages groups harder. He is not
  another static tower.

Both reuse LP/AP, Attack, Defense, shield, armor, physical damage,
progression, and the anchor/leash behaviour, and both remain valid
Teleport targets.

### 3.7 The enemy path

**One route.** Enemies spawn at the far end and follow the road toward
the Keep.

There is **no path-following system**, and that is deliberate: the road
is the only walkable ground, and `Combat._step` already flood-fills
walkable cells to find the first step of a shortest walkable route. An
authored road is therefore followed for free, and the picture and the
rules cannot disagree.

- Enemies **do not ghost through heroes**. A marching enemy strikes any
  defender adjacent to it, and resumes its advance the moment the road
  is clear again. It never chases a hero off the route.
- A survivor that breaks through reaches the Keep and attacks its
  Integrity.
- Deterministic authored path. No procedural generation, no branching,
  no maze-building.

### 3.8 Damage, resistance and susceptibility

Althar's Keep's typed-damage architecture carries over: **pierce, slash,
impact, fire, cold, electrical**, each folded through the target's
`resist` table before armor.

**Where values exist, they are reused. Where they do not, defaults stay
neutral and the gap is documented rather than invented.**

Provisional values established for Scene 01:

- **Skeleton family** — `pierce = 0.80`. Exposed bone: an arrow passes
  between ribs rather than through tissue, so arrows do ~20% less
  effective damage. This is a **creature property, not extra armor**, and
  it applies to *any* pierce source, not just the Archer.
- **Skeleton Warrior** — `pierce 0.80, electrical 1.5, impact 0.75`,
  `armor.lp 2`. Plate conducts; armor eats impact; bone still shrugs at
  cold.
- **Ogre** — `fire 1.25, impact 0.5`, `armor.lp 3`, and **poor dodge**.
  Ranged weapons are effective against it through its *size and reaction
  characteristics*, not through an invented damage bonus.

### 3.9 Loot, equipment and pause

**Loot stays.** Enemy dies → corpse → player clicks → loot panel →
TAKE ALL. Loot is **not** vacuumed automatically.

The long-term intent is a grounded medieval-martial-plus-restrained-magic
equipment pool — weapons, armor, accessories, boots, gloves, belts,
helmets — with **class-appropriate eligibility**:

| Hero | Appropriate |
|---|---|
| Warrior | swords, shields, heavier armor, helmets, martial gear |
| Barbarian | axes / large martial weapons, lighter and flexible protection, leather / heavy cloth / fur — **not** plate |
| Archer | bows, arrows, light protection, bracers, mobility gear |
| Healer | robes, support/magical gear, rings, amulets |
| Althar | robes, magical gear, rings, amulets, staff/focus |

No "+9000 flaming legendary shoulder pad of infinity". Equipment should
make physical and tactical sense.

**Now wired, minimally.** The pause overlay's MARKET button opens a
two-tab peddler panel over the shared `sim/market.gd`: BUY lists the
scenario's `MARKET_STOCK` (every `kind = "equipment"` piece plus the
trinkets, sorted by `value` — prices are the shared, PROVISIONAL
`value` fields; consumables are not stocked because the canonical
table gives them no `value` yet and they would be free), SELL lists
the shared pack at `floor(value * sell_ratio)`. Gold is the party's
`inventory.gold`, shown at the top of the panel.

Selecting a living hero opens his card, which lists the four
equipment slots (weapon / shield / armor / accessory) with UNEQUIP
buttons and every held pack item `Items.can_equip` allows him —
eligibility is the item's `usable_by` against hero id/class. Equip
and unequip work while paused (and live): modifiers bake in at equip
and reverse exactly at unequip. Panels stay small and centered — the
battlefield is never covered.

**Pause is preserved.** Pause-and-manage is the expected tactical
behaviour. No inventory redesign.

### 3.10 Keep upgrades and workers

Future systems. The terms are fixed: **KEEP UPGRADES**, not character
Level — more Max Integrity, stronger gate/walls, better defences, repair
capability, further fortification.

**Workers** normally operate from the Keep and repair structural damage.
For Scene 01 only a placeholder exists: `KEEP_REPAIR_PER_WAVE` restores
a little Integrity between waves. There is **no** worker simulation, no
worker economy, no housing, no resource harvesting, no RTS
micromanagement. Workers are support personnel, not another army.

### 3.11 Towers have no structural HP

Deliberate simplification: the Archer and Healer towers have **no**
Integrity or repair system. Their survival is the hero standing on them.
If the hero is incapacitated, that position stops functioning. Builders
do not repair towers.

### 3.12 Progression

Heroes use Althar's Keep's progression **unchanged** — Level, Lifetime
XP, Available XP, attributes, d100 advancement, AP progression, learned
values, equipment, history. There is **no** tower-defence-specific hero
progression system, and progression changes made in canonical Althar's
Keep remain the gameplay source of truth.

### 3.13 The continuous loop

```
PREPARE → START GROUP → ENEMIES ENTER THE ROAD → COMBAT → LOOT
   → ENCOUNTER COMPLETE → XP / LEVELLING
   → RECOVER / EQUIP / REPOSITION → NEXT GROUP → HARDER COMPOSITION → CONTINUE
```

Nothing silently refills between groups: LP, AP and MP keep their
meaning (LP never regenerates, AP recovers only through rest, MP ticks
continuously). The canonical rules do not refill on CONTINUE DEFENSE,
and neither does this.

### 3.14 Difficulty and struggle

This is **not** a casual tower game where everything dies automatically.
The player controls Althar because decisions matter.

Difficulty increasingly comes from enemy composition, timing, path
position, armor, ranged threats, resistance, susceptibility, Perception,
reaction, Ogre pressure, simultaneous threats, hero condition, AP, MP
and Keep Integrity — **not** from inflated HP.

The intended questions:

> Do I spend MP on Fireball now? · Do I Blizzard this choke? · Do I
> Lightning that Skeleton Archer? · Do I Teleport the Warrior back
> toward the Keep? · Can the Barbarian hold that group? · Do I pause and
> change equipment?

### 3.15 Visual style and scale

Our own **low-poly / stylized** direction, not Kingdom Rush's cartoon
rendering. A stylized 3D tabletop fantasy battlefield: readable
characters, road, Keep, towers, enemies, spells.

The camera shows the whole of Scene 01 at once, prioritizing gameplay
readability over cinematic close-ups.

**Block before decorating.** The first gate is the composition, proven
with simple geometry: Keep, path, Archer tower, Healer tower, Warrior,
Barbarian, enemy spawn, camera.

### 3.16 Definition of done for Scene 01

1. Launch Scene 01.
2. See Althar on the Keep.
3. See the Archer in her tower.
4. See the Healer in his tower.
5. See the Warrior and Barbarian defending the road.
6. Start an enemy group.
7. Watch enemies follow the winding road.
8. Cast Althar's existing spells onto the battlefield.
9. Watch the Archer autonomously shoot real arrows.
10. Watch the Healer autonomously heal.
11. Watch the Warrior and Barbarian physically intercept enemies.
12. Enemies that break through reach and damage the Keep.
13. Keep Integrity visibly decreases.
14. Kill enemies.
15. Loot corpses.
16. Equip appropriate loot.
17. Receive XP.
18. Level normally through canonical progression.
19. Pause and manage the party.
20. Start the NEXT GROUP without resetting character progression.

### 3.17 Command, selection and the pointer

Every pointer gesture — mouse **and** touch — is normalised into a
semantic pick and fed to a pure, tested state machine
(`scripts/tower/input/command_state.gd`); the 3D scene only resolves
picks and executes intents. Althar is the **default active hero**;
tapping another hero selects him (ring + portrait light up, his card
opens). Tapping an enemy with the Warrior or Barbarian selected is a
direct **attack order** (`command_focus`) — the AI still does the
fighting; an order the hero cannot reach is dropped after a stall
limit and autonomy **resumes** (`command_dropped` event). Tapping bare
ground deselects back to Althar. While a spell is armed every tap is a
targeting attempt — never a selection — and the battlefield grid stays
**invisible**: a translucent danger disc under the pointer carries the
ground-target read, and legal enemy targets glow during enemy-targeted
spells. The whole HUD is **handedness-mirrored** (pause overlay toggle,
persisted to `user://settings.cfg`).

### 3.18 Save slots — between waves

Six manual slots plus an autosave under `user://saves/`
(`scripts/save_service.gd`; `TOWER_SAVE_DIR` redirects the directory,
`--nosave` disables it entirely). Saves are **between waves only** —
every write refuses with `between_waves` while a group is in flight,
because in-flight spells/zones do not serialize yet. Clearing a wave
autosaves; `Cmd/Ctrl+S` quick-saves to the active slot; the pause
overlay's SAVE/LOAD open the slot list (overwrite needs a confirming
press; corrupt and foreign-schema files are labelled UNREADABLE and
never touched). A save is the full sim state — heroes' pools, XP,
inventory, the Keep's Integrity, and this wave's generated individuals
with their rolled stats, corpses and loot. Launching with saves present
opens a boot modal: CONTINUE (newest valid save, autosave included) or
NEW GAME.

---

## 4. Enemy archetypes, individual variation and ecology

Enemies are **individual actors generated from an archetype**:

```
ARCHETYPE + VARIANT + INDIVIDUAL ROLL + EQUIPMENT = ACTUAL ENEMY ACTOR
```

Implemented in `sim/enemy.gd`.

### 4.1 Base stats + individual variation

Each archetype authors **base** stats. Every individual receives a
bounded, **integer-rounded** variation representing natural individual
difference, rolled **once at spawn** through the battle's seeded RNG and
fixed for that actor's life. Nothing is re-rolled during combat.

```
Skeleton base LP 10, variation 0.20
  → spawns at 8, 9, 10, 11 or 12 max LP
  → NEVER 10.4 LP or 8.7 LP
  → if it spawned at 8, it stays an 8-max-LP Skeleton
```

**Default individual variation: ±20%.** Configurable per archetype via
the `variation` key; `0.0` (the default) disables it entirely, which is
why Althar's Keep's authored roster is unaffected.

### 4.2 What varies, and what must not

Variation applies to **innate creature stats only**: Max LP, Max AP,
attributes, Perception. It does **not** blindly multiply every property.

**Equipment is discrete.** A normal sword is that sword; armor is that
armor; a shield is that shield. There is no "83% sword". Equipment
quality, if ever introduced, would be its own explicit system.

### 4.3 Archetype dominates the roll

A ±20% Skeleton must still **feel like a Skeleton** and can never roll
into being a Skeleton Warrior. Distinct tiers are **their own
archetypes**, never a high-rolled normal creature:

| Archetype | Identity |
|---|---|
| **Skeleton** | baseline melee mass; teaches dice, dodge and loot |
| **Skeleton Archer** | ranged pressure against exposed heroes and towers |
| **Skeleton Warrior** | armored, harder frontline target; slow to react |
| **Skeleton Mage** | magical/special (later) |
| **Goblin** | smaller, quicker, fragile, evasive, dangerous in groups |
| **Orc** | more substantial martial enemy; tougher, armed, possibly armored |
| **Ogre** | large, slow, high threat, hard to stop |

Later: Orc variants, Ogre variants, and further families.

### 4.4 Elite / specialist baselines

Where a special variant has no designed stats yet, a **clearly marked
PROVISIONAL** starting point may be used (e.g. ≈+30% to *relevant*
capabilities). It must not be applied blindly to every property — a
Skeleton Mage should not gain +30% sword damage, armor and movement if
that makes no archetypal sense. Configuration must make replacing these
provisional values easy.

### 4.5 Creature ecology and damage types

Enemy bodies and materials matter. Different creatures respond
differently to pierce, slash, impact, fire, cold, electrical and future
status effects, so spell and weapon choice matters.

- **Skeleton** — exposed bone. Provisional `pierce 0.80`: arrows pass
  between bones rather than through tissue. Not armor — a creature
  property, applied to any pierce source.
- **Ogre** — large target, substantial mass, slower reactions, high
  physical threat. Arrows are effective against it because of **size,
  poor dodge and reaction**, not an arbitrary damage multiplier. Never
  "a giant Skeleton with more HP".
- **Goblin** — small, quick, low individual durability, better
  evasion/reaction, dangerous in groups. Values TBD.
- **Orc** — stronger, tougher, armed, potentially armored, more
  disciplined in direct combat. Values TBD.

### 4.6 Enemy equipment

Authored by archetype/variant and flowing through the **same** equipment
and damage architecture the heroes use wherever practical: skeleton →
simple/crude weapon and little armor; skeleton archer → bow; skeleton
warrior → better armor and a martial weapon/shield; goblin → light crude
weapons; orc → better martial equipment; ogre → a large
creature-appropriate weapon.

### 4.7 Loot connection

Enemy equipment can eventually inform loot, but **not every enemy drops
every visible item**. The MVP uses the existing loot architecture plus a
small configurable drop table keyed by archetype, with class/equipment
eligibility for our heroes.

### 4.8 Spawn identity and determinism

An enemy's individual stats are generated and stored **once**, at spawn.
Seeded, configurable randomness makes tests and debug runs reproducible.
Between-wave saves preserve the rolled values rather than re-rolling —
the save records each generated individual's spawn dict, so a reload
rebuilds the same creature (corpses and loot included) even though a
fresh wave would have rolled different individuals. Mid-encounter saves
remain future work.

**Debug visibility matters** — tapping an enemy shows its archetype,
variant (if any), **threat** rating and rolled Max LP/AP/Perception on
the inspect card; the probe prints the per-wave threat table. These
numbers are not hidden.

### 4.9 Why variation exists

Not for random numbers' own sake — so enemies feel like **individuals**.
Two Skeletons should be recognizably the same creature type without being
mathematically identical clones. The player should learn "Skeletons are
vulnerable/resistant in these ways" while still noticing "that Skeleton
is tougher than the other one."

### 4.10 MVP starting rules

Skeleton, Skeleton Archer, Skeleton Warrior, Ogre, Goblin. Orc
and Skeleton Mage may exist as configurable/future archetypes without
finished art or gameplay.

Each archetype also carries a **PROVISIONAL `threat` budget** (skeleton
2, skeleton_archer 3, skeleton_warrior 5, ogre 12, goblin 1) — a
read-only difficulty score stamped onto every individual for tooling
and the inspect card; combat never reads it. `tools/probe.sh` prints
the per-wave threat table.

**All of these numbers are BALANCE-CONFIG values, not hardcoded combat
rules.** They will be play-tested and tuned.

---

## 5. Implementation status

### Done

- Shared rules engine vendored, synced and drift-checked.
- Scene 01 layout: Keep, winding road, two towers, spawn, hero positions.
- The Keep as a simulated structure with **Integrity**, a state ladder
  and a repair hook.
- The **assault AI**: enemies march the road, fight what blocks them,
  reach the Keep and break it. Defeat is recorded.
- **Enemy archetypes + ±20% individual variation**, seeded and
  deterministic, with the Skeleton pierce response and the Ogre profile.
- **Wave compositions** that change the tactical question, and a
  next-group loop that rebuilds the roster with new individuals.
- **Provisional threat budgets** per archetype, surfaced on the inspect
  card (archetype, variant, threat, rolled stats) and in the probe's
  wave report.
- **Command/selection state machine** — Althar default, tap-to-select,
  direct attack orders with autonomous resume and unreachable-order
  fallback, explicit per-spell targeting modes, all tested headlessly.
- **Mouse and touch first-class** input: taps select/target, drags pan,
  wheel/pinch zooms; the HUD mirrors for left/right handedness.
- **Save slots + autosave, between waves** (§3.18): six versioned slots,
  autosave on wave clear, boot CONTINUE/NEW GAME, quick save, atomic
  writes, corrupt/newer-schema files protected.
- **Loot panel** (click a corpse, TAKE ALL), a **minimal market**
  (buy/sell over `sim/market.gd`) and **pause-and-equip** on the hero
  card via the shared equipment rules.
- Procedural low-poly bodies for all five heroes with distinct
  silhouettes and weapons.
- HUD: Keep Integrity bar, party pools, wave banner, event log.

### Not done yet (deliberately)

- **Mid-wave saves** — a group in flight does not serialize (in-flight
  spells/zones); saves happen between waves only, by design for now.
- **XP / Level-Up presentation** — progression runs, but there is no
  character sheet, party rail or level-up UI in this project yet.
- **Pause-and-manage beyond equipment** — the party sheet, belt
  assignment and consumable USE flows are not built.
- **Blizzard/zone avoidance** — enemies do not yet avoid zones (an
  existing shared-sim gap that a defensive corridor makes more visible).
- **Keep upgrades, workers, destructible towers, healer personality
  settings** — architecture and spec only.

---

## 6. Phase plan

| Phase | Contents |
|---|---|
| **0 — isolation & scaffold** | *(done)* shared-rules mechanism, scenario, runnable scene |
| **1 — Scene 01 blockout** | *(done)* composition, Keep Integrity, assault AI, archetypes, procedural bodies |
| **2 — the playable loop** | *(mostly done)* Teleport, loot, equipment + market, pause-and-equip, between-wave save/load. Left: XP/Level-Up UI, party sheet, mid-wave saves |
| **3 — enemy depth** | Skeleton Archer / Warrior / Ogre presentation, Goblin, the susceptibility matrix tuned |
| **4 — Keep depth** | breach changes traversal, damaged visual states, Keep Upgrades, a small worker repair system |
| **5 — polish** | VFX, framing, feedback, balance, docs |

---

## 7. Hard rules for agents working here

1. **Never fork the rules.** `sim/` is vendored and hash-checked. A rule
   change belongs in Althar's Keep's `sim/`, then `tools/sync-rules.sh`.
2. **Run `tools/test.sh` before reporting done** — it checks the sync,
   the probe, and Althar's Keep's own 3811 assertions.
3. **Presentation only in `scripts/tower/`.** No rules, no balance.
4. **Never write to Althar's Keep's `assets/characters03/`** — that is the
   cinematic character pipeline. This game is low-poly.
5. **Deterministic randomness.** All rolls go through `battle.rng`.
6. **Configurable values** live in `scenario_tower.gd` (scene, waves,
   archetypes) or the shared `sim/config.gd` (rules) — never inline in a
   view.
7. **Never claim human/visual verification you did not perform.**
   Headless probes prove logic; screenshots are evidence, not acceptance.
8. **Do not invent economies, upgrade trees, worker systems or
   campaign structure** — they are explicitly not designed yet.

---

## 8. Findings recorded while building this

- **`deployed` does not mean "inert".** In the shared sim, `deployed`
  gates only healer triage and encounter-XP participation
  (`sim/combat.gd`, `sim/battle.gd`). A reserve hero still engages
  anything that enters his leash. Althar's Keep's own config comment
  claiming otherwise is **stale** — it only looks true there because
  that field is huge.
- **GDScript cannot shadow a parent's constant.** `extends` + redefining
  `GRID_RADIUS` is a parse error ("already exists in parent class"), and
  compile-time member access through a path-based `extends` fails
  outright. Composition (`const X := Shared.X`) is the working pattern.
- **Godot's importer writes `.import` files next to assets**, so asset
  directories are **copied** here rather than symlinked — a symlinked
  `assets/` would let this project rewrite Althar's Keep's import
  metadata.
- **Hand-built triangle strips are a trap.** An offset ribbon
  self-intersects at sharp bends, and getting per-vertex normals and
  winding wrong renders as unlit black patches. The road is built from
  `PlaneMesh`/`CylinderMesh` primitives instead, which have correct
  normals and cannot fold.
- **Godot's `--quit-after` must precede `--`**; after it, it is a user
  argument and the process never exits (orphaned Godot processes then
  corrupt performance measurements).
