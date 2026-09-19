import Foundation
@testable import AlphaPlusPlus

/// Builds cities, runs them for thousands of ticks, and reports what the
/// economy and the hazard system actually did.
///
/// **Why this exists as committed code.** Nearly every constant in this
/// project is documented in place as a first guess awaiting playtesting.
/// Three of them were finally tuned against real numbers — `roadUpkeepPerTile`
/// (new), `bondInterestRate` (cut 8x), and the two `CityHazards` rates (cut
/// 10x) — and their doc comments cite very specific evidence for the change: a
/// mature city settling into a constant +$650-750/tick with treasury past
/// $1.2M, a borrowing city spiralling to -$1.15M over 5,000 ticks, fire and
/// crime together striking 4.5-5.6 tiles *every tick*. All of that came from a
/// standalone harness that was then thrown away, which left three balance
/// decisions resting on evidence nobody could reproduce or re-check.
///
/// This is that harness, kept this time. It is deliberately a plain type in
/// the test target rather than a new build target: the simulation is pure
/// Foundation and needs no Metal context, `GameController` is already
/// injectable with an RNG, and one `xcodebuild test -only-testing:` run is a
/// better iteration loop than a second product to build and maintain.
///
/// **On building cities directly rather than through `place(at:)`.** A player
/// pays `ZoneType.placementCost` per building, and a mature test city is
/// thousands of buildings — funded from a starting treasury of $10,000, the
/// harness would go broke long before it had a city worth measuring. Building
/// the `CityMap` directly and handing it to `GameController(map:)` models
/// exactly the scenario these measurements are about: a city that *already
/// exists*, now being run forward. Construction economics are a separate
/// question from steady-state economics, and conflating them is what made the
/// original "is upkeep keeping up with revenue?" question hard to see.
@MainActor
enum PlaytestHarness {

    // MARK: - Profiles

    /// How big and how long a scenario runs.
    ///
    /// Balance scenarios want a full-size city run for thousands of ticks;
    /// the test suite wants to finish in seconds. Measured cost per tick,
    /// with a fully built-out city:
    ///
    /// | map   | Debug     | Release  | lots |
    /// |-------|-----------|----------|------|
    /// | 16×16 |   25.8 ms |   0.8 ms |   33 |
    /// | 24×24 |  124.5 ms |   3.1 ms |   80 |
    /// | 32×32 |  364.2 ms |   8.5 ms |  133 |
    /// | 48×48 | 1994.5 ms |  39.5 ms |  320 |
    /// | 64×64 | 6286.3 ms | 114.5 ms |  560 |
    ///
    /// Two things to take from that table. **Debug is ~55x slower than
    /// Release**, because `@testable` and `-Onone` defeat essentially all of
    /// the optimizer on a workload that is almost entirely tight loops over
    /// structs — so any real balance work belongs in Release. And tick cost
    /// grows *superlinearly* in map area (16x the tiles from 16×16 to 64×64
    /// costs 143x the time), which is `Traffic.computeLoad` routing more
    /// commuters over longer paths as the city grows.
    ///
    /// So: `.quick` by default, sized to keep the suite fast while still
    /// catching a gross balance regression, and `.full` on demand for actual
    /// tuning. Enable the latter with `PLAYTEST_FULL=1` — via xcodebuild that
    /// is `TEST_RUNNER_PLAYTEST_FULL=1`, since xcodebuild only forwards
    /// environment variables carrying that prefix, which it strips.
    enum Profile: Equatable {
        /// Small and short: a regression guard that runs with the suite.
        case quick
        /// Full-size and long: what a real balance measurement uses.
        case full

        static var current: Profile {
            ProcessInfo.processInfo.environment["PLAYTEST_FULL"] != nil ? .full : .quick
        }

        var size: Int {
            switch self {
            // 24 rather than 16. The smaller size was chosen when a tick cost
            // 25.8 ms; after `ZoneDistanceField` a 24×24 tick costs 11.6 ms,
            // so this is *cheaper* than the old quick profile while being far
            // more representative. 16×16 held only ~33 lots, which meant a
            // full set of services — schools and hospitals included — was a
            // fixed cost heavy enough to bankrupt the city on its own, and
            // scenarios started failing for reasons that were about the
            // fixture's size rather than about the thing being measured.
            case .quick: return 24
            case .full: return MapSize.large.dimension
            }
        }

