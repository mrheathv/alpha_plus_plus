import XCTest
@testable import AlphaPlusPlus

/// Drawing a line: the gesture, and what it writes back to the city.
@MainActor
final class TransitEditorTests: XCTestCase {

    private let stops = [GridPosition(x: 2, y: 2), GridPosition(x: 12, y: 2), GridPosition(x: 22, y: 2)]
    private let house = GridPosition(x: 2, y: 4)

    private func controller(subwayToo: Bool = false, withShop: Bool = false) -> GameController {
        var map = CityMap(width: 30, height: 8)
        // The street runs *between* the stations and the blocks, so every
        // building has road frontage and a commute has somewhere to drive —
        // without which "the line took the car off the road" measures nothing.
        for x in 0 ..< 30 { map[GridPosition(x: x, y: 3)].zone = .road }
        for stop in stops { map.placeBuilding(zone: .publicTransit, origin: stop) }
        if subwayToo { map.placeBuilding(zone: .subway, origin: GridPosition(x: 6, y: 2)) }
        map.placeBuilding(zone: .residential, origin: house)
        for cell in map.footprintCells(origin: house, size: 2) { map[cell].density = 3 }
        if withShop {
            // Somewhere to work, right beside the far stop.
            let shop = GridPosition(x: 22, y: 4)
            map.placeBuilding(zone: .commercial, origin: shop)
            for cell in map.footprintCells(origin: shop, size: 2) { map[cell].density = 5 }
        }
        return GameController(map: map, rng: AlwaysZeroRNG(), peakPopulation: Unlocks.everythingUnlocked)
    }

    // MARK: - The gesture

    /// Picking the tool raises the view that makes stations clickable, the
    /// same contract Pipe and Power Line already have.
    func testStartingALineRaisesItsOwnView() {
        let game = controller()
        game.beginTransitRoute(mode: .bus)

        XCTAssertEqual(game.overlayMode, .bus)
        XCTAssertEqual(game.routeDraft?.mode, .bus)
        XCTAssertEqual(game.routeDraft?.stops, [])
    }

    func testClickingStationsBuildsTheLineInOrder() {
        let game = controller()
        game.beginTransitRoute(mode: .bus)

        XCTAssertEqual(game.addStopToRoute(at: stops[2]), .added)
        XCTAssertEqual(game.addStopToRoute(at: stops[0]), .added)
        XCTAssertEqual(game.routeDraft?.stops, [stops[2], stops[0]],
                       "the order stops were clicked in is the order the line runs")
    }

    /// **Undo is in the same gesture as the mistake.** Clicking the stop you
    /// just added takes it back off, so correcting a misclick does not mean
    /// finding a button.
    func testClickingTheLastStopAgainTakesItOff() {
        let game = controller()
        game.beginTransitRoute(mode: .bus)
        game.addStopToRoute(at: stops[0])

        XCTAssertEqual(game.addStopToRoute(at: stops[0]), .removed)
        XCTAssertEqual(game.routeDraft?.stops, [])
    }

    /// And that rule has to be "the *last* one", not "any one it already has",
    /// or a circular route could not be drawn at all.
    func testALineCanReturnToAStopItAlreadyCallsAt() {
        let game = controller()
        game.beginTransitRoute(mode: .bus)
        for stop in stops { game.addStopToRoute(at: stop) }

        XCTAssertEqual(game.addStopToRoute(at: stops[0]), .added, "a loop is not expressible")
        XCTAssertEqual(game.routeDraft?.stops.count, 4)
    }

    func testOnlyTheRightKindOfStationCanBeClicked() {
        let game = controller(subwayToo: true)
        game.beginTransitRoute(mode: .bus)

        XCTAssertEqual(game.addStopToRoute(at: house), .notAStation)
        XCTAssertEqual(game.addStopToRoute(at: GridPosition(x: 6, y: 2)), .notAStation,
                       "a bus route called at a subway entrance")
        XCTAssertEqual(game.addStopToRoute(at: GridPosition(x: 15, y: 5)), .notAStation)
        XCTAssertEqual(game.routeDraft?.stops, [])
    }

    // MARK: - Committing

    func testALineNeedsTwoStopsBeforeItCanBeFinished() {
        let game = controller()
        game.beginTransitRoute(mode: .bus)
        game.addStopToRoute(at: stops[0])

        XCTAssertEqual(game.routeDraft?.isCommittable, false)
        XCTAssertNil(game.commitTransitRoute(), "a one-stop line was accepted")
        XCTAssertTrue(game.map.transit.isEmpty)
        XCTAssertNotNil(game.routeDraft, "a refused commit threw the draft away")

        game.addStopToRoute(at: stops[1])
        let id = try? XCTUnwrap(game.commitTransitRoute())
        XCTAssertNotNil(id)
        XCTAssertNil(game.routeDraft)
        XCTAssertEqual(game.map.transit.routes.first?.stops, [stops[0], stops[1]])
    }

