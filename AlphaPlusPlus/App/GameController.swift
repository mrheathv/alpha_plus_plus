import Foundation

/// Bridges the pure `CityMap` simulation state to SwiftUI's observation
/// system, and is the one place that turns a click into a rule ("clicking
/// applies the selected tool").
///
/// `GameView` (toolbar, population/money readout) and `GameScene` (click
/// handling, sprite refresh) both hold a reference to the *same*
/// `GameController` instance, so there is exactly one `CityMap` in memory —
/// no separate copies for "the UI's idea of the city" and "the scene's idea
/// of the city" to drift out of sync.
///
/// This type deliberately lives in `App/`, not `Simulation/`: it imports
/// `Combine` (via `ObservableObject`) to talk to SwiftUI, and the
/// Simulation-folder rule in CLAUDE.md is "Foundation only, no UI
/// frameworks." `CityMap` itself stays UI-agnostic; this is the adapter on
/// top of it.
///
/// `@MainActor` because every reader (SwiftUI's view body, GameScene's mouse
/// handling) already runs on the main thread — this just makes that
/// assumption explicit and checked, rather than an unstated convention.
@MainActor
final class GameController: ObservableObject {

    /// `private(set)`: the *only* sanctioned way to change the map is
    /// `place(at:)` below, so every mutation goes through one rule-checked
    /// path instead of scattered `map[position].zone = ...` call sites.
    @Published private(set) var map: CityMap

    /// Which `ZoneType` the next click will paint. `.empty` doubles as the
    /// bulldoze tool — clicking with it clears a tile back to unzoned land,
    /// which is exactly what setting `zone = .empty` already means.
    @Published var selectedTool: ZoneType = .residential

    /// Spendable cash. Starts at `startingTreasury`, drops when the player
    /// places something, and — since tax revenue arrived — rises on every
    /// `advanceSimulation()` step in proportion to `population` and `jobs`.
    /// Running out still just means placement stops working rather than
    /// trapping or overdrawing; there's no debt in this model.
    @Published private(set) var treasury: Int

    static let startingTreasury = 10_000

    /// The player's own lever on `taxRevenue`, as a fraction of the default
    /// rate: 1.0 is the rate every existing balance number was tuned
    /// against (so a city nobody has touched behaves exactly as it did
    /// before this existed), 0.5 halves tax income, 1.5 raises it by half.
    /// A single city-wide rate rather than separate residential/commercial/
    /// industrial rates — matching SimCity Classic's original mechanic
    /// (later games split it further; this is the first rung of that
    /// ladder, not the top of it). Real SimCity games also let a rate set
    /// too high suppress growth or drive residents out — deliberately not
    /// modeled yet, since that's a second mechanic (something like a
    /// "happiness" feedback into `CitySimulator`) layered on top of "the
    /// player can move this number," not a requirement for the lever to
    /// exist at all.
    @Published var taxRate: Double = 1.0

    /// Whether the simulation clock is running. `GameScene`'s per-frame
    /// `update(_:)` reads this to decide whether it's time to call
    /// `advanceSimulation()` again; it lives here rather than as private
    /// state on `GameScene` so the Play/Pause toggle in `GameView`'s toolbar
    /// and the scene's clock are looking at the exact same flag, not two
    /// copies that could disagree about whether the city is running.
    ///
    /// Starts `false`: a freshly opened city is paused, matching how the
    /// old manual-only "Advance" button behaved — nothing grows until you
    /// deliberately start it.
    @Published var isRunning = false

    /// How fast `isRunning` ticks — see `SimulationSpeed`. Same "shared flag,
    /// not two copies" reasoning as `isRunning`: the toolbar's speed picker
    /// and `GameScene`'s clock both read this one value.
    @Published var simulationSpeed: SimulationSpeed = .normal

    /// Which overlay (if any) `GameScene` draws instead of normal zone
    /// colors. Lives here rather than as private `GameScene` state for the
    /// same reason `isRunning` does: the toolbar's picker and the scene's
    /// rendering need to agree on one value, not risk two copies drifting.
    @Published var overlayMode: OverlayMode = .none

