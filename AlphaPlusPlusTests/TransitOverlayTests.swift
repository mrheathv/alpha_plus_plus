import XCTest
import SpriteKit
@testable import AlphaPlusPlus

/// The Bus and Subway views: what they paint, and the diagram over the top.
@MainActor
final class TransitOverlayTests: XCTestCase {

    private let projection = Isometric(tileWidth: 32)

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

    // MARK: - The diagram

    func testTheDiagramDrawsOneLinePerWorkingRoute() throws {
        var map = city()
        _ = line(.bus, in: &map, at: [GridPosition(x: 1, y: 3), GridPosition(x: 10, y: 3)])
        _ = line(.bus, in: &map, at: [GridPosition(x: 14, y: 3), GridPosition(x: 20, y: 3)])
        _ = line(.subway, in: &map, at: [GridPosition(x: 1, y: 5), GridPosition(x: 20, y: 5)])

        let renderer = IsoTileRenderer(projection: projection)
        let buses = try XCTUnwrap(renderer.transitDiagram(for: .bus, in: map))
        let trains = try XCTUnwrap(renderer.transitDiagram(for: .subway, in: map))

        XCTAssertEqual(named(IsoTileRenderer.transitLineName, in: buses), 2,
                       "two bus routes did not draw as two lines")
        XCTAssertEqual(named(IsoTileRenderer.transitLineName, in: trains), 1)
        // And a mark at every station, because a line with no stops on it says
        // how the route runs but not where you can board it.
        XCTAssertEqual(named(IsoTileRenderer.transitStopName, in: buses), 4)
        XCTAssertEqual(named(IsoTileRenderer.transitStopName, in: trains), 2)
    }

    /// The diagram obeys the same "what works, not what was drawn" rule the
    /// coverage does — otherwise a demolished station would leave a line
    /// running to a patch of empty ground.
    func testTheDiagramDrawsNothingForALineThatIsNotRunning() throws {
        var map = city()
        let stop = GridPosition(x: 1, y: 3)
        let other = GridPosition(x: 10, y: 3)
        _ = line(.bus, in: &map, at: [stop, other])
        let renderer = IsoTileRenderer(projection: projection)
        XCTAssertNotNil(renderer.transitDiagram(for: .bus, in: map), "precondition: nothing was drawn to begin with")

        // The station goes, the route keeps its remaining stop, and the line
        // stops being a line.
        map.transit.removeStop(at: stop)
        map.placeBuilding(zone: .empty, origin: stop)
        XCTAssertNil(renderer.transitDiagram(for: .bus, in: map))
    }

    func testTheDiagramShowsOnlyItsOwnMode() throws {
        var map = city()
        _ = line(.subway, in: &map, at: [GridPosition(x: 1, y: 3), GridPosition(x: 20, y: 3)])
        let renderer = IsoTileRenderer(projection: projection)

        XCTAssertNil(renderer.transitDiagram(for: .bus, in: map), "the Bus view drew a subway line")
        XCTAssertNotNil(renderer.transitDiagram(for: .subway, in: map))
    }

    /// **Not additive, and the render is why.** An additive core over its own
    /// additive halo saturated the line to a white filament, which is the one
    /// thing its colour is carrying — the same failure the first conduits had.
    func testTheLineKeepsItsColourRatherThanBlowingOutToWhite() throws {
        var map = city()
        _ = line(.subway, in: &map, at: [GridPosition(x: 1, y: 3), GridPosition(x: 20, y: 3)])
        let renderer = IsoTileRenderer(projection: projection)
        let diagram = try XCTUnwrap(renderer.transitDiagram(for: .subway, in: map))

        let cores = diagram.children
            .filter { $0.name == IsoTileRenderer.transitLineName }
            .compactMap { $0 as? SKShapeNode }
        XCTAssertFalse(cores.isEmpty)
        for core in cores {
            XCTAssertEqual(core.blendMode, .alpha,
                           "the line's core is additive, so it will blow out to white over its own halo")
            XCTAssertEqual(components(core.strokeColor),
                           components(RenderPalette.transitLineColor(for: .subway)))
        }
    }

    // MARK: - The line being drawn

    /// **The editor's feedback is the map.** Clicking a station has to change
    /// the picture, or building a route is a list of coordinates in a panel.
    func testADraftIsDrawnBeforeItIsFinished() throws {
        var map = city()
        for stop in [GridPosition(x: 1, y: 3), GridPosition(x: 10, y: 3)] {
            map.placeBuilding(zone: .publicTransit, origin: stop)
        }
        let renderer = IsoTileRenderer(projection: projection)
        XCTAssertNil(renderer.transitDiagram(for: .bus, in: map), "precondition: something was already drawn")

        let draft = TransitRouteDraft(mode: .bus, stops: [GridPosition(x: 1, y: 3), GridPosition(x: 10, y: 3)])
        let diagram = try XCTUnwrap(renderer.transitDiagram(for: .bus, in: map, drawing: draft))
        XCTAssertEqual(named(IsoTileRenderer.transitDraftName, in: diagram), 1)
        XCTAssertEqual(named(IsoTileRenderer.transitLineName, in: diagram), 0,
                       "an uncommitted draft was drawn as a running line")
    }

    /// A draft for the other kind of line is not this view's business.
    func testABusDraftDoesNotAppearInTheSubwayView() throws {
        var map = city()
        for stop in [GridPosition(x: 1, y: 3), GridPosition(x: 10, y: 3)] {
            map.placeBuilding(zone: .publicTransit, origin: stop)
        }
        let draft = TransitRouteDraft(mode: .bus, stops: [GridPosition(x: 1, y: 3), GridPosition(x: 10, y: 3)])
        let renderer = IsoTileRenderer(projection: projection)

        XCTAssertNil(renderer.transitDiagram(for: .subway, in: map, drawing: draft))
    }

    /// A line being edited is drawn once, as the draft — otherwise its old
    /// shape sits underneath the new one and the two disagree about where the
    /// route goes.
    func testAnEditedLineIsNotDrawnTwice() throws {
        var map = city()
        let stops = [GridPosition(x: 1, y: 3), GridPosition(x: 10, y: 3), GridPosition(x: 20, y: 3)]
        let id = line(.bus, in: &map, at: [stops[0], stops[1]])
        map.placeBuilding(zone: .publicTransit, origin: stops[2])

        let renderer = IsoTileRenderer(projection: projection)
        let draft = TransitRouteDraft(mode: .bus, editing: id, stops: stops)
        let diagram = try XCTUnwrap(renderer.transitDiagram(for: .bus, in: map, drawing: draft))

        XCTAssertEqual(named(IsoTileRenderer.transitDraftName, in: diagram), 1)
        XCTAssertEqual(named(IsoTileRenderer.transitLineName, in: diagram), 0,
                       "the line being edited is still drawn in its old shape underneath")
    }

    // MARK: -

    /// `SKColor` equality is colour-space sensitive — SpriteKit converts what
    /// you assign into device RGB — so these compare components.
    private func components(_ color: SKColor) -> [CGFloat] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.usingColorSpace(.deviceRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a].map { ($0 * 1000).rounded() / 1000 }
    }

    private func named(_ name: String, in node: SKNode) -> Int {
        node.children.filter { $0.name == name }.count
    }
}
