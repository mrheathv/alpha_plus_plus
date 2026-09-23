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
    @Published private(set) var map: CityMap {
        didSet {
            mapRevision &+= 1
            updateGuide()
        }
    }

    /// Bumped on every change to `map`, however small.
    ///
    /// For renderers that keep their own copy of the city on the GPU and need
    /// a cheap "has anything moved?" — comparing two whole `CityMap`s every
    /// frame would cost more than the frame. Deliberately not `@Published`:
    /// SwiftUI already hears about the map through `map` itself.
    private(set) var mapRevision = 0

    /// Which renderer draws the map. See `MapRenderer`.
    @Published var mapRenderer: MapRenderer = .classic

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
    /// ladder, not the top of it).
    ///
    /// High rates now suppress growth, via `Demand.compute(for:)`. That used
    /// to be listed here as deliberately unmodeled, and a design playtest
    /// measured exactly what it cost: final population came out at *precisely*
    /// 3,320 whether the rate was 0.0, 1.0 or 2.0, so maximising it was
    /// strictly dominant and the slider was not a decision at all. See
    /// `Demand.taxDemandSensitivity`.
    ///
    /// A computed passthrough to `map.taxRate` rather than its own stored
    /// property, now that the simulation reads it — the same shape
    /// `cityDemand` and `isOrdinanceActive(_:)` already have, and for the same
    /// reason: one source of truth the simulation and the UI share, instead of
    /// a controller copy that could drift from what the map is actually being
    /// simulated with. Writes go through `map`, which is `@Published`, so
    /// SwiftUI still sees the change.
    var taxRate: Double {
        get { map.taxRate }
        set { map.taxRate = newValue }
    }

    // MARK: - Bonds (borrowing against future tax revenue)

    /// Outstanding bond principal — the "there's no debt in this model" gap
    /// `treasury`'s own doc comment used to flag as missing. `treasury` could
    /// already go negative from upkeep outrunning tax revenue (`netRevenue`
    /// can be negative; nothing floors it), but that was overspending with
    /// zero consequence beyond "placement stops working," not a deliberate
    /// borrowing tool. `issueBond()`/`repayBond(_:)` are the only ways this
    /// changes.
    /// Chrome off, city only.
    ///
    /// An App Store listing is mostly screenshots, and a screenshot of this
    /// game with the cockpit in it is a screenshot of a *toolbar*. The tool
    /// rail and the dashboard are between a third and a half of the window,
    /// and they are the half nobody is buying.
    ///
    /// On the controller rather than the view for the same reason
    /// `isShowingCityPanel` is: there are two routes to it, a menu item and a
    /// keyboard shortcut, and a mode needs one owner. The inspector and the
    /// route editor go with the rest of the chrome — they are panels, and a
    /// panel floating over an otherwise clean frame is worse than the full
    /// cockpit, because it reads as something left switched on by accident.
    @Published var isScreenshotMode = false

    /// Bumped when something outside the view asks for a capture.
    ///
    /// The same shape `manualAdvanceRequests` and `restyleRequests` already
    /// use, and for the same reason: the scene is private to `GameView`, and
    /// menus are built out where a view's state is out of reach.
    @Published private(set) var screenshotRequests = 0

    func requestScreenshot() {
        screenshotRequests += 1
    }

    /// Whether City Hall is open.
    ///
    /// On the controller rather than the document because there are two routes
    /// to it — the City menu and the cockpit's own button — and the sheet has
    /// one owner. The document's copy of this predated the cockpit, when the
    /// menu bar was the only way in.
    @Published var isShowingCityPanel = false {
        didSet { updateGuide() }
    }

    /// Whether the founding panel is open. Same reasoning as
    /// `isShowingCityPanel`: two routes in (the City menu and, later, a title
    /// screen), so the sheet needs one owner.
    @Published var isShowingNewCityPanel = false

    /// Whether the settings panel is open. Same reasoning again, and this one
    /// has three ways in: the title screen, the Simulation menu and the tool
    /// rail — a player looks for settings before they have a city as often as
    /// after.
    @Published var isShowingSettingsPanel = false

    /// Is there a city here already, or just the empty map every launch
    /// starts on?
    ///
    /// What "Continue" on the title screen needs to know. A brand-new
    /// `CityMap` has nothing on it and no days elapsed, so offering to
    /// continue into it would be a third button saying "New City".
    var hasACityWorthReturningTo: Bool {
        map.elapsedDays > 0 || map.tiles.contains { $0.zone != .empty }
    }

    /// A fresh coastline for the next city.
    func rerollTerrainSeed() {
        selectedTerrainSeed = UInt64.random(in: 0 ... 999_999)
    }

    @Published private(set) var bondBalance = 0

    /// How much one bond adds to `treasury` immediately.
    static let bondIssueAmount = 5_000

    /// Interest charged on the *entire* outstanding `bondBalance` every
    /// `advanceSimulation()` step, folded into `netRevenue` alongside
    /// upkeep — an ongoing cost paid automatically out of treasury, not a
    /// one-time fee.
    ///
    /// Was `0.02` (2% of the whole balance, *every tick*, forever) until a
    /// standalone playtest harness caught the actual consequence: a
    /// maxed-out `baseBondCap` balance of $15,000 charged $300/tick in
    /// interest alone, against a small-to-mid city's few-hundred-dollar
    /// tax revenue. That's not "a real tradeoff," it's unpayable — once a
    /// city borrowed anything close to its cap it could never out-earn the
    /// interest, and the same harness confirmed it in practice: a city
    /// that took on debt to fund ordinary expansion spiraled to
    /// **-$1.15 million** over 5,000 ticks with net revenue stuck at
    /// roughly -$240/tick the entire time, never recovering. Lowered by
    /// 8x to a rate the same harness confirmed lets a city that borrows
    /// during a growth spurt actually work the debt back down as its tax
    /// base catches up, instead of guaranteeing a death spiral — still a
    /// first guess, like every other rate in this file, just one now
    /// checked against real simulated numbers instead of a guess made in
    /// the abstract.
    static let bondInterestRate = 0.0025

    /// The flat portion of the borrowing cap, unrelated to city size — what
    /// a brand-new city can access from tick one. Three bonds' worth on its
    /// own: enough room to matter early, not so much that debt stops being
    /// a real constraint.
    static let baseBondCap = 15_000

    /// Added to `baseBondCap` per point of population — a real municipal
    /// bond's own capacity scales with the issuing city's tax base, and a
    /// flat cap doesn't: found via the same 300-tick playtest harness that
    /// caught `Ordinances`' flat cost going stale, a mature city's tax
    /// revenue outgrows a fixed $15,000 cap fast enough that maxing out
    /// bonds stops being a real decision. A first guess, same "needs
    /// playtesting" status every other number here has.
    static let bondCapPerCapita = 10

    /// The most bond principal the city can carry at once right now —
    /// `baseBondCap` plus a per-capita allowance for however big the city
    /// has actually grown. A computed property rather than a flat
    /// `static let`, the same reason `Ordinances.costPerOrdinance(population:)`
    /// isn't one either: this needs to answer differently as the city
    /// grows, not once at compile time.
    var maxBondBalance: Int {
        Self.baseBondCap + population * Self.bondCapPerCapita
    }

    /// Interest owed *this tick* on `bondBalance` — a preview, the same
    /// role `taxRevenue` plays for tax income: visible before it's
    /// charged, not just noticed afterward when the treasury number moves
    /// less than expected.
    var bondInterest: Int {
        Int(Double(bondBalance) * Self.bondInterestRate)
    }

    /// Borrow `bondIssueAmount` against future tax revenue, depositing it
    /// into `treasury` immediately. Refuses (a no-op, the same shape
    /// `layPipe`'s "already piped" guard has) once taking one more bond
    /// would cross `maxBondBalance`.
    @discardableResult
    func issueBond() -> Bool {
        guard bondBalance + Self.bondIssueAmount <= maxBondBalance else { return false }
        bondBalance += Self.bondIssueAmount
        treasury += Self.bondIssueAmount
        return true
    }

    /// Pay down bond principal early, straight out of `treasury` — clamped
    /// to whichever is smaller, the outstanding balance or what treasury
    /// can actually cover, so this can never take `bondBalance` negative
    /// or drain more cash than the city actually has. Paying down sooner
    /// means less `bondInterest` on every tick after.
    func repayBond(_ amount: Int) {
        let payment = min(amount, bondBalance, treasury)
        guard payment > 0 else { return }
        bondBalance -= payment
        treasury -= payment
    }

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
    @Published var isRunning = false {
        didSet { updateGuide() }
    }

    /// How fast `isRunning` ticks — see `SimulationSpeed`. Same "shared flag,
    /// not two copies" reasoning as `isRunning`: the toolbar's speed picker
    /// and `GameScene`'s clock both read this one value.
    @Published var simulationSpeed: SimulationSpeed = .normal

    /// Which overlay (if any) `GameScene` draws instead of normal zone
    /// colors. Lives here rather than as private `GameScene` state for the
    /// same reason `isRunning` does: the toolbar's picker and the scene's
    /// rendering need to agree on one value, not risk two copies drifting.
    @Published var overlayMode: OverlayMode = .none {
        didSet { updateGuide() }
    }

    /// Size the *next* `resetMap()` starts at — changing this doesn't touch
    /// the current city, only what a following Reset builds. Kept separate
    /// from acting on it immediately: picking a size is a decision you make
    /// before starting over, not a live "resize this city" operation (which
    /// would raise its own questions about what happens to existing tiles).
    @Published var selectedMapSize: MapSize = .small

    /// What kind of land the *next* new city is founded on.
    ///
    /// Defaults to `.flat`, which is exactly what the game did before terrain
    /// existed — so nothing changes for anyone until they choose otherwise,
    /// and `resetMap` keeps meaning what it meant. Takes effect on the next
    /// reset, like `selectedMapSize`: re-cutting a river under a city that is
    /// already standing on it is not a thing this wants to answer.
    @Published var selectedTerrain: Terrain = .flat

    /// The seed the next map's terrain is cut from.
    ///
    /// Rolled fresh for each new city so two Coastal maps are two different
    /// coastlines, but held in a property rather than generated inside
    /// `resetMap` so it can be *shown* — a player who likes a map should be
    /// able to write the number down and get it back.
    @Published var selectedTerrainSeed: UInt64 = UInt64.random(in: 0 ... 999_999)

    /// Which look the map is drawn in.
    ///
    /// Lives on the controller rather than only as `VisualStyle.current` so
    /// SwiftUI can bind a picker to it and the scene can be told to redraw;
    /// the static is what the renderer's free functions actually read. Two
    /// copies of one fact is the thing this project keeps paying for, so the
    /// setter is the only writer of both and nothing else assigns the static.
    @Published var visualStyle: VisualStyle = VisualStyle.current {
        didSet {
            guard visualStyle != oldValue else { return }
            VisualStyle.current = visualStyle
            restyleRequests += 1
        }
    }

    /// **Ambient motion off, information-carrying motion left alone.**
    ///
    /// The line is what a mark is *for*, not how much it moves. Rain, factory
    /// smoke and the slow swell in a building's contact light are atmosphere:
    /// they say nothing a player acts on, and they are the ones that make a
    /// screen tiring to sit in front of. Traffic, the vehicles on a line, an
    /// engine running to a fire and the flame itself all stay, because every
    /// one of them is the simulation reporting something — and a setting that
    /// quietly stopped telling a player where the fire is would be a worse
    /// accessibility failure than the one it set out to fix.
    ///
    /// Mirrored into a static for the same reason `visualStyle` is: SwiftUI
    /// binds to the property, the renderer's free functions read the static,
    /// and this setter is the only writer of both.
    @Published var reduceMotion: Bool = VisualStyle.reduceMotion {
        didSet {
            guard reduceMotion != oldValue else { return }
            VisualStyle.reduceMotion = reduceMotion
            // Heavier than it needs to be — this purges every cached texture
            // to change three node-level animations — and taken deliberately.
            // It is a rare action, and this project has twice shipped a
            // control that compiled and changed nothing on screen. Guaranteed
            // correct beats proportionate here.
            restyleRequests += 1
        }
    }

    /// Bumped when the map needs redrawing in a new style — the same shape
    /// `cityGeneration` uses to get "rebuild your sprites" from here to the
    /// scene, and deliberately *not* `cityGeneration` itself, which also
    /// means "the tile count changed" and recentres the camera.
    @Published private(set) var restyleRequests = 0

    /// Headline stats recorded after every `advanceSimulation()` step, so
    /// `GameView` can show a trend (`Sparkline`) instead of just the current
    /// instant. Capped at `maxHistoryLength` — a running city ticking forever
    /// shouldn't grow this array without bound.
    ///
    /// The element type used to be a `HistorySnapshot` nested right here;
    /// it's now `CityStatSnapshot` in `Simulation/`, because `CitySave` has
    /// to name it to persist a city's history and `Simulation/` can't reach
    /// up into `App/`. See that type's own doc comment.
    @Published private(set) var history: [CityStatSnapshot] = []
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
    /// `peakPopulation` seeds the unlock ladder's high-water mark. It defaults
    /// to 0 — a genuinely new city, which has earned only the starting tools.
    /// Callers that want a city which has already grown up (the playtest
    /// harness, and tests about placement rules rather than about unlocks) pass
    /// `Unlocks.everythingUnlocked`.
    init<RNG: RandomNumberGenerator>(
        map: CityMap = CityMap(width: MapSize.small.dimension, height: MapSize.small.dimension),
        rng: RNG = SystemRandomNumberGenerator(),
        peakPopulation: Int = 0
    ) {
        self.map = map
        self.treasury = Self.startingTreasury
        self.rng = AnyRandomNumberGenerator(rng)
        self.peakPopulation = peakPopulation
    }

    /// What happened when `place(at:)` was asked to apply a tool to a tile.
    ///
    /// `place(at:)` used to just silently do nothing on failure, which is
    /// indistinguishable from "nothing needed to happen" at the call site.
    /// Returning *why* lets `GameScene` react only to the cases a player
    /// should actually notice: `insufficientFunds` and `blocked` both get a
    /// flash; `unchanged` (already this zone, or off-map) doesn't, because
    /// nothing about the tile's own state was wrong.
    enum PlacementOutcome: Equatable {
        case placed
        case unchanged
        case insufficientFunds
        case blocked
        /// The tool hasn't been earned yet — see `Unlocks`.
        case locked
    }

    /// Apply `selectedTool` to the tile at `position`, which becomes that
    /// building's *anchor* if `selectedTool.footprintSize > 1`.
    ///
    /// In order: skip if `position` is already the anchor of a matching
    /// building (a no-op shouldn't cost anything or touch `map` — this
    /// matters now that `mouseDragged` can call this many times a second
    /// while the cursor sits over the same tile); skip if the footprint
    /// doesn't fit on the map at all; refuse if any cell the new footprint
    /// would cover already has something on it (a building, a road, another
    /// footprint's non-anchor corner — anything but bare `.empty` land);
    /// skip if the treasury can't cover `selectedTool.placementCost`,
    /// charged once for the whole building, not per cell. Otherwise stamp
    /// the new building.
    ///
    /// That "refuse if occupied" rule used to be a "clear it and place
    /// anyway" auto-replace instead — convenient in isolation, but risky
    /// once drag-painting is in the mix: a stroke that sweeps across an
    /// established building could silently demolish it with no confirmation,
    /// which reads very differently once you're the one holding the mouse
    /// instead of watching it happen deliberately, one click at a time.
    /// Flagged from exactly that: watching an actual play session. Removing
    /// something you don't want is still one right-click-bulldoze away —
    /// this only removes the *silent* shortcut, not the ability.
    @discardableResult
    /// **Why a placement would be refused, or `nil` if it would go ahead.**
    ///
    /// Extracted so that `place(at:)` and the placement cursor cannot
    /// disagree. They already had: the cursor asked only "would this replace
    /// something", which is a fair summary of the rules as they stood when it
    /// was written and has been wrong since water landed — a house hovered
    /// over a river drew in the clear colour and then refused the click, and
    /// a seaport on dry land did the same. The whole of the dock's mechanic
    /// is *where you may put it*, so a cursor that will not say is worse than
    /// no cursor.
    ///
    /// Same contract as `CityHazards.isExposed` and `CitySimulator.needsWater`
    /// — the rule is owned in one place and *called* by the view, rather than
    /// restated there and left to drift.
    func placementRefusal(of tool: ZoneType, at position: GridPosition) -> PlacementOutcome? {
        guard map.contains(position) else { return .unchanged }
        // Checked before anything else that could succeed: a locked tool must
        // not charge the treasury or touch the map, however legal the
        // placement would otherwise be.
        guard isUnlocked(tool) else { return .locked }
        guard !(map[position].zone == tool && map[position].isBuildingAnchor) else { return .unchanged }

        let footprint = map.footprintCells(origin: position, size: tool.footprintSize)
        guard !footprint.isEmpty else { return .unchanged } // doesn't fit on the map
        // **Nothing is built on land the city does not own**, and a building
        // straddling the boundary counts as on it. Refused as `.blocked` so
        // the cursor and the flash say so the same way they say everything
        // else — see `LandOwnership`.
        guard footprint.allSatisfy({ map.isOwned($0) }) else { return .blocked }

        guard footprint.allSatisfy({ map[$0].zone == .empty }) else { return .blocked }
        // **Nothing is built on water except a bridge.** A road may cross it,
        // at a surcharge per span; everything else is refused, and refused as
        // `.blocked` so the player gets the same mark as any other rejected
        // placement rather than a click that silently does nothing. See
        // `ZoneType.bridgeSurcharge` for why only roads.
        guard footprint.allSatisfy({ !map[$0].isWater }) || tool.canBridge else { return .blocked }

        // **A dock has to be on the shore.** The first placement rule in this
        // game that depends on the terrain, and the thing that turns the
        // choice at founding from a look into a strategy: a Flat map cannot
        // have a seaport at all.
        if tool == .seaport, !RegionalTrade.canBerth(footprint, in: map) { return .blocked }

        guard treasury >= placementCost(of: tool, at: position) else { return .insufficientFunds }
        return nil
    }

    /// What a placement would charge, bridge surcharge included.
    ///
    /// Charged per wet cell, so a wide river costs more to cross than a
    /// narrow one — which is the whole decision a bridge represents.
    func placementCost(of tool: ZoneType, at position: GridPosition) -> Int {
        let spans = map.footprintCells(origin: position, size: tool.footprintSize)
            .filter { map[$0].isWater }.count
        return tool.placementCost + spans * (tool.bridgeSurcharge ?? 0)
    }

    func place(at position: GridPosition) -> PlacementOutcome {
        if let refusal = placementRefusal(of: selectedTool, at: position) { return refusal }

        treasury -= placementCost(of: selectedTool, at: position)
        map.placeBuilding(zone: selectedTool, origin: position)
        // A tower or a plant changes what is supplied the instant it lands,
        // not on the next tick — and nothing else does. `place` refuses over
        // occupied land (see `placementRefusal`), so no building is cleared
        // here and the demand side cannot move either.
        if selectedTool.feedsAUtilityNetwork { recomputeUtilitySupply() }
        // **Rails are not supply.** They follow the *streets*, so any
        // placement can move them — and gating them behind the utility
        // condition above is exactly the bug `TramTests` caught: bulldozing a
        // street left its rails floating. Cheap, unlike the flood fills: one
        // search per segment of each tram line, and most cities have none.
        recomputeTramTracks()
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
        let origin = map[position].buildingOrigin
        // Clearing *can* move supply two ways: the building might be a source,
        // and it might have been drawing on the network — losing demand can
        // bring an overloaded grid back under its ceiling.
        let cleared = map[origin]
        let matters = cleared.zone.feedsAUtilityNetwork || cleared.density > 0
            || cleared.hasPipe || cleared.hasPowerLine
        clearBuilding(at: origin)
        if matters { recomputeUtilitySupply() }
        recomputeTramTracks()
    }

    /// Clears every cell of the building anchored at `origin` back to
    /// unzoned land. Looks up the anchor's own `zone.footprintSize` to find
    /// every cell it covers — for a plain 1×1 tile that's just `[origin]`
    /// itself, so `bulldoze(at:)` never has to special-case "one tile"
    /// versus "one building." `place(at:)` used to call this too, to
    /// auto-replace whatever a new footprint overlapped; it now refuses to
    /// place over anything non-`.empty` instead, so bulldozing is the only
    /// caller left.
    ///
    /// Carries each cell's existing `hasPipe`/`hasPowerLine` forward —
    /// bulldozing a road or a building must never silently erase either
    /// one laid underneath it, since both are independent underground/
    /// overhead layers (see `Tile.hasPipe`'s own doc comment).
    private func clearBuilding(at origin: GridPosition) {
        let size = map[origin].zone.footprintSize
        // A line cannot call at a station that is not there any more. The
        // *route* survives the loss of a stop — see `TransitNetwork`'s own doc
        // comment — it just stops carrying anyone if that leaves it with
        // fewer than two places to go.
        if TransitRoute.Mode.allCases.contains(where: { $0.stationZone == map[origin].zone }) {
            map.transit.removeStop(at: origin)
        }
        for cell in map.footprintCells(origin: origin, size: size) {
            let buried = map[cell].hasPipe || map[cell].hasPowerLine
            map[cell] = Tile(
                position: cell,
                hasPipe: map[cell].hasPipe,
                hasPowerLine: map[cell].hasPowerLine,
                // Wear carries forward only while something buried is still
                // there. `Infrastructure` keeps one wear value per tile for
                // the whole corridor — surface and trench together — so
                // rebuilding the road on top cannot make the main under it new
                // again, which would be a full repair for the price of a
                // bulldoze. Clear the tile completely and there is nothing
                // left to be worn.
                wear: buried ? map[cell].wear : nil,
                // Demolishing a bridge gives back the river, not dry land.
                isWater: map[cell].isWater
            )
        }
    }

    // MARK: - Transit routes (drawn, not placed — see `TransitRoute`)

    /// The line being drawn right now, if any — see `TransitRouteDraft`.
    ///
    /// Held here rather than in the view for the reason `inspectedReport` is:
    /// the scene and the panel both need it (one to take clicks into it, the
    /// other to show it and to finish it), and two copies of an edit in
    /// progress is the sort of thing that goes out of step the first time
    /// either side changes.
    @Published private(set) var routeDraft: TransitRouteDraft?

    /// Starts a new line, and raises the view that makes the stations
    /// clickable — the same "selecting the tool puts you in the mode" contract
    /// pipes and power lines already have.
    func beginTransitRoute(mode: TransitRoute.Mode) {
        overlayMode = OverlayMode.view(for: mode)
        routeDraft = TransitRouteDraft(mode: mode)
    }

    /// Reopens an existing line for editing, seeded with the stops it already
    /// has. Deliberately the same draft type as a new one: adding a stop to a
    /// line you already have should be the same gesture as drawing it.
    func editTransitRoute(id: TransitRoute.ID) {
        guard let route = map.transit.route(id: id) else { return }
        overlayMode = OverlayMode.view(for: route.mode)
        routeDraft = TransitRouteDraft(mode: route.mode, editing: id, stops: route.stops)
    }

    /// A click on the map while a draft is open.
    ///
    /// Returns what happened so the scene can answer the click — a station
    /// added or taken off, or the flash that says this was not something a
    /// line can call at.
    @discardableResult
    func addStopToRoute(at position: GridPosition) -> TransitRouteDraft.StopOutcome {
        guard var draft = routeDraft, map.contains(position) else { return .notAStation }
        let station = map[position].buildingOrigin
        guard map[station].zone == draft.mode.stationZone else { return .notAStation }
        let outcome = draft.toggle(station)
        routeDraft = draft
        return outcome
    }

    func undoLastStop() {
        routeDraft?.undoLastStop()
    }

    /// Writes the draft back to the city. A no-op below two stops, which is
    /// the one thing a line cannot be.
    @discardableResult
    func commitTransitRoute() -> TransitRoute.ID? {
        defer { recomputeTramTracks() }
        guard let draft = routeDraft, draft.isCommittable else { return nil }
        let id: TransitRoute.ID
        if let editing = draft.editing {
            map.transit.setStops(draft.stops, forRoute: editing)
            id = editing
        } else {
            id = map.transit.add(mode: draft.mode, stops: draft.stops)
        }
        routeDraft = nil
        return id
    }

    func cancelTransitRoute() {
        routeDraft = nil
    }

    /// How many of each line's stops are actually in service.
    ///
    /// Not `stops.count`: a stop whose station has been bulldozed is still on
    /// the route and calls at nothing (see `TransitNetwork`), and a line short
    /// of two working stops carries nobody. The panel needs the difference to
    /// say *why* a line it is listing shows no riders — "a station on this
    /// line is gone" and "needs another stop" are different jobs for the
    /// player.
    func workingStopCounts() -> [TransitRoute.ID: Int] {
        map.transit.routes.reduce(into: [:]) { counts, route in
            counts[route.id] = Transit.workingStops(of: route, in: map).count
        }
    }

    /// What each line can carry today — see `Transit.dailyCapacity`, which is
    /// where the bus's congestion penalty lives. The panel reads this against
    /// ridership, because "how close am I to the ceiling" is the question a
    /// meter answers and a bare rider count does not.
    func routeCapacities() -> [TransitRoute.ID: Int] {
        map.transit.routes.reduce(into: [:]) { capacities, route in
            capacities[route.id] = Transit.dailyCapacity(of: route, in: map)
        }
    }

    /// Start a new line. Free: the player already paid for the stations, and
    /// what a route adds is the claim that they are on the same line.
    ///
    /// Returns the new route's id so a caller — the editor, in phase 2 — can
    /// keep working on the thing it just made.
    @discardableResult
    func addTransitRoute(mode: TransitRoute.Mode, stops: [GridPosition] = []) -> TransitRoute.ID {
        map.transit.add(mode: mode, stops: stops)
    }

    func removeTransitRoute(id: TransitRoute.ID) {
        map.transit.remove(id: id)
        recomputeTramTracks()
    }

    /// Replaces a line's stops wholesale rather than offering insert/remove.
    /// A route is an *ordered* list, so nearly every edit — dragging a stop
    /// to a new place in the running order, dropping one from the middle — is
    /// a new list anyway, and one setter is one thing for the editor to
    /// undo.
    func setTransitStops(_ stops: [GridPosition], forRoute id: TransitRoute.ID) {
        map.transit.setStops(stops, forRoute: id)
    }

    // MARK: - Pipes (an underground layer, edited via the Water overlay)

    /// What it costs to lay one tile of pipe — pipes aren't a `ZoneType`
    /// (see `Tile.hasPipe`'s doc comment for why), so this doesn't live on
    /// `ZoneType.placementCost` the way every other placeable thing's cost
    /// does. Matches `.pipe`'s old placement cost from before pipes moved
    /// off the surface grid.
    /// `nonisolated` so the toolbar registry can name the cost without being
    /// main-actor bound. It is an immutable `Int`; the isolation bought
    /// nothing and cost `ToolCategory` its independence from the controller.
    nonisolated static let pipePlacementCost = 40

    /// Lay a pipe at `position`, charging `pipePlacementCost` — unless
    /// there's already one there, in which case this is a free no-op
    /// (`GameScene` calls this on every tile a drag stroke crosses, the
    /// same way painting a road works, and a stroke that re-crosses
    /// already-piped ground shouldn't charge twice). Reuses
    /// `PlacementOutcome` as-is: a pipe has no footprint to not fit and no
    /// existing building to auto-replace, so no new case is needed.
    @discardableResult
    func layPipe(at position: GridPosition,
                recomputingSupply: Bool = true) -> PlacementOutcome {
        guard map.contains(position) else { return .unchanged }
        // A main crosses water *under a bridge*, never through open river.
        // The same simplification `Infrastructure` already makes in the other
        // direction — one tile carries the road and whatever is buried in it,
        // because a public-works budget resurfaces the street and replaces
        // the main beneath it in one job.
        guard !map[position].isWater || map[position].zone.canBridge else { return .blocked }
        guard map.isOwned(position) else { return .blocked }
        guard !map[position].hasPipe else { return .unchanged }
        guard treasury >= Self.pipePlacementCost else { return .insufficientFunds }
        treasury -= Self.pipePlacementCost
        map[position].hasPipe = true
        // **Not on every tile of a drag.** Laying a conduit genuinely does
        // change what the network reaches, so this is not the unconditional
        // recompute `place` had — but a stroke lays several tiles per mouse
        // event, and two whole-map flood fills per tile is 8.6 ms each. The
        // caller says when the stroke is finished.
        if recomputingSupply { recomputeUtilitySupply() }
        return .placed
    }

    /// Remove a pipe at `position`, for free — matching every other
    /// bulldoze-style removal in the game.
    func removePipe(at position: GridPosition) {
        guard map.contains(position) else { return }
        map[position].hasPipe = false
        recomputeUtilitySupply()
    }

    // MARK: - Power lines (an overhead layer, edited via the Power overlay)

    /// Same shape as `pipePlacementCost` — power lines aren't a `ZoneType`
    /// either (see `Tile.hasPowerLine`'s doc comment), so this doesn't
    /// live on `ZoneType.placementCost`. Priced the same as a pipe: both
    /// are a single tile's worth of buried/strung utility line, not a
    /// building.
    nonisolated static let powerLinePlacementCost = 40

    /// Lay a power line at `position` — the exact same contract
    /// `layPipe(at:)` has, one paragraph up, for the parallel layer.
    @discardableResult
    func layPowerLine(at position: GridPosition,
                recomputingSupply: Bool = true) -> PlacementOutcome {
        guard map.contains(position) else { return .unchanged }
        guard !map[position].isWater || map[position].zone.canBridge else { return .blocked }
        guard map.isOwned(position) else { return .blocked }
        guard !map[position].hasPowerLine else { return .unchanged }
        guard treasury >= Self.powerLinePlacementCost else { return .insufficientFunds }
        treasury -= Self.powerLinePlacementCost
        map[position].hasPowerLine = true
        // **Not on every tile of a drag.** Laying a conduit genuinely does
        // change what the network reaches, so this is not the unconditional
        // recompute `place` had — but a stroke lays several tiles per mouse
        // event, and two whole-map flood fills per tile is 8.6 ms each. The
        // caller says when the stroke is finished.
        if recomputingSupply { recomputeUtilitySupply() }
        return .placed
    }

    /// Remove a power line at `position`, for free — matching `removePipe(at:)`.
    func removePowerLine(at position: GridPosition) {
        guard map.contains(position) else { return }
        map[position].hasPowerLine = false
        recomputeUtilitySupply()
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
    ///
    /// `guided` starts `FirstCityGuide` on the new city. Off by default so
    /// every existing caller — tests, the menu's reset — founds exactly the
    /// city it always did; the founding panel is the one place that asks.
    ///
    /// `buyingLand` founds the city on the middle of the map with the rest for
    /// sale — see `LandOwnership`. Off by default for the same reason `guided`
    /// is: every test and every playtest city expects to own the whole map.
    func resetMap(guided: Bool = false, buyingLand: Bool = false) {
        // Dropped *first*: assigning `map` below runs the guide's update, and
        // the old city's guide must not see the new city at all.
        guide = nil
        let size = selectedMapSize.dimension
        map = CityMap(width: size, height: size) // a fresh CityMap's serviceFunding already defaults to 1.0 for everything
        TerrainGenerator.apply(selectedTerrain, to: &map, seed: selectedTerrainSeed)
        if buyingLand { map.land = .starting(width: size, height: size) }
        treasury = Self.startingTreasury
        taxRate = 1.0
        bondBalance = 0
        isRunning = false
        // A reset changes the tile count exactly the way a load does, so it
        // needs the same rebuild-and-recentre — see `cityGeneration`. Bumping
        // it here means every caller gets that for free rather than each one
        // remembering to ask the scene itself.
        cityGeneration += 1
        peakPopulation = 0
        newlyUnlockedZones = []
        milestone = nil
        newlyEarnedMilestones = []
        scorecard = CityScorecard()
        history.removeAll()
        lastHazardStrikes = []
        isPowerOutageActive = false
        if guided { startGuide() }
    }

    /// Picks a zoning tool, dropping out of a network overlay if one is up.
    ///
    /// Clicking the map lays pipe or power line whenever the Water or Power
    /// overlay is showing, whatever `selectedTool` happens to be. So choosing
    /// an ordinary zone while one of those is up would leave the player in an
    /// invisible mode where their clicks did something other than what the
    /// highlighted tool says. Leaving the overlay keeps "what does a click do"
    /// answerable by looking at the toolbar.
    ///
    /// Lives here rather than in `GameView` because it is a rule about what
    /// the game does, not about how the toolbar draws — and a rule in a view
    /// is a rule no test can reach.
    func selectTool(_ zone: ZoneType) {
        selectedTool = zone
        // Picking a zone leaves any overlay that takes clicks of its own,
        // otherwise choosing Residential with the Water overlay up drops you
        // into an invisible mode where clicks lay pipe. The transit views are
        // the same kind of thing now, and a half-drawn line has no meaning
        // once you have stopped drawing it.
        if OverlayMode.clickEditing.contains(overlayMode) {
            overlayMode = .none
        }
        routeDraft = nil
    }

    /// Bumped when something outside the view asks for a single simulation
    /// step — the Simulation menu's Advance command.
    ///
    /// The menu cannot call `GameScene.runSimulationTick()` directly (the
    /// scene is private to `GameView`, and menus are built above it), and
    /// calling `advanceSimulation()` straight from the menu would skip the
    /// hazard flashes the scene adds. So the menu bumps this and the view
    /// turns it into a real tick, the same shape `cityGeneration` already uses
    /// to get "the whole map changed" from the controller to the scene.
    @Published private(set) var manualAdvanceRequests = 0

    func requestManualAdvance() {
        manualAdvanceRequests += 1
    }

    // MARK: - Land

    enum LandPurchase: Equatable {
        case bought(LandOwnership.Parcel)
        /// The map has no land budget — every tile is already the city's.
        case nothingForSale
        case refused(LandOwnership.Refusal)
        case insufficientFunds
    }

    /// Why the parcel under `position` cannot be bought right now, or `nil`
    /// if it can.
    ///
    /// The whole rule, owned here and *called* by the Land view's cursor and
    /// its panel — the contract `placementRefusal` keeps for buildings, and
    /// for the same reason: a cursor restating the rule is a cursor that
    /// drifts from it.
    func landRefusal(at position: GridPosition) -> LandPurchase? {
        guard let land = map.land else { return .nothingForSale }
        if let refusal = land.refusal(for: land.parcel(containing: position), rank: milestone) {
            return .refused(refusal)
        }
        guard treasury >= land.nextPrice else { return .insufficientFunds }
        return nil
    }

    /// Buys the parcel under `position`.
    @discardableResult
    func buyLand(at position: GridPosition) -> LandPurchase {
        if let refusal = landRefusal(at: position) { return refusal }
        guard var land = map.land else { return .nothingForSale }
        let parcel = land.parcel(containing: position)
        treasury -= land.nextPrice
        land.buy(parcel)
        map.land = land
        return .bought(parcel)
    }

    // MARK: - First-city guide

    /// The guide, while one is running. See `FirstCityGuide`.
    @Published private(set) var guide: FirstCityGuide?

    func startGuide() {
        guide = FirstCityGuide()
        updateGuide()
    }

    /// Skip it, or put it away once it is finished — the same thing to the
    /// player, and deliberately the same one call.
    func dismissGuide() {
        guide = nil
    }

    /// Does what the current step's button says.
    ///
    /// Here rather than in the view for the reason `selectTool` is: it is a
    /// rule about what the game does, and a rule in a view is one no test can
    /// reach. `FirstCityGuideTests` performs every shortcut and checks it
    /// actually finishes — or equips the tool that finishes — its own step.
    func perform(_ shortcut: FirstCityGuide.Shortcut) {
        switch shortcut {
        case .selectTool(let zone): selectTool(zone)
        case .play: isRunning = true
        case .showView(let mode): overlayMode = mode
        case .openCityHall: isShowingCityPanel = true
        }
    }

    /// Re-reads the city for the guide. Called from the `didSet` of every
    /// property a step looks at.
    ///
    /// Cheap enough to run on every map write — one pass over the tiles — but
    /// only while a guide is actually running, and it only publishes when a
    /// step really completed, so a tick does not announce eight changes to a
    /// panel that did not move.
    private func updateGuide() {
        guard var next = guide, !next.isFinished else { return }
        let state = FirstCityGuide.State(
            map: map, population: population, isRunning: isRunning,
            overlay: overlayMode, isShowingCityPanel: isShowingCityPanel
        )
        if next.update(with: state) { guide = next }
    }

    // MARK: - Unlocks

    /// The largest population this city has *ever* reached.
    ///
    /// A high-water mark rather than the current figure, because that is what
    /// `Unlocks` reads: a city knocked back by fire, a bad tax rate or a
    /// bulldozer keeps the tools it earned. Losing the fire station because
    /// your city burned down would be exactly backwards.
    @Published private(set) var peakPopulation: Int = 0

    /// Zones earned on the most recent `advanceSimulation()` — empty on almost
    /// every tick. `GameView` reads it to announce them.
    @Published private(set) var newlyUnlockedZones: [ZoneType] = []

    func isUnlocked(_ zone: ZoneType) -> Bool {
        Unlocks.isUnlocked(zone, peakPopulation: peakPopulation, rank: milestone)
    }

    /// How many residents `zone` still needs, or 0 if it is already earned.
    func residentsNeeded(for zone: ZoneType) -> Int {
        max(0, Unlocks.requiredPopulation(for: zone) - peakPopulation)
    }

    // MARK: - Milestones

    /// The highest rank this city has earned, or `nil` before the first.
    /// See `Milestone`.
    @Published private(set) var milestone: Milestone?

    /// Ranks earned on the most recent tick — empty on almost every one.
    /// `GameView` reads it to announce them, the way it announces unlocks.
    @Published private(set) var newlyEarnedMilestones: [Milestone] = []

    /// How the city scores on what the ladder asks for, as of the last tick.
    ///
    /// Kept rather than measured on demand, for the reason
    /// `inspectedReport` is: measuring builds a whole-map distance field, and
    /// a SwiftUI body calling it directly would pay for that on every
    /// published change from anywhere in the controller.
    @Published private(set) var scorecard = CityScorecard()

    /// The rank the city is working toward, or `nil` once it has them all.
    var nextMilestone: Milestone? { Milestone.next(after: milestone) }

    private func updateMilestones() {
        scorecard = CityScorecard.measure(map, population: population)
        newlyEarnedMilestones = Milestone.newlyEarned(after: milestone, card: scorecard,
                                                      netRevenue: netRevenue)
        if let top = newlyEarnedMilestones.last { milestone = top }
    }

    // MARK: - Save / load

    /// Bumped every time the *entire* city is replaced wholesale, as opposed
    /// to a tile changing.
    ///
    /// `map` is already `@Published`, so an ordinary edit redraws fine. A
    /// load is different in kind: the tile *count* can change, which means
    /// `GameScene`'s sprites no longer correspond one-to-one with the map and
    /// `refreshAll()` isn't enough — it needs `rebuildEntireGrid()` plus a
    /// recentre, the same path `GameView`'s Reset button already takes for a
    /// map-size change. Watching this counter is how the rendering layer
    /// learns that happened without the controller needing to know a scene
    /// exists.
    @Published private(set) var cityGeneration = 0

    /// Everything about this city worth keeping, as one serializable value.
    ///
    /// Deliberately a plain snapshot with no file handling anywhere near it:
    /// turning a live controller into data and writing that data to disk are
    /// two jobs, and only the first one is the simulation's business. That
    /// split is also what lets a test — or a headless playtest harness — set
    /// a city up, snapshot it, and replay it without a save file existing at
    /// all.
    func snapshot() -> CitySave {
        CitySave(
            map: map,
            treasury: treasury,
            taxRate: taxRate,
            bondBalance: bondBalance,
            history: history,
            peakPopulation: peakPopulation,
            milestone: milestone
        )
    }

    /// Replaces this controller's entire city with `save`'s.
    ///
    /// Throws if `save` came from a build with a newer `CitySave` format —
    /// checked *before* anything is mutated, so a rejected load leaves the
    /// city you already had completely untouched rather than half-replaced.
    ///
    /// Three deliberate choices about what this does beyond copying fields:
    ///
    /// - **The simulation is left paused.** Loading a city drops you into it
    ///   at a standstill, rather than resuming mid-tick into a town you
    ///   haven't looked at yet.
    /// - **`selectedMapSize` is realigned to the loaded map** where one
    ///   matches, so the size picker doesn't keep advertising whatever the
    ///   last Reset was going to build. A save whose dimensions match no
    ///   `MapSize` case (an older save, or one a future in-game resize
    ///   produced) leaves the picker alone rather than lying about it — the
    ///   map itself is authoritative either way, since `selectedMapSize`
    ///   only ever describes what the *next* `resetMap()` would build.
    /// - **Per-tick scratch state is cleared, not restored.**
    ///   `lastHazardStrikes` and `isPowerOutageActive` are both recomputed
    ///   from scratch by the next `advanceSimulation()`; carrying stale ones
    ///   in would briefly show fires on a map that never had them.
    func restore(from save: CitySave) throws {
        try save.validateFormatVersion()

        // A loaded city is somebody's city already. The guide is for a first
        // one, and it is not saved: it is a record of what *this session's*
        // player has been shown, not a fact about the map.
        guide = nil

        map = save.map
        // **Recomputed, not restored.** Supply is a pure function of the map,
        // and a save is not a second opinion about it — a file written before
        // a constant moved would otherwise load with a network that does not
        // match the rules the game is now playing by.
        recomputeUtilitySupply()
        treasury = save.treasury
        taxRate = save.taxRate
        bondBalance = save.bondBalance
        history = save.history
        // A save written before unlocks existed has no record of the mark, so
        // fall back to what the city currently supports — which is the most
        // generous reading that can't hand out tools the city never earned.
        peakPopulation = save.peakPopulation ?? population
        newlyUnlockedZones = []
        milestone = save.milestone
        newlyEarnedMilestones = []
        scorecard = CityScorecard.measure(map, population: population)

        isRunning = false
        lastHazardStrikes = []
        isPowerOutageActive = false
        if let size = MapSize.allCases.first(where: { $0.dimension == save.map.width }),
           save.map.width == save.map.height {
            selectedMapSize = size
        }
        cityGeneration += 1
    }

    /// Every tile a hazard struck on the most recent `advanceSimulation()`
    /// call — empty most ticks. `GameScene` reads this right after calling
    /// `advanceSimulation()` to flash the tiles that got hit, the same
    /// "controller reports what happened, scene decides how to show it"
    /// split `PlacementOutcome` uses for the insufficient-funds flash.
    @Published private(set) var lastHazardStrikes: [CityHazards.Strike] = []

    /// Whether the power grid is blacked out *this* tick, as of the most
    /// recent `advanceSimulation()` call — see `computePowerSupply()`'s
    /// own doc comment for how it's rolled. `GameView` reads this to show
    /// a plain warning rather than making the player infer an outage
    /// from growth quietly stalling with no visible cause.
    @Published private(set) var isPowerOutageActive = false

    /// The chance of a city-wide power outage this tick when the Power
    /// Plant is completely unfunded, scaling down to 0 at full (100%)
    /// funding or above — "fundable outages," per this feature's own
    /// roadmap note, the same "funding buys real reliability" shape
    /// `LandValue.falloffValue` already gives every other service's
    /// funding lever (weaker coverage/land value when underfunded). A
    /// first guess, same "needs playtesting" status as every other
    /// constant in this project starts at. Deliberately a single
    /// city-wide roll, not one per Power Plant — the simplest version of
    /// this that's still a real, felt consequence; per-plant redundancy
    /// (a second plant halving your exposure) is a genuine refinement to
    /// make later, not a correctness fix now.
    private static let basePowerOutageChance = 0.15

    /// Rolls whether the grid blacks out this tick, then computes the
    /// result the same way `Water.computeSupply(for:)` already does for
    /// the parallel network — `PowerGrid` itself stays exactly as
    /// deterministic as `Water` is; the one random decision lives here,
    /// drawing from the same shared `rng` `CityHazards` and
    /// `CitySimulator`'s demand roll already use, not a second
    /// independent source of randomness.
    private func computePowerSupply() -> PowerSupply {
        let fundingLevel = map.serviceFunding.level(for: .powerPlant)
        let outageChance = Self.basePowerOutageChance * max(0, 1 - fundingLevel)
        let outageActive = Double.random(in: 0 ..< 1, using: &rng) < outageChance
        isPowerOutageActive = outageActive
        return PowerGrid.computeSupply(for: map, outageActive: outageActive)
    }

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
    /// Recompute what the utility networks currently supply.
    ///
    /// **Why this is not only called from `advanceSimulation`.** It used to be,
    /// and the effect was that laying pipe or power line changed nothing you
    /// could see until the next tick — and the game starts *paused*, so a
    /// player could build an entire network, watch the Water overlay stay
    /// stubbornly dry, and reasonably conclude the mechanic was broken. The
    /// pipe markers appeared, because those read `Tile.hasPipe` directly; the
    /// supply colouring did not, because that reads a cached field nobody had
    /// recomputed.
    ///
    /// Supply is a pure function of the map, so recomputing it the moment the
    /// map changes is both correct and cheap — it is one flood fill per
    /// network, not a simulation step. Anything that can change what is
    /// connected calls this: laying or removing a pipe or line, placing or
    /// bulldozing a utility building, and changing funding, which buys
    /// capacity.
    /// **The expensive half**: two whole-map flood fills, measured at 8.6 ms
    /// together on a built-out 64×64 city. Only a source, a conduit or a
    /// change in demand moves it — see `ZoneType.feedsAUtilityNetwork` — so
    /// call it when one of those happened rather than after every placement.
    ///
    /// It no longer recomputes the tram tracks as a side effect. They are not
    /// supply, they follow the streets, and folding them in here meant every
    /// caller had to choose between recomputing rails it did not need or
    /// skipping supply it did.
    func recomputeUtilitySupply() {
        map.waterSupply = Water.computeSupply(for: map)
        map.powerSupply = computePowerSupply()
    }

    /// Where the rails are, which changes when a tram line does and when the
    /// streets under one do.
    ///
    /// Recomputed eagerly rather than per tick for the reason supply is: the
    /// game starts paused, and a player who draws a tram line and watches the
    /// traffic overlay not budge until the next tick would reasonably
    /// conclude the mechanic is broken. That exact bug is recorded for pipes.
    /// Sets a tile's density directly, for tests that need a city in a
    /// particular state without growing one to reach it. `map` is
    /// `private(set)`, deliberately — this is the one seam through it, and it
    /// is named so nothing mistakes it for a simulation step.
    func setDensityForTesting(_ density: Int, at position: GridPosition) {
        map[position].density = density
    }

    func recomputeTramTracks() {
        map.tramTracks = Transit.tramTracks(in: map)
    }

    func advanceSimulation() {
        // Routed commute load first, before hazards/growth run — both read
        // it (via `LandValue`'s road-frontage dampening), and they should
        // see this tick's freshly-computed congestion for the map as it
        // stood at the start of the tick, not last tick's stale numbers.
        // `CityHazards.apply`'s and `CitySimulator.advance`'s `next = map`
        // copies both carry it forward automatically since it's just
        // another field on the struct they copy.
        // Rails first: `Traffic.congestion` reads them to decide how much of
        // a street is left for cars, and routing reads congestion.
        map.tramTracks = Transit.tramTracks(in: map)
        map.trafficLoad = Traffic.computeLoad(for: map)
        // Between traffic and supply, and it has to be exactly there: wear
        // reads this tick's congestion to decide which roads are rotting
        // fastest, and a main that bursts this tick has to cut the network
        // this tick rather than next.
        map = Infrastructure.advance(map)
        map.waterSupply = Water.computeSupply(for: map)
        map.powerSupply = computePowerSupply()
        // The region moves on whether the player is watching or not, and it
        // has to move *before* demand is computed — `Demand.compute` reads it.
        map.regionalEconomy = map.regionalEconomy.advanced()
        map.cityDemand = Demand.compute(for: map)
        // Before hazards and growth, like every other whole-map value above:
        // `LandValue` reads it, and both of those read land value.
        map.pollution = Pollution.compute(for: map)
        // Fires that are already burning move *before* new ones are struck,
        // so a block lit this tick gets its first burnout-or-spread roll on
        // the next one. Same reasoning `CityHazards.apply` already runs on:
        // a thing has to survive one full step before the next stage of it is
        // considered.
        let (burning, spread) = Fire.advance(map, using: &rng)
        let (hazarded, strikes) = CityHazards.apply(to: burning, using: &rng)
        // Reported together, so a fire jumping to the next block gets the same
        // flash on the map as the strike that started it — to the player they
        // are the same event, and the second one is the more alarming.
        lastHazardStrikes = spread + strikes
        map = CitySimulator.advance(hazarded, using: &rng)
        treasury += netRevenue
        newlyUnlockedZones = Unlocks.newlyUnlocked(crossing: population, from: peakPopulation)
        peakPopulation = max(peakPopulation, population)
        updateMilestones()
        recordHistorySnapshot()
        // The city just moved under a pointer that has not. A panel showing
        // last tick's answer is worse than one showing none, because it looks
        // live.
        refreshInspection()
    }

    private func recordHistorySnapshot() {
        history.append(CityStatSnapshot(population: population, jobs: jobs, treasury: treasury))
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

    /// Upkeep per road tile, per tick — the missing "road maintenance" cost
    /// every real city-builder has, and highways cost more per tile than a
    /// plain road (they're wider, faster infrastructure) the same way they
    /// cost more to build. Deliberately small per tile: a road network
    /// runs into the thousands of tiles on a large, built-out map, so this
    /// only needs to be a fraction of a service building's flat upkeep to
    /// add up to a real number.
    ///
    /// This is the actual fix for a real bug a live playtest found:
    /// without it, `upkeepCost` below was 0 for every zoned tile and every
    /// road tile, so it was capped at whatever the map's fixed handful of
    /// service buildings cost — a number that stops growing the moment the
    /// player stops building new services, while `taxRevenue` keeps
    /// climbing with population/jobs indefinitely. A standalone playtest
    /// harness confirmed the failure mode precisely: a mature, fully-grown
    /// 64×64 test city (1,176 road tiles, population plateaued around 420)
    /// settled into a *constant* +$650-750/tick net revenue the moment
    /// growth stopped, with nothing to ever bring it back toward zero —
    /// treasury passed $1.2 million within 1,300 further ticks, climbing
    /// linearly forever. That's the exact "one-way accumulator" this
    /// property's own `ZoneType.upkeepCost` doc comment already named as
    /// the failure mode service upkeep was added to avoid, just one rung
    /// up: a bigger, more sprawling city (more roads) now costs more to
    /// maintain, the same way it earns more tax, instead of costing the
    /// same fixed amount as a tiny one. Re-running that same harness with
    /// this in place brought the mature city's net revenue down to a
    /// gentle trickle rather than a flat several-hundred-dollar surplus —
    /// still a first-guess rate, same as everything else in this file, but
    /// one checked against real simulated numbers rather than a guess made
    /// in the abstract.
    /// The lot the pointer is over, and what the inspector says about it.
    ///
    /// **Cached rather than derived in the view.** `TileReport.make` builds a
    /// `ZoneDistanceField` when it is not handed one — a whole-map distance
    /// transform — and a SwiftUI body that called it directly would pay for
    /// that on every mouse move *and* on every published change from anywhere
    /// else in the controller. Recomputed here instead exactly twice: when the
    /// pointer crosses onto a different lot, and when the city ticks
    /// underneath a stationary pointer.
    @Published private(set) var inspectedReport: TileReport?

    private var inspectedPosition: GridPosition?

    /// Point the inspector at a lot, or at nothing.
    ///
    /// Takes the position rather than the report so the "has it actually
    /// changed" check lives in one place: `mouseMoved` fires far faster than
    /// the pointer crosses tiles, and rebuilding the report on every event
    /// would be most of a tick's work several times a second.
    func inspect(at position: GridPosition?) {
        guard position != inspectedPosition else { return }
        inspectedPosition = position
        refreshInspection()
    }

    private func refreshInspection() {
        guard let inspectedPosition, map.contains(inspectedPosition) else {
            inspectedReport = nil
            return
        }
        inspectedReport = TileReport.make(at: inspectedPosition, in: map)
    }

    /// How many lots want the player's attention, by how badly.
    ///
    /// **The overview the inspector could not give.** Hovering answers "what
    /// is wrong with this lot", which only helps once you know which lot to
    /// point at — and finding that out meant checking every block in the city,
    /// faster than the simulation was changing them. Reported from play as
    /// "everything is happening so fast, there's no way to check on all the
    /// issues the buildings are having", which is a discovery problem wearing
    /// a pacing problem's clothes.
    ///
    /// Computed on demand rather than cached: it sweeps the map, so it is a
    /// tick's worth of work, and it is read once per dashboard refresh rather
    /// than per tile.
    func lotsNeedingAttention() -> [LotStatus.Severity: Int] {
        let distances = ZoneDistanceField.compute(for: map)
        var counts: [LotStatus.Severity: Int] = [:]
        for tile in map.tiles where tile.isBuildingAnchor && tile.zone.maxDensity > 0 {
            let severity = CitySimulator.status(of: tile, in: map, using: distances).severity
            guard severity != .fine else { continue }
            counts[severity, default: 0] += 1
        }
        return counts
    }

    /// How many separate blocks are on fire right now. Drives the cockpit's
    /// fire alert — see `Fire`.
    var burningBlocks: Int { Fire.count(in: map) }

    /// How much of the city's road, pipe and power-line network is worn far
    /// enough to be worth worrying about — see
    /// `Infrastructure.degradedFraction`. Drives the cockpit's Roads meter.
    var infrastructureWear: Double { Infrastructure.degradedFraction(in: map) }

    /// What the player is paying for public works, as a multiple of the
    /// default. Named separately from `fundingLevel(for: .road)` because
    /// upkeep reads it per tile, thousands of times per tick.
    var maintenanceFunding: Double { map.serviceFunding.level(for: .road) }

    static let roadUpkeepPerTile: Double = 0.5
    static let highwayUpkeepPerTile: Double = 1.2

    /// What the city costs to run this step: every placed service/
    /// infrastructure building (scaled by its own `fundingLevel(for:)` —
    /// the same lever that weakens its coverage in `LandValue.falloffValue`
    /// weakens what it costs to run, fund a station at 50% and it's both
    /// cheaper and less effective, not just one or the other) plus the
    /// road network's own per-tile maintenance above. One pass over
    /// `map.tiles` handles both: a road/highway tile's upkeep doesn't
    /// depend on `isBuildingAnchor` (every road tile is its own anchor,
    /// `footprintSize == 1`) the way a service building's flat cost does.
    var upkeepCost: Int {
        var total = 0.0
        for tile in map.tiles {
            switch tile.zone {
            // Scaled by the public-works dial, the same way a service
            // building's cost scales with its own funding. This is the whole
            // economics of phase 6: the dial buys road condition and charges
            // for it on the axis the condition is spent on.
            case .road:
                total += Self.roadUpkeepPerTile * maintenanceFunding
            case .highway:
                total += Self.highwayUpkeepPerTile * maintenanceFunding
            default:
                guard tile.isBuildingAnchor else { continue }
                let base = tile.zone.upkeepCost
                guard base > 0 else { continue }
                total += Double(base) * fundingLevel(for: tile.zone)
            }
        }
        // Running the lines, on top of the stations they call at. A station is
        // the shelter and is charged for above; this is the vehicles, so a
        // stop nobody has put on a route costs only the lower figure and
        // drawing a line is where the ongoing money goes.
        //
        // Charged on *working* stops, so a line whose station was demolished
        // stops billing for a service it is not providing — the same fact
        // `Transit.dailyCapacity` reads, from the same place.
        for route in map.transit.routes {
            guard Transit.isRunning(route, in: map) else { continue }
            total += Double(Transit.workingStops(of: route, in: map).count)
                * route.mode.upkeepPerStop
                * fundingLevel(for: route.mode.stationZone)
        }
        return Int(total)
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
        // Funding buys capacity, so halving the water budget can take a
        // network over its limit — which the overlay should show at once,
        // since the whole point of the dial is watching what it does.
        recomputeUtilitySupply()
    }

    /// Per-tick cost of running the city itself, per resident and per job —
    /// schools, sanitation, administration, everything a city owes its
    /// population that isn't a building the player placed.
    ///
    /// **This is the fix for the money-printer bug**, and it is deliberately
    /// a different *shape* of cost than everything above it rather than
    /// another rate to tune. A playtest harness run
    /// (`PlaytestScenarioTests.testAMatureCityDoesNotBecomeAMoneyPrinter`)
    /// showed a plateaued 64×64 city banking a flat +$6,160/tick forever,
    /// treasury climbing linearly past $9.2M, with `upkeepCost` pinned at a
    /// constant 2,174 against 8,334 of tax revenue. `roadUpkeepPerTile` had
    /// been added to fix exactly that and hadn't, because it addressed the
    /// wrong axis: every cost in this file scales with *placed
    /// infrastructure*, which stops changing the moment a city is built out,
    /// while `taxRevenue` scales with *population and jobs*, which keep
    /// climbing until they plateau high. No infrastructure-scaled constant
    /// can close a gap between a static cost and a much larger static
    /// income — only a cost on the same axis as the income can, which is
    /// this one.
    ///
    /// Charged per *citizen* — `population + jobs` — so it lands on exactly
    /// what `taxRevenue` is computed from. Against `taxPerPopulation` of 1
    /// and `taxPerJob` of 2, a rate below 1.0 leaves every resident and
    /// every job still net-positive for the treasury, so growth remains
    /// worth pursuing; it just stops being *unboundedly* profitable.
    ///
    /// Deliberately not scaled by `taxRate` (a cost, not a tax) and not by
    /// `fundingLevel(for:)` (the funding dial is about how well individual
    /// services are staffed, not about whether the city runs at all).
    ///
    /// The rate below was chosen by measurement, not guessed: at 0.75 the
    /// same harness city's steady-state net revenue falls from +$6,160/tick
    /// to roughly a fifth of tax revenue — a city that still profits enough
    /// to fund expansion, without the surplus growing without bound. Like
    /// every other number in this file it is a first guess in the sense that
    /// the *target* (how profitable a well-run city should be) is a design
    /// question nobody has playtested; unlike most of them, the number
    /// actually hits the target it was aimed at.
    static let civicUpkeepPerCitizen = 0.75

    /// `civicUpkeepPerCitizen` applied to the city's current population and
    /// jobs. Separate from `upkeepCost` rather than folded into it so the
    /// two stay legible as the different things they are — one is what the
    /// player *built*, the other is what the city *became*.
    var civicUpkeep: Int {
        Int(Double(population + jobs) * Self.civicUpkeepPerCitizen)
    }

    /// What `advanceSimulation()` actually deposits (or withdraws) this
    /// step: tax revenue minus infrastructure upkeep, the city's own civic
    /// cost, bond interest, and ordinance upkeep. Can go negative — a city
    /// with more services (or more debt, or more active ordinances) than its
    /// tax base supports yet should feel that as a real drain, not have it
    /// silently floored at zero.
    var netRevenue: Int {
        taxRevenue
            - upkeepCost
            - civicUpkeep
            - bondInterest
            - map.ordinances.totalUpkeepCost(population: population)
    }

    // MARK: - Ordinances (city-wide policy toggles)

    /// Whether `ordinance` is currently active. Reads straight through to
    /// `map.ordinances`, the same passthrough shape `fundingLevel(for:)`
    /// already has for `ServiceFunding` — one source of truth the
    /// simulation itself reads too, not a separate UI-facing copy.
    func isOrdinanceActive(_ ordinance: KeyPath<Ordinances, Bool>) -> Bool {
        map.ordinances[keyPath: ordinance]
    }

    /// Toggles `ordinance` on or off. `WritableKeyPath` rather than naming
    /// each ordinance its own setter (the way `ServiceFunding.setLevel(_:for:)`
    /// has to, since that one's keyed by `ZoneType` rather than by field) —
    /// `Ordinances` has a fixed, small set of named `Bool` properties, so a
    /// key path is enough to reach any one of them without a `switch`.
    func setOrdinance(_ ordinance: WritableKeyPath<Ordinances, Bool>, active: Bool) {
        map.ordinances[keyPath: ordinance] = active
    }

    /// What the city draws from its water network against what its towers
    /// supply. `GameView` shows it so that "growth stopped because you are out
    /// of water" is something the player can see coming rather than infer.
    var waterLoad: UtilityLoad { Water.load(in: map) }

    /// The power-grid counterpart to `waterLoad`.
    var powerLoad: UtilityLoad { PowerGrid.load(in: map) }

    /// How much the city currently wants more of each RCI type — reads
    /// straight through to `map.cityDemand`, which is where the simulation
    /// itself (`CitySimulator.advance`) reads it too. Exists so `GameView`
    /// doesn't need to know `CityMap` is where demand state actually
    /// lives, the same reasoning `fundingLevel(for:)` already documents
    /// for itself. Was invisible to the player entirely until now — the
    /// gate existed (`CitySimulator`'s growth roll) with no meter reading
    /// it out, exactly the "shallow half without the real half" shape the
    /// original design doc warned against building *instead of* the gate;
    /// this is that meter, added only once the gate underneath it was real.
    var cityDemand: CityDemand {
        map.cityDemand
    }

    /// Reads through `map.totalDensity(of:)` and `ZoneType.populationPerDensityLevel`
    /// rather than keeping its own rate — `Demand.compute(for:)` (Simulation/)
    /// needs the exact same number, so it lives on `ZoneType` now as one
    /// shared source instead of two copies that could drift.
    ///
    /// Plus whoever lives in an arcology, who are residents in every sense
    /// the city's books care about but not in `Demand` or on the roads — see
    /// `RewardBuildings.arcologyResidents`.
    var population: Int {
        map.totalDensity(of: .residential) * ZoneType.residential.populationPerDensityLevel
            + RewardBuildings.residents(in: map)
    }

    /// Same reasoning as `population`: reads `ZoneType.jobsPerDensityLevel`
    /// rather than a private rate of its own.
    var jobs: Int {
        map.totalDensity(of: .commercial) * ZoneType.commercial.jobsPerDensityLevel
            + map.totalDensity(of: .industrial) * ZoneType.industrial.jobsPerDensityLevel
    }
}