    /// Size the *next* `resetMap()` starts at — changing this doesn't touch
    /// the current city, only what a following Reset builds. Kept separate
    /// from acting on it immediately: picking a size is a decision you make
    /// before starting over, not a live "resize this city" operation (which
    /// would raise its own questions about what happens to existing tiles).
    @Published var selectedMapSize: MapSize = .small

    /// One snapshot of the headline stats, recorded after every
    /// `advanceSimulation()` step, so `GameView` can show a trend
    /// (`Sparkline`) instead of just the current instant. Capped at
    /// `maxHistoryLength` — a running city ticking forever shouldn't grow
    /// this array without bound.
    struct HistorySnapshot {
        let population: Int
        let jobs: Int
        let treasury: Int
    }

    @Published private(set) var history: [HistorySnapshot] = []
    private static let maxHistoryLength = 120

    /// Source of randomness for `CityHazards` and, now, `CitySimulator`'s
    /// demand-gated growth roll — the city's one shared generator for
    /// both, not two independent sources that could disagree about how
    /// "random" a given tick was. A stored property (not a fresh
    /// `SystemRandomNumberGenerator()` at each call site) purely so it's
    /// the *same* generator across every tick — `RandomNumberGenerator`
    /// is a mutating protocol (drawing a value changes its internal state),
    /// so a fresh instance per call would technically still work but reads
    /// oddly next to "this is the city's one source of randomness."
    ///
    /// Stored as `AnyRandomNumberGenerator` — see that type's own doc
    /// comment for why this needs to be manual type erasure and not the
    /// simpler-looking `any RandomNumberGenerator` existential. Letting
    /// this be some concrete-but-erased type, rather than a generic
    /// parameter on `GameController` itself, means tests can inject a
    /// deterministic stand-in (see `AlwaysZeroRNG`) through the
    /// initializer below without making every other `GameController`
    /// call site generic over a type nothing but this one property cares
    /// about.
    private var rng: AnyRandomNumberGenerator

    /// Defaults to `MapSize.small`, not an independent hardcoded number —
    /// the city you start with and the smallest one `resetMap()` can pick
    /// should always agree on what "small" means. `rng` defaults to a real
    /// system generator — only tests that need a deterministic growth roll
    /// (see `CitySimulator.advance`'s demand gate) pass their own. Generic
    /// over the caller's concrete `RNG` type (inferred from whatever's
    /// passed, including the default) rather than typed `any
    /// RandomNumberGenerator` here — this is where the type erasure into
    /// `AnyRandomNumberGenerator` actually happens, once, at construction.
    init<RNG: RandomNumberGenerator>(
        map: CityMap = CityMap(width: MapSize.small.dimension, height: MapSize.small.dimension),
        rng: RNG = SystemRandomNumberGenerator()
    ) {
        self.map = map
        self.treasury = Self.startingTreasury
        self.rng = AnyRandomNumberGenerator(rng)
    }

    /// What happened when `place(at:)` was asked to apply a tool to a tile.
    ///
    /// `place(at:)` used to just silently do nothing on failure, which is
    /// indistinguishable from "nothing needed to happen" at the call site.
    /// Returning *why* lets `GameScene` react only to the case a player
    /// should actually notice: `insufficientFunds` gets a flash; `unchanged`
    /// (already this zone, or off-map) doesn't, because nothing about the
    /// tile's own state was wrong.
    enum PlacementOutcome: Equatable {
        case placed
        case unchanged
        case insufficientFunds
    }

