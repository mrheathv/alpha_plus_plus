import SpriteKit
import XCTest
@testable import AlphaPlusPlus

@MainActor
final class FrameCostDiagnosticTests: XCTestCase {
    func testWhatUpdateCosts() throws {
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        let map = try CitySaveFile.read(from: url).map
        let controller = GameController(map: map, rng: SeededRNG(seed: 1),
                                        peakPopulation: Unlocks.everythingUnlocked)
        let size = CGSize(width: 1600, height: 1000)
        let scene = GameScene(controller: controller)
        scene.size = size
        let view = SKView(frame: NSRect(origin: .zero, size: size))
        view.presentScene(scene)
        scene.rebuildEntireGrid()
        scene.refreshAll()
        controller.isRunning = true
        scene.setCameraScaleForTesting(1.0)
        scene.update(0)

        func best(_ label: String, _ body: () -> Void) {
            var best = Double.greatestFiniteMagnitude
            for _ in 0 ..< 5 {
                let started = Date()
                for _ in 0 ..< 30 { body() }
                best = min(best, Date().timeIntervalSince(started) / 30 * 1000)
            }
            print(String(format: "  %-42@ %7.3f ms", label as NSString, best))
        }

        print("\n=== per-frame cost on a built-out 64×64 city ===")
        var clock: TimeInterval = 1
        best("scene.update() — everything") {
            clock += 1 / 60
            scene.update(clock)
        }
        best("retroEffectLayer.calculateAccumulatedFrame()") {
            _ = scene.postProcessAreaForTesting
        }
        print("  nodes in the scene: \(scene.children.reduce(0) { $0 + 1 + countAll($1) })")
    }

    private func countAll(_ node: SKNode) -> Int {
        node.children.reduce(node.children.count) { $0 + countAll($1) }
    }
}
