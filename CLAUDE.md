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
therefore **quantised**: a lot picks one of sixteen looks for its zone and tier
rather than one of unboundedly many.

That is a real reduction in variety. It is also exactly the target this file
asks for ("ten or more distinct looks per zone per tier"), and what is lost is
the difference between sixteen looks and thousands — imperceptible on a map
showing a hundred lots at once, against a map that draws at all. The
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

The app ships an icon (`Assets.xcassets/AppIcon.appiconset`, wired up via
`ASSETCATALOG_COMPILER_APPICON_NAME`). It predates the retirement of the
grayboxing rule, and was an explicit exception to it at the time, on the
grounds that an app icon is chrome *around* the game rather than game art.

Naming note: the app's user-visible name is **Alpha++**, but the on-disk target,
folder, and Swift module are named `AlphaPlusPlus`. Swift module names can't
contain `+`, so `Alpha++` would have been mangled into `Alpha__`. The `Alpha++`
name is set via `CFBundleName`/`CFBundleDisplayName` in build settings.
