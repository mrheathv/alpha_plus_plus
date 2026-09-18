import XCTest
@testable import AlphaPlusPlus

/// Phase 1 of the transportation module: what a route is, what it covers, and
/// what happens to a commute that can ride one.
@MainActor
final class TransitTests: XCTestCase {

    // MARK: - Fixtures

    private let home = GridPosition(x: 0, y: 1)
    private let homeDensity = 3
    private let midStreet = GridPosition(x: 12, y: 0)

    /// One long street, a house at the left end and the town's only shop at
    /// the right, plus a strip of clear ground at `y: 3`/`y: 4` for stations.
    /// Deliberately long enough that the two ends are well outside each
    /// other's catchment, so a line is the only thing that could connect
    /// them.
    private func street(length: Int = 24, height: Int = 6) -> CityMap {
        var map = CityMap(width: length, height: height)
        for x in 0 ..< length { map[GridPosition(x: x, y: 0)].zone = .road }
        map.placeBuilding(zone: .residential, origin: home)
        for cell in map.footprintCells(origin: home, size: 2) { map[cell].density = homeDensity }
        let shop = GridPosition(x: length - 2, y: 1)
        map.placeBuilding(zone: .commercial, origin: shop)
        for cell in map.footprintCells(origin: shop, size: 2) { map[cell].density = 5 }
        return map
    }

    /// A bus stop, as a building — a route names stations the player already
    /// paid for rather than drawing its own infrastructure.
    private func station(_ map: inout CityMap, at position: GridPosition, mode: TransitRoute.Mode = .bus) -> GridPosition {
        map.placeBuilding(zone: mode.stationZone, origin: position)
        return position
    }

    private func nearHome(_ map: inout CityMap, y: Int = 3) -> GridPosition {
        station(&map, at: GridPosition(x: 1, y: y))
    }

    private func nearShop(_ map: inout CityMap, y: Int = 3) -> GridPosition {
        station(&map, at: GridPosition(x: map.width - 2, y: y))
    }

    // MARK: - What a route covers

    func testARouteCoversTheGroundAroundEveryStationItCallsAt() {
        var map = street()
        let a = nearHome(&map)
        let b = nearShop(&map)
        map.transit.add(mode: .bus, stops: [a, b])

        let coverage = Transit.coverage(for: map)
        XCTAssertTrue(coverage.isServed(at: home), "the house next to the stop is not served")
        XCTAssertTrue(coverage.isServed(at: b), "the far end of the line is not served")

        // The edge of a catchment, from both sides of it.
        XCTAssertTrue(coverage.isServed(at: GridPosition(x: a.x + Transit.busCatchment, y: a.y)))
        XCTAssertFalse(coverage.isServed(at: GridPosition(x: a.x + Transit.busCatchment + 1, y: a.y)))

        XCTAssertFalse(coverage.isServed(at: GridPosition(x: 12, y: 3)),
                       "the middle of the line, nowhere near either stop, is covered")
    }

    /// The whole reason a subway costs what it does: it serves a bigger area.
    /// Asserted as the ratio rather than the raw numbers, so re-tuning the
    /// catchment in phase 4 does not have to come here and edit a constant.
    func testASubwayLineReachesTwiceAsFarAsABusLine() {
        XCTAssertEqual(Transit.subwayCatchment, Transit.busCatchment * 2)

        for mode in TransitRoute.Mode.allCases {
            var map = CityMap(width: 40, height: 40)
            let a = station(&map, at: GridPosition(x: 2, y: 2), mode: mode)
            let b = station(&map, at: GridPosition(x: 30, y: 2), mode: mode)
            map.transit.add(mode: mode, stops: [a, b])

            let coverage = Transit.coverage(for: map)
            let radius = Transit.catchment(for: mode)
            XCTAssertTrue(coverage.isServed(at: GridPosition(x: 2, y: 2 + radius)), "\(mode)")
            XCTAssertFalse(coverage.isServed(at: GridPosition(x: 2, y: 2 + radius + 1)), "\(mode)")
        }
    }