        var ticks: Int {
            switch self {
            // 120 rather than a rounder 200: a 16×16 city plateaus well
            // inside 60 ticks, so the back half is already steady state and
            // everything beyond that is paying 25.8 ms/tick to re-measure the
            // same numbers. Trimming it is most of why the scenario suite
            // runs in about half the time it first did.
            // 320 rather than 80. Every number in this comment's history was
            // chosen when growth was instantaneous and a city plateaued in
            // sixteen ticks, so 80 was mostly re-measuring a settled city.
            // Construction changed that: a lot now spends
            // `CitySimulator.constructionTicks(toReach:)` building each level,
            // up to 40 for the top tier, so a city needs a few hundred ticks
            // to finish. At 80 these scenarios were all quietly measuring a
            // half-built city — which is the sort of thing that looks like a
            // balance regression and is not one.
            case .quick: return 320
            case .full: return 1_500
            }
        }

        var name: String {
            switch self {
            case .quick: return "quick"
            case .full: return "full"
            }
        }
    }

    /// A spec sized for the active profile.
    static func spec(
        includeUtilities: Bool = true,
        includeServices: Bool = true,
        serviceSpacing: Int = 6,
        regionalWeather: Bool = false
    ) -> CitySpec {
        CitySpec(
            size: Profile.current.size,
            includeUtilities: includeUtilities,
            includeServices: includeServices,
            regionalWeather: regionalWeather,
            serviceSpacing: serviceSpacing
        )
    }

    // MARK: - City generation

    /// What kind of city to build.
    struct CitySpec {
        /// Map dimension; the city is always square.
        var size: Int = MapSize.large.dimension

        /// A road runs along every row where `y % roadSpacing == 0`, and
        /// 2×2 lots fill the rows between. At the default 3 that is one road
        /// row per two rows of buildings, so every lot touches a road — the
        /// access gate `CitySimulator` checks is satisfied by construction,
        /// which keeps a measurement about *economics* from silently
        /// becoming a measurement about road layout.
        var roadSpacing: Int = 3

        /// Whether to lay the water and power networks, and place the
        /// service buildings that make higher densities reachable at all.
        /// Off produces a deliberately under-served city — which is what a
        /// hazard-rate measurement wants, since hazards only ever fire on
        /// buildings below `CityHazards.coverageThreshold`.
        var includeUtilities: Bool = true
        var includeServices: Bool = true

        /// Whether the region outside the city runs its boom-and-bust cycle.
        ///
        /// **Off by default, and that is a measurement decision rather than a
        /// convenience.** This harness exists to measure the city's own
        /// economics, and it already goes out of its way to hold the other
        /// variables still — `roadSpacing` is chosen so every lot touches a
        /// road specifically to stop "a measurement about economics silently
        /// becoming a measurement about road layout". `RegionalEconomy` is the
        /// same hazard and worse: its cycles run up to
        /// `RegionalEconomy.longestCycle` ticks, which is *longer than the
        /// whole quick profile*, so a tail mean taken with weather on is not
        /// an average over the cycle at all — it is one arbitrary sample of
        /// it. That is exactly how a solvent city came to report negative net
        /// revenue the moment phase 5 landed: same city, same constants, the
        /// yardstick had started moving.
        ///
        /// Turn it on for scenarios where the region *is* the subject — see
        /// `PlateauDiagnosticTests`, which does.
        var regionalWeather: Bool = false

        /// How many building lots separate one service building from the
        /// next. Larger means thinner coverage and more hazard-eligible
        /// buildings.
        var serviceSpacing: Int = 6

        /// The rotation lots are zoned from, cycled in order. The default is
        /// 2 residential : 1 commercial : 1 industrial, roughly what `Demand`
        /// considers balanced. Override it to model a player who zones badly
        /// — all housing and no jobs, say.
        var zoneMix: [ZoneType] = [.residential, .residential, .commercial, .industrial]

        /// Whether industry is banished to its own district instead of being
        /// interleaved with housing.
        ///
        /// This is the knob that models *planning*. With it off, lots cycle
        /// through `zoneMix` wherever they fall, so factories sit next door to
        /// houses — which cost nothing at all until `Pollution` existed. With
        /// it on, industry is confined to the bottom of the map and housing
        /// and shops take the rest.
        var segregateIndustry: Bool = false

        /// Whether to build a transit *network* — stations at
        /// `transitSpacing`, over and above the single stop the service
        /// rotation already places — and of what kind.
        ///
        /// Separate from `drawTransitRoutes` on purpose, because the
        /// comparison that matters is a pair differing *only* in whether the
        /// lines were drawn. The service rotation on its own puts one transit
        /// stop per 36 lots, which on a 24×24 map is two stations and one
        /// two-stop line — not a network, and not enough to measure anything
        /// about one.
        var transitStations: TransitRoute.Mode?

