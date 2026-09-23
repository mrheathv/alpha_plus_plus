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

        // 96 and 128 are past anything `MapSize` offers, deliberately: the
        // question "why is 64 the biggest map" cannot be answered by
        // extrapolating two points, and this project's standing rule is to
        // measure rather than reason about cost. They are not playable sizes
        // yet; they are the evidence for whether they could be.
        log += String(format: "Tile stride %d bytes\n", MemoryLayout<Tile>.stride)
        for size in [16, 24, MapSize.small.dimension, MapSize.medium.dimension,
                     MapSize.large.dimension, 96, 128] {
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
            // The map's own bytes, so the "how much RAM does this need"
            // question has a number rather than an intuition.
            let mapBytes = MemoryLayout<Tile>.stride * size * size
            log += String(
                format: "%d×%d: %8.1f ms/tick  1000 ticks=%7.1f s   pop %5d  roads %5d  lots %4d  map %6.1f MB\n",
                size, size, perTick * 1000, perTick * 1000, controller.population, roads, lots,
                Double(mapBytes) / 1_048_576
            )
            try log.write(to: out, atomically: true, encoding: .utf8)
        }

        print(log)
    }

    /// Where a tick's time actually goes, component by component.
    ///
    /// Worth running before optimizing anything: this is what showed that the
    /// obvious suspect was the wrong one. `Traffic.computeLoad` looked like
    /// the bottleneck — it does a full breadth-first search per home per tick
    /// — but measured only 18.6% of a 64×64 tick, while `CitySimulator.advance`
    /// was 72%. The actual cost was `LandValue.distanceToNearest` scanning
    /// every tile, eight times per `value(at:)` call, once per footprint cell
    /// of every building; see `ZoneDistanceField`.
    ///
    /// After that fix, at 64×64: traffic 21.8 ms (90%), grow 1.2 ms (was
    /// 83.0), hazards 0.4 ms (was 11.0). Traffic is now the bottleneck it
    /// originally only looked like.
    func testMeasureTickBreakdown() throws {
        try XCTSkipUnless(
            PlaytestHarness.Profile.current == .full,
            "benchmark; set TEST_RUNNER_PLAYTEST_FULL=1 to run it"
        )

        // **96 and 128 are past anything `MapSize` offers**, and are here
        // because a player asked for them. The rendering side stopped scaling
        // with map area once the post-process was bound to the viewport, so
        // the tick is the only thing left deciding how big a city can get —
        // which makes *where a tick goes* at those sizes the question worth
        // answering.
        for size in [MapSize.small.dimension, MapSize.medium.dimension,
                     MapSize.large.dimension, 96, 128] {
            let spec = PlaytestHarness.CitySpec(size: size)
            let controller = GameController(map: PlaytestHarness.buildCity(spec), rng: SeededRNG(seed: 1))
            for _ in 0..<5 { controller.advanceSimulation() }

            let sample = 10

            let tickStart = Date()
            for _ in 0..<sample { controller.advanceSimulation() }
            let perTick = Date().timeIntervalSince(tickStart) / Double(sample)

            let map = controller.map
            let trafficStart = Date()
            for _ in 0..<sample { _ = Traffic.computeLoad(for: map) }
            let perTraffic = Date().timeIntervalSince(trafficStart) / Double(sample)

            func time(_ body: () -> Void) -> Double {
                let start = Date()
                for _ in 0..<sample { body() }
                return Date().timeIntervalSince(start) / Double(sample) * 1000
            }

            var rng = SeededRNG(seed: 2)
            let water = time { _ = Water.computeSupply(for: map) }
            let demand = time { _ = Demand.compute(for: map) }
            let hazards = time { _ = CityHazards.apply(to: map, using: &rng) }
            let grow = time { _ = CitySimulator.advance(map, using: &rng) }

            print(String(
                format: "%d×%d tick %6.1f ms  = traffic %5.1f (%4.1f%%) water %5.1f (%4.1f%%) "
                      + "demand %5.1f (%4.1f%%) hazards %5.1f (%4.1f%%) grow %5.1f (%4.1f%%)",
                size, size, perTick * 1000,
                perTraffic * 1000, perTraffic * 1000 / (perTick * 1000) * 100,
                water, water / (perTick * 1000) * 100,
                demand, demand / (perTick * 1000) * 100,
                hazards, hazards / (perTick * 1000) * 100,
                grow, grow / (perTick * 1000) * 100
            ))
        }
    }

    private func buildConfiguration() -> String {
        #if DEBUG
        return "Debug"
        #else
        return "Release"
        #endif
    }
}