    /// Apply `selectedTool` to the tile at `position`, which becomes that
    /// building's *anchor* if `selectedTool.footprintSize > 1`.
    ///
    /// In order: skip if `position` is already the anchor of a matching
    /// building (a no-op shouldn't cost anything or touch `map` — this
    /// matters now that `mouseDragged` can call this many times a second
    /// while the cursor sits over the same tile); skip if the footprint
    /// doesn't fit on the map at all; skip if the treasury can't cover
    /// `selectedTool.placementCost`, charged once for the whole building,
    /// not per cell. Otherwise, clear whatever building(s) the new
    /// footprint would overlap — in full, via `clearBuilding(at:)`, not
    /// just the overlapping cells — then stamp the new one.
    ///
    /// That clear-then-place order used to be a hard block instead ("must
    /// bulldoze first"), out of concern that auto-clearing could leave a
    /// stale sprite for an old building whose anchor wasn't the clicked
    /// cell. It didn't need to be that conservative: `GameScene` already
    /// routes every placement that touches a multi-tile building through a
    /// full `rebuildEntireGrid()` rather than a targeted refresh (see its
    /// `involvesAFootprint` check), which redraws correctly regardless of
    /// how many old buildings got cleared or where their anchors were.
    /// Economically this is exactly what manually bulldozing first and then
    /// placing would do — the old building was already free to remove, so
    /// this only removes the extra click, not a price break.
    @discardableResult
    func place(at position: GridPosition) -> PlacementOutcome {
        guard map.contains(position) else { return .unchanged }
        guard !(map[position].zone == selectedTool && map[position].isBuildingAnchor) else { return .unchanged }

        let footprint = map.footprintCells(origin: position, size: selectedTool.footprintSize)
        guard !footprint.isEmpty else { return .unchanged } // doesn't fit on the map

        let cost = selectedTool.placementCost
        guard treasury >= cost else { return .insufficientFunds }

        var clearedOrigins: Set<GridPosition> = []
        for cell in footprint where map[cell].zone != .empty {
            let origin = map[cell].buildingOrigin
            if clearedOrigins.insert(origin).inserted {
                clearBuilding(at: origin)
            }
        }

        treasury -= cost
        // Changing to a genuinely different zone resets density to 0, not
        // just the zone label — re-zoning is starting over, not upgrading.
        map.placeBuilding(zone: selectedTool, origin: position)
        return .placed
    }

    /// Clear an *entire* building back to unzoned land, regardless of which
    /// cell of it `position` happens to be, and free of charge.
    ///
    /// This backs the right-click "quick bulldoze" shortcut: it's a separate
    /// method rather than `place(at:)` with a `.empty` override so that
    /// "right-click always erases, for free" reads as its own rule at the
    /// call site, not as an implicit side effect of what the left-click tool
    /// happens to be.
    func bulldoze(at position: GridPosition) {
        guard map.contains(position) else { return }
        clearBuilding(at: map[position].buildingOrigin)
    }

    /// Clears every cell of the building anchored at `origin` back to
    /// unzoned land. Looks up the anchor's own `zone.footprintSize` to find
    /// every cell it covers — for a plain 1×1 tile that's just `[origin]`
    /// itself, so callers (`bulldoze(at:)`, and `place(at:)`'s auto-replace)
    /// never have to special-case "one tile" versus "one building."
    ///
    /// Carries each cell's existing `hasPipe` forward — bulldozing a road
    /// or a building must never silently erase a pipe laid underneath it,
    /// since a pipe is an independent underground layer (see `Tile.hasPipe`).
    private func clearBuilding(at origin: GridPosition) {
        let size = map[origin].zone.footprintSize
        for cell in map.footprintCells(origin: origin, size: size) {
            map[cell] = Tile(position: cell, hasPipe: map[cell].hasPipe)
        }
    }

    // MARK: - Pipes (an underground layer, edited via the Water overlay)

    /// What it costs to lay one tile of pipe — pipes aren't a `ZoneType`
    /// (see `Tile.hasPipe`'s doc comment for why), so this doesn't live on
    /// `ZoneType.placementCost` the way every other placeable thing's cost
    /// does. Matches `.pipe`'s old placement cost from before pipes moved
    /// off the surface grid.
    static let pipePlacementCost = 40

