import XCTest
@testable import AlphaPlusPlus

/// The tram: the mode that is not simply a pricier version of the one below.
///
/// Everything else in this module is a pure addition — build it, and trips
/// move off the street. A tram lays rails *in* the street, so the corridor it
/// relieves is also the corridor it narrows, and that is the only reason it is
/// a different decision rather than a different price.
@MainActor
final class TramTests: XCTestCase {

    /// A straight street with a stop at each end and blocks along it.
    private func corridor(length: Int = 30) -> CityMap {
        var map = CityMap(width: length, height: 8)
        for x in 0 ..< length { map[GridPosition(x: x, y: 3)].zone = .road }
        return map
    }

    private func stop(_ map: inout CityMap, at position: GridPosition,
                      mode: TransitRoute.Mode = .tram) -> GridPosition {
        map.placeBuilding(zone: mode.stationZone, origin: position)
        return position
    }

    // MARK: - The rails, in order

    /// **A path, not a set**, and the difference is what a vehicle needs.
    ///
    /// Written against the track `tramTracks` already reports rather than
    /// against a hand-drawn list of tiles: a second description of where the
    /// rails go would agree with itself forever, which is the failure this
    /// project keeps recording. The path has to be a walk over exactly those
    /// tiles, in order, with no jumps.
    func testTheTramPathWalksTheTrackItLaid() {
        var map = corridor()
        let a = stop(&map, at: GridPosition(x: 1, y: 2))
        let b = stop(&map, at: GridPosition(x: 28, y: 2))
        map.transit.add(mode: .tram, stops: [a, b])
        map.tramTracks = Transit.tramTracks(in: map)

        let route = map.transit.routes(mode: .tram)[0]
        let path = Transit.tramPath(of: route, in: map)

        XCTAssertFalse(path.isEmpty, "a connected line produced no path at all")
        XCTAssertEqual(Set(path), map.tramTracks,
                       "the path visits different tiles than the track it is on")
        for (from, to) in zip(path, path.dropFirst()) {
            XCTAssertEqual(abs(to.x - from.x) + abs(to.y - from.y), 1,
                           "the tram jumps from \(from) to \(to) rather than walking")
        }
    }

    /// A stop shared by two legs is one tile on the path, not two — otherwise
    /// a tram stutters on the spot at every station in the middle of a line.
    func testAStopBetweenTwoLegsIsVisitedOnce() {
        var map = corridor()
        let a = stop(&map, at: GridPosition(x: 1, y: 2))
        let b = stop(&map, at: GridPosition(x: 14, y: 2))
        let c = stop(&map, at: GridPosition(x: 28, y: 2))
        map.transit.add(mode: .tram, stops: [a, b, c])

        let path = Transit.tramPath(of: map.transit.routes(mode: .tram)[0], in: map)
        XCTAssertEqual(path.count, Set(path).count, "the path doubles back over itself")
    }

    /// **No jump at a station with road on both sides.** Stops built on the
    /// line itself — the way a player lays them along a street — used to
    /// leave a two- or three-tile gap where one leg ended and the next began,
    /// and the tram jumped diagonally across the station. Found by review of
    /// the Metal renderer, which draws the tram on this path.
    func testATramWalksThroughAStopBuiltOnTheLine() {
        var map = corridor()
        let a = stop(&map, at: GridPosition(x: 2, y: 3))
        let b = stop(&map, at: GridPosition(x: 14, y: 3))
        let c = stop(&map, at: GridPosition(x: 27, y: 3))
        map.transit.add(mode: .tram, stops: [a, b, c])
        let path = Transit.tramPath(of: map.transit.routes(mode: .tram)[0], in: map)
        XCTAssertFalse(path.isEmpty)
        for (from, to) in zip(path, path.dropFirst()) {
            XCTAssertEqual(abs(to.x - from.x) + abs(to.y - from.y), 1,
                           "the tram jumps from \(from) to \(to) at a station")
        }
    }

    /// **A severed line has no path**, and that is the honest answer rather
    /// than a straight line across the gap. Drawing a tram gliding over
    /// missing street would claim a connection the simulation does not have —
    /// the same distinction the conduit overlay draws between a pipe that
    /// exists and a pipe that is live.
    func testALineWithNoStreetBetweenItsStopsHasNoPath() {
        var map = corridor()
        let a = stop(&map, at: GridPosition(x: 1, y: 2))
        let b = stop(&map, at: GridPosition(x: 28, y: 2))
        map.transit.add(mode: .tram, stops: [a, b])
        // Cut the one street that joins them.
        map[GridPosition(x: 15, y: 3)].zone = .empty

        XCTAssertTrue(Transit.tramPath(of: map.transit.routes(mode: .tram)[0], in: map).isEmpty)
    }

