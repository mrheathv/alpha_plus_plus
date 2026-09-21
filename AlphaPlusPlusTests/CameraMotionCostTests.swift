import SpriteKit
import XCTest
@testable import AlphaPlusPlus

/// **What a frame costs while the camera is moving**, which is a different
/// question from what it costs standing still.
///
/// Reported from play: *"it glitches between the zoom and scroll"* — not a
/// steady low frame rate but a hitch, and specifically while panning or
/// zooming. That points at work which only happens when the view changes, and
/// nothing in this project measured that: every render timing here has been
/// taken on a stationary camera.
@MainActor
final class CameraMotionCostTests: XCTestCase {

    func testWhatMovingTheCameraCosts() throws {
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "needs Apex")
        let map = try CitySaveFile.read(from: url).map
        let controller = GameController(map: map, rng: SeededRNG(seed: 1),
                                        peakPopulation: Unlocks.everythingUnlocked)
        let size = CGSize(width: 1280, height: 800)
        let scene = GameScene(controller: controller)
        scene.size = size
        let view = SKView(frame: NSRect(origin: .zero, size: size))
        view.presentScene(scene)
        scene.rebuildEntireGrid()
        scene.refreshAll()
        controller.isRunning = true
        scene.setCameraScaleForTesting(1.0)
        scene.update(0)

        var clock: TimeInterval = 0

        /// Minimum of several batches, for the reason `RenderTimingTests`
        /// documents: a sample is the true cost plus whatever else the
        /// machine was doing, so the distribution has a floor and no ceiling.
        func best(_ label: String, batches: Int = 4, frames: Int = 30,
                  _ body: (Int) -> Void) -> Double {
            var best = Double.greatestFiniteMagnitude
            for _ in 0 ..< batches {
                let started = Date()
                for frame in 0 ..< frames { body(frame) }
                best = min(best, Date().timeIntervalSince(started) / Double(frames) * 1000)
            }
            print(String(format: "  %-34@ %8.3f ms", label as NSString, best))
            return best
        }

        // **Measured first, on a scene nothing else has poked.** The
        // phase breakdown below drives the camera while running only one
        // phase at a time, which leaves the scene owing a large catch-up
        // — and a run of this that measured *after* it reported 768 ms
        // for a frame that costs five. A benchmark that disturbs the
        // thing it measures is measuring itself.
        //
        // **The frame that crosses the detail threshold**, which is a
        // one-off and therefore invisible to any average. A hitch is not a
        // high mean; it is one frame that takes far too long, and the player
        // feels exactly that frame.
        print("\n=== crossing the near-detail threshold ===")
        for pass in 1 ... 2 {
            scene.setCameraForTesting(scale: 1.0)
            clock += 1 / 60
            scene.update(clock)
            var worst = 0.0
            var worstAt: CGFloat = 0
            for step in 0 ..< 40 {
                let target = 1.0 - CGFloat(step) * 0.0125   // 1.0 down to 0.5
                scene.setCameraScaleForTesting(target)
                clock += 1 / 60
                let started = Date()
                scene.update(clock)
                let ms = Date().timeIntervalSince(started) * 1000
                if ms > worst { worst = ms; worstAt = target }
            }
            print(String(format: "  pass %d: worst frame %7.1f ms at camera %.3f",
                         pass, worst, worstAt))
            // **A hitch is one frame, not an average**, which is why this
            // asserts on the maximum. Sixteen milliseconds is one frame at
            // 60fps: past it the player has visibly dropped one, and at the
            // 49 ms this measured before the refresh queue they dropped three
            // every time they crossed the threshold.
            XCTAssertLessThan(worst, 16,
                              "a frame of a pinch took \(worst) ms — zooming is dropping "
                              + "frames, which is what 'it glitches between the zoom and "
                              + "scroll' means")
        }


        print("\n=== update() only, 64×64 ===")
        scene.setCameraForTesting(scale: 1.0)
        let still = best("camera still") { _ in
            clock += 1 / 60
            scene.update(clock)
        }
        let panning = best("panning") { frame in
            clock += 1 / 60
            // A steady drag, the speed a player actually scrolls at.
            scene.nudgeCameraForTesting(by: CGPoint(x: frame.isMultiple(of: 2) ? 9 : 9, y: 0))
            scene.update(clock)
        }
        scene.setCameraForTesting(scale: 1.0)
        let zooming = best("zooming") { frame in
            clock += 1 / 60
            // A pinch across the middle of the range and back.
            let t = Double(frame) / 30
            scene.setCameraScaleForTesting(CGFloat(0.9 + 0.5 * sin(t * .pi)))
            scene.update(clock)
        }

        // Which phase a zoom is paying for. Each is driven with the same
        // camera movement, so the numbers are comparable to each other.
        print("\n=== a zooming frame, phase by phase ===")
        func phase(_ label: String, _ body: @escaping () -> Void) {
            scene.setCameraForTesting(scale: 1.0)
            var frame = 0
            _ = best(label) { _ in
                frame += 1
                let t = Double(frame % 30) / 30
                scene.setCameraScaleForTesting(CGFloat(0.9 + 0.5 * sin(t * .pi)))
                body()
            }
        }
        phase("camera move alone") {}
        phase("+ culling") { scene.runCullingForTesting() }
        phase("+ backdrop clip") { scene.runBackdropClipForTesting() }
        phase("+ bloom reach") { scene.runBloomReachForTesting() }
        phase("+ detail tier") { scene.runDetailTierForTesting() }

        print("""

          still   \(String(format: "%.3f", still)) ms
          panning \(String(format: "%.3f", panning)) ms  (\(String(format: "%.1f", panning / max(still, 0.001)))× still)
          zooming \(String(format: "%.3f", zooming)) ms  (\(String(format: "%.1f", zooming / max(still, 0.001)))× still)
        """)
    }
}
