# Alpha++ — Native Mac City Builder

## Vision

A city-building game in the spirit of SimCity 2000/3000 (aggregate simulation,
zone-based growth, land value, service coverage) with the depth of Cities:
Skylines, built natively for Apple Silicon to avoid Rosetta overhead.

## Where this is going

The end goal is a **finished, high-fidelity game shipped on the Mac App Store
and/or Steam** — not a prototype, not a tech demo. Two things follow, and they
are why the grayboxing rule was retired:

- **Visual quality is a feature, not a finishing pass.** The game has to look
  like something someone would pay for.
- **Variety matters as much as detail.** Even SimCity Classic drew several
  different buildings per zone per density. The target is **ten or more
  distinct looks per zone per tier** — which means a parametric generator, not
  ninety hand-written shape functions. See `ZoneIcon`.

## Tech stack

- Swift, native macOS app target, Apple Silicon only (no Intel fallback)
- Minimum deployment target: macOS 14
- SpriteKit for rendering (Phase 1–2). May consider custom Metal shaders later
  for effects SpriteKit can't handle natively, but not until mechanics are
  solid. (SpriteKit already renders via Metal under the hood, so this is an
  optimization/effects question, not a performance rescue.)
- No cross-platform requirement. Mac-only, on purpose.
- **The city is moving to our own Metal renderer** (`Rendering/Metal/`),
  behind *Settings ▸ Renderer ▸ Metal (beta)*. See "The Metal spike" and
  M0–M6 below: through M6 the Metal renderer draws the city, everything
  that moves and every view, while SpriteKit still owns input, the camera,
  the cursors and route diagrams, until M8 makes Metal the only renderer.

## Development philosophy

- **Art is part of the work now, not a later phase.** This project started
  under a grayboxing rule — placeholder shapes until mechanics locked, no real
  art before then. That rule has been retired. It did its job: every mechanic
  below was proven against coloured squares first. But the mechanics are stable
  enough now that deferring the visuals only defers finding out whether they
  work. Expect turns spent purely on how the game *looks*, interleaved with
  mechanics, rather than an art phase bolted on at the end.
- **Rendering is decoupled from simulation from day one**: simulation logic
  outputs plain data (e.g. "tile at (x,y): zone=residential, density=2"), and a
  separate rendering layer maps that data to visuals. This is what makes the
  point above cheap — visual style can be reworked at any time without touching
  a line of simulation code, and the import rule under "Project structure
  conventions" is what keeps it true.
- **Small, testable increments.** Each unit of work should be buildable and
  verifiable before moving to the next.
- **Look at the art, don't imagine it.** `ZoneIconContactSheetTests` renders
  every building variant to a single PNG in seconds (see "Looking at the art
  without playing to it"). Any change to how buildings are drawn gets reviewed
  there before it is committed — the same way a balance change gets measured on
  the playtest harness rather than argued about.

## Project structure conventions

- Keep simulation logic and rendering code in clearly separate folders/files
  (e.g. `Simulation/` vs `Rendering/`) so the data/rendering split in the
  philosophy above is easy to see and enforce in the file layout too.
- **Enforcement rule:** files under `Simulation/` may import `Foundation` only.
  They must never `import SpriteKit`, `import AppKit`, or `import SwiftUI`. If
  simulation code needs a color, a point, or a node, that mapping belongs in
  `Rendering/`. This is what makes the split real rather than aspirational.

## Current phase

Phases 1–3 are all complete. The originally-scoped arc — core loop, then
simulation depth, then real art direction — has played out in full:

- **Phase 1 (core loop):** grid-based map, click to place zones
  (residential/commercial/industrial) and roads, population/money counters
  that respond to placement.
- **Phase 2 (simulation depth):** density-based growth/decay gated by road or
  transit access and by land value (`CitySimulator`, `LandValue`), with a real
  underground water/pipe network required for the top density tiers
  (`Water`); routed point-to-point commute traffic over the road network,
  with congestion feeding back into land value (`Traffic`); random,
  service-gated fire/crime hazards (`CityHazards`); multi-tile buildings
  (2×2 zones and service buildings, 3×3 power plant/stadium); player levers
  for tax rate, per-service funding, simulation speed, and map size; and a
  stat-history sparkline. Roads, transit, and utilities each come in a
  cheap/upgraded pair (road/highway, transit stop/subway).
- **Phase 3 (art direction):** a full retrowave/synthwave visual treatment —
  a neon palette with growth-tier-based hues (not just brightness) for the
  three growable zones (`RenderPalette`), procedurally-drawn vector building
  silhouettes with two look-variants per zone/tier/service so lots don't
  repeat (`ZoneIcon`), and a Metal-backed full-scene shader pass (scanlines,
  vignette, chromatic aberration — `RetroShader`). This satisfies the
  "Phase 3 = real art" milestone via art *direction* rather than sourced
  sprites: everything is still procedurally-drawn SpriteKit shape nodes, no
  raster image assets, so the rendering/simulation split remains exactly as
  clean as the philosophy above intends.

**Genuinely next**, in rough order:

- **Balance tuning**, now with a tool for it. Most Phase 2 constants
  (land-value thresholds, coverage floors, traffic capacities) are still
  documented in-place as first guesses. The economic ones have been measured:
  see the playtest harness section below. The biggest one left is that a
  plateaued city still banks ~20% of its tax revenue every tick — bounded now
  rather than unbounded, but whether 20% is the *right* target is an
  unplaytested design question, not a measured one.
- **Simulation performance.** Tick cost grows superlinearly with map area and
  `Traffic.computeLoad` dominates it. A 64×64 tick blocks the main thread for
  114 ms in Release, so a large map visibly hitches, and a Debug build cannot
  play one at all. Numbers in the harness section below.
- Everything else is genre-parity gap-filling of the kind Phase 2 already did
  repeatedly (see `Traffic`/`Water`'s own doc comments for the pattern) —
  there's no fixed list, just whichever missing SimCity-style mechanic is
  worth chasing next. Real individual-agent traffic simulation is explicitly
  *not* on this list — `Traffic.swift` documents that as complexity this
  project's aggregate-simulation approach is deliberately not chasing.

## Explain-as-you-go

I'm new to Swift/SpriteKit/game dev. When you make a non-trivial decision
(project structure, SpriteKit scene setup, data model choices), briefly explain
why, so I actually learn the stack rather than just accepting output.

## Setting up on a new machine

Requires **full Xcode 16 or newer** — Command Line Tools alone are not enough,
because the project uses Xcode 16 file-system-synchronized groups. Verified
working on Xcode 26.6 and 27.0.

Note that a major Xcode upgrade resets the license agreement, and until it is
accepted *every* tool behind the shim fails — `git` and `python3` included, not
just `xcodebuild`. The fix is the `sudo xcodebuild -license accept` below.

```sh
xcodebuild -version
```

If that prints a version, the toolchain is ready and no further setup is needed.
If it errors instead, Xcode is installed but not selected; pointing at it needs
an admin account:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
```

Then clone:

```sh
git clone https://github.com/mrheathv/alpha_plus_plus.git
cd alpha_plus_plus
```

## Build and run

In Xcode:

```sh
open AlphaPlusPlus.xcodeproj
```

then press Cmd-R.

From the terminal. The `-derivedDataPath` flag keeps build output in `./build`
(gitignored) instead of burying it in `~/Library/Developer/Xcode/DerivedData`:

```sh
xcodebuild -project AlphaPlusPlus.xcodeproj \
           -scheme AlphaPlusPlus \
           -configuration Debug \
           -derivedDataPath ./build \
           build

open ./build/Build/Products/Debug/AlphaPlusPlus.app
```

## Balance tuning: the playtest harness

`PlaytestHarness` (test target) builds cities, runs them for hundreds or
thousands of ticks, and reports what the economy and hazard system actually
did. `PlaytestScenarioTests` turns those measurements into regression tests,
so a balance number is something you can re-derive rather than something a
commit message once claimed.

It runs with the normal suite at a small, fast profile. For real tuning, run
the full-size profile — and run it in **Release**, which is ~55x faster:

```sh
TEST_RUNNER_PLAYTEST_FULL=1 xcodebuild -project AlphaPlusPlus.xcodeproj \
  -scheme AlphaPlusPlus -configuration Release -derivedDataPath ./build \
  ENABLE_TESTABILITY=YES test \
  -only-testing:AlphaPlusPlusTests/PlaytestScenarioTests
```

`ENABLE_TESTABILITY=YES` is needed because Release disables testability and
`@testable import` requires it. `TEST_RUNNER_` is required because xcodebuild
forwards only variables carrying that prefix, which it strips.

### Rendering cost: why the map blinked

Two separate causes, both "SpriteKit nodes rebuilt when nothing changed."

**Every placement rebuilt the entire map.** Placing a multi-tile building
called `rebuildEntireGrid()`, which tears down and recreates every sprite —
measured at **202 ms** for a built-out 64×64 city in a Debug build, on the main
thread, in response to one click. Every growable zone is 2×2, so that was every
zone placement. `GameScene.rebuildRegion(around:)` does the same work over a
±4-tile window instead: **4.9 ms**, a 40x cut.

A full rebuild was used because a footprint placement changes which tiles are
*anchors* — four single tiles becoming one 2×2 building means three sprites go
and one appears, which a per-tile refresh cannot express. That is still true,
but only locally, so a bounded window is both correct and cheap.
`GameSceneRebuildTests` pins that by asserting a region rebuild leaves exactly
the sprite set a full rebuild would, including the awkward case of a building
whose anchor sits outside the footprint that was clicked.

**Every decoration rebuilt on every tick.** `TileRenderer`'s `sync…` methods
tore their nodes down and rebuilt them on every call, and `refreshAll()` calls
them for every tile every tick — thousands of `SKShapeNode`s, several with
`glowWidth`, destroyed and recreated once a second. `syncIcon` had been given a
cache key when this was first diagnosed for building icons; the mistake was
fixing the one symptom rather than the pattern. Every decoration now caches on
whatever determines its appearance (`isUpToDate`/`markUpToDate`/`invalidate`),
and every `clear…` invalidates.

Worth keeping in mind for anything drawn per tile: the question is not "is this
node cheap to make" but "how many times a second is it being made."

### Simulation cost, measured

`HarnessTimingTests` (opt-in, same flag) measures per-tick cost on a fully
built-out city, and `testMeasureTickBreakdown` splits a tick by component.

| map   | Debug    | Release  | lots |
|-------|----------|----------|------|
| 16×16 |   4.5 ms |   0.4 ms |   33 |
| 24×24 |  11.6 ms |   1.2 ms |   80 |
| 32×32 |  23.0 ms |   2.8 ms |  133 |
| 48×48 |  69.7 ms |   9.6 ms |  320 |
| 64×64 | 157.7 ms |  24.8 ms |  560 |

A 64×64 tick used to cost 6,286 ms in Debug and 114.5 ms in Release — 40x and
4.6x worse respectively. The cause was `LandValue.distanceToNearest` scanning
every tile on the map, eight times per `value(at:)` call, once per footprint
cell of every building: about 73 million tile visits per tick, and
`O(buildings × tiles)`, which is what made cost grow superlinearly with map
area. `ZoneDistanceField` precomputes every answer with a linear-time distance
transform instead. See its doc comment.

Both configurations now fit inside `SimulationSpeed.fast`'s 0.35 s interval at
every map size, so a Debug build (what Cmd-R gives you) can play a large map.
Release still blocks `@MainActor` for ~25 ms per 64×64 tick, about 1.5 frames.

**What's left:** `Traffic.computeLoad` is now ~90% of a tick (21.8 ms of 24.3
at 64×64). It runs a full breadth-first search over the road network per
residential building per tick, so it is `O(homes × road tiles)` — the
remaining superlinear term. Those searches depend only on the road layout and
building positions, neither of which usually changes tick to tick, so caching
them is the obvious next move if ticks need to get cheaper again.

### The treasury runaway, and how it was fixed

`upkeepCost` used to scale only with *placed infrastructure*, which stops
changing once a city is built out, while `taxRevenue` scales with *population
and jobs*, which climb until they plateau high. The result was a plateaued
64×64 city banking a flat +$6,160/tick forever, treasury past $9.2M in 1,500
ticks. `roadUpkeepPerTile` had been added to fix exactly this and hadn't,
because it addressed the wrong axis — no infrastructure-scaled constant can
close a gap between a static cost and a much larger static income.

`GameController.civicUpkeepPerCitizen` is the fix: a per-resident and per-job
cost, charged on the same axis `taxRevenue` is computed from. At 0.75 the same
city's steady-state net revenue falls from +$6,160/tick to +$1,798, about a
fifth of tax revenue — still profitable enough to fund expansion, no longer
unbounded. Kept below 1.0 deliberately, so against `taxPerPopulation` of 1 and
`taxPerJob` of 2 every resident and job stays net-positive and growth stays
worth pursuing.

## Is it a game yet? (measured)

`DesignPlaytestTests` runs the same map under different player strategies and
prints the spread. It exists to keep "is this fun" honest: a city builder is
only a game if the player's decisions move the outcome.

The first run (2026-09-14) found almost nothing pushed back on the player. Tax
rate had *zero* effect — 3,320 population at rates 0.0, 1.0 and 2.0 alike — and
zoning every lot residential was dominant at 5,152 population with no jobs at
all. Population spread between best and worst strategy was **2x**.

Two changes fixed that (2026-09-15), and the spread is now **37x**:

- **Tax rate suppresses growth**, via `Demand.taxDemandSensitivity`. Higher
  rates cost population and buy treasury, monotonically: 3,348 / 3,156 / 2,720
  people at rates 0.0 / 1.0 / 2.0, against -9.8M (bankrupt) / +2.6M / +14.0M
  treasury. A real tradeoff rather than a free win.
- **Oversupply bites.** `CitySimulator.minimumGrowthChance` went from 0.05 to
  0, and past `abandonmentDemand` buildings now lose density instead of merely
  stalling. All-residential collapsed from 5,152 population to 84, bankrupt.

Both depended on a third fix underneath them: `Demand` measured imbalance
against a flat scale of 30, so in a city of thousands demand was pinned at ±1
essentially always — a boolean, not a gradient, which swamped anything trying
to nudge it. It now scales with city size (`relativeScale`).

### Hazards, services, and repair

Hazard damage used to regrow on its own, which a design playtest measured as
worth about 20 population across a whole city — damage with no consequence, and
therefore services with nothing to protect. Adding services actively *cost*
population and money.

Damage now persists: a struck building records `Tile.damagedBy` (the service
whose absence let it happen) and neither grows nor decays until that service
covers it, at `CitySimulator.repairCoverageThreshold` — deliberately the same
number as `CityHazards.Risk.coverageThreshold`, so the repair condition is
literally "fix the gap that caused this." Bulldozing and rebuilding clears it
too, as the expensive escape hatch.

Services flipped from a net loss to the most valuable thing you can build:
population 1,640 with no services, 1,692 with them, 2,332 with them dense.
Ordinances went from moving population by ~4 to ~292. There is now an *optimum*
service density rather than "more is always better" — dense services buy
population but bankrupt the city, so normal spacing plus utilities beats them on
both axes.

One correction worth recording. Repair-gated damage with no other escape has no
equilibrium: a building below the coverage threshold takes a hazard at roughly
0.009 per tick, so over hundreds of ticks *every* uncovered building is hit, and
if only coverage clears damage then every uncovered building ends up
permanently dead. The first version did exactly that — nearly every strategy
went bankrupt and a service-less city fell to 32 people. That is a ratchet, not
difficulty. `unassistedRepairChancePerTick` (0.01) lets an uncovered block
rebuild itself eventually, so an unprotected district settles around half-broken
— visibly blighted, permanently worse off, but alive. Coverage still repairs on
the next tick, roughly a hundred times faster.

### Pollution: making *where* matter

Until this, nothing in the game cared where you put things. A factory next to
housing was identical to one across the map, so there was no reason not to zone
one homogeneous blob — most of why it read as placing boxes.

`Pollution` is an accumulating per-tile field (cached on `CityMap` like
`trafficLoad`) that industry emits in proportion to density, and `LandValue`
subtracts. Accumulating rather than nearest-only, because the point is that an
industrial *district* is worse than a lone factory, and "distance to the nearest
factory" cannot tell those apart. It has its own overlay.

Two calibrations were needed, both found by measuring:

- **Emission had to come down 3x.** At the first value a single fully-grown
  factory pinned an entire radius-3 blob at the 1.0 cap — no gradient, so
  stacking meant nothing and there was nothing to plan against.
- **Sensitivity had to become zone-dependent**, and this one is the whole
  mechanic. With every zone minding pollution equally, separating industry from
  housing bought *nothing* (2,384 planned vs 2,436 mixed), because concentrating
  industry concentrates the pollution onto the industry itself — whatever
  housing gained, factories lost. Residents now mind most (1.0), shops somewhat
  (0.6), factories barely (0.1). Planning then wins on both axes: 2,796 vs 2,576
  population and $2.0M vs $1.66M.

`DesignPlaytestTests.testAPlannedLayoutBeatsAHomogeneousBlob` is the standing
acceptance test, and it compares layouts with *identical* zone composition — an
earlier version also changed the R:C:I ratio and so compared two different
cities rather than two arrangements.

### Utility capacity: making *when* matter

Water and power used to be pure connectivity — one tower and one plant served an
infinite city, so growth created no new demands and you were finished with your
infrastructure the moment it was first connected.

Both now have capacity. Demand is the city's total density across growable
zones; capacity is `Water.capacityPerTower` (200) or
`PowerGrid.capacityPerPlant` (400) per building, scaled by funding — so the
funding slider buys throughput, not just coverage. Over capacity the whole
network drops, the same city-wide way a power outage already did. Growth stalls,
the toolbar meter turns red, and one more plant fixes it.

It is worth a lot: a 64×64 city on one tower and one plant reaches 1,976 people
against 3,580 with enough utilities, and spends every tick overloaded.

Finding it also turned up two bugs that had been quietly distorting everything.

**The harness had never placed a single power plant.** A plant is 3×3 and the
generated lot rows are two tiles deep, so the service rotation silently skipped
it every time. Every city ever measured for this project ran with *zero* power,
capped at density 3 by `powerRequiredFromLevel`, and nothing noticed until
capacity reported a capacity of zero. Plants now get a reserved strip along the
map edge. **Every population figure recorded before this is from a city that
could not exceed density 3.**

**`Traffic.computeLoad` was non-deterministic.** Route ties — two equally short
paths, two equidistant frontage cells — were broken by `Set` iteration order,
which is not stable between two sets holding the same elements, so consecutive
calls on one unchanged map alternated between different answers. It needs a map
complex enough to produce ties, so no hand-built fixture caught it; it surfaced
as the harness failing its own reproducibility check. Fixed by sorting
(`GridPosition.sortedByPosition()`) wherever order decides an outcome. Every
balance measurement taken before this carried that noise.

### Where the game stands (measured, 64×64, 1,500 ticks)

| strategy | population | treasury |
|---|---|---|
| all housing, no jobs | 100 | bankrupt |
| balanced, no infrastructure | 1,640 | $2.1M |
| + services | 1,740 | bankrupt |
| + water & power | 3,320 | $0.9M |
| industry zoned apart | **3,760** | **$1.5M** |
| one tower + one plant | 1,716 | — |
| all services unfunded | 1,268 | $1.4M |
| all services double-funded | 4,404 | bankrupt |

Best-to-worst spread is **33x**, and the levers are genuine tradeoffs rather
than dominant strategies — double funding buys the most people and bankrupts
you; maximum tax buys $13.9M and costs you residents; building services without
the utilities to support the growth they enable also bankrupts you.

The money sink works: a default city's treasury over 1,500 ticks fell from
$3.1M to $0.9M once civic buildings existed to spend on, and net revenue from
+2,084/tick to +598.

### Pollution: making *where* matter

Until this, nothing in the game cared where you put things. A factory next to
housing was identical to one across the map, so there was no reason not to zone
one homogeneous blob — most of why it read as placing boxes.

`Pollution` is an accumulating per-tile field (cached on `CityMap` like
`trafficLoad`) that industry emits in proportion to density, and `LandValue`
subtracts. Accumulating rather than nearest-only, because the point is that an
industrial *district* is worse than a lone factory, and "distance to the nearest
factory" cannot tell those apart. It has its own overlay.

Two calibrations were needed, both found by measuring:

- **Emission had to come down 3x.** At the first value a single fully-grown
  factory pinned an entire radius-3 blob at the 1.0 cap — no gradient, so
  stacking meant nothing and there was nothing to plan against.
- **Sensitivity had to become zone-dependent**, and this one is the whole
  mechanic. With every zone minding pollution equally, separating industry from
  housing bought *nothing* (2,384 planned vs 2,436 mixed), because concentrating
  industry concentrates the pollution onto the industry itself — whatever
  housing gained, factories lost. Residents now mind most (1.0), shops somewhat
  (0.6), factories barely (0.1). Planning then wins on both axes: 2,796 vs 2,576
  population and $2.0M vs $1.66M.

`DesignPlaytestTests.testAPlannedLayoutBeatsAHomogeneousBlob` is the standing
acceptance test, and it compares layouts with *identical* zone composition — an
earlier version also changed the R:C:I ratio and so compared two different
cities rather than two arrangements.

### Utility capacity: making *when* matter

Water and power used to be pure connectivity — one tower and one plant served an
infinite city, so growth created no new demands and you were finished with your
infrastructure the moment it was first connected.

Both now have capacity. Demand is the city's total density across growable
zones; capacity is `Water.capacityPerTower` (200) or
`PowerGrid.capacityPerPlant` (400) per building, scaled by funding — so the
funding slider buys throughput, not just coverage. Over capacity the whole
network drops, the same city-wide way a power outage already did. Growth stalls,
the toolbar meter turns red, and one more plant fixes it.

It is worth a lot: a 64×64 city on one tower and one plant reaches 1,976 people
against 3,580 with enough utilities, and spends every tick overloaded.

Finding it also turned up two bugs that had been quietly distorting everything.

**The harness had never placed a single power plant.** A plant is 3×3 and the
generated lot rows are two tiles deep, so the service rotation silently skipped
it every time. Every city ever measured for this project ran with *zero* power,
capped at density 3 by `powerRequiredFromLevel`, and nothing noticed until
capacity reported a capacity of zero. Plants now get a reserved strip along the
map edge. **Every population figure recorded before this is from a city that
could not exceed density 3.**

**`Traffic.computeLoad` was non-deterministic.** Route ties — two equally short
paths, two equidistant frontage cells — were broken by `Set` iteration order,
which is not stable between two sets holding the same elements, so consecutive
calls on one unchanged map alternated between different answers. It needs a map
complex enough to produce ties, so no hand-built fixture caught it; it surfaced
as the harness failing its own reproducibility check. Fixed by sorting
(`GridPosition.sortedByPosition()`) wherever order decides an outcome. Every
balance measurement taken before this carried that noise.

### Where the game stands (measured, 64×64, 1,500 ticks)

| strategy | population | treasury |
|---|---|---|
| all housing, no jobs | 100 | bankrupt |
| balanced, no infrastructure | 1,640 | $2.1M |
| + services | 1,956 | bankrupt |
| + water & power | 3,580 | $3.1M |
| industry zoned apart | **3,984** | **$4.3M** |
| one tower + one plant | 1,976 | — |
| all services unfunded | 1,268 | $1.4M |
| all services double-funded | 4,852 | bankrupt |

Best-to-worst spread is **35x**. Every lever now moves the outcome, and several
are genuine tradeoffs rather than dominant strategies — double funding buys the
most people and bankrupts you; maximum tax buys $17.5M and costs you residents.

### Re-tune after the power-plant fix: the constants held

Since every earlier measurement came from cities capped at density 3, the
balance constants were re-checked against cities that reach density 5. **None
of them needed changing.** What was wrong was two tests.

- `civicUpkeepPerCitizen` (0.75) still lands almost exactly on its target: tax
  revenue 9,806/tick against upkeep 2,778 and civic 4,995, for net 2,034 — a
  net-to-tax ratio of 0.207 against the 0.2 it was aimed at. It scaled for free
  because it is charged per citizen, the same axis tax revenue is computed on.
- The `CityHazards` rates are fine; the assertion was not. "Strikes per tick" is
  not scale-invariant — hazards roll once per building, so a bigger city takes
  proportionally more at an identical per-building rate. The bound passed at
  16×16 and failed at 64×64 with the rates untouched. It now measures strikes
  per building per tick: 0.00396, or one strike per building per ~250 ticks.
- The bond scenario borrowed at tick 0, when `bondCap` is still the $15,000
  floor because nobody lives there yet — so it was testing the *smallest* debt
  the game allows rather than the largest. Borrowing once the city exists
  raises interest from 37/tick to 112, about 5.5% of net revenue: a modest but
  real cost.

The lesson worth keeping: when a measurement changes, check whether the thing
being measured moved or the yardstick did.

### Unlocks: a ladder, not an ending

An open-ended city builder has no win condition — the genre's answer to "why
keep playing" is a progression of tools you earn, the way SimCity 2000 gates a
library at 2,000 residents and a stadium at 90,000. Everything here was
available from tick one, which cost two things: nothing to aim at, and no shape
to the early game, since a new city could paint every tool it would ever have
across the whole map immediately.

`Unlocks` gates tools behind a population high-water mark:

| unlocks at | tools |
|---|---|
| start | residential, commercial, industrial, road, water pump, generator (and the bulldozer, always) |
| 40 | police station, fire station |
| 100 | water tower |
| 200 | transit stop |
| 300 | power plant |
| 500 | highway |
| 700 | subway |
| 1,000 | stadium |

Thresholds are shaped by the gates that already exist rather than picked
freely. Water is needed to pass density 2, so the tower has to arrive while a
city is still capped there; power gates density 4, so the plant lands just past
where water-only growth tops out. The cheap/upgraded pairs keep their order.

**The starter utilities exist because of a bug playing the game found.** A
building raises a "no water" warning badge from density 2, but the tower was
locked until 100 residents — so a new city showed errors for a problem the
player was forbidden from fixing. `.waterPump` and `.generator` are the small,
cheap, low-capacity versions available from tick one; the tower and plant became
upgrades rather than prerequisites. They form the same cheap/upgraded pair
`.road`/`.highway` and `.publicTransit`/`.subway` already use, share their
counterpart's funding dial, and feed the same networks.

The general rule worth keeping: **every warning the game raises has to have an
answer the player can act on right now.**

A **high-water mark**, not current population: a city knocked back by fire or a
bad tax rate keeps what it earned. Losing the fire station because your city
burned down would be exactly backwards. It rides in `CitySave` as an `Optional`,
so saves written before unlocks still load.

Locked tools are shown disabled with what they need, not hidden — the next rung
has to be visible for it to be something to aim at. That also thins the zoning
row from thirteen buttons to four for a new city, which is a UI problem
`GameView`'s own doc comments had already flagged twice.

### Education and health: the mid-game axis, and a money sink

A mature city was banking millions with nothing left to buy, and the genre's
classic mid-game progression — schools and hospitals gating better development
— was missing entirely. Those are the same problem: a progression axis is what
gives money somewhere to go.

- **`.school`** is the third and last rung of the utility ladder. Water gates
  density 3, power gates 4, and a school in range now gates 5. The top tier used
  to be a reward for building *near good things*; it is now something you go and
  build for.
- **`.hospital`** halves what a hazard takes out of the blocks it covers. It
  does not prevent a strike — coverage by the *relevant* service is what does
  that — and it never makes a hazard free, so a one-level risk stays one level.
  That gives it a role of its own rather than making it a second police station.

Both are the heaviest ongoing costs in the game (a hospital is the single most
expensive thing to run), which is the sink. Both unlock mid-game, school first,
since a school has to arrive before a city is pressing on the ceiling it opens.

Two harness fixes came out of this. The generator now places schools and
hospitals — without a school no generated city can reach density 5, so every
scenario would quietly have been measuring a capped city. And lot assignment
moved to two passes so that `segregateIndustry` rearranges the *same* zones
rather than producing a different mix; the single-pass version gave the planned
and mixed layouts genuinely different compositions once services had eaten an
uneven share of each, which made the planning comparison a comparison of two
different cities.

The quick playtest profile also grew from 16×16 to 24×24. The smaller size was
chosen when a tick cost 25.8 ms; after `ZoneDistanceField` a 24×24 tick costs
11.6 ms, so it is *cheaper* than the old profile while being big enough that a
full set of services is not a fixed cost heavy enough to bankrupt the city on
its own.

### Still open

| finding | evidence |
|---|---|
| **Money still accumulates, more slowly** | a default city banks $0.9M over 1,500 ticks (down from $3.1M), a max-tax one $13.9M. Better, not solved. |
| **No pacing** | a fully zoned map still fills in within a handful of ticks. |
| **No goals** | no win condition, milestone or objective — nothing to aim at once the city runs itself. |
| **Testing gotcha** | `AlwaysZeroRNG` fires every hazard every tick, so fixtures without service coverage are levelled and never recover. See its doc comment. |

One caveat on the numbers: the harness zones a whole map at once, where a
player zones incrementally. "A handful of ticks to plateau" describes how fast
zoned land fills in, not session length.

## The toolbar, and utilities that work out of the box

Two things playing the game turned up, both about the first five minutes.

**A utility now serves its surroundings without pipes.** A new player's
instinct is to put a pump next to the houses, and that did nothing: supply
needed an unbroken pipe run, and laying pipe means finding the Water overlay
first — which now lives in a menu. So a starter city sat there showing "no
water" warnings with a pump right beside it. `Water.directSupplyRadius` (4
tiles, matched by `PowerGrid`) makes the obvious move work and leaves pipes as
what they should be: the way to *extend* a utility across a city rather than a
prerequisite for it doing anything. Direct service still respects capacity and
funding, so it is not a way to dodge either.

Worth noting the shape of that bug: the radius was implemented correctly and
still did nothing, because `computeSupply` returns early when a city has no
pipes *at all* — and that early return predates the radius. Direct coverage is
now computed before every guard.

**The toolbar does everything on its own.** Moving the settings to menus went
too far: the overlay picker went with them, and pipes and power lines are laid
by clicking while their overlay is up — so both became unreachable without the
menu bar, with nothing on screen saying they existed. The overlay picker is back
in the status row, and Pipe and Power Line now appear as tools in the Water &
Power group, which is where a player looks for them anyway. The menus stay as a
second route, not the only one.

Picking a zone tool leaves a network overlay (`GameController.selectTool`), so
the two are mutually exclusive — otherwise choosing Residential with the Water
overlay up leaves you in an invisible mode where clicks lay pipe instead.

**The tool row is grouped.** Seventeen tools in one row had stopped fitting;
`ToolCategory` splits them into Zones, Transport, Water & Power and Services,
with Bulldoze always visible outside the groups (needing to change category
before you can undo would be miserable). Within a group tools appear in unlock
order, so everything currently available sits to the left and locked tools
trail off to the right. `ToolCategoryTests` asserts every zone belongs to
exactly one group — a new `ZoneType` that nobody adds to a category would
otherwise be unreachable from the toolbar with nothing to say so.

## Menus, and one SwiftUI trap

Simulation, Overlay and City menus hold everything you set occasionally; the
toolbar keeps the zoning tools and Play. The budget (tax rate, the seven
funding dials, a per-tick summary) is a sheet behind City ▸ Budget… (Cmd-B).

**The trap, because it cost real time to find:** an *empty*
`CommandGroup(replacing: .newItem) { }` — the documented idiom for removing a
menu item, and what this app used from the scaffold onward to drop "New
Window" — corrupts menu construction on macOS 27. With it present, three
`CommandMenu`s declared right after it silently never appeared, with no error
and no warning. With it present and those menus removed, the *File* menu itself
vanished. Giving the group real content instead fixes both, so the city
commands now live in that group rather than in a separate `.saveItem` one.

Worth remembering generally: SwiftUI menu problems fail silently, so verify the
menu bar visually (a screenshot works) rather than trusting that it compiled.
Accessibility scripting against this app proved unreliable — System Events
reported "no menu bar" for an app whose menu bar was plainly on screen.

## Save and load

`Cmd-O` / `Cmd-S` / `Cmd-Shift-S`. Cities are JSON (`.alphacity`), written
atomically, defaulting to `~/Library/Application Support/Alpha++/Cities`.

The layering is deliberate and worth preserving: `CitySave` (Simulation/) is a
pure `Codable` value and knows nothing about files; `CitySaveFile` (App/) does
the encoding and disk I/O; `CityDocument` (App/) owns the open city, the
current file, and the panels. That split is what lets the playtest harness
snapshot and replay cities with no file ever existing.

Two invariants the tests pin: a save from a newer `formatVersion` is rejected
*before* `restore(from:)` mutates anything, so a bad file leaves the open city
intact; and a load bumps `GameController.cityGeneration`, which is how
`GameView` knows to rebuild the scene's sprites rather than just refresh them
(a load can change the tile count).

## Buildings are generated, not drawn one at a time

`ZoneIcon` used to hold two hand-written shape functions per zone per tier, and
a hash picked between them. That does not reach the ten-plus looks per zone per
tier this project now targets — that would be ninety functions — so growable
zones are moving to parametric generators instead: a building is *composed*
from parts against a seed, and the number of distinct results is the product of
those choices rather than the number of functions anyone typed.

`IndustrialBuilding` was the first, and industry went first for a reason the
contact sheet made obvious: all three growable zones drew the same silhouette,
a tall rectangle with a window grid, and differed only in hue. With the colour
stripped you could not tell a factory from a tower block. Industry now draws
wide and low, with sawtooth or monitor rooflines, one to three chimneys,
storage tanks and loading bays — a vocabulary nothing else in the game uses.
`ResidentialBuilding` answers it with stepped massing, punched window grids,
balcony bands and rooftop tanks; `CommercialBuilding` with continuous glazing
bands, glazed podiums, projecting signage and lit crowns. Those three
vocabularies are chosen to stay apart in greyscale, not just in hue.

Three rules this establishes:

- **Varying numbers is not variety; varying the building is.** The first
  residential and commercial passes varied only dimensions, and the contact
  sheet showed the cost at once: every tier-1 commercial lot was the same
  drawing at slightly different widths, because at tier 1 each random branch
  was either disabled by a `tier >= 2` guard or forced to one value. Both
  generators now pick a *form* first — a strip of shops, a corner unit, a shop
  with a flat over it; a row of separate houses or one stacked block — and only
  then size it. Low density is where most of a city's map area sits, so it is
  the tier that can least afford to be one drawing.

- **A lot's look is stable, its neighbour's is different.** `BuildingRandom`
  seeds from the lot's own position, so a building draws identically on every
  tick and every launch but differs from the one next door. It deliberately
  avoids `GridPosition.hashValue`, which Swift randomises per process.
- **The shared drawing vocabulary stays shared.** `ZoneIcon`'s primitives
  (`neonShape`, `detail`, `withGlow`, the window and sign palettes) are
  `internal` so generators can live in their own files while drawing in the
  same idiom — which is what stops the zones drifting into looking like three
  different games.

`ZoneIconContactSheetTests` renders ten seeds per tier for a generated zone and
asserts they produce at least seven structurally distinct buildings. A
generator that technically produces thousands of identical-looking buildings is
no better than the two hand-drawn ones it replaced, and that is the failure the
count is there to catch.

One caveat when reading the sheet: ten seeds is a small sample, and a fair
coin-flip branch really can come up two-out-of-ten on it. Before "re-balancing"
a probability because the sheet looks lopsided, count the branch over a whole
map's worth of positions — the residential house-row branch reads 2/10 on the
sheet's seeds and 2020/4096 across a 64×64 map. Tuning the generator to flatter
ten particular seeds is fitting the art to the yardstick.

Two composition traps this pass hit, both worth remembering because neither
failed a test:

- **Stack details from measured geometry, not guessed offsets.** A clerestory
  window band placed at `body.maxY - 20` landed *inside* the shopfront glazing,
  because the glazing's height is itself random. Having `shopfront` return
  where its glass actually ends fixed it — and revealed that a 36-point block
  has no room for both a sign band and a window band anyway, so the strip form
  now carries one or the other, which gave it two looks instead of one.
- **Clamp anything placed relative to a random width.** An unclamped rooftop
  plant box could be offset past its own parapet, where it read as a rectangle
  floating beside the building rather than as rooftop machinery.

## The isometric migration (done)

**The game is isometric.** It runs in eleven phases' worth of commits, and the
short version is: buildings stopped being drawings and became descriptions, a
projection turns those into pixels, and the top-down path was deleted once
nothing needed it.

**The problem it solves.** The game draws its ground from directly overhead
and its buildings as front elevations, as if seen from the street. Those are
two viewpoints in one picture, which is why a building reads as a lit card
standing on a floor plan. No amount of colour or glow tuning closes that: a
shape reads as a volume when you can see two of its faces at once, and an
elevation has one.

**And it suits this art direction rather than fighting it.** Neon is an *edge*
treatment. In elevation a box has no visible edges, so the glow can only trace
a silhouette — which is precisely what the current buildings look like. In
isometric the same box shows a top and two sides, and the creases between them
are real lines with direction. The style gets structure to light.

### What the migration actually touches

`GridLayout`'s doc comment claims a switch to isometric is a change to that one
struct. That is true for *positioning* and nothing else:

| | why |
|---|---|
| `GridLayout.position(for:)` | Today an integer divide, because squares tile trivially. Diamonds do not; click-to-tile needs the inverse projection. |
| **Draw order** | Every tile sprite sits in `tileLayer` at `zPosition = 0`. Correct top-down, where nothing overlaps; fatal in isometric, where a near building must occlude a far one. Needs a painter's algorithm keyed on `x + y` (`Isometric.sorted`), maintained through `rebuildRegion`. |
| The three generators | The *forms* survive — a strip of shops, a corner unit, a row of houses, a sawtooth roof are massing decisions, not drawing ones. What has to change is that they stop returning an `SKNode` of a facade and start returning **massing**: boxes in tile units, which a projection then draws. That split is the same one the project already draws between simulation and rendering, one level down. |
| `fitIconToTile`, `spriteSize(forFootprint:)` | "Fit a 2×2 lot" means fitting a diamond. |
| Overlays, roads, lane lines, cars, placement preview | All tint or draw squares today. |
| Both renders | The streetscape composites per lot into a tile rect, which isometric buildings break by overlapping. The spike shows the fix: depth-sorted batches composited back to front. |

### Phase 1 (done): the description layer

Three files, none of them wired into the running game yet:

- **`Isometric`** — the projection. A struct, not an enum of constants, for the
  same reason `GridLayout` is one: the render tools draw the same city at
  several scales. Carries `groundPosition(for:)`, the click inverse, and
  `sorted`, the painter's-algorithm ordering.
- **`BuildingMassing`** — what a building *is*: `Box`, `Ridge` and `Cylinder`
  volumes in tile units, lit `Panel`s on their faces, `Badge`s for signage.
- **`IsometricBuilding`** — what that looks like from the camera.

Four decisions in there are load-bearing:

- **Every volume reduces to `Face3`.** Visibility and shading then have exactly
  one implementation. The spike hardcoded "top, right, left" per volume, which
  is correct for a box and wrong the moment anything slopes — see the gable test
  below. `Cylinder` is an N-sided prism for the same reason: it gets per-face
  shading for free instead of needing its own.
- **Face normals are forced outward from the volume's centre.** Winding order
  decides a normal, and getting it wrong on one face out of six produces no
  compile error and no crash — the face just goes missing, or lights from the
  wrong side. Since every volume knows its own centre, the sign is checked
  rather than hand-verified, which deletes the whole bug class from the
  generators still to come.
- **Solids and panels sort together, not in two passes.** Drawing every panel
  after every solid is the obvious implementation and it is wrong: a window on
  a far building's wall would paint over a near building in front of it.
- **One blur pass per building, not per volume.** `ZoneIconContactSheetTests`
  has twice shown a scene silently dropping effect nodes past a budget, so a
  five-box building costing five of them would fail quietly, by the map just
  losing buildings. Pinned by a test.

And one result worth keeping because the intuition is backwards: **from a
bird's-eye camera a shallow roof shows both its slopes and a steep one hides
the far slope behind the ridge**, the opposite of how a house looks from the
street. The far slope's normal is proportional to `(0, rise, run)`, so it faces
the camera only while `run > 1.018 × rise`. The test asserting this was first
written the other way round and the code was right.

### Phase 2 (done): industry, and three things it taught

`IndustrialMassing` ports the whole vocabulary — wide low hall, sawtooth or
monitor or flat roofline, chimneys, tanks beside the hall, lit bays, loading
dock, hazard badge. `ZoneMassing` dispatches to it and returns `nil` for every
zone not yet ported, which is what lets `IsometricContactSheetTests` render
exactly what exists. The running game is untouched and still on elevations.

**`Isometric.toCamera` was inverted, and a passing test hid it.** `project`
sends increasing `x` *and* increasing `y` down the screen, and down the screen
is nearer the viewer, so the camera sits at positive x, y and z. Written
negative, it culled exactly the three faces pointing at the camera and drew the
three pointing away. Nothing crashed; the face *count* was still three, so
`testBoxShowsThreeFaces` passed. The visible symptom was lit panels apparently
floating in mid-air — they were correctly placed on the near walls, and those
walls were the ones being discarded. The test now asserts *which* faces are
visible rather than how many, which is the general lesson: a count is not an
identity.

**Height had to be calibrated against the lot, not guessed.** A tile reads as
roughly eight metres, so a 2×2 lot is a sixteen-metre frontage and one tall
factory storey is about one tile unit. The first pass used 0.4, which is a
two-metre shed: the halls came out as plates with walls too short to hold a
window. Height is the one dimension isometric adds, and under-using it throws
away the reason for the projection.

**A flat roof is the quiet option, not a blank one.** In elevation a flat roof
was a single line at the top of a silhouette. Isometric shows the whole roof
plane, so an empty one is the biggest surface on the building saying nothing;
flat-roofed halls get rooftop plant instead.

### Phase 3 (done): housing, and two marks that got *better*

`ResidentialMassing` carries the vocabulary across unchanged — stepped massing
that narrows as it rises, punched window grids rather than continuous bands,
rooftop clutter rather than lit crowns, and a row of separate houses at tier 1.

Two of those marks are genuinely better in isometric rather than merely
equivalent, which is worth naming because it is the payoff for the migration
rather than the cost of it:

- **A balcony is now a ledge, not a line.** In elevation it was a bright
  horizontal with railing posts, and the posts had to be deleted for being a
  quarter of a screen point wide, which left a line. Here it projects past the
  wall on every side and wraps the corner, so it reads as a balcony from its
  silhouette alone — the shape carries the meaning instead of the decoration,
  which is exactly the fix `minimumDetailSize` keeps asking for and elevation
  could not provide.
- **A pitched roof is a volume.** It was a trapezoid stuck on a rectangle;
  it is now two slopes and a gable end, and how many of them you see depends on
  the pitch.

### Phase 4 (done): commerce

`CommercialMassing` keeps the split that matters — continuous glazing bands
against housing's punched grid, a glazed podium, projecting signage, and an
illuminated crown where housing puts machinery. Tier 1 still picks between a
strip of shops, a corner unit, and a shop with a flat over it.

Two things the projection adds here:

- **Glazing bands wrap the corner.** In elevation a band was a horizontal on
  one face; here it runs the full width of both visible walls and turns the
  corner, which is what a continuous floor plate actually does and what makes
  the contrast with housing's separate little windows unmistakable at any zoom.
- **A blade sign is a volume standing off the wall.** In elevation a projecting
  sign was a bright rectangle beside a silhouette, indistinguishable from one
  painted *on* it; the only thing saying it projected was that it overlapped
  the outline. Now it stands proud and throws its own glow into the air beside
  the building. Same win as the balcony: the shape carries the meaning.

That completes the three growable zones. `ZoneMassing` covers them and still
returns `nil` for services, which is the next phase.

### Phases 5–6 (done): the eleven services

`ServiceMassing` covers all of them, 1×1 through the 3×3 power plant and
stadium. `ZoneMassing` now returns massing for every zone that has a building,
which completes the catalogue: the remaining phases are layout, scene and
decorations, not art.

**One generator per service, not two hand-picked looks.** `ZoneIcon` draws
exactly two variants of each, because hand-writing a third was unaffordable —
the file says as much. Massing has no such limit, so the seeded parameters that
give growable zones their variety work here too, and two fire stations differ
the way two factories do without anyone writing a second function.

What is preserved exactly is each service's **identity mark** — the one feature
that makes it findable while scanning for coverage gaps, which is what these
icons are *for*. A hose-drying tower, a tank on legs, a gable and a clock, a
cross, cooling towers, a bowl with floodlights.

Four things worth keeping:

- **The variety bar is lower for services, and not to make a test pass.** A
  growable zone tiles the map, so repetition reads as wallpaper. A city has two
  fire stations; what they owe the player is identity, and demanding eight
  distinguishable ones would trade that away for a property nobody can
  perceive. They still have to not be literally one building.
- **A service has no density**, so cataloguing it at three tiers rendered three
  identical copies of every fire station — noise pretending to be coverage.
- **An identity mark has to be placed where it can be seen.** The firehouse
  tower started at a far corner, where it sorts behind the body and survives
  only as a stub through the roof — which reads as a chimney, and a chimney is
  industry's mark. It sits at a near corner now. The school's clock tower was
  sized against the body and came out shorter than the roof it stood in.
- **Ties in the sort order are a real bug.** The hospital's cross is two boxes
  sharing a centre and an elevation, which ties every sort key, so which one
  landed on top came down to insertion order and at some seeds the plus
  collapsed to a single bar. They differ by a hair of height now.

### Phase 7 (done): layout and picking

`Isometric` gains the map-level operations `GameScene` needs — tile centres,
footprint centres, content bounds, camera centre, the click inverse, and the
depth key. Deliberately added to `Isometric` rather than bolted onto
`GridLayout` as a mode: in isometric there is no "sprite size" to fit a
building into, because massing occupies real space, so the two layouts have
genuinely different interfaces rather than one interface with different numbers.
`GridLayout` stays untouched until the elevation path is deleted.

Three decisions worth recording:

- **Picking is against the ground plane, not against what is drawn on it.** A
  point over a tall tower's upper floors is geometrically over ground several
  tiles *behind* the tower. Either answer is defensible; a city builder wants
  the ground, because every tool acts on a lot rather than a building — place,
  zone and bulldoze are all "this square of land" — and picking the tower would
  make the lot behind a skyscraper unselectable. Pinned by a test so it cannot
  drift into "topmost drawn thing" by accident.
- **Depth is a `zPosition`, not a sort of the child array.** `rebuildRegion`
  adds and removes nodes in a ±4-tile window without touching the rest, and
  re-sorting a whole tile layer on every placement would undo the 40x saving
  that exists for.
- **A multi-tile building sorts by its nearest corner, not its anchor.** A 3×3
  anchored at (1,1) reaches tile (3,3), so its key is `x + y + 2(N-1)`. Keyed on
  its anchor, a stadium would be painted over by the very tiles it covers. The
  first implementation used `x + y + N - 1`, and the test caught it.

`contentBounds` is the *ground* diamond rather than everything drawn: buildings
rise above its top edge, and clamping the camera to include them would let the
view drift off the map whenever a tall tower stood near an edge.

### Phase 8 (done): the scene renderer, and the texture cache

`IsoTileRenderer` is `TileRenderer`'s counterpart: one node per building
anchor carrying its ground diamond, its light pool, its surveyed-lot marker and
its building, with `zPosition` set from `Isometric.depth`. `IsometricCityTests`
renders a whole city through it at every zoom — the isometric streetscape, and
the acceptance test for everything a per-building sheet cannot show.

**`BuildingTextureCache` is the answer to the node count**, and it is worth
being honest about what it costs. An isometric building is ~55 `SKShapeNode`s,
which do not batch, so a built-out 64×64 map would ask for tens of thousands of
draw calls a frame. Buildings never change once placed, so that is paying
repeatedly for an identical result. Rendered once to a texture, a building is
one sprite.

But a cache only helps if it *hits*, and every lot has a different seed — so
caching per lot would store one texture per building and hit never. The seed is
therefore **quantised**: a lot picks one of `variantCount` looks for its zone
and tier rather than one of unboundedly many.

That is a real reduction in variety. It is also exactly the target this file
asks for ("ten or more distinct looks per zone per tier"), and what is lost is
the difference between that and thousands — imperceptible on a map showing a
hundred lots at once, against a map that draws at all. `variantCount` started
at sixteen and is thirty-two; see "More buildings, and a fire that is on
theme" below for why that number, and not a generator, was the thing holding
variety back. The
quantisation lives in the cache, not the generators, so `IndustrialMassing` and
friends stay pure functions of a seed and the contact sheet keeps showing
genuinely unbounded variety.

Two consequences worth noting:

- **The whole city renders in one scene with no effect node in it.** The
  top-down streetscape had to composite in depth-sorted batches because a scene
  silently stops servicing blur passes past a budget. With buildings
  pre-rasterised there are none left to service — the blur happens once per
  variant, inside the cache.
- **Variant choice is mixed from the position, not taken modulo it.** Modulo
  would march neighbouring lots through the variants in step and produce
  visible diagonal stripes of identical buildings. It also avoids `hashValue`
  for the reason `BuildingRandom` documents: Swift randomises it per process,
  and a city must not reshuffle itself between launches.

### Phase 9 (done): the flip

**`GameScene` is isometric.** It holds an `Isometric` and an `IsoTileRenderer`
where it held a `GridLayout` and a `TileRenderer`; tile nodes carry a
painter's-algorithm `zPosition`; clicks go through the ground-plane inverse;
the camera and the sun glow are placed off the ground diamond's bounds.

**Two bugs the compiler could not catch**, both of which would have shipped as
silent losses of behaviour rather than crashes:

- **`SKAction.colorize` does nothing on a plain `SKNode`.** All three feedback
  flashes — insufficient funds, blocked placement, hazard struck — worked by
  colorizing the tile's `SKSpriteNode` and animating back. An isometric tile
  node is a plain node holding a ground shape, so they kept compiling and
  stopped doing anything. They are a fading diamond now, which works on any
  node, needs no restore colour, and cannot go quietly dead. That also retired
  `currentColor(at:)` — a switch over every overlay mode that existed only to
  answer "what do I fade back to".
- **Cars drove along screen axes.** A road running east-west is a horizontal
  line on a top-down map and a *down-right diagonal* in isometric, so laying
  cars out along screen x or y sends them off the road at forty-five degrees.
  Lanes are expressed in tile units and projected now, and a car's rotation
  comes from the projected heading rather than a fixed angle per axis.

**Cache keys went in before the blink, not after.** `refreshAll()` runs every
decoration for every tile on every tick, so without them each tick rebuilds
thousands of shape nodes and re-hangs every building sprite — exactly the churn
recorded under "why the map blinked". The top-down renderer grew its keys after
a live playtest surfaced the problem; this one has them from the start, plus a
test that re-syncing an unchanged tile replaces none of its children.

Related, and easy to get wrong: **an overlay has to invalidate the keys of what
it hides**, not merely remove the nodes. The key is what decides whether a
decoration is rebuilt, so a stale one would mean the map never came back after
a player looked at land value — and it would look exactly like the overlay
working.

**Overlay handling collapsed from five branches of ten `clear…` calls to one.**
Every decoration added since the overlays were written had to be remembered in
all five, which is the kind of repetition that goes stale silently: a forgotten
line leaves a stray building floating over a heatmap rather than failing
anything. `applyOverlay` is the whole idea — hide what describes the building,
tint the ground.

### Phases 10–11 (done): bounds, cost, and a large deletion

**The camera is clamped to the map.** Panning was unbounded top-down and should
not have been — a stray flick left you looking at empty background with no
landmark to steer back by. Survivable when the map was a square filling the
view; much worse now it is a diamond whose corners are the only thing near the
screen edges. Clamped against the *ground* bounds, generously, so the point is
keeping the map findable rather than fencing the player in.

**What a built-out map costs, measured:** a 40×40 city of 832 buildings is
**2,177 nodes — 2.6 per lot — and 48 textures**. Without the texture cache the
same map is roughly 37,000 `SKShapeNode`s, which do not batch. Reported in the
test log rather than only asserted, because a number in a build log is what
makes a regression visible before it is a stutter.

**The elevation path is gone: 3,743 lines deleted against 135 added.**
`ZoneIcon`, `TileRenderer`, `GridLayout`, the three elevation building
generators, and the two top-down render tests. What survived is
`NeonStyle` — `ZoneIcon` with the icons taken out, and named for what it
actually is: the palette and primitives that keep a lit window the same colour
in a factory and a hospital, and stop the zones drifting into looking like
three different games. That half was always the more durable one.

The perf test that compared isometric against elevation went too. It was the
right question while both existed — finding out isometric cost four times as
much was worth doing at one zone ported rather than six — but with nothing to
compare against it would only measure itself. It guards the absolute number
now, which is what the texture cache has to rasterise and what would come
straight back as draw calls if that cache were ever bypassed.

## The cockpit (in progress)

The chrome is being rebuilt as a dashboard rather than two rows of buttons.
`GameView` had grown to four hundred lines of hand-rolled `HStack`s, so adding
anything meant editing one of them — which is how the toolbar overflowed twice
and how ordinances and bonds ended up with no home in the UI at all.

Phase 1 is the parts: `RetroUI` holds the tokens and the components
(`RetroPanel`, `RetroToolChip`, `RetroMeter`, `RetroBadge`, `RetroStatTile`,
`ChamferedRectangle`), so a new control becomes a line of data rather than a
line of layout.

Three decisions worth recording:

- **A fraction is a number; a meter is a status.** Utility load read
  `Water: 0/0`, and capacity is the one mechanic where "how close am I to the
  ceiling" *is* the question — it is what makes growth create new demands
  rather than being finished the moment it is first connected. A bar that fills
  and turns red answers that at a glance.
- **Locked tools show the gate, not a disabled button.** `Unlocks` already
  knows the population each tool needs; expressing that as `.disabled` plus 35%
  opacity reads as "broken" rather than "not yet". A locked chip carries a
  padlock and the shortfall, which turns a dead button into the thing it was
  meant to be — something to aim at.
- **Corners are cut, not rounded.** A 45° chamfer is the cheapest single thing
  that stops this chrome reading as a dark-mode macOS button.

### Phase 2: a toolbar you add to with data

`ToolbarEntry` describes what a button *does* — place a zone, edit a network —
along with its name, cost and whose neon it borrows. `ToolCategory.entries`
lists them, and `GameView` renders that list.

The branch this removes is the point. Pipes and power lines are not
`ZoneType`s: they are separate layers edited by clicking while their overlay is
up, so the row special-cased them with an `if category == .utilities` wedged
into the middle of its layout. Anything that was not a `ZoneType` needed
another such branch, which is exactly why ordinances and bonds still have no
button — adding one meant editing layout rather than adding data.

Three tests hold the registry honest, and they are the reason it is safe for
the layout to be dumb about what it is rendering: every entry appears exactly
once across all groups; both editable networks are offered (nothing else in the
suite would notice pipes going missing, and they were once completely
unreachable); and every entry's advertised cost is what it actually charges.

`GameController.pipePlacementCost` and its power-line twin became
`nonisolated`, so the registry can name a cost without being main-actor bound.
They are immutable `Int`s — the isolation bought nothing and cost
`ToolCategory` its independence from the controller.

### Phase 3: the cockpit

Tools live above the map, readouts below it. They were stacked together in one
block, which is how a row carrying ten things ended up with no give left: tools
and readouts competed for the same width and the readouts always lost, because
the tools are what a player clicks. They are different kinds of thing — one is
a verb, the other is the city answering back — so they get different edges of
the screen.

Three things this fixed that were not cosmetic:

- **The tool row scrolls rather than overflows.** A squeezed `HStack` shrinks
  the last things it lays out first, so the rightmost tools were the ones that
  vanished — and those are the *locked* ones, which is to say the ones a player
  most needs to see to know what they are working toward. `.fixedSize()` on the
  chips stops them compressing; a horizontal `ScrollView` stops the row
  clipping them.
- **One alert was invisible.** The power-outage warning lived inside the
  overlay hint, which only renders while the Power overlay is up — so a city
  could be blacked out and never say so unless the player happened to be
  looking at the right overlay. Alerts have their own panel now, always on
  screen.
- **The readouts have room.** Demand, utility load and treasury are the signals
  the whole simulation exists to produce, and they had been squeezed into
  whatever width was left over on a single row.

`RetroUIContactSheetTests` renders the assembled cockpit as well as the parts,
from the same components the live view uses — a picture of the real chrome
rather than a mock of it.

### Phase 4: City Hall

`BudgetPanel` became `CityPanel`, and ordinances and debt moved into it.

They had lived only in the City menu, on the reasoning that a toggle and an
action translate to menu items cleanly. They do — but **a menu shows a
control, not a state**, and both of these are mostly state: an ordinance's
upkeep scales with population, so its cost is a number that changes under you,
and a bond is a debt with a cap and a per-tick interest charge that nothing on
screen mentioned at all. A player could be paying interest every tick with no
way to see the balance, short of opening a menu that does not show it either.

The panel is also reachable from the cockpit now, not just the menu bar. Tax,
funding, ordinances and debt were *all* menu-only, which made the entire
economic half of the game invisible to anyone who did not go looking in a menu
for it. `isShowingCityPanel` moved to the controller, since there are now two
routes in and a sheet needs one owner.

Two things the render caught that the app would have hidden:

- **`ImageRenderer` cannot measure scrolling content**, so a `ScrollView` added
  to keep the taller panel usable made the whole body vanish from the contact
  sheet. That was worth more than the scroll view: a panel nobody can look at
  is how the truncated treasury readout survived. Two columns halve the height
  honestly instead.
- **A native `Toggle` was the last piece of stock AppKit chrome** in a panel
  that is otherwise entirely hand-drawn neon — and it does not render either,
  so the one control whose *state* is the whole point was the one control
  nobody could see. Ordinances are chips now, the same ones the toolbar uses.

### Phase 5: polish, and the two components that predated the language

The cockpit is done. What this pass added is mostly texture — scanlines on
panels, hover on buttons, a warm bleed at the seam — but two of the changes are
about consistency rather than decoration, and those are the ones that were
actually wrong:

- **`DemandBar` was the last progress bar.** Rounded segments on a grey track,
  where everything else in the cockpit is square segments on an accent-tinted
  track with a glow on the lit ones. It was the only thing left that looked
  like a loading indicator rather than an instrument.
- **`Sparkline` was the one graph that did not glow.** A single hairline, in a
  cockpit where every other lit thing draws a crisp stroke over a blurred copy
  of itself. It has a bloom pass now, the same two-pass trick the buildings use.

The rest:

- **Panels are scanlined.** The map runs through `RetroShader`, which scanlines
  the whole scene; the chrome did not, so the panels read as flat modern
  surfaces bolted onto a city that visibly lives on a cathode-ray tube. Kept
  very low contrast — at any strength you actually notice, it stops being
  texture and starts being stripes.
- **Buttons answer the cursor.** A `ButtonStyle` cannot hold `@State`, so the
  hover lives in a small view of its own; a neon sign that does not respond
  reads as a picture of a control.
- **A sun bleeds up out of the dashboard.** The map parks a sun in world space
  below its own bottom edge, and the dashboard sits exactly there on screen, so
  a warm glow along its top edge reads as that sun continuing behind the chrome
  rather than the city ending at a hard line.
- **Stat tiles have a minimum width.** Adding the Demand panel squeezed them,
  and because their label and value must not wrap they truncated instead —
  "POPULA…", "$1,48…". A readout that hides its own number is worse than no
  readout.

### Phase 6: the verbs were in the readout strip

Reported from play: *"the bottom left buttons are taking up way too much
space and making the playable screen smaller."*

Measured on `retro-live` at 1400×760 before touching anything:

| | height | share |
|---|---|---|
| tool rail | 40 pt | 5% |
| **map** | **422 pt** | **56%** |
| dashboard | 298 pt | 39% |

So the chrome held **44% of the window**, and it was one panel's fault.
`dashboard` is an `HStack` of panels, which makes it as tall as its tallest
child — and that child was a Simulation panel holding Play, Speed, the View
picker and City Hall, standing 285 points against about 100 for every other
panel in the row. The four readouts beside it were stretched to a height none
of them wanted and sat in whitespace.

**And phase 3's own rule had already said not to do this.** `toolRail`'s doc
comment reads *"Everything you do, above the map… they are different kinds of
thing — one is a verb, the other is the city answering back — so they get
different edges of the screen."* Play, Speed, View and City Hall are all
verbs. The rule was written, and then the controls were put on the wrong side
of it one at a time, each for a locally good reason — the speed control
because it belongs next to Play, City Hall because it had to escape the menu
bar, the View picker because it was there first.

Moving them up gives the map back **130 points — 31% more city** — and the
readout strip is now as tall as a stat tile, which is a height that stops
growing:

| | before | after |
|---|---|---|
| tool rail | 40 pt | 84 pt |
| **map** | 422 pt | **552 pt** |
| dashboard | 298 pt | 125 pt |
| chrome | 44% | **27%** |

**What it really changes is what the next overlay costs.** Every overlay added
used to wrap the View picker onto another row inside a panel, which made the
whole dashboard taller and took that height out of the map, permanently. On a
full-width rail the same picker is one line with room to spare, and the next
one widens a rail rather than shortening the city.

#### The narrow window is where rows go wrong, and nothing rendered one

Every overflow this project has shipped looked fine at the width it happened
to be rendered at — the tool row that clipped its locked tools, the Alerts
panel truncated to "Next: Police Stati…", the stat tiles that came out
"POPULA…". There was no render anywhere at a squeezing width, so the one thing
that reliably breaks these rows was the one thing no picture could show.
`testRenderLiveGameViewNarrow` is that picture, and it failed on its first
run — on a bug introduced twenty minutes earlier.

**A `ViewThatFits` whose last candidate always fits makes every container
above it think it fits too.** The first version put the run controls after the
tool chips with a `Spacer` between them. At 900 points the run group held its
width, the chips were squeezed to nothing, and the chip row's own
`ViewThatFits` then picked its scrolling variant — which always "fits", and
which `ImageRenderer` cannot measure, so the most important row in the UI
rendered completely empty. That is the identical failure `ViewThatFits` was
introduced to fix, re-created by putting something greedy beside it.

The fix is that the **rail** owns the decision, with the flat chip row as the
thing being measured: one line, then two lines, then two lines with the chips
scrolling. Nesting a fallback inside a candidate hides the candidate.

The View picker steps its own wrap down the same way — thirteen chips on one
line, then seven, then five — rather than taking a fixed `perRow`. Nothing is
ever clipped, which is the property that matters: a picker missing its
right-hand half looks exactly like a picker with fewer overlays in it.

One thing that render settled rather than fixed: below roughly **640 points
tall** the whole view overflows and clips its own first row, because the map
carries a `minHeight: 420` and the chrome wants about 215 on top of it. That
is a statement about the window's minimum size, not about how these rows wrap,
and it is why the narrow render is 1000×700.

## Making it a city you manage (in progress)

The design playtest says the game is in good shape: a 33x population spread
between strategies, real tradeoffs, reachable bankruptcy. It measures outcomes
at the *end* of a run, so it cannot see what a play session makes obvious — the
city reaches 90% of its final population by **tick 7** and 100% by **tick 16**,
then sits still for the remaining 1,484. That is a puzzle you solve once, not a
city you manage.

### Phase 1 (done): where the stillness actually is

Before adding pressure, `PlateauDiagnosticTests` asks what is *different* about
a city at tick 20, 200 and 1500. Full profile, 64×64:

| tick | pop | density | pollution | congestion | land value | damaged | demand R |
|---|---|---|---|---|---|---|---|
| 20 | 3384 | 1866 | 0.509 | 0.129 | 0.596 | 19 | −0.33 |
| 200 | 3340 | 1793 | 0.492 | 0.129 | 0.601 | 80 | −0.50 |
| 1500 | 3320 | 1767 | 0.486 | 0.120 | 0.604 | 81 | −0.55 |

Post-plateau spread across 1,450 ticks: **population 72, pollution 0.016,
congestion 0.011, land value 0.006**. The city is in a near-perfect steady
state, and retains 98% of peak population with no player input at all.

**Three findings that change the plan:**

- **Pollution, traffic and crime cannot cause decline — only stall growth.**
  Land value is checked as `bestLandValue >= requiredLandValue(toReach:
  nextLevel)`, a guard on the *next* level. A tier-5 tower is already at max
  density, so that check never runs again: you can ruin a district completely
  and nothing moves out. Tax is the exception, because it works through
  city-wide demand, which *is* bidirectional — which is exactly why tax is the
  one lever that already feels like management.
- **Demand is drifting toward abandonment and never arrives.** Residential
  demand falls steadily from −0.22 to −0.55 over the run, and
  `abandonmentDemand` is −0.75. The mechanism that would empty an oversupplied
  city is real, wired up, and permanently just out of reach.
- **About 17% of the city is rubble at all times, and it does not matter.**
  Damaged lots climb from 6 to ~80 of roughly 460 and stabilise there — the
  equilibrium between hazard strikes and `unassistedRepairChancePerTick`. A
  sixth of the city is permanently broken, nothing gets worse, and the player
  has no reason to notice.

The tripwire this leaves behind asserts that an unattended city retains >90% of
peak population — that is, it asserts the *current* behaviour so it fails the
moment decline lands. It is meant to be updated, not deleted.

### Phase 2 (done): desirability drives decline

Growth was gated by `bestLandValue >= requiredLandValue(toReach: nextLevel)` — a
guard on the level a lot is *reaching*. Nothing ever asked whether it could
still support the level it *had*. `CitySimulator.sustainableDensity` reads that
same table downward, and a lot above it sheds one level at a time at
`declineChancePerTick`.

Two decisions:

- **Hysteresis.** The threshold to *keep* a level sits `declineMargin` (0.05)
  below the threshold to *reach* it. Without it growth and decline read the
  same number and a lot on a boundary flickers between them forever. It caught
  the author immediately: a unit test asserting `sustainableDensity(0.6) == 3`
  failed, and the code was right — 0.6 is exactly the boundary for level 4.
- **Utilities now cause decline too, reversing a prior decision.** This file's
  own comment used to say "losing water later doesn't cause decay, exactly like
  insufficient land value doesn't", and its reasoning was consistency with the
  land-value gate. Once that gate became bidirectional the same argument
  required utilities to follow, or the rule would have been arbitrary.

**Measured: neglect now costs something.** Build a city, demolish every power
plant, walk away — 3,348 → 3,308 after ten ticks (−1%) → 2,896 after 120
(−14%). That is the recoverable shape: time to notice, and decline stops the
moment the ground can support the density again.

**And an expectation that was wrong, which is the useful part.** Phase 1 left a
tripwire asserting an unattended city retains >90% of peak, on the reasoning
that it would fail the moment decline landed. It did not fail: retention moved
only 98% → 95%, and post-plateau population spread 72 → 200.

That is correct behaviour, not a bug. Decline fires when a lot's *surroundings*
degrade, and in a city nothing is changing, they do not. Phase 2 gives the city
consequences; it does not give it weather. The stillness the diagnostic found is
not fixed by making decline possible — it needs something that changes the
surroundings over time, which is exactly what demand cycles (phase 5) and
maintenance decay (phase 6) are for. Worth remembering before assuming a later
phase has failed because the headline number barely moved.

### Phase 3 (done): oversupply empties the worst lots first

Abandonment read `map.cityDemand.value(for:)` — one number for the whole city —
so over-zoning housing emptied every residential lot equally, the waterfront
tower and the lot wedged between two factories alike. There was no such thing
as a bad neighbourhood: the city was uniformly in demand or uniformly not.

`localDemand(cityDemand:landValue:)` shifts that number by the lot's own
desirability, so marginal lots give way while desirable ones hold.

**Scoped to abandonment, not to growth**, and the first attempt got this wrong.
Applying the local offset to the shared `demand` variable also moved the growth
*probability*, which let a prime lot grow in a city at demand −1 — and demand
−1 has to keep meaning "nothing grows anywhere". Two existing tests caught it
immediately. Desirability decides *which* lots give way under oversupply; it
does not decide whether the city wants more.

It also connects a finding to a consequence. Phase 1 measured residential demand
drifting to −0.55 against a −0.75 threshold and never arriving; with a local
offset the worst lots cross it while the city average does not, so that drift
finally does something.

**Measured**, on a deliberately over-zoned city (4 residential : 1 commercial :
1 industrial) after 200 ticks: **mean density 0.88 in the least desirable
quarter of lots against 3.88 in the most desirable**. The bad neighbourhoods
emptied; the good ones held near maximum.

One thing worth recording about the fixture. The obvious test was an
all-residential city, and it measured nothing: a city with *no* jobs does not
get oversupplied, it dies — demand pins at the floor and every lot empties
regardless of desirability. That is a collapse, not the uneven decline this
phase is about, and the two are easy to confuse from a population number alone.

### Phase 4 (done): growth takes time

A zoned lot used to go from bare ground to a tower in five ticks — one level
per tick, the moment each gate opened. That is most of why phase 1 measured a
city reaching 90% of its peak population by **tick 7**: the map was not a city
being managed, it was a puzzle that solved itself the instant you finished
zoning.

`Tile.constructionRemaining` puts the work back in. A lot that clears every
growth gate is now *approved* rather than built: it records
`CitySimulator.constructionTicks(toReach:)` ticks of work and the level arrives
when the work does.

```
constructionTicks(toReach: level) = baseConstructionTicks * level   // 8 * level
```

**Scaled by level, not flat.** A shopfront going up is not the same job as a
tower, and a flat cost would make the top tiers — the ones a player is
deliberately steering toward — the cheapest part of the climb in wall-clock
terms. As it stands one lot takes 8 ticks for its first level and 40 for its
fifth, 125 ticks including approvals to climb from nothing to maximum, and a
whole 24×24 city settles in about **160 ticks** rather than sixteen.

Two placements in `advance` matter:

- The construction block sits **after** the damage branch, so a burnt-out block
  stops work until it is repaired rather than quietly continuing to rise.
- Losing road access **clears** `constructionRemaining` along with a level. A
  site nobody can reach is not a site under construction.

It rides in `CitySave` as an `Optional` via `decodeIfPresent`, so saves written
before this still load.

#### The scaffold, and where it goes

Construction is only a mechanic if you can see it; otherwise the player's
feedback for zoning is "nothing happened for a while", which is
indistinguishable from "this lot cannot grow" — the thing the utility badge
exists to say. `IsoTileRenderer.syncConstructionSite` draws a faint amber
wireframe of the volume that is coming, with a bright lit deck that climbs it
as the work is done.

**It spans the current roofline to the target one, not the ground to the
target.** The first version started at ground level, and the city render showed
why that is wrong: on a lot that already holds a tier-3 building the deck spent
most of the build *inside* the building, invisible, while the cap ring floated
unattached in the sky above it. Growth adds storeys to what is there.

It is also the one decoration whose appearance changes every single tick, so it
is cached on the *target* and only the deck's `position` moves — rebuilding it
the way the damage badge is rebuilt would put the per-tick shape-node churn
recorded above as "why the map blinked" back on the busiest lots in the city.

#### What it did to the test suite, and what that was worth

Thirty-eight tests failed, essentially all of them fixtures that ticked a fixed
number of times and asserted on the result. Almost none were wrong about the
game; they were written when a level was free. Three helpers in
`DeterministicRNGs.swift` replaced the guessed numbers:

- `advanceOneLevel` / `advanceThroughConstruction` — the *exact* ticks one
  level takes, at the map and the controller layer. Exact rather than generous
  on purpose: most of these fixtures use `AlwaysZeroRNG`, which passes every
  probability gate, so "plenty of ticks" would not settle at one level, it
  would keep climbing, and a test asserting a single step would silently become
  a test asserting five.
- `advanceToTheBrinkOfCompletion` — every tick but the last, so the money tests
  can still snapshot the treasury and then measure the single tick on which the
  building completes and is first taxed.
- `ticksToBuild(toLevel:)` and `advanceUntilSettled` — for the fixtures whose
  subject is what happens *after* a city settles. The first is arithmetic; the
  second is not, because a whole city staggers its lots behind demand, land
  value and capacity, so where it settles is emergent. `PlaytestHarness`'s quick
  profile went from **80 ticks to 320** for the same reason: at 80 every
  scenario was quietly measuring a half-built city.

Two of the failures were worth more than the fix.

**Bulldozing the power plants is not "losing power".**
`testLosingPowerMakesACityDecline` demolished every plant and measured a 3%
loss, which reads exactly like a broken decline mechanic. A power plant carries
`LandValue.powerPlantPenaltyStrength` (0.5) over a radius of 8, so on a 24×24
map demolishing them lifts a land-value penalty across most of the city at the
same instant it cuts the power, and every lot that penalty had capped was free
to climb. Defunding (`setFundingLevel(0, for: .powerPlant)`) is the clean
instrument: the grid drops, the buildings stay, nothing else moves.

**Population is the wrong readout for a utility.** With the confound removed the
number did not budge — because population counts residents only, and the
settled quick city keeps its density where the *jobs* are: sixteen industrial
lots at density 4 against six residential. Cutting the power costs the city
**12% of its total built density** while moving population by 3%. Measured on
built stock the mechanic was working correctly the whole time; measured on
population it looked dead. Same lesson as the re-tune above, third occurrence:
when a measurement changes, check whether the thing moved or the yardstick did.

**And one tripwire came due.** `testWhatChangesAfterThePlateau` asserted
`retained > 0.9` — that an unattended city never declines — written so it would
fail the moment decline landed. It has: the same city now retains **89%** of its
peak. It is rewritten rather than deleted, and it is now two-sided (`< 0.98`
and `> 0.6`), because both ends matter. A city that never slips gives the
player no reason to stay; a city that collapses while nobody is looking is a
punishment, not a game.

### Phase 5 (done): the region has weather

Phase 2 gave neglect consequences and the headline number barely moved, and
the note written then said exactly why: *"Phase 2 gives the city consequences;
it does not give it weather."* `Demand` was a closed loop — the city's own
residents against the city's own jobs, plus the tax rate — and a closed loop
settles. Post-plateau, residential demand moved 0.05 across fourteen hundred
ticks.

`RegionalEconomy` is the open term. The region outside the city booms and busts
on its own, pushing all three demands around independently of anything the
player does. In a boom there is somewhere new to grow; in a slump the marginal
lots — the ones `localDemand` already sorts to the bottom — cross
`abandonmentDemand` and empty.

**It is a clock, not a dice roll**, for three separate reasons, each of which
would have been enough on its own:

- A player can only steer against pressure they can *read*. A walk that
  re-rolls every tick is noise, and noise is something you endure rather than
  plan against.
- The playtest harness needs a city reproducible tick for tick. Drawing from
  the simulation RNG would put every balance measurement at the mercy of how
  many other rolls happened first that tick.
- `AlwaysZeroRNG` passes every probability gate, and most fixtures in this
  project use it. A random cycle would have pinned at one extreme forever,
  turning every test city into a permanent depression.

So it is two sine waves of co-prime period per sector, summed. One sine is a
metronome whose half-period a player learns; two that beat against each other
give booms of differing height and spacing that never repeat inside a session.
Each sector gets its own periods and phase, which is the part that makes this a
decision rather than a volume knob: in lockstep, a slump is just "everything is
worse for a while" and there is nothing to do but wait — decoupled, a city can
be short of jobs while housing is oversupplied, which you answer by *re-zoning*
using the RCI meter you already have.

`amplitude` is 0.25, sized between the two numbers it has to sit among. A
settled city already runs near demand −0.5 and `abandonmentDemand` is −0.75, so
a slump of this depth carries the average to the line and the worst quarter of
lots past it. And it stays below `taxDemandSensitivity`'s 0.5, so the player's
own lever remains the stronger one: the region can make a bad tax rate hurt, it
cannot overrule a good one.

#### The cycle has to be long relative to how long building takes

The first version used periods of 149–211 ticks, and measuring it found
something worth keeping. **The region made every city permanently poorer**, not
more volatile: the same scenario ran at net +6.6/tick and 390 population with
the weather off, and −1.9/tick and 349 with it on.

The cause is an interaction with phase 4. Construction takes 8 to 40 ticks per
level, 125 from bare ground to maximum — while decline, once a lot is above
what its surroundings sustain, starts immediately. So a boom shorter than the
construction it invites cannot be captured: the city is still building when the
upswing passes, and then sheds what it did build on the way down. Against flat
upkeep, a city that oscillates below its potential is simply a poorer city. The
mechanic was a one-way tax wearing a cycle's clothes.

Periods roughly doubled — 347/139, 421/173, 293/199, all prime and pairwise
co-prime — so an upswing lasts long enough to build into. That is the general
form worth remembering: **a cycle in one system has to be long compared to the
lag in the systems that respond to it, or it only ever punishes them.**

The mood threshold needed the same treatment in miniature. At half of full
amplitude the region read boom or slump on 12% of ticks, because the mean of
three *decoupled* sectors has about a third of the variance of any one of them
— a player could finish a session having never met either. At 0.35 it is named
on roughly a quarter of ticks.

#### Measured

A settled 24×24 city, weather on, over 600 ticks: **built density ranges
191–208, an 8% swing**, with all three moods occurring. It no longer sits still.

The utility-decline measurement moved too, and got sharper:
`testLosingPowerMakesACityDecline` now runs **two identical cities and cuts the
power in one**, which is how it should always have worked. Everything else is
held fixed by construction — same spec, same seed, same tick counts, and the
region is a pure function of elapsed ticks, so the pair see the same weather.
Measured against a control the outage costs **22% of built density**, against
the 7% a single city reported when the cycle happened to be climbing underneath
it.

#### The harness holds the weather still, on purpose

`CitySpec.regionalWeather` defaults to **off**, and that is a measurement
decision rather than a convenience. This harness exists to measure the city's
own economics, and it already works to hold everything else fixed —
`roadSpacing` is chosen so every lot touches a road specifically to keep "a
measurement about economics" from becoming "a measurement about road layout."
The region is the same hazard and worse: its cycles run up to 421 ticks, which
is **longer than the whole quick profile**, so a tail mean taken with weather on
is not an average over the cycle at all, it is one arbitrary sample of it. That
is precisely how a solvent city came to report negative net revenue the instant
phase 5 landed — same city, same constants, the yardstick had started moving.
`PlateauDiagnosticTests` turns it on, because there the region is the subject.

`DemandTests` gets the same treatment through `RegionalEconomy.calm`: those
tests assert that a balanced city reads *exactly* zero, and with weather on
that becomes "zero plus wherever the cycle is," which would pin the cycle's
shape rather than the demand formula. `calm` is a region with `swing: 0` — a
real value rather than a test backdoor, and the obvious shape for a future
difficulty or sandbox setting.

#### Save compatibility, admitted rather than assumed

`CityMap` decodes through the synthesised `Codable` conformance, and that
throws on a *missing* key even where the property has a default value. So every
non-optional field ever added to `CityMap` has silently made older saves
unreadable — `pollution`, `ordinances` and `taxRate` all did, none bumped the
format version, and the failure reached the player as a raw `DecodingError`
("the data couldn't be read"). `regionalEconomy` is the fourth, and the first
to say so: `currentFormatVersion` is 2, `minimumSupportedFormatVersion` is 2,
and `CitySave.LoadError.obsoleteFormatVersion` names the problem.

Two things follow that are worth keeping:

- **The version is checked before the full decode.** `CitySaveFile.read`
  decodes a one-field `CitySaveVersion` first. Checking an already-decoded
  `CitySave` was the obvious order and was useless: a save from either side of
  a format change is exactly the save whose fields do not line up, so
  `JSONDecoder` threw first and the check that exists to produce a better
  message never ran.
- **An optional field still needs no bump.** `decodeIfPresent` handles those
  for free, which is why `peakPopulation` and `Tile.damagedBy` cost nothing.
  Prefer it wherever the field is genuinely optional. A non-optional one is a
  format break, and should be declared as such.

### Phase 6 (done): infrastructure is owned, not bought

Every piece of infrastructure in the game was a one-time purchase. You laid a
road, paid a flat `roadUpkeepPerTile` forever, and it worked identically on
tick 10,000 as on tick 1 — so the only question a mature treasury faced was
"what else can I build", never "can I still afford what I have."

`Infrastructure` wears roads, pipes and power lines out, and
`ServiceFunding.road` — public works — is the budget that holds them together.
Phase 5 gave the city weather from outside; this is entropy from inside.

**Wear is deterministic, for the same three reasons `RegionalEconomy` is**: a
player steers against a trend rather than a die, the harness needs cities
reproducible tick for tick, and `AlwaysZeroRNG` would have rotted every fixture
city's network at maximum speed. Entropy is not an event — it is what happens
when no event does.

#### Congestion is the mechanic; the base rate is just the floor

Three rates, and the relationship between them is the whole design:

| | per tick |
|---|---|
| `baseWearPerTick` | 0.002 — a quiet street, 500 ticks to ruin unmaintained |
| `congestionWearPerTick` | 0.010 — what a *saturated* road adds on top |
| `repairPerTickAtFullFunding` | 0.005 |

Full funding comfortably covers the floor and comfortably does **not** cover
congestion. So what wears a city out is its own traffic: the arterials rot and
the back streets do not, and a congested corridor has two real answers — pay
for it, or fix the congestion with a highway or a transit line. A flat decay
rate would have been one more bill with no decision attached.
`InfrastructureTests.testFundingCoversQuietRoadsAndNotBusyOnes` states exactly
that relationship, checkable without building a city.

Two consequences worth naming:

- **A worn road carries less traffic**, which makes it more congested, which
  wears it faster. That loop is deliberate, and
  `ruinedCapacityFraction` (0.4) is the floor that keeps it recoverable rather
  than terminal — the house rule phase 2 settled for this exact shape.
- **A pipe or line worn past `failureWear` (0.75) stops conducting**, and the
  gap it leaves cuts the network exactly the way a missing tile would, because
  the player's fix for both is the same. It fails *before* total ruin so the
  overlay has a warning band, rather than being an invisible cliff.

One tile carries one wear value covering the road *and* whatever is buried
under it. That is a simplification with a defensible shape — a public-works
budget resurfaces the street and replaces the main under it in the same job —
and it is why `clearBuilding` carries wear forward whenever anything buried
remains: otherwise rebuilding the road on top would be a full repair of the
main for the price of a bulldoze.

#### Measured

A control pair, the design `testLosingPowerMakesACityDecline` had to adopt:
two identical settled cities, one of which stops paying for public works, over
375 ticks.

| | density | worn | net/tick | treasury |
|---|---|---|---|---|
| funded | 208 | 0% | +56 | 15,276 |
| neglected | **124** | **100%** | **−80** | **1,972** |

Neglect is dominated on both axes — 40% less city *and* less money — which is
what makes the dial a lever rather than a tax. The standing test asserts both
halves, because either one alone would let the mechanic degenerate: without the
density gap it is free money, without the treasury gap it is a dominant
strategy.

**One honest caveat about that measurement.** The funded city reads 0% worn,
which means full funding holds everything in the quick profile — the congestion
term never bites there. That is a property of the fixture, not of the mechanic:
`CitySpec.roadSpacing` is 3 so that every lot touches a road, which spreads
traffic thin by construction. A player city with a few arterials concentrates
it. The congestion term is covered directly by
`testABusyRoadWearsFasterThanAQuietOne` instead.

#### What it turned up in the UI

- **`.school` and `.hospital` had no funding row anywhere**, and had not since
  they were added. Both carry a dial that `LandValue` and `CityHazards`
  actually read, both are documented as "heavy enough per building that
  defunding one is a real lever," and neither was reachable. A lever with no
  control on it is not a lever.
- **City Hall had no render**, which is how that survived. Phase 4 of the
  cockpit found two bugs in that panel by rendering it and the render then went
  away with the mock cockpit sheet. It is the tallest view in the app and it
  splits into two columns *by hand*, so it is exactly the layout that quietly
  stops fitting. `testRenderCityPanel` brings it back.
- The cockpit gets a **Roads meter** beside Water and Power, reading as a load
  — a full red bar means the network is falling apart — so all three point the
  same way and can be scanned without reading the labels. On the map, a worn
  road's lane line simply goes dim; brightness rather than hue, because hue is
  already saying which *kind* of road it is. The condition is quantised into
  five steps in the cache key, since wear moves by a thousandth per tick and a
  raw key would rebuild the entire street grid every second.

### Phase 7 (done): fire spreads, and the grid comes apart

`CityHazards` struck a building and stopped: one lot lost density, recorded
`damagedBy`, and the event was over inside the tick it happened. That is a
hazard doing its job, but it is not a *disaster* — a disaster has a time
dimension and a spatial one. It unfolds over several ticks, it threatens to get
worse, and it asks the player to do something now rather than eventually.

`Fire` gives the fire risk both. A strike now leaves the block alight, and a
block that is alight reaches for its neighbours. Everything the strike did
before still happens on the tick it lands — density loss, `damagedBy`, the
reported `Strike` — so this is propagation layered on that contract rather than
a replacement for it. Crime stays atomic: one mechanic at a time, and a
burglary reaching for the house next door is a different model.

**It gives the fire station a second job.** Coverage used to be pure
prevention, with nothing to say once a fire started. It now decides whether one
burning lot becomes one burnt lot or a burnt district: a covered fire goes out
three times faster and is about seven times less likely to jump. The asymmetry
is deliberate — a service that merely shortened fires would read as a smaller
number, while one that stops them *travelling* is the difference between an
incident and a disaster.

**And the player has an answer right now**: bulldozing a burning lot puts the
fire out, at the cost of the building. That is exactly the trade a firebreak
is, and it satisfies this project's standing rule that every warning the game
raises has an answer the player can act on immediately.

Two things fall out of the model for free:

- **Roads are firebreaks**, without any of this knowing what a firebreak is. A
  fire only travels to something that can burn, so a grid of streets bounds how
  far one can reach — which rewards the layout the player is already building
  for traffic reasons.
- **Services are not kindling.** Spread only reaches growable zones. A random
  roll quietly deleting the player's fire station would be a far bigger event
  than this models.

**Burnout is checked before spread, and that ordering is load-bearing twice
over.** A fire going out this tick is not also reaching for the next block —
the same "do one thing or the other, never both" exclusivity `CitySimulator`
keeps between growing and being abandoned. And it is what keeps phase 7 from
levelling the entire test suite: `AlwaysZeroRNG` passes every roll, so under it
every fire goes out immediately and never spreads, which is exactly how
fixtures behaved before this existed. `FireTests` pins that rather than
trusting it.

#### The blackout cascade

An overload used to be a flat state: the grid drops city-wide, growth stalls,
the meter turns red, and it stays exactly that bad for as long as you leave it.
Nothing got *worse*, so an overloaded city was a city with a to-do item.
`Infrastructure.overloadWearPerTick` makes the overload eat the lines carrying
it, so they fail one at a time and a grid left overloaded does not merely stay
broken — it comes apart, and the repair bill grows while you ignore it. Five
times the base wear rate: the first line goes in about a hundred ticks even at
full public-works funding.

#### Measured

`FireTests`, 25 runs of a row of eight adjacent industrial blocks with one
alight: **26 blocks lost with no fire station, 1 with one.**

`PlateauDiagnosticTests`, a settled city over 400 ticks:

| | lots in rubble | worst moment |
|---|---|---|
| with services | 19% | 4 blocks alight |
| without services | 38% | 5 blocks alight |

The 19% sits right on the ~17% standing equilibrium phase 1 recorded, so spread
did not blow up the balance — and services now halve it, where before they
barely touched it.

#### Three things worth keeping

- **A mark whose only channel is hue vanishes on anything sharing the hue.**
  The first fire was an ember-coloured glow, and the city render showed the
  problem at once: an industrial building is *already* orange, so a fire on one
  was indistinguishable from its own neon. Exactly the mistake the road button
  made going black-on-black. Fire now has a silhouette no zone has — a flame
  standing above the roofline, white-hot at the base — because height is the
  one dimension a building cannot compete on, since the plume starts where the
  building stops.
- **`Double.random(in: 0 ..< 1)` keeps only the low 53 bits** of what a
  generator hands it; it is filling a significand, not dividing a 64-bit range.
  So a test generator returning `UInt64(0.9 * Double(UInt64.max))` produces
  **0.2**, the fractional part of 0.9 × 2^11 — which looks exactly like a
  working generator rolling unluckily. `AlwaysZeroRNG` and `AlwaysMaxRNG` are
  immune by accident, sitting at the ends of the range. `ScriptedRNG` scales to
  2^53 instead.
- **Fire could not be tested with either existing generator**, and the reason
  is worth recognising in general: `spreadChancePerTick` (0.18) sits *below*
  `burnoutChancePerTick` (0.25), so "high enough not to burn out" and "low
  enough to spread" do not overlap. One generator passing every roll burns out
  on tick one; one failing every roll burns forever. Both report "fire does not
  spread" about working code. A scripted sequence is the only thing that
  separates a chain of rolls against *different* chances.

#### And the bond scenario, finally measured properly

`testACityThatBorrowsToItsCapCanStillPayTheInterest` asserted that an indebted
city's net revenue was simply positive, which quietly made it a test of the
quick profile's whole economy — and that economy sits close enough to
break-even (tax revenue ~1,010 against ~990 of upkeep and civic services) that
any change anywhere flips the sign. It did so twice, in phases 5 and 7, both
times about mechanics with nothing to do with debt, while interest stayed a
flat 37/tick, under 4% of revenue.

It now runs a control pair differing only in whether the bond is taken. The
property the 8x rate cut restored is that the *whole* cost of borrowing is the
interest — that the debt does not feed back into the tax base servicing it —
and measured that way it is exact: **borrowing to the cap costs 37/tick against
37 of interest.** That the quick profile is structurally marginal is a real
finding, and it belongs to the rebalance.

## How far a service reaches, and a quiet first season

Both reported from play, and the second one turned out to be structural
rather than a number needing a nudge.

### Nothing burns in the first ninety days

*"Perhaps we need to make it so there's no fires for at least the first few
minutes — a player is probably building all new buildings and might not have
made a fire station yet."*

That is this project's own standing rule, unapplied: **every warning the game
raises has to have an answer the player can act on right now.** It is why the
starter utilities exist — a new city used to show "no water" badges while the
tower was still locked at 100 residents. A fire on day three is the same bug
wearing a different coat: the answer to a fire is a fire station, and a city
with no residents has neither built one nor unlocked it.

`CityHazards.gracePeriodDays` is 90. Days rather than an unlock check, for two
reasons — a police or fire station unlocks at 40 residents, which a zoned city
passes in a couple of weeks, so gating on the unlock alone would end the grace
almost immediately and leave the reported problem exactly where it was; and a
span of days is something the calendar can *say*, now that the city is founded
in spring 1985 and dated. Three months is roughly three minutes at
`SimulationSpeed.normal`, and comfortably shorter than the ~160 days a city
takes to settle, so it quietens the opening rather than removing hazards from
the early game.

Fire *spread* is not separately gated: nothing can be alight to spread from.

### The radius was one number doing two jobs

*"The police and fire radius is a big problem in the gameplay."* Measured
before touching it, which is what turned a balance complaint into a structural
one.

Protection was expressed as a threshold on a land-value gradient:

```swift
LandValue.falloffValue(nearestZone: service,
                       falloffDistance: LandValue.serviceFalloffDistance,  // 12
                       at: cell, in: map, using: distances) >= 0.3
```

Six copies of that — hazards, fire containment, the repair gate, schooling,
hospital range, and a sixth inline in `CityHazards.apply`, in the same file as
the doc comment explaining that a second copy of `isExposed` would drift. Four
separately-named `0.3` constants, all equal by coincidence of everyone picking
0.3, all resolving to the same thing: **a protected radius of 8 tiles.**

Three problems fell out of that arithmetic, none of them visible as a number
anyone had written down:

- **A 64×64 map wanted 28 police stations and 28 fire stations** at perfect
  packing, each a 2×2 building. That is not a decision, it is an obligation.
- **Funding was a cliff, not a dial.** It multiplied into the value before the
  comparison, so 1.0 → 0.5 took the radius from 8 to 4 — a 72% loss of *area*
  — and any funding at or below 0.3 protected nothing anywhere, including the
  station's own lot.
- **The overlay overstated coverage by half.** The Crime and Fire Risk views
  painted their ground from the same falloff, which runs to 12 — so the outer
  third of the glow a player uses to site the next station was promising cover
  that was not there.

And underneath all three: `serviceFalloffDistance` is how far a station
projects **land value**, an amenity felt as desirability. It was also, by
accident, how far the station **protects**. There was no way to make a police
station cover more ground without making it a bigger amenity, and no way to
tune desirability without silently moving every hazard in the game. That is
exactly the separation `Transit` already had to draw between a catchment and a
land-value falloff — *"tying them would make a balance change to one a silent
change to the other"* — never carried back here.

`ServiceCoverage` is reach as a real distance in tiles, separate from land
value, funding-scaled linearly. One concept, one knob:

| | before | after |
|---|---|---|
| protected radius | 8 tiles | **14** |
| tiles one station covers | 145 | **421** |
| stations a 64×64 map wants | 28 of each | **~10 of each** |
| 40×40 | 11 | ~4 |
| half funding | radius 4 (area −72%) | radius 7 (area −75%… of a much larger circle, and linear) |
| funding ≤ 0.3 | nothing protected at all | proportionally smaller, down to nothing at zero |

`ServiceCoverageTests` pins the geometry, prints the station count into the
build log, and asserts the two properties that were previously accidents:
that `strength` is positive **exactly** where `serves` is true — so the
overlay can never again depict a catchment it does not have — and that reach
and the land-value falloff are not the same number.

Two side effects worth naming, both improvements the refactor made structural
rather than documented:

- **The repair invariant is no longer a comment.** It used to read
  "`repairCoverageThreshold` is deliberately the same number as
  `CityHazards.Risk.coverageThreshold`", which is an instruction to a future
  reader to keep two constants equal. Repair now asks `ServiceCoverage` the
  same question the hazard asked, so the condition *is* "fix the gap that
  caused this".
- **The inspector's pills stopped thresholding a gradient.** They tested
  `report.policeCoverage >= CityHazards.crime.coverageThreshold`, borrowing a
  hazard constant as a display cutoff. Under the new model that would have lit
  "Police" for the inner seven-tenths of a catchment and left the rest dark.
  `TileReport` carries the boolean now; a reach is a yes/no, and the gradient
  is for shading a map.

#### What it did to the rest of the balance

Every number went **up**, because coverage reaching further means more lots
clear the school gate and reach the top tier. On the quick profile a settled
city went from 388 residents to 456, and transit ridership rose across the
board with it.

One test failed on that, and it is worth recording because the answer was
neither "the change is wrong" nor "relax the assertion".
`testTransitEarnsItsKeepWhereTheCommuteIsLong` asserts a tram carries more
than a bus over the same stations, and at 24×24 that flipped: 120 riders
against 128, where before it read 88 against 80.

Re-measured at the profile the claim was originally made on, it is untouched:

| 64×64, 1500 days | riders/day | congestion | pop |
|---|---|---|---|
| idle stops | 0 | 0.211 | 3,012 |
| bus | 1,912 | 0.139 | 3,528 |
| **tram** | **3,464** | 0.117 | 3,576 |
| subway | 6,352 | 0.038 | 4,056 |

A 1.8× margin, essentially the 3,444 against 1,904 recorded when the tram
landed. So the property is real and the quick profile simply cannot see it:
three lines over a 24×24 town is not a network, and the tram's quarter-lane
costs about as much as its speed buys back at that size. It is also a tool
that city could not have built — a tram stop unlocks at 450 residents and the
quick profile settles around 450.

That is the **same** finding the rail scenario already recorded: *when a
scenario measures a tool the city could not have built, the scenario is the
thing that is wrong.* The tram/bus ordering is now asserted only under
`PLAYTEST_FULL`, where it is a measurement rather than a coin flip; the
subway/bus ordering, which holds at both sizes, still runs with the suite.

Worth keeping generally, because it is the third time this has come up in a
different costume: **a bound that holds by a few percent on numbers under a
hundred is not a regression test, it is a coin toss with a comment on it.**

#### And one fixture that had gone degenerate

`testTheReportedStatusPredictsWhatTheNextTickActuallyDoes` grew a city for 120
ticks and checked once, needing at least one lot that was merely *waiting on
demand*. With services reaching further more lots could top out, so a settled
city became all `atMaximumDensity` and the positive half of the agreement had
nothing left to check — it failed on its own precondition, which is the good
version of this failure. It samples across the city's whole climb now, since
where a city happens to be in its growth is not something that test should
depend on.

Every hazard fixture also had to be aged past the grace period
(`CityMap.agedPastTheHazardGracePeriod()`), which moves the clock rather than
ticking the simulation — ticking to day 90 would grow, decline and possibly
burn the very city the test is about to assert on.


## The inspector (in progress)

The city runs about ten systems that interact, and the player's only window
into any of them is a whole-map overlay showing one channel at a time.
Diagnosing one block means visiting five overlays and remembering what each
looked like there — and several things have **no overlay at all**: school and
hospital coverage, crime and fire exposure, how worn the roads are, what
density a lot could actually sustain. So the honest answer to "why is this
block stuck at 3?" was that you could not find out.

**It is a player tool, not a debug view.** That decides the vocabulary: the
headline names a *fix* rather than a mechanism, ratings replace raw numbers
wherever a number means nothing to a player, and engineer-only fields (tick
counts, wear fractions) do not ship. The words live in `Rendering/` regardless,
since `Simulation/` may import Foundation only — the same reason
`RenderPalette.displayName(for:)` is not on `ZoneType`.

### Phase 1 (done): the gate chain, made askable

`CitySimulator.advance` decided a lot's fate by falling through a ranked chain
of gates — access, fire, damage, construction, oversupply, having outgrown its
surroundings, then land value, water, power and a school for the *next* level.
That chain is the complete answer to "why is this block stuck", and it existed
only as control flow. Nothing could ask it a question; it could only be run.

`LotStatus` is that chain as a value, and `advance` is now written in terms of
it rather than the other way round. **That direction is the whole point.** An
inspector with its own copy of "is it missing water?" drifts from the rules the
first time either changes, and this project has been bitten by exactly that
three times: a streetscape painting its own flat tiles while the renderer had
moved on, an overlay render carrying a second stale switch, and hazard damage
computed in two places.

The standing guard is
`TileReportTests.testTheReportedStatusPredictsWhatTheNextTickActuallyDoes`:
grow a real city, then check every lot. Where the report says blocked, one tick
must not move it; where it says the lot is only waiting on demand, a generator
that passes every roll must. It currently compares 48 blocked lots against
what actually happens to them.

Three things worth recording from the extraction:

- **`.burning` and `.damaged` are one state to the simulation and two
  different problems to the player.** A block alight is always also damaged, so
  separating them changed nothing about `advance` — and the first version of
  the switch accidentally let a burning block skip its repair roll, which is a
  balance change smuggled inside a refactor. They share a branch deliberately,
  with a comment saying why.
- **`.readyToGrow` had to exist.** Without a case meaning "nothing is wrong,
  the city just doesn't want more yet", every healthy lot would show an
  inspector unable to name a problem it did not have.
- **The report describes the building, not the cell under the pointer.**
  Hovering the far corner of a 2×2 tower is still hovering the tower, and the
  simulation already decides growth, coverage and hazards per footprint.

One fixture lesson, which is the same one the phase-5 power measurement taught:
a test for "this lot's land value is too low" added a school to satisfy the
gate *behind* it, and a school is itself an amenity — so it pushed land value
over the very bar the test needed it to fall short of. When a fixture stops
measuring what it claims, check whether it moved the thing or the yardstick.

### Phase 2 (done): the panel

One headline, one line of advice, then supporting evidence in two groups.
Structured as a *diagnosis* rather than a dump, because listing a dozen
available numbers fails the way `NeonStyle.minimumDetailSize` describes for
art: past a certain density more marks stop adding information and start
averaging into noise. A player who reads only the first line has still been
told the useful thing.

`InspectorText` holds every word. Two rules run through it — the headline names
a *fix* rather than a mechanism ("Needs water", then "put a tower or a pump
within a few tiles"), and continuous fields become ratings, since a player
reasons in levels and residents but "desirability 0.62" is a debug readout.

`RetroUIContactSheetTests.testRenderInspectorStates` renders **every state at
once**, which is the only arrangement that can answer the question the panel
exists to answer: whether "on fire" and "not desirable enough" read differently
at a glance. It found four real problems immediately.

- **Bare ground introduced itself as "BULLDOZE".**
  `RenderPalette.displayName` is the *toolbar's* name for a zone, and the
  toolbar's name for `.empty` is the tool that produces it.
- **Plain road frontage read as "Prime".** Even bands over 0…1 put the
  baseline — a lot with a road and nothing else, 0.75 — in the top word,
  congratulating the player on a lot that cannot reach the top tier. The bands
  are cut at `CitySimulator.requiredLandValue` instead, so each word names the
  level that land actually supports.
- **"Unzoned land" was drawn in `.empty`'s colour**, which is the near-black
  night the whole map sits on. Invisible as text — the same trap that once drew
  the Road button black on black, and the second time `.empty`'s *ground*
  colour has been wrong as a *foreground* colour.
- **The "fully served" fixture had no utilities.** It placed a tower and a
  generator a few tiles away and trusted `Water.directSupplyRadius` to bridge
  the gap; both pills rendered dark, so the one panel in the sheet meant to
  show what "covered" looks like was showing the opposite. Exactly the trap the
  overlay render fell into with a fixture that had no pipes in it, one phase
  earlier.

A lot that does not grow shows no headline: its headline is its own name, which
the title line has already said, and a panel that repeats itself teaches a
player to stop reading it. Exposure warnings ("no fire cover") sit at the
bottom rather than in the headline, because an uncovered block is not broken —
it is at risk, and promoting that would bury the thing that actually is wrong.

### Phase 3 (done): hover, and the answer the router was throwing away

The inspector rides the placement preview's existing mouse tracking, which
already computes the grid cell it needs. `GameController.inspect(at:)` no-ops
unless the pointer has crossed onto a *different* lot, and the report is cached
on the controller rather than derived in the view — `TileReport.make` builds a
whole-map distance field when it is not handed one, and a SwiftUI body calling
it directly would pay for that on every mouse move and on every published
change from anywhere else. It is rebuilt exactly twice: when the pointer moves
to another lot, and when the city ticks under a stationary pointer. A panel
showing last tick's answer is worse than one showing none, because it looks
live.

**`mouseExited` had never once run.** `GameSKView`'s tracking area asked for
`.mouseMoved` and not `.mouseEnteredAndExited`, and AppKit only delivers the
events a tracking area asks for — so the "cursor left the grid" cleanup was
dead code and the placement preview stayed stuck wherever the cursor last was.
Tolerable for an outline; not for a panel that would sit there describing a lot
the player is no longer pointing at.

#### "Can the people who live here reach a job?"

`Traffic.computeLoad` routes every home to the nearest job *with room left*,
and the line that decides whether one was found ends `else { continue } // no
reachable job has room`. The answer was computed every tick and discarded. It
is now kept on `TrafficLoad`, and it is the one fact about a residential lot
that no overlay shows and nothing else implies — a block can have water, power,
every service and prime land and still be full of people with nowhere to work.

Two details worth keeping:

- **It records the successes, not the failures.** `computeLoad` returns early
  when a city has no job sites at all, before any home is considered, so a set
  of failures would come back empty and report full employment in a city that
  has none. Recording employment and marking that routing *ran* makes "nobody
  found work" distinguishable from "nobody has looked yet".
- **It is not the headline.** Unemployment does not stop a lot growing — it
  feeds `Demand`, which is city-wide — so putting it where the blocking gate
  goes would claim a causation the simulation does not have. It sits with the
  other warnings.

The field is `Optional`, which is what keeps it off
`CitySave.minimumSupportedFormatVersion`: `decodeIfPresent` handles it for
free, and "this map has not routed yet" is a real state rather than a
compatibility dodge.

#### One thing only the live render could catch

The panel floats over the map, and `RetroPanel` fills at 55% opacity — right
for a panel on the dashboard's own background, wrong for one over a lit neon
city, which showed straight through a paragraph of 10-point text. It looked
perfect in the component sheet's plain surroundings. The inspector carries its
own opaque ground and a drop shadow now, because legibility over arbitrary
content is a property of *this* panel rather than of where it happens to be
placed.

### Crime and fire risk get their own maps

Police and fire coverage were the last mechanics with no way to see them at
all, and the genre's name for the police one is the tell: a player does not
especially want a map of their stations, they want a map of the *problem*. So
`OverlayMode.police` is called **Crime** and `.fire` is **Fire Risk**.

**They answer two questions at once, which is why they are two colours.** The
ground carries how strongly the service reaches each tile — a gradient, so the
catchment's edge is visible and the player can see where the next station
should go. The buildings carry whether they are actually in danger, which is a
*different set*: a factory outside every police catchment is perfectly safe,
because crime does not threaten industry.

The first version shared one colour for both, and the render showed the cost
immediately — those safe factories were tinted to near-black along with the
uncovered ground they stood on, so the map claimed half the city was at risk
when it was not. `OverlayPaint` now carries a separate `buildingColor`, which
defaults to the ground colour for water and power, where the two genuinely are
answering the same yes/no.

Lit means fine and dark means trouble, the same way round as water and power —
one rule across all four maps, rather than a crime map that runs hot where the
others run cold.

`CityHazards.isExposed` is the single definition of "can a hazard strike here",
called by the overlay, the inspector, and nothing else re-deriving it.
`TileReportTests.testNothingCalledSafeIsEverActuallyStruck` grows a city, fires
every hazard that can fire, and checks that nothing the overlay called safe was
hit — because an overlay promising protection the simulation does not honour is
worse than no overlay.

The overlay picker is driven by `OverlayMode.allCases`, so adding the two cases
was the whole UI change; and the render picks them up automatically now that
both it and `GameScene` share `IsoTileRenderer.paint`.

## The scene playtest: play the game, and check the picture kept up

Three bugs in a row came back from play with one shape — the simulation right
and the scene quietly disagreeing. A pipe that existed and was not drawn, a
building that grew and was not redrawn, cars driving around a stopped city. Not
one could have been caught by anything in the suite, and **not by accident**:
every render test takes a still picture of a freshly built scene, and all three
bugs need *change over time* to exist at all.

`ScenePlaytest` drives a real `GameScene` through real actions — place, drag,
lay pipe, change view, pause, tick — and after each one asks whether the scene
still agrees with the map. It goes in below the mouse handlers, at
`GameScene.place(at:)`: every bug so far has lived there or deeper, and
synthesising `NSEvent`s would mostly re-test coordinate maths that is already
pinned.

### The yardstick is a second scene, not a second opinion

`SceneAgreement` does not describe what a lot *should* draw. It builds a
throwaway scene from the same city and asks whether the incrementally-updated
one matches it.

That distinction is the whole design. This project has been bitten three times
by a yardstick that reimplemented the thing it measured and so agreed with
itself forever — a streetscape painting its own flat tiles, an overlay render
carrying its own stale switch, hazard damage computed twice. A written-down
table of what each zone draws would have been the fourth.

It compares two things per tile: **how many** of each decoration (which catches
one missing or duplicated — a pipe segment under a covered cell) and **the
cache key each was built from** (which catches one that is merely *stale*,
since a building drawn at the wrong density is still exactly one building). The
key is what the renderer itself recorded about the state it drew, so comparing
two of them compares two runs of the same code.

Being honest about the limit: this cannot catch a renderer that draws the wrong
thing *consistently*. It catches one that has fallen behind — which is every
bug play has found.

### It found three more immediately

None of them reported, all of them real:

- **`rebuildRegion` rebuilt bare nodes.** It synced the traffic and the lane
  line and nothing else, so a rebuilt tile came back with no utility warning,
  no damage marker, no scaffold, no fire — and, once overlays existed, wearing
  no overlay at all. **Placing anything stripped a nine-by-nine patch of the
  map back to a bare Normal view**, until a tick repainted it; while paused,
  never. It refreshes each rebuilt cell now, which is the whole job rather than
  two remembered pieces of it.
- **A view never cleared the layer it was not showing.** Pipes are drawn by the
  Water view and power lines by Power, and neither was ever taken away by the
  other — so Water → Power left the mains on the map underneath the lines.
  Asking for the empty set is how a layer gets cleared; skipping the call is
  how it lingers.
- **Every joint in a freshly dragged run was drawn as a dead end.** A conduit's
  mark is a statement about its *neighbours*, exactly as a road's lane line is,
  and laying one changes how the ones already down should be drawn. Nothing
  told them. `refreshRoadNeighbors` has done this for lane lines since roads
  had connectivity; the buried layers never got their version, so a dragged run
  read as a chain of disconnected stubs until a tick — and laying pipe is
  something a player does *paused*.

### And a player nobody wrote

The scripted sessions only cover what I thought to try, and every bug reported
so far has been something nobody thought to try. `RandomScenePlayer` plays a
city for as long as it is given — zoning, dragging roads, bulldozing, changing
view, laying mains, pausing, stringing lines between stations, borrowing when
the money runs out — and checks after every step.

**Plausible rather than chaotic**, deliberately. A player who clicks uniformly
at random builds a city no player would build, and the interesting
interactions — laying pipe under blocks, growing while a view is up, bulldozing
next to something — come out of *sequences that make sense*. Pure noise mostly
measures how the game handles noise. The weighting is `allCases` with the
common actions listed twice, which stays readable in a way a table of
percentages does not.

Seeded, and `ScenePlaytest.log` prints the run that produced a failure —
because "step 147 of a random walk" is otherwise a failure nobody can act on.
Same requirement `PlaytestHarness` already states for balance numbers.

**It found a fourth bug on step eight**, and a good one: picking a zone tool
while a network view is up drops that view on purpose, so the two stay mutually
exclusive — and *nothing told the scene*. `GameView` announces an overlay change
through a SwiftUI binding, but this change happens underneath it, so the map
went on painting the view the player had just left until something else
happened to refresh it.

The fix is that the scene notices for itself rather than waiting to be told:
`update` compares the view it last drew against the one that is current. The
binding stays, because it makes the change immediate — but correctness no
longer rests on it firing. This project has been caught by "the view did not
tell the scene" before, when a freshly laid pipe stayed dark because the game
starts paused.

Six seeds of three hundred steps — eighteen hundred actions — run clean after
it. Short in the normal suite, long behind `PLAYTEST_FULL`.

### And a strip I can actually look at

Every render this project had before this one is a still of a **freshly built
scene** — which is precisely the state none of these bugs can exist in. A pipe
laid but not drawn, a building grown but not redrawn, a run whose joints are
stale: all of them are facts about what happened *between two frames*, and one
frame has no way to express one.

`ScenePlaytest.capture` photographs the live scene mid-session —
`SKView.texture(from:)` on the view the session is actually running on, camera
and shader and all — and `writeFilmstrip` stacks the frames the way every other
contact sheet here is stacked. Nine of them across a session: an empty city,
the water view, a main going in, six days of growth, the same view again.

Two things it needed before it was worth reading, both obvious only once there
was a picture. The camera had to be **pulled back to fit the city**, because
`centerCameraOnMap` says nothing about zoom and most of every frame was empty
night. And the filmstrip needs a **denser fixture** than the scripted sessions
use: those ask whether the picture agrees, this one asks whether I can read it,
and that needs something on the map worth reading.

What it shows, on its first run, is the thing I have never been able to see: a
main running unbroken *through* the blocks, the corridor around it turning blue
over six days as the lots connect — and two lots quietly declining to bare
ground in the same six days for want of the water that never reached them.
Correct, all of it, and not assertable in any form I would have thought to
write.

Two false positives came first, and both were worth the trip. A one-shot
feedback flash is an animation **in flight**, not a fact about the city, so a
rebuilt scene has none by definition and it has to be excluded. And the pause
flag was *cached* on the scene and only refreshed inside `update`, so a refresh
before the first frame — which the real app never does and a harness does
constantly — built cars that had never been told the city was stopped. Reading
`isRunning` at the point of use fixed it, and "a cache that can be stale" is
the same shape as everything else on this list.

The driver pumps a frame after every action for the same reason: a scene
nothing is driving is not the scene the game runs.

### A half-drawn line stopped every drag in the game

Reported from play: *"you place a power line or pipe and it doesn't place."*

Picking a route tool on the toolbar **starts a line**, deliberately — a route
view that left you with nothing to draw would be a mode with nothing in it.
Picking a different network tool afterwards only changes the view; it says
nothing about that half-drawn line, which survives the switch on purpose
because you come back to it.

And `mouseDragged` read:

```swift
guard controller.routeDraft == nil else { return }
```

So from the moment a bus line was started, **every pipe and power-line drag in
the game silently did nothing**, until the player happened to pick a zone tool
— `selectTool` being the only thing that clears a draft. The guard is right
about the thing it was written for (a drag across a station must not add it
once per frame) and wrong about its scope: that is a fact about *the view
taking the click*, not about a draft existing somewhere.

**Only the drag was guarded, which is what made it so confusing to report.** A
single click still laid one tile, so the tool was visibly working — it just
would not paint a run. "It doesn't place" is exactly what that feels like, and
it is why the bug reads as intermittent rather than as a mode being stuck.

`dragPaints` now asks the same question `place(at:)` already asks to decide a
click is a route click, one layer up: a drag paints unless this view is the
one drawing that line.

#### And the harness could not have caught it

`ScenePlaytest` drove a drag as `for step in line { scene.place(at: step) }` —
which is what a *click* does, once per tile. That is a reasonable-looking
shortcut and it made the drag handler's own body unreachable from the harness,
so a drag that refused to paint was indistinguishable from one that painted
fine. Every scripted session and eighteen hundred random steps ran straight
past it.

The fix is the same one this file keeps arriving at from other directions:
`mouseDragged`'s body is extracted as `GameScene.dragTo(_:)` and the harness
calls *that* — the real handler rather than a paraphrase of it — with the
press and the movement told apart the way AppKit delivers them. A drag is not
a series of clicks, and the one line that made it different was the one line
nothing could reach.

Worth stating as the general form, because the harness's own doc comment
argues for going in below the mouse handlers and that argument is still right:
**"below the event" has to mean below the `NSEvent`, not below the handler.**
Anything a handler decides before it calls into shared code is logic like any
other, and needs a seam of its own.


### An overlay tints what is there; it never built anything

Reported from play: new buildings, and buildings that had grown a storey, did
not appear while a view was up — they arrived only when you flipped to Normal
and back.

`refresh` has two branches. Normal calls `tileRenderer.update`, which syncs the
ground, the light pool and the *building*. Every overlay calls `applyOverlay`,
which recolours or removes what it finds. Nothing in the second branch has ever
created a building sprite, so a lot that changed under an overlay kept whatever
it had — and returning to Normal ran `update`, which is why flipping fixed it.

**The obvious fix does not work, and why it does not is the interesting part.**
Calling `update` before `applyOverlay` would rebuild every sprite on the map
every tick, because `applyOverlay` was clearing each cache key every time it
ran. That invalidation was sound in itself — a stale key would mean returning
to Normal restored nothing — but a key cleared every tick is a key that can
never *hit*, so the caching that exists to stop the map blinking was doing
nothing at all under an overlay.

It is a **property of the view, not of a tile**, so it belongs on the view
changing: `GameScene` remembers which overlay the tiles were drawn for and
clears their keys once when it differs. `applyOverlay` removes nodes and leaves
the keys alone. In between, the keys behave normally — a lot that grows
rebuilds, a lot that does not costs a dictionary lookup — and `update` can be
called under every overlay safely.

Worth keeping as a shape: **invalidation belongs at the granularity of the
thing that changed.** Per tile per tick was the wrong axis for a fact about
which view is up, and it quietly cost both correctness (buildings never
updated) and the performance the cache was there to buy.

### Pause stops the city, not the player

Reported from play: the ambient traffic kept driving around a paused map.

`GameScene.update` returns early when paused and always has — but the cars are
`SKAction` loops, and SpriteKit runs those itself without ever going near
`update`. So the simulation stopped and the decorations carried on, which is
the same shape as `SKAction.colorize` silently doing nothing on a plain node:
**an animation that nothing in this file drives is an animation nothing in this
file can stop.**

The rule is by node name rather than by layer, and both alternatives are wrong
in an instructive way:

- **`SKScene.isPaused` takes the camera with it**, and looking around a stopped
  city is most of what pausing is *for* — the same reason `update` pans before
  it checks the pause at all.
- **Pausing `tileLayer` wholesale** is nearly right and wrong in the one place
  that matters. The placement and hazard flashes are `SKAction`s too, they fire
  in response to *clicks*, and clicking is exactly what you do while the game
  is stopped. A paused flash would never fade and never remove itself, leaving
  a coloured diamond stuck on the map.

So: things the simulation is driving stop, things answering the player do not.
Cars and flames pause; feedback flashes do not. Applied on the transition
rather than per frame (five hundred nodes once, not sixty times a second), and
again at the end of every `refresh`, because a placement rebuilds tiles *while*
paused and a car built then would otherwise drive off immediately.

### Keyboard navigation

WASD and the arrow keys pan; space pauses. `KeyboardControls` is the mapping,
split out from `GameView` so it is one table rather than a chain of comparisons
inside a view modifier — and so it can be tested, since `onKeyPress` cannot be
driven from a unit test but "does W pan north" should not need a human at a
keyboard to find out.

**Held keys are tracked and the camera integrates a velocity per frame**, which
is the difference between a camera you steer and one you nudge. Acting on the
key events directly would move once, pause for the OS key-repeat delay, then
repeat at the system rate — a stutter. Three details fall out of doing it
properly:

- **Panning runs before the pause check** in `update(_:)`. Looking around a
  stopped city is most of what pausing is *for*, and sharing the simulation's
  clock would freeze the camera exactly when a player has stopped to look at
  something.
- **The velocity is normalised**, so holding two keys does not travel 1.41x
  faster than holding one. That is the oldest bug in this genre of code and it
  is invisible until someone notices the map slides faster diagonally.
- **It scales with the camera's zoom**, so a key covers the same fraction of
  the screen however far out you are — otherwise panning crawls when zoomed
  out, which is exactly when you are trying to cross the map.

Space is a one-shot on the way down. Treating it as held would flip the
simulation on and off many times a second and leave it wherever the last repeat
landed.

Three things this needed that are easy to miss:

- **`.focusable()` is not focused.** WASD did nothing until the player clicked
  the map, and nobody discovers a keyboard control they have to earn first. The
  map takes focus on appear, and takes it back when the City Hall sheet closes.
- **A key held when focus moves away never sends its `.up`**, so the camera
  would slide forever behind an open sheet. Held keys are cleared when one
  opens.
- **Putting `.focusable()` on the map rather than the window** is what makes
  the sheet behave: a sheet takes focus, so WASD stops steering the moment a
  panel is open, with no "is a sheet up" check to forget about later.

The two new overlay buttons pushed the dashboard's Alerts panel narrow enough
to truncate its text to "Next: Police Stati…", so `RetroSegmentedPicker` wraps
at six. Every overlay added makes that row wider, and the tool rail above the
map has already learned this lesson twice: a row that grows every time a
feature lands needs a wrap in it, not a bigger window.

## Water and power, made legible (in progress)

Reported from play: *"it really is difficult to tell where you're laying
pipe/power lines and if that's going to help what is above it."* Rendering the
water overlay confirmed it — you could see which *buildings* had water, and the
pipe run itself was invisible.

The rules, for reference, because they are more forgiving than they look and
two of them are easy to confuse:

- A **source** serves everything within Manhattan distance 4 of its footprint,
  with no pipe at all — about 60 tiles. Added because playtesting found a new
  player putting a pump next to their houses and nothing happening.
- A **pipe** supplies any building orthogonally *adjacent* to it, provided that
  pipe traces back to a source through a connected run. Pipes go beside a
  block, not under it.

So there are two supply mechanisms with different shapes, and neither was
drawn. That is a lot to hold in your head about an invisible system.

### Phase 1 (done): the network reads as a network

Three things, all of which had the data already.

**Conduits are drawn as a connected run.** `syncBuriedMarker` painted one muted
disc per tile, so a ten-tile pipe read as ten faint dots.
`IsoTextureCache.conduit(isPipe:mask:live:)` reuses `lane`'s rasteriser — a
path from the tile centre to each connected neighbour, keyed on a sixteen-value
mask — because a conduit and a road are the same drawing problem one layer
apart. Sixteen masks × two kinds × live-or-dead is 64 textures against a cache
already holding about fifty, and additive blending makes a straight run
brighten where tiles meet, exactly like the street grid.

**Live and dead look different.** A conduit that does not reach a source does
nothing, and looked identical to one that does — so "did that connect?", the
only question a player is actually asking while laying pipe, had no answer on
screen. `WaterSupply.isSupplied(at:)` has known it every tick since pipes
existed and nothing drew it. Live runs glow; orphaned ones are unlit wire.

**The overlay draws the network *over* the city.** Tile nodes are depth-sorted,
so at any ordinary `zPosition` a buried conduit is hidden behind whatever
stands in front of it — which is most of a city, and which is why the pipes
were invisible even once they were bright. In its own overlay the network is a
schematic: the one thing the player came here to look at.

Three tuning notes from the render, all caught by looking:

- The first live colour was full-brightness, and additive overlap plus bloom
  saturated the run to **white** — losing the one thing the colour carried,
  which is which utility it is. Held below the ceiling, the sum lands on blue
  or yellow instead of on paper.
- `glowWidth` 5 made the run a smear that swamped the tiles either side. Same
  mistake as putting `glowWidth` on individual windows, recorded above.
- The first dead colour was 0.30 grey, which against this palette's near-black
  ground is not "unlit wire", it is nothing at all — an orphaned run you cannot
  see is the exact failure the distinction exists to fix.

And the render fixture had to grow an orphaned run, for the reason it once had
to grow pipes at all: a fixture where every conduit is live cannot show whether
a dead one is visible.

### Phase 2 (done): the network lights what it feeds

Also reported from play: *"it's tough to tell where buildings are in the
power/water overlay."* The cause was that both states **repainted** the
building — 85% toward the utility colour when supplied, 85% toward near-black
when not — and the second sank a block of flats into bare ground.

The fix is the move this project already made when the map stopped being flat
coloured tiles: **colour comes from the light a thing throws, not from
repainting it.** A building on the network keeps its form and casts a pool of
the utility's colour on its lot — the existing `syncGroundGlow` pool,
recoloured rather than removed, so it costs nothing new. One off the network
washes to `unlitBuilding` and keeps a readable silhouette.

**The blend had to go hard in both directions**, and the middle was worse than
either end. At 0.45 supplied and 0.8 unsupplied the buildings kept so much of
their own neon that the two states read as the same picture at slightly
different brightness — the overlay went from "everything is mush" to
"everything is lit" without passing through "these are obviously different". A
utility overlay asks exactly one question and Normal view is where zone
identity lives, so it can afford to spend all its colour on the answer: 0.78
and 0.92, a dark slate city with the supplied half burning.

**And the ground has three states, not two.** A source covers everything within
`Water.directSupplyRadius` with no pipe at all; a pipe covers what it runs
beside. Drawing both as one "served" colour hid the most useful thing the
overlay could say — which part of the network you did not need to build. Radius
coverage is now a soft halo around each source and pipe coverage the brighter
field, and the difference between them is the pipe you could have skipped.

One process note. Two rounds of this were spent squinting at a small crop and
reaching for the wrong conclusion — I twice "saw" buildings keeping their own
colours when the tint was in fact applying exactly as written. Printing the
actual `colorBlendFactor` and `color` off the rendered nodes settled it in one
run, and the magnified crop then showed the effect plainly. **When a render
disagrees with the code, measure the render before changing the code** — the
small crop was the unreliable instrument, not the renderer.

### And one rule nobody could have inferred

`hasSupply` checked a tile's orthogonal neighbours and never the tile itself,
so a conduit laid *under* a building supplied it only by accident: every
growable zone is 2×2, and one footprint cell is adjacent to another. It would
have failed silently on anything 1×1.

"Under" and "beside" behaving differently, for no reason a player could work
out, is the kind of rule that makes a mechanic feel arbitrary — and it is
exactly the sort of thing an unreadable overlay hides. Making the network
visible is what surfaced it. The tile now counts as well as its neighbours, in
both utilities; an orphaned conduit still supplies nothing, since the fix is
about where a *live* conduit counts.

Practically this changes almost nothing — the zones it could affect are all
2×2 — which is the point: it removes an arbitrary rule at no gameplay cost.

## Mains have an area of effect (from a SimCity 4 screenshot)

Brought back from a play session of the game this project takes its bearings
from, and it is two things wearing one coat — a mechanic and a reading.

### Laying pipe was a tracing exercise; now it is a spacing one

A main used to supply only what it orthogonally touched, so covering a city
meant following every street past every building and the only skill involved
was not missing one. `Water.pipeSupplyRadius` (3) makes it an area: run trunk
mains far enough apart that their bands meet, and the decision becomes *where
the trunks go* rather than whether you remembered a lot. Seven tiles across, so
on this lot grid a main covers one street either side.

One less than `directSupplyRadius`, so a tower standing on its own is still
worth slightly more than a length of pipe — a source is a bigger thing than a
main. `PowerGrid` matches it exactly, for the reason it matches everything
else: two utilities behaving differently for no reason a player could work out
is a rule this project has already had to go back and delete.

It also quietly deletes a wrinkle. `hasSupply` used to have to answer whether a
conduit laid *under* a building counted as well as one beside it — a rule
nobody could have inferred, fixed once and documented at length. With a radius
the question stops arising.

#### It broke maintenance, and the fix is better than what it replaced

The harness caught it in one run: **neglecting public works became the dominant
strategy.** Mains three rows apart with a three-tile reach cover each other two
and three times over, so losing one to a burst changed nothing a player could
see — the city that stopped paying ended up richer *and* no smaller. That is
the whole of phase 6 undone by an unrelated change.

Reach now falls off with condition, through the same
`Infrastructure.capacityFraction` a worn road already loses capacity by. A
neglected network does not wait to burst; it stops reaching the far side of the
street first. Measured again:

| | density | worn | net/tick | treasury |
|---|---|---|---|---|
| funded | **202** | 0% | **+23** | **4,502** |
| neglected | 131 | 100% | −53 | 3,851 |

Dominated on both axes again, and by a *continuous* mechanism rather than a
cliff — which is a better mechanic than the binary one it replaces. Worth
recording as the general shape: **a redundancy-creating change can silently
remove the consequence of an unrelated system**, and only a standing
measurement of that system will say so.

Pipe cost was left alone deliberately. Coverage per tile went up sevenfold, but
a player still runs mains the length of the map — a lattice every seven rows
against one every three is about half the tiles, not a seventh — and the
harness cannot measure it either way, since it lays pipe under every road row
regardless of what a tile reaches.

### "You can't put a pipe under a building" — reported from play, and never true

It was never a placement rule. The pipe was laid, it was live, it was part of
the network and it supplied water. It simply had nowhere to be **drawn**.

A scene node exists **per building, not per tile** — that is what keeps a
built-out map at 2.6 nodes a lot — so the three cells of a 2×2 that are not its
anchor have no node of their own. Every buried marker was hung on the tile
node, so a run laid across a block appeared on the bare ground either side and
vanished in the middle. Worse, the visible neighbours' masks still read
`hasPipe` correctly and drew a stub pointing into the gap, so the run read as
**severed** rather than hidden — which is a far more alarming thing to show
than nothing at all.

`IsoTileRenderer.syncConduits` takes a *list* of segments now, one per cell of
the building that carries something, each offset by the projection of its own
position. The projection is linear through the origin, so a cell's offset from
the anchor projects to exactly the difference between the two. Node count only
rises where pipes actually run under a multi-tile building, and the one-node-
per-building property survives.

Two things fell out of it:

- **The cache key has to see every segment.** Keyed on the anchor's state
  alone, a pipe appearing under one cell of a block would be skipped as "no
  change" — the same class of bug as the stale keys an overlay has to
  invalidate, which this file already records.
- **`GameScene.refresh` has to redirect to the building.** Laying pipe under a
  covered cell called `refresh` on a position with no node, which returned
  immediately and redrew nothing. It resolves the building's anchor first now,
  and works in the building's coordinates from there — `position` is only the
  ground somebody touched.

**And the render fixture could not have shown it**, which is why it survived
into a play session: every pipe in it ran along bare ground. It drives a run
straight through a block now. Same shape as the fixture that had no pipes at
all, and the one where every conduit was live — *a picture in which the
failing case cannot occur reports success.*

Worth keeping generally: **a rendering decision taken for the whole map ("one
node per building") silently constrains every per-tile thing added later.** The
buried layers are per *tile*; the nodes are per *building*; nothing failed, and
the map just quietly stopped drawing part of what the simulation knew.

### Three answers, not two

The screenshot's other half. SimCity 4's water view paints **served buildings
blue and buildings that want water and have not got it orange**, and ours
washed every unserved building to the same near-black.

That is the crime overlay's lesson, never carried back: a house too small to
need water yet and a tower dying for want of a main are not the same thing, and
painting both as nothing made the map claim a problem that was not there —
exactly what safe factories outside every police catchment used to do on the
Crime view.

`CitySimulator.needsWater` / `needsPower` is the condition, owned by the
simulation and *called* by the overlay rather than restated there — the same
contract `CityHazards.isExposed` has. Served is lit in the utility's own hue,
wanting-and-lacking is lit in the loudest colour on the map, and everything
else is quiet.

**And it retires a rule.** "Lit means fine, dark means trouble" was written
across all four network overlays and it works only while an overlay asks a
yes/no of every building. With three answers, "dark" has to mean both *not
applicable* and *broken*, which could hardly be less alike. The refinement:
**one reading per answer, and the answer that wants something is the loud
one.**

The alarm hue took two goes. It first borrowed `problemColor(for: .critical)`
on the reasoning that this is the same claim the Problems view makes — which is
not true (that view ranks a missing utility as `.blocked`, and paints it blue),
and which picked an amber sitting almost on top of the power network's own
yellow. A hot red reads against water's cyan and power's amber alike.

One thing to watch in play: water's blue-against-red is unmistakable, power's
amber-against-red less so. If it bites, the answer is a second channel rather
than a third hue — the Problems view's additive glow pool, which exists for
exactly this.

### And one test that was wrong about its own geometry

The reach is a diamond, like every other coverage question in this game. The
first attempt to pin that measured beside the *middle* of a straight main,
where every band merges into a straight edge and the nearest pipe to any tile
is the one directly across — so the corner can never appear. It has to be
measured past the **end** of a run.

## Parks: the one thing that only makes a place nicer

Every contributor to `LandValue` was a service with desirability as a side
effect — a police station raises land value *and* stops crime, a school raises
it *and* unlocks the top tier. So "make this neighbourhood desirable" had no
direct tool, and the land-value gate on the upper densities was something you
satisfied by accident rather than aimed at.

**A park adds rather than competes, and that is the whole design.** Every other
positive goes through a `max` in `LandValue.value` — "how good is the best
thing near you" — which means a second amenity beside a police station
contributes nothing at all. A park is not trying to be the best thing nearby;
it makes an already-decent block better, so it stacks on top the same way the
pollution and power-plant penalties stack underneath. It is the only positive
that does.

`parkBonus` is 0.18, sized against the gate it exists to help with: plain road
frontage tops out at 0.75 and the top tier asks 0.8, so a park is what carries
an ordinary street over that line. It cannot do it alone — density 5 still
wants water, power and a school — it just stops land value being the thing
quietly blocking it.

Three decisions worth recording:

- **1×1, unlike every other civic building.** A park's cost is the *ground* it
  sits on. Trading buildable area for desirability is a real land-use decision
  and it only reads as one if parks are small enough to thread between blocks.
- **Unlocked from tick one.** The land-value gate bites from density 2, long
  before any service unlocks; holding parks back would repeat the mistake the
  starter utilities exist to fix — a problem the game shows you and will not
  let you solve.
- **They do not stack with each other.** `falloffValue` measures distance to
  the *nearest*, so a wall of parks is one park's worth of desirability. That
  is what stops paving the map in them being the dominant strategy.

### The clamp that nearly smuggled itself in

Adding parks to `positives` meant the total could exceed 1, so the obvious move
was to clamp it — and that quietly deleted a documented feature.
`falloffValue` scales with funding, the player can push funding above 1.0, and
`testOverfundedServiceProjectsProportionallyMoreLandValue` pins an over-funded
station out-projecting its usual falloff as a *deliberate lever*. The test
caught it immediately.

Same shape as the `.burning` branch that nearly skipped a repair roll during
the `LotStatus` extraction: a behaviour change riding along inside an unrelated
feature, justified by a tidiness argument. The park test was rewritten to
assert what actually matters — that a park's contribution is bounded by
`parkBonus` — rather than that land value stays under 1, which is not a
property this model has ever had.

### Schools and hospitals already existed

Worth writing down because it was not obvious from playing: `.school` unlocks
at 250 population and `.hospital` at 600. The quick playtest profile settles
around 370, so a hospital never appears in a short session at that size — which
is a reasonable thing to revisit if they feel absent in play, but it is an
unlock-threshold question rather than a missing feature.

## The transportation module (in progress)

Transit was two lines of simulation: `CitySimulator.hasAccess` counts a stop as
road access, and `LandValue` treats it as an amenity with a falloff. A bus stop
did not take a single car off the road — `Traffic.isRoadLike` is `road ||
highway` and nothing in the routing has ever heard of `.publicTransit`. Subway
differed from a bus stop only in radius and price, so the two were the same
tool twice.

The plan is a real module: player-drawn bus and subway routes with ridership,
in the spirit of Cities: Skylines. Three decisions keep it tractable — **the
route is the infrastructure** (a bus route runs on roads, a subway route
tunnels, so there is no separate track layer to draw), **no transfers in v1**
(a trip rides if one line serves both ends, because multi-leg journeys are a
routing problem that would dominate the work), and **ridership is an index
lookup, not a search** (tile → which routes cover it, then a set intersection
per commute, because `Traffic.computeLoad` is already ~90% of tick cost).

### Phase 0 (done): the city has a calendar

The cockpit said "+$1,798/tick". Nobody lives in ticks — people build things in
weeks and watch economies turn over years — and a city builder that cannot say
how old your city is has made its own bookkeeping the player's problem.

**One tick is one day**, and that was not chosen to make a nice number. Nearly
every constant already in the simulation lands on a sensible real duration
under it:

| | ticks | as days |
|---|---|---|
| a storey of construction | 8–40 | 8–40 days |
| bare ground → max density | 125 | ~4 months |
| a city settling | ~160 | ~5 months |
| the regional boom/bust cycle | 293–421 | **10–14 months** |
| one hazard per building | ~250 | ~8 months |

The economy turning over on roughly an annual cycle is the reading that settled
it. At normal speed a year is about six minutes of play.

Four decisions worth keeping:

- **No hours**, and for a better reason than resolution. There is no sub-day
  grain, but more to the point this city is permanently night by design — a
  clock showing the time of day would promise a day/night cycle the art
  direction deliberately does not have.
- **One clock.** `RegionalEconomy.elapsed` has counted days since founding
  since it was written and is already saved, so `CityMap.elapsedDays` reads
  that rather than introducing a second counter beside it. Two copies of the
  same fact drifting apart is the mistake this project keeps paying for; a
  calendar disagreeing with the economy's own clock would have been the next
  one. Only one line in `CityMap` knows where the number lives.
- **The player-facing text changed; the internals did not.**
  `declineChancePerTick`, `wearPerTick` and forty-odd others keep their names.
  Renaming them all is churn with real risk and no gain while the mapping is
  exactly 1:1 — `CityDate` states it once.
- **Founded in 1985.** The art direction is retrowave, so the city is dated as
  the decade it is dressed as.

`CityDateTests` also pins the mapping itself: if a construction time or the
regional cycle ever moves far enough that "one tick is one day" stops reading
as a sensible duration, the test says so rather than letting the fiction quietly
rot.

One honest wrinkle: a fire burns for about four ticks, which now reads as four
days. That is long for a fire. SimCity has the same oddity, and retuning a
balance constant to suit a naming change is the wrong way round — but it is the
one place the day reading strains.

### The speed control was built the whole time

`SimulationSpeed` has had slow/normal/fast wired to the scene clock since the
clock existed, bound in the menu bar and **nowhere else**. It was the last
survivor of a problem this file already records once: tax, funding, ordinances
and debt were all menu-only, "which made the whole economic half of the game
invisible to anyone who did not go looking in a menu for it." A control nobody
can see is a control nobody has.

It sits next to Play now, because how fast is the same question as whether.

**And putting it there immediately broke something else.** Two pickers ended up
side by side whose selected chip both read "Normal" — one meaning 1× speed, the
other meaning no overlay — in a panel with no labels on either row. The overlay
row had been unlabelled since it was written and had got away with it purely by
being alone; eleven identical buttons with the same word lit twice in them is
not a row anyone reads. Both rows are labelled now, Speed and View.

Worth noting for pacing: at `.normal` one tick is one second, so a day is a
second, a year is six minutes, and `RegionalEconomy`'s cycle turns over in five
to seven. `.slow` only doubles that, which is not much of a slow for systems
that operate over hundreds of days.

### Phase 1 (done): a line, and the trip that rides it

**The route is the infrastructure.** There is no track layer to draw and no
vehicles to place: a bus route runs on the roads that are already there, a
subway tunnels under whatever is above it, and what the player authors is
*which stations are on the same line*. So `TransitRoute` holds an ordered list
of positions rather than a path, and the stations keep carrying the cost, the
unlock, the upkeep and the land-value amenity they always did. Drawing a route
is free; the decision it expresses is where you already spent the money.

**A commute that can ride does not drive.** `Traffic.computeLoad` runs its job
lottery exactly as before, and *then* asks whether one route serves both the
home and the job it picked. If one does, the trip rides: no road load anywhere
along the way, and the route counts the riders.

Asking after the lottery rather than before it is the load-bearing bit. A bus
line is supposed to change how people get to work, not who employs them —
folding transit into the choice of destination would quietly make a route a
land-use lever nobody asked for, and would put hops and stops into the same
weighting where they mean different things.

**Ridership is an index lookup, not a search**, and that is what made the
feature affordable at all. `computeLoad` is already ~90% of a tick because it
runs a breadth-first search per home; a second network searched per trip would
have doubled the most expensive thing in the game. Instead every station stamps
its catchment once into `TransitCoverage`, and "can these two places ride the
same line?" is a dictionary lookup and a set intersection.

**No transfers in v1**, and it is one function — `TransitCoverage.connection`
looks for a route present at both ends and nothing else. Multi-leg journeys are
a routing problem in their own right, and would dominate the module while being
nearly invisible next to the thing a player actually watches, which is whether
their line carries anyone. Stated once rather than assumed in several places.

Three things worth recording:

- **What was drawn and what works are different types.** `TransitNetwork` is
  the player's authored state; `Transit` reads the map and decides what any of
  it currently does — a stop whose station was bulldozed, a bus route listing a
  subway entrance, a line left with one stop. Same split the conduit overlay
  already draws between a pipe that exists and a pipe that is live, and there
  for the same reason: "I never built that" and "that stopped working" are
  different problems. Bulldozing a station drops it from the lines that called
  there and keeps the lines, because losing a route for rearranging your own
  city is a punishment; losing its *service* is just the consequence.
- **A catchment is not a land-value falloff.** The obvious move was to reuse
  `LandValue.transitFalloffDistance`, and it measures a different question —
  how far the amenity is *felt* as desirability, not whether the people who
  live here can use the thing. Tying them would make a balance change to one a
  silent change to the other. `Transit.busCatchment` is 4, matching
  `Water.directSupplyRadius`, which is this game's existing answer to "near
  enough to count"; the subway's is twice it, a ratio rather than a tuned
  number, since balance belongs to phase 4.
- **One station is not a line.** Without a two-stop minimum a single stop would
  carry every commute inside its own catchment, for the price of one building
  and no route worth the name.

#### A view each for bus and subway

The player's call, and the right one. They are two networks you plan
separately — a bus line is cheap, local and threaded through streets you
already have; a subway is expensive, wide-reaching and worth building before
the city that justifies it — and one combined view would overlap their
catchments into a single "somewhere near transit" wash that answers neither
"where should the next bus stop go" nor "is the subway worth extending". Every
other overlay in the game shows one network or one channel.

Both are built to the shape Water and Power already established, deliberately
down to the highlighted source: **lit means served**, the ground carries the
catchment, and the stations keep their own colours because they are what the
player is hunting for. A fourth network overlay is only worth having if
learning one of them is learning all of them.

Over the top goes the route diagram, and it is **schematic rather than
geographic**: a straight run from station to station, not a trace of the roads
a bus would use. That is the honest drawing of what a route is here — there is
no track layer, and a line following streets would be a picture of a path
nothing in the simulation stores. Every transit map worth reading is a diagram
for the same reason. It is one node for the whole network rather than one per
tile, because a line spans arbitrary distance and there is no tile it belongs
to; with a handful of routes against thousands of tiles, `SKShapeNode`'s
refusal to batch costs nothing here.

Three things the render decided, and one it caught:

- **The line's core is not additive.** Drawn additively over its own additive
  halo it saturated to a white-pink filament, and the line stopped carrying the
  one thing its colour is for. That is *exactly* the mistake recorded one
  section above for the first conduits — "additive overlap plus bloom saturated
  the run to white" — repeated within the same feature. The bloom is the
  additive half; the line itself stays the hue it was given.
- **A hollow ring reads as a hole in the line**, not as a station, at the
  eleven points one is actually drawn at. A dark band with a lit dot inside it
  — how a transit map draws an interchange — survives the size.
- **A catchment is not a land-value falloff**, so the ground is painted from
  `Transit.busCatchment` rather than `LandValue.transitFalloffDistance`. The
  same separation phase 1 drew, now visible: the Subway view's field is
  obviously twice the Bus view's.

**And the Overlay menu crashed the app on its tenth entry.** It built each
shortcut as `Character("\(index)")`, which is fine for one digit and a fatal
error for two, so adding Bus and Subway took the whole app down at launch — in
a `CommandMenu`, which this file already records as failing *silently*. Only
the render caught it, because a test target that never builds the menu never
runs the line. `overlayShortcut(for:)` returns `nil` past the digits, and
`OverlayModeTests` walks `allCases` so the next overlay added cannot bring it
back.

One perf bug came out of the same pass. `refreshAll` computed its
`ZoneDistanceField` only `if overlayMode == .landValue`, which was true when
land value was the only overlay that read one — and by the time Crime, Fire
Risk and Problems arrived it was quietly making each of them rebuild a
whole-map field *per tile*, the `O(tiles²)` cost `ZoneDistanceField` exists to
delete, paid on the render thread. It is computed for any overlay now: cheaper
than keeping a list of which ones happen to need it, and a list like that is
exactly what goes stale.

#### The hole it closed

A home with no road frontage generated no trips at all — `computeLoad` dropped
it with a comment reading "transit-only access: no road trips generated". That
was harmless while nothing could carry those people, and stopped being harmless
the moment the inspector started reporting who found work: a block that
`CitySimulator.hasAccess` had happily let grow off a transit stop reported
every resident as unable to reach a job. It picks its job off the lines that
serve it now, measured in stops.

Job sites with no road frontage were being dropped for the mirror-image reason
("no road access: not a reachable job at all") and are kept for the same one.

### Phase 2 (done): drawing a line

**You build a route by clicking the stations on it**, while its own view is up
— the same contract pipes and power lines have had since they existed, and the
reason the Bus and Subway views were worth building before the editor rather
than after it. Picking the tool raises the view and starts a line; clicking a
station appends it; clicking the one you just added takes it off again.

Four decisions worth recording:

- **Undo is in the same gesture as the mistake.** Clicking the last stop
  removes it, so correcting a misclick does not mean finding a button. It has
  to be *the last one* rather than any stop already on the line, though —
  "click to toggle" would make the common correction work and make a circular
  route impossible to express at all.
- **A drag adds nothing.** Every other tool in the game paints, and a route is
  a short ordered list of buildings rather than something you paint: a drag
  across a station would have added it once per frame.
- **Editing an existing line is the same gesture as drawing a new one.**
  `TransitRouteDraft` carries the route it is a revision of, so adding a stop
  to something you already have is not a second mode with its own rules.
- **The draft is drawn on the map**, dashed and in the amber a construction
  scaffold already uses — this game has picked a colour and a texture for "not
  finished" and this is the same idea. Without it the editor is a list of stops
  in a panel and a map that looks no different after a click than before one,
  which throws away the reason to build a route by clicking at all.

The panel floats over the map rather than opening as a sheet, because building
a route means clicking the map — City Hall can be a sheet precisely because
nothing in it needs the city visible. Top-leading, since the inspector already
owns top-trailing.

#### Ridership is the readout

A route panel that only listed lines would say nothing a glance at the map does
not. The number a player steers by is how many people actually used the thing
they paid for, and one tick being one day means what the router counted this
tick *is* the day's ridership — no conversion anywhere, which is the dividend
from the calendar work.

A line showing no riders has two very different causes and the panel names
which: "needs another stop" against "a station on this line is gone". That is
what `workingStopCounts` exists for — `stops.count` is what was drawn, and
`Transit` decides what works.

#### Two things the render caught

- **A disabled neon button looked identical to a working one.** `.disabled(_:)`
  greys a stock AppKit control for free and did nothing at all here, because
  every colour in `RetroButtonStyle` comes from its accent — so the one panel
  whose job is saying "this line is not finishable yet" had its unavailable
  Finish button burning exactly as brightly as Cancel beside it. It reads
  `\.isEnabled` now, which fixes every button in the app rather than this one.
- **The draft lost its stops to the routes already running.** A draft calls at
  the same handful of buildings the finished lines do, and the finished diagram
  is drawn after it, so at every shared station the running line's own mark
  painted over the draft's. The draft sorts above them now.

And one bug the render could not have caught, because it needs two views:
switching from Bus to Subway with a line half-drawn showed the *bus* draft in
the Subway panel, offering to finish it there. The draft survives the switch on
purpose — you come back to it — but the other view has no business in it.

#### A test whose premise moved

`ToolCategoryTests` asserted that every non-zone tool shows a cost, which was
true for as long as pipes and power lines were the only ones. A route is
genuinely free: the stations carried the cost, and drawing the line is the free
act of saying which of them are on one.

Worth noting because this project's standing rule for a test that starts
failing is to ask whether the thing moved or the yardstick did — and both
answers have come up here before. This time the thing moved, so the assertion
is *restated* ("a free tool has to be a route tool") rather than relaxed into
one that would no longer notice a pipe tool quietly losing its price.

### Phase 4 (done): what makes a subway a subway, and what it all costs

Bus and subway differed only in how far they reached and what they cost, which
made the subway a bus with bigger numbers rather than a different answer to a
different problem. **A bus shares the street.** Park a line along a jammed
arterial and it crawls, exactly when the city needs it most; a subway has its
own tunnel and does not care. That is the whole character of the two modes, and
it reuses machinery that already existed — `Traffic.congestion`, read at the
stops, because the line has no road path to read along (it is a schematic
between stations).

`Transit.busJamFloor` (0.3) exists for the reason
`Infrastructure.ruinedCapacityFraction` does: a bus line losing capacity pushes
riders onto the roads that are jamming it, and without a floor that loop has no
bottom.

**A route has a ceiling and an operating cost**, both per stop, so extending a
line is a real alternative to building a second one and a city cannot blanket
the map in lines for free. The station is the shelter and was already charged
for; this is the vehicles running through it. Four to one on both counts,
matching the subway's four-times catchment area — so a subway is not
*relatively* more capacious per person reached, it is simply bigger, and what it
buys is reach in one line plus the tunnel.

**Ridership moved from density units to people.** Road load is an abstract
weight and density is the right currency for it; ridership is a number the
player reads, and "31 riders/day" for a line serving a neighbourhood of hundreds
reads as broken. One tick being one day means the router's own count *is* the
daily figure, with no conversion anywhere.

#### Measured (64×64, 1,500 days)

Four cities, same seed, same layout. `no stops` has no transit buildings at
all; `idle` has the stations and no lines, which is exactly what transit was
before this module.

| network | lines | pop | congestion | riders/day | busiest line | net/day |
|---|---|---|---|---|---|---|
| no stops | 0 | 3,112 | 0.138 | 0 | — | **+124** |
| idle | 0 | 2,668 | 0.179 | 0 | — | −329 |
| bus | 22 | 2,908 | 0.122 | 812 | 73% | −276 |
| subway | 22 | **3,080** | **0.037** | **2,744** | 42% | −1,791 |

**Drawing the lines pays for itself**: against idle stations a bus network buys
240 people and *improves* net revenue, and a subway network buys 412 and cuts
congestion by four fifths. The mode distinction reads exactly as designed — the
subway nearly eliminates congestion where the bus roughly halves the reduction,
and the bus's own line is the one running near its ceiling.

**The capacity number was found by measuring, not by reasoning.** Halving
`capacityPerStop` from the first guess changed the outcome *not at all* —
identical ridership to the digit — which is how a ceiling that looked generous
turned out to be nowhere near reach. At the halved value the busiest bus line
runs 73% full at 64×64 and 83% at 24×24: close enough to bind on a line drawn
where people actually travel, loose enough that an ordinary one is not capped.
The subway over the same stations sits at 42%, which is the honest signal that
a subway *here* is an over-build.

Worth recording that the total was the wrong statistic and the maximum was the
right one. Mean utilisation across twenty arbitrary lines would have hidden one
saturated route among nineteen empty ones, and "a mechanic that never binds" is
something this project has shipped before — demand drifted toward abandonment
for fifteen hundred ticks and never arrived.

#### Still open: transit never beats having no stations at all

Both networks are worse than the city that built nothing, by about 200 people
and 400/day. Half of that gap is real upkeep and half is **displacement** — the
harness assigns every lot, so each of the 44 stations demolishes a 2×2
building, and 444 of the missing people are simply the buildings the stops
replaced.

That is a property of the fixture rather than of the mechanic, and the honest
response is to say so rather than tune constants until a yardstick flatters the
thing it measures. Two real questions it leaves, both outside this phase:
whether a transit stop should be smaller or cheaper than a full lot, and
whether congestion is weighted heavily enough for relieving it to be worth
paying for. The harness also spreads traffic thin by construction —
`roadSpacing` is 3 so that every lot touches a road — so the congestion figures
here are a floor, and a player city with a few arterials concentrates it.

Route capacity is not affected by funding, and trams are still deferred on the
player's own call.

### Phase 5 (done): the transit graph, and one currency for getting to work

Adding trams and regional rail meant first admitting that the model could not
express a network. Three things were wrong, and all three were fine with two
modes and untenable with four:

- **No transfers.** A trip rode only when *one* route served both ends. A tram
  feeding a subway feeding a regional train is the whole mechanic, and this
  made it impossible.
- **No notion of better.** Transit was taken whenever it was merely
  *available*, so a line that went the long way round beat a two-tile drive,
  and congestion could not push anybody onto anything.
- **Two incompatible distances.** A road-fronted home picked its job by road
  hops and a transit-only one by stops along a line, in separate code paths
  that never met, because the two numbers could not be compared.

**Why transfers turned out to be affordable, having been ruled out on cost.**
The original reasoning was that `Traffic.computeLoad` is already ~90% of a tick
running a breadth-first search *per home*, and a second network searched per
trip would double the most expensive thing in the game. That was right about
searching per trip and wrong about needing to. The transit graph has one node
per **(station, line)** pair — tens of them in a real city against thousands of
road tiles — so all-pairs shortest paths over the whole thing costs less than
one of the searches already being run per home, computed once per tick. The
per-home step stays exactly what it was: an index lookup.

A **(station, line) pair** rather than a station, because that is what makes a
transfer cost anything. With a station as the node, riding through an
interchange and changing lines there would be the same journey at the same
price — and the entire point of an interchange is that changing is worse than
not having to. Two stations within `Transit.transferWalkDistance` are a
transfer edge, so **an interchange is something the player builds** by siting
stations near each other. There is no interchange building and there does not
need to be.

#### Everything now costs minutes

Driving is hops × `Traffic.drivingMinutesPerTile`, scaled up by congestion.
Riding is walk + wait + in-vehicle + a penalty and a second wait per change.
The job lottery weighs minutes, and the faster option wins the trip — with
driving taking an exact tie, because a journey that is no faster is not worth
a walk and a wait.

That closes a loop the module never had: **roads fill → driving slows → trips
move onto the lines → roads empty.** Transit was previously a discount applied
whenever it was available.

`drivingMinutesPerTile` is deliberately **1.0**, so that on an empty road a
journey in minutes is numerically the journey in hops the lottery used before.
Moving to minutes therefore moved nothing by itself, and every difference it
does make is attributable to congestion or to a faster line rather than to a
silent re-weighting of where the city works.

**The minute constants were calibrated against one worked example**, not
against a stopwatch — the map is far too abstracted for geography to help. Take
a cross-town commute of about twenty tiles, twenty-odd minutes by car on a
clear road: a bus should land on roughly the same number, so it is a coin flip
on an empty street and wins outright once the street fills; a subway should win
it comfortably; and both should lose a five-tile trip, because nobody waits for
a bus to go two blocks. The first values put walking and waiting at **12.5
minutes of a 22 minute journey** — over half the trip spent not moving — which
made even a subway a coin flip across a whole city. The fixed overhead is what
these numbers really set.

Two simplifications admitted rather than hidden:

- **Congestion is measured at the doorstep**, not along the route. The exact
  answer needs every tile on the path, and the path is only known once a job
  is chosen — while congestion is one of the things choosing it. A weighted
  search per home instead of a plain breadth-first one would make the most
  expensive loop in the game several times more expensive to buy a decimal
  place. It also reads correctly as a story: the street outside your house is
  jammed, so you take the bus.
- **A full line turns a trip onto the road rather than rerouting it.**
  Rerouting needs a search per trip against a table built without that line,
  and in the aggregate the answer is the same: this trip is not on transit.

**Every leg counts a boarding.** A trip that changes from a bus to a subway
puts its riders on both lines, which is what a per-line figure means everywhere
outside this game too — and what makes a feeder line's number reflect the work
it is doing.

#### Measured (64×64, 1,500 days)

Ridership roughly **2.4×** what the no-transfer model carried, and — the part
that matters — **capacity finally binds**. The busiest line ran 73% full
before; it now runs at or over 100%, which is a ceiling doing its job.

| network | pop | congestion | riders/day | busiest line | net/day |
|---|---|---|---|---|---|
| no stops | 3,132 | 0.113 | 0 | — | **+285** |
| idle stops | 2,596 | 0.171 | 0 | — | −397 |
| bus | 3,004 | 0.085 | 1,992 | 112% | −240 |
| subway | 3,092 | **0.041** | 6,012 | 99% | −1,764 |

And in a city where the commute is actually long — `segregateIndustry`, which
`DesignPlaytestTests` already proves is the better way to build — transit earns
its keep outright:

| network | pop | congestion | riders/day | net/day |
|---|---|---|---|---|
| idle stops | 2,884 | 0.164 | 0 | −52 |
| bus | 3,140 | 0.094 | 1,904 | −90 |
| subway | **3,368** | **0.028** | 6,272 | −1,624 |

**Transit is worth what the commute is long**, and that is the finding worth
keeping. The default generated city interleaves housing, shops and factories
every other lot, so nearly every journey is three blocks and a bus's walk and
wait swamp it — correctly, and uselessly as a test. The scenario that measures
transit has to be the one that generates journeys worth catching a line for.

#### The payoff a player can read

`TrafficLoad.Commute` keeps what the router works out and used to discard —
exactly as it once discarded whether a job was found at all. The inspector now
says **"18 minutes to work, by bus"**, which is the one sentence about this
model anybody understands without being taught it, and the only place the mode
decision surfaces at all.

#### What it costs per tick

A 64×64 city with **no** transit ticks in **16.1 ms** in Release; the same size
carrying twenty-two routes ticks in about **34 ms**. So the machinery roughly
doubles the most expensive loop in the game on a city that leans on it hard —
against a `SimulationSpeed.fast` interval of 0.75 s, which is 4.5% of the
budget, so it is a number to watch rather than a problem.

The graph itself is not where that goes: it is built once per tick over tens of
nodes. The cost is the per-(home, job) journey lookup.

**Both halves of that sentence were later measured, and the second half named
the wrong term.** See "Where the transit half of a tick actually was" below —
it was not the `reach²` pairing, it was `legs` allocating arrays for an answer
the job lottery discarded.

#### One yardstick that had to move

`testFireSpreadDoesNotLeaveTheCityPermanentlyAblaze` asserted that a serviced
city has *zero* blocks alight at tick 400, and duly failed — on a change that
touches fire only by way of land value deciding what grows where. Whether one
arbitrary tick catches a fire is close to a coin toss: the serviced city is
alight on **13% of ticks**, so a single sample was never the property the
comment described ("fires are events; between them the city should be quiet").
It measures the fraction of ticks now. Same lesson as the hazard rate that had
to move from strikes-per-tick to strikes-per-building-per-tick: when a
measurement starts failing, check whether the thing moved or the yardstick did.

### Phase 6 (done): the tram, and the first transit building that costs the road

A tram is the middle rung on every axis — catchment, capacity, speed, price,
upkeep, unlock — which on its own would make it a bus with bigger numbers, the
exact criticism that drove phase 4. What makes it a different *decision* is one
thing:

**A tram lays rails in the street, and the street loses a quarter of its
capacity.** Every other transit building in this game is a pure addition: build
it, and trips move off the road. This one narrows the corridor it relieves. Put
a tram down your busiest arterial and you may find you have made it worse —
`Traffic.tramLaneShare` is a quarter, so a tram has to carry more than a
quarter of a street's traffic to be worth running down it.

**The track is derived, not authored**, which is what keeps "the route is the
infrastructure" true for a mode that genuinely occupies ground. The player
still only clicks stations; `Transit.tramTracks` lays rails along the shortest
road run between each consecutive pair. One breadth-first search per *segment
of a line* — a dozen for a city with four tram routes, against the thousands
`computeLoad` already runs per home.

It cached on `CityMap` rather than being derived on demand, and that was
forced: `Traffic.congestion(at:in:)` reads it, and that is called from
`LandValue`, `Infrastructure`, every overlay and the inspector with nothing but
a position and a map. Deriving it per call would be a search per tile.

**And traffic slows the three modes three different ways**, which is the split
they exist for — a bus is stuck in the jam it is trying to relieve, a tram has
its own rails down the middle and loses a little at junctions, a subway is in a
tunnel. `Transit.jamEffect(on:)` states all three in one place, and the test
asserts each mode against *its own declared numbers* rather than against a list
of modes, so a fourth cannot land without either obeying the rule or saying out
loud that it does not.

#### Measured (64×64, 1,500 days): the trade is real, and it depends on the city

| | congestion | riders/day | pop |
|---|---|---|---|
| **long commutes** — idle stops | 0.164 | 0 | 2,884 |
| bus | 0.094 | 1,904 | 3,140 |
| **tram** | **0.087** | **3,444** | 3,132 |
| subway | 0.028 | 6,272 | 3,368 |
| **mixed use** — bus | **0.085** | 1,992 | 3,004 |
| **tram** | **0.090** | **3,944** | 3,000 |

Read those two tram rows together, because they are the whole mechanic. In the
long-commute city a tram carries nearly twice a bus's riders and beats it on
congestion. In the mixed-use city it carries *twice as many riders again* —
3,944 — and comes out **worse than the bus**, because the lane it took cancels
what it carried. Same network, same constants, opposite verdict, decided by
whether the corridor was worth running down.

That is a placement decision rather than a price comparison, which is what this
mode was added to create. It is also the first time in this project that
building more transit has been measurably able to make traffic worse.

#### Two things the render decided

- **The rails blew out to cyan-white**, and it is the *third* time this module
  has walked into additive saturation — the conduit run, the route line, now
  this. Adjacent track tiles sum where they meet, so the corridor stopped
  reading as teal rails in a street and became a river of light brighter than
  the route line it is supposed to sit beneath. The texture carries its own
  bloom; the blend does not need to add one.
- **The teal was picked against its neighbours, not for itself.** `.park` is a
  warm mint and both are 1×1 buildings threaded between blocks; the highway's
  lane glow is a pure sky cyan. The tram sits between them and is clearly
  neither, while staying in the blue half of the wheel where the rest of
  transit lives.

The stop's identity mark is a **kerbed island with a lit edge and a single
mast** — a bus stop is four legs under a flat canopy and a subway is a
headhouse with a lit mouth, so the three read apart while scanning a corridor
for gaps, which is what these icons are for.

Two smaller consequences. `OverlayMode.view(for:)` replaced a
`mode == .bus ? .bus : .subway` ternary in four places — a construction that
silently means "one of the two I happened to have" and has to be hunted down
for every mode added after it. And the Transport group put the highway between
the tram stop and the subway, because tools list in unlock order rather than
pairing each cheap tool with its upgrade; `ToolCategoryTests` caught that
immediately.

### Phase 7 (done): commuter rail, and the first way out of the city

The three urban modes all move people *within* the city. This one points off
the map, and what it buys is somewhere for residents to work that the
simulation does not have to build.

**Run your line to the edge and it carries on into the region.** The geometry
is the whole rule — a rail station within `Transit.regionalEdgeDistance` of the
boundary makes its line regional, and then every stop on that line is a way
out, because you board where you live and stay on. No new building, no separate
switch, and discoverable by doing the obvious thing with a line that is built
for long journeys.

**The region is modelled as a job site you cannot drive to.** One more entry in
the list `Traffic.computeLoad` already walks, with an empty frontage so no path
ever reaches it. That was the cheap way in and also the honest one: every rule
already there — the lottery, the capacity draw-down, riding against driving,
ridership per leg — applies to it unchanged, and there are no off-map roads, so
making the train the sole way out is what gives the connection its point.

**Bounded by what the trains can carry**, which is the payoff for building
capacity in phase 4: a regional connection is not a switch that turns outside
work on, it is a pipe of a particular size. Want more of a bedroom community?
Run more stops, or another line.

And scaled by how the region itself is doing — the first time
`RegionalEconomy` has reached a city through anything other than demand. That
means a rail-connected city is *more* exposed to the regional cycle than one
that is not: the region hits it once through demand and again through these
jobs. That is the intended reading rather than an oversight. Tying your
fortunes to the outside world is what connecting to it means.

#### The bedroom-community trade, in one line of `Demand`

Outside jobs are added to the job count, and counted on **both** sides
deliberately. Residential demand rises, because there is work to move here for;
commercial and industrial demand falls, because those residents are not
available to fill a local job.

So a rail connection buys population and costs local business. That is a
genuine strategy rather than a bonus, and it is the only thing in this game
that lets a city grow past what it can employ itself.

#### Measured (24×24, 320 days, long commutes)

| network | pop | congestion | riders/day | net/day |
|---|---|---|---|---|
| idle stops | 388 | 0.080 | 0 | +17 |
| bus | 384 | 0.046 | 80 | −28 |
| tram | 348 | 0.043 | 88 | −128 |
| subway | 396 | 0.025 | 180 | −241 |
| **rail** | **428** | **0.000** | 428 | −849 |

The rail city is the **largest of the five** and the only one with no
congestion at all, because a commute that leaves the map puts nothing on any
street. It is also by far the most expensive to run, which is the trade: a
bedroom community is a real place with a real bill.

#### And what is *one* line worth?

Every other scenario in the harness wires every station into a route, which
measures what a network does and says nothing about the decision a player
actually faces first. Regional rail is the sharpest case to ask it of, since it
is the only thing in the game that raises residential demand without a building
to fill the jobs — so `routeLimit` was added to build exactly one.

| | pop | outside jobs | riders/day | net/day |
|---|---|---|---|---|
| no lines | 2,752 | 0 | 0 | −2,052 |
| **one line** | 2,788 | 1,200 | **0** | −2,170 |
| 22 lines | 3,664 | 24,000 | 3,552 | −6,705 |

One line on a large map is a **small nudge**: +36 people, no riders at all, and
118/day. Nobody rides it because four stops cover a sliver of a 64×64 city and
the off-map leg costs 25 minutes on top of reaching the terminus — so a local
job stays faster for almost everybody. The demand lever still fires, quietly.
A whole network is transformative and ruinously expensive. That is the shape a
progression should have.

Worth recording the measurement that *looked* alarming first: at 24×24 one line
gets the entire population gain and the second and third add nothing at all
(428 either way), which reads as a lever that saturates immediately. It is an
artifact of the profile rather than a finding — 1,200 outside jobs against a
400-person city is three times its population, and a city that size would never
unlock rail in play, since the unlock is 1,500 and the quick profile settles
around 400. The harness bypasses unlocks; a player does not. **When a scenario
measures a tool the city could not have built, the scenario is the thing that
is wrong.**

#### Where it sits, and why it is not just a better subway

Fastest ride of the four and by a distance the longest wait — a regional train
runs a few times an hour. That fixed cost is what no local trip can justify:
the crossover against a subway lands somewhere past thirty tiles, roughly half
a large map. The station is also the only transit building that is 2×2, and the
land is part of the price: a bus shelter threads between blocks, a regional
terminus takes a lot.

#### Two things the render decided

- **Chartreuse flooded the map.** At full brightness it is the most luminous
  colour in the game, and its ground wash — spread over the widest catchment of
  any mode — drowned the route line inside its own coverage field. The hue came
  down, and `transitGroundColor` now **scales the blend by the mode's
  catchment**: a radius-10 station covers six times the area of a radius-4 one,
  so the same fraction that reads as a pool of light under a bus stop reads as
  a flood under a terminus. Tied to the catchment rather than tuned per mode,
  so a fifth cannot get it wrong.
- **The station is a trainshed** — a long roof over two lit platforms, spanning
  its whole lot. The tram is a kerbed island with a mast and the subway a
  headhouse with a lit mouth, so all four stay apart while scanning a corridor
  for gaps, which is what these icons are for.

And one assertion that had quietly assumed something: the catchment test
measured from a station's *anchor*, which is the same thing as its footprint
only while every station is 1×1. A 2×2 station reaches one tile further, which
is correct — a catchment is a walk from the building — and nothing had existed
to catch it.

## Freight: the seaport, the airport, and terrain that finally matters

Regional rail sends *people* off the map, and it pulls a city toward being a
dormitory — residential demand up, the other two down. Nothing sent **goods**
anywhere. `RegionalTrade` is the other half: a **seaport** raises industrial
demand and an **airport** raises commercial, so a city with all three has a
reason to be large in every direction at once, which is the shape a late game
wants.

Both are deliberately **buildings, not networks**. Rail earns its connection by
being routed to the edge, which is a thing you draw; a port earns its
connection by existing somewhere it can. One drawn network is enough — a
second would be the transit module again with different nouns.

### The seaport is the first thing in this game that needs the terrain

It has to touch water, so a **Flat map cannot have one**. That is what turns
the founding choice from a look into a strategy: rivers and coasts were a
picture until something depended on them, and this is that something. The
airport has no such rule, which is what stops Flat being a strictly worse map —
a landlocked city buys its connection instead of siting it.

The berth is checked against the whole **footprint's** neighbours rather than
the anchor's, so a 3×3 quay needs water along one of its edges rather than at
one particular corner. Nothing else in the game asks this question, so nothing
else would have caught an anchor-only check; `RegionalTradeTests` pins it
directly. Same shape as the transit catchment that had quietly assumed every
station was 1×1.

### Diminishing returns, because otherwise a port is a slider

`boostPerPort` is 0.34 and two of the same kind add as `1 - 0.5^n`. The first
port is the one that *connects* the city at all; every one after it only
widens a connection that already exists. Without that curve, ports are a demand
lever a large treasury can simply hold down — and this project has shipped a
mechanic that never binds before.

The number is sized against the levers it sits among rather than picked:
above `RegionalEconomy.amplitude` (0.25) so a port outweighs a swing of the
regional cycle, below `Demand.taxDemandSensitivity` (0.5) so it cannot
overrule how the city is run. Funding scales it rather than gating it, the
same way it scales everything else a service does — a mothballed dock connects
nothing.

### Two buildings, and three goes at the airport

The seaport's mark is a **quay with gantry cranes**, and the jib is the whole
point: a horizontal that ends in mid-air over the water is a silhouette
nothing else in this game has. Containers on the deck say freight rather than
marina — and they had to be drawn **three times the size** of the first
attempt, which put five of them at a fifth of a tile and produced specks on an
empty deck. `minimumDetailSize`'s rule reaching massing: three boxes a player
can see beat five they cannot.

The airport took three passes, and the failures are the useful part.

- **A flat strip over flat ground is not a runway.** The first version drew
  the deck 0.03 tall with five lamps down the middle, and the contact sheet
  showed nothing at all — in this projection a plane with no height has no
  edge to catch the light. It is a deck 0.1 tall now, with a **dashed
  centreline of big lit slabs** drawn the size industry's lit bays are drawn.
  Those read at every zoom; the first lamps read at none.
- **A full-lot apron paints over everything standing on it.** The slab sat at
  the lot's centre, so the painter's algorithm drew it *after* the runway at
  the back and *with* the aircraft in the middle. Two versions of this
  building were drawn correctly and then buried under their own hardstanding.
  The general shape, and it has bitten here before in the hospital cross's
  sort ties: **a volume that spans the lot has no useful depth key**, so it
  can only be frontmost or backmost. Everything is laid out back-to-front by
  `y` now — runway, terminal, tower — and the lot's own ground diamond is the
  hardstanding.
- **There is no aircraft, and it was tried twice.** A plane is a fuselage, a
  wing and a fin, and at three tiles across the wing is a tenth of a tile
  thick, so the three volumes merged into one lump that read as a crate.
  Scaled up enough to separate, it stopped being a plane and became a hangar.
  Cut, per this file's own rule: **if a mark cannot be drawn big enough to
  read, cut it rather than shrink the building around it.** The runway carries
  the lot on its own, and an airport is mostly open ground anyway.

### Freight displaced two properties that were true by accident

Both surfaced as test failures, and both were the *thing* moving rather than
the yardstick being wrong — so both are restated, and in each case the new
ordering is now asserted rather than left to be true by accident, which is how
the old one drifted in the first place.

- **"Rail is the last thing earned."** It meant the last rung of the transit
  ladder and was written as the last `ZoneType`, because rail was the top of
  every ladder there was. Freight now sits above it on purpose: rail is how a
  city outgrows the jobs it can build, a port is how it starts supplying
  somewhere else. The assertion derives its set from `TransitRoute.Mode`, so a
  fifth mode cannot land above rail without saying so.
- **"A hospital is the single most expensive thing in the game to run."**
  Stated in this file and asserted in `CivicServicesTests`, and the airport
  (75) now outruns it (55). That is deliberate — each port raises a whole
  sector's demand by itself, so the counterweight has to be a bill a plateaued
  treasury notices, and *money still accumulates* is a standing open finding
  above. The hospital keeps the claim that was really being made: the heaviest
  thing a city builds to serve **its own residents**.

**Both of those upkeep numbers, and `boostPerPort`, are unmeasured.** They are
sized by argument against the constants they sit among, which is exactly how
`capacityPerStop` was first sized — and measuring that one found a ceiling
nowhere near reach. A harness scenario for a port city against a control is
the honest next step, and until it exists these are first guesses wearing a
rationale.

### And the placement cursor had been lying since water landed

Adding a rule about *where* a building may go turned up that the cursor could
not express one. `updatePlacementPreview` tested `would this replace
something`, which was the complete rule on the day it was written and a
partial one ever since: a seaport hovered over dry land drew in the clear
colour and then refused the click, and so — it turns out — did **a house
hovered over a river**, which has been true since terrain landed and was
never noticed.

`GameController.placementRefusal(of:at:)` is the gate chain as a value, and
`place(at:)` is now written in terms of it. Same direction, and for the same
reason, as `LotStatus`, `CityHazards.isExposed` and `CitySimulator.needsWater`:
**the rule is owned in one place and *called* by the view, rather than restated
there and left to drift.** Affordability is deliberately not drawn as blocked —
it has its own red flash on the click, and a cursor that turns red across the
whole map the moment you are broke is saying something about your treasury
rather than about this lot.

The test is a **sweep, not two examples**. A test naming the cases I thought of
would have passed on the day water landed; asking every cell of a map with a
river in it, for four tools, and comparing the cursor's colour against what
`place` actually returns is what makes the next rule added to
`placementRefusal` show up here if the cursor is not taught about it. Verified
by putting the old one-line test back: it fails on residential at (0, 7)
onward, which is the river.

## The Problems view, and slowing the clock down

Reported from play: *"everything is happening so fast, there's no way to check
on all the issues the buildings are having."* That is two problems wearing one
coat, and only one of them is pacing.

**The inspector answers the wrong half of the question.** It says what is wrong
with the lot under the pointer, which only helps once you know which lot to
point at — and the only way to find that out was to hover over every block in
the city, faster than the simulation was changing them. With four hundred lots
that is hopeless at *any* speed.

`LotStatus.Severity` ranks every state the gate chain already produces — fine,
blocked, failing, critical — and the **Problems** overlay paints the whole city
by it at once. A count in Alerts says how many blocks want looking at and names
the view that shows where. Nothing else was needed: the ranking is a property
of a type that already existed, which is the dividend from extracting the gate
chain in the first place.

Two things the render decided:

- **A tint could not get bright enough.** `RetroShader` costs up to 40% of
  brightness at the map's edges, so a lot painted in *pure* red still came out
  a muted maroon — a correct picture nobody would notice they were being shown.
  Additive light is the one thing that survives a vignette, which is why every
  other urgent mark in this game is made of it. The overlay flags a lot with a
  glow pool rather than a fill, and `OverlayBuildings.flagged` exists to say
  so.
- **"Fine" has to mean *nothing at all* on screen.** Healthy lots are painted
  the background and get no glow, so the only marks anywhere are the ones that
  want something. A view that flags every lot flags nothing.

### And the clock was too fast

The systems this game grew are all long-horizon — a storey takes 8 to 40 days,
maintenance and the regional cycle run over hundreds — and at one second a day
the whole range was compressed into minutes: a complete boom and bust inside
five, a decision and its consequence inside eight seconds. `.slow` doubling
`.normal` was not much of a slow for any of that.

Now roughly a 2× ladder at 4.0 / 2.0 / 0.75 seconds a day. A year is twelve
minutes at normal, the economy turns over in twenty, and `.slow` is genuinely a
watch-the-city-breathe speed. `ProblemsOverlayTests` pins the ratio and the
range rather than the raw numbers, so the next time these move the test says
whether they still mean what they claim.

### Every overlay had been painting nothing at all

Reported from play, twice over: *"I still can't figure out the power and water
system. It was kind of working a few iterations ago where if a building had
water it was blue in the water overlay."*

`IsoTileRenderer.applyOverlay` recoloured the ground with

```swift
(node.childNode(withName: groundNodeName) as? SKShapeNode)?.fillColor = color
```

and the ground stopped being an `SKShapeNode` the day it was rasterised into a
texture for the "everything repeated is a texture" pass. The cast returned
`nil`, the tint became a silent no-op, and **every overlay in the game had been
painting no data since** — the heatmaps hid the buildings and then coloured
nothing, so land value, pollution and traffic were three blank grids.

This is the third time this exact shape of bug has landed here, and the pattern
is worth naming: **changing what a node *is* silently breaks every cast to what
it was.** `SKAction.colorize` went dead on a plain `SKNode` after the same
migration; the flashes kept compiling and stopped doing anything. Neither
failed a test, because nothing was asserting on the *result* — only that the
call had been made.

Three things came out of fixing it.

**Supply is a colour again, not a brightness.** `OverlayBuildings.dimmed(Double)`
had the call site flatten "is this on the network" into an alpha before the
renderer saw it, which left the renderer unable to say anything else about the
two states. It is `connected(Bool)` now, so a supplied building is washed
toward the utility's own colour and an unsupplied one toward near-black. Blue
means it has water, which is what a player reads and what the top-down version
did before the port.

**The overlay decision lives in one place.** `GameScene` held a five-case
switch and `IsometricCityTests`' render held a second copy — and the copy had
only ever grown the water and power cases, so every heatmap rendered as an
ordinary city and the render cheerfully reported three overlays were fine while
they painted nothing. `IsoTileRenderer.paint(for:at:in:using:)` is a pure
function both call. Same failure as the streetscape that painted its own flat
tiles while the renderer had moved on: **a yardstick that reimplements the
thing it measures always reports success.**

**And the render fixture had one state, twice.** The overlay render used the
bare city, which has no pipes and no power lines anywhere, so every building
came back unsupplied. An overlay's whole job is telling two states apart, and a
picture in which only one of them occurs cannot show whether it does. The
fixture now lays a partial network — and computes `pollution` and
`trafficLoad`, without which those heatmaps render a uniform black field that
is indistinguishable from the bug.

Two tests now assert the *colour arrives* rather than that the call happened,
and that it goes away again — a city left permanently blue after a visit to the
water overlay would look exactly like the overlay being stuck on. Note that
`SKColor` equality is colour-space sensitive and SpriteKit converts what you
assign to `SKSpriteNode.color` into device RGB, so those tests compare
components rather than colours.

### Utilities looked broken, and were

Two bugs, reported from play as "when you lay down a power line it is not clear
the building gets power".

**Supply was only recomputed inside `advanceSimulation()`.** The game starts
paused, so a player could lay an entire network and watch the overlay stay
stubbornly dark — the pipe and power-line *markers* appeared, because those read
`Tile.hasPipe` directly, but the supply *colouring* did not, because it reads a
cached field nobody had recomputed. `recomputeUtilitySupply()` now runs whenever
anything that changes connectivity does: laying or removing a pipe or line,
placing or bulldozing a utility, and changing funding, which buys capacity.
Supply is a pure function of the map — one flood fill per network, not a
simulation step — so recomputing it the moment the map changes is both correct
and cheap.

**And a ground tint was answering the wrong question.** What a player wants to
know in these overlays is "is *that building* on my network?", and the overlay
was answering it by tinting the ground underneath. Buildings are now lit when
supplied and dark when not, so connecting one visibly turns it on. Lit means
supplied.

Worth noting how this survived: the mechanic was correct the whole time — every
`hasSupply` test passed, because they all ran a tick first. The regression tests
added here deliberately never tick, which is the entire point.

### QA pass: what rendering the *real* view found

The cockpit render assembled the same components in the same order as
`GameView`, which is close but is still a second copy of the layout — and a
second copy can drift from the first without either failing. Rendering the
actual `GameView` found two bugs in a minute:

- **The tool row was empty.** `ImageRenderer` cannot measure `ScrollView`
  content — the same trap that had already blanked City Hall — so the most
  important row in the UI rendered as nothing. `ViewThatFits` gets both
  properties: the flat row when there is room, which is the common case and the
  one that renders, and a scrolling row only when the window is genuinely too
  narrow.
- **White bands either side of the tool rail.** Moving the chips into
  `ViewThatFits` dropped a trailing `Spacer`, so the row was only as wide as its
  contents and its background stopped where the last chip did — the window's own
  colour showing through, in a game that is otherwise entirely night.

The mock cockpit render is gone; there is no reason to keep a reconstruction
once the real thing can be rendered, and the reconstruction had already drifted
(it ordered the dashboard's panels differently).

Also pinned: **tile nodes sit exactly where the projection says they do**.
Clicks convert through `event.location(in: self)` — *scene* coordinates — and
`Isometric.position(for:in:)` assumes the projection's origin is the scene's
origin. That holds only because `tileLayer` and the effect node above it both
sit at zero. Give either a position, to inset or centre the map, and every click
silently lands on the wrong tile while the map still looks perfect.

### The UI gets a render, like the art does

`RetroUIContactSheetTests` renders the components to a PNG through
`ImageRenderer`, with no window involved.

Every art decision in this project is reviewed on a render rather than argued
about, and it has caught something every time. The chrome had no such render —
it was only ever checked by running the app, which on this machine means a
remote desktop session that does not reliably hand back a screenshot. It found
its first bug immediately: the treasury tile read
`$1,482,910 +$1,798/tick` as one string, and since these numbers grow without
bound and the line must not wrap, it truncated to `$1,482,910 +$…` — silently
dropping the rate, which is the half a player actually steers by.

### Smooth like butter: everything repeated is a texture

The measured result: a built-out 40×40 city is **2,177 nodes and zero
`SKShapeNode`s**.

`SKShapeNode` does not batch — every one is its own draw call — and `glowWidth`
on a shape costs more still, because SpriteKit renders the stroke more than
once to get it. After the isometric port a built-out map was drawing a shape
node per lot for its ground, a *glowing* shape node per road tile for its lane
line, and three more per moving car, every frame, forever, to produce pictures
that never change.

Everything in that list is discrete and repeats: a lot's ground is one of a
handful of colours, a road's lane line is one of **sixteen** connection masks, a
car points one of two ways. `IsoTextureCache` (formerly
`BuildingTextureCache` — it outgrew the name) renders each once. A thousand-tile
road network draws from at most thirty-two textures.

**The glow comes along inside the texture**, which is the part worth noticing:
the retrowave bloom on the street grid is now free per tile, where before it was
the single most expensive thing on the map. Lane sprites blend additively, so a
straight run brightens where tiles meet and reads as one continuous neon tube
rather than a chain of separately-lit squares — and cars gained headlights and
tail lights, which is most of what makes traffic read as traffic at night.

The guard against regressing this is a test that counts shape nodes per lot
rather than total nodes, because total nodes was never the number that mattered.

### Four things a play session found that no render did

All four were introduced by the isometric port, and all four are the same shape
of mistake: a decision that was right top-down and silently wrong once the
projection changed.

- **The Road button went black-on-black.** `RetroUITheme.accent(for:)` labels a
  tool with `RenderPalette.fullColor(for:)`, and the ground/light split made
  asphalt the *darkest* surface in the game on purpose. Right on the map, wrong
  in a toolbar. The `.empty` guard sitting directly above already documented
  this exact failure for the bulldozer, which is a fair warning that reaching
  for a *ground* colour to label a *tool* was the mistake both times. A tool
  button wants what the zone emits — for a road, its lane-line glow, which is
  also what the player sees when they place one.
- **Water and Power hid the utilities.** The port dropped the top-down
  renderer's dimmed-building pass, so both overlays became flat supply-coloured
  fields with no way to see where the water tower you were routing from stood.
  Buildings are dimmed rather than hidden now, and the utilities that *feed*
  the network being shown stay at full brightness, because those are the things
  the player is hunting for.
- **The placement cursor vanished into the city.** Top-down it was a square
  filling the tile and impossible to miss; the same idea as a diamond lying on
  the ground disappears into a map where every edge is already at one of its
  two angles. It has corner risers now — vertical lines, the one thing nothing
  else on the ground has — so it reads as a volume about to be placed. Its
  `zPosition` was also 5, against tile nodes whose depth key now runs to the
  map's width plus height.
- **Cars became slivers.** A rounded rectangle pointing along the road is
  exactly right top-down. Rotated to a projected heading it is the only thing
  on an isometric map with no thickness, surrounded by buildings that are
  nothing but thickness. They are little boxes built from the same `Box` and
  face-shading as the buildings, so they catch the light from the same
  direction.

The overlays now have a render of their own (`isometric-overlays.png`). They
had been ported and never looked at — nothing failed, there was simply no
picture of them anywhere.

### The bug that froze the game, and why no test caught it

`BuildingTextureCache` rasterises a building by presenting a scratch scene on
an `SKView` and calling `texture(from:)`. The first version took that view as a
*parameter*, and `GameScene` passed its own.

`presentScene` **replaces** what a view is showing. So the first time a lot
actually grew a building, the live game was swapped out for a one-pixel scratch
scene: the map froze, clicks stopped landing, the simulation stopped ticking.
Nothing crashed. Nothing logged.

The symptom ordering is the tell, and it is worth recognising again: placing
zones worked fine, and everything died the moment you pressed play. A zone sits
at density 0 until a tick grows it, and density 0 needs no texture — so the
cache never missed until the simulation started.

**Why the whole suite passed.** Every test handed the cache a scratch `SKView`
of its own and never looked at it again, so the hijack was invisible: the bug
was only reachable when the borrowed view was one somebody was watching. The
tests asserted the cache produced correct sprites, which it did.

Two lessons worth keeping:

- **Do not borrow a shared resource to do private work.** The cache needs *an*
  SKView, not *the* SKView; it owns a private offscreen one now. Anything that
  takes a shared object as a parameter in order to mutate its state is worth a
  second look.
- **A test that supplies the collaborator cannot detect misuse of it.** The
  regression test does not check the sprite at all — it presents a scene on a
  view the renderer was never given, renders some buildings, and asserts that
  view is still showing what it was.

### Rendering cost, measured at phase 2 rather than phase 11

A building costs **~55 nodes in isometric against ~26 in elevation**, and the
first measurement was 104 — caught by a test written deliberately early, when
one zone was ported rather than six.

What brought it down was `ZoneIcon.minimumDetailSize`'s rule applied to
geometry: a cylinder had sixteen sides for a chimney six points wide (now ten),
and chimney caps and tank bands were whole extra volumes for a stripe under two
points tall (now gone — in isometric a tank already reads as a drum because its
top is a real ellipse catching light). Faces too small to survive a 7-point blur
no longer get a glow copy either.

**The real answer is deferred on purpose.** 55 nodes × 560 lots is far more
`SKShapeNode` than a 64×64 map should be drawing, and the fix is not to keep
shaving geometry: it is to rasterise each distinct building once and draw it as
one `SKSpriteNode`, cached by zone, tier and variant. Buildings are static for
their whole lifetime, so this is free. It needs a live `SKView` to render into,
which is why it belongs to the scene phase — and it is what `TileRenderer`'s own
doc comment has predicted all along ("the body of `makeNode` becomes
`SKSpriteNode(texture:)`"). Until then the node count is a number to watch, not
a number to panic about.

### What the spike already established

- Volumes read, the three zones still separate, and lit panels projected onto
  the *face plane* (rather than drawn as screen-space rectangles) are what stop
  an isometric building looking like a crate.
- `heightUnit` is the knob that matters most and must not be tied to
  `tileHeight`: a storey is not as tall as a lot is wide, and tying them makes
  every building squat.
- Node count per building is comparable to the elevation version (three faces
  per box plus panels on two of them), so this is not obviously a performance
  regression — but it should be measured on `HarnessTimingTests` before the
  migration is called done, not after.

## Ground and light: retiring the last of the grayboxing

The buildings were never the thing holding the look back. The *ground* was.

`RenderPalette` opened with the words "Graybox color palette", and its tile
function was documented as "the graybox stand-in for a building appears and
grows": every lot a big flat saturated rectangle keyed to what you had zoned
it, brightening as it densified. That is the correct answer while you are
proving mechanics against coloured squares, and it is a data visualisation, not
a city. It survived the whole art pass because nothing ever forced the
question — and it spent the screen's entire colour budget on a flat field,
leaving the neon nothing to be brighter *than*.

The palette now splits two ideas that had been one:

- **Ground** is what a tile is made of — asphalt and earth at night, near-black,
  carrying a ~8% tint of its zone's hue so a district has a *cast* rather than a
  colour.
- **Light** is what a zone emits — the neon a building is stroked in, its halo,
  and `TileRenderer.syncGroundGlow`, a wide faint additive pool of the zone's
  colour on the ground beneath it.

Zone identity did not get weaker in the trade; it moved from a flat fill into
light, which is both more legible against black and the only version of it that
looks like night. It also survives distance better — when the camera is far
enough out that a building is twenty points across and its silhouette has
stopped resolving, the colour of the light it throws still reads. Analytical
views that genuinely want a colour-coded field still have one: that is exactly
what the overlays are for, and they override the tile fill wholesale, so none of
this touched them.

Three things fell out of it, all of which had been invisible while the tiles
were bright:

- **Asphalt was twice the brightness of bare ground.** Roads are about a third
  of the tiles in a normal grid, so a pavement brighter than the land turned the
  map into a lilac board with dark blocks sitting on it. Asphalt is now the
  *darkest* surface in the game — what makes a road visible is the lane line
  glowing on top of it, and that needs the darkest possible bed.
- **The road network glow was tuned to fight bright tiles.** At its old alpha
  its additive bleed lit the whole board. The brightest thing in frame should be
  a building, not the pavement.
- **The ground pool had to be wide and faint, not tight and bright.** A pool
  sized close to the lot is just the flat colour field again with a gradient in
  it. Spilling well past the footprint at low alpha lets neighbouring lots add
  together instead, so a dense block haloes as a district and no tile edge ever
  shows.

The density pips went too. They existed because "the colour ramp shows growth as
brightness, which is subtle" — graybox reasoning for a graybox problem. Growth
now reads as the building's own tier: a different silhouette, a different hue, a
brighter pool. The one thing genuinely lost is the exact density *number* within
a tier, which no game in this genre puts on the map anyway.

### Brightness is a channel, not a constant

Every building used to glow exactly as hard as every other, so a two-storey
house and a tier-3 tower carried identical visual weight: the map read as
uniformly busy rather than as a place with a centre. `ZoneIcon.glowIntensity`
ties halo weight to growth tier (0.55 / 0.78 / 1.15), with a small per-building
`liveliness` wobble on top so a row of same-tier lots is not a row of identical
lamps. Density is now legible from further out than the silhouette survives,
and the eye has somewhere to land.

One experiment from that pass is worth recording as a *failure*, because it
looked obviously right on paper. Lit windows were given SpriteKit's built-in
`glowWidth` halo, on the reasoning that a window should read as a light source
rather than a patch of paint, and that `glowWidth` costs nothing extra because
it is a property of a node already being drawn. It made everything worse: the
halo is far more aggressive than it sounds, at 2.5 on a nine-point pane it
roughly doubles the pane, and a facade of them became overlapping blurry
lozenges with the dark silhouette between them washed out. Halving it did not
save it — the whole point of `minimumDetailSize` is crisp marks with black
between them, and bloom on small shapes is the same mistake as detail on small
shapes wearing a different hat. Reverted; the glow belongs on the silhouette
stroke, where the shape is big enough to carry it.

### The render has to include the post-process

`RetroShader` only ever multiplies brightness down — scanlines up to 11%, the
vignette up to 35% at the edges — and those values were picked when every tile
was a saturated fill with headroom to lose. A render without it is a render of a
frame the game never draws, and "is the dark palette still legible once the
post-process crushes it" is precisely the question a change like this has to
answer. `ZoneStreetscapeTests` runs each panel back through the real shader.

### The yardstick must not reimplement the thing it measures

The streetscape used to build each lot by hand: a flat zone-coloured plate with
an icon on it. That was a faithful picture of the renderer right up until the
renderer changed — every mark carrying the new look was invisible, because the
test did not know those marks existed. It renders through
`TileRenderer.makeNode(for:)` now, the same call `GameScene` makes, and streets
go through it too rather than being painted by the composer. Streets are half
the picture, and a render showing flat asphalt while the game drew a glowing
network was measuring something else.

## Detail has a floor, and the theme has a budget

The first generated buildings were reviewed on a contact sheet at 132 points a
cell and on a streetscape at 128 points a lot — and both flattered the art
badly, because **that is the rarest view the game ever shows**. `GameScene`
draws a 32-point tile and its camera ranges 0.5–3.0, so a 2×2 lot is 126 screen
points zoomed all the way in, 63 at rest, and about 21 zoomed out. One
design-space point is therefore 1.26, 0.63 and 0.21 screen points. A 5-point
window is three points of screen at rest and a single pixel zoomed out: not
small, *absent*.

Judged at rest, the window grids, mullions, railing posts and frame lines were
a grey speckle. They did not add detail; they averaged the facade toward mud
and muted the neon, which is the one thing this art direction cannot afford.

`ZoneIcon.minimumDetailSize` (9 points, ~6 of screen at rest) makes the floor
explicit, and the rule that follows is: **if a mark cannot be drawn at least
this big, cut it rather than shrink it.** A building carried by four bold lit
blocks reads at every zoom; the same building carried by twenty faint ones
reads at exactly one.

What that changed, and it is worth reading as a list of what *survives* a
downsample versus what does not:

| cut | kept, and made bolder |
|---|---|
| 1.4-point glazing mullions | the glazing band itself, 9–12 points thick |
| 1.6-point shopfront door mullions | the shopfront as one unbroken slab of light |
| 1.2-point balcony railing posts | the balcony band, 5 points and full width |
| 3-point storey slab lines (near-black on near-black) | the setback, which already reads as the break |
| window frames on grid panes | flat, fully saturated panes, ~1/3 as many and much larger |
| unlit industrial bays painted near-black | only the lit bays, as real blocks of light |
| a third, desaturated "cool white" window hue | two saturated hues, cool and warm |

Two things got *more* weight rather than less, because they are what carries
the theme at every zoom: the silhouette stroke (2.5 → 3.5) and its glow halo
(line 4 → 7, blur 5 → 7). Neon is an edge and a bloom. Those survive being
scaled to a fifth; a hairline does not.

Two calibrations were needed after, both caught on the streetscape:

- **Thickening a band and keeping it full-width swallows the building.**
  Commercial towers became stacks of fat light bars with no facade between
  them. The bands are inset 17% now; the dark margin either side is what makes
  them read as glazing *in* a wall.
- **Fewer cells means an independent per-window roll can turn them all off.**
  A narrow house in a row gets a single column, and some came out with no light
  in them at all. One window per volume is now always lit.

**The process lesson, which is the general one:** art has to be reviewed at the
size it is played at, not the size it is comfortable to draw at. The streetscape
render now emits all three zoom levels in one image for exactly this reason —
the earlier single-panel version is what let this ship.

And one long-standing placement bug the new forms exposed. Icons are authored
from a ground line at `y = -40` upward, so a tall tower's drawn frame happens to
straddle its origin while a short one — a strip of shops, a row of houses, an
industrial shed — does not. `TileRenderer.fitIconToTile` measured the frame in
order to *scale* by it but then left the icon at its origin, so short buildings
hung a quarter of a lot below their tile, overlapping the neighbour. It now
recentres on the measured frame as well, which is why every building on the
contact sheet suddenly sits square in its cell.

## More buildings, and a fire that is on theme

Two halves of one request: more variety in what a city is made of, and a fire
that looks like it belongs in this game.

### The ceiling was the cache, not the generators

The obvious move was to write more forms for the growable zones. Measuring
first said not to. Counting *distinct* massings over the seeds the game
actually uses — `IsoTextureCache.canonicalSeed`, not arbitrary ones — the
three growable zones came back at **14–16 out of a possible 16**. The
generators were not the constraint; `variantCount` was, and every extra branch
written into `ResidentialMassing` would have been quantised straight back out
again.

`variantCount` is **32** now. Raising it costs textures and nothing else: a
built-out 40×40 city went from 48 to **93 textures with the node count
unchanged at 2,177**, because a texture is shared by every lot that draws it
and a lot is one sprite either way. At 32 the generators still do not
saturate — R/C/I read 21–32 distinct — so this is headroom, not a new ceiling.

### The gap was the services you build in numbers

With the cache opened up, the same count named the real problem. Police 26,
hospital 25, generator 24, power plant 22 — a service a city has two of, doing
fine. And then **park 4, bus stop 3, tram stop 3, subway 3, rail station 3**.

Those are exactly the buildings a city has *dozens* of, and they were flat for
one reason: each varied its dimensions and nothing else. This file already
states the rule — **"varying numbers is not variety; varying the building
is"** — and it had been applied to the growable zones and never to the
services that tile a map alongside them.

The variety bar being lower for services is still right, and it is why the
fire station was left alone. What was wrong was treating "service" as one
category. A city has two fire stations and thirty bus stops; the second is in
the park's position, not the firehouse's.

Each now picks a **form** first:

| | forms |
|---|---|
| park | a grove, a lit pond, a bandstand, a ball court |
| bus stop | an open shelter, one with a backed ad wall, a twin-bay shelter — half of them with a flag at the kerb |
| tram stop | one island, paired islands under a catenary boom, an island with a screen wall |
| subway | a headhouse, an open stairwell, an entrance tower |
| rail station | a pitched train shed, a terminus with a head building, an elevated viaduct |

Measured over the same 32 seeds: park 4 → **11**, bus 3 → **11**, tram 3 →
**9**, subway 3 → **9**, rail 3 → **15**.

**What stays fixed is the identity mark**, which is what these icons are for —
a player scanning a corridor for coverage gaps has to know what they are
looking at before they notice it is a different one. A bus stop is always a
canopy on posts; a tram stop is always a kerbed island with a lit edge and a
mast; a subway always has a lit mouth at ground level; a rail station always
has long lit platforms. The forms vary everything else.

Three things the contact sheet decided, and the counter could not:

- **Two of the tram forms did not read apart at all.** Paired islands 0.2 tile
  wide with a fifth of a tile between them merge into one island the moment
  the camera pulls back, so the count said three forms and the picture showed
  one. The fix was a **catenary boom** — a horizontal at the top of the
  silhouette, where the other two have only a mast head. `minimumDetailSize`'s
  argument applies to massing exactly as it does to marks: a distinction that
  cannot survive the downsample is not a distinction.
- **The screen wall had to out-top the mast.** At its first height it was a
  detail on an island; taller than the mast it is the tallest thing in the
  silhouette, and that is what tells it apart.
- **The pond is the best of the four parks** and it is the one with no
  vertical mass at all — a lit blue surface where everything else in the game
  is a lit edge. `NeonStyle.waterAccent` exists for it: deeper and bluer than
  `litAccent`, which is the glow *of* a window rather than a thing you could
  fall into.

### The fire is a sunset now

`emberColor` alone never worked and this file has said so since fire spread
landed: an industrial building is already orange, so an orange flame on a
factory is a mark competing with its own background. The answer then was to
give fire a *silhouette* no zone has — a plume above the roofline — which
fixed legibility and left the colour problem in place.

`NeonStyle.sunsetFlameTexture` fixes the colour by refusing to pick one. The
plume is filled with the whole retrowave ramp — white-hot at the base through
yellow and ember to hot magenta at the tip — cut by horizontal slats. **A
gradient cannot be swallowed by any one zone, because no zone owns more than
one end of it.**

It is also the synthwave sun, run upside down: on the sun the slats widen
toward the bottom where the disc meets the horizon, on a flame they widen
toward the top where it breaks up into the air. Same motif, and it happens to
be what fire actually does. The most urgent thing on the map is now drawn in
the palette the rest of the map is dressed in, rather than in a warning colour
borrowed from somewhere else.

Around it: two additive pools rather than one — a wide magenta halo with the
ember pool burning inside it, so the lot haloes in two colours and stays
legible on any ground in the game — and four embers rising on their own beats.
This is the one place in the renderer where additive light summing to white is
the *intended* result rather than the bug recorded three times over in the
conduit, route and tram-track passes: a fire has a white-hot centre.

Two corrections the magnified render made, neither of which the code could
have flagged:

- **It was as wide as it was tall, and read as a lamp on the roof.** Narrower,
  taller, and closed across a notch between two licks instead of a straight
  line, it reads as something coming *out* of the building. Proportion is what
  carries the mark, since at the zoom this game is played at the gradient
  inside it is four pixels wide.
- **The white core blew out the bottom third of the gradient** — 0.7 of a tile
  at alpha 0.95 flattened the flame's hottest section, and the roof under it,
  to paper. Half the size at 0.6 alpha keeps the ramp visible and still reads
  white-hot.


## The visual overhaul (in progress)

Aimed at "App Store ready", and the first finding was that **the art
direction is not the problem**. The neon isometric look is coherent and
photographs well. Two things hold it back, and neither is the style:

- **The city floats in a void.** It is a diamond island on flat near-black,
  with no ground beyond it, no horizon and no context — a diagram on a
  desktop rather than a place at night.
- **The value structure is inverted.** Everything runs at peak saturation at
  once, and the brightest thing in frame is the pavement.

The plan is six phases, one commit each so any can be reverted on its own:
value structure, a world beyond the map, terrain, contact and depth, life,
and the frame (title screen, icon, screenshot camera). Terrain is the
expensive one and is a player choice at new-game time rather than a change
forced on every city — see below.

### Phase 1 (done): the value ladder, and a switch to compare two of them

A well-kept lane line drew at **alpha 1.0, additively, in full-saturation
magenta, with a glow** — on about a third of the tiles in a normal grid. So
the street grid was the brightest thing on the map everywhere at once and the
buildings, which are the subject, had to compete with the road they stand on.

This file already recorded that exact fix once, when the ground stopped being
flat coloured tiles: *"the brightest thing in frame should be a building, not
the pavement."* It drifted back. The ladder is now stated as data rather than
as a sentence, so it can be asserted:

| | |
|---|---|
| ground, asphalt | near-black — the bed everything else is bright against |
| lane lines | dim neon: infrastructure, everywhere, must recede |
| building silhouettes | the mid tones |
| lit windows, signage | bright — the thing you are looking at |
| fire, flagged problems | peak — nothing else is allowed up here |

A highway keeps more of its brightness than a street, which is also the first
time the two have differed by anything except hue and width: an arterial
should read as the bigger road from across the map.

**The contrast had to be bought at the bottom, not the top**, and finding out
why is the useful part. `IsometricBuilding.glowLayer` ends in
`alpha = min(1, 0.85 * intensity)`, so the channel saturates at an intensity
of about 1.176. The first attempt raised the top tier from 1.15 to 1.40 and
moved its alpha from 0.978 to 1.0 — which is to say it did nothing; only the
glow's *width* kept scaling, and width is not brightness. So the top sits just
under the clamp and the low tiers come down instead, widening the
tier-3-to-tier-1 ratio from 2.1× to 2.8×. That is the better version of the
idea anyway: a night skyline is mostly dim with a few things blazing.

`VisualStyleTests` pins the clamp, and caught 1.18 being 0.3% over it.

#### Why there is a switch

How a look *feels* while you play in it is the one art question a render
cannot answer, and it is not a question a test can settle either.
`VisualStyle` holds two sets of numbers — `classic` is exactly what the game
looked like before, `cinematic` is the graded version — and Simulation ▸
Visuals flips between them live.

Deliberately **not** the shape a permanent theming system would take. Two
structural renderers kept alive forever would double the cost of every
feature after them; this holds two sets of *numbers*, which is cheap, and is
expected to collapse to one once the question is answered.

**A style change needs more than a rebuild.** The palette is baked into every
cached texture — that is the entire point of `IsoTextureCache` — so switching
without purging would move the handful of values read live (a lane's alpha)
and leave every building drawn in the style just switched away from. Nothing
would *look* broken, which is worse: the toggle would appear to do almost
nothing. `GameScene.restyle()` purges, rebuilds and refreshes, and does not
recentre the camera, because the map has not changed and a camera that jumps
under a player comparing two looks is its own bug.

`VisualStyleTests` exists because this project has twice shipped a control
that compiled and did nothing — `SKAction.colorize` on a plain node, and an
overlay tint casting to a type the ground had stopped being. It asserts the
street actually comes back dimmer, and that the cache hands back a *different*
texture after a restyle rather than the one it baked in the old style.


### Phase 2 (done): the city sits in a landscape

Everything outside the map was the scene's flat background colour, so a city
read as a diamond island floating on nothing — a diagram on a desktop rather
than a place at night. The single biggest thing holding the look back, and it
was never a styling problem: there was no world there.

The ground now carries on past the map's edge — the same isometric grid,
unclaimed and unlit, fading out with distance. The city is somewhere *in* a
landscape, and its boundary reads as where your land stops rather than where
the drawing stops. It also finally gives the sun something to light: that
glow has been parked below the map since the art pass and had nothing but
void to bleed into.

**Bounded rather than infinite, and that is affordable because the camera is
already clamped.** Panning cannot wander off into open space, so the backdrop
only has to cover the map plus a generous margin — one sprite and one
texture, no shader and no tile map.

The grid is drawn by **projecting real tile coordinates** rather than working
out where the lines fall on screen. A second implementation of the projection
would line up until the day it did not, and a backdrop grid a half-tile out
of step with the city standing on it is worse than no grid at all.

Three corrections, all of which needed a picture:

- **Lines are not ground.** The first version drew only the grid, at an alpha
  low enough to be tasteful, and it vanished — the city still floated. What
  makes somewhere look like somewhere is that it has a *value*, however dark,
  which the neon then sits on. It is a filled surface with a grid ruled
  across it now.
- **Ruled every four tiles, not every tile.** At the zoom a player plans at, a
  36-tile margin of one-tile diamonds collapses into a moiré quilt that fights
  the city instead of sitting behind it. The coarse pitch reads as large
  unclaimed parcels. Same `minimumDetailSize` argument the buildings already
  follow: a mark too small to resolve is not detail, it is noise.
- **The fade holds and then drops** (`[0, 0.72, 1]`) rather than falling off
  from the middle. The land nearest the city is the part doing the work.

#### The city render cannot see scene-level art

Worth recording because it cost a confused round-trip and it affects
everything still to come in this pass. `IsometricCityTests.render` builds a
**plain `SKScene`** of its own and calls `IsoTileRenderer` directly — it never
constructs a `GameScene`. So it cannot show the backdrop, and it turns out it
has never shown the sun either. Two rounds of tuning the backdrop produced
pixel-identical renders before that was noticed.

That is the same shape as the mock cockpit render this file already retired:
*a reconstruction can drift from the thing it reconstructs, and neither
fails.* The city render is still the right tool for **tiles and buildings**,
which is what it draws. Anything that lives on `GameScene` — the backdrop, the
sun, the camera, the shader pass — has to be judged on `ScenePlaytest`'s
filmstrip, which photographs a real `GameScene` on a real `SKView`.

`VisualStyleTests` now also asserts the land exists, extends well past the
map, sits behind it, and survives `rebuildEntireGrid()` — none of which any
existing test would have noticed going.

### Phase 4 (done): things sit on the ground

Phase 2 gave the city land to stand on; this is what makes it look like it
is standing on it, at two scales.

**A building lights the ground at its feet.** Buildings had a wide, faint
pool of their own colour — 1.7× the footprint at alpha 0.13 — which reads as
the light of a *neighbourhood* and says nothing about where any one building
stands. They hovered.

The obvious fix is wrong on this map. Contact normally means a shadow, and a
shadow means darkening the ground — but **this ground is already near-black,
so there is nothing left to take away.** At night the real cue runs the other
way: a lit building spills onto the pavement hardest right at its feet. So
contact here is a *bright* mark, tight to the footprint (1.02×), under the
wide pool rather than instead of it. The two together give the falloff — hot
at the base, fading across the lot — that makes a thing look planted rather
than pasted on. Same texture and blend mode as the pool, so it costs a node
and no new draw call.

Worth keeping as a general rule: **on a dark ground, occlusion has to be
expressed as light rather than as shadow.**

**And the claimed land reads as a plate laid on the wild land.** The macro
version of the same idea: without it the map is a differently-coloured region
of one flat surface. Filling the map's own diamond *with a shadow set* spills
a soft dark fringe down-screen past its edge — the only part that shows,
since the map's tiles cover everything inside it.

That fill has to happen **before** the radial fade, and it is worth saying why
out loud: the fade leaves the context in `.destinationIn`, so a plate drawn
after it does not shade the land, it erases everything outside the plate. The
first version did exactly that, described itself in a comment as being before
the fade, and was not.

Node cost went from ~2.6 to ~3.6 per lot, against the standing bound of 6.
Shape nodes are unchanged at zero, which is the number that actually matters.

**Atmospheric perspective was considered and dropped.** A distance fade is the
textbook third cue, and on a map this size it trades a real gameplay property
— being able to read the far side of your own city — for a subtle one.
`RetroShader`'s vignette already supplies a little of it for free.

### Phase 5 (done): the city breathes

A still city at night reads as a diorama. What sells a place as inhabited is
that some of it changes while the rest holds.

**It is the light already there that moves, not a new mark**, and the first
attempt getting that wrong is the useful part. It hung a small blinking
beacon above every tall roof — an aviation light on housing and industry, a
marquee on dense commerce — and it failed twice over:

- **It was indistinguishable from the building's own lit crown.** A soft
  additive blob on top of a tower that already ends in a lit crown is just
  more crown.
- **It was about three screen points.** At the zoom the game is actually
  played at, a 0.12-tile dot is under `NeonStyle.minimumDetailSize`, which
  says to **cut a mark that cannot be drawn big enough, not shrink it**. The
  rule was written for facade details and applies identically here.

So the pulse went onto the contact light instead — a mark that is already a
whole lot across, survives every zoom, and costs no node at all. A shop's
sign works harder than a window does, so commerce flickers faster and further
(34%) than everything else (16%), which is a slow swell you notice across a
block rather than on one building.

The beat and its phase are seeded from the lot's own position, so a row of
towers does not pulse as one. Same reason `BuildingRandom` seeds from
position, and the same reason the fire's flicker sums beats of different
length.

Kept deliberately shallow: this is meant to be *felt* rather than watched. A
map of lights visibly throbbing is a screensaver, not a city.

The contact light joins `animatedBySimulation`, so it stops when the city
does — the same side of that line as the traffic, and the opposite side from
a placement flash, which answers a *click* and therefore has to keep running
while paused or it would never fade away.

### Phase 3 (done): the land has a shape

Every map this game ever generated was the same flat, featureless plane,
which is most of why every city looked alike: the *shape* of the land is what
makes one place different from another before a single lot is zoned.

**A choice at founding, not a change forced on every city.** `Terrain.flat`
is exactly what the game did before and stays the default, and because water
rides on `Tile` as an Optional, every save written before this loads as dry
land — `decodeIfPresent` again, no format bump, nobody's city changes under
them. The same trick `damagedBy`, `constructionRemaining` and `fireTicks`
already use.

Four shapes, and a seed so a coastline you like can be written down and got
back: **flat**, **coastal** (sea behind a ragged shoreline), **lakes**
(inland, clear of the edges) and **river** — the one that cuts the map in
two, which is the whole reason bridges exist.

#### Bridges, and what may cross

Only **roads** cross water, at three times a road's own price per span. That
is deliberately not a general "build on water for more money" rule: a river
is meant to constrain where a city can go, and it stops constraining anything
the moment anything can be dropped in it. What a bridge buys is a *route*,
and routes are what roads are for. Mains and power lines cross **under a
bridge**, never through open water — the mirror of the simplification
`Infrastructure` already makes, where one tile carries the road and whatever
is buried in it.

The acceptance test is the one that matters and it goes through the router
rather than through geometry: homes on one bank, jobs on the other, and
`Traffic` reports nobody employed until a span goes in.

**One bug this nearly shipped.** `CityMap.placeBuilding` builds a *fresh*
`Tile`, carrying `hasPipe` and `hasPowerLine` forward by hand — so a bridge
would have quietly dried out the river underneath it, and bulldozing one
would have handed back dry land. `isWater` now carries forward for exactly
the reason `hasPipe` does: it is a property of the ground, not of what stands
on it.

**And one stale expectation of my own**, worth recording for its shape.
`testWaterRefusesEveryPlacement` was written before bridges and listed
`.road` among the tools water turns away. Bridges made that false, so the
thing moved and the yardstick had to follow — restated as
`testOpenWaterRefusesEveryPlacement` rather than relaxed, since what roads
may do is pinned separately. It failed instructively too: the road
*succeeded*, which turned the tile into a bridge, and the pipe and power
assertions after it then legitimately passed. **One stale expectation
produced three failures, only one of which was about itself.**

#### Waterfront is in the `max` group, not added like a park

The balance decision worth recording. A park is *additive* because it is the
one tool a player has for making a block nicer, and a second additive
positive would dilute the thing parks exist to be. Nobody builds a river, so
water competes to be the best thing near a lot rather than stacking on top of
whatever already is. The effect that matters survives: on a fresh coastal map
the shore is where a city wants to start, and beside a police station the
water adds nothing — which is correct, because by then the block is served.

Water needed its own channel in `ZoneDistanceField`, since it is not a
`ZoneType` and `LandValue` runs per footprint cell per tick — a scan would
land straight back on the `O(tiles²)` path that type exists to delete. The
two-sweep transform is now taken over a *predicate* so water shares it
exactly rather than getting a near-copy.

#### Founding became a panel

"New City" was a menu of three map sizes, which was fine while size was the
only question. Size × terrain is a twelve-item matrix, and this project has
watched the tool rail and the overlay row outgrow their containers twice
already. `NewCityPanel` is also the first screen a new player meets, and
"pick 32×32 / 48×48 / 64×64" is a poor opening line for a game about building
somewhere — a panel can say what a coastline *is*, which is why each terrain
carries a one-line summary. River's is load-bearing: you should know the map
will be cut in two before you find out by building into it.

It has a render from the start, because City Hall shipped two bugs while it
had none. That render immediately earned itself twice: the body defeated the
Swift type checker outright as one expression ("failed to produce diagnostic
for expression", which is SwiftUI's way of saying a view is too big to
infer), and the three panels stacked up at three different widths because
`RetroPanel` sizes to its content — three unrelated boxes rather than one
form.

### Three things a play session found

#### The Traffic view hid the traffic

*"The traffic overlay should still show cars and you should be able to place
roads and highways while in the overlay."* Two complaints, one cause.

`applyOverlay` strips every decoration including the lane lines, and
`syncTrafficAnimation` removed the cars under any overlay at all
(`overlayMode == .none`). So the Traffic view — a heatmap **of the street
network** — was the single view that drew neither the streets nor the traffic
on them.

The second half follows from the first and is the more misleading of the two:
roads placed in that view were landing correctly the whole time. They were
just never drawn, which a player cannot tell apart from a click that did
nothing.

`OverlayMode.showsRoadNetwork` names the exception. A heatmap normally hides
the buildings because the data *is* the picture and the city on top is
clutter; traffic is the case where the thing being measured is the streets,
and a congestion map you cannot see the streets in measures nothing you can
act on. It rides on `OverlayPaint` rather than being read from the mode at
each call site, for the same reason `paint` exists at all — the last time
that decision lived in two places, three heatmaps silently painted nothing
while the render cheerfully reported they were fine.

#### A warning that says what is missing

*"I think we should add an icon that indicates if a building is missing power
or water rather than the little indicator we have currently."*

The badge was a small outlined disc with an **identical vertical bar** inside
it, drawn in the utility's colour. So hue was the only channel distinguishing
"no water" from "no power" — and this project has twice written down what
that costs, most recently when an ember-coloured fire turned out to be
invisible on an already-orange factory. Water's blue and power's icy white
both sit on top of the neon the city is drawn in.

A **drop** and a **bolt** are the genre's own symbols and need no legend.
They also forced the badge to grow: the old disc was ten points across, right
on `NeonStyle.minimumDetailSize`, so a glyph inside it had no chance of
resolving. The colours did not change — power's icy blue-white is deliberate
("a lightning bolt, not a warm colour") and correct; the point is that the
glyph now carries the meaning so the hue no longer has to.

Cached in `IsoTextureCache` like everything else that repeats: two textures
for the whole game, against an `SKShapeNode` with `glowWidth` per warned
building.

Two things this needed:

- **The drop rendered as an up-arrow.** `addArc(..., clockwise: false)`
  sweeps 0 → π/2 → π with y up, which bulges over the *top* and cuts the
  belly off. Clockwise puts it underneath.
- **It had never been looked at.** `syncUtilityWarning` is called from
  `GameScene` and nowhere else, so the city render has never drawn it and no
  test had ever seen it — the same blind spot the backdrop had. It has a
  scene render now, showing all three states (water, power, both) together,
  because the question is whether they are *distinguishable*, which one badge
  at a time cannot answer.

#### The route cursor was lying

*"It could be more apparent that you're selecting a valid stop when making a
route."* It was worse than unclear.

While a line is being drawn a click names a **station**, but the placement
preview went on describing whatever zoning tool happened to be armed — and
its test is `wouldReplaceSomething`, which is true of every building on the
map. So the bus stop you were meant to click was drawn in the *blocked*
colour: the one tile that works, marked forbidden.

The cursor now answers the question the click will actually be asked, and
wraps the whole station rather than the tool's footprint, so a 2×2 rail
terminus lights up as one thing.

`updatePlacementPreview` was split from its `NSEvent` to make that testable —
the third time this pass has needed that split (`place(at:)`, `dragTo(_:)`),
and the same lesson each time: **what the cursor says is logic, and logic
nothing can drive is logic nothing can check.**

### Phase 6 (in progress): the frame

#### A title screen

The app booted straight into a city, which is what a prototype does. A game
opens on something that tells you what it is — and for the App Store it is
also the one screen that has to survive being a thumbnail.

**Drawn rather than photographed.** Putting a live `GameScene` behind the
title was tempting, since the game already renders a city and it looks good.
But a title screen is *composed* — a horizon at a chosen height, a sun in a
chosen place — and a real city is an isometric diamond that sits wherever the
map is. This is the one picture in the project that gets to be a poster
instead of a simulation, so it is a `Canvas`: a synthwave sun over a receding
grid, the image the whole art direction has been quoting from since the
start. It uses `NeonStyle`'s own colours rather than new ones, so the title
and the game are unmistakably the same thing.

The sun's slats run the **right way up** here — widening toward the bottom,
where the disc meets the horizon — where `NeonStyle.sunsetFlameTexture` runs
the identical motif upside down for fire, because that is what a flame does
as it breaks apart. Same idea, two readings.

Three things the render caught, and it caught all three on the first look:

- **The slats did not punch through.** They were drawn with a
  `.destinationOut` pass inside a `drawLayer`, which silently did nothing —
  the sun came back a solid gradient blob, which is a sunset from any decade.
  Subtracting them from the disc's `Path` is one call and cannot fail
  quietly.
- **Blurring the disc turned it to haze** and took the slats with it. The
  bloom is now its own soft copy *behind* a crisp disc — the same split the
  buildings already use.
- **A flat ground fill met the sky's last gradient stop** in a hard seam
  straight across the frame. The ground fades out of the horizon instead.

`RootView` is the seam between title and game; `CityDocument.isShowingTitle`
owns it, because which screen you are looking at is a statement about the app
rather than about the city. **Simulation ▸ Main Menu** goes back, since a
title screen you cannot return to is a splash screen. "Continue" appears only
once there is a city worth returning to — on a first launch the map is empty
and it would be a third button saying "New City".

#### The app icon

The icon that shipped predates the entire art direction — this file records
it as an explicit exception to the grayboxing rule at the time, on the
grounds that an icon is chrome *around* the game rather than game art. That
was fair then and stopped being fair the day the game became isometric: the
old icon is a **flat front-elevation skyline**, which is precisely the "two
viewpoints in one picture" mismatch the whole projection change existed to
fix. It was a picture of a game this is not.

What survives is the sun, because the sun was always right — and it is now
literally the same sun as `TitleScreen`, slats and all. What replaces the
skyline is a handful of isometric blocks drawn from `RenderPalette`'s own
zone colours, as near-black faces with a neon edge, which is how the game
draws every building.

**It simplifies as it shrinks**, which is the part that makes it an icon
rather than a picture. Five towers overlap into an indistinct dark smudge at
16 and 32 pixels, so below 64 it draws **one**, silhouetted against the disc;
the slats drop out below 64 too, and the neon edge below 48. Same argument
`NeonStyle.minimumDetailSize` makes about facade details: a mark that cannot
be drawn big enough is cut, not shrunk.

**Generated rather than authored.** An icon has to be a raster asset, which
makes it the one place this project cannot avoid shipping PNGs — but it does
not have to make them a mystery. `AppIconTests` writes every size in the
asset catalogue from code, into the source tree deliberately: the drawing is
deterministic, so the bytes only change when the art does, and a palette edit
shows up as a diff on the icon. The icon cannot silently fall out of step
with the game the way the one it replaces did.

Two mistakes worth recording, because both are the *same* mistake made twice
in two different APIs:

- **The slats were punched with `.clear` inside a clip**, which does not
  reveal the sky — it removes the pixels, and the icon came back striped with
  holes. Exactly what `TitleScreen` had just recorded about its own
  `.destinationOut` attempt. Subtracting the slats from the disc's `CGPath`
  is one call and cannot fail quietly.
- **Only the sky was painted.** Everything below the horizon was left
  untouched, which in a bitmap with an alpha channel is not "dark", it is
  *nothing* — the first icon had a white bottom half.

#### The screenshot camera

An App Store listing is mostly screenshots, and a screenshot of this game
with the cockpit in it is a screenshot of a *toolbar* — the tool rail and the
dashboard are between a third and a half of the window, and they are the half
nobody is buying. **Screenshot Mode** (⇧⌘K) strips all of it, the inspector
and route editor included: a panel floating over an otherwise clean frame is
worse than the full cockpit, because it reads as something left switched on
by accident.

**Capture Screenshot…** (⇧⌘P) writes the PNG itself rather than leaving it to
the OS, which is both higher fidelity than a window grab and the only route
that works at all over the remote session this project is usually driven from
— `screencapture` fails there, as does accessibility scripting against the
menu bar.

Two constraints worth recording:

- **It captures from the live view, not an offscreen one.** Rendering this
  scene into a second view to get a larger image would swap the running game
  out from under the player: `presentScene` *replaces* what a view is
  showing, and this project has already shipped that exact bug once, when the
  texture cache borrowed `GameScene`'s own view and froze the map the first
  time a building grew. A capture takes the backing scale it is given, which
  on any Mac worth screenshotting on is already 2×.
- **It includes the shader pass**, because the scanlines and the vignette
  *are* the look. A capture without them would be a picture of a frame the
  game never draws — the same objection `ZoneStreetscapeTests` records about
  reviewing art without the post-process.

The menu cannot reach the scene (it is private to `GameView`), so the command
bumps `screenshotRequests` and the view does the work — the same shape
`cityGeneration`, `manualAdvanceRequests` and `restyleRequests` already use.

That completes phase 6, and with it the six-phase visual overhaul.

## Traffic, and the thing that was never on the lines

Reported as wanting a turn on how cars look. It turned into three changes and
one real bug.

### What is on the street depends on what is beside it

Every vehicle was the same vehicle — one texture per axis, so a street
outside a factory carried the same hatchback as one outside a tower block.
Traffic is one of the few things on this map that *moves*, which makes it one
of the few places variety is watched rather than glanced at.

Roads running past industry now carry **lorries** (longer, taller, a separate
box body so they read as freight from the silhouette rather than the colour);
elsewhere they carry cars. Seeded from the tile, so a street keeps its own mix
instead of reshuffling on every refresh, and mixed with the car's index so
three vehicles on one tile are not three of the same thing.

### A jam that looks like stopping

Congestion already changed how many cars a tile has and how slowly they
cross, and **neither of those reads as a brake**. Above two thirds — exactly
where `Traffic.carCount` adds its third car, so the street gains a vehicle and
turns red in the same moment — the tail lamp goes hot red and larger. One
more texture variant rather than a node per car.

### Something actually running the line

The transit module has four modes, routes, ridership, capacity and a
transfer graph, and until now **nothing ever moved along a line**. The lines
were a diagram, and the only evidence a route carried anyone was a number in
a panel.

A vehicle now runs each working route, paced off that mode's own
`minutesPerTile` — the same constant the router weighs journeys with, so a
subway visibly outruns a bus over the same stations rather than being told to
by a second number that could disagree.

**Only in the route's own view**, which is honest rather than timid: a route
here is schematic, a straight run between stations rather than a path along
streets, so a bus cutting diagonally across blocks would be a lie in Normal
view. Over the diagram it is exactly what the diagram means. (Trams are the
one mode with a real path — `Transit.tramTracks` already follows roads — so
running a tram on its actual rails in Normal view is the obvious next step.)

It joins `animatedBySimulation`, and needed one thing the cars did not: the
pause walk only visits **tile** nodes, and a transit vehicle hangs off
`transitDiagramNode`, a sibling of `tileLayer`. A bus still running its line
around a stopped city is the cars-keep-driving bug one layer up.

### And the tram and rail views drew no lines at all

Found while adding the above. `syncTransitDiagram` switched on `.bus` and
`.subway` with a `default: return` — written when those were the only two
modes, and never revisited when tram and rail landed. **Routes in either were
invisible in their own view.**

Nothing failed, and the reason is worth keeping: every existing test asks
`IsoTileRenderer.transitDiagram` directly, and the *renderer* was always
right. It was the scene's dispatch that had gone stale. `OverlayMode` already
answers "which line is this view drawing" — this was the fifth copy of that
question, and `view(for:)` was introduced to kill four of them and missed
this one.

### A third mark nothing could see

Cars are drawn by `GameScene` and by nothing else, so the city render has
never shown a single one — the same blind spot as the backdrop and the
utility badge, now three for three. There is a scene render for traffic now,
and it is framed **at the zoom the game is played at** rather than the zoom
that fits the map: a car is about eleven points across at camera 1.0 and half
that with the whole city in frame, and reviewing vehicles at the second one is
precisely the mistake `minimumDetailSize` was written about.

One honest limit of that render: `SKAction`s do not advance in a headless
capture, so a still cannot show a bus part-way along its route — it sits at
its first stop, which is where it starts. The vehicle is covered by tests
instead, and judged in the running app.

## Putting the GPU to work

The GPU was doing almost nothing. `RetroShader` was the only shader in the
project — one fragment pass over the finished frame doing scanlines, a
vignette and chromatic aberration — there were no particles anywhere, and the
neon glow was not a GPU effect at all: `CIGaussianBlur` **baked into each
texture once** at rasterisation time.

Meanwhile the CPU is the bottleneck (`Traffic.computeLoad` is ~90% of a tick).
So there is real GPU headroom, and spending it is close to free in a way CPU
work is not.

### First, something to measure with

This project measures simulation cost carefully and had measured *rendering*
cost exactly once, as a node count — which is a proxy for draw calls and says
nothing about what a shader spends. That was fine with one cheap pass over
the frame. It stops being fine the moment the plan is "put the GPU to work":
without a number, "it looks better" and "it dropped to 40fps" are
indistinguishable from outside.

`RenderTimingTests` times `SKView.texture(from:)`, which forces a real render
through the same draw calls and the same shader. **A relative instrument, and
it says so**: it is a synchronous off-loop render, so it misses presentation
and vsync entirely. Every number is a comparison, never a frame rate.

**Its first version was not usable, and fixing it is the point.** It timed
thirty frames once and reported the mean, and the same bloom pass — a fixed
per-pixel cost over a fixed 1280×800 frame — came out +5.4 ms at 32×32, +1.2
at 48×48 and +2.5 at 64×64. A cost that must be flat measured as anything
but, which means the noise was larger than the signal.

The fix is the general one for timing under contention: **every sample is the
true cost plus whatever else the machine was doing, so the distribution has a
floor and no ceiling.** The minimum of several batches is the honest
estimator and the mean is the one thing not to take. Three batches of sixty,
report the best.

### G1 (done): bloom, and the first light this game does not fake

Every glow until now was baked — a blurred copy of each building rasterised
into its texture once. That is why it costs nothing per tile and why it can
never respond to anything: two towers side by side do not brighten where they
overlap, because each halo was drawn before the other existed.

Bloom happens in the frame now. A bright-pass keeps only what is already near
white; a ring of taps sums what it finds; overlapping neon genuinely adds up
and a dense district blazes the way a dense district should.

**Sixteen taps on a golden-angle spiral, not a grid.** A regular ring at this
count bands visibly — you can count the samples in a wide glow. Rotating each
tap by the golden angle and growing the radius with its index scatters them
evenly at every scale, which buys a smooth falloff out of sixteen reads
instead of the several hundred a separable two-pass blur would want. A second
pass is not available: `SKShader` is one fragment function over one texture,
and more render targets means nesting effect nodes, which this project
already knows silently stop being serviced past a budget.

The threshold sits high on purpose. Below it this stops being a bloom and
becomes a blur, and a blurred city is a smeared city — only windows,
signage, lane lines and fire are meant to cross it.

It rides on `VisualStyle`, so **Classic turns it off entirely** rather than
turning it down. Whether a lit frame beats a baked one is a judgement, not a
measurement, and that switch exists precisely for judgements. It is also the
one part of a style change a purge-and-rebuild would miss, since bloom lives
in the shader rather than in a texture.

#### Measured

| map | Classic | Cinematic | bloom costs |
|---|---|---|---|
| 32×32 | 18.27 | 20.88 | +2.6 |
| 48×48 | 18.42 | 19.50 | **+1.1** |
| 64×64 | 27.57 | 28.55 | **+1.0** |

The two larger maps agree at about **a millisecond** for a sixteen-tap bloom
over 1280×800; the 32×32 figure is residual noise rather than signal, which
is what the instrument's own limits predict. Classic costs the same at 32×32
and 48×48 because the frame size is fixed and most of that cost is per-pixel
— the jump at 64×64 is nodes, not shader.

#### And the baked glow came down, which was half right

With real bloom in the frame, the baked per-texture halo could come down —
and it did: radius 7 to 4, weight to 0.7. Keeping both at full strength
double-counts, which is how a dense block went to mush. The bake is a tight
rim now and the frame carries the spill, which is the right division of
labour and visibly crisper on the render.

**The cost half of that argument was wrong, and only measuring it found
out.** The prediction was that blur scales superlinearly with radius, so a
smaller bake would fill the texture cache faster as well as look better — a
change that pays for itself. Measured on a cold cache over every building
variant:

| style | blur radius | ms to fill |
|---|---|---|
| Classic | 7 | 191.9 |
| Cinematic | 4 | **191.0** |

Nine tenths of a millisecond out of a hundred and ninety. Whatever dominates
that number, it is not the blur — most likely the shape-node construction and
texture upload around it. The change stays because the picture is better; the
saving does not exist, and a comment claiming one would be exactly the sort
of unmeasured assertion this file keeps finding and deleting.

Worth keeping as the general form: **"it will also be faster" is a claim, not
a bonus.** It was cheap to check and it was false.

### G2 (done): water that moves

Terrain landed with water as a flat fill — correct, legible, and completely
still, which on a map where the streets pulse and the traffic runs makes a
river read as painted floor.

`WaterShader` is the project's second GPU effect, and unlike `RetroShader` it
runs **per tile rather than over the finished frame**. That distinction is
the whole design problem: a fragment shader on a sprite knows its own texture
and its own `v_tex_coord`, which runs 0…1 across *every* water tile
identically — so a wave written in local coordinates restarts at each tile
edge and the river comes out **quilted**.

`SKAttribute` is the way out. Each water sprite carries its own tile
position, the shader adds it to the local coordinate, and the waves are
computed in **map space**: one continuous surface across however many tiles
it was cut into.

**One shader instance, shared by every water tile.** An `SKShader` is the
batching unit, so a per-tile instance would be a draw call per tile — the
exact cost `IsoTextureCache` exists to avoid. What is per-tile is the
attribute, which is what attributes are for.

Two crossing waves of different wavelength drifting opposite ways, and only
their **crests** light: a smooth remap would brighten the whole surface and
merely make the water paler, where what reads as water is a few moving
highlights on something otherwise dark. One wave alone is a corrugated sheet;
the interference between two is what stops the pattern repeating anywhere the
eye can catch it — the same reason `RegionalEconomy` sums two sines rather
than running one.

**Not reflections, and worth saying why.** The obvious retrowave move is the
city mirrored in the water, and it is not reachable from here: a tile shader
can see its own texture and nothing else, so a reflection needs the scene
rendered to a texture first. That is a second render target, which in
SpriteKit means nesting effect nodes — something this project already knows
silently stops being serviced past a budget. It belongs with the
light-accumulation work.

Water keeps moving while the city is paused, deliberately: the pause is for
the *simulation*, and a river is not part of it.

### G3 (done): the first particles

`SKEmitterNode` appeared nowhere in this project until now — every moving
mark was a handful of sprites each running its own `SKAction`. That works,
and it is what the fire's embers were, but it has a hard ceiling: the cost is
per *particle*, paid on the CPU in the scene graph, so "a few more sparks"
means a few more nodes and a few more action evaluations every frame.

**The embers were four, and the reason they were four is worth unpicking.**
The comment argued it from `minimumDetailSize` — four sparks each carrying
real weight beat a cloud of specks averaging into haze. That argument is
right about *static* marks and does not hold here: a rising spark is legible
by its **motion** rather than its size. What actually kept the count at four
was cost. An emitter is one node whose particles are simulated and drawn on
the GPU, so the honest number goes from four to fifty for less than the four
cost.

**Factory smoke is the new one, and it says something the game could not.**
Industry is the one zone that should look like it is *doing* something, and
until now a factory at density 5 differed from one at density 1 only in size
and how hard it glowed. Smoke is the first mark in the game that says a
building is **running** rather than standing there, and its birth rate scales
with density — so a busy industrial district visibly is one.

It is also **the one particle here that is not additive**. Everything else
lit in this game adds; smoke *occludes*, and adding it would make a chimney
look like it was firing a beam. A prevailing `xAcceleration` leans every
plume the same way, so a row of factories reads as one district under one
wind rather than as several unrelated effects.

Both emitters call `advanceSimulationTime` when they appear, so a block that
catches fire is already throwing sparks rather than spending a second and a
half filling up.

Smoke joins `animatedBySimulation`: a chimney smoking over a stopped city is
the cars-keep-driving bug again, and work is exactly what a pause stops.

One tuning note from the render, which is the same note this file keeps
making: at alpha 0.20 the plume read as a smudge at the zoom the game is
actually played at. Soot against a night sky should be subtle, but not
invisible.

### G4 (done): the grade

Two more terms in the post-process, both cheap now the bloom chain exists,
and between them most of what separates "dark screen" from "shot at night".

**The shadows are lifted toward the sunset.** Every dark pixel in this game
sits at almost exactly the same near-black, because that is what the
ground/light split decided — right for contrast, and slightly wrong for
film. A photographed night is never truly black; it is a shade of whatever
is lighting the sky. One `mix` weighted by how dark a pixel already is.

It runs **after** the vignette on purpose. The vignette's whole job is
darkening the corners, so grading before it would lift exactly the pixels the
vignette is about to crush and leave the frame's edges the one place the
grade does not reach.

**Grain goes last**, because it is the top layer of a photographic frame —
emulsion, or a sensor's noise floor — and anything applied after it would be
grading the grain rather than the picture. Weighted toward the shadows, where
film grain actually lives: uniform noise over a bright neon sign just looks
like dirt. Static rather than animated, which reads as film stock where a
crawling grain reads as video noise.

Both stay small, and the tests pin the bounds rather than the numbers: past
about 0.03 the grain stops reading as stock and starts reading as a dirty
screen, and past about 0.5 the lift turns the ground purple rather than warm.

`RetroShader` now carries seven uniforms, four of them driven by
`VisualStyle` — so `Classic` is a genuinely ungraded, unbloomed frame and the
switch keeps answering the only question that matters here, which is whether
any of it is an improvement.

## G6–G11: motion, weather, and a reflection that works

The six-phase visual overhaul and four GPU phases left the city a beautiful
still. What it lacked was things *moving*, and the most on-theme image
available to a neon game at night — its own reflection — had never been
attempted. The plan runs G6 cars, G7 trams, G8 ports, G9 weather, G10
reflections, G11 camera.

### G7 (done): trams run on the rails they actually laid

`Transit.tramTracks` has computed a tram line's track since trams landed and
nothing ever drew a vehicle on it. `Transit.tramPath` is the same information
**in order** — a set answers "which tiles carry rails", which is what
`Traffic.congestion` and the texture cache want, and it cannot say which end
of the line a vehicle starts from.

**It is the only mode that can answer the question at all.** Every other route
here is a schematic between stations: a bus route says which stops are on one
line and nothing about the streets between them, which is why transit vehicles
have only ever run over their own diagram. A tram runs on the map itself.

**Driven per frame rather than by an `SKAction`**, which buys two things. A
tram crosses tiles, so its painter's-algorithm key changes as it goes and an
action would need `zPosition` rewritten every frame anyway — at which point
the action is only supplying position. And it advances after `update`'s own
`isRunning` guard, so a stopped city stops its trams with none of the
`animatedBySimulation` bookkeeping an `SKAction` needs to dodge the "cars kept
driving around a paused map" bug.

A severed line has no path and gets no vehicle, rather than a tram gliding
across missing street — the distinction the conduit overlay already draws
between a pipe that exists and one that is live.

### G6 (part done): the cars were the fourth additive saturation

Reported twice from play as "we need to revisit cars", with no more detail —
so the first move was a *diagnostic*, not a change.
`ScenePlaytestTests.testRenderCarsAtEveryZoom` photographs traffic at 0.5,
1.0 and 3.0, the range the camera actually covers. The existing traffic render
only ever showed camera 1.0, so there had never been a picture of what a
vehicle becomes when you pull back.

It answered the question immediately, and the answer was a defect rather than
a preference. `RenderPalette.trafficCarBody` was `white: 0.95`, and the face
shading then blended it *further* toward white by up to 0.7 — so an
eleven-point car was brighter than a lit window and comfortably past
`VisualStyle.bloomThreshold`. Traffic bloomed into a row of identical white
lozenges sliding along the lane glow.

**That is the fourth time this project has walked into additive saturation**,
after the conduit runs, the route lines and the tram rails. The plan written
the night before said "assume the fourth is waiting"; it was already there.

The fix is the value ladder `VisualStyle` already states: silhouettes are mid
tones, and the top is reserved for lit windows and signage. A car is smaller
than any of them, so it belongs at or below a silhouette — and against the
magenta of a lit street a *dark* body reads better, because the road is doing
the lighting. The lamps carry the car, which is what they were added for.

The same render showed a second thing the code could not: **every tile
staggered its cars identically**, so adjacent tiles ran in lockstep and a
street came out as an evenly spaced dotted line marching in step. A seeded
per-tile phase breaks it, seeded from the position for the reason
`BuildingRandom` always is — a street keeps its own rhythm rather than
reshuffling whenever a tile is rebuilt.

What is *not* done is whether cars read well at all now. That is a judgement
and needs eyes on a moving map; the render exists so the question can be
asked from a picture rather than a memory.

### G11 (part done): the zoom anchors on the cursor

Zooming at the screen's centre is the wrong default for a map. The thing a
player is pinching toward is the thing they are looking at, and a
centre-anchored zoom slides it out from under them — so getting closer to a
district was zoom, pan, zoom, pan.

The correction is one line of algebra: a world point's screen offset from the
centre is `(point - camera) / scale`, so holding that constant across the
change gives the camera's new position. **Taken off the *clamped* scale rather
than the requested one**, or a pinch at the end of the zoom range keeps
shoving the camera sideways while nothing appears to zoom, which reads as the
gesture being broken. `CameraZoomTests` pins that case specifically.

`anchoredAt` is optional, so callers with no cursor — the keyboard, and the
clamping tests — keep exactly the behaviour they had.

The rest of G11 (eased transitions, an opening pan on load) is *feel*, and
this file's rule for feel is that it gets played rather than rendered.

### G8 (done): the ports do something

A seaport and an airport were built and then sat there. Everything they do
happens in `Demand`, which is a number in a panel — **nothing on the map ever
said the quay was trading**, which made them the only buildings in the game
whose entire purpose was invisible once placed.

`ShippingLane.path(in:)` is a breadth-first search over water from the tile a
quay touches out to the edge of the map, the same shape as `Transit.tramPath`
over roads. A hull travels it, and it is by a distance the largest moving
thing in the game so that it reads from across the map.

**A ship only sails for a port that works**, and an empty coastline gets
nothing. A vessel gliding past a shore with no dock on it would be *scenery*,
and nothing else on this map is scenery — every mark says something about the
city. A dock on a landlocked pond gets nothing either, which is the same
honesty a severed tram line already gets: drawing a ship sailing into a dead
end would claim a connection the map does not have.

The tram runner generalised into `PathVehicle` rather than being copied. A
tram and a ship are the same problem — a vehicle whose route is real ground
rather than a schematic, so it has to be sorted against the city it moves
through — and a third copy of that loop was the wrong answer.

#### And the aircraft came back, because motion is not shape

`ServiceMassing.airport` cut its static aircraft: at three tiles across a
fuselage, a wing and a fin merged into one lump that read as a crate, and
scaled up enough to separate they stopped being a plane and became a hangar.

The same mark **moving** is a different proposition, for the reason the fire's
embers already established — a moving mark reads at a size a still one cannot.
A shape sliding down a lit centreline is an aircraft because of where it is
and what it is doing, not because its silhouette resolves.

It is a child of the airport's own node rather than a `PathVehicle`, because
it never leaves the lot: its depth key is the building's, so there is nothing
to re-sort per frame and an `SKAction` is the cheaper tool.

**It is invisible except while moving**, and that is the whole basis for
drawing it. Parked at the threshold between departures it is a grey lump on
the apron — which is precisely why the static version was cut — so it fades in
as it accelerates and out as it goes. Without that it would be a lump for half
of every cycle, and half of every screenshot.

One honest limit: `SKAction`s do not advance in a headless capture, so **no
render in this project can show the aircraft mid-roll or the ship under way**.
Both are covered by tests for existence and movement, and judged in the
running app.

### G9 and G10 (done): rain, and the wet street

`Weather` is a clock, not a dice roll, for the three reasons `RegionalEconomy`
is one, plus a fourth that is specific to it: this one is *visible*, so a
forecast that re-rolled between frames would be a broken effect rather than a
surprising one. Two sines of co-prime period biased below zero — **measured
over 400 days, it rains on 22% of them in spells averaging 8**, about sixteen
seconds of rain every couple of minutes at normal speed. The first draft of
that comment said "spells of two to four", which was reasoning rather than
counting.

It lives in `Rendering/` because nothing in the city's economics reads it, and
putting it in `Simulation/` would claim a mechanic the game does not have.

#### A reflection belongs to the ground it lands on

The reflection is a building's **own cached texture**, flipped and squashed —
no new texture and nothing to invalidate, because it *is* the building's
texture. It is emphatically not the render-target reflection G5 is holding out
for: this is one building reflecting only itself. It works anyway because wet
asphalt does not return a picture, it returns a dim smear directly beneath
whatever stands on it, which is exactly the shape of the approximation.

**Getting the ownership backwards is why the first two renders showed
nothing.** Hung off the building's own tile node, a reflection falls on ground
that building already covers, and anything reaching past the lot is painted
over by the tile in front — drawn later, and opaque. Reflections appeared
*only* where they happened to hang over the edge of the map into open ground.
The ground asks the question instead: `GameScene.reflection(at:)` looks
up-screen at `(x-1, y)` and `(x, y-1)` and reports whatever stands there,
which puts the mark on the road in front of a tower where you would see it.

Worth keeping as the general shape: **in a painter's-algorithm renderer, a
mark that falls outside the node that owns it is a mark nobody will see.**

#### Four things the renders and the harness caught

None of which the compiler could have:

- **Camera children are positioned in points**, because the camera's own scale
  cancels out. Sizing the rain by the zoom spread it over several times the
  screen and the first frame had about four drops in it.
- **`advanceSimulationTime` only works once the emitter is in the scene graph
  with its `targetNode` set.** Pre-rolling before either existed produced a
  handful of drops in the wrong coordinate space — which looked exactly like a
  birth rate set too low.
- **`??` binds looser than `+`.** The obvious spelling of the cache key put
  the wetness on the fallback branch only, so a tile that *did* reflect
  something was keyed without it.
- **A reflection is a statement about a neighbour**, like a road's lane mask,
  and `refreshRoadNeighbors` only refreshes neighbours that are road. A
  reflection lands on bare ground too, so placing a park at (9, 7) left
  (10, 7) and (9, 8) reflecting nothing. `ScenePlaytest` caught that, which is
  precisely the shape of bug it exists for — nothing failed, the map was
  simply showing less than it knew.

And `Weather.wetness` is floored at one step rather than rounded to the
nearest, because rounding sent the first and last day of every shower to zero:
it was raining on dry ground.

#### The fixture had to be plumbed before any of it was visible

An unserved city wears a water drop and a lightning bolt over every building,
and the first render of this was a picture of badges with a city somewhere
behind them. Worse, laying pipe was not enough: **funding buys capacity, not
just coverage**, so thirty lots at density 3–5 draw several times what one
tower supplies and the city sat in an outage that looks identical to having no
pipes at all. Same lesson as every fixture note in this file — *a picture in
which the failing case cannot occur reports success*, and its twin, a picture
in which the effect cannot be seen reports failure.

## The soundtrack is synthesised, not sampled

The game had **no audio at all** — not a line of it, and not a mention
anywhere in this file. For a project whose whole identity is retrowave and
whose target is the App Store, that was the largest hole in it.

It is a **synthesiser** rather than a file, and that is not a workaround. This
project has exactly one raster asset, the app icon, recorded here as an
admitted exception; a sampled soundtrack would be the first real asset in it
and a synthesised one is not. Synthwave is also the most synthesisable genre
there is — saw bass, detuned pads, a narrow-pulse lead and a drum machine that
is a pitch-enveloped sine, filtered noise and a noise burst. Oscillators are
not an approximation of this music, they are what it is made of.

And it can take the city as input the way `Weather` takes the day: pads
thickening with density, bass dropping when you pause, tempo following
`SimulationSpeed`. A fixed loop is wallpaper. That is the argument the contact
light's pulse already won over a blinking beacon — a mark that responds beats
one that repeats.

`Synth` is pure arithmetic over `Double` with no AVFoundation in it, so the
whole instrument is testable offline, and because the live render callback
must not allocate or lock, the code it runs has to be that plain anyway.
`Soundtrack` is the score and the mix. `SoundtrackRenderTests` writes
`build/Audio/theme.wav` — the contact sheet for sound, so the theme can be
heard without launching the game.

### Composing without ears

**The author of this code cannot hear it.** Every art decision in this project
goes through "look at the render, don't imagine it", and there is no
equivalent available. That changes what the tests are for: they catch *wrong*,
they cannot catch *bad*, and the judgement has to go to whoever plays the WAV.

It also changes the engineering. Where a technique exists that prevents a
fault outright, use it rather than writing the naive version and listening for
trouble:

- **Oscillators are band-limited (PolyBLEP).** A naive saw's instantaneous
  jump carries energy above Nyquist that folds back as inharmonic whistling —
  the single most common reason a hand-written synth sounds cheap, and exactly
  the kind of fault a deaf author ships.
- **The filter is a topology-preserving transform, not the classic Chamberlin
  form.** The obvious four-line state-variable filter is only stable below
  about `fs/6`; the first version clamped at `0.45 × fs` and the test asking
  for an absurd cutoff came back with **infinity**. At volume, in headphones,
  that is not a bad sound, it is a hazard.

Two things the tests caught immediately, both inaudible as themselves and
neither findable by reading:

- **The lead's pulse had a constant −0.36 offset.** A pulse spends `width` of
  its cycle high and the rest low, so a 32% duty wave has a mean of
  `2 × width − 1` *by construction*. It wastes headroom and thumps at note
  edges. Centred at the oscillator, with a DC blocker on the master as belt
  and braces.
- **The filter diverged**, as above.

The standing checks are the failures that would be glaring to a listener and
invisible here: nothing clips, nothing is silent, no DC offset, every bar has
something in it, both channels differ, and a note lands on the frequency it
claims. A soundtrack a semitone out is still a soundtrack, and nothing else
would notice.

## The post-process was shading the whole city

Reported from play: *"the rain feels stuttery, and scrolling across the map
should seem effortless."* Both are frame-rate complaints, and a frame-rate
complaint has exactly one first question — **is this bound by work per pixel
or work per node?** They have opposite fixes, and guessing wrong means
optimising the half that was never the problem.

`RenderTimingTests.testMeasureWhatAFrameSpendsItsTimeOn` answers it by
changing one thing at a time: post-process on and off, resolution doubled,
rain present and absent. The answer was strange enough to be the whole clue:

| | shader cost |
|---|---|
| 64×64 @ 1280×800 | 38.8 ms |
| 64×64 @ **2560×1600** | 39.2 ms |

**The cost ignored the resolution and tracked the size of the city**, which is
backwards for anything per-pixel — unless the pixels it runs over are not the
window's.

### `SKEffectNode` sizes its render target to its children

It renders them into an offscreen texture sized to their **accumulated
frame**. Everything in this game's world sits inside the one running
`RetroShader`, and the backdrop spans the map plus thirty-six tiles of margin.
So the post-process was covering **8704×8771 points against a 1280×800
window — 74.5× the area of the screen**, every frame, almost all of it on
parts of the city nobody could see.

Nothing in the API hints at this, and it applies to any full-screen
post-process in SpriteKit over a world bigger than the window.

The fix is that the two world-sized background sprites show only the slice the
camera can see (`clipToView`), and tiles outside the view are **detached**.
Both were needed: fixing either alone changes almost nothing, because the
frame is the union.

**`isHidden` does not shrink the accumulated frame** — hiding 1,059 tiles
moved the shaded area by exactly zero, and only detaching worked. That
measured fact is why the culling is written the awkward way, and it is the
thing to know before writing any culling of your own.

### Measured

| map | shaded area before | after | frame @1280×800 |
|---|---|---|---|
| 16×16 | 5632×3057 (16.8×) | 1536×960 (1.4×) | |
| 32×32 | 6656×4961 (32.2×) | 2060×1112 (2.2×) | 26.1 → 18.0 ms |
| 48×48 | 7680×6866 (51.5×) | 2247×1646 (3.6×) | |
| 64×64 | 8704×8771 (74.5×) | **2259×1747 (3.9×)** | **56.4 → 28.3 ms** |

Frame cost roughly halved at 64×64, and the shader's own share fell from
38.8 ms to 11.9 ms. It now also *scales with resolution again* — 11.9 ms at
1280×800 against ~23 ms at 2560×1600 — which is the real confirmation the fix
is structural rather than a coincidence.

### Four wrong guesses, and what actually found it

Worth recording, because the method is the transferable part and the
reasoning was wrong every single time:

1. **Predicted a resolution-bound shader.** The numbers showed cost ignoring
   resolution entirely.
2. **Nearly built tile culling first.** It would have changed the shaded area
   by *zero* while the backdrop still spanned the map.
3. **Fixed the backdrop and called it done.** That got barely a third of the
   win, because the sun glow is `contentBounds × 1.6` — 6554 points across on
   a 64×64 map — and had not been considered at all.
4. **Measured the fix with a benchmark that never ran it.** Culling happens in
   `update(_:)`, and the test only built and refreshed a scene; it also
   measured at `centerCameraOnMap`'s zoom, which pulls back to fit the entire
   city and is a view nobody plays at. The first "after" numbers were not
   evidence of anything.

What settled it was **listing every child's accumulated frame** instead of
deciding which node ought to be big. Thirty seconds, and it would have skipped
all four. The general form: when a measurement is strange, stop reasoning
about the mechanism and enumerate the parts.

## Traffic is light, not little boxes

Reported from play: *"they look strange now — I almost wonder if they should
be small traces of light rather than boxes we draw. This would allow other
vehicles to have different colors."* Both halves of that are right, and the
second is the more important one.

**A box is the wrong object at this size.** A vehicle is about eleven screen
points across at the zoom the game is played at, and a form that small cannot
show its form. Two genuine defects were fixed in the boxes first — they
bloomed into identical white lozenges, and every tile staggered its cars the
same way so a street read as an evenly spaced dotted line — and they *still*
looked wrong, because the problem was never the execution. It is the case
`NeonStyle.minimumDetailSize` already describes: a mark that cannot be drawn
big enough gets cut, not shrunk.

A streak has no such problem. It is a direction and a colour, and both survive
any zoom. It is also this art direction's own rule applied to the one thing
that moves — *colour comes from the light a thing throws, not from repainting
it* — which is the same move the ground/light split made when the map stopped
being flat coloured tiles.

### The feature was eighty per cent built and assembled backwards

`makeSpeedTrail` already existed behind every car: additive, length and
brightness scaled by speed, and described in its own comment as a second read
of congestion — long bright streak means free-flowing, short dim one means
jammed. The retrowave part was already there, dragging a box around in front
of it.

And it took `networkAccentColor(for: zone)` — **the colour of the road, not of
the vehicle.** That one line was the whole thing standing between this and a
legible vocabulary. Traffic now colours by what is driving: pale cyan for
ordinary cars, industry's amber for freight, blue for a patrol car, hot red
for an engine running to a fire.

**The fire engines are the part that stops being decoration.** Red streaks
converging on a burning block say where the emergency is from across the map,
which no silhouette at eleven points could ever have said. Same for freight,
which is the rule the lorry's separate box body was added to convey and never
actually managed.

### Alpha blending was tried first, and it was wrong

The reasoning was sound: this project has saturated to white four separate
times — the conduit runs, the route lines, the tram rails, and the cars
themselves — and every vehicle becoming light on an already-glowing lane is
exactly that setup a fifth time. So the first pass used `.alpha`.

It looked like **pale bars painted on the road**. Alpha blending removes the
one property that makes light read as light: a trace that cannot be *brighter*
than what it lies on is paint.

The correction is that **saturation is a function of alpha, not of additive**.
Held at 0.3–0.65 a saturated hue tints the lane rather than bleaching it — a
cyan streak and a red one land on visibly different colours — where a pale
colour at high alpha whitens whatever it touches. Which is also why the first
attempt read grey: the car colour was nearly white. Saturated hues, modest
alpha, and it works.

The other half was thickness. Eight points read as a bar; a trace is mostly
length, and thickness is what makes it look like an object instead.

## Everything that moves is a trace of light

Road traffic, trams on their rails, fire engines, and the vehicles running a
transit line over its diagram all draw through one `streakSprite` now. Three
separate implementations of "a small thing that moves" is how the cars ended
up saying one thing about congestion and the buses another.

Two things fell out that a box could not have done:

- **A streak points anywhere.** The projected boxes came in one texture per
  axis, because they are little volumes with faces, so a turn swapped
  textures — and a route running at any angle other than the two had a vehicle
  pointing the wrong way along it. A trace has no faces to get wrong, so the
  diagram vehicles are `orientToPath: true` now and simply face where they are
  going.
- **A vehicle parks at its first stop.** `SKAction.follow` only moves a node
  once it ticks, so a transit vehicle spent its first frame at the scene's
  origin — off the map entirely. It showed up in the render as a streak
  floating above the city, brief in play and wrong every time a route is drawn
  or a view switched.

**The ship keeps its hull.** It is the largest moving thing in the game, and a
streak would throw away the silhouette that makes a seaport read as trading at
all — which is the whole reason that building got a vehicle. The rule is not
"light is better", it is that a mark too small to show its shape should stop
trying to have one.

## Engines that actually drive to the fire

Colouring traffic by type made a vehicle near a burning block red. That is a
*hint*: something that happens to be the right colour because it is standing
near the right thing. `EmergencyResponse` is the real version — a route from a
fire station, along streets that exist, to the building that is alight.

**The difference is information rather than decoration.** A hint says a fire
is roughly over there. An engine leaving a station and crossing the map says
*which station is covering it*, and — when none appears at all — that nothing
is. That is what the Fire Risk overlay tells you, except you get it without
going to look for it.

It reuses `PathVehicle` unchanged, which is the payoff for having generalised
the tram runner rather than copying it: a fire engine is the same problem as a
tram and a ship — a vehicle whose route is real ground rather than a schematic,
so it has to be sorted against the city it moves through and stop when the city
does.

Three decisions worth keeping:

- **Searched from the fire outward**, not from each station. A search from the
  fire stops the instant it meets any station; one from each station would
  have to run to completion to find out which fire is nearest. In a bad moment
  there are more fires than stations, and this is the cheaper direction either
  way.
- **One-way.** An engine runs to the fire and the next one leaves the depot. A
  vehicle sliding back to its station in reverse — which is what the shuttle
  behaviour trams and ships use would have done — says something untrue about
  what it is doing.
- **Capped at four.** A citywide conflagration is exactly when you least want
  forty extra vehicles in the scene, and past a handful of converging streaks
  the mark stops reading as "the response" and starts reading as noise.

### Two things that would have shipped broken

- **The path comes out station-first already**, because the search walks back
  from its arrival — which is the depot. The instinct is to reverse it, and
  the first version did, which would have sent every engine *away* from the
  emergency. Caught by tracing the direction rather than trusting the comment
  that was sitting above it, which said the opposite of what the code did.
- **The fires had to go in the cache key.** Tram routes are drawn once and a
  shipping lane lasts as long as the dock, but a block catches alight on the
  simulation's own clock. Keyed without them, an engine would only ever have
  appeared if the player happened to redraw a tram route while something was
  burning — and the test asserting the route is correct would have passed the
  whole time. Asked of the scene rather than of the route, for exactly that
  reason: the trams already shipped once with a path computed and nothing
  drawing it.

## Zooming in, and the two halves of "these are just drawings"

Reported from play: *"when we're zoomed out, the game looks good. When we're
zoomed in it becomes clear these are just drawings."*

That is two problems wearing one coat, and separating them is what made both
cheap. A building is **blurry** up close, and there is **nothing more to see**
up close — and only the first one is about resolution.

### Half one: a texture drawn at a quarter of the pixels it needs

`IsoTextureCache` rasterised each building once at about one pixel per world
point. A Retina display draws two physical pixels per point, and
`GameScene.minimumZoomScale` (0.5) doubles it again, so at the closest view
every texture pixel was covering a four-by-four block of screen pixels. The
city genuinely was a photograph of a city as you approached it.

`oversample` is **4**, which is exactly what that arithmetic asks for. It was
nearly not, because the estimate that framed the decision was wrong by about
fifty times: a built-out 40×40 city was supposed to hold ~19 MB of texture, so
four would cost 300 and oversampling could only ever be a mitigation.
Measured, it holds **1.6 MB** — ninety-three textures about 65 points square,
not the 200×250 that guess assumed. Four costs **25 MB**. The ceiling was
imaginary, and the only reason anyone found out was that `approximateBytes`
was cheaper to write than to keep arguing about.

It **scales the finished node** rather than rebuilding at a larger projection.
The blur radius and the stroke widths are in points, so a bigger projection
would make the glow relatively tighter and the neon thinner — a change to the
*look* wearing the clothes of a change to resolution.

What it costs is cold-cache time: filling every variant goes from about 190 ms
to 650. That is paid lazily as buildings first appear, so it lands as a hitch
when a large saved city is opened. Warming the cache off the main thread, or
behind the title screen, would remove it and has not been done.

**And the render harness cannot see any of this.** It captures at one pixel
per point, so its only magnification is the camera's, and two already covers
that — 2× and 4× produce pixel-identical sheets. Four is justified by the
arithmetic and by a real display, not by any picture in this repository, which
is worth knowing before someone "simplifies" it back.

### The vector tier was planned, measured, and not built

The plan agreed with the player was oversample first, then draw buildings as
shape nodes past a zoom threshold — affordable because only about twenty are
on screen when you are close, with the risk flagged up front that each
building's glow is its own `SKEffectNode` and this project has twice watched a
scene silently stop servicing effect passes past a budget.

`CloseZoomDetailTests` rendered both paths at 4× before any of that was
written: the cached texture beside the same massing drawn as live shapes.
**They are the same picture.** A mullion's worth of edge crispness separates
them, and nothing else — because at oversample 4 the texture already has every
pixel the closest camera can ask for, and both paths draw *the same marks*.

So the vector tier bought resolution the game had already bought, and its
whole value was as a carrier for marks that did not exist yet. It is not
built. If `minimumZoomScale` ever goes below 0.5, the fix is to raise
`oversample`, not to add a renderer.

Worth keeping as the general form, because it is the same shape as the blur
radius that was going to be "also faster" and was not: **a plan is a claim
too.** This one was cheap to check and it was half wrong.

### Half two: the marks were cut at the wrong floor

`NeonStyle.minimumDetailSize` cuts any mark that cannot be drawn about nine
points across, and this file lists by name what went: glazing mullions, window
frames, storey slab lines, balcony railing posts. That floor was set against
the size a lot is at **rest** — 63 points for a 2×2 — and it is correct there.
It is the wrong floor with the camera all the way in, where the same lot is
126 points across 252 physical pixels: a mark dropped for being four points
wide would have arrived at sixteen.

So zooming in showed *less* than it should, and that is the half the player
was actually reporting. Sharpening a picture cannot add something that was
never in it.

`IsometricBuilding.Detail` makes those marks **deferred rather than gone**.
`.near` puts back the two with the most to say — the glazing mullion and the
storey slab line — and **derives both from the panels already on the
building** rather than inventing them, so a ledge lands under a row of windows
instead of at a spacing nobody chose, and a band that is one unbroken slab of
light at rest comes apart into panes up close. Both are expressed as ordinary
`Panel`s, so they project onto the face plane and shear with the wall like
everything else, and both are appended **immediately after the panel they
mark** rather than gathered into a pass of their own — a mullion ties every
sort key its own pane has, and this project has already lost a hospital's
cross to exactly that tie.

Two calibrations, both from the render:

- **Pane count comes from the panel's projected width, not its width in tile
  units**, so a band on a narrow tower and one on a wide hall end up with
  panes the same size on screen. The target is 14 points — about 56 physical
  pixels at the closest camera, deliberately chunky, because a mullion finer
  than that is the grey speckle `minimumDetailSize` was written to delete.
- **The slab line is drawn in the building's accent, not in the silhouette.**
  Its elevation ancestor was "3-point storey slab lines (near-black on
  near-black)" and it was cut *for being invisible*. A slab edge catches the
  light the creases catch.

Industry gains the least, and that is correct rather than a gap: its
vocabulary is deliberately big blocks of light, so there is little fine
detail to restore. Dividing its lit bays would undo a decision this file
already records making.

### It is a second texture, not a second renderer

The near tier is one more dimension of `IsoTextureCache.Key`. Everything the
cache exists for survives: no shape nodes in the scene, one sprite per
building, no `SKEffectNode` per lot — and no second drawing path that can
drift from the first, which is the failure this file records four times over.
The cost is one more texture per variant in use, against a budget measured in
tens of megabytes.

`GameScene` drives it off the camera and **notices for itself** rather than
waiting to be told, the same way it notices an overlay changing under it.
There are four ways the camera can move (pinch, keyboard, `centerCameraOnMap`,
a load) and correctness should not rest on all four remembering.

Three things that had to be right:

- **Hysteresis**, engaging at 0.72 and releasing at 0.78, for the reason
  `CitySimulator.declineMargin` has it: read one number in both directions and
  a pinch resting on the boundary flips the entire map back and forth forever.
- **Only what is on screen is redrawn.** `refreshAll` walks every tile the map
  has, attached or not, so on a built-out city a tier swap would ask the cache
  to rasterise the whole near variant set in one frame — a freeze, the instant
  the player zooms in. It refreshes the attached tiles, which at this zoom is
  about twenty buildings.
- **A tile coming back into view is asked whether it is still current.**
  `cullTilesOutsideTheView` re-attached silently, which was fine until
  something could change *because* a tile was detached. The cache keys make
  that a handful of dictionary lookups when nothing has moved.

And the detail tier is deliberately **not** always on. At rest a mullion is
three physical pixels, which is exactly the mark `minimumDetailSize` refuses.
Detail below the size it can be resolved at does not add information; it
averages the facade toward mud.

### A photograph of the running game

Asked for while away from the machine: *"can you open up the game, play for a
bit and take a screenshot — one zoomed in, one zoomed out."*

**The app cannot be driven from here**, and this file already records why —
`screencapture` fails over the remote session this project is usually driven
from, and accessibility scripting against the menu bar fails too, which is the
whole reason Capture Screenshot writes the PNG itself. `CityPortraitTests` is
the honest version of the request: it opens a minted save in a real
`GameScene` on a real `SKView` and photographs it through
`view.texture(from:)` — the same path the in-game capture takes, shader and
all. Real frames, not a reconstruction, and the one thing they cannot show is
anything mid-`SKAction`, which is the standing limit the traffic render
already records.

Two things it has to do that a naive capture would not, and both were wrong
first:

- **Call `update(_:)` after moving the camera.** Culling and the
  `IsometricBuilding.Detail` tier both live there and both read the camera, so
  shooting straight after setting a scale gets the far textures at close
  range — a picture of a frame the game never draws. The test asserts it
  reached `.near` rather than trusting it.
- **`centerCameraOnMap` sets position and says nothing about zoom.** Exactly
  the trap `ScenePlaytest`'s filmstrip recorded: most of the frame comes back
  empty night. The wide shot works its scale out of `contentBounds`.

It frames the close shot on the **densest block** rather than the middle of
the map, because the middle of a generated city is not necessarily anywhere.

#### "Full" and "optimised" are different cities

The obvious answer was `Metropolis`, the minter's "settled, fully-served
64×64". Measured, it is **full and not optimised**: mean density 3.57 with
**14%** of growable lots topped out. Two reasons, and the second is the
interesting one.

It is played by **default** rather than by the strategy `DesignPlaytestTests`
measures as best, and it is minted at **200 days** — which settles a city and
does not finish one. One lot takes 125 days to climb from bare ground to
maximum and a whole city staggers its lots behind demand, land value and
utility capacity, so the standing "a city settles in ~160 days" figure is
about when growth *stops accelerating*, not when it stops.

`Apex` is the same map with every measured lever set the way the measurement
says — industry zoned apart, a full subway network — and 900 days to build:

| | Metropolis | Apex |
|---|---|---|
| residents | 3,360 | **4,080** |
| mean density | 3.57 | **4.38** |
| lots at maximum | 75 of 533 (14%) | **246 of 471 (52%)** |
| blocks alight | 1 | 0 |

Worth keeping as a fixture lesson: **a settled city is not a finished one**,
and every picture taken of a 200-day city has been a picture of scaffolding.

`MINT_ONLY` mints one recipe rather than all eight, because a 900-day 64×64
city is about a minute of Release simulation and re-cutting the other seven to
look at one of them is the sort of wait that stops a fixture being re-cut.

## The buildings were not translucent; the bloom was printing ghosts

Reported from play, on the close-zoom portrait: *"it seems like because we have
translucent buildings the buildings look funny when they're close together."*

The reading was right and the cause was not the buildings. Two measurements
settled it in a few minutes, and the order matters — the cheap one first:

- **A building rasterised over a saturated background leaks 2–5% of its
  pixels**, all of it the soft edge of the baked glow. The bodies are opaque.
- **The same frame with the post-process switched off is completely solid.**
  No see-through anywhere.

So it was one of the seven terms running over the finished picture, and a
still of all seven together cannot say which. `setShaderUniformForTesting`
exists to knock them out one at a time; with bloom at zero the frame is clean.

### Sixteen taps, and every pixel used the same sixteen

The spiral was `angle * float(i)` — **identical for every pixel in the
frame**. So a bright source is not blurred by that loop, it is *copied*,
sixteen times, to sixteen fixed offsets.

A few pixels across, those copies overlap into something that passes for a
halo. That is why this looked right: it was built and reviewed on whole-city
frames, where a lit window is two or three pixels. Forty pixels across — which
is what a window is at `minimumZoomScale` on a Retina display — each copy is a
plainly readable rectangle printed onto whatever building stands next door.
A ghost of the window behind, on the wall in front, is *exactly* what
"translucent" looks like.

A per-pixel rotation of the spiral turns sixteen copies into sixteen different
offsets per pixel, which is noise rather than structure — and this frame
already ends in grain, so noise is the one artefact it can absorb.

### And the reach was tracking the render target, not the screen

`u_bloomRadius` is a fraction of the render target, and `SKEffectNode` sizes
its target to whatever its children cover — which
`cullTilesOutsideTheView` deliberately made **camera-dependent** when it cut
the shaded area down to the visible slice. Measured:

| camera | bloom reach on screen |
|---|---|
| 0.5 (closest) | **33.3 pt** |
| 1.0 (rest) | 23.0 pt |
| 2.0 | 14.4 pt |
| 3.0 (widest) | 14.4 pt |

A 2.3× swing nobody chose, in the worst direction: widest exactly where a lit
window is already four times its resting size. Bloom is a lens artefact — it
happens in the camera, so it covers a fixed distance on the glass however far
away the subject is. `GameScene.matchBloomReachToTheCamera` sets the fraction
from the camera each frame and it reads a flat **23 points** at every zoom,
23 being what the resting camera already had so the view the game is mostly
played at is unchanged.

Worth keeping as a shape, because it is a new one for this file: **a change
made for performance can silently re-scale something that reads off the thing
it changed.** The culling fix was correct, measured, and tested; it also
quietly moved a value in the shader, and nothing failed.

### Two things the test for this got wrong first

`BloomTests.testTheHaloIsEvenRatherThanSixteenGhosts` measures the evenness of
the halo around a bright source — sixteen discrete copies make a lobed ring, a
real halo a flat one. Both mistakes are the same mistake: **measuring the
fixture rather than the thing.**

- **The source was a square.** A circle of any radius crosses a square's edge
  at some angles and its corner at others, so the ring came back lobed on a
  picture with *no bloom in it at all*. A disc has no angular structure of its
  own.
- **The effect node held only the source**, so its render target was 40×40
  points and there was nowhere outside the source for a halo to land — a test
  for the bloom, measuring a frame the bloom could not reach. The same
  `SKEffectNode` sizing rule that caused the original performance bug, met
  from the other direction.

And one about where to measure: close to the source all sixteen copies overlap
heavily, and measured there the test **passes on the bug it exists for** —
1.30 against a bound of 1.6. Out in the falloff where the copies separate it
reads **2.08 against 1.15**. Verified by putting the old shader line back,
which is this project's standing rule for a test written after the fact.

### "HD sprites" would have fixed nothing

Reported next, once the buildings got sharp: *"now I can see some pixelation
on the windows. Is it worth doing a pass to make HD sprites?"*

No, and the measurement says so before any work starts. The same frame with
the post-process switched off has **crisp window rectangles**; with it on they
are soft and fringed. Whatever is softening them is added *after* the texture
is drawn, so texture resolution cannot reach it — and the textures are
already rasterised at 4×, which is exactly Retina times the closest camera.

**The obvious mechanism was wrong, twice.** First guess was that
`SKEffectNode` sizes its render target in scene points, so zooming in past 1.0
would magnify the shaded image rather than re-render it — the same shape as
the `u_bloomRadius` bug found an hour earlier. An edge-width measurement was
too noisy to settle it and pointed the wrong way. The grain settles it
cleanly, because it is computed once per fragment and therefore *is* a ruler:
at screen resolution neighbouring output pixels almost never match, and a
magnified pass would show the noise in blocks. It reads **1.7–2.9% matching
neighbours at every zoom from 0.5 to 3.0** — no blocks. The pass runs at full
screen resolution.

So the softness is the pass's own effects: chromatic aberration fringing every
edge, the bloom's halo over it, grain on top. `ShaderResolutionTests` keeps
the invariant, because anything that makes the pass render coarser —
`shouldRasterize` on the effect layer, most obviously — would soften the whole
game with nothing else failing.

**What is actually behind it is the same thing as the bloom.** Every term in
that grade is fixed in *screen* space, while the thing being photographed
changes size sixfold across the zoom range: a lit window is about three pixels
at the widest camera and forty at the closest. Values that read as film
texture over a whole city read as dirt on the glass when one window fills the
same area. Two of these have now been found — the bloom's reach, fixed, and
the grade's intensity, not — which is enough to state the general form:
**a post-process tuned at one zoom is tuned at exactly one zoom**, and this
project has no render that looks at any other.

## Phase 0 of the graphics roadmap: a camera that records

The roadmap opens with a tool rather than a pass, and the reason is that
**every judgement this project has ever made about how it looks was made on a
still**. Four of the five graphics passes planned after it change things that
only read in motion.

`SceneRecorder` drives `GameScene.update(_:)` itself at a fixed step instead of
letting SpriteKit run the loop, which is what makes it work with no window and
no display — the same reason Capture Screenshot writes its own PNG rather than
calling `screencapture`, which fails over the remote session this project is
usually driven from. It writes **two things from one pass**: a `.mov` through
`AVAssetWriter` for a person, and a filmstrip of sampled frames for whoever
cannot play a movie, which is most of this project's history. Frames stream to
the encoder as they are taken; a few seconds at 2560×1600 is gigabytes of
`CGImage` and buffering them is not an option worth debating.

### The clock cannot be jumped, only stepped

`GameScene.update` clamps its own delta with `min(currentTime - last, 0.1)`, so
handing it a timestamp a second later advances the world by **a tenth of a
second**. That is correct for the game — it stops the city lurching after a
stall or a drag between displays — and it is a fact any harness driving the
clock has to respect. Two captures a second apart produced a byte-identical
difference until the recorder supplied a real cadence, and the identical figure
is what gave it away.

### And then it measured 0.06%

Over a full second of a *running* city, 0.06% of the frame changed. One tram.

Road traffic, the transit-diagram vehicles, the airport's aircraft and the
feedback flashes were all `SKAction`s, which SpriteKit runs on its own loop —
so a tool built to judge motion could not see the main thing that moves. That
is the recorder's first real finding rather than a limitation to work around.

### Ambient traffic moved onto the per-frame driver

The same three arguments `PathVehicle` already made: an action cannot be
advanced by anything driving the scene from outside, a paused city then needs a
separate walk to stop it, and the motion is a pure function of elapsed time
anyway — so an action is storing a program to compute something arithmetic.

**Measured before adopting, which the roadmap asked for**, because the worry
was real in shape: `SKAction` evaluation is native and a built-out city has
over a thousand road tiles. On the largest city in the project — **302 cars
driven at 0.221 ms per `update()`**, in a Debug build, about 1.3% of a 60 fps
budget. The worry was unfounded and is now a number.

Motion over one second went **0.06% → 0.30%**, and the bound in
`CityMotionTests` was raised with it rather than left as a floor nothing could
fail.

Two things fell out of it that are worth more than the tool:

- **Every ambient car in the game has been drawn at the wrong opacity.** The
  action sequence ended in `SKAction.fadeIn`, which fades to *1.0* rather than
  back to whatever the node had — so each car jumped to full opacity after its
  first loop and stayed there. The streaks are deliberately drawn at 0.3–0.65
  because this file records that a saturated hue at modest alpha *tints* a lane
  while the same hue at high alpha *bleaches* it. Traffic has been running at
  the bleaching end since the streaks landed, which is very likely part of why
  it still read as wrong after the streaks fixed the shape problem.
- **A whole bug class is gone.** A car built *while* the game was paused had
  never been through `applyAnimationPause`, so it drove off the moment it
  appeared unless something remembered to catch it. There is no "start" to miss
  now: nothing moves a car until a running `update` does.

### And then the other two families

The diagram vehicles and the airport's aircraft followed, on the same argument
and with the same shape of fix: both motions are pure functions of elapsed
time, so an action was storing a program to compute arithmetic.

- **A route vehicle** was `SKAction.follow` out and back with `orientToPath`.
  It is a fraction along a polyline now, with the cumulative lengths kept per
  vehicle so a frame is a search rather than a re-measure of the whole line.
- **The aircraft** lives in `IsoTileRenderer` but is flown by `GameScene`, and
  what crosses that gap is the **geometry as data**: the renderer records the
  runway's two ends on the sprite's `userData` rather than letting the scene
  recompute them. This file already warns that a second implementation of the
  projection lines up until the day it does not, and `userData` is where this
  project already hangs per-node facts — the decoration cache keys work the
  same way.

**`animatedBySimulation` is down to the fire and the rain.** Every vehicle in
the game now stops because nothing advances it, which is strictly better than
being told to stop: there is no newly-built node for the pause walk to miss.

One fixture trap worth recording, because it is the same one twice in a day:
no single view carries all three. Ambient cars are drawn only where the road
network is shown, and a route diagram only in its own line's view — so a test
asking for both at once measures a city with no cars in it, exactly as the
first motion test did by not ticking. `CityMotionTests` visits two views.

### Three tests that had to be restated, not relaxed

Two in `PauseStopsTheCityTests` and one in `TransitOverlayTests` asserted on
`SKNode.isPaused`, which was never the property anyone wanted — it was the
*mechanism* that delivered it. All three now assert on **where the vehicle
actually is** across a few frames, which survives this change and would have
survived the previous one. Same standing rule as ever: when a test fails, ask
whether the thing moved or the yardstick did. Here the thing moved,
deliberately, and three separate yardsticks turned out to have been measuring
a proxy the whole time — which is itself the argument for asserting on
observable state rather than on the flag that happens to produce it.

### One fixture lesson, and it is the usual one

The first motion test measured a city **with no cars in it**.
`Traffic.carCount` returns zero for zero congestion, and congestion comes from
routed commutes, so an unticked city has empty streets by construction — a
picture in which the failing case cannot occur, for the fifth or sixth time in
this file. The fixture ticks now.

## Phase 1: the grade, and a value that stopped being right

Planned as "scale grain and chromatic aberration with the camera, the way the
bloom's reach now is." **Neither of them turned out to be the problem**, which
is the third time in two days that the obvious mechanism was wrong about this
shader — so the phase opened by isolating every term at the closest camera
rather than by editing one.

With each knocked out in turn: switching off **chromatic aberration** produced a
frame indistinguishable from the full one, and **grain** barely moved it.
Switching off the **bloom** was the whole difference.

### 21% against 4.8%

That was surprising, because the bloom's *reach* had already been pinned to a
constant 23 screen points. What had not been measured is how much of the frame
it is reaching *from*:

| camera | fraction of the frame above `bloomThreshold` |
|---|---|
| 0.5 (closest) | **21.4%** |
| 1.0 (rest) | 20.4% |
| 2.0 | 9.0% |
| 3.0 (widest) | 4.8% |

A lit window at the widest camera is three pixels, and averages with the dark
facade around it into something under the threshold. At the closest camera it
is forty pixels of pure lit colour, every one of them over. So the bloom's
*input* is four and a half times larger at the zooms the game is played at —
and bloom was reviewed on whole-city frames, which is the one view where it
lands on a twentieth of the picture and reads as an accent rather than a veil.

### And why the value had to move now rather than earlier

`bloomStrength` was 0.55, and 0.55 was chosen when every pixel in the frame
sampled the **same sixteen directions**. A bright source deposited its light in
sixteen discrete spots; the per-pixel rotation that fixed the ghosting spreads
that same energy over a filled area instead. Fixing the ghosting therefore
changed how *dense* the bloom is, and the strength it had been tuned against
stopped being the right one. The re-tune is a consequence of the fix rather
than a separate opinion about it.

**The obvious answer was to scale strength with the camera, and the renders
said not to.** 0.28 is better at *both* ends — crisper windows up close, and
more depth between buildings across a whole city, with the neon still
glowing — so it is one number rather than a second curve nothing could justify.
Worth recording because this file keeps arriving at "tuned at one zoom is tuned
at exactly one zoom" and this is the case where the fix was *not* a curve: the
value was simply wrong everywhere, and only looking at both ends showed it.

Still a judgement rather than a measurement, and it is the kind this project
sends to a playtest: two renders at two zooms say 0.28, and how it feels to
play in is not something a still can answer.

## Two bugs a play session found in a day's work

Reported together: *"the game is running really slow now, also when you select
a new thing to build it takes you back to the center of the map."*

### Picking a tool threw away where you were looking

`didChangeSize` recentred the camera, with a comment calling the lost pan "a
fairly minor annoyance" — fair when a resize meant dragging a window edge.
Moving the simulation controls into the tool rail made it anything but: the
rail **changes height** when a category with more chips wraps it to a second
row, so picking a different tool resized the map view and discarded the pan.

Recentring was never doing the job it claimed. What keeps a map findable after
a resize is `clampCameraToMap`, which was already being called; the recentre on
top of it was only destroying information. A resize now keeps the camera where
the player left it.

Worth keeping as the shape: **a trade-off is only as small as the thing that
triggers it.** Nothing about that comment was wrong when it was written — what
changed was how often the condition fired.

### And oversampling at 4 was the slowness

Measured back to back **in one process**, which is the only honest way to
compare on this machine: it throttles under a long test run, so two readings an
hour apart say more about its temperature than about any change. A built-out
64×64 city at 1280×800:

| oversample | mipmaps | ms/frame | texture |
|---|---|---|---|
| 4× | yes | 49.4 | 215 MB |
| 4× | no | 52.3 | 215 MB |
| **2×** | yes | **19.3** | **54 MB** |
| 1× | no | 16.4 | 14 MB |

**Four triples the cost of drawing a frame.** It is back to two.

Textures also carry **mipmaps** now, which they never did. At 4× a screen pixel
covers sixteen texels, and without mipmaps the GPU samples the full-resolution
texture anyway — cache-hostile, because consecutive pixels land four texels
apart, and aliased, because sixteen texels get represented by one of them. The
speed it buys is small (52.3 → 49.4); the aliasing it removes when zoomed out
is the real reason to keep it.

#### Two wrong numbers, both mine, and the second was worse

This started at 2, went to 4 on a memory estimate, and has come back. The
estimate said a built-out city held ~19 MB at 1×, so four would be 300 — a
ceiling. A measurement then "corrected" that to 1.6 MB at 1×, making four look
like 25 MB and the ceiling imaginary.

**The correction was the wrong number.** It was taken on a *40×40* city and
counted only the building entries — while the ground diamonds, lane lines,
conduits, badges and vehicle sprites in the same cache oversample too, and the
near-detail tier doubles what a close camera keeps resident. On a 64×64 city
four is **215 MB**. The original instinct was closer to right than the
correction that overruled it.

The lesson generalises past textures: **a measurement taken on a smaller
fixture, over a subset of the thing being measured, is not a correction.** It
is a second guess wearing a number's clothes, and it is more dangerous than the
guess it replaced because it arrives with authority. `OversampleCostTests`
measures the whole cache on the largest city that exists, in one process.

#### What two gives up

Two is exactly Retina at the *resting* camera, which is where the game is
played; the closest camera is magnified past it again. What makes that
survivable is `IsometricBuilding.Detail`, built since — it puts real marks back
at close zoom, and **marks beat pixels**. Sharpening a picture cannot add what
was never in it, which was always the larger half of the original complaint.

### One shader line that was not the problem, kept anyway

The bloom's spiral applies its per-pixel rotation with an angle-addition
identity now rather than rotating inside the loop, because
`cos(angle * float(i))` is a loop constant the compiler can fold while
`cos(angle * float(i) + spin)` cannot. It was expected to be most of the
regression and measured as almost none of it — the loop evidently was not being
unrolled either way. Two transcendentals per pixel instead of thirty-two is
worth keeping regardless, and the expectation is recorded as wrong.

`matchBloomReachToTheCamera` also stopped calling
`calculateAccumulatedFrame()` every frame. That walks every node under the
effect layer — eight thousand on a built-out city, measured at **0.35 ms
against 0.42 ms for the whole of `update()`** — and it only changes when the
culling attaches something or the camera moves, both of which were already
tracked.

## "It glitches between the zoom and scroll"

Reported from play, and a far more useful sentence than "it is slow": a hitch
*while the camera moves* is a different fault from a low frame rate, and it
points at work that only happens when the view changes. **Nothing in this
project had ever measured that** — every render timing here was taken on a
stationary camera.

`CameraMotionCostTests` measures it, and `update()` alone came back:

| | ms/frame | |
|---|---|---|
| camera still | 0.067 | |
| panning | 0.544 | 8× still |
| zooming | 1.350 | 20× still |

### Four things, and the last one was the actual glitch

- **The culling re-culled on every frame of a pan**, because it compared the
  exact visible rect and any sub-point movement failed the guard. Snapped to a
  tile now, which costs nothing against a twelve-tile margin.
- **The bloom's shaded area was re-measured on every frame of a zoom.**
  `calculateAccumulatedFrame()` walks every node under the effect layer —
  eight thousand of them. Re-measured on a 2% change of scale now, which moves
  a 23-point reach by less than half a point.
- **The culling walked a dictionary and re-projected every tile.** A tile's
  projected position never changes; it is a flat array now. (Honestly: this
  one measured as *no* improvement. Kept because it is plainly better, and
  recorded as an expectation that was wrong.)
- **Every tile coming back into view was refreshed**, which was added with the
  detail tier and is the one that mattered. A pinch sweeps thousands of tiles
  in and out; refreshing each was **1.0 ms of a 1.45 ms zooming frame**.
  Everything else that changes a tile already visits the detached ones — a
  tick, an overlay change and `refreshAll` all walk `tileNodes` regardless of
  attachment, and a placement goes through `rebuildRegion`. The *only* thing
  that skips them is the detail-tier swap, so that is the only thing that has
  to leave a note: `staleWhileDetached`.

Panning 0.544 → 0.194 ms; zooming 1.350 → 0.769 ms.

### But a hitch is one frame, not an average

None of that was the reported symptom, and the averages above could never have
found it. Timing the *individual* frames of a pinch did:

**49 ms on the frame at camera 0.712** — the detail threshold. Three dropped
frames, every time the player crosses it.

It is the texture cache filling on demand. A building's texture is rasterised
the first time it is asked for, and a tier swap asks for every visible lot at
once, on the frame the camera moved. `pendingRefresh` spreads that over frames
at four lots each, which costs nothing anybody can see — a lot is redrawn a few
frames later than it might have been — against a stall long enough to feel, as
it was described, like the machine had run out of memory.

**Worst frame of a zoom sweep: 49.4 ms → 4.8 ms**, and the test asserts on the
maximum rather than the mean, because the maximum is the thing a player feels.

### And the benchmark measured itself

The first run of this reported **768 ms** for that frame. It was real, and it
was the benchmark's own fault: the phase-by-phase breakdown drives the camera
while running only one phase at a time, which leaves the scene owing a large
catch-up that the next measurement then paid for. Measured first, on a scene
nothing else has poked, the same frame costs five milliseconds.

**A benchmark that disturbs the thing it measures is measuring itself** — and
it is a close cousin of the yardstick that reimplements its subject, which this
file already records four times over.

### One test restated

`CloseZoomDetailTests` asserted the tier swap happened on the next `update`.
It happens over a few frames now, deliberately, so the property became "it
finishes *promptly*" — settled until the queue drains, with a bound on how many
frames that may take. Instant was never the thing worth having; finishing
without dropping frames is.

### The scrolling stutter was never the scrolling

Reported again after the camera work above: *"still stuttering when scrolling
across the map. It's not smooth like butter how we always say."*

Recording **every** frame of a 150-frame pan rather than an average found one
spike, and only one: **frame 120, at 800 ms.** Frame 120 at one sixtieth of a
second is 2.0 seconds, which is exactly `SimulationSpeed.normal`'s interval.
Not the camera at all — the tick, landing on a single frame every couple of
seconds while the view happened to be moving, which is when a dropped frame is
most visible.

**The two halves of a tick on Apex**, the densest city this project ships:

| | Debug | Release |
|---|---|---|
| `advanceSimulation()` | 654 ms | 50.6 ms |
| `refreshAll()` | 82 ms | 37 ms |
| **one frame in 120** | **736 ms** | **87 ms** |

44 dropped frames in Debug, 5 in Release. **Which build is being played is the
single largest factor in how this game feels**, and `Cmd-R` gives Debug.

And inside the simulation half, on this city:

| | |
|---|---|
| `Traffic.computeLoad` | **37.3 ms** |
| the rest of `CitySimulator.advance` | 1.4 ms |
| `Pollution.compute` | 1.2 ms |
| `ZoneDistanceField.compute` | 0.5 ms |

Three quarters of a tick is one function, which is exactly what this file has
said since `ZoneDistanceField` landed — *"caching them is the obvious next move
if ticks need to get cheaper again"*. They need to get cheaper again.

#### What was fixed, and what the number now is

`refreshAll` walked every tile the map has, after every tick. The cache keys
make an unchanged decoration cheap, but cheap is not free — the key still has
to be built and looked up before it can say nothing happened, and two thousand
tiles' worth of that *is* the cost. It refreshes the tiles on screen and marks
the rest, which the culling redraws as they come back into view. On a 64×64
city at rest that is 1,651 of 2,387 tiles, so the saving is proportional and
modest; zoomed in it is most of the map.

With the simulation paused — the camera alone, which is what the previous pass
was about — a scroll now delivers **1.6× spread between its worst frame and its
median, and no spikes at all.** That is the part that is smooth. The tick is
not, and `testScrollingDeliversFramesEvenly` pauses the simulation deliberately
rather than flattering itself: a benchmark that measures a scroll while
something else dominates every reading is a test of that other thing wearing a
scroll's clothes.

#### The honest state of "smooth like butter"

Steady-state scrolling is smooth. What is not smooth is that the city stops to
think every two seconds, and the fix is the traffic cache this file has had on
its list since the beginning — **not** a rendering problem, which is where the
last two days of this work have been looking.

## The tick learns to use more than one core

Asked while playing: *what is the point of all these compute and GPU cores if
a game like this has issues?* A fair question, and the answer was a
measurement rather than a defence. This machine is an **Apple M3: 8 CPU cores
(4 performance, 4 efficiency), 10 GPU cores, 16 GB**. The game was using about
one core, and the GPU was not the bottleneck at all — what costs on the render
side is the CPU walking eight thousand scene nodes to *describe* a city a
10-core GPU could draw hundreds of times a second.

### Three guesses, three measurements, and only the last guess was right

Worth recording as a sequence, because the pattern is the lesson:

1. **"The searches are the cost."** `Traffic.computeLoad` runs a flood fill
   over the road network per home, which sounds like the expensive part.
   Measured: **7.4 ms of 37.2 — 21%**.
2. **"The sort inside the inner loop is the cost."** It called
   `job.frontage.sortedByPosition()` per (home, job) pair — 233 homes against
   ~200 jobs, re-sorting the same unchanging sets about forty-six thousand
   times a tick. Hoisting it to once per job is obviously right and it bought
   **37.2 → 34.9 ms, 6%**.
3. **The transit journey lookup.** Measured by deleting the city's lines and
   running the same city again: **46%**. Which is exactly what this file
   already predicted when the transit graph landed — *"the cost is the
   per-(home, job) journey lookup, which walks the boarding points at each
   end"*.

Three assumptions about one function, two of them wrong, all three cheap to
check. The hoist stayed because it is free and correct; the headline was
somewhere else.

### The split that made it parallel

Both expensive halves live in the same per-home loop, and that loop turned out
to be **two different kinds of work wearing one `for`**:

- Working out what every job would cost this household reads only the road
  network, the transit graph and the job sites — all fixed for a tick. It is
  independent per home.
- Deciding who actually *gets* the place is not: a job has room for so many
  people and a line has seats, so this home's outcome depends on who was
  served first.

`HomeRouting` is that seam. Phase one runs across the cores; phase two runs
sequentially, **in exactly the order it always did**, which is what keeps the
answer identical — `chooseJob` is seeded from the home's own position rather
than from a shared generator, so nothing depends on which core finished first.

| | before | after |
|---|---|---|
| `Traffic.computeLoad` | 35.7 ms | **11.0 ms** |
| `advanceSimulation()` | 50.6 ms | **24.4 ms** |
| the tick's whole frame | 87 ms | **61 ms** |

**Written for every Mac, not for this one.** `DispatchQueue.concurrentPerform`
adapts to the cores it finds, so the same binary uses four on an M1 Air and
sixteen on a Max. What is hard-coded is a threshold on the *problem* —
`parallelRoutingThreshold`, 64 homes — because handing out forty homes costs
more in scheduling than doing them here. Scaling is not linear on Apple
Silicon and should not be expected to be: the searches alone measured **5.3×
on 8 cores**, which is what a four-plus-four split looks like.

### The test the ordinary suite could not be

`ParallelRoutingTests` forces both paths on one large city and asserts the
`TrafficLoad` is equal, then runs the parallel path six times and asserts it
agrees with itself.

It needs to exist because **the rest of the suite cannot check this**: the
quick playtest profile is a 24×24 city with fewer homes than the threshold, so
every scenario test in the project takes the serial path and would pass on a
thoroughly broken parallel one. `parallelRoutingThreshold` is not `private`
for exactly that reason — making the hottest function in the game concurrent
without proving the two routes agree would be the least defensible change in
this project, and `computeLoad` has already been non-deterministic once, from
`Set` iteration order, caught only because the harness failed its own
reproducibility check.

### And the redraw stopped repainting a city to change sixty lots

The other half of the tick. `refreshAll` ran after every one, walking every
visible tile — **37 ms in Release**, landing on the same frame as the
simulation.

Measured first, because change detection is only worth its risk if the change
is small. On Apex, per tick:

| | |
|---|---|
| tiles whose `Tile` changed | **~60 of 4,096** |
| tiles whose congestion crossed a step | ~30 |

So the old behaviour repainted 1,651 lots to catch about ninety. It now
redraws what moved, plus the neighbours that describe it — a road's lane line,
a conduit's run and a wet reflection are all statements about *neighbours*, so
a changed tile drags its surroundings in. That expansion is why it redraws 278
rather than 90, and it is deliberately generous: being wrong costs a stale map,
and being generous costs a few hundred microseconds.

**The tick's whole frame: 87 ms → 32 ms**, across this and the parallel router.

#### `ScenePlaytest` earned its keep twice in ten minutes

Change detection is the most dangerous kind of cache, because getting it wrong
does not fail — it leaves a map quietly out of date. This is the exact shape
`SceneAgreement` was built for, and it caught both mistakes immediately, by
name and by tile.

- **Reflections.** When the street turns wet, every reflection in the city
  changes meaning at once — and a reflection belongs to the *ground* it lands
  on, whose own tile has not moved. Nothing watching tiles can see it coming.
  `syncWeather` reports whether the wetness turned now, and a turn falls back
  to redrawing everything.
- **Traffic.** The first version bucketed congestion into twentieths and
  compared those. `Traffic.carCount` puts a car on *any* congestion above
  zero, and 0.0 and 0.04 are the same twentieth — so a street going from empty
  to busy was invisible to the diff, and six tiles of road expected a car and
  drew none.

The second is the more general lesson and this file has arrived at it from
other directions: **compare the value the renderer actually reads, not a proxy
for it.** A quantisation invented at the comparison site is a second opinion
about what counts as a change, and it will disagree with the first one
eventually.

## Placing a zone re-flooded the whole city's plumbing

Reported from play: *"especially when trying to place zones, you have to wait
for the game to catch up."* A placement does not tick the simulation, so this
was a third path — and it had never been measured on a built-out city.

Measured, in Release: **mean 10.99 ms per placed tile, worst 34.15 ms**, with
three frames of twenty-seven over budget. And the breakdown named it at once:

| | |
|---|---|
| `recomputeUtilitySupply` | **8.58 ms** |
| the scene's refresh and its neighbours | 0.09 ms |

`GameController.place` called it after **every** placement, and the comment
directly above that call already named the real condition — *"a tower or a
plant changes what is supplied the instant it lands"* — while the code checked
nothing. So dragging out a road re-flooded the water and power networks once
per tile.

`ZoneType.feedsAUtilityNetwork` is that condition written down. Nothing else
can move supply on this path: `place` refuses over occupied land, so no
building is cleared and the demand side cannot move either. **Placement: 10.99
→ 1.65 ms, worst 34.15 → 6.05, and none of twenty-seven frames over budget.**

Laying pipe is the sibling case and genuinely *does* change supply — but not
once per tile of a drag, which lays several per mouse event. The recompute is
coalesced to one per stroke.

### Three guesses before the measurement, all wrong

Worth recording because the sequence is by now a habit worth naming. The
suspects were `rebuildCullOrder` and `culledFor = nil`, both added to
`rebuildRegion` the day before — exactly the kind of thing that *should* be
the cause. Removing both changed the number by 0.1 ms. And for a 1×1 tool
`rebuildRegion` is never called at all, which reading the code would have
said before any of it.

### And two bugs on the way out, both caught by the suite

- **`recomputeUtilitySupply` was doing something that is not supply.** It also
  recomputed the tram tracks, so gating it on a utility condition left rails
  floating over bulldozed streets — `TramTests` caught that in one run. Rails
  follow the *streets*, so they are recomputed on any placement; they are
  cheap, and folding them into the expensive call meant every caller had to
  choose between recomputing rails it did not need and skipping supply it did.
- **Conduits were drawn against last moment's supply.** A run is drawn lit or
  unlit depending on whether it reaches a source, which is precisely what the
  recompute decides — so deferring the recompute while still drawing inside
  the loop painted every tile against the supply from before the run existed.
  `ScenePlaytest` caught it as the picture disagreeing with the city right
  after plumbing. The stroke now lays, recomputes, then draws.

Both are the same shape, and it is the shape this file keeps returning to:
**a function that does two things gets called for one of them**, and the other
goes wrong quietly.

## Phase 2: the ground gets its first mark

42% of a frame is road or bare land — measured, 1,387 + 353 tiles of 4,096 on
Apex — and until now every one of them was a flat diamond with a lane line on
top. Every other surface in this game has had passes; this one had never had
one. Kerbs and pavements are the first.

**A kerb is a statement about neighbours**, exactly as a lane line is: a
street grows a footway on each side that does *not* carry on into more street.
So it is drawn from the same sixteen-value connection mask, and the mask goes
into the *ground's* texture key rather than onto a sprite of its own.

That distinction is the whole reason this phase is affordable. Sixteen masks
against two street zones is a few dozen more entries in a cache that already
holds a hundred. A sprite would have been **one more node on every road tile
in the city**, and a built-out map has 1,387 of them — against a standing
budget of about 3.6 nodes per lot. `StreetSurfaceTests` pins that: a kerbed
street and an uninterrupted one carry the same number of children, and none of
them is an `SKShapeNode`.

Drawn per side rather than as one inset ring, because a crossroads has no
pavement at all and a dead end has three — a ring would put a kerb across the
middle of every junction.

### The colour is the constrained part

Asphalt is deliberately the **darkest** surface in the game: what makes a road
visible is the lane line glowing on top of it, and that needs the darkest
possible bed. A pavement bright enough to notice on its own would undo exactly
the fix that made the street grid recede. `RenderPalette.pavement` is a step
up from asphalt and still under bare ground — enough that a street has an
*edge* rather than bleeding into the lot beside it, and not enough to compete
with anything lit. Only the inner edge gets a kerb line; the outer edge is
where the lot begins and already reads, and a second line there would draw a
box around every street tile.

### Three things the tests caught, and the third is a rule

- **The pavement changed the tile's size.** A sprite's size comes from its
  node's accumulated frame, and the carriageway is inset 0.02 while the
  pavement reached the tile's true edge — so a kerbed tile rendered 64 points
  wide against an uninterrupted one's 62.8. Every street with a kerb would
  have sat a fraction out of line with the lots beside it, which reads as "the
  art is slightly wrong" and never as a bug. `groundInset` is shared now.
- **The city render drew no kerbs at all**, because it calls `IsoTileRenderer`
  directly rather than through a `GameScene` and so never passed a mask. Same
  blind spot that once left the backdrop, the utility badge and the traffic
  invisible in that render — **three for three, now four.** The tool for
  reviewing cities has to be told about anything the scene knows and the
  renderer does not.
- **The key described more than the picture.** Putting the mask in every
  tile's ground key — including the bare land and lots that ignore it — meant
  every tile beside a new road rebuilt its ground to produce a byte-identical
  texture, *and reported itself stale while doing it*. `ScenePlaytest` caught
  it as a row of empty tiles disagreeing after a cross street went in.

  Worth stating plainly, because it is the opposite of the failure this file
  usually records: **a cache key has to describe what was drawn.** Too little
  in it leaves a stale picture; too much is not a harmless safety margin — it
  is churn, and it makes the key lie about what it represents.

`Traffic.isRoadLike` stopped being `private` for this. "Is this a street" now
has exactly one answer on both sides of the simulation/rendering split, which
is the same reason `CityHazards.isExposed` and `CitySimulator.needsWater` are
called by the renderer rather than restated in it.

### A picture of the ground, at last

Every render in this project photographs a *building*. The surface one stands
on has never been in front of a camera, which is how it went eleven phases as
a flat diamond. `StreetSurfaceTests.testRenderTheStreetSurface` writes
`street-surface.png`: the six shapes a grid produces — crossroads, T, corner,
straight run, dead end, island — in two columns.

```sh
xcodebuild -project AlphaPlusPlus.xcodeproj -scheme AlphaPlusPlus \
           -configuration Debug -derivedDataPath ./build test \
           -only-testing:AlphaPlusPlusTests/StreetSurfaceTests

open ./build/ContactSheet/street-surface.png
```

The two columns answer different questions and both are needed. The left is a
tile at its resting size, which is the only place `minimumDetailSize`'s rule
can be applied. The right is 4×, the closest the camera gets on a Retina
display, and what it is for is telling **"this mark is too small" apart from
"this mark is not being drawn at all"** — which the left column cannot do, and
which is the first question a missing mark raises.

It draws through `IsoTileRenderer.makeNode` *and then calls `syncLaneLine`*,
because `update` does not: the lane needs the map to know its connections and
the renderer only has a tile. The neon runs straight over the middle of every
mark on this surface, so the first version of this sheet — without it — was a
picture of a frame the game never draws. It found that immediately.

### Stop lines were built, measured, and cut

The mark a crossroads wants is a bar across the mouth of each arm, and it was
built: four strokes straight into the ground texture, no node cost. The render
showed a grey **rectangle** sitting around the neon with a small cross at each
corner. Not four marks. One frame.

The cause is arithmetic rather than taste, which is why it is worth keeping. A
bar spanning the carriageway reaches 0.32 of a tile either side of centre, so
its ends sit at 0.18 from the edge — *inside* where the perpendicular bars sit,
at 0.26. Every corner is a crossing. And backing them off does not help,
because the bar and the gap between bars are the same 64 points fighting over
each other:

| bar spans | bar | corner gap |
|---|---|---|
| 0.64 tile | 22.9 pt | −2.9 pt (they cross) |
| 0.48 tile | 17.2 pt | 0.0 pt (they touch) |
| 0.32 tile | 11.4 pt | 2.9 pt |
| 0.18 tile | 6.4 pt | 5.4 pt |

**No row clears `NeonStyle.minimumDetailSize` in both columns.** That is the
rule in its original form — cut a mark that cannot be drawn big enough, do not
shrink it — reached by measuring rather than by looking, because here the two
failures look alike: a ring and four specks are both "the junction has
something grey on it".

The one placement with room is hard against the tile's edge, and a grid kills
that: every road tile in a built-out city is a junction, so two facing bars
would land either side of every seam and the street would read as a ladder.
Same answer the airport's static aircraft got, and the same reason each time.

What still tells a junction apart is the pavement underneath: a crossroads is
the one street tile with **no footway at all**, so it reads visibly wider than
everything around it.

### Street lamps: the light, not the lamp

The first piece of street furniture, and it rides the mask that is already in
the key — so it costs **nothing**. A lamp belongs on a footway, a footway
exists exactly where the street does not carry on, and that is what the mask
says: a crossroads gets none, a straight run two, a dead end three. The variety
is a consequence of the street's own shape rather than a roll, no new texture
dimension, no node on any tile, and a lamp cannot end up standing in a
carriageway.

**There is no lamp drawn — only its light.** The first version stood a mast up
with a lit head on it, which is the obvious drawing and is two marks this scale
cannot hold: a column 13 points tall and one wide is a hairline, and a head
three points across is under the floor outright. Rendered, they were a row of
antennae floating above the road, detached from it because a lamp at the tile's
up-screen edge rises further up-screen still. Cut, like the aviation beacon
before it.

What survives is a warm wash on the pavement, and getting it to read took three
corrections the render made one at a time:

- **Shaped along the footway, not as a disc on it.** A round pool centred on a
  footway 0.09 of a tile wide has to be under 0.09 in radius to stay on the
  tile — six points, invisible — and at any useful size it hangs over the lot
  boundary, where it reads as a separate slab of ground rather than as light on
  this one. Bounded in both directions instead. Which is the truer drawing
  anyway: a lamp does not put a circle on the pavement, it washes the length of
  footway it stands over and spills past the kerb.
- **Added, not painted over.** Alpha-blended onto a near-black ground a warm
  colour does not read as warm at all — it averages toward the ground and
  arrives as grey haze, a translucent panel lying on the road. Exactly the
  correction the traffic streaks needed one pass earlier: *a trace that cannot
  be brighter than what it lies on is paint.*
- **Eight nested quads, not three.** A shape node has no falloff, so a pool is
  built by stacking; three steps rendered as concentric rectangles, a target
  painted on the road. The count is what decides whether a stack reads as a
  gradient or as bands, and it is free here because all of it is rasterised
  once per mask and arrives in the scene inside one sprite.

Sodium, against a city lit in magenta and cyan, so a street reads as a
different kind of light from the buildings either side of it rather than as
more of the same — and kept low in value, because the ladder puts
infrastructure in the tier that recedes. The first additive pass was three
times too bright and made the pavement the warmest thing in frame, which is the
complaint this file already records against the old lane lines.

`testTheLampLightsTheFootwayAndNotTheCarriageway` asserts the **colour
arrives** rather than that the call was made — footway +0.055 warmth against
the carriageway's −0.063, measured off the rendered texture. Two marks added to
this surface now pass through several blend modes into one rasterised sprite,
which is more ways for a colour to silently not arrive, not fewer, and this
project has shipped that failure twice.

### Bare land, and the one surface whose failure mode is repetition

The last item in the phase, and the only one where a single tile cannot be
judged. Every other mark on the ground is a fact about *this* tile — a kerb is
about its neighbours, a lamp is about its footway — so it is reviewed one tile
at a time. Bare land is the field: there is exactly one `.empty` ground
texture, so whatever is drawn on it is drawn **identically on every unbuilt
tile in the city**, and a mark that reads beautifully alone becomes a regular
grid of itself the moment there are forty of them.

So `testRenderBareLand` writes `bare-land.png` — a 6×6 block at the resting
camera, deliberately not one tile and deliberately not magnified, because the
question is whether the field has texture or whether it has a pattern.

It answered on the first look, and the answer was not what the phase had set
out to fix: **the tile outline was the loudest mark on the surface.** A field
of them came back as graph paper, and no amount of texture inside a tile was
going to help while a pale line was drawn round every one.

Two corrections, and the first one is the transferable part:

- **Dimming the line does not work; removing it does.** The obvious fix was to
  draw bare land's edge fainter, and it left the grid intact — because the
  line is drawn from `RenderPalette.ground` and the fill from the zone, so a
  dimmer line is still a *different colour* from what it encloses. Forty of
  them are still a grid, just a quieter one. Stroking in the fill colour
  removes the mark rather than turning it down, and widens each tile into its
  own 0.02 inset, which narrows the dark seam between neighbours to well under
  a point. Unbuilt ground is not parcelled anyway: the grid a player needs is
  the placement cursor's, and a zoned lot already draws a surveyed outline of
  its own.
- **Bare land picks a look from its own position.** Eight variants, mixed
  through the same `variant(for:)` that stops neighbouring lots marching
  through the building variants in step. Only `.empty` does this — handing a
  lot eight identical grounds is exactly the churn `syncGround`'s comment
  already records, and the key has to describe the picture.

The marks themselves are five soft patches of lighter and darker earth, and
they are **large and almost valueless**, which is the opposite of the instinct.
Fine detail on a surface the eye is shown forty copies of at once is the moiré
quilt the backdrop already ran into. Two further corrections came off the
render:

- **Square patches read as a chequer** — forty little diamonds all the same
  shape, which is a pattern wearing texture's clothes. Sizing each axis on its
  own roll is the whole fix.
- **A single quad has a hard border**, and a hard border turns a patch of
  ground into a drawn mark. Each patch is four nested quads, the same way the
  lamp's pool is eight — a shape node has no falloff, so the only way to get
  one is to stack.

Patches stay inside the diamond, which costs the field a little and is not
negotiable: one overhanging the edge would grow the node's accumulated frame,
and a sprite's size comes from that — the bug the pavement shipped, where a
kerbed tile rendered 64 points wide against an uninterrupted one's 62.8.

Still zero shape nodes in the scene, which is the property the whole approach
rests on. Bare land is the most numerous tile on an unbuilt map, so a mark that
cost it a node would be the single most expensive thing on screen — eight
textures instead, against 353 tiles on Apex and a few thousand on a map nobody
has built on yet.

## Phase 3: density reads as darkness

Every building in this game is rasterised **alone** — that is the whole point
of `IsoTextureCache` — so a tower wedged into a packed block has always been
lit *identically* to one standing by itself in a field. The frame's bloom adds
light and nothing in this renderer has ever taken any away, which is why a
dense district reads as a lot of bright things near each other rather than as
somewhere dense. Real density reads partly as darkness in the crevices.

`GameScene.occlusion(at:)` is one number per lot: what share of its perimeter
its neighbours block, weighted by their own tier so a ring of houses barely
registers and a ring of towers is a canyon. A road or bare ground is open sky
and counts as nothing — which is what makes a corner lot brighter than one
mid-block, and that gradient *across* a block is the whole reading. A flat tint
over a whole downtown would say nothing about density.

### It subtracts light rather than adding dark

Which is this renderer's own rule, found once already and run backwards here.
Phase 4 of the visual overhaul recorded that **on a ground this near-black
there is nothing left to take away**, which is why contact at a building's foot
is drawn as a *bright* mark rather than as a shadow. So occlusion turns down
the light that is there: an enclosed lot's contact light and ground pool are
dimmed by up to 72%, and its silhouette by only 22%.

That split is deliberate. Darkening a whole building uniformly flattens a tower
rather than seating it, and the crevices between buildings are where density
actually reads as dark. It also folds the plan's separate "ground shadow from a
tall neighbour up-screen" into the same mechanism — a shadow needs light to
remove, and the pools are the only light the ground has.

**The tint is on the sprite, not in the texture**, which is what makes it
affordable: one cached variant still serves every lot that draws it, and a lot
whose neighbour grew re-tints without rasterising anything. Measured by
bulldozing a neighbour and watching the cache — **22 textures → 22**, with the
subject's shade going 0.22 → 0.

### The scale was calibrated against a layout the game cannot build

The first version scaled enclosure over 0…1 and the fixture — four towers
pressed against all four sides of a 2×2 — duly read 1.0. Measured on **Apex**,
the largest and densest city this project ships, the distribution was

```
step 0…5:   25%  44%  30%   0%   0%   0%
```

**The top half of the scale was dead weight**, and a whole built-out downtown
resolved into three shades. It cannot reach further: every lot in a city with
streets fronts onto one, and a street is open sky, so enclosure never exceeds
0.5. The fraction stays an honest physical number and the *scale* is cut at
`IsoTileRenderer.fullyEnclosed` instead:

```
step 0…5:   11%  15%  23%  21%  17%  13%
```

A real gradient across a real city. `testReportTheSpreadOfEnclosureOnABuiltOutCity`
prints that line into the build log and asserts it two-sidedly — collapse into
one bucket means a uniform tint, and everything in bucket zero means the
mechanic is not running.

Worth keeping as the shape: **a scale is a claim about the range its subject
occupies**, and the fixture that saturates it may be a configuration nothing in
the game can produce.

### Orthogonal neighbours only, and that is a correctness decision

Enclosure is a statement about neighbours, exactly like a lane line's mask, so
every lot it describes has to be redrawn when one of them changes — and
`refreshTilesChanged` expands a changed tile to its **orthogonal** neighbours.
Reading diagonals here would make a lot's appearance depend on tiles the diff
never brings in, and it would fail the way every stale-key bug in this file
fails: quietly, with the map showing less than it knows. `ScenePlaytest` would
catch it; better not to write it.

Quantised into six steps before it reaches any cache key, for the reason road
wear is: a neighbour three lots away growing a storey nudges it by a
thousandth, and a raw key would miss on every tile every tick and rebuild the
whole city once a second.

### And two yardsticks that measured the fixture

Both were mine, both failed on a working mechanic, and both are the same
mistake this file keeps recording:

- **Comparing textures across two scenes.** Each `GameScene` owns its own
  `IsoTextureCache`, so two of them hand back two distinct objects with
  identical content. Restated as a count, changed *within one city*.
- **Comparing texture counts across two cities.** The packed fixture holds five
  towers against the open one's one, so of course it had more textures. The
  property is what happens when a lot's enclosure changes, not what happens
  when a city gains four buildings.

### The render, and the fixture trap for the third time

`testRenderEnclosureAgainstOpenGround` writes `enclosure.png`: one city holding
a packed block *and* lone towers on open ground, in one frame. It has to be one
frame — every render in this project has shown that a mark judged on its own
flatters itself — and a number can say the middle of a block is more enclosed
than its corner while saying nothing about whether that reads as depth or as a
stain.

Its first run was **a picture of badges**: an unserved city wears a drop and a
bolt over every roof. Exactly what the rain render recorded, and laying pipe is
not enough on its own either — funding buys *capacity*, so eighteen lots at
density 5 need more than one tower or the city sits in an outage that looks
identical to having no mains at all.

```sh
xcodebuild -project AlphaPlusPlus.xcodeproj -scheme AlphaPlusPlus \
           -configuration Debug -derivedDataPath ./build test \
           -only-testing:AlphaPlusPlusTests/OcclusionTests

open ./build/ContactSheet/enclosure.png
```

## Phase 4: landmarks, so a skyline is about something

Every building in this game is one idiom — dark faces, a neon edge, lit
rectangles — so a density-5 tower was a taller density-3 tower and a built-out
downtown was a bar chart. `ZoneMassing.isLandmark(tier:seed:)` is the exception
each zone gets to make about itself, drawn for about **one top-tier lot in
twelve**.

**It is a property of the variant, not of the lot**, and that falls out of the
cache rather than being arranged: `IsoTextureCache` quantises a lot's seed to
one of thirty-two looks, so the roll happens against a canonical seed and three
of the thirty-two come back true. A lot that is a landmark is one on every
launch and every tick, for the same reason a lot's building does not reshuffle.

**Rolled on its own stream, with its own salt.** The obvious place is a first
roll inside each `make`, and that would shift every subsequent draw and
silently redesign every ordinary building in the game — a change to
nine-tenths of the city smuggled inside a feature about one-twelfth of it. A
separate stream leaves everything that is not a landmark byte-identical, which
is also what makes the contact sheet readable afterwards: the only cells that
moved are the new ones.

### One form per zone, from that zone's own vocabulary

A landmark that stopped looking like its zone would be a fourth zone. Each of
these keeps its own marks and adds the one thing reserved for it:

| | form | tops out at | ordinary |
|---|---|---|---|
| commercial | **spire** — a shaft a third of its lot across, a crowned setback, a lit collar and a mast | 6.6 | 4.8 |
| residential | **point block** — a wide two-storey podium under one slim shaft, balconies wrapping it all the way up | 4.5 | 2.9 |
| industrial | **the works** — an ordinary hall with one stack three times the usual, on a plinth | 4.6 | 2.7 |

**The silhouette is the point, not the height**, and that is why the commercial
one is *thin*. At the zoom this game is played at you cannot compare two
heights side by side, but you can see at a glance that one shape is
proportioned unlike everything around it. `testALandmarkStandsClearOfItsZones‑
OrdinaryTopTier` states it as a comparison against the zone's own tallest
ordinary variant rather than as a number, so it survives a retune of either.

**Industry deliberately does not grow a tower.** Its vocabulary is *wide and
low* on purpose — the opposite ladder — and a tall industrial building stops
reading as industry and starts reading as a badly-coloured office. A works that
dominates a view does it with one enormous stack, which is infrastructure
rather than floor space.

And the stack had to be **slender**. The first version went to nearly double an
ordinary chimney's radius, on the reasoning that a landmark should be bigger,
and the render was unambiguous: a fat post is not a chimney. What makes a stack
a stack is the ratio — this one is barely wider than the two slim ones on an
ordinary works and three times as tall.

### The two 3×3 civics were shorter than a block of flats

Measured before touching them: the stadium topped out at **1.8** tile units and
the power plant at **1.9**, against ordinary housing at 2.9 and an ordinary
office at 4.8. So the most expensive buildings in the game, covering nine lots
of ground each, stood shorter than the flats across the road. **Covering more
ground is not dominating**, and that is the clearest case in the project of a
mark not doing the job it was paid for.

- The **power plant**'s cooling towers roughly doubled, and a stack stands
  beside them — deliberately the same slender-and-very-tall language the
  industrial landmark uses, because a player reading a skyline should not have
  to learn two vocabularies for one idea. It reaches 5.0.
- The **stadium** keeps a narrow eave over its stands and puts the height into
  its floodlight masts, reaching 4.3.

`testTheBigCivicsStandTallerThanOrdinaryHousing` states both against housing
rather than against a number.

### Three things the renders and the standing tests caught

- **The sheet drew six ordinary buildings and nothing failed.** Asking the
  cache for a landmark's *canonical seed* draws something else entirely,
  because `rendered` quantises whatever seed it is handed and
  `canonicalSeed(for:)` is not a fixed point of `variant(for:)`. The fix is to
  walk **positions**, quantise each exactly as the cache will, and keep the
  first whose variant is the kind wanted — which is also the only honest
  instrument, since it is what the game does.
- **The stadium roofed over its own lit pitch.** At an overhang of 0.3 on
  stands raised to 1.9 it came back a solid block, and the lit field is the one
  mark that makes a stadium findable while scanning a city. Same failure as the
  airport's apron — *a volume that spans the lot paints over everything
  standing in it* — and the same answer: the identity mark wins and the bulk
  moves somewhere that costs nothing, which here is the masts.
- **The enlarged floodlight head overhung the lot**, caught immediately by
  `testMassingStaysInsideItsFootprint`. The old head cleared its corner by a
  hundredth of a tile, which is the kind of margin that is not a decision; the
  masts are inset by the head's own half-width now.

### Looking at them

```sh
xcodebuild -project AlphaPlusPlus.xcodeproj -scheme AlphaPlusPlus \
           -configuration Debug -derivedDataPath ./build test \
           -only-testing:AlphaPlusPlusTests/LandmarkTests

open ./build/ContactSheet/landmarks.png
```

Each zone's landmark beside an ordinary top-tier building of the same zone, at
one scale, over one ground line, with the two civics on the end. **The
comparison has to be in one frame** — a landmark is defined entirely by
contrast with what stands around it, so a sheet of landmarks on their own would
be six nice buildings and no evidence.

## Phase 5: more than one material, trimmed by measuring first

The plan's last phase was "glass curtain wall against punched masonry against
panel", and **its own acceptance test said most of it was already done**. The
check is whether the zones tell apart with hue stripped out, and a greyscale
crop of Apex passes it plainly: commerce's continuous bands against housing's
punched grid is a distinction that survives desaturation, which was the whole
point of the massing port.

So the phase was cut to what greyscale *actually* exposed, which was a
different thing:

- **Every surface in the city is the same two values.** One near-black face,
  one white window, on every building. Within a zone, every tower was the same
  tower — the variety was all in the outline and none of it in the surface.
- **The roofs are large and empty.** In this projection a roof is the biggest
  single face a 2×2 building shows, and most of them said nothing.

Worth recording as the general form: **a plan's verification step can retire
half the plan.** Running phase 5's own check before starting it is what turned
a large art pass into two narrow ones.

### Two materials per zone, and no more

`NeonStyle.Cladding` is the shared vocabulary, so a wall is drawn the same way
whichever generator asks for it — the same reason `NeonStyle`'s primitives are
shared at all. Commerce picks between a **curtain wall** and a **piered frame**;
housing between plain masonry and **precast panel**, with its slab lines
showing.

Deliberately not the same pair. Piers on a punched grid would read as a glazing
frame, which is the one thing housing's facade is defined against; bands on
commerce would compete with the glazing bands that *are* commerce's mark.
Industry gets neither, for the reason this file already records: its vocabulary
is big blocks of light, and dividing its lit bays would undo a decision made
on purpose.

**Clad before the windows.** Panels sort with the volume they sit on and ties
break on insertion order, so cladding added first draws under the glazing —
the way round a building is built, and the way round that keeps the lit marks
on top where the value ladder wants them.

### A `Panel`'s `v` range is a proportion, and that is a trap

The slab bands were asked for as 7% of the box height. A residential volume is
nine-tenths of a tile tall, so they arrived **two screen points thick** —
invisible, on every variant, with nothing failing. The same number means a
different mark on every box it is applied to.

Thickness is converted from world units once, inside `clad`. Same lesson as the
near-detail mullion, whose pane count comes from a panel's *projected width*
rather than from its width in tile units — and the same shape as every
`minimumDetailSize` finding in this file, arrived at from a new direction:
here the mark was not too small because someone chose a small number, it was
too small because the number was relative to something short.

### Rooftop plant, in the outer band

`IndustrialMassing` worked this out when it landed — *"a flat roof is the quiet
option, not a blank one"* — and its halls got rooftop plant. Commerce and
housing never did: their roofs carried a crown in the middle and nothing else.

One to three boxes in the roof's **outer band**, never the middle, because the
crown is the centre feature and keeping them apart is what stops a stair head
and a lit band arriving at the same spot with tied sort keys — which is how a
hospital's cross once collapsed into a single bar. Sized against
`minimumDetailSize` rather than against the roof: a third of a tile is ten
screen points at the resting camera, and four smaller ones would be speckle.

Everything here is inside the texture, so it costs **no nodes at all** — the
property the whole cache exists for, and the reason this pass could afford to
add marks to every building in the game.

### Looking at it

```sh
xcodebuild -project AlphaPlusPlus.xcodeproj -scheme AlphaPlusPlus \
           -configuration Debug -derivedDataPath ./build test \
           -only-testing:AlphaPlusPlusTests/WallMaterialTests

open ./build/ContactSheet/wall-materials.png
```

Eight consecutive *variants* per zone — the looks the cache actually draws
from — **with the colour removed by the test itself**, so the sheet written is
the one the decision was taken on rather than something desaturated by hand
afterwards. Hue is the channel this game has most of and leans on hardest, and
it will happily hide a facade carrying no information at all, which is exactly
what it was doing.

## The grade across the zoom range: the defect was not there

This file recorded, from looking at a crop, that *"a post-process tuned at one
zoom is tuned at exactly one zoom"* — the bloom's reach had drifted 2.3× and
was fixed, and the grade's intensity was named as the same problem and left.
`GradeAcrossZoomTests` measures it. **It is not the same problem, and it is
mostly not a problem.**

| zoom | local contrast | grain | grain share | aberration | ab. share |
|---|---|---|---|---|---|
| 0.5 | 0.0191 | 0.0028 | 0.146 | 0.0088 | 0.464 |
| 0.7 | 0.0269 | 0.0028 | 0.104 | 0.0114 | 0.425 |
| 1.0 | 0.0373 | 0.0030 | **0.080** | 0.0143 | 0.384 |
| 2.0 | 0.0285 | 0.0041 | 0.144 | 0.0080 | 0.279 |
| 3.0 | 0.0193 | 0.0045 | **0.234** | 0.0040 | 0.208 |

**Grain's amplitude is flat** — 0.0028 to 0.0045 across a sixfold change of
magnification, which is correct: it is computed per screen pixel and cannot
know how far away the subject is. What varies is the picture under it, and the
prediction had the direction backwards. Grain's share of the frame's own local
contrast is *lowest* at the resting camera and highest with the whole city in
view, where most of the screen is unbuilt land — not, as the note claimed,
"dirt on the glass when one window fills the same area".

So nothing was changed. The test stays as the standing guard that grain's
amplitude does not start tracking the camera — the same claim
`BloomTests.testTheBloomReachesTheSameDistanceAtEveryZoom` makes about the
bloom's reach, which *did* drift before anybody measured it. It deliberately
does not bound the *share*, which is a property of how built-out the fixture
is rather than of the shader.

### And the first capture of any scene is not the frame the game draws

The real bug this pass found, and it invalidates more than it fixes. The first
`texture(from:)` after a scene is built comes back **different from the
second, with nothing changed in between** — measured at **0.024** mean
brightness at the closest camera, which is larger than the entire film-grain
term being measured.

It presented as an eightfold grain spike at camera 0.5 that **moved to camera
3.0 when the sweep was reversed**. That is the benchmark measuring itself, and
this file already records the shape: the phase-isolated frame timing that
reported 768 ms for a five-millisecond frame because it left the scene owing
catch-up. Two guesses were spent on mechanisms first — the shadow-weighted
grain, then the detail tier — and both were wrong; what settled it was asking
whether two *identical* captures were even equal.

`CityPortraitTests` takes a throwaway capture now. Every render in this project
that photographs a scene it has just built was reading a frame the game never
draws.

## Where the transit half of a tick actually was

`Traffic.computeLoad` is three quarters of a simulation step. This file said
the remaining cost was the per-(home, job) journey lookup pairing the boarding
points at both ends — `O(homes × jobs × reach²)` — and named collapsing that
pairing as the fix.

**Measured on Apex, in one process, before and after: 10.9 ms → 11.0 ms. The
collapse bought nothing.**

The 46% the claim rested on came from deleting a city's lines and re-running,
which removes the coverage stamp and the whole all-pairs graph along with the
pairing, and so attributes all three to it. Enumerating instead:

| | |
|---|---|
| `computeLoad` on Apex | 11.0 ms |
| the same city with every line deleted | 4.7 ms |
| `Transit.coverage` | 1.13 ms |
| `Transit.graph` (88 nodes) | 0.69 ms |
| **unaccounted for** | **4.4 ms** |
| boarding points per home | mean **3.40**, max 6 |

A `reach` of 3.4 makes `reach²` a dozen steps; collapsing it saved a dozen of
nothing. The 4.4 ms was in a loop whose only remaining work was **allocating
arrays nobody read**: `TransitGraph.legs` walks the predecessor chain and
builds two arrays to say which lines a trip boards, and `computeLoad` asked
for that once per (home, job) pair — about 48,000 times a tick — for an answer
the job lottery reads the `minutes` off and discards. The legs are wanted
exactly once per home, for the job that actually wins.

| | before | after |
|---|---|---|
| `Traffic.computeLoad` | 11.0 ms | **7.5 ms** |
| transit's share of routing | 57% | 38% |

Bit-for-bit identical output, which is the only acceptable result here:
`computeLoad` has been non-deterministic once already, from `Set` iteration
order breaking route ties, and this change reorders exactly the loop that
breaks them. `JourneyLookupCostTests` pins it on Apex rather than on a
hand-built fixture, for the reason that bug needed — ties only happen on a map
complex enough to produce them — and checks the serial and parallel paths
against each other as well.

The collapse stayed even though it measured as nothing, because it is the
shape the lookup should have and it costs nothing to keep. It is recorded here
as a claim that measured false, which is what this file asks for: **"it will
also be faster" is a claim, not a bonus** — for the second time, and this time
the claim was in this file.

## Shipping: the product gap, and the first thing measured in it

An assessment of how far this is from a Steam release found the simulation
essentially done and the product around it about a third built. The full
write-up is the "The Product Gap" artifact; the short version is that the
remaining work is audio, settings, onboarding, goals, brand and platform
integration, and **none of it is simulation work**.

Two findings from that pass belong here because they are facts about the
repository rather than opinions about the plan:

- **Update: the music plays now.** `SoundtrackConductor` (App/) owns the
  player and the director, ticks ten times a second on the title screen and
  in the game, and Settings has a Music row (Off / Low / Medium / High),
  stored once in `UserDefaults`. Only the app constructs one, so the tests
  never open an audio device. What follows is how it stood before.
- **The game is silent, and the soundtrack keeps getting more finished.**
  `Audio/` now holds a band-limited synthesiser, a score, a mixer, a
  **`MusicDirector`** that decides which track a city has earned, and a
  **`SoundtrackPlayer`** that renders a track into an `AVAudioPCMBuffer` and
  hands it to an `AVAudioPlayerNode` — every piece of the chain, each one
  tested. `App/`, `Rendering/` and `Simulation/` reference **none of it**, and
  nothing constructs a player. The music has still never played.

  Worth stating as the shape rather than the status, because the status keeps
  moving: **the whole module is complete and unreachable.** What is missing is
  not a component, it is the half-dozen lines that own a player, watch
  `GameController` and pass the director's answer to it. A module nobody calls
  is the same defect as a control that does nothing, one level up — and this
  file records that defect twice already.
- **No picture anywhere shows the chrome over the city.** `ImageRenderer`
  cannot draw the hosted `SKView`, so the live-view render draws the map as a
  placeholder rectangle; every city render is taken with no cockpit. Whether
  the inspector covers something important, or the tool rail stays readable
  over a bright district, is unanswerable from anything in this repository —
  and the last five passes made the city considerably brighter underneath a UI
  tuned against the old one.

### Colour vision: the one meaning that was carried by hue alone

This project has twice written down that **a mark whose only channel is hue
vanishes on anything sharing the hue** — once when an ember-coloured fire
turned out to be invisible on an already-orange factory, and once when a
utility badge told water from power by hue alone. Colour vision deficiency is
that rule applied to the player rather than to the background, and the utility
overlay already recorded the suspicion: *"water's blue-against-red is
unmistakable, power's amber-against-red less so. If it bites, the answer is a
second channel rather than a third hue."*

`ColourAccessibilityTests` measures it — every pair of colours in the game that
means two different things, put through the Brettel/Viénot matrices. **One pair
collapses, and it is exactly the suspected one:**

| view | meanings | normal | deuter | protan | tritan |
|---|---|---|---|---|---|
| Water | supplied / wants water | 1.082 | 0.808 | 0.668 | 1.031 |
| **Power** | **supplied / wants power** | **0.516** | **0.060** | **0.112** | 0.203 |
| Zones | commercial / industrial | 0.460 | 0.409 | 0.430 | 0.334 |

To a deuteranope a powered building and one screaming for power are **the same
colour**, and the colour was the only thing saying which was which. Everything
else clears comfortably — including zone identity, which is helped by the
massing port giving each zone a silhouette vocabulary that survives greyscale.

**And there is no third hue.** A search over the colour cube for an alarm that
separates from water's blue, power's amber *and* the unlit tone under all three
deficiencies returns only near-white: this palette already spans what a
dichromat can see. That is the measurement that makes the second channel the
answer rather than a preference.

So the drop-and-bolt badge is drawn in the Water and Power overlays now. It was
suppressed there on the reasoning that "the overlays already have their own,
bigger signal for this — the whole lot's colour — so a badge on top would be
redundant", and that reasoning has now been measured and is false for Power. A
glyph does not care what anybody's cones do.

**The guard is two-sided**, and deliberately not "no two colours may be close":
the rule is that a pair of meanings may share a colour *only if something else
tells them apart*. `testTheOnlyMeaningsSharingAColourAreTheOnesCarryingAGlyph`
pins the exact set, so a new collapse fails it and fixing this one in colour
also fails it, asking for the list to be rewritten rather than quietly widened.
A colour comparison cannot see a glyph, so the other half is asserted on a real
scene.

One fixture lesson, and it is the oldest one here: the first version of that
scene test gave the *served* block no water, so it wore a badge anyway — for the
drop rather than the bolt — and the test failed on a working fix. The badge
reports whichever utility is missing, so a fixture missing a second one cannot
say anything about the first.

#### And `ScenePlaytest` caught the fix, which is what it is for

Sixteen failures, all of them "the picture stopped agreeing with the city"
under a utility view. `applyOverlay` removes every node in
`overlayDisturbedNodes` and the badge is one of them — but it does **not**
clear that node's cache key. So the badge survived the first build, was
removed on the next refresh, and then skipped as up-to-date forever. A freshly
built scene had it and an incrementally-updated one did not, which is exactly
the disagreement `SceneAgreement` exists to find and precisely the stale-key
shape this file already records for overlays.

The fix uses the seam that was already there. `OverlayMode.showsRoadNetwork`
exists because the Traffic view is a heatmap *of the streets* and has to keep
them; `showsUtilityBadges` is the same idea, and it rides on `OverlayPaint` for
the same recorded reason — the last time a decision like this lived at each
call site, three heatmaps silently painted nothing while the render reported
they were fine.

One difference worth keeping. `showsRoads` is set inside the case that wants
it, and got away with that because exactly one view does. A **second** such
flag set the same way is the shape that goes stale, so `paint` now sets it once
from the mode and the per-case builder became `basePaint`.

### Settings, and one control deliberately absent

There was no settings panel at all. The single thing a player could change
about how the game looks lived in a menu, and nothing about motion or the
keyboard was reachable or even written down on screen.

`SettingsPanel` holds three things, reachable three ways — the title screen,
`⌘,` in the menu, and a button on the tool rail — because a player looks for
settings before they have a city about as often as after.

- **Visuals.** The Classic/Cinematic picker moved here out of the menu. Moved
  rather than duplicated: a setting reachable two ways is fine, a *control*
  existing twice is the thing this project keeps going back to delete. Each
  option now carries a line saying what it does, because a picker with two
  invented words on it is not a choice anybody can make.
- **Reduce motion.** Ambient motion off, information-carrying motion left
  alone — the rain, the factory smoke and the slow swell in a building's
  contact light stop; traffic, the vehicles on a line, an engine running to a
  fire and the flame itself do not. The line is what a mark is *for*, not how
  much it moves, and a setting that quietly stopped telling a player where the
  fire is would be a worse accessibility failure than the one it fixes.
- **The keyboard**, read off `KeyboardControls.reference` rather than retyped
  in the view — the same reason the toolbar renders `ToolCategory.entries`.

**And no volume control**, which is the deliberate part. There is no audio in
the app yet, and a slider that moved nothing would be precisely the failure
this file records twice — `SKAction.colorize` on a plain node, and an overlay
tint cast to a type the ground had stopped being. Both compiled. Both did
nothing. Neither failed a test, because what was asserted was that the call had
been made. The volume arrives with the sound, in one change, or not at all.

`SettingsTests` asserts the *result* rather than the call: a fixture with a
smoking factory and a pulsing light, and the marks counted before and after.
It also pins that the controller's copy and the renderer's static move
together and that setting a value it already has does not redraw the city.

`reduceMotion` reuses `restyleRequests`, which purges every cached texture to
change three node-level animations. Knowingly heavier than needed: it is a rare
action, and given the two failures above, guaranteed-correct beat proportionate.


### A guided first city

The second P0 on the product-gap list. A new city opened on an empty map with
seventeen tools, thirteen views and nothing saying where to start.

`FirstCityGuide` (App/) is ten ordered steps — road, housing, jobs, Play,
growth, water, power, the Problems view, a fire station, City Hall — each
**finished by doing it**, never by clicking Next. It watches the city and
moves on when the road exists. `GuidePanel` shows one step at a time over the
map's bottom-left, and `GuideText` holds every word, for the reason
`InspectorText` does.

Four decisions worth keeping:

- **Progress is a record, not a reading.** Every step is checked on every
  update, not just the current one, so a pump put down before Play has
  already done the water step. And a done step stays done: bulldozing the
  road does not un-teach roads.
- **Every step has a button that does it**, or equips the tool that does.
  That is the standing rule, *every warning has an answer the player can act
  on right now*, applied to instructions. `testEveryShortcutAnswersItsOwnStep`
  performs each one and checks it really finishes its own step. The fire
  station is the one step whose tool is still locked on a fresh city; the
  button is shown disabled with the shortfall rather than hidden, and a test
  pins it as the only such step.
- **It watches state, not events.** "Opened the Problems view" is read as
  `overlayMode == .problems` from the `didSet` of every property a step looks
  at (`map`, `isRunning`, `overlayMode`, `isShowingCityPanel`). Hooking the
  picker instead would miss every other way into the same view: the menu,
  the guide's own button, a future shortcut.
- **Offered at founding, not forced.** `NewCityPanel` carries the choice,
  remembered with `@AppStorage` and on by default. It lives in the panel so
  the controller, and every test that builds one, never touches
  `UserDefaults`. `resetMap(guided:)` defaults to `false`, so every existing
  caller founds exactly the city it always did. The guide is not saved:
  loading a city ends it, because it is a record of what this session's
  player has been shown, not a fact about the map.

Cost: one pass over the tiles per map write, and only while a guide is
running and unfinished. It publishes only when a step actually completes, so
a tick does not announce eight changes to a panel that did not move.

`testAFirstCityCanBeWalkedThroughByDoingWhatEachStepSays` uses a real
controller with real placements and real ticks. A guide whose steps can only be
finished by a test that hands it a `State` is a guide nobody can finish.
`RetroUIContactSheetTests.testRenderGuidePanelStates` renders an open step, a
locked step and the closing card side by side.

### Milestones: a ladder that asks for more than a headcount

The goals item on the product-gap list, built as a ladder, as the player
chose. `Unlocks` is already a progression, but it is gated on population
alone, and population is the one number every strategy produces some of. A
city that never laid a pipe still reaches 1,500 residents on a big map.

`Milestone` (Simulation/) has five ranks. Each adds one skill to the
headcount: Hamlet (100), Village (400 + water), Town (900 + water, power and
schools), City (2,000 + clean air over the homes and a budget in the black),
Metropolis (3,500 + free-flowing roads and little rubble). A rank is earned
on a day the city meets **all** of its conditions at once, ranks are earned
in order, and the top rank earned is a high-water mark that rides in
`CitySave` as an `Optional`, like `peakPopulation`.

`CityScorecard` measures the conditions, and every number is *called* from
the system that owns it (`needsWater`, `Water.hasSupply`, `ServiceCoverage`,
`Traffic.congestion`), for the reason `CityHazards.isExposed` exists. It costs
**0.62 ms of a 20.2 ms tick** on a settled 64×64 city in Release, about 3%.

**Every threshold was measured, not picked.** `MilestoneCalibrationTests`
(opt-in, `PLAYTEST_FULL`) prints what eight strategies score on every field
at 32, 48 and 64 tiles. Each bar sits between a strategy that clears it and
one that does not, and `MilestoneTests` pins those pairs with the measured
scorecards:

| rank | cleared by | refused |
|---|---|---|
| Village | any serviced city | no utilities: water 0% |
| Town (32×32) | industry apart: 960 | default layout: 784 |
| City | industry apart: pollution 0.05 | mixed: 0.35 |
| City | — | dense services: losing 514/day |
| Metropolis | subway city: congestion 0.04 | best car-only city: 0.19 |

Two things the calibration found:

- **Employment was cut before it shipped.** It read 88–100% in every
  strategy on every map, because a city that zones any jobs employs nearly
  everybody. A figure that does not move cannot tell a good city from a bad
  one.
- **Every solvent strategy still banks money without limit.** Max tax reaches
  $15M on a 64×64 map. City's "in the black" condition cannot bite a city
  like that, so the ladder does not close the standing *money accumulates*
  finding. The closing lever still has to be something that costs money.

**Rewards are not built yet.** A rank is a name in the dashboard and a badge
when it is earned. What a rank *buys* is the next decision.

On screen, the rank is the first dashboard panel's title, which costs no
height. The next rank's conditions sit in a two-column Goal panel, each
marked with a tick as well as a colour. When the row is too narrow for a
fifth panel, the goal folds into a badge in Alerts. The narrow render caught
the first version squeezing Alerts to "A…", which is the urgent panel losing
to the one that can wait.

### Buying land

The player's call, modelled on Cities: Skylines. The map size chosen at
founding is the **region**. The city starts on the middle 16×16 and buys the
rest in 8×8 parcels. `LandOwnership` (Simulation/) is the rule, and
`GameController.landRefusal` is the one place the Land view's cursor, the
click and the Alerts hint all ask.

**Rank decides whether you may buy; money decides whether you can.** Each
rank permits a total number of parcels (6, 10, 20, 42, then all). Each total
is sized so that rank's land can hold the *next* rank's residents at 48 a
parcel, the default layout's measured density on the smallest map. An
allowance below that would be a deadlock: a rank you could only reach with
land that rank unlocks. `testEachRankAllowsLandEnoughToReachTheNext` pins it.

**It is the first money sink that is a purchase rather than an upkeep.**
Every sink before this was an upkeep, and a big tax base simply outruns
those. Parcels cost $2,500 × the number bought so far, so the first is a
quarter of a new city's treasury and buying out a 64×64 region costs about
$4.6M. That is the scale of the *money accumulates* finding. **The price is
sized by argument, not measured**: the harness zones a whole map at once and
owns all of it, so measuring this needs a scenario that buys as it grows.

**`nil` means all of it.** `CityMap.land` is an `Optional`, so every save from
before this decodes to a fully owned map. Every test fixture and every
playtest city is fully owned too, because they measure the city's own
economics and a land budget would turn them into measurements of how much
map the fixture started with. Only the founding panel passes `buyingLand`.

Two things the render decided:

- **Unowned ground is darkened on the sprite, not in a new texture.** One
  tint serves every kind of ground, water included, and the ground key
  gained an owned flag so a purchase redraws exactly the tiles it changed.
- **The Land view is lit, not tinted.** The first render came out maroon and
  navy for the reason the Problems view recorded: a tint multiplies into
  near-black ground and then loses up to 40% more to the vignette. Owned
  land and land for sale glow additively; land out of reach stays dark.

`LandOwnershipTests.testTheMapKeepsUpWithAPurchase` buys a parcel through the
scene and has `ScenePlaytest` check the picture in both views, because a
purchase repaints a whole parcel at once. That is exactly the kind of change
where a stale cache key would show up.

### Rank rewards: a building worth earning

The player's call: big ranks unlock "cool buildings". `RewardBuildings`
(Simulation/) is the single source for which rank earns what, and for what
each one does:

| reward | rank | does |
|---|---|---|
| **Neon Arcade** (2×2) | Town | adds land value like a park, harder (0.28) and further (7) |
| **Broadcast Tower** (2×2) | City | commercial demand +0.22 city-wide; a second adds nothing |
| **Arcology** (3×3) | Metropolis | 500 self-contained residents: taxed, counted for the ladder, never in `Demand` or on the roads |

**Gated on rank, not on a headcount.** Their `requiredPopulation` is zero, so
the population ladder never announces or blocks them, and
`Unlocks.isUnlocked` asks for the rank as well. A caller that does not say
what rank the city holds has not earned them. Locked chips say "Reach Town"
rather than a resident count, and the rank announcement names its reward.

Each has an identity mark nothing else has, checked against the city in
`RewardBuildingsTests.testRenderTheRewards`. The tower is the tallest thing
in the game, a mast rather than a building, and slender for the reason the
industrial landmark's stack is. The arcology is broad and tall at once, with
lit garden terraces at every setback. The arcade's mark is its sign, which
is the weakest of the three at a whole-city zoom.

**Every number is a first guess sized by argument** against the constant it
sits among (`parkBonus`, `boostPerPort`), and none has been playtested.
Their prices ($3k / $8k / $25k) and upkeeps are sinks aimed at the cities
rich enough to earn them.

`CivicServicesTests` asserted that the hospital is the costliest service,
and the rewards broke it. The thing moved rather than the yardstick,
exactly as freight did before, so it is restated with the rewards excluded:
they are landmarks a rank buys, not services residents rely on.

### Autosave and crash recovery

Nothing autosaved, so a crash, a force-quit or a flat battery lost everything
since the last Cmd-S. For a city builder that can be hours, which is a
refund rather than an inconvenience.

`CityAutosave` (App/) saves every two minutes, but only when the city has
changed, and also on quit and on returning to the title. The encode and write
run off the main thread, since a 64×64 city is megabytes of JSON. Writes go
through `CitySaveFile.write`, which is atomic, so a crash *during* an autosave
leaves the previous one intact.

- **A session marker** is written at launch and removed on a clean quit. If
  it is still there at the next launch, the last session did not end
  properly, and the title screen says so rather than silently offering a
  rescued city.
- **Continue now means the autosave on a relaunch.** It used to mean only the
  city still in memory, which never survives a relaunch, so the one moment a
  player most wanted to pick up where they left off was the one moment it
  was missing.
- **The origin comes back with the city.** A recovered city remembers the
  file it was opened from, so Cmd-S afterwards writes there rather than into
  the autosave slot, where the next autosave would overwrite it.
- **The change check is a fingerprint, not a hash of the map**, which would
  cost as much as encoding it: generation, day, treasury, how much is built,
  and land owned. `testEveryKindOfEditIsNoticed` pins it against placing, a
  *free* bulldoze and a day passing.

**Off unless the app turns it on.** Only `AlphaPlusPlusApp` hands
`CityDocument` a `CityAutosave`, pointed at Application Support. Every test
uses a temporary directory or none, so the suite never writes into a
player's saves. That is the same reason the founding panel, not the
controller, owns `UserDefaults`.

The render caught one thing: `RelativeDateTimeFormatter` described a save
from a second ago as "in 0 seconds". Under a minute it now says "moments ago".

## The Metal spike: the city as lit geometry

The player chose "Cyberpunk 2077 styling with the simplicity of Mini
Motorways", and asked whether that needs a real graphics engine. The answer
this spike tests is **our own renderer on Metal**. Unity, Godot or Unreal
would mean rewriting the Swift simulation and giving up the native-Mac
design. SpriteKit's ceiling is the look itself: light that falls on things,
reflections, haze, and sharpness at any zoom are all things a sprite engine
can only fake.

The reason it is tractable: **the buildings are already 3D descriptions.**
`BuildingMassing` is volumes in tile units, which SpriteKit flattens into
pictures. `MetalCityRenderer` feeds the same volumes to the GPU as geometry,
through a camera matched exactly to `Isometric.project`. The projection is
affine, so it is one matrix, with depth along `Isometric.toCamera`.

Four passes:

1. **Reflection.** The city drawn mirrored under the street. For a flat
   mirror and a fixed camera that is exactly what a reflection *is*, not an
   approximation of one. Street tiles mirror strongly, and land only in its
   puddles.
2. **Scene** (4× MSAA). Flat, dark faces lit by a weak moon; neon rims on
   every edge; windows and lit volumes as emissive; and point lights placed
   from each building's lit parts, street lamps and ground pools. The light
   falls on walls and street rather than being baked into one picture.
3. **Bloom**: five levels down and back up, the shape real lens bloom has.
4. **Composite**: ACES tone-mapping, haze from the widest bloom level,
   vignette, grain.

Not wired into the game. `MetalSpikeTests` renders one block through a real
`GameScene` and through the spike from the same map at the same moment,
dry, raining and at the closest zoom, into `metal-spike.png`. It is on
Quick's skip list, so it runs through the Full plan:

```sh
xcodebuild -project AlphaPlusPlus.xcodeproj -scheme AlphaPlusPlus -testPlan Full \
           -configuration Release -derivedDataPath ./build ENABLE_TESTABILITY=YES \
           test -only-testing:AlphaPlusPlusTests/MetalSpikeTests
```

**`-only-testing` inside a plan that skips the test runs nothing and still
reports success.** Found immediately, by the sheet not changing.

Two lessons from the first render, both the same as lessons this file already
records for SpriteKit:

- **Night comes from dim light, not black paint.** The first pass gave the
  ground and walls near-black albedo, so no lamp or sign could show up on
  them. Surfaces carry real albedo now, and the dark is a low ambient.
- **Neon blew out to white**, the saturation this project has hit four
  times. The fix was the same one each time: less emission, not more
  clamping.

**Measured:** 4–10 ms of GPU per 1200×800 frame for this block (about 3,100
triangles, 75 lights). The lighting loops over every light for every pixel,
which is fine for a block and **will not be fine for a 64×64 city**, which
would have well over a thousand lights. A real migration needs tiled or
clustered light culling first.

The shaders are a Swift string compiled at runtime (`MetalCityShaders`),
because this Xcode has no Metal toolchain. A `.metal` file fails the whole
build until someone runs `xcodebuild -downloadComponent MetalToolchain`.

### M0 (done): the Metal map in the real game

*Settings ▸ Renderer ▸ Metal (beta)* draws the city through
`MetalCityRenderer`, live. The plan is the "The Metal Migration" artifact.

**SpriteKit keeps everything that is not the city, for now.** In Metal mode
`GameScene.setDrawsCity(false)` hides the city, the sun and the backdrop,
turns off its post-process, and goes transparent. The scene keeps input, the
camera, the placement cursor, route diagrams and the rain, drawn *over*
`MetalMapView`, which reads the scene's camera every frame. So nothing about
placing, zoning, pipes, routes or the inspector changed, and each later
phase moves another piece across until the scene has nothing left to draw.

- **The shaders are a real `.metal` file** now that the toolchain is
  installed, so a mistake fails the build rather than the launch.
- **Buildings are cached** by zone, density and variant (`MetalCityMesh.Cache`),
  the same idea as `IsoTextureCache` one level up. The mesh rebuilds only when
  `GameController.mapRevision` moves, a counter bumped on every map write and
  deliberately not `@Published`.
- **MSAA colour and depth are memoryless.** On Apple Silicon a render pass
  lives in on-chip tile memory, so a target that is only ever resolved never
  needs to exist in RAM.

**Tiled light culling had to come forward from M1**, because measuring said
so. On Apex (the densest 64×64 fixture) at 2880×1800, every pixel checking
every light cost **57 ms of GPU at the resting camera**, about 17 fps. A
compute pass (`cullLights`) now lists, for each 32-pixel screen tile, the
lights that can reach it, and each pixel walks only its tile's list:

| Apex, 2880×1800 | before | after |
|---|---|---|
| resting camera | 57.4 ms, capped at 384 lights | **11.2 ms, all 1,453** |
| whole city | 18.3 ms | **6.9 ms, all 2,376** |
| mesh rebuild | | 4.7 ms with the building cache warm |

The reflection pass takes no point lights. It is blurred and mostly emissive,
and its fragments sit at mirrored screen positions the tile lists were not
built for.

`MetalMapTests.testTheLiveViewPresentsFrames` puts the real view in an
offscreen window and draws through the drawable, which no picture test
touches. It crashed on its first run, and the crash was the *test*: an
`NSWindow` made in code frees itself on close, and it was also released at
the end of the test. `isReleasedWhenClosed = false`.

### M1 (done): a 64×64 city inside the frame budget

Measured on Apex (the densest 64×64 fixture) at 2880×1800, with the GPU warm,
by `MetalMapTests.testApexFitsTheFrameBudget` in the Full plan:

| | |
|---|---|
| GPU, resting camera | **7.7 ms** (target 8) |
| GPU, whole city | 4.0 ms |
| CPU to prepare a frame | 0.1 ms |
| a day that changes nothing drawn | 0.18 ms, 0 chunks rebuilt |
| one building placed | 0.33 ms, 1 chunk rebuilt |

- **The city is 8×8-tile chunks, each with its own buffer.** A chunk is
  rebuilt only when a fingerprint of its tiles changes: zone, density,
  water, anchor and ownership, read one tile past its edge because a lane
  line depends on its neighbours. Traffic, wear and supply change every day
  without changing a triangle, so most days rebuild nothing. A chunk off
  screen is never sent to the GPU. **Chosen over instancing**, which the
  plan named: a building is a couple of hundred triangles copied out of the
  variant cache, so instancing buys little, where chunks buy both dirty
  rebuilds and culling in one mechanism.
- **SpriteKit does no tile work in Metal mode.** No per-tick diff, no
  redraws, no culling, no rebuilt regions: `GameScene` records what it owes
  and catches up in one pass when the city is handed back. What it still
  draws (routes, the rain, the cursor) keeps updating.
- **The main-pass shader never discards.** Apple GPUs skip shading pixels a
  nearer opaque surface covers, but not for shaders that can discard, so the
  reflection pass has its own entry point. Correct practice; it measured as
  no gain here.

**Three measurement traps, each of which made a wrong number first:**

- **Apple GPUs ramp their clock under load.** The first budget run measured
  12.5 ms for a frame that costs 7.65 once the GPU is awake. The test warms
  up with 30 frames first. A running game never draws from cold.
- **This machine's timing noise is ±50% between runs**, so a stage's cost
  comes from switching stages off and measuring in one process, interleaved
  (`MetalFrameBreakdownTests`, opt-in), never from comparing two runs.
- **The test's bound is 9 ms, not 8.** The target is 8 and it measures 7.7;
  a bound that holds by 4% is a coin toss.

**Where the frame goes** (resting camera, warm): point lights about 4.5 ms
(60%), bloom 0.8, reflection 0.4, everything else 1.8. Halving the
light-culling tile to 16 pixels changed nothing, because a light's reach at
this zoom is about 450 pixels, far bigger than either tile. The cost is how
many neon sources a dense downtown genuinely overlaps. If M2–M4 need room,
the lever is merging each building's several lights into fewer.

### Two test plans: Quick and Full

A full run took about 23 minutes in Debug, which is too long to run before
every commit. Measured first: 41 of ~900 tests carried 91% of the time, all
of them either whole playtest cities or the soundtrack synthesiser.

| plan | what | Debug | Release |
|---|---|---|---|
| **Quick** (the default, Cmd-U) | everything but the playtest cities and the timing benchmarks, in parallel | **97 s** | — |
| **Full** | everything, one class at a time | ~18 min | **182 s** |

Run Quick before every commit. Run Full before a merge to main and after any
balance change, and run it in Release:

```sh
xcodebuild -project AlphaPlusPlus.xcodeproj -scheme AlphaPlusPlus -testPlan Full \
           -configuration Release -derivedDataPath ./build ENABLE_TESTABILITY=YES test
```

Three changes got there:

- **Each soundtrack is created once per run.** The soundtrack suites asked
  `Soundtrack.render` for the same tracks at fourteen call sites, about 480 s
  in Debug. `RenderedTracks` caches by track name. The one test that *times*
  rendering still renders for real, and is opt-in.
- **Report-only tests are opt-in** (`TestReports`, `TEST_RUNNER_REPORTS=1`,
  or the full playtest profile). A spectrum printout, a render-cost readout
  and a grade-cost readout were a sixth of the suite and asserted little.
- **Quick runs in parallel, Full does not.** Parallel testing took the whole
  suite from 1,100 s to 372 s, and two timing benchmarks failed by a hair
  (16.9 ms against a 16 ms budget) because seven other processes were sharing
  the cores. A benchmark cannot measure honestly beside other work, so the
  benchmarks live only in the serial plan. That is the same reason
  `RenderTimingTests` takes the best of several batches: contention adds
  time, never removes it.

**Adding a slow test means deciding which plan it belongs to.** Anything that
simulates a city for hundreds of days, or asserts a time budget, goes on
Quick's skip list in `Quick.xctestplan`.

### Wet streets: light, not a mirror

Reported from play: the reflections were "really not landing". The close-up
showed why. Each reflection was the building's own cached texture, flipped
and squashed onto the tile in front of it, windows and outlines crisp. So
every wet tile carried a flat miniature of its building: decals on the
floor, not water.

Wet asphalt at night never gives back a *picture*. It gives back the lights,
each stretched into a vertical smear toward the viewer and broken up by
ripples. `IsoTextureCache.wetStreaks` is that: one white texture of two
soft streaks, cut into pieces whose gaps open up as the streak falls, tinted
per tile to the neon of the building behind it. There are four variants,
chosen by the ground's own position, and four textures serve every colour in
the game.

**Two tiles, not one.** A tile node can only draw on itself, because the
tile in front is drawn later and opaque. So a streak that should run a long
way toward the viewer continues onto a second tile of open ground, at half
strength. `GameScene.reflectionReach` is the one list of tiles a building's
light can reach, and both the placement path and the per-tick diff use it.
Anything that depends on a neighbour has to be written down once.

The first two passes were each wrong in a way only a picture showed. At the
old building-copy strength and width the streaks read as noise, and three
parallel bars cut at even intervals read as a graphic equaliser. Soft ends,
irregular breaks and two streaks fixed both.

**The old render could not have caught any of this.** The rain filmstrip
frames the whole map, where a reflection is a few pixels across.
`WetStreetTests` renders the same block dry and in the day-6 downpour at the
resting camera.

### M2 (done): the ground, the streets and the water

Streets became geometry rather than a flat quad: asphalt, pavements on the
sides a street does not carry on, a lit kerb face, sodium lamps on every other
tile and neon lane tubes (two on a highway). Bridges are decks standing over
the water. The land carries on past the map as a faint, gridded backdrop, and
bare land has low-frequency patches so a field is not one flat value.

**Rims only where an edge is real.** Rimming every pavement and deck face made
a street read as a segmented ladder. Only the kerb face and the open-water side
of a bridge deck carry one now.

**Water went through the same failure the SpriteKit water once did.** The
first surface was additive noise, and it read as lavender fabric. Water shows
almost nothing of its own. What makes it look like water is waves bending the
reflection, plus the odd glint of the moon. So four layered waves give a
surface normal, the normal offsets the reflection lookup, and the only colour
the water adds is a deep base and a sharp specular glint.

**Water is sunk 0.14 below the street behind rimmed quay walls.** Flush with
the land, a river was a line painted on the ground; with a bank, the city has a
waterfront. That needed the backdrop moved down to −0.2, or it put a lid on
every river in the city, and nothing failed when it did. The render showed the
backdrop's grid running straight across the water.

The wave distortion was first set twice as strong as it is now, and
reflections came back as funhouse smears. Half that reads as moving water.

**Budget, Apex resting camera:** 8.68 ms against the 9 ms bound, with 1,966
lights. The lamps were what pushed it over (9.36 ms). Radius 2.1 → 1.35 fixed
it, because light cost goes as the square of radius.

### M3 (done): everything that moves

Traffic, trams on their rails, ships on their lane, fire engines running to a
fire, aircraft rolling down a runway, flames, embers, factory smoke and rain,
all on the Metal renderer. `MetalMotion` is the Metal half; **`CityMotion`
holds the rules for both renderers**: the lane a car keeps to, how slowly a
jam makes it cross, what kind of vehicle a street carries, path speeds, the
runway and the aircraft's timing. `GameScene` was moved onto it in the same
change. A car that drove a different lane in Metal than in SpriteKit would be
the next entry in this file's long list of second copies that drifted. Apex
plans 302 cars in both.

- **Traces are light, not paint**: a segment with a width, instanced, added to
  the frame, depth-tested against the city and never writing depth. So a car
  behind a tower is hidden, and two crossing traces add up. The width has a
  floor in pixels, which is the rim lesson from M1.
- **Flames are blended over what is behind them**, not added. Five tongues
  added under bloom summed to a white blob every time. They carry the
  SpriteKit plume's slatted sunset ramp; without the slats they read as
  searchlight beams.
- **Fire is a real light**, flickering, and it lights the walls beside it. So
  does an engine's beacon.
- **Rain and smoke are GPU particles**: the vertex shader places each one from
  its index and the clock, so the CPU plans only a count. Rain falls over the
  ground the camera can see, and buildings hide it. SpriteKit's rain is off
  in Metal mode.
- **The ship keeps a hull**, as lit geometry, for the reason the SpriteKit
  ship did: it is what makes a seaport read as trading.

**Pausing works because everything is a function of the motion clock**
(`MotionClock`), which only advances while the city runs. There is nothing
to remember to stop. The water keeps the wall clock, because it is not part
of the simulation. `MetalMotionTests.testRecordTheCity` records 3 s running
and 1.5 s paused through `SceneRecorder`, which now records any frame source:
3.1% of the frame changes per frame while running and 0.03% while paused
(that 0.03% is the water).

Three things the renders decided:

- **The cars were invisible at 2.2× their colour.** They sat under what the
  tone map and the bloom lift off a lit street. Found by rendering one
  variable at a time (lift, width, brightness), because the obvious suspect
  was depth. Seven keeps the hue; past about ten they bleach toward white.
- **A close-up of hidden cars says nothing about cars.** In a dense downtown
  the camera sees streets mostly through canyons, and the towers in front
  correctly hide the traffic. The close-up is aimed by
  `exposedBusiestStreet`, the busiest street with nothing standing in front
  of it.
- **`Fire.count` was called once per car.** It scans the whole map, and it
  was 95% of planning Apex's traffic: placement cost rose from 0.6 to 3.0 ms
  against a 4 ms bound. It is asked once per plan now, and the plan takes
  0.3 ms.

The plan is rebuilt only when the city moves: a new day, a chunk rebuilt, a
tram line drawn or a fire started. An unchanged city asked again rebuilds
nothing. Apex still draws in 8.5 ms at the resting camera.

### M4 (done): what the map tells you

Every view, and every mark a building wears, on the Metal renderer
(`MetalOverlay`). **The decision is not made here**: which colour a tile gets
under which view, and what happens to its building, is still
`IsoTileRenderer.paint`, the one call SpriteKit and the city render make.
Metal only decides how that answer looks when light is real:

- **The ground is lit, not tinted.** A view's colour is added to the street
  as light, at a third of its strength. At full strength every heatmap was a
  glaring plate: the palette was picked as paint, and as light it goes
  further.
- **A heatmap removes the buildings.** Each chunk's buffer is ground first
  and buildings after (`Built.groundFloats`), so a view draws the first part
  alone. A network view washes each building toward its answer in the shader,
  one texel a tile, using SpriteKit's own blend factors (0.78/0.92). A source
  the player is hunting for is left alone.
- **What a player came to find is drawn over everything**: pipe and power
  runs, lit where they reach a source and dim where they do not, tram rails in
  the Tram view, and badges. Badges are billboards a fixed number of pixels
  across, drawn from the same `dropPath`/`boltPath` the SpriteKit badges use.
  **Scaffolds and damage** are Normal view's, as they are in SpriteKit, and
  the badge condition is `IsoTileRenderer.missingUtilities`, shared.

**Colour vision was measured on rendered pixels**, not palette entries,
because a lit renderer changes what a colour looks like
(`testTheRenderedViewsKeepTheirMeaningsApart`). Under the three deficiencies
the result matches SpriteKit exactly: the only pair that collapses is
Power's served/wanting (0.13), and that view carries the bolt. Its fixture
needed three corrections before it measured anything, all the usual lesson:
a "wanting water" block that had water, one pump short of the city's demand
(an overloaded network serves nobody), and a pump one tile too far away.
`hasSupply` asks about the tile itself, not the building.

**A view costs up to 13 ms to rebuild on Apex, in Release**, and it is rebuilt
on every change of the map, so a click with a view up can hitch a frame. It
is the shared decision itself (land value, congestion and coverage per
tile), which SpriteKit pays too. It was measured before guessing: the
obvious suspect, colour conversion, changed nothing when removed. It stays
under the 16 ms bound, and moving it off the drawing path is M7's job.

**The placement cursor, the land cursor and the route diagrams stay in
SpriteKit for now**, although the plan put them here. They already draw
correctly over Metal through the transparent scene, and they belong with
input and the camera, which the plan moves at M8. Moving them now would mean
a second copy of cursor logic living beside the first until then.

### M5 (done): the safety net comes across

`ScenePlaytest.drawWithMetal()` hands a session's city to the Metal renderer
the way the Renderer setting does. Every frame it then reads the controller
exactly as `MetalMapView` does (revision, view, traffic flag), and `check`
asks **`MetalAgreement`** instead of `SceneAgreement`. The yardstick is the
same kind: a Metal renderer built fresh from the same city, compared against
the one updated change by change. It compares every chunk's triangles and
lights byte for byte, the motion plan and the view. Buffers rather than
pixels, because a buffer names the chunk that fell behind where a pixel diff
only says "somewhere".

`MetalPlaytestTests` runs a scripted session, building and bulldozing while
paused under every view (when no day passes to wake the motion plan), and
the random player. **Six random sessions of 300 steps run clean under
`PLAYTEST_FULL`**, which is the plan's bar.

**The yardstick was proven before it was trusted**: a planted bug (chunk
signatures ignoring density) failed the random player within a few steps.
It also exposed that the scripted session could not fail on it. Eight days
is shorter than one storey takes to build, so nothing ever finished growing.
Its growth spells are a month now.

**And it found a real bug on its first long run.** A building's window lights
were gathered in a `Dictionary` keyed by wall, whose iteration order is not
stable between two dictionaries holding the same keys. So two builds of the
same building listed its lights in different orders: identical triangles,
"stale" lights. That is invisible until a screen tile reaches the 64-light
cap, where the order decides which lights survive. It is the same shape as
`Traffic.computeLoad`'s `Set`-order bug, and the fix is the same: a fixed
order wherever order decides an outcome.

### M6 (done, first rounds): the look

Taste, done without its reviewer. The player was asleep, so each call below
was made against the brief ("Cyberpunk 2077 with the simplicity of Mini
Motorways") and recorded so it can be reversed. `MetalLookTests.testRenderTheLook`
is the instrument: Apex at the closest, resting and widest cameras, dry and
in rain, plus the river city. `LOOK_NAME=metal-look-before` kept the starting
point for comparison.

**The widest camera was the real failure, and it was the zoom lesson again.**
The city dissolved into pastel lavender. Two causes, both invisible at the
resting camera the look had been tuned at:

- **Rims have a 1.4-pixel floor** so they survive the camera pulling back,
  and at the widest camera a face is a few pixels across: the rim covered
  it, and every building came out the colour of its outline. Where the floor
  has taken over, the rim now gives back energy in proportion (never below
  30%). The edge stays; its light does not flood the face.
- **Bloom and haze were one strength at every zoom**, while pulling back puts
  three times the lights in every region of the frame. Both now scale with
  pixels per tile (haze as the square), and are unchanged at the resting
  camera.

**A grade, for the milkiness at rest**: a toe that presses only what is
already dark toward black, and 15% more saturation. Deep black with
saturated neon in it, which is the brief, rather than pale windows in a
lavender veil.

**Ragged windows were z-fighting.** Cladding and glazing sat at the same
offset from the wall. Lit panels now stand further out than dark ones, which
is the order the massing already layers them in.

**Close-up detail as geometry.** `IsometricBuilding.nearDetail` (mullions,
and a slab line per row) is now shared, so the Metal renderer draws the same
marks SpriteKit's near tier does, as polygons standing proud of their panel.
The tier follows pixels per tile (on at 178, off at 164, hysteresis for the
reason SpriteKit's has it), and chunks are swapped four a frame, visible
first. The worst frame of the swap on Apex is 2.9 ms.

**Classic and Cinematic carried across**: Classic is the ungraded Metal
frame (no bloom, haze, grain or grade), and a test asserts the switch
changes the frame rather than that the setting was set. Reduce motion was
already carried in M3 (rain and smoke).

**Left for the player to judge**: the flames are softer than the SpriteKit
plume. The Traffic view washes every tile green, which is the shared paint
decision and not a Metal choice. The reflection is half resolution, whose
stair-steps show only at the closest camera in rain; full resolution costs
about 1.2 ms against a 0.5 ms margin.

### M6-B (done): the holistic second pass

A second look at M0–M6 as a whole, asked for by the player: the whole Full
plan in Release (954 tests, no failures), a code review of the Metal files
by a separate reviewer, and every finding verified before it was fixed.

**What the review found, and what came of it:**

- **Trams jumped across stations**, which was real, and in shared simulation
  code. Each leg of `Transit.tramPath` left from whichever road tile beside
  its stop sorted first, not from where the last leg arrived, so a stop with
  road on both sides left a gap. Legs now chain from the previous arrival,
  and a stop built on the line is passable to its own tram. The new test
  fails on the old code. SpriteKit's tram gets the fix too.
- **A fire restarted every tram and ship.** Every run was keyed on one
  string that included the fires. A run now keeps its place while its own
  route (vehicle and tiles) is unchanged, which also fixes a seaport rebuilt
  elsewhere, a track re-routed to the same length, and an engine still
  leaving a demolished depot.
- **Reduce Motion waited for the map to change**, because the plan is gated
  on the map's revision and a setting is not a map change. It invalidates
  the plan itself now.
- **The reflection pass bound no texture** where its shader expects one,
  which is invalid under Metal's API validation (on for a Debug run). A 1×1
  placeholder fills every slot that might be empty, and the renders pass
  under `MTL_DEBUG_LAYER=1`.
- **Buildings popped at the screen's edges.** A chunk was culled on its own
  tiles while its buildings overhang into the next. The cull pads by the
  widest footprint.
- **A view uploaded a whole map's worth of instances every frame.** It uploads
  once per change of the map now. Static lights are no longer copied every
  frame either, and moving lights (a fire, a beacon) are listed first, so
  they are the ones kept when a screen tile is full.
- **Puddle ripples kept moving while paused.** Rain is weather, so they run
  on the motion clock; the river keeps the wall clock.

The pattern worth keeping is the one this file already names: **a cache key
has to be the thing it describes**. The run key was a string of proxies, and
every stale-run bug above is a proxy that did not move when the thing did.

### The direction: clean retrowave, not gritty cyberpunk

Decided by the player on 2026-09-23, after the M6 pass had drifted the look
toward Cyberpunk 2077: rain as a headline, film grain, crushed blacks, grey
haze. **80s cyberpunk was considered and rejected as too dark and gritty.**
The direction is clean retrowave, using the Metal renderer's real light to
get there: gloss instead of grime, sunset-coloured air instead of grey,
deep indigo rather than black, and a strict magenta, cyan, violet and sunset
palette. Rain stays, as weather that sits on the gloss rather than as the
feature.

`MetalCityRenderer.Look` holds the look as data (fog, sky colours, gloss,
grade), and `MetalLookTests.testRenderTheMoodFrames` renders the candidates
side by side. The player picked **`Look.retrowave`**: Chrome night's gloss
and crisp streets up close, with Sunset haze's pink horizon for depth. Miami
dusk was rejected (it slid back to the lavender wash). The Apex budget is
8.73 ms against 9 with it on, a margin the building pass will have to watch.

**Next, agreed:** fog and sky, then visual hierarchy by role, **a real new
density level** with taller skyscrapers (a simulation and balance change,
measured on the harness), large clean neon signage, rain reworked to sit on
the gloss, and **a repetition pass**. Up close the city looks good; zoomed
out it reads as a repeating pattern.

**Also agreed: a redraw-hitch pass.** Reported from play: the screen stops
for a moment when a building redraws on an upgrade or a downgrade. Measure
first, frame by frame around one growth, in both renderers. Suspects: in
Metal, one growth rebuilds every chunk whose three-tile signature reach
covers it, and a new variant or level generates its massing on that frame;
in SpriteKit, a cache miss rasterises a texture on that frame; and in both,
the growth lands on the same frame as the tick.

**Measured (2026-09-23): the hitch was the Debug build.** `RedrawHitchTests`
(opt-in) times a day's tick and the Metal catch-up separately. On the
player's 48×48 city a day costs 71 ms of tick in Debug against 1.4 ms in
Release; on a large city about 450 ms against 29 ms. The redraw is the
smaller part (Release: 0.6 ms on the player's city, up to 12 ms on a large
growing one). Two further fixes remain for large cities: run the tick off
the main thread, and rebuild chunks off it or spread over frames. Also, every
build was instrumented for code coverage, Release included: a test plan with
empty default options means coverage on, and the scheme's plans apply it to
plain builds too. Both plans now say `"codeCoverage": false`, and a Debug
build names itself in the window title ("Debug build (slow)").

**Also agreed: the utility glow in Metal.** Reported from play: *"I miss how
in the old SpriteKit version we could see the glow of the buildings for power
and water. Now they just light up or they don't."* SpriteKit's Water and
Power views gave each supplied building a pool of the utility's colour
spilling past its lot, so a served district glowed as one field, and the
ground carried three states (a source's radius halo, a brighter pipe field,
dark). `MetalOverlay` kept the decision but not the pools: a wash on the
building and a flat ground tint. The Metal version can make the pools real
light that falls on neighbouring walls and street.

### Retrowave step 1 (done): the sky and the sun

The sky is a pass of its own behind everything, in the same sunset gradient
the fog uses, and the land past the map now fades into it within a few tiles
rather than thirty. **The title screen's synthwave sun** rises behind the far
corner of the map, with the same slats and the same yellow, orange and
magenta, and the city stands in front of it. In this projection the far side
of the city is the top of the screen, so a player finds the sun by looking at
the back of the map. The camera stops two tiles past the map, so the sun is
sized and placed for the thin strip of sky that is actually reachable
(`MetalLookTests.testRenderTheSky` frames the cameras at that limit).

Three things measuring caught:

- **Drawn full-screen, the sun cost Apex 4.4 ms**: its slat loop ran over
  millions of pixels, almost none of which had a sun in them. Its own
  bounded quad costs nothing when it is off screen, which is nearly always.
  The full-screen sky gradient itself measured as free.
- **At 2.2× brightness the disc bleached to near-white** and lost the orange
  and magenta that make it a synthwave sun; it is 1.15× now. The halo has to
  fade to zero inside its quad, or the quad shows as a lit rectangle.
- **The retrowave look broke colour accessibility** the day it became the
  default: sunset-tinted fog pulled Power's "wanting" and "not applicable"
  together for a colourblind eye (0.19, against 0.20). Views now draw with no
  fog, keeping only the gloss. A view answers one question with colour, and
  atmosphere describes the city, which a view hides. This was caught by the
  standing test, not by looking. The lesson: **a change to the default look
  reruns the accessibility test**, however unrelated it seems.

### Retrowave step 2, round 1: a readable skyline

Up close the city looked good; zoomed out it read as a pattern. Measured on
Apex, the fault was one level of everything: every building glowing equally,
one colour per zone and tier, one height per density.

- **Hierarchy by role** (`MetalCityMesh.prominence`): housing, most of a
  city, has the quietest outline (0.6); industry 0.8; shops 1.0; services 1.2;
  and a rank's landmarks 1.35. Legibility is hierarchy, the Mini Motorways
  half of the brief.
- **A family of colours** (`varied`): each variant shifts slightly in hue,
  saturation and brightness within its zone's family, seeded by the variant
  so a lot keeps its colour. Kept small, because zone identity is what a
  colour must still say.
- **Height follows density** (`heightScale`): housing and shops rise with
  the mean density within three tiles, so downtown climbs as a cluster, with
  a small per-lot wobble. Industry keeps its height, because wide and low is
  its identity. The scale is applied when a chunk copies a building into
  place, so the cache stays one entry per variant. **The chunk signature
  reads three tiles past its edge now**, because a neighbour growing changes
  this chunk's heights. That costs 0.6 ms on an unchanged Apex (0.36 → 0.99),
  and the random player runs clean with it. Fires and badges sit on the
  scaled height.
- **Windows calm from afar**: lit panels are tagged, and fade to half as the
  camera pulls back, because a facade of lit panels at distance is speckle and
  the outline carries the form. Distance haze is halved on open ground, where
  it had turned an empty map into one mauve slab.

`MetalLookTests.testRenderTheSkyline` is the instrument: the player's
autosave beside Apex, from the widest camera and at rest. The autosave was a
brand-new city when this was built, too small to show repetition, which is
itself worth knowing: Apex is a generator's grid, and some of its repetition
is its layout. Judge this pass on a player's city as soon as one exists.

### Retrowave step 3a: a sixth level, the skyline

A real density level, not taller drawings: the player asked for "denser
taller buildings for sure". **Housing and shops reach level 6; industry stops
at 5**, because a tall factory stops reading as industry.

**The gate is rapid transit.** Level 6 needs everything level 5 does, plus a
land value of 0.9 (plain road frontage is 0.75 and a park adds 0.18, so it
wants a genuinely good address) and a subway entrance or rail station within
that mode's catchment (`CitySimulator.rapidTransitRequiredFromLevel`,
`hasRapidTransit`). **Downtown forms where the player invests in transit.**
That makes the transport module a lever on the city's shape, not only on its
traffic. Like the school, it gates reaching the level rather than keeping it:
losing a station stalls a block and does not tear the towers down. The
inspector says "Needs a subway or rail station" and names the fix; the
desirability ladder gains "Skyline". Level 6 is its own visual tier (4), so
3b can draw it as a different kind of building rather than a taller level 5.

A survey for every "5 is the top" found two that would have shipped badly:
**`sustainableDensity` looped `1...5`**, which would have decayed every
level-6 tower back to 5 the tick after it was built; and **the desirability
words ran out at index 6**, a crash in the inspector the first time a lot was
good enough for the skyline. Loops read `CitySimulator.highestDensity` now.

Seven tests failed. All seven were the thing moving rather than the yardstick
(the school now unlocks level 5, not the top), and each was restated to say
what is now true rather than relaxed. `SkylineTests` pins the gate: it waits
for transit, a subway or rail station in reach opens it, one out of reach
does not, and industry has no skyline.

### Retrowave step 3b: the skyscrapers

`SkyscraperMassing` draws level 6 (growth tier 4). It is not the level-5
tower generator with bigger numbers. It has five forms, each a silhouette
nothing below level 6 has:

- **Deco:** setbacks, each ledge lit, with a needle on top.
- **Pyramid:** a stepped pyramid with a lit capstone.
- **Slab:** a thin blade edged in neon.
- **Twin:** two shafts joined by a lit sky bridge.
- **Round:** a glass drum ringed in light.

The rare landmark roll becomes a supertall Deco tower.

**The forms are shared, and the walls are not.** Housing and shops use the
same five forms, but each is dressed with its own zone's facade helpers:
commerce gets bands and a shopfront, housing a punched grid, balconies and a
lit door. Those helpers are now `internal`, so they are called rather than
copied. `ZoneMassing.make` sends tier 4 here before the zone generators.

Level 6 has its own tier colour: periwinkle for housing, neon magenta for
shops. `tierColor` clamps industry at 3.

`SkyscraperMassingTests` checks three things:

- all five forms appear among the 32 cached variants;
- the shortest skyscraper stands taller than every ordinary level-5 tower;
- housing and shops dress the same form differently.

It also writes `skyline.png`: level 5, the five forms and the supertall, with
shops and housing in separate rows.

**Not yet measured in Metal.** The fixture cities were minted before level 6
existed, so the Apex budget does not include any skyscrapers yet. Step 3d
re-mints Apex and measures it.

### Retrowave step 3c: skipped

The agreed 3×3 merge does not fit a city of 2×2 lots: any 3×3 holding one
lot takes part of the lots beside it. A 4×4 merge of four level-6 lots would
fit, either drawn by the renderer only or as a real simulation change (a
footprint that is fixed per zone is read in 67 places). The player chose to
skip it.

### Retrowave step 3d: measured

**Apex was rebuilt** (`MINT_ONLY=Apex`) now that level 6 exists: 4,208
residents against 4,080, and 79 lots at level 6 (34 housing, 45 shops) out
of about 480.

**The skyline put Apex over its frame budget**: 10.1–10.3 ms against a 9 ms
bound at the resting camera. `MetalFrameBreakdownTests` now also draws the
same city with every level-6 lot capped at 5, in the same process. That
comparison found the skyscrapers cost about 0.5 ms; the rest is a denser
city. Two fixes:

- **At most two lights per building from its lit volumes**, merged low and
  high in massing order. A round tower's dozen rings had each been a light.
  Worth about 1 ms.
- **The light loop is skipped where albedo is zero.** Lit surfaces (windows,
  neon, lit volumes) multiplied the tile's lighting by zero, and the skyline
  is mostly lit glass. The picture is identical. Worth about 1.3 ms.

Apex is **7.8–8.0 ms** now, back under the 8 ms target.

**The balance harness cannot see level 6.** Its default cities have no subway
or rail stations, so no lot there reaches level 6, and the full-size design
playtest (all 14 tests pass) measures the city without it. A scenario with
rapid transit, compared with and without level 6, is the honest next
measurement. One thing the run showed that predates this work: planned and
mixed layouts now finish level (3,276 against 3,272 people) where this file
records planning winning clearly. That is worth checking separately.

### The utility glow, back in Metal

Reported from play: in the Water and Power views, buildings *"just light up
or they don't"*. `UtilityGlowTests` renders one half-plumbed city in both
views, SpriteKit beside Metal. That showed the cause: Metal repainted each
building in the answer's colour, walls and all, so the views were a city of
plastic blocks. SpriteKit's buildings stayed night silhouettes whose *neon*
changed colour, and each one threw a pool of it on the ground.

- **The light is recoloured, not the building.** In a network view the walls
  are dimmed and the neon edges and lit windows take the answer's hue at
  their own brightness, with a small floor so a dark facade still reads.
- **Every building throws its answer on the ground**: a soft pool, 1.9× its
  footprint, so a served district glows as one field. Overlapping pools at
  full strength summed to a milky sheet, the additive-saturation lesson
  again, so they sit at 0.2.
- **Badges are offset on the screen, not in the world.** A drop and a bolt
  were shifted 0.45 of a tile apart, which shrinks as the camera pulls back,
  so at a whole-city view the bolt covered the drop. `Billboard` carries a
  pixel offset now.

The colour-vision test on rendered pixels still passes. That test has to be
rerun after any change to how a view looks, however unrelated it seems.

**To revisit.** The player's verdict: a subtle glow, fine for now, and
*"more of a sprite problem than a glow problem"*. At a whole-city zoom a
building's own neon is thin, so there is little for the recolour to carry.
Look again once the building-variety work lands.

### The cars pass (Metal)

**A street is driven end to end now.** Each road tile used to carry its own
one-tile car that crossed, faded and started again, so a street read as a
row of short dashes blinking in step. `CityMotion.streets` makes every
straight run of road one street with two lanes, one each way. A car drives
the whole length and fades only where the street ends, spending one tile of
its loop off the map, as if turning off at the junction. It is still
aggregate, not agents: a lane's car count and speed come from the same
per-tile congestion `Traffic.carCount` reads. A street fronting buildings
keeps an ambient floor (`ambientCarsPerTile`, 0.2) so a quiet neighbourhood
is not dead. SpriteKit keeps its per-tile cars until it is retired.

**Up close a vehicle is a body; further out it stays light.** Past the
near-detail threshold a car is a small dark box edged in its kind's colour,
with a cabin, twin headlights and red tail lights (traces, bright enough to
bloom), a short red trail and a headlight wash on the road ahead. Further
out it stays a streak, because a body a few pixels across stops being a
shape. `MetalMotion.block` now builds both vehicles and the ship's hull.
Apex holds at 8.0 ms, since bodies are only drawn when zoomed in.

**The ordinary car is an 80s sports car.** The player brought the
reference: an F40 under a slatted sun. At 30–60 pixels long, what carries
that is the silhouette and the lights, so `sportsCar` is a long low wedge
with the cabin set back, a wing on two posts, twin round tail lights each
side, and real paint from a retrowave set (red, magenta, white, cyan,
orange, black) that the street's light falls on. The top panels carry only
a faint edge: a full neon rim on every panel striped the body, and what
sells it is one sweep of paint. Lorries, patrols and engines keep boxes.

**Next, agreed: a closer camera, level of detail, and a richer toolkit.**
Asked how detailed Metal can draw: the limit is not the GPU (Apex draws
~110k triangles against a budget of millions) but how close the camera goes
(a car is under 100 pixels long at the closest zoom, so anything under a few
pixels is wasted) and how shapes are authored (primitives in code, judged on
stills). In order: let the camera go nearer to street level, draw detailed
meshes only when close (the near tier, extended), then widen the procedural
vocabulary with bevels, curved and lathed profiles, and shader detail such
as panel lines. Imported 3D models (an artist's or bought) are the route
past what code can express, and would be the project's first real art
assets; that is the player's decision and is parked.

### Neon signs (Metal)

`MetalSigns` gives shops, level-6 towers and the arcade real neon signs:
rooftop billboards on posts, tall blades with stacked letters, and marquees
round a shop's ground floor. The words (MOTEL, ARCADE, VIDEO, DINER and 20
more, plus 8 vertical) are drawn once with CoreText as outlined tubes with a
soft halo into one grey atlas. Each sign is a world-space quad that samples
a word and adds its colour as light: hidden by what stands in front of it,
reflected in a wet street, hidden in views.

**Planned per lot, not per building design.** The sign is seeded by the
lot's position, so two lots drawing the same cached tower carry different
signs, which is variety the 32-variant cache cannot give. The frame (dark
backing board, posts) is ordinary chunk geometry; the letters are a
per-chunk instance buffer, compared by `MetalAgreement` like the rest.

Three things the renders caught, none of which failed a test:

- **`MTKTextureLoader` turned down the one-channel grey atlas without an
  error**, and a missing atlas skips the draw, so 67 planned signs drew
  nothing. The atlas is built from its pixels now, and a test asserts it
  loaded.
- **"The roof" was the top of the building**, which on nearly every tall one
  is a mast, so almost no billboard was placed and the signs were blades
  alone. `testSignsChangeTheFrame` diffs a frame with and without signs and
  writes `neon-signs-where.png`, which is what showed it. The roof is now the
  highest level at least most of a tile wide.
- **Held to the roof's width, billboards read as trim.** They overhang it
  now, as real ones do.

### Rain on the gloss (Metal)

The player's brief: rain stays, but as weather that sits on the gloss, not
the headline. Before this, rain barely changed a street that already shines
when dry: it doubled the reflection and drew grey vertical lines that read
as scratches on the lens.

- **Rain rings** (`rainRings` in the shader): drops land in a grid of
  quarter-tile cells, each spreading a ring that fades as it grows. A ring
  bends the reflection outward and catches light in proportion to what the
  street is already reflecting, so rings sparkle under neon and all but
  vanish in the dark. Heavier rain, more rings. They run on the motion clock
  and stop with the city; Reduce Motion turns them off with the drops.
- **Wet is darker and glassier than dry**: wet tarmac darkens more (0.45
  against 0.3) and its reflections blur less, so a wet street no longer reads
  as a brighter dry one.
- **Drops catch the city's light**: thinner, pink or cyan, not grey.

`rainfall` reaches the scene shader in `Uniforms.overlay.z`. The Apex budget
test now also measures a raining frame: 8.20 ms against 8.02 dry.

### The day runs in the background

A day on a large city cost the frame it landed on about 29 ms in Release,
nearly two dropped frames every day (`RedrawHitchTests`). The live game now
simulates each day off the main thread.

- **The day is split in two.** `GameController.simulateDay` is the heavy
  half (routing, utilities, growth, hazards): a pure, `nonisolated` function
  of a city and the generator. `apply` is the bookkeeping (treasury, unlocks,
  milestones, history, the inspector), on the main thread.
  `advanceSimulation()` runs both synchronously and is what every test and
  the manual "advance" use. `beginDayInBackground` runs the first half in a
  detached task and applies it when it lands.
- **The player's click wins.** If `mapRevision` moved while the day ran, the
  day is thrown away and the scene starts another on the next frame, so an
  edit is never overwritten. The cost is a day arriving a frame or two late.
- **The generator belongs to the day alone.** It is a struct wrapping a
  closure, so a copy shares its state, and using it on two threads would be
  a race. The one other caller was `recomputeUtilitySupply` re-rolling the
  power outage after an edit, which was a quirk in its own right: laying a
  line should not start or end a blackout. Edits now keep the day's outage.
- **Opt-in, for the live game only** (`GameScene.runsDaysInBackground`,
  set by `GameView`). A test drives the frame loop synchronously and never
  spins the run loop, so a background day would start, never land, and
  every tick after it would quietly be skipped while the clock waited for it.

`BackgroundDayTests` pins it: ten background days equal ten synchronous
ones exactly, map and treasury; an edit mid-day survives and the day is
discarded; starting a day on Apex costs the main thread 0.004 ms against
23.5 ms to simulate it there; and a scene running background days still
agrees with a freshly built one, which fails when the redraw on landing is
removed.

**Still on the main thread:** the Metal renderer's catch-up after a day
(rebuilding changed map sections, 2–12 ms on a large growing city). Moving
that off, or spreading it over frames, is the next step for big-city
smoothness.

### A closer camera, and a street tier

Metal may zoom about two and a half times nearer than SpriteKit
(`GameScene.metalMinimumZoomScale`, 0.2 against 0.5): it draws geometry, so
nothing blurs. SpriteKit keeps its limit, and switching back to it clamps
the camera. At the closest zoom a tile is about 640 Retina pixels.

Past `streetEngages` (380 px a tile, releasing at 350) the renderer adds a
third tier, swapped a few chunks a frame like the near tier:

- **Paint on the road**: dashed lane lines either side of the neon on
  straight streets, and a zebra across each arm of a junction. Paint rather
  than light, so lamps light it and a wet street mirrors it.
- **Framed windows**: a dark frame and a sill standing proud of each lit
  pane, cached per variant as `Cache.Key.street`.
- **Cars on wheels.**

Two things measuring caught:

- **Neon edges went fat up close.** An outline held at its world width was
  fourteen pixels across at the closest camera, a bar rather than a tube.
  `rimAmount` caps it at about five pixels.
- **Up close, every car in the city was built as a body every frame**,
  including hundreds off screen: 3 ms of CPU a frame on Apex at the closest
  camera. Bodies are built only for cars inside the camera's ground rectangle
  now (the one the rain already used): 0.41 ms. The budget test measures the
  closest camera too: GPU 5.35 ms, since fewer buildings are in view.

**What the closer camera exposed**: buildings designed to be seen from
further out read as sparse up close, with big blank roofs and few windows.
That is the richer-toolkit work, not a camera problem.

### P1: level of detail as a property of each part

Agreed with the buildings session, which owns the tagging (the plan is the
"Building Detail Plan" page). Every `Solid` and `Panel` carries a
`DetailTier` (`far`, `standard`, `near`, `street`): the farthest camera it
is drawn at. Untagged parts are `.far`, drawn at every zoom.

- **API**: `BuildingMassing.add(_:_:from:)`, `Panel.at(_:)`,
  `BuildingMassing.drawn(at:)`, and `DetailTier.floor(_:)` (0.19 / 0.06 /
  0.03 / 0.016 tiles, about eight pixels at the farthest camera each tier is
  drawn at).
- **The Metal renderer** holds one `detailTier` chosen from pixels per tile,
  with hysteresis at every boundary (standard 100/92, near 178/164, street
  380/350). `Cache.Key.tier` replaces the near and street flags, a chunk is
  rebuilt when its tier differs, and a building draws `drawn(at:)` its tier.
  The resting camera (128) is `.standard`, so it draws exactly what it did.
- **SpriteKit draws `drawn(at: .standard)`**, exactly what it drew before
  tiers existed. The close tiers are Metal's only.
- **The floor is measured on a part's largest extent** — a speck is small
  in every direction, a mast or a lit fin is thin but long and reads — and
  bounded only for parts with an explicit tier. Today 286 of 8,069 untagged
  solids fall under the far floor; they are reported, and the tagging passes
  will move them.

Still in the renderer rather than the massing: the near tier's mullions and
slab lines (`IsometricBuilding.nearDetail`, added in `MetalCityMesh.building`
when `key.near`), and the street tier's window frames (same function, when
`key.street`). Both become tagged parts during the facade pass. Crossing the
far/standard boundary rebuilds chunks even while nothing is tagged
`.standard`; cheap, spread over frames, and worth skipping once measured.

### Retrowave step 4: sixteen skyscrapers, and more of level 5

The player asked for "a TON of variety... all sorts of skyscrapers". Level 6
went from five forms to **sixteen**, each a different silhouette rather than
the same drawing at different numbers: ziggurat (equal tiers stepped from the
ground, a lit fin on every wall), antenna farm (steps retreating to the back
corner, a roof of masts), telescope (an octagon closing in three collared
stages), cantilever (a full-width block overhanging a slim shaft), split top
(one shaft forking into two blades), stacked (four blocks zigzagging corner to
corner), wedge (a steep slanted roof with a lit ridge), cluster (three towers of
three heights on one podium), halo (a core carrying one or two saucers),
obelisk (eight shallow steps tapering into a needle) and ribbed (lit fins that
break the roofline into a comb). Level 5 gained a corner tower and a glass slab
for shops, an L-block and an estate slab for housing, picked on their own
stream so the variants it already drew are unchanged.

- **Forms are dealt, not rolled.** Sixteen forms over the ~29 ordinary cached
  variants, rolled fairly, leaves one or two forms the game never draws.
  `SkyscraperMassing.form(for:)` deals them in turn over the canonical seeds,
  so each appears once or twice; any other seed still rolls.
- **Two of the original five were already over the geometry bound**, and had
  been hidden by the contact sheet's eight seeds: a residential drum was 275
  nodes and a twin 232, against 220. `testEveryFormStaysWithinTheGeometryBudget`
  now weighs every form over the variants the game draws. Rings went from 16
  sides to 12 and housing's window rows are capped at ten per shaft.
- **Measured on Apex**, same process, before and after: GPU at the resting
  camera 7.99 → 7.91 ms, whole city 5.22 → 5.05, lights 2,034 → 2,041. Lit
  solids are nearly free here, because a building's lit volumes merge into at
  most two lights.
- **Distinct massings over the 32 cached variants**: housing 25 / 32 / 32 / 32
  at densities 1, 3, 5, 6; shops 24 / 31 / 32 / 31; industry 28 / 31 / 29. The
  top tiers saturate `variantCount`. Raising it is the next lever for variety,
  and it needs texture memory measured first (`OversampleCostTests`).
- **What the widest camera showed**: the ringed drums and telescopes are the
  loudest marks in a downtown, since every ring is lit. If a skyline reads as
  "all drums", thin those rings first.

### Icons: prestige, one of each per city

Asked for after the player brought three reference images (a Hong Kong
street, a skyline silhouetted on a striped sun, a skyline over grid water):
"special buildings the player can only place a few of". Decided: **one of
each per city, prestige only** — no effect on demand, land value or anything
else, and no upkeep. `IconBuildings` (Simulation/) holds the rules;
`IconMassing` draws them.

| icon | rank | cost | the mark |
|---|---|---|---|
| Night Market | Village | $6k | pagoda eaves wrapped in tall vertical neon signs |
| Chrome Dome | Town | $12k | a lit dome on a drum over a slim tower |
| Twin Masts | City | $20k | two slim towers, two antennas each |
| Harbour Tower | City | $30k | a tapering shaft under a crown of lit spikes |
| Sunset Spire | Metropolis | $50k | Deco shoulders, a lit crown and a needle, 12.7 units |

- **Earned through `RewardBuildings.requiredRank`**, which now falls through
  to the icons, so `Unlocks`, the locked chip and the rank announcement needed
  no second path. The announcement names every building a rank earns now
  ("Broadcast Tower, Twin Masts, Harbour Tower unlocked"), since City opens
  three and naming the first hid the others. One test moved with it: Village
  used to carry no reward.
- **One per city is a placement rule**, `.blocked` in `placementRefusal`, so
  the cursor turns red over a second one the same way it does over water. The
  chip reads **Built** once one stands, because a chip that looked available
  and refused every click would read as a bug. Bulldozing frees the slot.
- **The spire has to lead by a clear margin**, and the first version did not:
  at 11.2 units it beat the Harbour Tower (10.3) by less than the 20% the test
  asks. `testTheSunsetSpireIsTheTallestThingInTheGame` compares it with every
  variant of every zone at every density.
- **Two things only the render caught.** Twin Masts on the lot's main
  diagonal put one tower directly behind the other and read as one; on the
  anti-diagonal they stand side by side. And the night market's signs, at
  first no taller than its eaves, read as a house with some trim.
- `IconBuildingsTests.testRenderTheIcons` writes `icons.png`, and
  `MetalLookTests.testRenderTheIconsDowntown` places all five in Apex and
  renders them with Metal (`metal-icons.png`, Full plan).

### The low end: an 80s Miami suburb, and industry that says it several ways

The contact sheet after the skyline pass showed the repetition had moved to
the bottom of the ladder, which is most of a city's map area and the first
hour of play. Seven of eight tier-1 houses were the same squat box filling
its lot; tier 2 housing was one stepped block; the plain strip took half of
tier-1 shops and the podium tower all of tier 2; every tier-1 factory was
one sawtooth shed. The player chose a Miami suburb as the answer.

| | added |
|---|---|
| housing T1 | detached house with garage and palm, pool bungalow, duplex |
| housing T2 | garden court round a pool, walk-up with lit galleries, townhouses |
| shops T1 | diner, petrol station, mini-mall behind its car park, big-sign store |
| shops T2 | motel round its pool, glass office on a lobby, billboard block |
| industry T1 | warehouse with trucks at its doors, gabled sheds, container yard, grain silos |
| industry T2–3 | tank farm, container port with gantry, refinery with a flare |

Every existing form is still in each list, so nothing was removed.

- **Low density leaves ground.** The tier-1 house now covers about a third
  of its lot on average, where the old block covered most of it, and the
  open ground carries the suburb's marks: palms, lit pools, pole signs.
  `SuburbMassing` holds those, shared by housing and shops.
- **`LotPlan`** writes a form once in lot-local axes (along, across) and
  flips it to either orientation, so a duplex or a motel can face either way
  without two copies of every coordinate.
- **`ZoneMassing.dealt`** generalises the skyscraper's rule: over the
  canonical seeds, forms are dealt in turn, so every form is drawn.
- **Shapes per tier over the 32 cached variants** (counted by volume kinds,
  so size changes do not count): housing 14 / 14, shops 12 / 12 at tiers 1
  and 2, industry 5 → 12 at tier 1. `LowEndMassingTests` asserts at least 12
  for housing and shops.
- **A palm is a drooping frond, not a cross.** The first palms had flat
  fronds and read as telegraph poles. Each frond is a `Ridge` with its ridge
  at the trunk end, so it falls away along its length.
- **Apex's frame budget is unchanged** at 7.98 ms (it has no low-density
  lots). The new forms are cheap: few volumes, and lit solids merge into at
  most two lights a building.
- `LowEndMassingTests.testRenderTheLowEnd` writes `low-end.png`, and
  `MetalLookTests.testRenderTheSuburb` renders a small town of tiers 1–2 in
  Metal (`metal-suburb.png`, Full plan).

### Industry's colour, and the first look at a grown city

- **Industry's colour family is wider in Metal, leaning to amber.**
  `MetalCityRenderer.varied` shifts each variant's hue by −0.03…+0.075 for
  industry, against ±0.045 elsewhere, and saturation further. It leans away
  from red because red is the direction of shops' magenta.
- **Every stack carries a red aviation beacon** (`NeonStyle.beaconColor`),
  and warehouses and container yards a sodium floodlight
  (`NeonStyle.sodiumColor`): working light rather than neon, the one light
  an industrial skyline has that no other zone does. Apex at the resting
  camera: 7.98 → 8.13 ms, 2,101 → 2,128 lights, inside the 9 ms bound.
- **`MetalLookTests.testRenderAGrownCity`** grows a 32×32 harness city and
  photographs it at day 45 and day 200 (`metal-grown-city.png`, Full plan) —
  the first render of a city the simulation made rather than one placed by
  hand. **It found that the first hour is scaffolding**: at day 45 nearly
  every lot is under construction, and the amber wireframes, bloomed, swamp
  the buildings they stand on. By day 200 the suburb reads as designed. The
  harness zones a whole map at once, which overstates it, but a player
  zoning a district at a time sees the same thing locally.
- **Fixed in Metal by making the deck the mark.** `MetalOverlay.scaffold`
  no longer draws the ring at the coming roofline, the posts are faint and
  rise only as far as the work has, and the climbing deck is calmer
  (1.6× amber rather than 3×). Re-rendered, day 45 reads as a city being
  built rather than a lattice. SpriteKit's scaffold is unchanged, since
  Metal is the renderer being carried forward.

### Skyline tops, sparse windows, and icons that rise with downtown

The last items from the reference images.

- **Two new tops for ordinary skyscrapers**: a crown of lit spikes, taller
  at the corners (the Hong Kong supertall's top, which the Harbour Tower
  icon has in full), and a dome on a drum with a mast (the silhouette
  image). They come through the shared `crown` helper on about a third of
  its towers, on Deco towers in place of the needle a third of the time, and
  as spikes on 40% of slabs. Each is picked on its own random stream, so
  towers that keep their old top are unchanged.
- **Sparse windows on about a third of towers**: a dark shaft with a
  scatter of lit dashes (shops) or a thin punched grid (housing) instead of
  a full lit grid. From afar the outline carries the tower, and the skyline
  gets dark towers to set the bright ones against.
- **The dome is not offered to the stacked form.** Four window-covered
  blocks already sit near the 220-node geometry bound, and a stacked
  housing tower with a dome measured 236.
- **Icons rise with downtown in Metal.** `MetalCityMesh.heightScale` used to
  scale only housing and shops, by up to about 1.5× in a dense district,
  which shrank the Sunset Spire's lead in exactly the view it exists for.
  An icon now takes the same neighbourhood scale, without the per-lot wobble
  and never below 1.
- Apex at the resting camera: 8.13 ms, 2,128 lights.

### Building detail, P0: the baseline

The plan for adding detail by camera distance is the "Building Detail Plan"
artifact (https://claude.ai/artifact/EPbNaykqUmDHj3agmjCdjk). The split: the
visuals session owns the closer camera, P1 (a detail tier per part) and P6
(shader detail); the buildings session owns P0, P2–P5 and P7. All of it is
Metal only.

P0 is `DetailBaselineTests` (an extension of `MetalLookTests`, Full plan):

- **A showcase city**: six skyscraper forms per zone, two variants of every
  lower zone and level, and the five icons, placed on lots whose position
  gives the wanted variant. Every tile is plumbed and wired, so no close-up
  is a picture of a utility badge. Towers take lots at the back and
  everything else at the front, since a tower in front hid the house the
  close-up was meant to show.
- **Four sheets** (`detail-p0-overview`, `-skyline`, `-lowrise`, `-icons`):
  the showcase at the widest and resting cameras in colour and greyscale,
  then every building at the near and closest cameras.
- **`Camera.scale` is points per output pixel**, so the game's cameras are
  1.5 (widest, 43 px a tile), 0.5 (resting, 128), 0.3 (near, 213) and 0.1
  (closest, 640). Close-ups aim at a building's *body*, ignoring needles and
  masts, and allow for Metal's downtown height stretch, or they frame sky.
- **Triangles per building** (`detail-p0-triangles.txt`): the heaviest,
  level-6 housing at the near tier, is 784; most buildings are 100–450.
  Against a GPU that draws millions, there is plenty of room to add
  geometry.
- **What the close-ups show**: facades are flat lit rectangles with no depth,
  roofs are empty planes with at most a box or two, and the suburb's ground
  is bare between the palms. That is the list P3–P5 exist to answer.

### P6: detail in the shader

Detail that would cost millions of triangles, done as shading, in the main
pass only and off under the Classic look (`Uniforms.overlay.w`). Everything
fades out below the size it can be read at.

- **Every window a room.** A lit window's seed rides in its surface tag
  (`MetalCityMesh.windowTag`, 0.201…0.299, inside the band the shader reads
  as "window"), hashed from the pane's position in the variant and mixed with
  the lot's when the building is copied into place, so two lots drawing the
  same cached design do not light the same panes the same way. From the seed:
  a warm or cool tint on the window's own colour, about one room in seven
  dark (whose glass then shows the sunset sky, more of it higher up), blinds
  drawn part way on about a third (slats up close), a darker rim just inside
  the frame that reads as a room behind the glass, and one window in a
  hundred with a failing tube.
- **Panel lines**: a storey line every 0.36 and joints every half tile, in
  world space so they run straight across faces, drawn only where a storey
  is at least a dozen pixels tall.

**The first tint washed the palette out.** Mixing each window toward a
neutral warm or cool white turned the cyan and gold windows cream. It is a
tint on the window's own colour now.

Cost on Apex: 8.02 → 8.28 ms at the resting camera (raining 8.52), inside
the 9 ms bound but with a thinner margin. `ShaderDetailTests` pins the
window band and that two lots of one design differ, and fails when the lot
mix is removed.

**Not done**: interior mapping (a fake room seen through the glass), and
glass catching the sky at glancing angles, since in this fixed isometric
camera every wall is seen at the same angle. The sky on dark panes is the
version of it that reads.

### Changed chunks rebuild off the main thread

The last big-city cost on the main thread after the day moved there: the
Metal renderer rebuilding the chunks a day changed, up to 22 ms on a large
growing city in Release (`BackgroundChunkTests`, ten days at a time).

- **A day that changes more than two chunks** rebuilds them on a concurrent
  queue and swaps each in when it lands, while the old one stays on screen
  a frame or two. A chunk that changes again meanwhile gets a newer job, and
  the older result is discarded on arrival. Worst update on the main thread:
  22.65 → 5.73 ms.
- **A click stays synchronous.** One or two chunks cost about 1.6 ms, and
  deferring them would only draw the player's own building a frame late.
- **A city just loaded builds here**, so the map never appears empty.
- **Opt-in for the live view** (`rebuildsInBackground`, set by
  `MetalMapView`), for the reason the background day is: a test pictures the
  city straight after an update.
- **The building cache is locked** (`Cache.built(for:)`), since the queue
  writes it while the main thread reads heights from it.
- A result discarded for a changed detail tier forces a re-check on the next
  frame, or a paused city would never rebuild that chunk.

`BackgroundChunkTests` pins that background rebuilds land byte for byte
where synchronous ones would, that a newer change wins, and that a click is
drawn at once. **Still on the main thread** after a changed day, about 5 ms
on the growing city: the signature pass, the motion plan, the view layer's
rebuild and its uploads.

### Building detail, P2: shapes beyond boxes

`MassingShape` (Rendering/MassingShapes.swift) is one more kind of `Volume`,
`.shape`, holding its faces already computed. Its constructors: `prism` (any
convex plan raised to a height), `bevelledBox`, `frustum`, `lathe` (a
profile spun round an axis), `dome`, and `arch`. `MassingShapesTests`
checks every face points outward and is convex, and writes
`massing-shapes.png`.

- **One case, not five.** Everything that consumes a volume already works on
  `faces`, so the only new code outside the file is one branch per `switch`.
- **Every face must be convex.** Metal fills a face as a fan from its first
  corner, so a concave face draws wrongly with no error. `prism` refuses a
  concave plan, an L-shaped building stays two boxes, and an arch is a ring
  of small convex blocks.
- **Not called `Shape`.** That is SwiftUI's, and the clash made the compiler
  crash on SwiftUI views elsewhere in the module rather than report an
  error.
- **First ports:** the skyscraper dome top and the Chrome Dome icon are real
  lathed domes where they were stacked drums, and the Harbour Tower's stages
  are bevelled boxes with the lit strip on the cut face, where it used to
  paint a chamfer on a square corner. Apex: 8.27 ms at rest, fewer triangles
  than before.

### Building detail, P3 part 1 and P4: facades and roofs up close

Both are near-tier parts only, so the resting camera draws exactly what it
did (Apex: 115,600 triangles, about 8.3 ms, 2,128 lights, unchanged).

- **`FacadeDetail` (P3 part 1)**: balustrades on housing balconies, air
  conditioners under about one housing window in seven, awnings over
  street-level shopfronts, cornices on commercial volumes, fire escapes on
  half the tier 2–3 apartment blocks. Hooked into the shared helpers
  (`balcony`, `windows`, `shopfront`, `glazingBands`).
- **`RoofDetail` (P4)**: a pass in `ZoneMassing.make` over every growable
  building's finished massing. Housing gets water tanks on legs,
  condensers, and sometimes a lit rooftop pool; shops get HVAC units,
  dishes, and on tall roofs a lit helipad; industry gets vents joined by a
  pipe run. A pass rather than an edit to some forty forms.
- **Neither draws from a building's random stream.** Each helper already
  consumes it in a fixed order, and one more draw would redesign every
  building after it. Choices come from `FacadeDetail.roll`, a hash of the
  part's own geometry.
- **Finding roofs by what covers them.** The first roof pass asked whether
  anything stood on a roof's centre and found almost none, because most
  roofs carry a parapet or a lit crown band across the whole top. A box
  now counts as a roof while less than half of it is covered, so the
  parapet's own top becomes the roof.
- **Closest camera on Apex**: 56,402 triangles before P3, then 61,506
  after the facades and 77,760 after the roofs; 5.40 → 5.75 ms; lights 282
  → 285, from the lit pools and helipads.

### Building detail, P3 part 2: the close-up marks move into the massing

The mullions and slab lines (near tier) and the window frames and sills
(street tier) were drawn by `MetalCityMesh.building` itself. They are parts
of the massing now, made by `FacadeDetail.windowDetail` for every building,
and the two renderer blocks are gone.

- **`Panel.isMark`** (agreed with the visuals session): a mark has no window
  tag, no share of the wall's light, and is emissive (×1.3) above luminance
  0.03, dark otherwise. It is a flag of its own rather than inferred from
  `standoff`, since a lit pane with a custom offset must stay a window.
  `FacadeDetailTests` pins both halves against a control window.
- **The frames lost their glow in the move, and had to get it back.** The
  renderer drew them dark with a rim of accent light, which gave each
  window its pale surround; a mark has no rim, and the first render showed
  plain black borders. They are a tint of the building's accent now, which
  a mark draws as a faint glow: 20%, or just enough to clear the mark's
  glow threshold for a dark accent like housing's violet. 28% came first,
  and the visuals session found it loud: every pane a framed picture.
- **Sills are boxes**, so they cost more than the flat quad the renderer drew:
  Apex at the closest camera went 77,760 → 100,110 triangles, 5.75 → 5.66 ms
  (noise), lights unchanged. None under a pane that starts at the ground,
  which is a door and would sink its sill below the street.
- **One colour difference**: slab lines use the zone's accent, not the Metal
  renderer's per-variant variation of it (`MetalCityMesh.varied`), which
  the massing cannot see. The difference is a few degrees of hue.

## Looking at the art without playing to it

There are two renders, and they answer different questions.

**`ZoneIconContactSheetTests` — is this building any good?** Every `ZoneIcon`
variant, one per cell, centred with air around it, so checking a building's
look no longer means growing a city to that tier:

```sh
xcodebuild -project AlphaPlusPlus.xcodeproj -scheme AlphaPlusPlus \
           -configuration Debug -derivedDataPath ./build test \
           -only-testing:AlphaPlusPlusTests/ZoneIconContactSheetTests

open ./build/ContactSheet/zone-icons.png
```

Pass `TEST_RUNNER_CONTACT_SHEET_PATH=/some/where.png` to write it elsewhere —
`xcodebuild` only forwards environment variables to the test process when they
carry that `TEST_RUNNER_` prefix, which it strips.

The same test file also asserts every catalogued icon actually draws (non-nil,
non-zero frame) and that both variant seeds really select different buildings,
so a silently-blank or accidentally-duplicated icon fails the build instead of
waiting to be noticed in play.

**`ZoneStreetscapeTests` — does this *city* look right?** A hand-authored block
of city at the game's own proportions: roads, and 2×2 lots of every zone and
tier sitting next to each other, so zone cycles along x and density rises
toward the middle the way land value does.

```sh
xcodebuild -project AlphaPlusPlus.xcodeproj -scheme AlphaPlusPlus \
           -configuration Debug -derivedDataPath ./build test \
           -only-testing:AlphaPlusPlusTests/ZoneStreetscapeTests

open ./build/ContactSheet/streetscape.png
```

Every question about art in context is a question about neighbours — whether
lots fill their footprint, whether adjacent buildings collide or leave gaps,
whether three zones side by side still read as three zones once they are small
and touching — and the contact sheet cannot answer any of them, because with
one icon per cell there is no neighbour. That is not hypothetical: it is
exactly why the `fitIconToTile` centring bug above survived so long. The file
also carries the regression test for it, asserting every building stays inside
its own footprint once scaled and placed.

It is hand-authored rather than grown by `CitySimulator` on purpose: the point
is to guarantee that every tier of every zone appears, and appears next to the
others. A grown city shows whatever it happened to grow. Density 0 is in that
rotation deliberately: a lot you have zoned and which has not grown anything
yet is the first thing a new player ever sees, it is drawn by a completely
different path (no building at all — a surveyed outline on less-tinted ground),
and every lot in the render used to be built, so that state appeared nowhere.

**`CloseZoomDetailTests` — is it still a building when you walk up to it?**
The third render, and the only one framed at a *magnification* rather than a
size: at `GameScene.minimumZoomScale` on a Retina display a lot is shown four
times larger than it is drawn, and every other sheet here photographs a
building at whatever size is convenient. Both detail tiers side by side at 4×.

```sh
xcodebuild -project AlphaPlusPlus.xcodeproj -scheme AlphaPlusPlus \
           -configuration Debug -derivedDataPath ./build test \
           -only-testing:AlphaPlusPlusTests/CloseZoomDetailTests

open ./build/ContactSheet/close-zoom-detail.png
```

**`GuideFiguresTests` — what does this look like to somebody who has never
seen it?** The figures the player-facing manual is illustrated with, and a
different question from every sheet above. Those exist to *review* the art;
this one has to make a building recognisable on a stranger's own map, so it
shows one of each rather than many and captions everything with the name the
**toolbar** uses rather than the `ZoneType` case — a guide that teaches
vocabulary the game does not use has taught the wrong thing.

```sh
xcodebuild -project AlphaPlusPlus.xcodeproj -scheme AlphaPlusPlus \
           -configuration Debug -derivedDataPath ./build test \
           -only-testing:AlphaPlusPlusTests/GuideFiguresTests

open ./build/ContactSheet/guide-cover-70.png
```

Three of its figures are worth knowing about beyond the manual:

- **`guide-transit` is the first picture in this project showing the chrome
  over the city.** Neither renderer can do it alone — `ImageRenderer` cannot
  draw the hosted `SKView` (which is why the live cockpit render comes out
  with a blank rectangle where the map is), and `SKView.texture(from:)` knows
  nothing about SwiftUI. It composes both halves into one bitmap at the offset
  `GameView` actually puts the panel at, so both are real.
- **The cover frames the most *varied* neighbourhood, not the busiest.**
  `CityPortraitTests.busiestBlock` finds downtown, which is a wall of towers
  in one hue — the opposite of what sells this game. `mostVariedNeighbourhood`
  scores windows on distinct zones, distinct civic kinds, density spread and a
  little water, rejecting anything over 40% water. Scored rather than
  hand-picked because a hand-picked coordinate silently stops meaning anything
  the moment the city is re-minted.
- **The growth ladder is three cells for five levels**, because `ZoneMassing`
  draws from `RenderPalette.growthTier`, which pairs 1 with 2 and 3 with 4. A
  five-cell figure renders two pairs of identical buildings, which reads as a
  broken render rather than as the truth it is. The test pins that pairing, so
  splitting the tiers later fails here rather than quietly under-reporting.

### The manual is downstream of the constants, and it rots

`Docs/Manual/` holds the player guide the figures above illustrate: a page
whose every number — costs, unlock thresholds, the density gates, catchments,
hazard rates — is read out of this codebase rather than estimated.

**It went stale within ninety minutes of being written.** Ranks, land
ownership and the three rank-reward buildings landed while it was being
built, and between them they falsified six separate claims in it: the unlock
table, the cost table, "the only additive positive in the game", "an airport
costs more than a hospital", the count of views, and the whole premise that
you can build anywhere on the map you founded.

So the rule is the same one this file keeps arriving at from other
directions: **a second copy of a fact drifts, and prose is a second copy.**
What makes it survivable is that the source is in the repository, so a
change to `ZoneType`, `Unlocks`, `Milestone` or `OverlayMode` is a change
somebody can grep the manual for. Anything that adds a `ZoneType` case, moves
an unlock threshold or adds an `OverlayMode` should assume the manual is now
wrong until checked.

The figures are **not** committed. They are regenerable build output and
`build/` is gitignored; the app icon is the standing exception, and it is
committed because the app needs it to compile.

The app ships an icon (`Assets.xcassets/AppIcon.appiconset`, wired up via
`ASSETCATALOG_COMPILER_APPICON_NAME`). It predates the retirement of the
grayboxing rule, and was an explicit exception to it at the time, on the
grounds that an app icon is chrome *around* the game rather than game art.

Naming note: the app's user-visible name is **Alpha++**, but the on-disk target,
folder, and Swift module are named `AlphaPlusPlus`. Swift module names can't
contain `+`, so `Alpha++` would have been mangled into `Alpha__`. The `Alpha++`
name is set via `CFBundleName`/`CFBundleDisplayName` in build settings.
