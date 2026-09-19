import XCTest
import SpriteKit
@testable import AlphaPlusPlus

/// A pipe goes under anything — and, until this, was invisible wherever it did.
///
/// **Reported from play as "you can't put a pipe under a building".** It was
/// never a placement rule: the pipe was laid, it was live, and it supplied
/// water. It simply had nowhere to be *drawn*, because a scene node exists per
/// building rather than per tile, so the three cells of a 2×2 that are not its
/// anchor had no node of their own. A run laid across a block appeared on the
/// bare ground either side and vanished in the middle — and the visible
/// neighbours still drew a stub pointing into the gap, so it read as severed
/// rather than hidden.
@MainActor
final class BuriedUnderBuildingsTests: XCTestCase {

    private let projection = Isometric(tileWidth: 32)

    /// A tower at the left, a 2×2 block in the middle, and bare ground either
    /// side — so a run straight across covers both kinds of tile.
    private func blockOnAStreet() -> CityMap {
        var map = CityMap(width: 20, height: 12)
        for x in 0 ..< 20 { map[GridPosition(x: x, y: 0)].zone = .road }
        // Sitting *on* the run, so the main it feeds is actually connected —
        // and far enough from the block that `directSupplyRadius` cannot
        // supply it, which would make the pipe irrelevant to the test.
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 0, y: 2))
        let home = GridPosition(x: 6, y: 3)
        map.placeBuilding(zone: .residential, origin: home)
        for cell in map.footprintCells(origin: home, size: 2) { map[cell].density = 3 }
        return map
    }

    private let block = GridPosition(x: 6, y: 3)
    private var covered: GridPosition { GridPosition(x: 7, y: 3) }  // not the anchor

    // MARK: - It always worked; it was never drawn

    /// The half that was never broken, pinned so a future "fix" cannot make
    /// it a placement rule by mistake.
    func testAPipeGoesUnderABuildingAndCarriesWater() {
        let controller = GameController(map: blockOnAStreet(), rng: AlwaysZeroRNG(),
                                        peakPopulation: Unlocks.everythingUnlocked)
        for x in 0 ... 8 {
            XCTAssertEqual(controller.layPipe(at: GridPosition(x: x, y: 3)), .placed,
                           "laying pipe at x=\(x) was refused")
        }

        XCTAssertTrue(controller.map[covered].hasPipe)
        XCTAssertFalse(controller.map[covered].isBuildingAnchor, "precondition: this cell has a node")
        XCTAssertTrue(controller.map.waterSupply.isSupplied(at: covered),
                      "a pipe under a building is not part of the network")
        XCTAssertTrue(Water.hasSupply(at: block, in: controller.map))
    }

    // MARK: - And now it is drawn

    /// **The bug.** Every cell of the building that carries a pipe gets a
    /// segment, so a run across a block is continuous on screen.
    func testEveryCoveredCellCarryingAPipeIsDrawn() {
        var map = blockOnAStreet()
        for x in 0 ... 8 { map[GridPosition(x: x, y: 3)].hasPipe = true }
        map.waterSupply = Water.computeSupply(for: map)

        let renderer = IsoTileRenderer(projection: projection)
        let node = renderer.makeNode(for: map[block])
        renderer.syncConduits(on: node, isPipe: true, segments: [
            IsoTileRenderer.Segment(offset: GridPosition(x: 0, y: 0),
                                    mask: Infrastructure.conduitMask(at: block, in: map, isPipe: true),
                                    live: true),
            IsoTileRenderer.Segment(offset: GridPosition(x: 1, y: 0),
                                    mask: Infrastructure.conduitMask(at: covered, in: map, isPipe: true),
                                    live: true),
        ])

        let drawn = node.children.filter { $0.name == IsoTileRenderer.pipeNodeName }
        XCTAssertEqual(drawn.count, 2, "a building drew only one cell's worth of pipe")
        // And the second is offset from the first by exactly one tile east,
        // which is what puts it over the ground it is actually buried under.
        let shift = projection.project(1, 0, 0)
        let positions = drawn.map(\.position).sorted { $0.x < $1.x }
        XCTAssertEqual(positions[1].x - positions[0].x, shift.x, accuracy: 0.01)
        XCTAssertEqual(positions[1].y - positions[0].y, shift.y, accuracy: 0.01)
    }

    /// Cells without a pipe draw nothing, so a building standing over one
    /// corner of a run does not sprout three phantom segments.
    func testOnlyTheCellsThatCarryOneAreDrawn() {
        var map = blockOnAStreet()
        map[block].hasPipe = true
        map.waterSupply = Water.computeSupply(for: map)

        let renderer = IsoTileRenderer(projection: projection)
        let node = renderer.makeNode(for: map[block])
        renderer.syncConduits(on: node, isPipe: true, segments: [
            IsoTileRenderer.Segment(offset: GridPosition(x: 0, y: 0), mask: 0, live: false),
        ])
        XCTAssertEqual(node.children.filter { $0.name == IsoTileRenderer.pipeNodeName }.count, 1)
    }

    /// Leaving the overlay takes them all away — every one, not just the
    /// anchor's. A stale segment would leave a pipe drawn over a city in
    /// Normal view, which is how an overlay bug hides.
    func testLeavingTheOverlayClearsEverySegment() {
        let renderer = IsoTileRenderer(projection: projection)
        let node = renderer.makeNode(for: blockOnAStreet()[block])
        renderer.syncConduits(on: node, isPipe: true, segments: [
            IsoTileRenderer.Segment(offset: GridPosition(x: 0, y: 0), mask: 3, live: true),
            IsoTileRenderer.Segment(offset: GridPosition(x: 1, y: 0), mask: 3, live: true),
        ])
        XCTAssertEqual(node.children.filter { $0.name == IsoTileRenderer.pipeNodeName }.count, 2)

        renderer.syncConduits(on: node, isPipe: true, segments: [])
        XCTAssertTrue(node.children.filter { $0.name == IsoTileRenderer.pipeNodeName }.isEmpty)
    }

    /// The cache key has to see *every* segment, or a change under one cell
    /// of a block would be skipped as "already up to date" — which is the
    /// same class of bug as the stale keys an overlay has to invalidate.
    func testAChangeUnderOneCellIsNotMistakenForNoChange() {
        let renderer = IsoTileRenderer(projection: projection)
        let node = renderer.makeNode(for: blockOnAStreet()[block])
        let first = IsoTileRenderer.Segment(offset: GridPosition(x: 0, y: 0), mask: 3, live: true)

        renderer.syncConduits(on: node, isPipe: true, segments: [first])
        renderer.syncConduits(on: node, isPipe: true, segments: [
            first,
            IsoTileRenderer.Segment(offset: GridPosition(x: 1, y: 0), mask: 3, live: true),
        ])
        XCTAssertEqual(node.children.filter { $0.name == IsoTileRenderer.pipeNodeName }.count, 2,
                       "a second segment appearing was mistaken for no change at all")
    }
}