    /// Only the tram has one. Every other route in this game is a schematic
    /// between stations, so there is no path to report — asserted rather than
    /// assumed, because a mode quietly gaining one would put a bus on streets
    /// the simulation never routed it down.
    func testNoOtherModeHasAPath() {
        for mode in TransitRoute.Mode.allCases where mode != .tram {
            var map = corridor()
            let a = stop(&map, at: GridPosition(x: 1, y: 2), mode: mode)
            let b = stop(&map, at: GridPosition(x: 28, y: 2), mode: mode)
            map.transit.add(mode: mode, stops: [a, b])
            XCTAssertTrue(
                Transit.tramPath(of: map.transit.routes(mode: mode)[0], in: map).isEmpty,
                "\(mode) reported a street path it does not have"
            )
        }
    }

    // MARK: - A tram takes a lane

    /// **The mechanic.** The street a tram runs down carries less traffic than
    /// it did, because a quarter of it is now rails.
    func testAStreetWithRailsInItCarriesLessTraffic() {
        var bare = corridor()
        bare.trafficLoad = .loaded(20, everyRoadIn: bare)
        let before = Traffic.congestion(at: GridPosition(x: 15, y: 3), in: bare)

        var railed = bare
        let a = stop(&railed, at: GridPosition(x: 1, y: 2))
        let b = stop(&railed, at: GridPosition(x: 28, y: 2))
        railed.transit.add(mode: .tram, stops: [a, b])
        railed.tramTracks = Transit.tramTracks(in: railed)

        let after = Traffic.congestion(at: GridPosition(x: 15, y: 3), in: railed)
        XCTAssertGreaterThan(after, before, "rails in the street cost it nothing")
        XCTAssertEqual(after / before, 1 / (1 - Traffic.tramLaneShare), accuracy: 0.02)
    }

    /// And only the streets it actually runs down — the cost is local to the
    /// corridor, which is what makes *where* a tram goes a decision.
    func testOnlyTheCorridorPays() {
        var map = corridor()
        // A second street the line has no reason to use.
        for x in 0 ..< 30 { map[GridPosition(x: x, y: 6)].zone = .road }
        let a = stop(&map, at: GridPosition(x: 1, y: 2))
        let b = stop(&map, at: GridPosition(x: 28, y: 2))
        map.transit.add(mode: .tram, stops: [a, b])
        map.tramTracks = Transit.tramTracks(in: map)

        XCTAssertTrue(map.tramTracks.contains(GridPosition(x: 15, y: 3)))
        XCTAssertFalse(map.tramTracks.contains(GridPosition(x: 15, y: 6)),
                       "the rails were laid down a street the line never uses")
    }

    /// The track is *derived*, not authored: the player clicks stations and
    /// the shortest road run between them is where the rails go. That is what
    /// keeps "the route is the infrastructure" true for a mode that genuinely
    /// occupies ground.
    func testTheTrackFollowsTheStreetsBetweenTheStops() {
        var map = corridor()
        let a = stop(&map, at: GridPosition(x: 1, y: 2))
        let b = stop(&map, at: GridPosition(x: 10, y: 2))
        map.transit.add(mode: .tram, stops: [a, b])
        let tracks = Transit.tramTracks(in: map)

        for x in 1 ... 10 {
            XCTAssertTrue(tracks.contains(GridPosition(x: x, y: 3)), "no rails at x=\(x)")
        }
        XCTAssertFalse(tracks.contains(GridPosition(x: 20, y: 3)),
                       "the rails ran past the end of the line")
    }

    /// Stops with no street between them lay no rails and take no lane. The
    /// line still runs — a tram route is not gated on road connectivity, the
    /// same way a bus route is not.
    func testStopsWithNoStreetBetweenThemTakeNoLane() {
        var map = CityMap(width: 30, height: 8)
        // Two disconnected stubs of road, one under each stop.
        for x in 0 ... 2 { map[GridPosition(x: x, y: 3)].zone = .road }
        for x in 26 ... 28 { map[GridPosition(x: x, y: 3)].zone = .road }
        let a = stop(&map, at: GridPosition(x: 1, y: 2))
        let b = stop(&map, at: GridPosition(x: 27, y: 2))
        let id = map.transit.add(mode: .tram, stops: [a, b])

        XCTAssertTrue(Transit.tramTracks(in: map).isEmpty)
        XCTAssertTrue(Transit.isRunning(try! XCTUnwrap(map.transit.route(id: id)), in: map),
                      "the line stopped running because the streets do not connect its stops")
    }

