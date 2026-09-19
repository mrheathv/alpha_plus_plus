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
    private func spec(
        _ mode: TransitRoute.Mode?, routes: Bool, segregated: Bool = false, limit: Int? = nil
    ) -> PlaytestHarness.CitySpec {
        var spec = PlaytestHarness.spec()
        spec.transitStations = mode
        spec.drawTransitRoutes = routes
        spec.segregateIndustry = segregated
        spec.routeLimit = limit
        return spec
    }

    private struct Outcome {
        let population: Int
        let treasury: Int
        let netRevenue: Int
        let congestion: Double
        let ridership: Int
        let lines: Int
        let outsideJobs: Int

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

    private func measure(
        _ mode: TransitRoute.Mode?, routes: Bool = true, segregated: Bool = false,
        limit: Int? = nil
    ) -> Outcome {
        let (controller, result) = PlaytestHarness.runScenario(
            spec(mode, routes: routes, segregated: segregated, limit: limit), ticks: ticks
        )
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
            outsideJobs: Transit.outsideJobs(in: map),
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
        let trams = measure(.tram)
        let trains = measure(.subway)

        print("""

        === What transit is worth (\(size)×\(size), \(ticks) days) ===
        | network  | lines | pop  | congestion | riders/day | busiest | net/day | treasury |
        |----------|-------|------|------------|------------|---------|---------|----------|
        | no stops | \(bare.lines) | \(bare.population) | \(String(format: "%.3f", bare.congestion)) | \(bare.ridership) | \(String(format: "%.0f%%", bare.busiestLoad * 100)) | \(bare.netRevenue) | \(bare.treasury) |
        | idle     | \(control.lines) | \(control.population) | \(String(format: "%.3f", control.congestion)) | \(control.ridership) | \(String(format: "%.0f%%", control.busiestLoad * 100)) | \(control.netRevenue) | \(control.treasury) |
        | bus      | \(buses.lines) | \(buses.population) | \(String(format: "%.3f", buses.congestion)) | \(buses.ridership) | \(String(format: "%.0f%%", buses.busiestLoad * 100)) | \(buses.netRevenue) | \(buses.treasury) |
        | tram     | \(trams.lines) | \(trams.population) | \(String(format: "%.3f", trams.congestion)) | \(trams.ridership) | \(String(format: "%.0f%%", trams.busiestLoad * 100)) | \(trams.netRevenue) | \(trams.treasury) |
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
        XCTAssertGreaterThan(trains.population, control.population,
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
        XCTAssertGreaterThan(buses.busiestLoad, 0.1,
                             "no bus line carries anything, so the ceiling is not a mechanic")
        XCTAssertLessThan(buses.busiestLoad, 1.5)
    }

    /// **Transit is worth what the commute is long.**
    ///
    /// The default generated city interleaves housing, shops and factories
    /// every other lot, so nearly every commute is three blocks and a bus's
    /// walk and wait swamp it — which is the correct answer and a poor test.
    /// `segregateIndustry` banishes the factories to one end, which is both
    /// the layout `DesignPlaytestTests` already proves is the *better* way to
    /// build a city and the one that generates journeys long enough for a
    /// line to be worth catching.
    func testTransitEarnsItsKeepWhereTheCommuteIsLong() {
        let control = measure(.bus, routes: false, segregated: true)
        let buses = measure(.bus, segregated: true)
        let trams = measure(.tram, segregated: true)
        let trains = measure(.subway, segregated: true)
        let rail = measure(.rail, segregated: true)

        print("""

        === Transit where the commute is long (\(size)×\(size), \(ticks) days) ===
        | network  | lines | pop  | congestion | riders/day | busiest | net/day |
        |----------|-------|------|------------|------------|---------|---------|
        | idle     | \(control.lines) | \(control.population) | \(String(format: "%.3f", control.congestion)) | \(control.ridership) | \(String(format: "%.0f%%", control.busiestLoad * 100)) | \(control.netRevenue) |
        | bus      | \(buses.lines) | \(buses.population) | \(String(format: "%.3f", buses.congestion)) | \(buses.ridership) | \(String(format: "%.0f%%", buses.busiestLoad * 100)) | \(buses.netRevenue) |
        | tram     | \(trams.lines) | \(trams.population) | \(String(format: "%.3f", trams.congestion)) | \(trams.ridership) | \(String(format: "%.0f%%", trams.busiestLoad * 100)) | \(trams.netRevenue) |
        | subway   | \(trains.lines) | \(trains.population) | \(String(format: "%.3f", trains.congestion)) | \(trains.ridership) | \(String(format: "%.0f%%", trains.busiestLoad * 100)) | \(trains.netRevenue) |
        | rail     | \(rail.lines) | \(rail.population) | \(String(format: "%.3f", rail.congestion)) | \(rail.ridership) | \(String(format: "%.0f%%", rail.busiestLoad * 100)) | \(rail.netRevenue) |

        """)
        // **A regional connection makes a city bigger than its own jobs.**
        // Outside work raises residential demand, so the city grows past what
        // it could employ itself — which is the bedroom-community strategy,
        // and the only thing in this game that does it.
        XCTAssertGreaterThan(rail.population, control.population,
                             "a connection to the region bought no population at all")

        XCTAssertGreaterThan(buses.ridership, 0)
        XCTAssertGreaterThan(trams.ridership, buses.ridership,
                             "a tram carried no more than a bus over the same stations")
        XCTAssertGreaterThan(trains.ridership, trams.ridership)

        // **The tram's own trade, measured.** It relieves the corridor and
        // narrows it at the same time — the only transit building in the game
        // that costs the road anything — so the question is whether what it
        // carries beats the quarter-lane it took. Asserted as the direction
        // rather than the size, because the size is what a player's placement
        // decides and this network was laid down without looking.
        XCTAssertLessThan(trams.congestion, control.congestion,
                          "a tram network left the streets no better than no lines at all, "
                          + "despite taking a lane from every corridor it runs down")
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

extension TransitBalanceTests {

    /// **What is *one* line worth?**
    ///
    /// Every other scenario here wires every station into a route, which
    /// measures what a network does and says nothing about the decision a
    /// player actually faces first. A regional line is the sharpest case: it
    /// is the one thing in the game that raises residential demand without a
    /// building to fill the jobs, so if a single one of them is transformative
    /// for pocket change then the lever is mis-sized.
    func testWhatASingleRegionalLineIsWorth() {
        let none = measure(.rail, routes: false, segregated: true)
        let one = measure(.rail, segregated: true, limit: 1)
        let everything = measure(.rail, segregated: true)

        print("""

        === One regional line against a whole network ===
        | lines | pop | outside jobs | riders/day | net/day |
        |-------|-----|--------------|------------|---------|
        | \(none.lines) | \(none.population) | \(none.outsideJobs) | \(none.ridership) | \(none.netRevenue) |
        | \(one.lines) | \(one.population) | \(one.outsideJobs) | \(one.ridership) | \(one.netRevenue) |
        | \(everything.lines) | \(everything.population) | \(everything.outsideJobs) | \(everything.ridership) | \(everything.netRevenue) |

        """)

        XCTAssertEqual(none.outsideJobs, 0)
        XCTAssertGreaterThan(one.outsideJobs, 0, "one line offered no outside work at all")
        XCTAssertLessThan(one.outsideJobs, everything.outsideJobs,
                          "one line was worth as much as the whole network")
    }
}
