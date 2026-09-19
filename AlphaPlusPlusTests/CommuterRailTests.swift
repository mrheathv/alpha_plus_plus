import XCTest
@testable import AlphaPlusPlus

/// Commuter rail: the mode that points off the map.
///
/// Every other kind of line moves people *within* the city. This one connects
/// it to the region — the first channel `RegionalEconomy` has ever had into a
/// city other than demand — and what that buys is somewhere for residents to
/// work that the simulation does not have to build.
@MainActor
final class CommuterRailTests: XCTestCase {

    private let size = 40

    /// A street across the middle and housing on it. Deliberately with *no*
    /// commercial or industrial anywhere, so that any employment measured
    /// here can only have come from outside.
    private func bedroomCity() -> CityMap {
        var map = CityMap(width: size, height: 12)
        for x in 0 ..< size { map[GridPosition(x: x, y: 5)].zone = .road }
        for x in stride(from: 4, to: 20, by: 2) {
            let home = GridPosition(x: x, y: 6)
            map.placeBuilding(zone: .residential, origin: home)
            for cell in map.footprintCells(origin: home, size: 2) { map[cell].density = 3 }
        }
        return map
    }

    @discardableResult
    private func station(_ map: inout CityMap, at origin: GridPosition,
                         mode: TransitRoute.Mode = .rail) -> GridPosition {
        map.placeBuilding(zone: mode.stationZone, origin: origin)
        return origin
    }

    // MARK: - What makes a line regional

    /// **Run your line to the edge of the city and it carries on into the
    /// region.** No new building, no separate switch — the geometry is the
    /// rule, which is what makes it discoverable.
    func testALineReachingTheEdgeConnectsToTheRegionAndOneStoppingShortDoesNot() {
        var connected = bedroomCity()
        let inner = station(&connected, at: GridPosition(x: 10, y: 2))
        let edge = station(&connected, at: GridPosition(x: size - 2, y: 2))
        connected.transit.add(mode: .rail, stops: [inner, edge])

        var short = bedroomCity()
        let a = station(&short, at: GridPosition(x: 10, y: 2))
        let b = station(&short, at: GridPosition(x: 20, y: 2))
        short.transit.add(mode: .rail, stops: [a, b])

        XCTAssertGreaterThan(Transit.outsideJobs(in: connected), 0)
        XCTAssertEqual(Transit.outsideJobs(in: short), 0,
                       "a line that never leaves the map found work outside it")
        // And every stop on a regional line is a way out — you board where
        // you live and stay on.
        XCTAssertEqual(Transit.regionalTermini(in: connected).count, 2)
    }

    func testOnlyRailLeavesTheCity() {
        for mode in TransitRoute.Mode.allCases where mode != .rail {
            var map = bedroomCity()
            let inner = station(&map, at: GridPosition(x: 10, y: 2), mode: mode)
            let edge = station(&map, at: GridPosition(x: size - 2, y: 2), mode: mode)
            map.transit.add(mode: mode, stops: [inner, edge])
            XCTAssertEqual(Transit.outsideJobs(in: map), 0, "\(mode) ran off the map")
        }
    }

    /// **Bounded by what the trains can carry.** A regional connection is not
    /// a switch that turns outside work on, it is a pipe of a particular
    /// size — which is the whole reason the capacity mechanic was worth
    /// having.
    func testOutsideWorkIsBoundedByWhatTheTrainsCarry() {
        var two = bedroomCity()
        let inner = station(&two, at: GridPosition(x: 10, y: 2))
        let edge = station(&two, at: GridPosition(x: size - 2, y: 2))
        let id = two.transit.add(mode: .rail, stops: [inner, edge])
        two.regionalEconomy = .calm

        var three = two
        let extra = station(&three, at: GridPosition(x: 20, y: 2))
        three.transit.setStops([inner, extra, edge], forRoute: id)

        XCTAssertEqual(Transit.outsideJobs(in: two), 2 * TransitRoute.Mode.rail.capacityPerStop)
        XCTAssertEqual(Transit.outsideJobs(in: three), 3 * TransitRoute.Mode.rail.capacityPerStop,
                       "another stop did not widen the pipe")
    }

    /// And by how the region itself is doing, which is the first time
    /// `RegionalEconomy` has reached a city through anything but demand. A
    /// rail-connected city is therefore *more* exposed to the cycle than one
    /// that is not — which is what connecting to the outside world means.
    func testASlumpOutThereCostsWorkInHere() {
        var map = bedroomCity()
        let inner = station(&map, at: GridPosition(x: 10, y: 2))
        let edge = station(&map, at: GridPosition(x: size - 2, y: 2))
        map.transit.add(mode: .rail, stops: [inner, edge])

        var readings: [Int] = []
        var region = RegionalEconomy()
        for _ in 0 ..< RegionalEconomy.longestCycle {
            map.regionalEconomy = region
            readings.append(Transit.outsideJobs(in: map))
            region = region.advanced()
        }
        XCTAssertGreaterThan(try! XCTUnwrap(readings.max()), try! XCTUnwrap(readings.min()),
                             "the region's own fortunes made no difference to the work it offers")
    }

