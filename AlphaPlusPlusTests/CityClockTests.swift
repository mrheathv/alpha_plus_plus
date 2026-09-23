import XCTest
@testable import AlphaPlusPlus

/// **The clock without a scene** (M8): days start on the interval while the
/// city runs, never while it is paused, and resuming waits a full interval.
@MainActor
final class CityClockTests: XCTestCase {

    private func controller() -> GameController {
        GameController(map: PlaytestHarness.buildCity(.init(size: 24)), rng: SeededRNG(seed: 3),
                       peakPopulation: Unlocks.everythingUnlocked)
    }

    func testADayStartsEachIntervalWhileRunning() {
        let controller = controller()
        let clock = CityClock(controller: controller)
        var days = 0
        clock.onDay = { _ in days += 1 }
        controller.isRunning = true
        let interval = controller.simulationSpeed.tickInterval
        clock.advance(to: 10)                          // arms the clock
        XCTAssertEqual(days, 0, "ticked on the very frame it started")
        clock.advance(to: 10 + interval * 0.5)
        XCTAssertEqual(days, 0, "ticked before the interval was up")
        clock.advance(to: 10 + interval)
        XCTAssertEqual(days, 1)
        XCTAssertEqual(controller.map.elapsedDays, 1)
        clock.advance(to: 10 + interval * 2)
        XCTAssertEqual(days, 2)
    }

    func testNothingHappensWhilePausedAndResumingWaitsAnInterval() {
        let controller = controller()
        let clock = CityClock(controller: controller)
        let interval = controller.simulationSpeed.tickInterval
        clock.advance(to: 0)
        clock.advance(to: interval * 50)
        XCTAssertEqual(controller.map.elapsedDays, 0, "a paused city advanced")
        controller.isRunning = true
        clock.advance(to: interval * 100)
        XCTAssertEqual(controller.map.elapsedDays, 0, "resuming ticked at once for the time spent paused")
        clock.advance(to: interval * 101)
        XCTAssertEqual(controller.map.elapsedDays, 1)
    }

    /// In the background, a day the player's edit made stale is thrown away
    /// and another starts on the next frame.
    func testADiscardedBackgroundDayIsRetried() async throws {
        let controller = controller()
        let clock = CityClock(controller: controller)
        clock.runsDaysInBackground = true
        controller.isRunning = true
        let interval = controller.simulationSpeed.tickInterval
        clock.advance(to: 0)
        clock.advance(to: interval)                    // starts a day in the background
        XCTAssertTrue(controller.isDayInFlight)
        let spot = try XCTUnwrap(controller.map.tiles.first { $0.zone == .empty && !$0.isWater }).position
        controller.selectedTool = .road
        _ = controller.place(at: spot)                 // the edit that makes it stale
        while controller.isDayInFlight { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(controller.map.elapsedDays, 0, "the stale day was applied over the edit")
        clock.advance(to: interval * 1.1)              // retried at once, not an interval later
        while controller.isDayInFlight { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(controller.map.elapsedDays, 1)
        XCTAssertEqual(controller.map[spot].zone, .road, "the edit was lost")
    }
}
