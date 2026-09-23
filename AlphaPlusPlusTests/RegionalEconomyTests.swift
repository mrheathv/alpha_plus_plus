import XCTest
@testable import AlphaPlusPlus

/// The region's boom-and-bust cycle — phase 5 of making this a city you
/// manage, and the first input to `Demand` that does not come from the city
/// itself.
@MainActor
final class RegionalEconomyTests: XCTestCase {

    private let sectors: [ZoneType] = [.residential, .commercial, .industrial]

    private func makeController() -> GameController {
        GameController(
            map: CityMap(width: MapSize.small.dimension, height: MapSize.small.dimension),
            rng: AlwaysZeroRNG(),
            peakPopulation: Unlocks.everythingUnlocked
        )
    }

    private func trace(_ zone: ZoneType, ticks: Int) -> [Double] {
        (0 ..< ticks).map { RegionalEconomy(elapsed: $0).strength(for: zone) }
    }

    // MARK: - Shape

    func testTheCycleStaysInsideItsAmplitude() {
        for zone in sectors {
            for value in trace(zone, ticks: 2_000) {
                XCTAssertLessThanOrEqual(abs(value), RegionalEconomy.amplitude + 1e-9,
                                         "\(zone.rawValue) left its stated range")
            }
        }
    }

    /// A cycle that never reaches its extremes is a smaller cycle wearing a
    /// bigger number, which would make `amplitude` a lie and any balance
    /// reasoning built on it wrong. Two sines summed and normalised only hit
    /// ±1 when both peak together, so this checks the normalisation actually
    /// lets that happen within a reasonable span.
    func testTheCycleReachesMostOfItsRangeBothWays() {
        for zone in sectors {
            let values = trace(zone, ticks: 2_000)
            XCTAssertGreaterThan(values.max() ?? 0, RegionalEconomy.amplitude * 0.9,
                                 "\(zone.rawValue) never really booms")
            XCTAssertLessThan(values.min() ?? 0, -RegionalEconomy.amplitude * 0.9,
                              "\(zone.rawValue) never really slumps")
        }
    }

    /// It has to move slowly enough to be a trend rather than noise: a player
    /// steers against weather, not against a coin flip.
    func testTheCycleMovesSlowly() {
        for zone in sectors {
            let values = trace(zone, ticks: 600)
            let biggestStep = zip(values, values.dropFirst()).map { abs($1 - $0) }.max() ?? 0
            // 6% of the range per tick, which is what the two periods actually
            // produce at their steepest (about 0.014 of 0.25) — so crossing
            // from a peak to a trough takes tens of ticks no matter where you
            // start. The first bound here was 5%, picked without doing that
            // arithmetic, and it failed by a hair against correct code.
            XCTAssertLessThan(biggestStep, RegionalEconomy.amplitude * 0.06,
                              "\(zone.rawValue) jumps rather than drifts")
        }
    }

