import SpriteKit
import XCTest
@testable import AlphaPlusPlus

/// **What oversampling costs to draw, measured in one process.**
///
/// Reported from play the day `oversample` went to 4 and the near-detail tier
/// landed: the game is running really slow. Comparing against numbers recorded
/// hours earlier would have been worthless — this machine throttles under a
/// long test run, so two readings taken an hour apart say more about its
/// temperature than about any change. Every variant here is measured back to
/// back, in one process, on one city.
@MainActor
final class OversampleCostTests: XCTestCase {

    func testWhatTheTexturesCostToDraw() throws {
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "needs the Apex city")
        let map = try CitySaveFile.read(from: url).map
        let size = CGSize(width: 1280, height: 800)

        let original = (IsoTextureCache.oversample, IsoTextureCache.usesMipmaps)
        defer {
            IsoTextureCache.oversample = original.0
            IsoTextureCache.usesMipmaps = original.1
        }

        func measure(oversample: CGFloat, mipmaps: Bool) -> (ms: Double, mb: Double) {
            IsoTextureCache.oversample = oversample
            IsoTextureCache.usesMipmaps = mipmaps
            let controller = GameController(map: map, rng: SeededRNG(seed: 1),
                                            peakPopulation: Unlocks.everythingUnlocked)
            let scene = GameScene(controller: controller)
            scene.size = size
            let view = SKView(frame: NSRect(origin: .zero, size: size))
            view.presentScene(scene)
            scene.rebuildEntireGrid()
            scene.refreshAll()
            scene.update(0)
            // Warm, so the first frame's texture uploads are not in the
            // number.
            for _ in 0 ..< 5 { _ = view.texture(from: scene) }
            var best = Double.greatestFiniteMagnitude
            for _ in 0 ..< 3 {
                let started = Date()
                for _ in 0 ..< 20 { _ = view.texture(from: scene) }
                best = min(best, Date().timeIntervalSince(started) / 20 * 1000)
            }
            let mb = Double(scene.tileRendererForTesting.textures.approximateBytes) / 1_048_576
            return (best, mb)
        }

        print("\n=== drawing a 64×64 city at 1280×800 ===")
        print("oversample  mipmaps   ms/frame   texture MB")
        var results: [(CGFloat, Bool, Double)] = []
        for (oversample, mipmaps) in [(CGFloat(4), true), (CGFloat(4), false),
                                      (CGFloat(2), true), (CGFloat(1), false)] {
            let r = measure(oversample: oversample, mipmaps: mipmaps)
            results.append((oversample, mipmaps, r.ms))
            print(String(format: "%9.0f×  %-8@ %8.2f   %9.1f",
                         oversample, (mipmaps ? "yes" : "no") as NSString, r.ms, r.mb))
        }

        // The claim this test exists to keep honest: mipmaps must not make
        // drawing *slower*, and at 4× they should make it faster, because a
        // screen pixel covering sixteen texels is the case they exist for.
        let with = results.first { $0.0 == 4 && $0.1 }?.2 ?? 0
        let without = results.first { $0.0 == 4 && !$0.1 }?.2 ?? 0
        XCTAssertLessThan(with, without * 1.05,
                          "mipmaps made a 4× oversampled city slower to draw (\(with) against "
                          + "\(without) ms) — the minification they exist for is not happening")
    }
}
