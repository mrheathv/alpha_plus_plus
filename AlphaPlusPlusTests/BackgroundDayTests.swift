import XCTest
@testable import AlphaPlusPlus

/// **The day, off the main thread.** The live game simulates each day in the
/// background and applies it when it arrives; these pin the three things that
/// make that safe to do.
@MainActor
final class BackgroundDayTests: XCTestCase {

    private func grownCity() -> CityMap {
        let controller = GameController(map: PlaytestHarness.buildCity(.init(size: 24)), rng: SeededRNG(seed: 5),
                                        peakPopulation: Unlocks.everythingUnlocked)
        for _ in 0 ..< 40 { controller.advanceSimulation() }
        return controller.map
    }

    private func runDay(on controller: GameController) async -> Bool {
        await withCheckedContinuation { continuation in
            controller.beginDayInBackground { applied in continuation.resume(returning: applied) }
        }
    }

    /// Same city, same seed: a day in the background is exactly the day the
    /// synchronous path produces — the map, the treasury, the strikes. Ten
    /// days in a row, so the generator's state is carried over correctly too.
    func testABackgroundDayIsTheSameDay() async {
        let city = grownCity()
        let foreground = GameController(map: city, rng: SeededRNG(seed: 9), peakPopulation: Unlocks.everythingUnlocked)
        let background = GameController(map: city, rng: SeededRNG(seed: 9), peakPopulation: Unlocks.everythingUnlocked)
        for day in 1 ... 10 {
            foreground.advanceSimulation()
            let applied = await runDay(on: background)
            XCTAssertTrue(applied, "day \(day) was not applied")
            XCTAssertEqual(background.map, foreground.map, "day \(day): the cities differ")
            XCTAssertEqual(background.treasury, foreground.treasury, "day \(day): the treasuries differ")
            XCTAssertEqual(background.lastHazardStrikes.map(\.position), foreground.lastHazardStrikes.map(\.position))
        }
    }

    /// **The player's click wins.** An edit made while a day is running
    /// throws that day away rather than letting it overwrite the edit.
    func testAnEditDuringTheDayWins() async {
        let controller = GameController(map: grownCity(), rng: SeededRNG(seed: 9),
                                        peakPopulation: Unlocks.everythingUnlocked)
        let spot = controller.map.tiles.first { $0.zone == .empty && !$0.isWater }!.position
        let day = controller.map.elapsedDays
        let applied: Bool = await withCheckedContinuation { continuation in
            controller.beginDayInBackground { applied in continuation.resume(returning: applied) }
            // Straight after starting it, on the main thread: the day is
            // still running when this lands.
            controller.selectedTool = .park
            _ = controller.place(at: spot)
        }
        XCTAssertFalse(applied, "a day started before the edit was applied over it")
        XCTAssertEqual(controller.map[spot].zone, .park, "the edit was lost")
        XCTAssertEqual(controller.map.elapsedDays, day, "the discarded day still moved the calendar")
        XCTAssertFalse(controller.isDayInFlight)
        // And the next one goes through.
        let next = await runDay(on: controller)
        XCTAssertTrue(next)
        XCTAssertEqual(controller.map.elapsedDays, day + 1)
    }

    /// **The point of it**: starting a day costs the main thread almost
    /// nothing, where simulating it there cost Apex ~29 ms in Release.
    func testStartingADayBarelyTouchesTheMainThread() async throws {
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "needs Apex")
        let map = try CitySaveFile.read(from: url).map
        let controller = GameController(map: map, rng: SeededRNG(seed: 1), peakPopulation: Unlocks.everythingUnlocked)
        var onMain = Double.infinity
        for _ in 0 ..< 3 {
            let applied: Bool = await withCheckedContinuation { continuation in
                let start = DispatchTime.now().uptimeNanoseconds
                controller.beginDayInBackground { applied in continuation.resume(returning: applied) }
                onMain = min(onMain, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            XCTAssertTrue(applied)
        }
        let synchronous = ContinuousClock().measure { controller.advanceSimulation() }
        print(String(format: "Apex: starting a day costs the main thread %.3f ms; simulating it there %@",
                     onMain, String(describing: synchronous)))
        XCTAssertLessThan(onMain, 2, "starting a background day blocked the main thread for \(onMain) ms")
    }

    /// **The scene, end to end.** The clock starts background days and the
    /// map is redrawn when each lands; `SceneAgreement` then checks the
    /// picture against a scene built fresh from the same city — the check
    /// that has caught every stale-redraw bug this project has had.
    func testTheSceneKeepsUpWithBackgroundDays() async throws {
        let game = ScenePlaytest(map: grownCity())
        game.scene.runsDaysInBackground = true
        game.play()
        let start = game.controller.map.elapsedDays
        var frames = 0
        while game.controller.map.elapsedDays < start + 6, frames < 2000 {
            game.frame()
            frames += 1
            // Let the finished day hop back onto the main actor.
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertGreaterThanOrEqual(game.controller.map.elapsedDays, start + 6,
                                    "background days never landed in the scene")
        // Wait out any day still in flight, so the check sees a settled city.
        while game.controller.isDayInFlight { try await Task.sleep(nanoseconds: 2_000_000) }
        game.pause()
        game.check("after six background days")
    }
}
