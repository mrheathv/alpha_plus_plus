import SpriteKit
import XCTest
@testable import AlphaPlusPlus

/// `GameScene.rebuildRegion(around:)` replaces a full-map rebuild on every
/// click. It is only safe if it leaves the scene in exactly the state the full
/// rebuild would have — so that is what these assert, rather than trusting the
/// radius arithmetic to be right by inspection.
@MainActor
final class GameSceneRebuildTests: XCTestCase {

    /// A tile's node must sit exactly where the projection says that tile is.
    ///
    /// **Why this is worth a test of its own.** Clicks are converted with
    /// `event.location(in: self)` — *scene* coordinates — and then handed to
    /// `Isometric.position(for:in:)`, which assumes the projection's origin is
    /// the scene's origin. That holds only because `tileLayer` and the effect
    /// node above it both sit at zero. Give either one a position — to inset
    /// the map, say, or to centre it — and every click silently lands on the
    /// wrong tile while the map still looks perfect. Nothing else in the suite
    /// would notice.
    func testTileNodesSitWhereTheProjectionSaysTheyDo() {
        let (scene, _) = makeScene()
        let projection = Isometric()
        var checked = 0

        for (position, node) in scene.tileNodesForTesting {
            // Where the node actually is, in scene coordinates.
            let inScene = node.parent.map { $0.convert(node.position, to: scene) } ?? node.position
            XCTAssertEqual(inScene.x, projection.project(CGFloat(position.x), CGFloat(position.y), 0).x,
                           accuracy: 0.01, "tile (\(position.x), \(position.y)) is not where it is projected")
            XCTAssertEqual(inScene.y, projection.project(CGFloat(position.x), CGFloat(position.y), 0).y,
                           accuracy: 0.01, "tile (\(position.x), \(position.y)) is not where it is projected")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 20, "expected a populated scene to check against")
    }

    private func makeScene(size: Int = 24) -> (GameScene, GameController) {
        let spec = PlaytestHarness.CitySpec(size: size)
        let controller = GameController(
            map: PlaytestHarness.buildCity(spec),
            rng: SeededRNG(seed: 1),
            peakPopulation: Unlocks.everythingUnlocked
        )
        for _ in 0 ..< 10 { controller.advanceSimulation() }

        let scene = GameScene(controller: controller)
        let view = SKView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.presentScene(scene)
        scene.rebuildEntireGrid()
        return (scene, controller)
    }

    /// Every sprite the map should have, by anchor position.
    private func expectedAnchors(in map: CityMap) -> Set<GridPosition> {
        Set(map.tiles.filter(\.isBuildingAnchor).map(\.position))
    }

    private func actualNodes(in scene: GameScene) -> Set<GridPosition> {
        Set(scene.tileNodesForTesting.keys)
    }

    /// Placing a 2×2 zone turns four single-tile anchors into one, which is
    /// precisely the change a per-tile refresh cannot express and why a
    /// rebuild is needed at all.
    func testRegionRebuildMatchesAFullRebuildAfterPlacingAFootprint() {
        let (scene, controller) = makeScene()
        let target = GridPosition(x: 10, y: 10)
        for cell in controller.map.footprintCells(origin: target, size: 3) {
            controller.bulldoze(at: cell)
        }
        scene.rebuildEntireGrid()

        controller.selectTool(.residential)
        XCTAssertEqual(controller.place(at: target), .placed)

        scene.rebuildRegion(around: target)
        let afterRegion = actualNodes(in: scene)

        scene.rebuildEntireGrid()
        let afterFull = actualNodes(in: scene)

        XCTAssertEqual(afterRegion, afterFull, "a bounded rebuild left a different set of sprites")
        XCTAssertEqual(afterRegion, expectedAnchors(in: controller.map))
    }

    /// Bulldozing a multi-tile building is the opposite case: one anchor
    /// becomes several, and the cleared building's own sprite has to go.
    func testRegionRebuildMatchesAFullRebuildAfterBulldozingAFootprint() {
        let (scene, controller) = makeScene()
        guard let anchor = controller.map.tiles.first(where: {
            $0.isBuildingAnchor && $0.zone.footprintSize > 1
        })?.position else {
            return XCTFail("the fixture has no multi-tile building to bulldoze")
        }

        controller.bulldoze(at: anchor)
        scene.rebuildRegion(around: anchor)
        let afterRegion = actualNodes(in: scene)

        scene.rebuildEntireGrid()
        XCTAssertEqual(afterRegion, actualNodes(in: scene))
    }

    /// The case the radius exists for: a new building overlapping an older one
    /// whose *anchor* sits outside the footprint that was clicked. A radius
    /// too small would leave that building's sprite behind as a ghost.
    func testRegionRebuildClearsAnOverlappedBuildingsAnchorOutsideTheFootprint() {
        let (scene, controller) = makeScene()
        let origin = GridPosition(x: 6, y: 6)
        for cell in controller.map.footprintCells(origin: GridPosition(x: 4, y: 4), size: 8) {
            controller.bulldoze(at: cell)
        }
        scene.rebuildEntireGrid()

        // A 3×3 plant whose anchor is two tiles back from where we then click.
        controller.selectTool(.powerPlant)
        XCTAssertEqual(controller.place(at: origin), .placed)
        scene.rebuildRegion(around: origin)
        XCTAssertTrue(actualNodes(in: scene).contains(origin))

        // Clearing any cell of it clears the whole building, anchor included.
        let farCell = GridPosition(x: origin.x + 2, y: origin.y + 2)
        controller.bulldoze(at: farCell)
        scene.rebuildRegion(around: farCell)

        // Not "the sprite is gone" — every empty tile is its own anchor and so
        // still has a sprite. What matters is that the scene agrees with the
        // map about *what* is there, which a stale 3×3 plant sprite left
        // behind by too small a radius would break.
        let afterRegion = actualNodes(in: scene)
        scene.rebuildEntireGrid()
        XCTAssertEqual(
            afterRegion, actualNodes(in: scene),
            "the bounded rebuild disagreed with a full one about an overlapped building's anchor"
        )
        XCTAssertEqual(controller.map[origin].zone, .empty, "the plant was not actually cleared")
    }

    /// Rebuilding a region twice must not duplicate sprites — a stale node
    /// left in the layer would draw on top of its replacement.
    func testRebuildingTheSameRegionTwiceIsIdempotent() {
        let (scene, _) = makeScene()
        let target = GridPosition(x: 12, y: 12)

        scene.rebuildRegion(around: target)
        let once = actualNodes(in: scene)
        let onceChildCount = scene.tileLayerChildCountForTesting

        scene.rebuildRegion(around: target)

        XCTAssertEqual(actualNodes(in: scene), once)
        XCTAssertEqual(scene.tileLayerChildCountForTesting, onceChildCount, "a repeat rebuild duplicated sprites")
    }
}
