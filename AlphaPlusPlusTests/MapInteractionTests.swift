import XCTest
@testable import AlphaPlusPlus

/// M8: the input layer, driven with no scene and no renderer. Every rule
/// here used to be reachable only through `GameScene`.
@MainActor
final class MapInteractionTests: XCTestCase {

    private func make(size: Int = 16) -> (GameController, MapInteraction) {
        let controller = GameController(map: CityMap(width: size, height: size), rng: SeededRNG(seed: 1),
                                        peakPopulation: Unlocks.everythingUnlocked)
        return (controller, MapInteraction(controller: controller))
    }

    private func p(_ x: Int, _ y: Int) -> GridPosition { GridPosition(x: x, y: y) }

    /// A drag reports where the pointer is, not the path it took, so a jump
    /// of several tiles between two events is filled back in.
    func testAFastDragPaintsAnUnbrokenRoad() {
        let (controller, input) = make()
        controller.selectTool(.road)
        input.press(at: p(1, 3))
        input.drag(to: p(9, 3))
        input.release()
        for x in 1 ... 9 { XCTAssertEqual(controller.map[p(x, 3)].zone, .road, "gap at \(x)") }
    }

    /// Each stroke starts afresh: a second press does not join back to where
    /// the first one ended.
    func testAStrokeDoesNotJoinThePreviousOne() {
        let (controller, input) = make()
        controller.selectTool(.road)
        input.press(at: p(1, 1)); input.release()
        input.press(at: p(6, 1)); input.release()
        XCTAssertEqual(controller.map[p(3, 1)].zone, .empty)
    }

    /// A multi-tile building is placed once per click; dragging on does not
    /// stamp more of them.
    func testAFootprintIsPlacedOncePerClick() {
        let (controller, input) = make()
        controller.selectTool(.residential)
        input.press(at: p(2, 2))
        input.drag(to: p(8, 2))
        input.release()
        let anchors = controller.map.tiles.filter { $0.isBuildingAnchor && $0.zone == .residential }
        XCTAssertEqual(anchors.count, 1)
    }

    /// A refused click earns a flash over the building that refused it, and
    /// the cursor already said it would be refused.
    func testAnOccupiedLotIsBlockedAndFlashes() {
        let (controller, input) = make()
        controller.selectTool(.residential)
        input.press(at: p(2, 2)); input.release()
        _ = input.takeFlashes()

        input.pointerMoved(to: p(3, 3))
        XCTAssertEqual(input.cursor?.blocked, true)
        input.press(at: p(3, 3)); input.release()
        XCTAssertEqual(input.takeFlashes(), [.init(origin: p(2, 2), size: 2, kind: .blocked)])
        XCTAssertTrue(input.takeFlashes().isEmpty, "flashes are handed over once")

        input.pointerMoved(to: p(10, 10))
        XCTAssertEqual(input.cursor, .init(origin: p(10, 10), size: 2, blocked: false, kind: .tool))
    }

    /// Running out of money flashes once per event and stops that event's
    /// line, since every tile after it costs the same.
    func testRunningOutOfMoneyFlashesAndStops() {
        let (controller, input) = make(size: 40)
        controller.selectTool(.road)
        var row = 0
        while input.takeFlashes().isEmpty, row < 40 {
            input.press(at: p(0, row)); input.drag(to: p(39, row)); input.release()
            row += 1
        }
        XCTAssertLessThan(row, 40, "the treasury never ran out")
        _ = input.takeFlashes()
        input.press(at: p(0, 39)); input.drag(to: p(39, 39)); input.release()
        XCTAssertEqual(input.takeFlashes().map(\.kind), [.insufficientFunds, .insufficientFunds],
                       "one flash for the press and one for the drag event, not one per tile")
        XCTAssertEqual(controller.map[p(20, 39)].zone, .empty)
    }

    /// Right-dragging bulldozes a whole line.
    func testARightDragBulldozes() {
        let (controller, input) = make()
        controller.selectTool(.road)
        input.press(at: p(0, 5)); input.drag(to: p(10, 5)); input.release()
        input.rightPress(at: p(2, 5)); input.rightDrag(to: p(8, 5)); input.release()
        XCTAssertEqual(controller.map[p(1, 5)].zone, .road)
        for x in 2 ... 8 { XCTAssertEqual(controller.map[p(x, 5)].zone, .empty) }
        XCTAssertEqual(controller.map[p(9, 5)].zone, .road)
    }

    /// **A half-drawn bus line must not stop a pipe drag.** The bug this
    /// guards once shipped: the drag guard asked whether a draft existed
    /// anywhere rather than whether this view was drawing it.
    func testAnOpenRouteDraftDoesNotStopAPipeDrag() {
        let (controller, input) = make()
        controller.beginTransitRoute(mode: .bus)
        controller.overlayMode = .water
        XCTAssertNotNil(controller.routeDraft)
        input.press(at: p(1, 7)); input.drag(to: p(6, 7)); input.release()
        for x in 1 ... 6 { XCTAssertTrue(controller.map[p(x, 7)].hasPipe, "no pipe at \(x)") }

        input.rightPress(at: p(3, 7)); input.rightDrag(to: p(4, 7)); input.release()
        XCTAssertFalse(controller.map[p(3, 7)].hasPipe)
        XCTAssertTrue(controller.map[p(5, 7)].hasPipe)
    }

