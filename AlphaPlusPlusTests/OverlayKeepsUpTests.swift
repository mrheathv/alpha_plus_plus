import XCTest
import SpriteKit
@testable import AlphaPlusPlus

/// A city keeps growing while you are looking at an overlay, and the overlay
/// has to keep up with it.
///
/// **Reported from play:** new buildings, and buildings that had grown a
/// storey, did not appear until you flipped to Normal view and back. An
/// overlay *tints* what is on a tile; it has never built anything — so a lot
/// that changed under one kept whatever sprite it had.
@MainActor
final class OverlayKeepsUpTests: XCTestCase {

    private let lot = GridPosition(x: 2, y: 1)

    private func city() -> CityMap {
        var map = CityMap(width: 12, height: 8)
        for x in 0 ..< 12 { map[GridPosition(x: x, y: 0)].zone = .road }
        map.placeBuilding(zone: .residential, origin: lot)
        for cell in map.footprintCells(origin: lot, size: 2) { map[cell].density = 1 }
        // A tower right beside it, so the water view has something to say.
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 6, y: 1))
        map.waterSupply = Water.computeSupply(for: map)
        return map
    }

    private func scene(_ controller: GameController) -> GameScene {
        let scene = GameScene(controller: controller)
        scene.size = CGSize(width: 800, height: 600)
        let view = SKView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.presentScene(scene)
        scene.rebuildEntireGrid()
        return scene
    }

    private func buildingSprite(_ scene: GameScene, at position: GridPosition) -> SKSpriteNode? {
        scene.tileNodesForTesting[position]?
            .childNode(withName: IsoTileRenderer.buildingNodeName) as? SKSpriteNode
    }

    // MARK: -

    /// **The report.** A lot that grows while a view is up shows its new
    /// building there and then.
    func testABuildingThatGrowsUnderAnOverlayAppearsWithoutFlippingViews() throws {
        let controller = GameController(map: city(), rng: AlwaysZeroRNG(),
                                        peakPopulation: Unlocks.everythingUnlocked)
        controller.overlayMode = .water
        let scene = self.scene(controller)
        scene.refreshAll()

        let before = try XCTUnwrap(buildingSprite(scene, at: lot)).texture
        for cell in controller.map.footprintCells(origin: lot, size: 2) {
            controller.setDensityForTesting(3, at: cell)
        }
        scene.refreshAll()

        let after = try XCTUnwrap(buildingSprite(scene, at: lot)).texture
        XCTAssertNotIdentical(before, after,
                              "the lot grew a storey and the overlay went on drawing the old one")
    }

    /// And a lot that has not changed is not rebuilt, which is the property
    /// the per-tick invalidation used to make impossible — and the reason
    /// this could not simply be fixed by calling `update` before the paint.
    func testAnUnchangedLotIsNotRebuiltEveryTick() throws {
        let controller = GameController(map: city(), rng: AlwaysZeroRNG(),
                                        peakPopulation: Unlocks.everythingUnlocked)
        controller.overlayMode = .water
        let scene = self.scene(controller)
        scene.refreshAll()

        let first = try XCTUnwrap(buildingSprite(scene, at: lot))
        scene.refreshAll()
        scene.refreshAll()
        XCTAssertIdentical(first, buildingSprite(scene, at: lot),
                           "an unchanged lot had its building rebuilt under the overlay")
    }

    /// Changing view still restores everything the last one hid — the
    /// property the per-tick invalidation existed to guarantee, now bought by
    /// invalidating once on the change instead.
    func testLeavingAnOverlayRestoresWhatItHid() throws {
        let controller = GameController(map: city(), rng: AlwaysZeroRNG(),
                                        peakPopulation: Unlocks.everythingUnlocked)
        let scene = self.scene(controller)
        scene.refreshAll()
        XCTAssertNotNil(buildingSprite(scene, at: lot))

        // Land value hides the buildings entirely.
        controller.overlayMode = .landValue
        scene.refreshAll()
        XCTAssertNil(buildingSprite(scene, at: lot), "a heatmap left the buildings standing")

        controller.overlayMode = .none
        scene.refreshAll()
        XCTAssertNotNil(buildingSprite(scene, at: lot),
                        "returning to Normal restored nothing — the stale-key bug, back again")
    }

    /// The same for a lot that appears *while* a heatmap is up: it must be
    /// hidden now and present the moment the player looks at the city again.
    func testALotBuiltUnderAHeatmapIsThereWhenYouLookBack() throws {
        let controller = GameController(map: city(), rng: AlwaysZeroRNG(),
                                        peakPopulation: Unlocks.everythingUnlocked)
        controller.overlayMode = .landValue
        let scene = self.scene(controller)
        scene.refreshAll()

        let fresh = GridPosition(x: 8, y: 1)
        controller.selectedTool = .commercial
        controller.place(at: fresh)
        for cell in controller.map.footprintCells(origin: fresh, size: 2) {
            controller.setDensityForTesting(2, at: cell)
        }
        scene.rebuildEntireGrid()
        scene.refreshAll()
        XCTAssertNil(buildingSprite(scene, at: fresh), "a heatmap drew a building")

        controller.overlayMode = .none
        scene.refreshAll()
        XCTAssertNotNil(buildingSprite(scene, at: fresh),
                        "a lot built under a heatmap never appeared")
    }
}
