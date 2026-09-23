import XCTest
@testable import AlphaPlusPlus

/// The Bus and Subway views: what they paint, and the diagram over the top.
@MainActor
final class TransitOverlayTests: XCTestCase {

    /// A street, a house at each end, and a station beside the western one.
    private func city() -> CityMap {
        var map = CityMap(width: 24, height: 8)
        for x in 0 ..< 24 { map[GridPosition(x: x, y: 0)].zone = .road }
        for origin in [GridPosition(x: 0, y: 1), GridPosition(x: 20, y: 1)] {
            map.placeBuilding(zone: .residential, origin: origin)
            for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = 3 }
        }
        return map
    }

    private func line(_ mode: TransitRoute.Mode, in map: inout CityMap,
                      at stops: [GridPosition]) -> TransitRoute.ID {
        for stop in stops { map.placeBuilding(zone: mode.stationZone, origin: stop) }
        return map.transit.add(mode: mode, stops: stops)
    }

    private func paint(_ overlay: OverlayMode, at position: GridPosition,
                       in map: CityMap) -> IsoTileRenderer.OverlayPaint? {
        IsoTileRenderer.paint(for: overlay, at: position, in: map, using: nil,
                              transit: Transit.coverage(for: map))
    }

    // MARK: - What the ground and the buildings say

    /// **Lit means served, the same way round as water, power and crime.** The
    /// value of a fourth network overlay is that a player who has learned one
    /// of them has learned it — so this asserts the reading rather than the
    /// colours.
    func testAServedBlockIsLitAndAnUnservedOneIsNot() throws {
        var map = city()
        _ = line(.bus, in: &map, at: [GridPosition(x: 1, y: 3), GridPosition(x: 3, y: 3)])

        let served = try XCTUnwrap(paint(.bus, at: GridPosition(x: 0, y: 1), in: map))
        let stranded = try XCTUnwrap(paint(.bus, at: GridPosition(x: 20, y: 1), in: map))

        XCTAssertEqual(served.buildings, .connected(true))
        XCTAssertEqual(stranded.buildings, .connected(false))
        XCTAssertNotEqual(components(served.color), components(stranded.color),
                          "the ground says the same thing inside and outside the catchment")
        XCTAssertEqual(components(stranded.buildingColor), components(RenderPalette.unlitBuilding))
    }

    /// A station is what a route is built out of, so it is the thing the
    /// player is hunting for here — the role a water tower plays in the water
    /// overlay.
    func testStationsKeepTheirOwnColours() throws {
        var map = city()
        let stop = GridPosition(x: 1, y: 3)
        _ = line(.bus, in: &map, at: [stop, GridPosition(x: 3, y: 3)])

        XCTAssertEqual(try XCTUnwrap(paint(.bus, at: stop, in: map)).buildings, .highlighted)
    }

    /// **The whole reason these are two views.** A bus line must not light the
    /// Subway overlay, or the separation is cosmetic and the player is back to
    /// reading one "somewhere near transit" wash.
    func testOneModesLinesAreInvisibleInTheOthersView() throws {
        var map = city()
        _ = line(.bus, in: &map, at: [GridPosition(x: 1, y: 3), GridPosition(x: 3, y: 3)])
        let home = GridPosition(x: 0, y: 1)

        XCTAssertEqual(try XCTUnwrap(paint(.bus, at: home, in: map)).buildings, .connected(true))
        XCTAssertEqual(try XCTUnwrap(paint(.subway, at: home, in: map)).buildings, .connected(false))
    }

    /// The subway's catchment is twice a bus stop's, and the two overlays have
    /// to show that difference rather than merely hold it in a constant.
    func testTheSubwayViewReachesFurtherThanTheBusView() throws {
        let edge = GridPosition(x: 1, y: Transit.busCatchment + 2)

        var buses = city()
        _ = line(.bus, in: &buses, at: [GridPosition(x: 1, y: 1), GridPosition(x: 3, y: 1)])
        XCTAssertFalse(try XCTUnwrap(paint(.bus, at: edge, in: buses)).buildings == .connected(true))

        var trains = city()
        _ = line(.subway, in: &trains, at: [GridPosition(x: 1, y: 1), GridPosition(x: 3, y: 1)])
        XCTAssertEqual(try XCTUnwrap(paint(.subway, at: edge, in: trains)).buildings, .connected(true))
    }

    // MARK: - The diagram (`MetalMarks.diagram`)

    private func diagram(_ mode: TransitRoute.Mode, in map: CityMap,
                         drawing draft: TransitRouteDraft? = nil) -> [Float] {
        MetalMarks.diagram(for: mode, in: map, drawing: draft)
    }

    /// Two routes of the same shape draw twice what one does: a line and a
    /// mark at each stop apiece.
    func testTheDiagramDrawsEveryWorkingRoute() {
        var one = city()
        _ = line(.bus, in: &one, at: [GridPosition(x: 1, y: 3), GridPosition(x: 10, y: 3)])
        var two = one
        _ = line(.bus, in: &two, at: [GridPosition(x: 14, y: 3), GridPosition(x: 20, y: 3)])
        XCTAssertFalse(diagram(.bus, in: one).isEmpty)
        XCTAssertEqual(diagram(.bus, in: two).count, 2 * diagram(.bus, in: one).count,
                       "two bus routes did not draw as two lines")
    }

    /// The diagram obeys the same "what works, not what was drawn" rule the
    /// coverage does — otherwise a demolished station would leave a line
    /// running to a patch of empty ground.
    func testTheDiagramDrawsNothingForALineThatIsNotRunning() {
        var map = city()
        let stop = GridPosition(x: 1, y: 3)
        _ = line(.bus, in: &map, at: [stop, GridPosition(x: 10, y: 3)])
        XCTAssertFalse(diagram(.bus, in: map).isEmpty, "precondition: nothing was drawn to begin with")
        // The station goes, the route keeps its remaining stop, and the line
        // stops being a line.
        map.transit.removeStop(at: stop)
        map.placeBuilding(zone: .empty, origin: stop)
        XCTAssertTrue(diagram(.bus, in: map).isEmpty)
    }

    func testTheDiagramShowsOnlyItsOwnMode() {
        var map = city()
        _ = line(.subway, in: &map, at: [GridPosition(x: 1, y: 3), GridPosition(x: 20, y: 3)])
        XCTAssertTrue(diagram(.bus, in: map).isEmpty, "the Bus view drew a subway line")
        XCTAssertFalse(diagram(.subway, in: map).isEmpty)
    }

    /// **The editor's feedback is the map.** Clicking a station has to change
    /// the picture, or building a route is a list of coordinates in a panel.
    func testADraftIsDrawnBeforeItIsFinished() {
        var map = city()
        let stops = [GridPosition(x: 1, y: 3), GridPosition(x: 10, y: 3)]
        for stop in stops { map.placeBuilding(zone: .publicTransit, origin: stop) }
        XCTAssertTrue(diagram(.bus, in: map).isEmpty, "precondition: something was already drawn")
        XCTAssertFalse(diagram(.bus, in: map, drawing: TransitRouteDraft(mode: .bus, stops: stops)).isEmpty)
    }

    /// A draft for the other kind of line is not this view's business.
    func testABusDraftDoesNotAppearInTheSubwayView() {
        var map = city()
        let stops = [GridPosition(x: 1, y: 3), GridPosition(x: 10, y: 3)]
        for stop in stops { map.placeBuilding(zone: .publicTransit, origin: stop) }
        XCTAssertTrue(diagram(.subway, in: map, drawing: TransitRouteDraft(mode: .bus, stops: stops)).isEmpty)
    }

    /// A line being edited is drawn once, as the draft — otherwise its old
    /// shape sits underneath the new one and the two disagree about where the
    /// route goes. So the diagram is exactly what it would be with the old
    /// line gone.
    func testAnEditedLineIsNotDrawnTwice() {
        var map = city()
        let stops = [GridPosition(x: 1, y: 3), GridPosition(x: 10, y: 3), GridPosition(x: 20, y: 3)]
        let id = line(.bus, in: &map, at: [stops[0], stops[1]])
        map.placeBuilding(zone: .publicTransit, origin: stops[2])
        let draft = TransitRouteDraft(mode: .bus, editing: id, stops: stops)
        var without = map
        without.transit.remove(id: id)
        XCTAssertEqual(diagram(.bus, in: map, drawing: draft), diagram(.bus, in: without, drawing: draft),
                       "the line being edited is still drawn in its old shape underneath")
    }

    // MARK: - Something running the line (`MetalMarks.vehicles`)

    private func lineCity(mode: TransitRoute.Mode) -> CityMap {
        var map = CityMap(width: 20, height: 12)
        for x in 0 ..< 20 { map[GridPosition(x: x, y: 6)].zone = .road }
        let stops = [GridPosition(x: 4, y: 5), GridPosition(x: 12, y: 5)]
        for stop in stops { map.placeBuilding(zone: mode.stationZone, origin: stop) }
        map.transit.add(mode: mode, stops: stops)
        return map
    }

    /// **The tram and rail views once drew no lines at all**: the scene's
    /// dispatch knew only the first two modes. The renderer now asks the view
    /// which mode it draws, so every mode has to answer, and draw.
    func testEveryModeDrawsItsLinesInItsOwnView() {
        for mode in TransitRoute.Mode.allCases {
            XCTAssertEqual(OverlayMode.view(for: mode).routeMode, mode, "the \(mode) view draws another mode")
            XCTAssertFalse(diagram(mode, in: lineCity(mode: mode)).isEmpty, "the \(mode) view draws no lines")
        }
    }

    /// Until vehicles ran the lines, the only evidence a route carried anyone
    /// was a number in a panel.
    func testAWorkingLineHasSomethingRunningIt() {
        for mode in TransitRoute.Mode.allCases {
            let traces = MetalMarks.vehicles(for: mode, in: lineCity(mode: mode), clock: 3)
            XCTAssertEqual(traces.count / MetalMotion.traceFloatCount, 1, "nothing is running the \(mode) line")
        }
    }

    /// A line with one working stop goes nowhere, so nothing runs it — the
    /// same rule `Transit` already applies to whether it carries anyone.
    func testALineGoingNowhereRunsNothing() {
        var map = lineCity(mode: .bus)
        for cell in map.footprintCells(origin: GridPosition(x: 12, y: 5), size: 2) {
            map[cell] = Tile(position: cell)
        }
        XCTAssertTrue(MetalMarks.vehicles(for: .bus, in: map, clock: 3).isEmpty,
                      "a line with one stop left still has a bus on it")
    }

    /// A vehicle is a function of the motion clock, which only advances while
    /// the city runs: the same clock holds it still, a later one moves it.
    func testTheVehicleIsAFunctionOfTheMotionClock() {
        let map = lineCity(mode: .bus)
        let parked = MetalMarks.vehicles(for: .bus, in: map, clock: 3)
        XCTAssertEqual(parked, MetalMarks.vehicles(for: .bus, in: map, clock: 3))
        XCTAssertNotEqual(parked, MetalMarks.vehicles(for: .bus, in: map, clock: 4),
                          "the bus does not move as the city runs")
    }

    /// `SKColor` equality is colour-space sensitive, so these compare
    /// components in one space.
    private func components(_ color: NSColor) -> [CGFloat] {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return [] }
        return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
    }
}