    /// While a line is drawn, a click names a station: the cursor wraps a
    /// station clear and anything else blocked, a miss flashes, and a drag
    /// adds nothing.
    func testDrawingALineAsksAboutStations() {
        let (controller, input) = make()
        controller.selectTool(.publicTransit)
        input.press(at: p(4, 4)); input.release()
        controller.beginTransitRoute(mode: .bus)

        input.pointerMoved(to: p(4, 4))
        XCTAssertEqual(input.cursor?.kind, .routeStop)
        XCTAssertEqual(input.cursor?.blocked, false)
        input.pointerMoved(to: p(9, 9))
        XCTAssertEqual(input.cursor?.blocked, true)

        input.press(at: p(4, 4))
        input.drag(to: p(4, 4))
        input.release()
        XCTAssertEqual(controller.routeDraft?.stops.count, 1)

        _ = input.takeFlashes()
        input.press(at: p(9, 9)); input.release()
        XCTAssertEqual(input.takeFlashes().map(\.kind), [.blocked])
    }

    /// Leaving the map clears the cursor, and the revision moves with it.
    func testLeavingTheMapClearsTheCursor() {
        let (_, input) = make()
        input.pointerMoved(to: p(3, 3))
        XCTAssertNotNil(input.cursor)
        let before = input.revision
        input.pointerMoved(to: nil)
        XCTAssertNil(input.cursor)
        XCTAssertGreaterThan(input.revision, before)
    }

    /// A stroke hides the cursor; letting go brings it back for what is now
    /// under the pointer.
    func testAStrokeHidesTheCursorUntilRelease() {
        let (controller, input) = make()
        controller.selectTool(.road)
        input.pointerMoved(to: p(5, 5))
        input.press(at: p(5, 5))
        XCTAssertNil(input.cursor)
        input.release()
        XCTAssertEqual(input.cursor?.blocked, true, "the road just laid is under the pointer")
    }
}

/// The cursor tests `ScenePlaytestTests` asked of `GameScene`'s preview,
/// asked of the rule itself now that the renderer only draws its answer.
@MainActor
final class MapInteractionCursorTests: XCTestCase {

    /// **The cursor never promises a placement the click refuses**, swept
    /// over every cell of a map with a river in it, for four tools. A test
    /// naming the cases somebody thought of would have passed on the day
    /// water landed; the sweep is what makes the next rule added to
    /// `placementRefusal` show up here if the cursor is not taught about it.
    func testTheCursorNeverPromisesAPlacementTheClickRefuses() {
        var map = MetalPlaytestTests.startedCity()
        for x in 0 ..< map.width { map[GridPosition(x: x, y: 8)].isWater = true }
        let controller = GameController(map: map, rng: SeededRNG(seed: 1),
                                        peakPopulation: Unlocks.everythingUnlocked)
        for tool in [ZoneType.residential, .road, .seaport, .airport] {
            controller.selectedTool = tool
            for position in map.tiles.map(\.position) {
                guard let cursor = MapInteraction.cursor(at: position, controller: controller) else { continue }
                // A copy, so asking the question does not build the city.
                let trial = GameController(map: map, rng: SystemRandomNumberGenerator(),
                                           peakPopulation: Unlocks.everythingUnlocked)
                trial.selectedTool = tool
                let outcome = trial.place(at: position)
                if cursor.blocked {
                    XCTAssertNotEqual(outcome, .placed, "\(tool) at \(position): said blocked, and it placed")
                } else {
                    XCTAssertEqual(outcome, .placed, "\(tool) at \(position): said clear, and got \(outcome)")
                }
            }
        }
    }

    /// While a line is drawn the station is the clear tile and bare ground the
    /// blocked one. It was once the other way round: the cursor described the
    /// armed zoning tool, which calls every building occupied.
    func testTheCursorSaysWhichStopsALineCanCallAt() {
        var map = MetalPlaytestTests.startedCity()
        map.placeBuilding(zone: .publicTransit, origin: GridPosition(x: 5, y: 3))
        let controller = GameController(map: map, rng: SeededRNG(seed: 1),
                                        peakPopulation: Unlocks.everythingUnlocked)
        controller.beginTransitRoute(mode: .bus)
        let onStation = MapInteraction.cursor(at: GridPosition(x: 5, y: 3), controller: controller)
        let onNothing = MapInteraction.cursor(at: GridPosition(x: 9, y: 9), controller: controller)
        XCTAssertEqual(onStation?.blocked, false, "the station you are meant to click is drawn as forbidden")
        XCTAssertEqual(onNothing?.blocked, true)
        XCTAssertEqual(onStation?.kind, .routeStop)
    }
}