    /// **The decoupling is the mechanic.** If all three sectors rose and fell
    /// together the region would be one volume knob and a slump would have no
    /// answer but to wait. Apart, a city can be short of jobs while housing is
    /// oversupplied — which the player answers by re-zoning.
    func testTheSectorsDoNotMoveTogether() {
        let traces = sectors.map { trace($0, ticks: 1_200) }
        for (a, b) in [(0, 1), (0, 2), (1, 2)] {
            let x = traces[a], y = traces[b]
            let meanX = x.reduce(0, +) / Double(x.count)
            let meanY = y.reduce(0, +) / Double(y.count)
            let covariance = zip(x, y).reduce(0.0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
            let sdX = x.reduce(0.0) { $0 + ($1 - meanX) * ($1 - meanX) }.squareRoot()
            let sdY = y.reduce(0.0) { $0 + ($1 - meanY) * ($1 - meanY) }.squareRoot()
            let correlation = covariance / (sdX * sdY)
            XCTAssertLessThan(abs(correlation), 0.5,
                              "\(self.sectors[a].rawValue) and \(self.sectors[b].rawValue) "
                              + "move in lockstep — the region is one dial, not three")
        }
    }

    /// Deliberately not a sine wave: one period is a metronome a player learns
    /// the half-life of, at which point the mechanic is a countdown rather
    /// than a climate. Two co-prime periods beat, so consecutive peaks differ.
    func testConsecutiveBoomsAreNotIdentical() {
        let values = trace(.residential, ticks: 1_200)
        var peaks: [Double] = []
        for index in 1 ..< values.count - 1
        where values[index] > values[index - 1] && values[index] >= values[index + 1] {
            peaks.append(values[index])
        }
        XCTAssertGreaterThan(peaks.count, 3, "not enough peaks to compare")
        let spread = (peaks.max() ?? 0) - (peaks.min() ?? 0)
        XCTAssertGreaterThan(spread, RegionalEconomy.amplitude * 0.15,
                             "every boom is the same height — this is a metronome")
    }

    /// Steady has to be the common case, or the two named states stop meaning
    /// anything, and both have to actually occur.
    func testAllThreeMoodsHappenAndSteadyIsTheCommonOne() {
        // A dozen-odd full cycles, not a handful. `longestCycle` is 421 ticks,
        // so a 2,000-tick sample covers fewer than five of them and the
        // fractions it reports swing with which phases happened to land inside
        // it — the first version of this test failed on a 2.5% wobble that
        // said nothing about the mechanic.
        let horizon = RegionalEconomy.longestCycle * 15
        var counts: [RegionalEconomy.Mood: Int] = [:]
        for tick in 0 ..< horizon {
            counts[RegionalEconomy(elapsed: tick).mood, default: 0] += 1
        }
        func share(_ mood: RegionalEconomy.Mood) -> Double {
            Double(counts[mood] ?? 0) / Double(horizon)
        }
        XCTAssertGreaterThan(share(.steady), 0.5,
                             "the region is dramatic more often than it is calm")
        // And the other way: a named mood nobody ever meets is not a mechanic.
        for mood in [RegionalEconomy.Mood.boom, .slump] {
            XCTAssertGreaterThan(share(mood), 0.08,
                                 "\(mood.label) is too rare to be part of playing")
        }
        print(String(format: "\nregional moods over %d ticks: boom %.0f%%, steady %.0f%%, slump %.0f%%",
                     horizon, share(.boom) * 100, share(.steady) * 100, share(.slump) * 100))
    }

    /// The region has no opinion about how many police stations you want —
    /// the same "always has an answer, never an optional" contract
    /// `CityDemand.value(for:)` keeps.
    func testNonGrowableZonesFeelNothing() {
        for zone in [ZoneType.road, .policeStation, .waterTower, .empty] {
            XCTAssertEqual(RegionalEconomy(elapsed: 137).strength(for: zone), 0)
        }
    }

    // MARK: - Wiring

    func testDemandMovesWithTheRegion() {
        var map = CityMap(width: 8, height: 8)
        func demand(at tick: Int) -> CityDemand {
            map.regionalEconomy = RegionalEconomy(elapsed: tick)
            return Demand.compute(for: map)
        }
        // An empty city is perfectly balanced, so whatever moves here is the
        // region and nothing else.
        let neutral = demand(at: 0)
        let residentialTrace = (0 ..< 400).map { demand(at: $0).residential }
        XCTAssertGreaterThan((residentialTrace.max() ?? 0) - (residentialTrace.min() ?? 0),
                             RegionalEconomy.amplitude,
                             "demand did not respond to the regional cycle at all")
        XCTAssertEqual(neutral.residential,
                       RegionalEconomy(elapsed: 0).strength(for: .residential),
                       accuracy: 1e-9)
    }

    /// Demand is clamped to ±1, and the region is added *inside* that clamp
    /// rather than applied to the result — otherwise a boom on top of an
    /// already-maxed demand would smuggle the value past the range every other
    /// piece of the simulation assumes.
    func testTheRegionCannotPushDemandPastItsRange() {
        var map = CityMap(width: 12, height: 12)
        // A city of nothing but housing: demand for housing pins at the floor.
        map[GridPosition(x: 2, y: 0)].zone = .road
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        for cell in map.footprintCells(origin: GridPosition(x: 0, y: 0), size: 2) {
            map[cell].density = 5
        }
        for tick in 0 ..< 400 {
            map.regionalEconomy = RegionalEconomy(elapsed: tick)
            let demand = Demand.compute(for: map)
            XCTAssertLessThanOrEqual(abs(demand.residential), 1)
            XCTAssertLessThanOrEqual(abs(demand.commercial), 1)
            XCTAssertLessThanOrEqual(abs(demand.industrial), 1)
        }
    }

    /// The clock has to actually advance, and it has to advance on the map the
    /// controller owns — a cycle nobody ticks is a constant.
    func testTicking() {
        let controller = makeController()
        XCTAssertEqual(controller.map.regionalEconomy.elapsed, 0)
        for _ in 0 ..< 5 { controller.advanceSimulation() }
        XCTAssertEqual(controller.map.regionalEconomy.elapsed, 5)
    }

    /// And it has to survive a save, or a reloaded city silently restarts its
    /// economic history at tick zero.
    func testTheCycleSurvivesARoundTrip() throws {
        let controller = makeController()
        for _ in 0 ..< 40 { controller.advanceSimulation() }

        let data = try JSONEncoder().encode(controller.snapshot())
        let decoded = try JSONDecoder().decode(CitySave.self, from: data)
        let restored = makeController()
        try restored.restore(from: decoded)

        XCTAssertEqual(restored.map.regionalEconomy, controller.map.regionalEconomy)
        XCTAssertEqual(restored.map.regionalEconomy.elapsed, 40)
    }
}
