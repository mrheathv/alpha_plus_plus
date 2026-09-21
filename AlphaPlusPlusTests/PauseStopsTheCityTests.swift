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

    private var _clock: TimeInterval = 0

    private func animated(in scene: GameScene, named name: String) -> [SKNode] {
        scene.tileNodesForTesting.values.flatMap { $0.children.filter { $0.name == name } }
    }

    // MARK: -

    /// Where every ambient car currently is.
    private func carPositions(in scene: GameScene) -> [CGPoint] {
        animated(in: scene, named: GameScene.trafficCarNodeNameForTesting).map(\.position)
    }

    /// Steps the scene a few frames at a real cadence.
    ///
    /// **Stepped, not jumped**: `GameScene.update` clamps its own delta with
    /// `min(currentTime - last, 0.1)`, so a single call a second later
    /// advances the world by a tenth of a second. Anything driving this clock
    /// from outside has to supply a cadence.
    private func step(_ scene: GameScene, frames: Int) {
        for _ in 0 ..< frames {
            clock += 1.0 / 60
            scene.update(clock)
        }
    }
    private var clock: TimeInterval {
        get { _clock } set { _clock = newValue }
    }

    /// **The report.** Cars stop when the city does, and drive again when it
    /// resumes.
    ///
    /// **Restated when the traffic moved off `SKAction`.** This used to assert
    /// on `SKNode.isPaused`, which was never the property anybody wanted — it
    /// was the *mechanism* that delivered it, and cars are now driven per
    /// frame from `update` instead, so they stop because nothing advances
    /// them rather than because they were told to. Asserting on where the car
    /// actually is survives that change and would have survived the previous
    /// one too, which is the argument for writing it this way round.
    func testCarsStopWhenTheCityIsPaused() {
        let controller = GameController(map: busyCity(), rng: AlwaysZeroRNG(),
                                        peakPopulation: Unlocks.everythingUnlocked)
        controller.isRunning = true
        let scene = self.scene(controller)
        scene.refreshAll()
        step(scene, frames: 1)

        XCTAssertFalse(carPositions(in: scene).isEmpty,
                       "precondition: this street draws no cars at all")

        let running = carPositions(in: scene)
        step(scene, frames: 30)
        let stillRunning = carPositions(in: scene)
        XCTAssertNotEqual(running, stillRunning, "a running city had its traffic stopped")

        controller.isRunning = false
        step(scene, frames: 2)
        let paused = carPositions(in: scene)
        step(scene, frames: 30)
        XCTAssertEqual(paused, carPositions(in: scene),
                       "the traffic kept driving around a paused city")

        controller.isRunning = true
        step(scene, frames: 30)
        XCTAssertNotEqual(paused, carPositions(in: scene), "the traffic never started again")
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
    ///
    /// This was the awkward case under the old design: a car built during a
    /// pause had never been through `applyAnimationPause`, so it drove off the
    /// moment it appeared unless something remembered to catch it. Driving the
    /// cars per frame deletes the whole class — there is no "start" to miss,
    /// because nothing moves them until a running `update` does. The test
    /// stays because the *property* still matters and the next mechanism
    /// might not be so forgiving.
    func testTrafficBuiltWhilePausedStartsStopped() {
        let controller = GameController(map: busyCity(), rng: AlwaysZeroRNG(),
                                        peakPopulation: Unlocks.everythingUnlocked)
        let scene = self.scene(controller)
        controller.isRunning = false
        step(scene, frames: 1)
        // Now build it all, with the game stopped.
        scene.refreshAll()

        let built = carPositions(in: scene)
        XCTAssertFalse(built.isEmpty)
        step(scene, frames: 30)
        XCTAssertEqual(built, carPositions(in: scene),
                       "a car built during a pause drove off immediately")
    }
}