    /// Lay a pipe at `position`, charging `pipePlacementCost` — unless
    /// there's already one there, in which case this is a free no-op
    /// (`GameScene` calls this on every tile a drag stroke crosses, the
    /// same way painting a road works, and a stroke that re-crosses
    /// already-piped ground shouldn't charge twice). Reuses
    /// `PlacementOutcome` as-is: a pipe has no footprint to not fit and no
    /// existing building to auto-replace, so no new case is needed.
    @discardableResult
    func layPipe(at position: GridPosition) -> PlacementOutcome {
        guard map.contains(position) else { return .unchanged }
        guard !map[position].hasPipe else { return .unchanged }
        guard treasury >= Self.pipePlacementCost else { return .insufficientFunds }
        treasury -= Self.pipePlacementCost
        map[position].hasPipe = true
        return .placed
    }

    /// Remove a pipe at `position`, for free — matching every other
    /// bulldoze-style removal in the game.
    func removePipe(at position: GridPosition) {
        guard map.contains(position) else { return }
        map[position].hasPipe = false
    }

    /// Wipe the city and restore the starting budget, at `selectedMapSize`
    /// rather than whatever size the previous city happened to be —
    /// changing the size picker only takes effect on the *next* reset.
    /// Grayboxing needs to iterate on a clean map often, and rebuilding the
    /// whole controller (and with it the `GameScene` that holds a reference
    /// to it) is more disruptive than resetting the state in place. Also
    /// pauses the clock and clears `history` — a fresh map should sit still
    /// until you deliberately start it again, with no trend line left over
    /// from the city it replaced.
    ///
    /// A size change means the *number of tiles* changed, not just their
    /// contents — `GameScene` needs to rebuild its sprites from scratch for
    /// this one (`rebuildEntireGrid()`), not just `refreshAll()` the ones it
    /// already has.
    func resetMap() {
        let size = selectedMapSize.dimension
        map = CityMap(width: size, height: size) // a fresh CityMap's serviceFunding already defaults to 1.0 for everything
        treasury = Self.startingTreasury
        taxRate = 1.0
        isRunning = false
        history.removeAll()
        lastHazardStrikes = []
    }

    /// Every tile a hazard struck on the most recent `advanceSimulation()`
    /// call — empty most ticks. `GameScene` reads this right after calling
    /// `advanceSimulation()` to flash the tiles that got hit, the same
    /// "controller reports what happened, scene decides how to show it"
    /// split `PlacementOutcome` uses for the insufficient-funds flash.
    @Published private(set) var lastHazardStrikes: [CityHazards.Strike] = []

    /// Advance the city by one simulation step: hazards first (see
    /// `CityHazards`), then growth (see `CitySimulator`), then tax revenue
    /// on the result, then a snapshot into `history`. Unlike `place`/`bulldoze`,
    /// this touches every tile at once rather than one — callers need to
    /// follow it with a full-scene refresh (`GameScene.refreshAll()`), the
    /// same requirement `resetMap()` already has, for the same reason.
    ///
    /// Hazards run against the map *before* this step's growth, not after —
    /// so a tile that grows from 0 to 1 this very step can't also burn down
    /// or get hit by crime in that same step. It has to survive one full
    /// tick at a density before either risk considers it. Taxing after
    /// growth (and after hazards) means the treasury reflects the city this
    /// step is actually leaving you with.
    func advanceSimulation() {
        // Routed commute load first, before hazards/growth run — both read
        // it (via `LandValue`'s road-frontage dampening), and they should
        // see this tick's freshly-computed congestion for the map as it
        // stood at the start of the tick, not last tick's stale numbers.
        // `CityHazards.apply`'s and `CitySimulator.advance`'s `next = map`
        // copies both carry it forward automatically since it's just
        // another field on the struct they copy.
        map.trafficLoad = Traffic.computeLoad(for: map)
        map.waterSupply = Water.computeSupply(for: map)
        map.cityDemand = Demand.compute(for: map)
        let (hazarded, strikes) = CityHazards.apply(to: map, using: &rng)
        lastHazardStrikes = strikes
        map = CitySimulator.advance(hazarded, using: &rng)
        treasury += netRevenue
        recordHistorySnapshot()
    }