        /// Lots between stations.
        ///
        /// Eight, measured rather than guessed: a stop's catchment is a
        /// radius-`Transit.busCatchment` diamond, about forty tiles, which on
        /// this lot grid is roughly ten lots. Closer than that and the
        /// catchments overlap while the stations eat the tax base they exist
        /// to serve — at four, a 24×24 city gave a quarter of its lots over to
        /// bus stops and went bankrupt before a single line was drawn.
        var transitSpacing: Int = 8

        /// Whether those stations are wired into lines. The control leaves
        /// this off: the stations are still built, still gate road access,
        /// still count as an amenity — exactly as they did before routes
        /// existed.
        var drawTransitRoutes: Bool = false

        /// How many stations go on one line before a new one is started.
        /// Four is a plausible player network on these map sizes: long enough
        /// to cross a district, short enough that a city gets several.
        var stopsPerRoute: Int = 4

        /// At most this many lines, or all of them.
        ///
        /// The generator wires *every* station into a route, which is a city
        /// that has gone all-in on one mode — useful for measuring what a
        /// network does and useless for measuring what a single line is
        /// worth. A player builds one first.
        var routeLimit: Int?
    }

    /// Lays out a city according to `spec`.
    ///
    /// The zone mix is 2 residential : 1 commercial : 1 industrial, which
    /// roughly matches what `Demand` considers balanced — a city built all of
    /// one type would stall on demand rather than on anything the caller is
    /// trying to measure.
    static func buildCity(_ spec: CitySpec) -> CityMap {
        var map = CityMap(width: spec.size, height: spec.size)
        if !spec.regionalWeather { map.regionalEconomy = .calm }

        // Road rows first, so lots can be placed against them.
        for y in stride(from: 0, to: spec.size, by: spec.roadSpacing) {
            for x in 0..<spec.size {
                map.placeBuilding(zone: .road, origin: GridPosition(x: x, y: y))
            }
        }

        // Utilities share the road rows: a pipe or a power line under a
        // street reaches every lot fronting it, which is the same adjacency
        // `Water.hasSupply(at:in:)` and `PowerGrid` already check.
        if spec.includeUtilities {
            for y in stride(from: 0, to: spec.size, by: spec.roadSpacing) {
                for x in 0..<spec.size {
                    map[GridPosition(x: x, y: y)].hasPipe = true
                    map[GridPosition(x: x, y: y)].hasPowerLine = true
                }
            }
            // The vertical trunk that ties every horizontal run together.
            for y in 0..<spec.size {
                map[GridPosition(x: 0, y: y)].hasPipe = true
                map[GridPosition(x: 0, y: y)].hasPowerLine = true
            }
        }

        // A reserved strip along the top edge for power plants, which need
        // three rows and so cannot share the two-row lot grid. Realistic
        // enough — plants go on the outskirts — and it is the only way the
        // generator produces any at all.
        let plantStripTop = spec.size - 4
        if spec.includeServices {
            for x in 0 ..< spec.size {
                map[GridPosition(x: x, y: spec.size - 1)].hasPowerLine = true
            }
            // Sized from expected draw rather than picked: lots work out at
            // about `size² / 6`, each reaching roughly density 4, so a
            // built-out city draws on the order of `size² / 1.5`. Dividing
            // that by `PowerGrid.capacityPerPlant` and leaving headroom lands
            // near `size² / 600`. Headroom is deliberate — the *default*
            // generated city should not be power-starved, or every other
            // scenario in the suite would silently be measuring a capacity
            // stall instead of whatever it meant to measure.
            // `DesignPlaytestTests.testUtilityCapacityGatesGrowth` thins them
            // back down when it wants capacity to bite.
            // Rounded *up*: plain integer division turned 32×32's 1.7 plants
            // into 1, leaving the small map permanently over capacity while
            // the large one was fine.
            let plantCount = max(1, (spec.size * spec.size + 599) / 600)
            var x = 0
            for _ in 0 ..< plantCount {
                guard x + 3 <= spec.size else { break }
                map.placeBuilding(zone: .powerPlant, origin: GridPosition(x: x, y: plantStripTop))
                x += 4
            }
        }

        // Lots are assigned in two passes rather than one, so that
        // `segregateIndustry` can rearrange the *same* set of zones instead of
        // producing a different mix.
        //
        // The single-pass version decided each lot's zone as it reached it,
        // which meant the planned and mixed layouts ended up with genuinely
        // different compositions once services had eaten an uneven share of
        // each — 34R/14C/21I against 29R/20C/20I in one measured case. That
        // makes the planning comparison a comparison of two different cities,
        // which is exactly the confound it was written to avoid.
        var lots: [GridPosition] = []
        for y in stride(from: 1, to: spec.includeServices ? plantStripTop : spec.size - 1, by: spec.roadSpacing) {
            for x in stride(from: 0, to: spec.size - 1, by: 2) {
                let origin = GridPosition(x: x, y: y)
                guard map[origin].zone == .empty else { continue }
                lots.append(origin)
            }
        }

        // Services first, at a fixed stride, so both layouts place them
        // identically.
        var assignment = [ZoneType?](repeating: nil, count: lots.count)
        if spec.includeServices {
            // The transit stop in the rotation becomes whichever kind the
            // spec asks for, so a bus city and a subway city are the same
            // layout with the stations swapped — not two different cities.
            let services: [ZoneType] = [
                .policeStation, .fireStation, spec.transitStations?.stationZone ?? .publicTransit,
                .waterTower, .school, .hospital,
            ]
            for index in stride(from: 0, to: lots.count, by: spec.serviceSpacing) {
                assignment[index] = services[(index / spec.serviceSpacing) % services.count]
            }
        }

        // A real transit network, laid over the top of the rotation. Written
        // after it so a station always wins the lot: a city being measured for
        // what its transit does must not have half its stops quietly replaced
        // by a hospital.
        if let mode = spec.transitStations {
            for index in stride(from: 0, to: lots.count, by: spec.transitSpacing) {
                assignment[index] = mode.stationZone
            }
        }

        // Everything else cycles `zoneMix`. Segregating keeps that exact
        // multiset and only changes *where* each zone lands: industry takes
        // the lowest rows, since `lots` is built in row order.
        let openSlots = assignment.indices.filter { assignment[$0] == nil }
        var mix = openSlots.indices.map { spec.zoneMix[$0 % spec.zoneMix.count] }
        if spec.segregateIndustry {
            let industrial = mix.filter { $0 == .industrial }
            let everythingElse = mix.filter { $0 != .industrial }
            mix = industrial + everythingElse
        }
        for (slot, zone) in zip(openSlots, mix) {
            assignment[slot] = zone
        }

        for (index, origin) in lots.enumerated() {
            guard let zone = assignment[index] else { continue }
            let footprint = map.footprintCells(origin: origin, size: zone.footprintSize)
            guard footprint.count == zone.footprintSize * zone.footprintSize else { continue }
            guard footprint.allSatisfy({ map[$0].zone == .empty }) else { continue }
            map.placeBuilding(zone: zone, origin: origin)
        }

        // Lines last, over whatever stations actually went down — chained in
        // row order, so each one runs across a band of the city the way a
        // player drawing a cross-town service would.
        if let mode = spec.transitStations, spec.drawTransitRoutes {
            let stations = map.tiles
                .filter { $0.isBuildingAnchor && $0.zone == mode.stationZone }
                .map(\.position)
                .sortedByPosition()
            for chunk in stride(from: 0, to: stations.count, by: spec.stopsPerRoute) {
                if let limit = spec.routeLimit, map.transit.routes.count >= limit { break }
                let stops = Array(stations[chunk ..< min(chunk + spec.stopsPerRoute, stations.count)])
                guard stops.count >= TransitRoute.minimumStops else { continue }
                map.transit.add(mode: mode, stops: stops)
            }
        }

        return map
    }

