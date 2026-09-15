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
    enum Profile {
        /// Small and short: a regression guard that runs with the suite.
        case quick
        /// Full-size and long: what a real balance measurement uses.
        case full

        static var current: Profile {
            ProcessInfo.processInfo.environment["PLAYTEST_FULL"] != nil ? .full : .quick
        }

        var size: Int {
            switch self {
            case .quick: return 16
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
            case .quick: return 120
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
        serviceSpacing: Int = 6
    ) -> CitySpec {
        CitySpec(
            size: Profile.current.size,
            includeUtilities: includeUtilities,
            includeServices: includeServices,
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
    }

    /// Lays out a city according to `spec`.
    ///
    /// The zone mix is 2 residential : 1 commercial : 1 industrial, which
    /// roughly matches what `Demand` considers balanced — a city built all of
    /// one type would stall on demand rather than on anything the caller is
    /// trying to measure.
    static func buildCity(_ spec: CitySpec) -> CityMap {
        var map = CityMap(width: spec.size, height: spec.size)

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

        var lotIndex = 0
        for y in stride(from: 1, to: spec.includeServices ? plantStripTop : spec.size - 1, by: spec.roadSpacing) {
            for x in stride(from: 0, to: spec.size - 1, by: 2) {
                let origin = GridPosition(x: x, y: y)
                guard map[origin].zone == .empty else { continue }

                let zone = placement(for: lotIndex, at: origin, spec: spec)
                lotIndex += 1

                guard map.footprintCells(origin: origin, size: zone.footprintSize).count
                        == zone.footprintSize * zone.footprintSize else { continue }
                guard map.footprintCells(origin: origin, size: zone.footprintSize)
                        .allSatisfy({ map[$0].zone == .empty }) else { continue }

                map.placeBuilding(zone: zone, origin: origin)
            }
        }

        return map
    }

    /// Which zone lot number `index` gets: a service building at every
    /// `serviceSpacing`-th lot when services are enabled, otherwise the next
    /// entry in `spec.zoneMix`.
    private static func placement(for index: Int, at origin: GridPosition, spec: CitySpec) -> ZoneType {
        if spec.includeServices, index % spec.serviceSpacing == 0 {
            // Rotate through the services so coverage is mixed rather than
            // every station being the same kind.
            // No `.powerPlant` here: it is 3×3 and the lot rows are two tiles
            // deep, so it never fit and was silently skipped every single
            // time — every generated city ran with *zero* power plants, which
            // capped everything at density 3 (`powerRequiredFromLevel`) and
            // went unnoticed until utility capacity started reporting a
            // capacity of 0. Plants now get their own reserved strip in
            // `buildCity`.
            let services: [ZoneType] = [.policeStation, .fireStation, .publicTransit, .waterTower]
            return services[(index / spec.serviceSpacing) % services.count]
        }
        guard spec.segregateIndustry else {
            return spec.zoneMix[index % spec.zoneMix.count]
        }

        // Same *composition* as `zoneMix`, different *arrangement* — which is
        // the only way this comparison measures planning rather than zone
        // ratios. The default mix is 2 residential : 1 commercial : 1
        // industrial, so industry takes the lowest quarter of the lot rows and
        // the rest cycle 2:1 above it. An earlier version banished industry to
        // the bottom fifth and rebalanced everything else, which changed the
        // ratio as well as the layout and so compared two different cities.
        let rows = Int((Double(spec.size - 2) / Double(spec.roadSpacing)).rounded(.up))
        let industrialRows = max(1, rows / 4)
        if origin.y < 1 + industrialRows * spec.roadSpacing {
            return .industrial
        }
        return index % 3 == 2 ? .commercial : .residential
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
