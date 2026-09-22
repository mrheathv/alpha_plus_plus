import SpriteKit
import XCTest
@testable import AlphaPlusPlus

/// **A post-process tuned at one zoom is tuned at exactly one zoom.**
///
/// Every term in this grade is fixed in *screen* space, which is physically
/// right — grain is emulsion and aberration is glass, and neither knows how
/// far away the subject is. What changes is the subject: a lit window is about
/// three pixels at the widest camera and forty at the closest, so the same
/// noise sits over a frame full of edges in one case and over a flat facade in
/// the other.
///
/// The bloom's half of this was found and fixed — its reach drifted 33 points
/// to 14 across the zoom range as a side effect of the culling, and it is
/// pinned to 23 now. The grade's half was named and left. This measures it
/// before anything is changed, because this shader has had its mechanism
/// guessed wrong twice already.
@MainActor
final class GradeAcrossZoomTests: XCTestCase {

    private func city() -> CityMap {
        var map = CityMap(width: 28, height: 28)
        for x in 0 ..< 28 where x % 3 == 0 {
            for y in 0 ..< 28 { map[GridPosition(x: x, y: y)].zone = .road }
        }
        var zones: [ZoneType] = [.residential, .commercial, .industrial]
        var index = 0
        for x in stride(from: 1, to: 27, by: 3) {
            for y in stride(from: 1, to: 27, by: 3) {
                let origin = GridPosition(x: x, y: y)
                map.placeBuilding(zone: zones[index % zones.count], origin: origin)
                for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = 5 }
                index += 1
            }
        }
        zones.removeAll()
        return map
    }

    private struct Frame {
        var samples: [CGFloat]
        var width: Int
    }

    /// Reads the rendered frame as a plain array of brightnesses.
    private func shoot(_ scene: GameScene, _ view: SKView) throws -> Frame {
        let size = scene.size
        let texture = try XCTUnwrap(view.texture(from: scene,
                                                 crop: CGRect(origin: .zero, size: size)))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(cgImage: texture.cgImage()))
        var samples: [CGFloat] = []
        samples.reserveCapacity(bitmap.pixelsWide * bitmap.pixelsHigh)
        for y in 0 ..< bitmap.pixelsHigh {
            for x in 0 ..< bitmap.pixelsWide {
                samples.append(bitmap.colorAt(x: x, y: y)?.brightnessComponent ?? 0)
            }
        }
        return Frame(samples: samples, width: bitmap.pixelsWide)
    }

    /// How much a frame varies between neighbouring pixels — the signal the
    /// grain has to sit on top of without swamping.
    private func localContrast(_ frame: Frame) -> CGFloat {
        var total: CGFloat = 0, count: CGFloat = 0
        for index in frame.samples.indices where index % frame.width != frame.width - 1 {
            total += abs(frame.samples[index] - frame.samples[index + 1])
            count += 1
        }
        return count > 0 ? total / count : 0
    }

    /// And how much the grain itself moves each pixel, isolated by rendering
    /// the same frame twice with only that term changed.
    private func difference(_ a: Frame, _ b: Frame) -> CGFloat {
        var total: CGFloat = 0
        for index in a.samples.indices { total += abs(a.samples[index] - b.samples[index]) }
        return a.samples.isEmpty ? 0 : total / CGFloat(a.samples.count)
    }

    func testReportWhatTheGradeCostsAtEachZoom() throws {
        let controller = GameController(map: city(), rng: SeededRNG(seed: 6))
        let scene = GameScene(controller: controller)
        scene.size = CGSize(width: 900, height: 600)
        let view = SKView(frame: NSRect(origin: .zero, size: scene.size))
        view.presentScene(scene)
        scene.rebuildEntireGrid()
        scene.refreshAll()

        // **Let the scene settle, and the first version did not.**
        //
        // A camera move queues work — `cullTilesOutsideTheView` attaches and
        // detaches tiles, and a detail-tier swap queues a few lots a frame
        // rather than redrawing the whole city on the frame the threshold is
        // crossed. One `update` starts that and does not finish it, so every
        // reading was taken on a half-redrawn scene and how half depended on
        // what the previous row had left queued.
        //
        // It showed up as an eightfold grain spike at camera 0.5 — which
        // *moved to camera 3.0 when the sweep was reversed*. That is the
        // benchmark measuring itself, a shape this project has recorded
        // before: the phase-isolated frame timing that reported 768 ms for a
        // five-millisecond frame because it left the scene owing catch-up.
        var clock: TimeInterval = 0
        func settle(_ frames: Int = 200) throws {
            for _ in 0 ..< frames {
                clock += 1.0 / 60
                scene.update(clock)
                if scene.pendingRefreshCountForTesting == 0 { break }
            }
            // **And one throwaway capture.** Draining the queue is not enough:
            // the very first `texture(from:)` after a scene is built comes back
            // different from the second, with nothing changed in between — a
            // measured 0.024 at camera 0.5, which is larger than the whole
            // grain term this test exists to measure. Whatever SpriteKit is
            // doing on that first render, it is not the frame the game draws,
            // and every difference taken against it is noise wearing a
            // signal's clothes.
            _ = try shoot(scene, view)
        }

        print("zoom | local contrast | grain | grain share | aberration | ab. share | mean | dark")
        var shares: [CGFloat] = []
        var fringeShares: [CGFloat] = []
        var grains: [CGFloat] = []
        for scale in [0.5, 0.7, 1.0, 2.0, 3.0] as [CGFloat] {
            scene.setCameraScaleForTesting(scale)
            try settle()

            // Grain off, everything else as the game draws it.
            scene.setShaderUniformForTesting("u_grainStrength", 0)
            scene.setShaderUniformForTesting("u_aberrationStrength", 0)
            let bare = try shoot(scene, view)
            let contrast = localContrast(bare)
            // **Is the frame even stable?** Two captures with nothing changed
            // between them must be identical, or every difference measured
            // below is noise wearing a signal's clothes.
            let again = try shoot(scene, view)
            let drift = difference(bare, again)
            XCTAssertLessThan(drift, 0.0005,
                              String(format: "at camera %.1f two identical captures differ by "
                                     + "%.4f — the frame is not stable, so every number below "
                                     + "it is noise", scale, drift))

            scene.setShaderUniformForTesting("u_grainStrength",
                                             Float(VisualStyle.current.grainStrength))
            let grained = try shoot(scene, view)
            let grain = difference(bare, grained)

            scene.setShaderUniformForTesting("u_grainStrength", 0)
            scene.setShaderUniformForTesting("u_aberrationStrength", 0.2)
            let fringed = try shoot(scene, view)
            let aberration = difference(bare, fringed)

            // Put the scene back the way the game keeps it.
            scene.setShaderUniformForTesting("u_grainStrength",
                                             Float(VisualStyle.current.grainStrength))
            scene.setShaderUniformForTesting("u_aberrationStrength", 0.2)

            fringeShares.append(contrast > 0 ? aberration / contrast : 0)
            grains.append(grain)
            let share = contrast > 0 ? grain / contrast : 0
            shares.append(share)
            let mean = bare.samples.reduce(0, +) / CGFloat(bare.samples.count)
            let dark = CGFloat(bare.samples.filter { $0 < 0.25 }.count)
                / CGFloat(bare.samples.count)
            print(String(format: "%4.1f | %14.4f | %.4f | %11.3f | %10.4f | %.3f | %.3f | %.0f%%",
                         scale, contrast, grain, share, aberration,
                         contrast > 0 ? aberration / contrast : 0, mean, dark * 100))
        }

        print(String(format: "grain share spread %.2f×, aberration share spread %.2f×",
                     (shares.max() ?? 1) / (shares.min() ?? 1),
                     (fringeShares.max() ?? 1) / (fringeShares.min() ?? 1)))

        // **What this pins is that grain stays put.** Its amplitude is a
        // property of the film rather than of the subject, so it must not
        // drift with the camera — which is the same claim
        // `BloomTests.testTheBloomReachesTheSameDistanceAtEveryZoom` makes
        // about the bloom's reach, and the bloom's *did* drift 2.3× before
        // anybody measured it.
        let amplitudes = grains
        XCTAssertLessThan((amplitudes.max() ?? 1) / (amplitudes.min() ?? 1), 2,
                          "grain amplitude moved \(amplitudes) across the zoom range — it is "
                          + "computed per screen pixel and cannot know how far away the subject "
                          + "is, so something has tied it to the camera")

        // And what it deliberately does *not* pin is the share. That number
        // varies because the picture under the grain varies, which is what a
        // camera does: it is 0.08 at the resting camera and 0.23 with the
        // whole city in frame, where most of the screen is unbuilt land. A
        // bound on it would be a bound on how built-out the fixture happens
        // to be.
    }
}