    private func recordHistorySnapshot() {
        history.append(HistorySnapshot(population: population, jobs: jobs, treasury: treasury))
        if history.count > Self.maxHistoryLength {
            history.removeFirst(history.count - Self.maxHistoryLength)
        }
    }

    // MARK: - Derived stats

    /// Tax dollars per point of `population`/`jobs`, collected each
    /// simulation step. Jobs are taxed at twice the rate of population —
    /// commercial/industrial zones paying more than residents is the usual
    /// city-builder convention, and it's a placeholder rate either way:
    /// real balance tuning (how fast a city should become self-sustaining)
    /// needs playtesting, not a guess made before the mechanic even existed.
    private static let taxPerPopulation = 1
    private static let taxPerJob = 2

    /// Tax on the city as it stands *right now* — a preview, not a promise.
    /// `advanceSimulation()` grows the map first and taxes the result, so if
    /// anything grows this step the actual deposit will be a bit higher than
    /// this. Not `private`: `GameView` shows it so the new "growth funds
    /// itself" mechanic is something you can see coming, not just notice
    /// after the fact when the number moves.
    var taxRevenue: Int {
        Int(Double(population * Self.taxPerPopulation + jobs * Self.taxPerJob) * taxRate)
    }

    /// What every placed service/infrastructure building costs to run this
    /// step, summed across every building regardless of density — a Police
    /// Station costs the same to keep staffed whether the residential
    /// blocks around it are half-empty or fully grown. `ZoneType.upkeepCost`
    /// is 0 for zoned land and roads, so this only ever counts services.
    ///
    /// Each building's share is scaled by its own `fundingLevel(for:)` —
    /// the same lever that weakens its coverage in `LandValue.falloffValue`
    /// weakens what it costs to run, in the same direction: fund a station
    /// at 50% and it's both cheaper and less effective, not just one or
    /// the other.
    var upkeepCost: Int {
        map.tiles.filter { $0.isBuildingAnchor }.reduce(0) { partial, tile in
            let base = tile.zone.upkeepCost
            guard base > 0 else { return partial }
            return partial + Int(Double(base) * fundingLevel(for: tile.zone))
        }
    }

    /// How well-funded `zone` currently is (1.0 = full funding). Reads
    /// straight through to `map.serviceFunding`, which is where the
    /// simulation itself (`LandValue.falloffValue`) reads it too — this
    /// accessor exists so `GameView` doesn't need to know `CityMap` is
    /// where funding state actually lives.
    func fundingLevel(for zone: ZoneType) -> Double {
        map.serviceFunding.level(for: zone)
    }

    /// Sets how well-funded `zone` is, city-wide — one dial per service
    /// type (matching how the genre's own funding sliders work), not one
    /// per individual building. A no-op for a non-fundable zone, via
    /// `ServiceFunding.setLevel(_:for:)`.
    func setFundingLevel(_ level: Double, for zone: ZoneType) {
        map.serviceFunding.setLevel(level, for: zone)
    }

    /// What `advanceSimulation()` actually deposits (or withdraws) this
    /// step: tax revenue minus upkeep. Can go negative — a city with more
    /// services than the tax base supports yet should feel that as a real
    /// drain, not have it silently floored at zero.
    var netRevenue: Int {
        taxRevenue - upkeepCost
    }

    /// Reads through `map.totalDensity(of:)` and `ZoneType.populationPerDensityLevel`
    /// rather than keeping its own rate — `Demand.compute(for:)` (Simulation/)
    /// needs the exact same number, so it lives on `ZoneType` now as one
    /// shared source instead of two copies that could drift.
    var population: Int {
        map.totalDensity(of: .residential) * ZoneType.residential.populationPerDensityLevel
    }

    /// Same reasoning as `population`: reads `ZoneType.jobsPerDensityLevel`
    /// rather than a private rate of its own.
    var jobs: Int {
        map.totalDensity(of: .commercial) * ZoneType.commercial.jobsPerDensityLevel
            + map.totalDensity(of: .industrial) * ZoneType.industrial.jobsPerDensityLevel
    }
}
