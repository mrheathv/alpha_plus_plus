import XCTest
import SpriteKit
@testable import AlphaPlusPlus

/// Pausing stops the city, not the player.
///
/// Reported from play: the ambient traffic kept driving around a paused map.
/// `GameScene.update` returns early when paused, but `SKAction`s are run by
/// SpriteKit itself and never went near it — so the simulation stopped and the
/// decorations carried on.
@MainActor
final class PauseStopsTheCityTests: XCTestCase {

    /// A street with enough traffic on it to draw cars, and a block alight.
    private func busyCity() -> CityMap {
        var map = CityMap(width: 14, height: 8)
        for x in 0 ..< 14 { map[GridPosition(x: x, y: 3)].zone = .road }
        let home = GridPosition(x: 0, y: 4)
        map.placeBuilding(zone: .residential, origin: home)
        for cell in map.footprintCells(origin: home, size: 2) { map[cell].density = 5 }
        let shop = GridPosition(x: 11, y: 4)
        map.placeBuilding(zone: .commercial, origin: shop)
        for cell in map.footprintCells(origin: shop, size: 2) { map[cell].density = 5 }
        for cell in map.footprintCells(origin: shop, size: 2) { map[cell].fireTicks = 2 }
        map.trafficLoad = Traffic.computeLoad(for: map)
        return map
    }

    private func scene(_ controller: GameController) -> GameScene {
        let scene = GameScene(controller: controller)
        scene.size = CGSize(width: 800, height: 600)
        scene.didMove(to: SKView(frame: NSRect(x: 0, y: 0, width: 800, height: 600)))
        return scene
    }

    private func animated(in scene: GameScene, named name: String) -> [SKNode] {
        scene.tileNodesForTesting.values.flatMap { $0.children.filter { $0.name == name } }
    }

    // MARK: -

    /// **The report.** Cars stop when the city does, and drive again when it
    /// resumes.
    func testCarsStopWhenTheCityIsPaused() {
        let controller = GameController(map: busyCity(), rng: AlwaysZeroRNG(),
                                        peakPopulation: Unlocks.everythingUnlocked)
        controller.isRunning = true
        let scene = self.scene(controller)
        scene.refreshAll()
        scene.update(0)

        let cars = animated(in: scene, named: GameScene.trafficCarNodeNameForTesting)
        XCTAssertFalse(cars.isEmpty, "precondition: this street draws no cars at all")
        XCTAssertTrue(cars.allSatisfy { !$0.isPaused }, "a running city had its traffic stopped")

        controller.isRunning = false
        scene.update(1)
        XCTAssertTrue(animated(in: scene, named: GameScene.trafficCarNodeNameForTesting)
            .allSatisfy(\.isPaused), "the traffic kept driving around a paused city")

        controller.isRunning = true
        scene.update(2)
        XCTAssertTrue(animated(in: scene, named: GameScene.trafficCarNodeNameForTesting)
            .allSatisfy { !$0.isPaused }, "the traffic never started again")
    }

    /// The same rule for anything else the simulation is driving — a flame
    /// flickering over a stopped city is the same complaint wearing a
    /// different hat.
    func testFlamesStopToo() {
        let controller = GameController(map: busyCity(), rng: AlwaysZeroRNG(),
                                        peakPopulation: Unlocks.everythingUnlocked)
        let scene = self.scene(controller)
        scene.refreshAll()

        let flames = animated(in: scene, named: IsoTileRenderer.fireNodeName)
        XCTAssertFalse(flames.isEmpty, "precondition: nothing in this fixture is alight")
        controller.isRunning = false
        scene.update(1)
        XCTAssertTrue(animated(in: scene, named: IsoTileRenderer.fireNodeName).allSatisfy(\.isPaused))
    }

    /// **And the player is not paused.** A placement flash is an `SKAction`
    /// too, and it answers a *click* — which is exactly the thing you do while
    /// the game is stopped. Pausing the tile layer wholesale would have left
    /// it stuck on the map, never fading and never removing itself.
    func testTheFeedbackFlashStillRunsWhilePaused() {
        let controller = GameController(map: busyCity(), rng: AlwaysZeroRNG(),
                                        peakPopulation: Unlocks.everythingUnlocked)
        controller.isRunning = false
        let scene = self.scene(controller)
        scene.refreshAll()
        scene.update(1)

        let node = try! XCTUnwrap(scene.tileNodesForTesting.values.first)
        XCTAssertFalse(node.isPaused, "a whole tile was paused, which would freeze its flashes too")
        XCTAssertFalse(scene.isPaused, "the scene was paused, which takes the camera with it")
    }

    /// A tile refreshed *while* paused — which is what a placement does —
    /// must not start driving.
    func testTrafficBuiltWhilePausedStartsStopped() {
        let controller = GameController(map: busyCity(), rng: AlwaysZeroRNG(),
                                        peakPopulation: Unlocks.everythingUnlocked)
        let scene = self.scene(controller)
        controller.isRunning = false
        scene.update(1)
        // Now build it all, with the game stopped.
        scene.refreshAll()

        let cars = animated(in: scene, named: GameScene.trafficCarNodeNameForTesting)
        XCTAssertFalse(cars.isEmpty)
        XCTAssertTrue(cars.allSatisfy(\.isPaused),
                      "a car built during a pause drove off immediately")
    }
}
