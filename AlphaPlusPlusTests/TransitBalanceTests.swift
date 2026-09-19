import XCTest
@testable import AlphaPlusPlus

/// Is transit worth building? Measured, like every other balance claim here.
///
/// Run against a **control pair** — the same city, the same stations, the same
/// seed, differing only in whether the lines were drawn. A scenario that also
/// added the station buildings would be measuring the buildings, which are an
/// amenity and a road-access gate quite apart from anything they carry.
@MainActor
final class TransitBalanceTests: XCTestCase {

    private var ticks: Int { PlaytestHarness.Profile.current.ticks }
    private var size: Int { PlaytestHarness.Profile.current.size }

    /// Stations either way; `routes` is the only thing that differs.
    private func spec(_ mode: TransitRoute.Mode?, routes: Bool) -> PlaytestHarness.CitySpec {
        var spec = PlaytestHarness.spec()
        spec.transitStations = mode
        spec.drawTransitRoutes = routes
        return spec
    }

    private struct Outcome {
        let population: Int
        let treasury: Int
        let netRevenue: Int
        let congestion: Double
        let ridership: Int
        let lines: Int

        /// How full the *busiest* line is, not the average.
        ///
        /// The total says whether anybody rides; this says whether the
        /// ceiling is anywhere near being a real constraint. A mean over
        /// twenty arbitrary lines would hide one saturated route among
        /// nineteen empty ones — and a mechanic that never binds is the thing
        /// this project has already been caught shipping once, when demand
        /// drifted toward abandonment for fifteen hundred ticks and never
        /// arrived.
        let busiestLoad: Double
    }

    private func measure(_ mode: TransitRoute.Mode?, routes: Bool = true) -> Outcome {
        let (controller, result) = PlaytestHarness.runScenario(spec(mode, routes: routes), ticks: ticks)
        let map = controller.map
        let roads = map.tiles.filter { $0.zone == .road || $0.zone == .highway }
        let congestion = roads.isEmpty ? 0 : roads
            .map { Traffic.congestion(at: $0.position, in: map) }
            .reduce(0, +) / Double(roads.count)
        var busiest = 0.0
        for route in map.transit.routes {
            let seats = Transit.dailyCapacity(of: route, in: map)
            guard seats > 0, let riders = map.trafficLoad.ridership(onRoute: route.id) else { continue }
            busiest = Swift.max(busiest, Double(riders) / Double(seats))
        }
        return Outcome(
            population: controller.population,
            treasury: controller.treasury,
            netRevenue: Int(result.tail().mean(\.netRevenue)),
            congestion: congestion,
            ridership: map.trafficLoad.totalRidership ?? 0,
            lines: map.transit.routes.count,
            busiestLoad: busiest
        )
    }

    /// The headline: what drawing lines over stations you already own does to
    /// a city, on both axes a player cares about.
    func testWhatTransitIsWorth() {
        // Two controls, because a player asks two different questions.
        // "Should I build transit at all" compares against a city with no
        // stations; "should I draw lines over the stops I have" compares
        // against the stations standing idle, which is what they did before
        // this module existed.
        let bare = measure(nil, routes: false)
        let control = measure(.bus, routes: false)
        let buses = measure(.bus)
        let trains = measure(.subway)

        print("""

        === What transit is worth (\(size)×\(size), \(ticks) days) ===
        | network  | lines | pop  | congestion | riders/day | busiest | net/day | treasury |
        |----------|-------|------|------------|------------|---------|---------|----------|
        | no stops | \(bare.lines) | \(bare.population) | \(String(format: "%.3f", bare.congestion)) | \(bare.ridership) | \(String(format: "%.0f%%", bare.busiestLoad * 100)) | \(bare.netRevenue) | \(bare.treasury) |
        | idle     | \(control.lines) | \(control.population) | \(String(format: "%.3f", control.congestion)) | \(control.ridership) | \(String(format: "%.0f%%", control.busiestLoad * 100)) | \(control.netRevenue) | \(control.treasury) |
        | bus      | \(buses.lines) | \(buses.population) | \(String(format: "%.3f", buses.congestion)) | \(buses.ridership) | \(String(format: "%.0f%%", buses.busiestLoad * 100)) | \(buses.netRevenue) | \(buses.treasury) |
        | subway   | \(trains.lines) | \(trains.population) | \(String(format: "%.3f", trains.congestion)) | \(trains.ridership) | \(String(format: "%.0f%%", trains.busiestLoad * 100)) | \(trains.netRevenue) | \(trains.treasury) |

        """)
        XCTAssertEqual(bare.lines, 0)

        XCTAssertEqual(control.ridership, 0, "the control city carried riders with no lines drawn")
        XCTAssertGreaterThan(buses.ridership, 0, "a city full of bus lines carried nobody")
        XCTAssertGreaterThan(trains.ridership, 0)

        // **The point of the mechanic.** A line that does not take cars off
        // the road is a cost with no benefit, and the whole reason a player
        // draws one.
        XCTAssertLessThan(buses.congestion, control.congestion,
                          "drawing bus lines did not reduce congestion at all")
        XCTAssertLessThan(trains.congestion, control.congestion)

        // **Stops standing idle are pure cost.** They gate road access and
        // lift land value a little, and they were the *whole* of what transit
        // did before this module — so a network that does not beat them is a
        // network that has not earned its lines.
        XCTAssertGreaterThan(buses.population, control.population,
                             "drawing the lines bought nothing over leaving the stops idle")

        // **The ceiling has to be reachable.** A capacity nobody ever hits is
        // a mechanic that does not exist — this project has shipped one of
        // those before, when demand drifted toward abandonment for fifteen
        // hundred ticks and never arrived. The busiest bus line in a
        // generated city runs 73–83% full, which is where a ceiling should
        // sit: close enough to bind on a line drawn where people actually
        // travel, loose enough that an ordinary one is not capped.
        //
        // Halving `capacityPerStop` from the first guess changed the measured
        // outcome *not at all* — identical ridership to the digit — which is
        // how the first value was found to be far out of reach rather than
        // merely generous.
        XCTAssertGreaterThan(buses.busiestLoad, 0.4,
                             "no bus line comes close to its capacity, so the ceiling is not a mechanic")
        XCTAssertLessThan(buses.busiestLoad, 1.5)
        // And a subway over the same stations is *not* near its ceiling,
        // because it has four times the seats for the same ground. That is
        // the honest signal that a subway here is an over-build.
        XCTAssertLessThan(trains.busiestLoad, buses.busiestLoad)
    }