    // MARK: - What it does to the city

    /// **The point.** A city with no jobs of its own and a train to the
    /// region is a bedroom community: its residents are employed, and nothing
    /// about that came from a building the player placed.
    func testResidentsWithATrainCanWorkOutsideACityThatHasNoJobs() {
        let home = GridPosition(x: 4, y: 6)

        var stranded = bedroomCity()
        XCTAssertEqual(Traffic.computeLoad(for: stranded).commuteFound(at: home), false,
                       "precondition: somebody found work in a city with no jobs in it")
        _ = stranded

        var connected = bedroomCity()
        let inner = station(&connected, at: GridPosition(x: 6, y: 2))
        let edge = station(&connected, at: GridPosition(x: size - 2, y: 2))
        let line = connected.transit.add(mode: .rail, stops: [inner, edge])

        let load = Traffic.computeLoad(for: connected)
        XCTAssertEqual(load.commuteFound(at: home), true, "the train found nobody any work")
        XCTAssertGreaterThan(try! XCTUnwrap(load.ridership(onRoute: line)), 0)
    }

    /// You cannot drive out of the city. There are no off-map roads, and the
    /// train being the only way out is what gives the connection its point.
    func testTheOnlyWayOutIsTheTrain() {
        var map = bedroomCity()
        let inner = station(&map, at: GridPosition(x: 6, y: 2))
        let edge = station(&map, at: GridPosition(x: size - 2, y: 2))
        map.transit.add(mode: .rail, stops: [inner, edge])

        let load = Traffic.computeLoad(for: map)
        // Nobody drove anywhere, because the only destination is off the map
        // and no road reaches it.
        XCTAssertEqual(load.load(at: GridPosition(x: 25, y: 5)), 0,
                       "somebody drove to a job outside the city")
    }

    /// **The bedroom-community trade, stated in one measurement.** Outside
    /// work raises residential demand, because there is a reason to move
    /// here; and lowers commercial and industrial demand, because those
    /// residents are not available to fill a local job.
    func testARegionalConnectionBuysHousingDemandAndCostsLocalBusinessDemand() {
        var map = bedroomCity()
        map.regionalEconomy = .calm
        let before = Demand.compute(for: map)

        let inner = station(&map, at: GridPosition(x: 6, y: 2))
        let edge = station(&map, at: GridPosition(x: size - 2, y: 2))
        map.transit.add(mode: .rail, stops: [inner, edge])
        let after = Demand.compute(for: map)

        XCTAssertGreaterThan(after.residential, before.residential,
                             "a train to the region gave nobody a reason to move here")
        XCTAssertLessThan(after.commercial, before.commercial,
                          "residents working outside still counted as needing local jobs")
        XCTAssertLessThan(after.industrial, before.industrial)
    }

    // MARK: - Where it sits

    /// The fastest and the least frequent, which is what makes it a mode for
    /// a journey no other is worth making rather than simply a better subway.
    func testRailIsTheFastestRideAndTheLongestWait() {
        for other in TransitRoute.Mode.allCases where other != .rail {
            XCTAssertLessThan(TransitRoute.Mode.rail.minutesPerTile, other.minutesPerTile)
            XCTAssertGreaterThan(TransitRoute.Mode.rail.boardingWaitMinutes, other.boardingWaitMinutes)
        }
    }

    /// So a subway beats it across town and it beats a subway across the
    /// region — the crossover is what the long wait buys.
    func testASubwayWinsAShortTripAndTheTrainWinsALongOne() {
        func minutes(_ mode: TransitRoute.Mode, tiles: Int) -> Double {
            mode.boardingWaitMinutes + Double(tiles) * mode.minutesPerTile
        }
        XCTAssertLessThan(minutes(.subway, tiles: 20), minutes(.rail, tiles: 20))
        XCTAssertLessThan(minutes(.rail, tiles: 60), minutes(.subway, tiles: 60))
    }

    func testTheRailToolsAreOfferedAndEarnedLast() throws {
        let entries = ToolCategory.allEntries
        XCTAssertTrue(entries.contains { $0.zone == .railStation })
        XCTAssertEqual(try XCTUnwrap(entries.first { $0.overlay == .rail }).unlockedBy, .railStation)

        let last = ZoneType.allCases.max { Unlocks.requiredPopulation(for: $0) < Unlocks.requiredPopulation(for: $1) }
        XCTAssertEqual(last, .railStation, "a regional connection is no longer the last thing earned")
    }
}
