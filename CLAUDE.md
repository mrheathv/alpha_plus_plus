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
others. A grown city shows whatever it happened to grow.

The app ships an icon (`Assets.xcassets/AppIcon.appiconset`, wired up via
`ASSETCATALOG_COMPILER_APPICON_NAME`). It predates the retirement of the
grayboxing rule, and was an explicit exception to it at the time, on the
grounds that an app icon is chrome *around* the game rather than game art.

Naming note: the app's user-visible name is **Alpha++**, but the on-disk target,
folder, and Swift module are named `AlphaPlusPlus`. Swift module names can't
contain `+`, so `Alpha++` would have been mangled into `Alpha__`. The `Alpha++`
name is set via `CFBundleName`/`CFBundleDisplayName` in build settings.
