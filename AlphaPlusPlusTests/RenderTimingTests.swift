import XCTest
import SpriteKit
@testable import AlphaPlusPlus

/// **What a frame costs.**
///
/// This project measures simulation cost carefully — `HarnessTimingTests`
/// splits a tick by component and CLAUDE.md carries the table — and has
/// measured *rendering* cost exactly once, as a node count. Node counts are a
/// proxy for draw calls and say nothing at all about what the GPU spends on a
/// shader.
///
/// That was fine while there was one cheap fragment pass over the frame. It
/// stops being fine the moment the plan is "put the GPU to work": without a
/// number, "it looks better" and "it dropped to 40fps" are indistinguishable
/// from the outside, and the only honest way to add an effect is to know what
/// the one before it cost.
///
/// **A proxy, and worth saying so.** `SKView.texture(from:)` forces a render
/// of the scene and hands back the result, which exercises the same draw
/// calls and the same shader the live loop does — but it is a synchronous
/// off-loop render, so it does not capture presentation, vsync, or the
/// scheduling a real frame is subject to. It is a good *relative* instrument
/// (this change made the frame 30% dearer) and a poor absolute one. Every
/// number here should be read as a comparison, never as a frame rate.
///
/// Opt-in, like the rest of the benchmarks.
@MainActor
final class RenderTimingTests: XCTestCase {

    private func builtOutCity(side: Int) -> CityMap {
        var map = CityMap(width: side, height: side)
        for y in stride(from: 0, to: side, by: 3) {
            for x in 0 ..< side { map[GridPosition(x: x, y: y)].zone = .road }
        }
        var index = 0
        for y in stride(from: 1, to: side - 1, by: 3) {
            for x in stride(from: 0, to: side - 1, by: 2) {
                let origin = GridPosition(x: x, y: y)
                guard map.footprintCells(origin: origin, size: 2).count == 4 else { continue }
                index += 1
                let zone: ZoneType = [.residential, .commercial, .industrial][index % 3]
                map.placeBuilding(zone: zone, origin: origin)
                for cell in map.footprintCells(origin: origin, size: 2) {
                    map[cell].density = 3 + index % 3
                }
            }
        }
        map.trafficLoad = Traffic.computeLoad(for: map)
        return map
    }

    func testMeasureFrameCost() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PLAYTEST_FULL"] != nil,
            "benchmark; set TEST_RUNNER_PLAYTEST_FULL=1 to run it"
        )

        print("\n=== Frame cost (SKView.texture(from:), a relative instrument) ===")
        print("| map   | style     | ms/frame |")
        print("|-------|-----------|----------|")
        for side in [32, 48, 64] {
            let map = builtOutCity(side: side)
            for style in VisualStyle.allCases {
                VisualStyle.current = style
                let controller = GameController(map: map, rng: SeededRNG(seed: 9),
                                                peakPopulation: Unlocks.everythingUnlocked)
                let scene = GameScene(controller: controller)
                scene.size = CGSize(width: 1_280, height: 800)
                let view = SKView(frame: NSRect(origin: .zero, size: scene.size))
                view.presentScene(scene)
                scene.rebuildEntireGrid()
                scene.refreshAll()

                // One warm render first: the first frame pays for texture
                // upload and shader compilation, which is a one-off and not
                // what a frame costs.
                _ = view.texture(from: scene)

                let frames = 30
                let started = CFAbsoluteTimeGetCurrent()
                for _ in 0 ..< frames { _ = view.texture(from: scene) }
                let each = (CFAbsoluteTimeGetCurrent() - started) / Double(frames) * 1_000
                print(String(format: "| %d×%d | %-9@ | %8.2f |",
                             side, side, style.displayName as NSString, each))
            }
        }
        VisualStyle.current = .cinematic
    }
}
