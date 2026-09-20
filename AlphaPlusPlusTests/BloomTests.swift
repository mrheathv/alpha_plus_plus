import XCTest
import SpriteKit
@testable import AlphaPlusPlus

/// **What the bloom does to a frame, measured rather than looked at.**
///
/// Reported from play, on a close-zoom screenshot: buildings look translucent
/// where they crowd together. They are not — the geometry is opaque, and the
/// same frame with the post-process switched off is completely solid. Both
/// causes were in this one pass, and both were invisible on the whole-city
/// frames it was built and reviewed against.
@MainActor
final class BloomTests: XCTestCase {

    private func cityWithSomeTowers() -> CityMap {
        var map = CityMap(width: 20, height: 20)
        for x in 1 ..< 19 where x % 3 == 0 {
            for y in 1 ..< 19 { map[GridPosition(x: x, y: y)].zone = .road }
        }
        for x in stride(from: 1, to: 18, by: 3) {
            for y in stride(from: 1, to: 18, by: 3) {
                map.placeBuilding(zone: .commercial, origin: GridPosition(x: x, y: y))
                for cell in map.footprintCells(origin: GridPosition(x: x, y: y), size: 2) {
                    map[cell].density = 5
                }
            }
        }
        return map
    }

    /// **The reach has to be the same at every zoom, and it was not.**
    ///
    /// `u_bloomRadius` is a fraction of the render target, and an
    /// `SKEffectNode` sizes its target to whatever its children cover — which
    /// `cullTilesOutsideTheView` deliberately made camera-dependent when it
    /// cut the shaded area down to the visible slice. So the bloom's reach on
    /// screen drifted with the zoom as a side effect of a change made for
    /// performance, and in the worst direction: **33 points at the closest
    /// camera against 14 at the widest**, largest exactly where a lit window
    /// is already four times its resting size.
    ///
    /// Bloom is a lens artefact. It happens in the camera, so it covers a
    /// fixed distance on the glass however far away the subject is.
    ///
    /// Worth keeping as a shape: **a change made for performance can silently
    /// re-scale something that reads off the thing it changed.** Nothing here
    /// failed; the frame simply stopped being the frame anyone had tuned.
    func testTheBloomReachesTheSameDistanceAtEveryZoom() {
        let controller = GameController(map: cityWithSomeTowers(), rng: SeededRNG(seed: 4))
        let scene = GameScene(controller: controller)
        scene.size = CGSize(width: 900, height: 600)
        let view = SKView(frame: NSRect(origin: .zero, size: scene.size))
        view.presentScene(scene)
        scene.rebuildEntireGrid()
        scene.refreshAll()

        var reaches: [CGFloat] = []
        for scale in [0.5, 1.0, 2.0, 3.0] as [CGFloat] {
            scene.setCameraScaleForTesting(scale)
            scene.update(0)
            reaches.append(scene.bloomReachInPointsForTesting)
        }
        let spread = (reaches.max() ?? 0) - (reaches.min() ?? 0)
        XCTAssertLessThan(spread, 1.0,
                          "the bloom reaches \(reaches) points across the zoom range — it has "
                          + "come loose from the screen and is tracking the render target again")
        XCTAssertGreaterThan(reaches.first ?? 0, 1, "the bloom reaches nothing at all")
    }