    /// End to end: a line drawn through the editor is a line the simulation
    /// carries people on. Everything above is about the gesture; this is the
    /// one that says the gesture reaches the city.
    func testALineDrawnInTheEditorCarriesRealCommuters() {
        let game = controller(withShop: true)
        let driving = Traffic.computeLoad(for: game.map)
        XCTAssertGreaterThan(driving.load(at: GridPosition(x: 12, y: 3)), 0,
                             "precondition: nobody was driving to begin with")

        game.beginTransitRoute(mode: .bus)
        game.addStopToRoute(at: stops[0])
        game.addStopToRoute(at: stops[2])
        let id = game.commitTransitRoute()

        let riding = Traffic.computeLoad(for: game.map)
        XCTAssertEqual(riding.load(at: GridPosition(x: 12, y: 3)), 0, "the commute still drives")
        XCTAssertEqual(riding.ridership(onRoute: try XCTUnwrap(id)),
                       3 * ZoneType.residential.populationPerDensityLevel,
                       "ridership is counted in people, the same units the panel prints")
    }

    // MARK: - Editing what is already there

    func testEditingALineSeedsTheDraftAndWritesBackToTheSameRoute() {
        let game = controller()
        game.beginTransitRoute(mode: .bus)
        game.addStopToRoute(at: stops[0])
        game.addStopToRoute(at: stops[1])
        let id = try! XCTUnwrap(game.commitTransitRoute())

        game.editTransitRoute(id: id)
        XCTAssertEqual(game.routeDraft?.stops, [stops[0], stops[1]])
        XCTAssertEqual(game.routeDraft?.editing, id)

        game.addStopToRoute(at: stops[2])
        XCTAssertEqual(game.commitTransitRoute(), id, "editing a line made a second one")
        XCTAssertEqual(game.map.transit.routes.count, 1)
        XCTAssertEqual(game.map.transit.route(id: id)?.stops, stops)
    }

    func testCancellingLeavesTheCityAlone() {
        let game = controller()
        game.beginTransitRoute(mode: .bus)
        game.addStopToRoute(at: stops[0])
        game.addStopToRoute(at: stops[1])
        game.cancelTransitRoute()

        XCTAssertNil(game.routeDraft)
        XCTAssertTrue(game.map.transit.isEmpty)
    }

    /// The same exclusivity that stops Residential-with-the-Water-overlay
    /// dropping you into an invisible pipe-laying mode. A half-drawn line has
    /// no meaning once you have picked up a different tool.
    func testPickingAZoneToolLeavesTheViewAndAbandonsTheDraft() {
        let game = controller()
        game.beginTransitRoute(mode: .bus)
        game.addStopToRoute(at: stops[0])

        game.selectTool(.residential)
        XCTAssertEqual(game.overlayMode, .none)
        XCTAssertNil(game.routeDraft)
    }

    // MARK: - What the panel reads

    /// A stop whose station has been bulldozed is still on the line and calls
    /// at nothing, so the panel has to be able to say *why* a line it is
    /// listing shows no riders.
    func testWorkingStopsAreCountedSeparatelyFromDrawnOnes() {
        let game = controller()
        game.beginTransitRoute(mode: .bus)
        game.addStopToRoute(at: stops[0])
        game.addStopToRoute(at: stops[1])
        game.addStopToRoute(at: stops[2])
        let id = try! XCTUnwrap(game.commitTransitRoute())
        XCTAssertEqual(game.workingStopCounts()[id], 3)

        game.bulldoze(at: stops[1])
        let route = try! XCTUnwrap(game.map.transit.route(id: id))
        XCTAssertEqual(route.stops.count, 2, "bulldozing a station left a phantom stop on the line")
        XCTAssertEqual(game.workingStopCounts()[id], 2)
        XCTAssertNil(TransitText.fault(for: route, workingStops: 2), "a working line was reported as faulty")
    }

    func testTheNamesAndUnitsReadAsAPlayerWouldSayThem() {
        let game = controller()
        game.beginTransitRoute(mode: .bus)
        game.addStopToRoute(at: stops[0])
        game.addStopToRoute(at: stops[1])
        game.commitTransitRoute()
        game.beginTransitRoute(mode: .bus)
        game.addStopToRoute(at: stops[1])
        game.addStopToRoute(at: stops[2])
        game.commitTransitRoute()

        let routes = game.map.transit.routes(mode: .bus)
        XCTAssertEqual(TransitText.name(for: routes[0], numberedWithin: routes), "Bus 1")
        XCTAssertEqual(TransitText.name(for: routes[1], numberedWithin: routes), "Bus 2")
        XCTAssertEqual(TransitText.stops(1), "1 stop")
        XCTAssertEqual(TransitText.stops(3), "3 stops")
        XCTAssertEqual(TransitText.ridership(1284), "1,284 riders/day")
        // Never routed and carried nobody are different facts, and the panel
        // must not report the first as the second.
        XCTAssertEqual(TransitText.ridership(nil), "no data yet")
        XCTAssertEqual(TransitText.ridership(0), "0 riders/day")
    }

    /// The route tools are offered, and gated on there being a station to
    /// click — a control with nothing to act on is the shape of problem the
    /// starter utilities exist to fix.
    func testTheRouteToolsAreOfferedAndGatedOnTheirStations() {
        let offered = ToolCategory.allEntries
        let bus = try! XCTUnwrap(offered.first { $0.overlay == .bus })
        let subway = try! XCTUnwrap(offered.first { $0.overlay == .subway })

        XCTAssertEqual(bus.unlockedBy, .publicTransit)
        XCTAssertEqual(subway.unlockedBy, .subway)
        XCTAssertNil(bus.cost, "drawing a line charges the player")
        // Pipes and power lines have always been available from tick one.
        XCTAssertNil(try! XCTUnwrap(offered.first { $0.overlay == .water }).unlockedBy)
    }
}