    func testOnlyATramLaysRails() {
        for mode in TransitRoute.Mode.allCases where mode != .tram {
            var map = corridor()
            let a = stop(&map, at: GridPosition(x: 1, y: 2), mode: mode)
            let b = stop(&map, at: GridPosition(x: 28, y: 2), mode: mode)
            map.transit.add(mode: mode, stops: [a, b])
            XCTAssertTrue(Transit.tramTracks(in: map).isEmpty, "\(mode) laid rails")
        }
    }

    /// The rails follow the map, not just the route: bulldoze the street and
    /// the lane comes back.
    func testBulldozingTheStreetTakesTheRailsWithIt() {
        var map = corridor()
        let a = stop(&map, at: GridPosition(x: 1, y: 2))
        let b = stop(&map, at: GridPosition(x: 28, y: 2))
        map.transit.add(mode: .tram, stops: [a, b])
        let controller = GameController(map: map, rng: AlwaysZeroRNG(),
                                        peakPopulation: Unlocks.everythingUnlocked)
        controller.recomputeTramTracks()
        XCTAssertFalse(controller.map.tramTracks.isEmpty)

        for x in 10 ... 20 { controller.bulldoze(at: GridPosition(x: x, y: 3)) }
        XCTAssertTrue(controller.map.tramTracks.isEmpty,
                      "the rails survived the street being torn up")
    }

    // MARK: - A tram is barely slowed by the traffic

    /// **The three-way split the modes exist for.** A bus is stuck in the
    /// traffic it is trying to relieve; a tram has its own rails down the
    /// middle and loses a little at junctions; a subway is in a tunnel.
    func testTrafficSlowsABusHardATramALittleAndASubwayNotAtAll() {
        var kept: [TransitRoute.Mode: Double] = [:]
        for mode in TransitRoute.Mode.allCases {
            var map = corridor()
            let a = stop(&map, at: GridPosition(x: 1, y: 2), mode: mode)
            let b = stop(&map, at: GridPosition(x: 28, y: 2), mode: mode)
            let id = map.transit.add(mode: mode, stops: [a, b])
            let route = try! XCTUnwrap(map.transit.route(id: id))
            let clear = Transit.dailyCapacity(of: route, in: map)

            map.trafficLoad = .jammed(everyRoadIn: map)
            kept[mode] = Double(Transit.dailyCapacity(of: route, in: map)) / Double(clear)
        }
        XCTAssertLessThan(kept[.bus]!, kept[.tram]!, "a tram is as stuck as a bus")
        XCTAssertLessThan(kept[.tram]!, kept[.subway]!, "a tram is as untouchable as a subway")
        XCTAssertEqual(kept[.subway]!, 1, accuracy: 0.001)
    }

    // MARK: - Where it sits on every other axis

    /// It is the middle rung on everything except the lane it takes, which is
    /// the one thing that makes it a different decision rather than a
    /// different price.
    func testATramSitsBetweenABusAndASubwayOnEveryScale() {
        let bus = TransitRoute.Mode.bus
        let tram = TransitRoute.Mode.tram
        let subway = TransitRoute.Mode.subway

        for (name, value) in [
            ("catchment", { (m: TransitRoute.Mode) in Double(Transit.catchment(for: m)) }),
            ("capacity", { Double($0.capacityPerStop) }),
            ("upkeep", { $0.upkeepPerStop }),
            ("station cost", { Double($0.stationZone.placementCost) }),
            ("unlock", { Double(Unlocks.requiredPopulation(for: $0.stationZone)) }),
        ] as [(String, (TransitRoute.Mode) -> Double)] {
            XCTAssertLessThan(value(bus), value(tram), "\(name): a tram is no dearer than a bus")
            XCTAssertLessThan(value(tram), value(subway), "\(name): a tram matches a subway")
        }
        // Faster than a bus, slower than a subway — the ride is what it buys.
        XCTAssertLessThan(tram.minutesPerTile, bus.minutesPerTile)
        XCTAssertGreaterThan(tram.minutesPerTile, subway.minutesPerTile)
    }

    func testTheTramToolsAreOffered() throws {
        let entries = ToolCategory.allEntries
        XCTAssertTrue(entries.contains { $0.zone == .tramStop }, "no way to place a tram stop")
        let route = try XCTUnwrap(entries.first { $0.overlay == .tram })
        XCTAssertEqual(route.unlockedBy, .tramStop)
    }
}