    /// **A halo, not sixteen copies of the thing that made it.**
    ///
    /// The bloom sums sixteen taps on a golden-angle spiral, and the spiral
    /// used to be identical for every pixel in the frame — so a bright source
    /// was not blurred, it was *copied*, sixteen times, to sixteen fixed
    /// offsets. A few pixels across, those copies overlap into something that
    /// passes for a glow, which is why this looked right on a whole-city
    /// frame. Forty pixels across, each copy is a plainly readable rectangle
    /// printed onto whatever stands next door — which is what "the buildings
    /// look translucent" actually was.
    ///
    /// Measured as the evenness of the halo around a bright square: sixteen
    /// discrete copies make a strongly lobed ring, a real halo makes a flat
    /// one. Every other post-process term is switched off, grain included,
    /// so what is being measured is the bloom alone.
    func testTheHaloIsEvenRatherThanSixteenGhosts() throws {
        let size = CGSize(width: 400, height: 400)
        let scene = SKScene(size: size)
        scene.backgroundColor = .black

        let effect = SKEffectNode()
        let shader = RetroShader.make()
        func set(_ name: String, _ value: Float) {
            shader.uniforms.first { $0.name == name }?.floatValue = value
        }
        // The bloom alone: nothing else may contribute to the ring.
        for name in ["u_scanlineStrength", "u_vignetteStrength", "u_aberration",
                     "u_grainStrength", "u_liftShadows"] { set(name, 0) }
        set("u_bloomStrength", 1.0)
        set("u_bloomRadius", 0.075)
        effect.shader = shader
        effect.shouldEnableEffects = true

        // **The effect node needs something the size of the frame in it.**
        // `SKEffectNode` sizes its render target to its children's accumulated
        // frame — the fact the whole post-process fix turned on — so an effect
        // node holding only the source would shade a 40×40 patch and there
        // would be nowhere outside it for a halo to land. The first version
        // did exactly that and measured a frame with no bloom in it.
        let ground = SKSpriteNode(color: .black, size: size)
        ground.position = CGPoint(x: size.width / 2, y: size.height / 2)
        effect.addChild(ground)

        // **A disc, not a square**, and the first version was a square — which
        // measured the *source's* corners rather than the bloom. A circle of
        // any radius crosses a square's edge at some angles and its corner at
        // others, so the ring came back lobed on a picture with no bloom in it
        // at all. A round source has no angular structure of its own, so
        // whatever the ring finds belongs to the pass being measured.
        //
        // Twenty points across, which is a lit window at the closest camera.
        let source = SKShapeNode(circleOfRadius: 20)
        source.fillColor = .white
        source.strokeColor = .clear
        source.position = CGPoint(x: size.width / 2, y: size.height / 2)
        effect.addChild(source)
        scene.addChild(effect)

        let view = SKView(frame: NSRect(origin: .zero, size: size))
        view.presentScene(scene)
        let texture = try XCTUnwrap(view.texture(from: scene,
                                                 crop: CGRect(origin: .zero, size: size)))
        let bitmap = NSBitmapImageRep(cgImage: texture.cgImage())
        let scale = CGFloat(bitmap.pixelsWide) / size.width

        // Sample a ring outside the square but inside the bloom's reach,
        // box-averaged so a single noisy pixel does not decide anything.
        let centre = CGPoint(x: CGFloat(bitmap.pixelsWide) / 2,
                             y: CGFloat(bitmap.pixelsHigh) / 2)
        // Where the halo actually is, rather than where it was assumed to be:
        // the ring radius is chosen by looking, which also makes the test
        // independent of the exact radius the uniform happens to carry.
        func meanBrightness(atRadius r: CGFloat) -> CGFloat {
            var total: CGFloat = 0, count: CGFloat = 0
            for step in 0 ..< 72 {
                let a = CGFloat(step) / 72 * 2 * .pi
                let x = Int(centre.x + cos(a) * r), y = Int(centre.y + sin(a) * r)
                guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh,
                      let c = bitmap.colorAt(x: x, y: y) else { continue }
                total += c.brightnessComponent
                count += 1
            }
            return count > 0 ? total / count : 0
        }
        let half = 20 * scale   // the source's own radius
        // **Measured out in the falloff, not at the brightest ring.** Close
        // to the source all sixteen copies overlap heavily, and measured
        // there this test passes on the very bug it exists for — checked by
        // putting the old shader line back, which read 1.30 against a bound
        // of 1.6. Out where the copies separate it reads 2.08 against the
        // 1.15 an even halo gives. The radius is *found* rather than fixed,
        // so the bound does not quietly become a statement about one blur
        // width.
        var brightest: CGFloat = 0
        for candidate in stride(from: half + 6 * scale, to: half + 60 * scale, by: 2) {
            brightest = max(brightest, meanBrightness(atRadius: candidate))
        }
        var ring = half + 6 * scale
        for candidate in stride(from: half + 6 * scale, to: half + 60 * scale, by: 2)
        where meanBrightness(atRadius: candidate) > brightest * 0.35 {
            ring = candidate
        }
        var samples: [CGFloat] = []
        for step in 0 ..< 72 {
            let a = CGFloat(step) / 72 * 2 * .pi
            var total: CGFloat = 0, count: CGFloat = 0
            for dy in -2 ... 2 {
                for dx in -2 ... 2 {
                    let x = Int(centre.x + cos(a) * ring) + dx
                    let y = Int(centre.y + sin(a) * ring) + dy
                    guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh,
                          let c = bitmap.colorAt(x: x, y: y) else { continue }
                    total += c.brightnessComponent
                    count += 1
                }
            }
            if count > 0 { samples.append(total / count) }
        }

        let mean = samples.reduce(0, +) / CGFloat(samples.count)
        try XCTSkipIf(mean < 0.01, "no halo to measure — the bloom did not run in this capture")
        let peak = samples.max() ?? 0
        let lobing = peak / mean
        print(String(format: "halo evenness: peak/mean %.2f over %d angles (mean %.3f)",
                     lobing, samples.count, mean))
        // Sixteen fixed copies of a 40-point square put the ring's peak far
        // above its mean. An even halo sits close to 1.
        // 1.6 sits between the 1.15 an even halo measures on this fixture
        // and the 2.08 sixteen fixed copies measure on it.
        XCTAssertLessThan(lobing, 1.6,
                          "the halo is lobed (peak/mean \(lobing)) — the spiral has lost its "
                          + "per-pixel rotation and is printing ghosts of the source again")
    }
}