    /// A line has to go from somewhere to somewhere. Without this a single
    /// station would teleport every commute inside its own catchment, for the
    /// price of one building and no route worth the name.
    func testOneStationIsNotALine() {
        var map = street()
        let a = nearHome(&map)
        map.transit.add(mode: .bus, stops: [a])

        XCTAssertTrue(Transit.coverage(for: map).isEmpty, "a one-stop route is carrying people")
    }

    /// A bus does not call at a subway entrance. The route keeps the stop —
    /// it is what the player drew — it just does not count, which leaves this
    /// line one valid station short of being a line at all.
    func testALineOnlyCallsAtItsOwnKindOfStation() {
        var map = street()
        let stop = nearHome(&map)
        let entrance = station(&map, at: GridPosition(x: map.width - 2, y: 3), mode: .subway)
        map.transit.add(mode: .bus, stops: [stop, entrance])

        XCTAssertTrue(Transit.coverage(for: map).isEmpty)
    }

    func testAStopOnGroundWithNoStationOnItCountsForNothing() {
        var map = street()
        let real = nearHome(&map)
        map.transit.add(mode: .bus, stops: [real, GridPosition(x: 12, y: 4)])

        XCTAssertTrue(Transit.coverage(for: map).isEmpty)
    }

    // MARK: - No transfers

    /// **The v1 rule, stated as a test.** Two lines that would together make
    /// the journey do not make it: a trip rides when one route serves both
    /// ends, and otherwise it drives.
    func testATripThatWouldNeedAChangeOfLineDrivesInstead() {
        var map = street()
        let a = nearHome(&map)
        let interchangeIn = station(&map, at: GridPosition(x: 11, y: 3))
        let interchangeOut = station(&map, at: GridPosition(x: 13, y: 3))
        let b = nearShop(&map)
        map.transit.add(mode: .bus, stops: [a, interchangeIn])
        map.transit.add(mode: .bus, stops: [interchangeOut, b])

        let load = Traffic.computeLoad(for: map)
        XCTAssertEqual(load.totalRidership, 0, "a trip changed lines")
        XCTAssertGreaterThan(load.load(at: midStreet), 0, "nobody drove, but nobody could ride either")
    }

    /// Where two lines both serve both ends, the shorter ride wins — and the
    /// tie-break is on route id rather than dictionary order, because
    /// `Traffic.computeLoad` has already been genuinely non-deterministic
    /// once from exactly this kind of ordering.
    func testTheShorterOfTwoLinesServingBothEndsCarriesTheTrip() {
        var map = street()
        let directA = nearHome(&map, y: 3)
        let directB = nearShop(&map, y: 3)
        let slowA = station(&map, at: GridPosition(x: 1, y: 4))
        let slowMiddle = station(&map, at: GridPosition(x: 12, y: 4))
        let slowB = station(&map, at: GridPosition(x: map.width - 2, y: 4))

        let direct = map.transit.add(mode: .bus, stops: [directA, directB])
        let indirect = map.transit.add(mode: .bus, stops: [slowA, slowMiddle, slowB])

        let load = Traffic.computeLoad(for: map)
        XCTAssertEqual(load.ridership(onRoute: direct), homeDensity)
        XCTAssertEqual(load.ridership(onRoute: indirect), 0)
    }

    // MARK: - The mechanic

    /// Measured against a control, the way every other claim in this project
    /// about a mechanic's effect is: the same city, differing only in whether
    /// the line exists.
    func testACommuteServedByOneLineTakesItsCarOffTheRoad() {
        var withoutLine = street()
        _ = nearHome(&withoutLine)
        _ = nearShop(&withoutLine)
        let driving = Traffic.computeLoad(for: withoutLine)

        var withLine = withoutLine
        let route = withLine.transit.add(
            mode: .bus,
            stops: [GridPosition(x: 1, y: 3), GridPosition(x: withLine.width - 2, y: 3)]
        )
        let riding = Traffic.computeLoad(for: withLine)

        XCTAssertGreaterThan(driving.load(at: midStreet), 0, "precondition: nobody was driving to begin with")
        XCTAssertEqual(driving.totalRidership, 0)

        XCTAssertEqual(riding.load(at: midStreet), 0, "the commute still drives the whole street")
        XCTAssertEqual(riding.ridership(onRoute: route), homeDensity)
        XCTAssertEqual(riding.commuteFound(at: home), true, "riding to work is not working")
    }

