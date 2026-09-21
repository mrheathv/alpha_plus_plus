import XCTest
import SpriteKit
@testable import AlphaPlusPlus

/// **What resolution the post-process actually runs at.**
///
/// Reported from play once the buildings themselves got sharp: the windows
/// look pixelated when you zoom in. They are not pixelated in the texture —
/// the same frame with the shader switched off is crisp — so the softness is
/// being introduced by the pass on top.
///
/// The suspicion is that an `SKEffectNode` renders its children into a target
/// sized from their extent **in scene points**, which the camera then scales.
/// Zoom in past 1.0 and that target is magnified rather than re-rendered, so
/// every shaded pixel covers more than one screen pixel.
///
/// **Measured, and the suspicion was wrong.** The grain is computed once per
/// fragment of the pass, so it makes a ruler: at screen resolution every
/// output pixel gets its own value and neighbours almost never match, and if
/// the pass were being magnified the noise would come in blocks. It reads
/// 1.7–2.9% near-identical neighbours at every zoom from 0.5 to 3.0 — no
/// blocks, so the pass is running at full screen resolution and the target is
/// *not* sized in world points the way `u_bloomRadius` turned out to be.
///
/// So the softness at close zoom is the pass's own effects rather than its
/// resolution: chromatic aberration fringing every edge, the bloom's halo
/// over it, and grain on top. All three are fixed in *screen* space while the
/// thing being photographed changes size sixfold across the zoom range — a
/// window is three pixels at the widest camera and forty at the closest, so
/// the grade that reads as film texture on a whole-city frame reads as dirt
/// on the glass up close. That is a tuning question, not a resolution one,
/// and raising texture resolution cannot touch it.
///
/// This is kept as a standing test because the invariant is worth pinning:
/// anything that makes the pass render coarser — `shouldRasterize` on the
/// effect layer, most obviously — would soften the whole game with nothing
/// else failing.
@MainActor
final class ShaderResolutionTests: XCTestCase {

    private func city() -> CityMap {
        var map = CityMap(width: 16, height: 16)
        for x in 0 ..< 16 { map[GridPosition(x: x, y: 7)].zone = .road }
        for x in stride(from: 1, to: 14, by: 3) {
            for y in stride(from: 1, to: 6, by: 3) {
                map.placeBuilding(zone: .commercial, origin: GridPosition(x: x, y: y))
                for cell in map.footprintCells(origin: GridPosition(x: x, y: y), size: 2) {
                    map[cell].density = 5
                }
            }
        }
        return map
    }

    /// **The grain is a ruler.** It is computed once per fragment of the
    /// post-process pass, so if that pass runs at screen resolution every
    /// output pixel gets its own value and neighbours almost never match. If
    /// the pass runs at some coarser resolution and is then scaled up, the
    /// noise comes in blocks and neighbours match often.
    ///
    /// Reported as the fraction of horizontally-adjacent pixel pairs that are
    /// near-identical. High means the shading is being magnified.
    private func flatPairFraction(_ bitmap: NSBitmapImageRep) -> Double {
        var flat = 0, total = 0
        for y in stride(from: 4, to: bitmap.pixelsHigh - 4, by: 3) {
            for x in stride(from: 4, to: bitmap.pixelsWide - 5, by: 2) {
                guard let a = bitmap.colorAt(x: x, y: y),
                      let b = bitmap.colorAt(x: x + 1, y: y) else { continue }
                total += 1
                if abs(a.brightnessComponent - b.brightnessComponent) < 0.002 { flat += 1 }
            }
        }
        return total == 0 ? 0 : Double(flat) / Double(total)
    }

    func testMeasureShadedResolutionAcrossZoom() throws {
        let controller = GameController(map: city(), rng: SeededRNG(seed: 4))
        let size = CGSize(width: 800, height: 500)
        let scene = GameScene(controller: controller)
        scene.size = size
        let view = SKView(frame: NSRect(origin: .zero, size: size))
        view.presentScene(scene)
        scene.rebuildEntireGrid()
        scene.refreshAll()
        scene.centerCameraForTesting(on: GridPosition(x: 7, y: 3))

        func shot() throws -> NSBitmapImageRep {
            for step in 0 ..< 3 { scene.update(TimeInterval(step) / 60) }
            let t = try XCTUnwrap(view.texture(from: scene,
                                               crop: CGRect(origin: .zero, size: size)))
            return NSBitmapImageRep(cgImage: t.cgImage())
        }

        print("\n=== is the post-process running at screen resolution? ===")
        print("camera   flat adjacent pairs   shaded area (world pt)")
        for scale in [0.5, 1.0, 2.0, 3.0] as [CGFloat] {
            scene.setCameraScaleForTesting(scale)
            scene.setPostProcessEnabledForTesting(true)
            // Grain alone, turned well up, so the noise is the only thing
            // varying between neighbouring pixels.
            scene.setShaderUniformForTesting("u_bloomStrength", 0)
            scene.setShaderUniformForTesting("u_scanlineStrength", 0)
            scene.setShaderUniformForTesting("u_grainStrength", 0.35)
            let flat = flatPairFraction(try shot())
            let area = scene.postProcessAreaForTesting
            print(String(format: "%5.1f    %17.1f%%   %7.0f × %-7.0f",
                         scale, flat * 100, area.width, area.height))
            XCTAssertLessThan(flat, 0.20,
                              "at camera \(scale) the grain comes in blocks (\(flat * 100)% of "
                              + "neighbours identical) — the post-process is being magnified "
                              + "rather than rendered at screen resolution")
        }
    }
}