    /// **A subway carries more than a bus over the same stations.** Four times
    /// the capacity against four times the ground covered, so the difference
    /// a player actually buys is reach in one line and a tunnel of its own —
    /// not a better ratio.
    func testASubwayCarriesMoreThanABusOverTheSameStations() {
        let buses = measure(.bus)
        let trains = measure(.subway)
        XCTAssertGreaterThan(trains.ridership, buses.ridership)
    }

    /// And it costs more to run, or it would simply be the better bus.
    func testRunningLinesCostsMoneyAndASubwayCostsMore() {
        let stations = PlaytestHarness.buildCity(spec(.bus, routes: false))
        let bused = PlaytestHarness.buildCity(spec(.bus, routes: true))
        let underground = PlaytestHarness.buildCity(spec(.subway, routes: true))

        func upkeep(_ map: CityMap) -> Int {
            GameController(map: map, rng: AlwaysZeroRNG()).upkeepCost
        }
        XCTAssertGreaterThan(upkeep(bused), upkeep(stations),
                             "drawing a line over stations you already own is free")
        XCTAssertGreaterThan(upkeep(underground), upkeep(bused))
    }

    /// A line has a ceiling, and past it the extra trips drive. Without this
    /// one route would serve an unbounded city and there would never be a
    /// reason to build a second.
    func testALineTurnsPeopleAwayOnceItIsFull() {
        var map = CityMap(width: 40, height: 10)
        for x in 0 ..< 40 { map[GridPosition(x: x, y: 3)].zone = .road }
        let stops = [GridPosition(x: 1, y: 1), GridPosition(x: 34, y: 1)]
        for stop in stops { map.placeBuilding(zone: .publicTransit, origin: stop) }
        let route = map.transit.add(mode: .bus, stops: stops)

        // Far more people than two stops' worth of bus can carry.
        for x in stride(from: 0, to: 8, by: 2) {
            let home = GridPosition(x: x, y: 4)
            map.placeBuilding(zone: .residential, origin: home)
            for cell in map.footprintCells(origin: home, size: 2) { map[cell].density = 5 }
        }
        let shop = GridPosition(x: 34, y: 4)
        map.placeBuilding(zone: .commercial, origin: shop)
        for cell in map.footprintCells(origin: shop, size: 2) { map[cell].density = 5 }

        let load = Traffic.computeLoad(for: map)
        let seats = Transit.dailyCapacity(of: try! XCTUnwrap(map.transit.route(id: route)), in: map)
        let riders = try! XCTUnwrap(load.ridership(onRoute: route))

        XCTAssertGreaterThan(riders, 0)
        // Overshoot by at most one home's worth: a single building's commute
        // is never split across two modes.
        XCTAssertLessThanOrEqual(
            riders, seats + 5 * ZoneType.residential.populationPerDensityLevel,
            "the line carried everyone regardless of capacity"
        )
        XCTAssertGreaterThan(load.load(at: GridPosition(x: 20, y: 3)), 0,
                             "nobody drove, so the full line turned nobody away")
    }
}