    /// A line the player drew that happens not to connect anyone changes
    /// nothing — it is not a city-wide discount on traffic.
    func testALineThatConnectsNobodyChangesNothing() {
        var map = street()
        let a = station(&map, at: GridPosition(x: 10, y: 3))
        let b = station(&map, at: GridPosition(x: 14, y: 3))
        map.transit.add(mode: .bus, stops: [a, b])

        var control = street()
        _ = station(&control, at: GridPosition(x: 10, y: 3))
        _ = station(&control, at: GridPosition(x: 14, y: 3))

        let load = Traffic.computeLoad(for: map)
        XCTAssertEqual(load.totalRidership, 0)
        XCTAssertEqual(load.load(at: midStreet), Traffic.computeLoad(for: control).load(at: midStreet))
    }

    /// **The hole this closes.** A block with no street of its own generated
    /// no trips at all, so everyone living there reported as unable to find
    /// work — even though `CitySimulator.hasAccess` has always let a transit
    /// stop be the thing that lets it grow in the first place.
    func testABlockWithNoStreetOfItsOwnCanStillGetToWorkOnALine() {
        var map = CityMap(width: 30, height: 12)
        for x in 0 ..< 30 { map[GridPosition(x: x, y: 0)].zone = .road }
        let isolated = GridPosition(x: 2, y: 6)
        map.placeBuilding(zone: .residential, origin: isolated)
        for cell in map.footprintCells(origin: isolated, size: 2) { map[cell].density = 4 }
        let shop = GridPosition(x: 26, y: 1)
        map.placeBuilding(zone: .commercial, origin: shop)
        for cell in map.footprintCells(origin: shop, size: 2) { map[cell].density = 5 }

        let stranded = Traffic.computeLoad(for: map)
        XCTAssertEqual(stranded.commuteFound(at: isolated), false, "precondition: this block has a street after all")

        let a = station(&map, at: GridPosition(x: 2, y: 5))
        let b = station(&map, at: GridPosition(x: 26, y: 4))
        let route = map.transit.add(mode: .bus, stops: [a, b])

        let served = Traffic.computeLoad(for: map)
        XCTAssertEqual(served.commuteFound(at: isolated), true)
        XCTAssertEqual(served.ridership(onRoute: route), 4)
        XCTAssertEqual(served.load(at: midStreet), 0, "a transit-only commute put a car on the road")
    }

    func testRidershipIsUnknownUntilRoutingHasRun() {
        let untouched = TrafficLoad()
        XCTAssertNil(untouched.totalRidership, "a map that has never routed claims to know its ridership")
        XCTAssertNil(untouched.ridership(onRoute: 1))

        var map = street()
        _ = nearHome(&map)
        XCTAssertEqual(Traffic.computeLoad(for: map).totalRidership, 0)
    }

    /// One tick is one day (`CityDate`), so what the router produces is the
    /// day's ridership with no conversion anywhere — and it is the *people*,
    /// which is to say the home's density, the same weight a commute
    /// contributes to a road.
    func testRidershipCountsThePeopleWhoRodeAndSumsAcrossHomes() {
        var map = street(length: 24, height: 6)
        let second = GridPosition(x: 4, y: 1)
        map.placeBuilding(zone: .residential, origin: second)
        for cell in map.footprintCells(origin: second, size: 2) { map[cell].density = 2 }
        let a = nearHome(&map)
        let alsoNearHome = station(&map, at: GridPosition(x: 5, y: 3))
        let b = nearShop(&map)
        let route = map.transit.add(mode: .bus, stops: [a, alsoNearHome, b])

        let load = Traffic.computeLoad(for: map)
        XCTAssertEqual(load.ridership(onRoute: route), homeDensity + 2)
        XCTAssertEqual(load.totalRidership, homeDensity + 2)
    }

