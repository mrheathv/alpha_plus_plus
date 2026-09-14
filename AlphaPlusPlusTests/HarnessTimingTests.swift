import XCTest
@testable import AlphaPlusPlus

/// Measures what one simulation tick actually costs at each map size.
///
/// Opt-in, because measuring the largest map in Debug takes minutes on its
/// own — a single 64×64 tick costs over six seconds there. Run it with:
///
///     TEST_RUNNER_PLAYTEST_FULL=1 xcodebuild -project AlphaPlusPlus.xcodeproj \
///       -scheme AlphaPlusPlus -configuration Release -derivedDataPath ./build \
///       ENABLE_TESTABILITY=YES test \
///       -only-testing:AlphaPlusPlusTests/HarnessTimingTests
///
/// Results are written to `build/tick-timing.txt` incrementally, so a run too
/// slow to finish still reports the sizes it got through.
///
/// **What it found, and why it is worth keeping around.** Measured on a fully
/// built-out city:
///
/// | map   | Debug     | Release  | lots |
/// |-------|-----------|----------|------|
/// | 16×16 |   25.8 ms |   0.8 ms |   33 |
/// | 24×24 |  124.5 ms |   3.1 ms |   80 |
/// | 32×32 |  364.2 ms |   8.5 ms |  133 |
/// | 48×48 | 1994.5 ms |  39.5 ms |  320 |
/// | 64×64 | 6286.3 ms | 114.5 ms |  560 |
///
/// Two conclusions. First, **Debug is ~55x slower than Release** on this
/// workload, which is nearly all tight loops over structs — so balance runs
/// belong in Release, and a Debug build (what Cmd-R gives you) cannot play a
/// large map at all: 6.3 s/tick against `SimulationSpeed.fast`'s 0.35 s
/// interval is eighteen times over budget, and still six times over at
/// `.normal`.
///
/// Second, cost grows *superlinearly* in map area — 16x the tiles from 16×16
/// to 64×64 costs 143x the time. That is `Traffic.computeLoad` routing more
/// commuters over longer paths as the city grows, and it is why even Release
/// spends 114 ms on a 64×64 tick. That fits inside a 350 ms tick interval, but
/// `GameController` is `@MainActor`, so it is 114 ms of blocked main thread —
/// roughly seven dropped frames — every tick.
@MainActor
final class HarnessTimingTests: XCTestCase {

    func testMeasureTickCost() throws {
        try XCTSkipUnless(
            PlaytestHarness.Profile.current == .full,
            "benchmark; set TEST_RUNNER_PLAYTEST_FULL=1 to run it"
        )

        let out = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build/tick-timing.txt")
        try FileManager.default.createDirectory(
            at: out.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        var log = "config: \(buildConfiguration())\n"
        try log.write(to: out, atomically: true, encoding: .utf8)

        for size in [16, 24, MapSize.small.dimension, MapSize.medium.dimension, MapSize.large.dimension] {
            let spec = PlaytestHarness.CitySpec(size: size)
            let controller = GameController(map: PlaytestHarness.buildCity(spec), rng: SeededRNG(seed: 1))

            // Warm up, so the measured ticks are of a grown city rather than
            // of one still filling in.
            for _ in 0..<5 { controller.advanceSimulation() }

            let sample = 10
            let start = Date()
            for _ in 0..<sample { controller.advanceSimulation() }
            let perTick = Date().timeIntervalSince(start) / Double(sample)

            let roads = controller.map.tiles.filter { $0.zone == .road }.count
            let lots = controller.map.tiles.filter { $0.isBuildingAnchor && $0.zone.maxDensity > 0 }.count
            log += String(
                format: "%d×%d: %8.1f ms/tick  1000 ticks=%7.1f s   pop %5d  roads %5d  lots %4d\n",
                size, size, perTick * 1000, perTick * 1000, controller.population, roads, lots
            )
            try log.write(to: out, atomically: true, encoding: .utf8)
        }

        print(log)
    }

    private func buildConfiguration() -> String {
        #if DEBUG
        return "Debug"
        #else
        return "Release"
        #endif
    }
}
