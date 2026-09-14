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

- **Balance tuning.** Nearly every constant introduced in Phase 2 (land-value
  thresholds, hazard chances/coverage floors, traffic capacities, upkeep and
  tax rates) is documented in-place as a first guess awaiting real
  playtesting, not a tuned design.
- **Save/load.** Called out as deliberately deferred since the Vision section
  above was written; the data model (`CityMap`, `Tile`, and friends) has been
  kept `Codable` throughout for exactly this, but no save/load system exists
  yet.
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
built-out city:

| map   | Debug     | Release  | lots |
|-------|-----------|----------|------|
| 16×16 |   25.8 ms |   0.8 ms |   33 |
| 24×24 |  124.5 ms |   3.1 ms |   80 |
| 32×32 |  364.2 ms |   8.5 ms |  133 |
| 48×48 | 1994.5 ms |  39.5 ms |  320 |
| 64×64 | 6286.3 ms | 114.5 ms |  560 |

Two consequences worth knowing before playing or profiling:

- **A Debug build cannot play a large map.** 6.3 s/tick against
  `SimulationSpeed.fast`'s 0.35 s interval is 18x over budget, and still 6x
  over at `.normal`. Cmd-R gives you Debug. Use Release for anything above
  `.small`.
- **Cost grows superlinearly in map area** — 16x the tiles costs 143x the
  time, from `Traffic.computeLoad` routing more commuters over longer paths.
  Even in Release a 64×64 tick blocks `@MainActor` for 114 ms, roughly seven
  dropped frames.

### Known-unfixed: the treasury still runs away

`testAMatureCityDoesNotBecomeAMoneyPrinter` is a strict `XCTExpectFailure`.
Once a city plateaus it banks a flat ~74% of its tax revenue every tick
forever (measured: +$6,160/tick, treasury past $9M in 1,500 ticks). Every cost
in the model scales with *placed infrastructure*, which is static once a city
is built out, while `taxRevenue` scales with *population and jobs*, which
plateau high — so no infrastructure-scaled constant can close the gap, road
upkeep included. Fixing it needs a cost that grows with economic activity,
which is a design decision rather than a retuning. Strict mode means the test
will fail loudly if it ever starts passing, so the expectation gets removed
when that happens.

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