    // MARK: - Running

    /// One tick's worth of numbers.
    struct TickMetrics {
        let tick: Int
        let population: Int
        let jobs: Int
        let treasury: Int
        let taxRevenue: Int
        let upkeepCost: Int
        let civicUpkeep: Int
        let bondInterest: Int
        let netRevenue: Int
        let hazardStrikes: Int
    }

    struct RunResult {
        let ticks: [TickMetrics]

        var final: TickMetrics { ticks[ticks.count - 1] }

        func mean(_ value: (TickMetrics) -> Int) -> Double {
            guard !ticks.isEmpty else { return 0 }
            return ticks.reduce(0.0) { $0 + Double(value($1)) } / Double(ticks.count)
        }

        func max(_ value: (TickMetrics) -> Int) -> Int {
            ticks.map(value).max() ?? 0
        }

        /// The last `fraction` of the run — the part after early growth has
        /// settled, which is what a steady-state claim should be measured on.
        func tail(_ fraction: Double = 0.25) -> RunResult {
            let count = Swift.max(1, Int(Double(ticks.count) * fraction))
            return RunResult(ticks: Array(ticks.suffix(count)))
        }
    }

    /// Ticks `controller` `count` times, recording every tick.
    static func run(_ controller: GameController, ticks count: Int) -> RunResult {
        var recorded: [TickMetrics] = []
        recorded.reserveCapacity(count)
        for tick in 0..<count {
            controller.advanceSimulation()
            recorded.append(TickMetrics(
                tick: tick,
                population: controller.population,
                jobs: controller.jobs,
                treasury: controller.treasury,
                taxRevenue: controller.taxRevenue,
                upkeepCost: controller.upkeepCost,
                civicUpkeep: controller.civicUpkeep,
                bondInterest: controller.bondInterest,
                netRevenue: controller.netRevenue,
                hazardStrikes: controller.lastHazardStrikes.count
            ))
        }
        return RunResult(ticks: recorded)
    }

