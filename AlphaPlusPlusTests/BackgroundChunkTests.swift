import XCTest
@testable import AlphaPlusPlus

/// **Changed chunks rebuilt off the main thread.** The live view rebuilds
/// what a day changed in the background and swaps each chunk in when it
/// lands; these pin that it ends up exactly where a synchronous rebuild
/// would, and that the main thread is spared the work.
@MainActor
final class BackgroundChunkTests: XCTestCase {

    /// A large city in its first months, when a day grows the most — the
    /// case `RedrawHitchTests` measured at up to 12 ms of rebuild in Release.
    private func growingCity() -> GameController {
        var spec = PlaytestHarness.CitySpec(size: 64)
        spec.segregateIndustry = true
        let controller = GameController(map: PlaytestHarness.buildCity(spec), rng: SeededRNG(seed: 2),
                                        peakPopulation: Unlocks.everythingUnlocked)
        for _ in 0 ..< 20 { controller.advanceSimulation() }
        return controller
    }

    /// Ten days at a time: a lot changes only when its construction finishes,
    /// so single days mostly change nothing a chunk draws — the first run of
    /// these compared renderers that had nothing to rebuild.
    private func grow(_ controller: GameController) {
        for _ in 0 ..< 10 { controller.advanceSimulation() }
    }

    private func settle(_ renderer: MetalCityRenderer) async throws {
        var waited = 0
        while renderer.isRebuildingInBackground, waited < 2000 {
            try await Task.sleep(nanoseconds: 1_000_000)
            waited += 1
        }
        XCTAssertFalse(renderer.isRebuildingInBackground, "a background rebuild never landed")
    }

    /// Day after day, a renderer rebuilding in the background holds exactly
    /// the chunks one rebuilding synchronously does, once its work lands.
    func testBackgroundRebuildsLandWhereSynchronousOnesWould() async throws {
        let controller = growingCity()
        let background = try XCTUnwrap(MetalCityRenderer())
        background.rebuildsInBackground = true
        let foreground = try XCTUnwrap(MetalCityRenderer())
        background.update(controller.map, revision: nil)
        foreground.update(controller.map, revision: nil)
        for day in 1 ... 5 {
            grow(controller)
            background.update(controller.map, revision: nil)
            foreground.update(controller.map, revision: nil)
            XCTAssertGreaterThan(foreground.chunksRebuiltLastUpdate, 0, "day \(day) changed nothing to rebuild")
            try await settle(background)
            XCTAssertEqual(background.chunksForTesting(), foreground.chunksForTesting(),
                           "day \(day): the background chunks differ from the synchronous ones")
        }
    }

    /// A chunk that changes again while it is being rebuilt ends up with the
    /// newer city, not whichever job happened to finish last.
    func testANewerChangeWins() async throws {
        let controller = growingCity()
        let renderer = try XCTUnwrap(MetalCityRenderer())
        renderer.rebuildsInBackground = true
        renderer.update(controller.map, revision: nil)
        grow(controller)
        renderer.update(controller.map, revision: nil)
        grow(controller)
        renderer.update(controller.map, revision: nil)
        try await settle(renderer)
        let fresh = try XCTUnwrap(MetalCityRenderer())
        fresh.update(controller.map, revision: nil)
        XCTAssertEqual(renderer.chunksForTesting(), fresh.chunksForTesting())
    }

    /// **The point of it**: the frame a day lands on no longer pays for the
    /// rebuild.
    func testTheMainThreadIsSparedTheRebuild() async throws {
        let controller = growingCity()
        let background = try XCTUnwrap(MetalCityRenderer())
        background.rebuildsInBackground = true
        let foreground = try XCTUnwrap(MetalCityRenderer())
        background.update(controller.map, revision: nil)
        foreground.update(controller.map, revision: nil)
        func ms(_ work: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            work()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }
        var onMain: [Double] = [], synchronous: [Double] = []
        for _ in 0 ..< 5 {
            grow(controller)
            onMain.append(ms { background.update(controller.map, revision: nil) })
            synchronous.append(ms { foreground.update(controller.map, revision: nil) })
            try await settle(background)
        }
        let worstBackground = onMain.max() ?? 0, worstSynchronous = synchronous.max() ?? 0
        print(String(format: "a growing day's update on the main thread: background worst %.2f ms, synchronous worst %.2f ms",
                     worstBackground, worstSynchronous))
        XCTAssertLessThan(worstBackground, worstSynchronous, "rebuilding in the background saved nothing")
    }

    /// A player's own click is drawn at once, not a frame later: an edit that
    /// changes a chunk or two is rebuilt on the spot even in the background
    /// mode.
    func testAClickIsDrawnAtOnce() throws {
        let controller = growingCity()
        let renderer = try XCTUnwrap(MetalCityRenderer())
        renderer.rebuildsInBackground = true
        renderer.update(controller.map, revision: nil)
        let spot = try XCTUnwrap(controller.map.tiles.first { $0.zone == .empty && !$0.isWater }).position
        controller.selectedTool = .park
        _ = controller.place(at: spot)
        renderer.update(controller.map, revision: nil)
        XCTAssertFalse(renderer.isRebuildingInBackground, "a single placement was sent to the background")
        let fresh = try XCTUnwrap(MetalCityRenderer())
        fresh.update(controller.map, revision: nil)
        XCTAssertEqual(renderer.chunksForTesting(), fresh.chunksForTesting())
    }
}
