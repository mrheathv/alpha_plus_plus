# Alpha++ — Native Mac City Builder

## Vision

A city-building game in the spirit of SimCity 2000/3000 (aggregate simulation,
zone-based growth, land value, service coverage) with the depth of Cities:
Skylines, built natively for Apple Silicon to avoid Rosetta overhead.

## Tech stack

- Swift, native macOS app target, Apple Silicon only (no Intel fallback)
- Minimum deployment target: macOS 14
- SpriteKit for rendering (Phase 1–2). May consider custom Metal shaders later
  for effects SpriteKit can't handle natively, but not until mechanics are
  solid. (SpriteKit already renders via Metal under the hood, so this is an
  optimization/effects question, not a performance rescue.)
- No cross-platform requirement. Mac-only, on purpose.

## Development philosophy

- **Grayboxing first**: prove mechanics with colored squares/placeholder shapes
  before any real art. Do not build final art assets until zone/simulation
  mechanics are stable.
- **Rendering is decoupled from simulation from day one**: simulation logic
  outputs plain data (e.g. "tile at (x,y): zone=residential, density=2"), and a
  separate rendering layer maps that data to visuals. This lets us iterate on
  visual style anytime without touching simulation logic.
- Visual style polish (color palette, camera feel, clean shapes, UI) is fine to
  iterate on early since it's cheap. Final asset production (detailed sprites
  per building/zone type) waits until mechanics lock.
- **Small, testable increments.** Each unit of work should be buildable and
  verifiable before moving to the next.
- Keep data models serialization-friendly where reasonable (we'll want
  save/load eventually), but don't build save/load system yet.

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
  clean as the grayboxing philosophy above intends.

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
working on Xcode 26.6.

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

## Is it a game yet? (measured, 2026-09-14)

`DesignPlaytestTests` runs the same map under different player strategies and
prints the spread. It exists to keep "is this fun" honest: a city builder is
only a game if the player's decisions move the outcome.

Measured on a built-out 64×64 city over 1,500 ticks:

| finding | evidence |
|---|---|
| **Tax rate does nothing** | population 3,320 at tax 0.0, 1.0 *and* 2.0 — identical. Only treasury moves. |
| **All-residential is dominant** | 5,152 population with zero jobs, vs 3,320 balanced. |
| **Services are a net loss** | adding them: population 2,564 → 2,188, treasury 3.69M → 709K. Doubling their density bankrupts the city. |
| **Utilities genuinely work** | water + power together: population 2,188 → 3,320 (+52%). |
| **Hazards are cosmetic** | all ordinances on halves strikes (1.73 → 0.86/tick) and changes final population by 4. |
| **No pacing** | a fully zoned map hits 90% of final population in 12 ticks. |
| **You can't lose** | every failure found required setting tax to 0, which no player does. |

The through-line is that **almost nothing pushes back on the player**. Every
SimCity mechanic that creates a decision is a constraint — high taxes drive
residents out, pollution spoils land, crime empties neighbourhoods. Here the
only constraint is money, and money is abundant, so the levers are either
strictly dominant (max the tax), negligible (ordinances, hazards), or a
punishment for engaging (services).

In rough order of how much each would add:

1. **Make tax rate suppress growth.** `GameController.taxRate`'s doc comment
   already names this as deliberately unmodeled. It is the genre's central
   risk/reward dial and its absence is why the budget row has no decisions.
2. **Make RCI demand gate growth, not just weight a die roll.** Today
   imbalance slows growth slightly; it should stall it, so zoning is a
   balancing act rather than a paint job.
3. **Make hazard damage persist.** Abandonment the player has to fix, rather
   than density that grows straight back.
4. **Slow growth down.** Zoning is currently rewarded almost instantly, which
   leaves no window in which to react to anything.
5. **Rebalance services** so coverage is worth more than the lot and upkeep it
   costs.

One caveat on the numbers: the harness zones a whole map at once, where a
player zones incrementally. That makes "12 ticks to plateau" a statement about
how fast zoned land fills in, not about session length — but the underlying
point stands, that zoning meets no resistance over time.

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

## Looking at the art without playing to it

Every `ZoneIcon` variant renders to a single PNG contact sheet via a test, so
checking a building's look no longer means growing a city to that tier:

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

The app ships an icon (`Assets.xcassets/AppIcon.appiconset`, wired up via
`ASSETCATALOG_COMPILER_APPICON_NAME`). This is a deliberate exception to the
grayboxing rule above: the icon is chrome around the game, not game art, so
producing it early costs nothing that the "wait until mechanics lock" rule is
meant to protect. That rule still applies in full to anything *inside* the
map view.

Naming note: the app's user-visible name is **Alpha++**, but the on-disk target,
folder, and Swift module are named `AlphaPlusPlus`. Swift module names can't
contain `+`, so `Alpha++` would have been mangled into `Alpha__`. The `Alpha++`
name is set via `CFBundleName`/`CFBundleDisplayName` in build settings.