    /// Builds a city from `spec` and runs it, all in one call.
    ///
    /// `seed` feeds `SeededRNG`, so a scenario reproduces exactly run to run
    /// — a balance number nobody can re-measure is the thing this harness
    /// exists to stop producing.
    static func runScenario(
        _ spec: CitySpec,
        ticks: Int,
        seed: UInt64 = 0xA1F4,
        configure: (GameController) -> Void = { _ in }
    ) -> (controller: GameController, result: RunResult) {
        let controller = GameController(map: buildCity(spec), rng: SeededRNG(seed: seed))
        configure(controller)
        return (controller, run(controller, ticks: ticks))
    }

    // MARK: - Reporting

    /// A human-readable summary, for reading in the test log or writing to a
    /// file alongside the icon contact sheet.
    ///
    /// Reports both the final tick and the *tail mean* — the average across
    /// the last quarter of the run. A steady-state claim ("this city settles
    /// into +$700/tick forever") is a claim about the tail, not about one
    /// final reading that might have caught an unusual tick.
    static func report(title: String, spec: CitySpec, result: RunResult) -> String {
        let tail = result.tail()

        var lines: [String] = []
        lines.append("=== \(title) ===")
        lines.append("map \(spec.size)×\(spec.size), road spacing \(spec.roadSpacing), "
                     + "services \(spec.includeServices ? "on" : "off"), "
                     + "utilities \(spec.includeUtilities ? "on" : "off")")
        lines.append("ticks: \(result.ticks.count)")
        lines.append("")
        lines.append(pad("metric", 16) + pad("final", 14) + pad("tail mean", 14))
        lines.append(String(repeating: "-", count: 44))

        func row(_ label: String, _ value: @escaping (TickMetrics) -> Int) {
            lines.append(
                pad(label, 16)
                + pad("\(value(result.final))", 14)
                + pad(String(format: "%.2f", tail.mean(value)), 14)
            )
        }
        row("population") { $0.population }
        row("jobs") { $0.jobs }
        row("treasury") { $0.treasury }
        row("tax revenue") { $0.taxRevenue }
        row("upkeep") { $0.upkeepCost }
        row("civic upkeep") { $0.civicUpkeep }
        row("bond interest") { $0.bondInterest }
        row("net revenue") { $0.netRevenue }
        row("hazard strikes") { $0.hazardStrikes }

        lines.append("")
        lines.append("population  " + trajectoryLine(result) { $0.population })
        lines.append("treasury    " + trajectoryLine(result) { $0.treasury })
        lines.append("net revenue " + trajectoryLine(result) { $0.netRevenue })
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private static func trajectoryLine(
        _ result: RunResult,
        _ value: (TickMetrics) -> Int
    ) -> String {
        trajectory(result, value).map(String.init).joined(separator: " → ")
    }

    /// `samples` evenly spaced readings, so a 5,000-tick run is legible as
    /// one line of text.
    static func trajectory(
        _ result: RunResult,
        _ value: (TickMetrics) -> Int,
        samples: Int = 8
    ) -> [Int] {
        guard !result.ticks.isEmpty else { return [] }
        let step = Swift.max(1, result.ticks.count / samples)
        return stride(from: 0, to: result.ticks.count, by: step).map { value(result.ticks[$0]) }
    }
}