    /// Routing has been non-deterministic once already, from `Set` iteration
    /// order deciding a tie — and it quietly poisoned every balance number
    /// taken before it was found. Transit adds two more places an unordered
    /// collection decides an outcome, so this asks the same question again.
    func testRoutingStaysReproducibleWithTransitInPlay() {
        var map = street()
        let a = nearHome(&map)
        let b = nearShop(&map)
        let c = station(&map, at: GridPosition(x: 1, y: 4))
        let d = station(&map, at: GridPosition(x: map.width - 2, y: 4))
        map.transit.add(mode: .bus, stops: [a, b])
        map.transit.add(mode: .bus, stops: [c, d])

        XCTAssertEqual(Traffic.computeLoad(for: map), Traffic.computeLoad(for: map))
    }

    // MARK: - Routes as state the player owns

    func testBulldozingAStationTakesTheLineOutOfServiceButKeepsTheLine() {
        var map = street()
        let a = nearHome(&map)
        let b = nearShop(&map)
        let controller = GameController(map: map, rng: AlwaysZeroRNG(), peakPopulation: Unlocks.everythingUnlocked)
        let route = controller.addTransitRoute(mode: .bus, stops: [a, b])
        XCTAssertEqual(Traffic.computeLoad(for: controller.map).ridership(onRoute: route), homeDensity)

        controller.bulldoze(at: a)

        XCTAssertNotNil(controller.map.transit.route(id: route), "the whole line was deleted with one station")
        XCTAssertEqual(controller.map.transit.route(id: route)?.stops, [b], "a stop survived its station")
        XCTAssertEqual(Traffic.computeLoad(for: controller.map).ridership(onRoute: route), 0)
    }

    /// Ids are never reused, because ridership is keyed on them — handing a
    /// deleted line's id to a new one would credit its riders to the wrong
    /// route.
    func testRouteIdsAreNeverHandedOutTwice() {
        var network = TransitNetwork()
        let first = network.add(mode: .bus)
        network.remove(id: first)
        let second = network.add(mode: .subway)

        XCTAssertNotEqual(first, second)
        XCTAssertNil(network.route(id: first))
        XCTAssertEqual(network.route(id: second)?.mode, .subway)
    }

    func testRoutesSurviveASaveRoundTrip() throws {
        var map = street()
        let a = nearHome(&map)
        let b = nearShop(&map)
        let controller = GameController(map: map, rng: AlwaysZeroRNG(), peakPopulation: Unlocks.everythingUnlocked)
        let route = controller.addTransitRoute(mode: .subway, stops: [a, b])

        let data = try JSONEncoder().encode(controller.snapshot())
        let decoded = try JSONDecoder().decode(CitySave.self, from: data)

        XCTAssertEqual(decoded.map.transit.route(id: route)?.stops, [a, b])
        XCTAssertEqual(decoded.map.transit.route(id: route)?.mode, .subway)
    }

    /// The reason the field is stored `Optional`: `CityMap` decodes through
    /// the synthesised conformance, which throws on a missing key even where
    /// the property has a default. Four earlier fields broke every existing
    /// save exactly that way; this asserts that this one does not.
    func testACitySavedBeforeTransitExistedStillLoads() throws {
        let controller = GameController(
            map: CityMap(width: 8, height: 8), rng: AlwaysZeroRNG(),
            peakPopulation: Unlocks.everythingUnlocked
        )
        // Drawn first, so the key is genuinely present to be taken away — a
        // fresh map encodes `nil` as no key at all, which would have made this
        // assert nothing.
        controller.addTransitRoute(mode: .bus, stops: [GridPosition(x: 1, y: 1)])
        let data = try JSONEncoder().encode(controller.snapshot())
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var mapJSON = try XCTUnwrap(json["map"] as? [String: Any])
        XCTAssertNotNil(mapJSON.removeValue(forKey: "transitNetwork"),
                        "nothing was removed, so this is not testing an older save")
        json["map"] = mapJSON

        let older = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(CitySave.self, from: older)
        XCTAssertTrue(decoded.map.transit.isEmpty)
    }
}
