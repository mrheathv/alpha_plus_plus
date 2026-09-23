import Foundation

/// **The city's clock, without a scene** (M8). `GameScene.update` was the only
/// thing that ever advanced the simulation, so with SpriteKit gone nothing
/// would. This is that clock, lifted out as it was: whatever frame loop the
/// view runs calls `advance(to:)` every frame, and a day starts every
/// `SimulationSpeed.tickInterval` while the city runs.
@MainActor
final class CityClock {
    private let controller: GameController

    /// **Whether days are simulated in the background.** On for the live game
    /// only. A test drives the clock synchronously and never spins the run
    /// loop, so a background day would start and never land, and every tick
    /// after it would quietly be skipped while the clock waited for it.
    var runsDaysInBackground = false

    /// Called on the main thread once a day has been applied, with the map
    /// as it was before it, so the view can flash what the day's hazards
    /// struck.
    var onDay: ((_ before: CityMap) -> Void)?

    /// Frame time of the last tick, or `nil` while paused or just resumed.
    private var lastTickTime: TimeInterval?

    /// Set when a day was discarded because the player edited the city while
    /// it ran, so the next frame starts another at once.
    private var retryDay = false

    init(controller: GameController) {
        self.controller = controller
    }

    /// One frame. `currentTime` is any monotonic clock in seconds.
    func advance(to currentTime: TimeInterval) {
        guard controller.isRunning else {
            // Paused: forget the last tick, so resuming waits a full interval
            // rather than ticking at once on however long the pause lasted.
            lastTickTime = nil
            return
        }
        if retryDay, !controller.isDayInFlight {
            retryDay = false
            startDay()
            return
        }
        guard let lastTickTime else {
            // Just resumed, or the first frame: start timing from now.
            self.lastTickTime = currentTime
            return
        }
        guard currentTime - lastTickTime >= controller.simulationSpeed.tickInterval,
              !controller.isDayInFlight else { return }
        self.lastTickTime = currentTime
        startDay()
    }

    /// One day, now and on this thread: the menu's Advance, and tests.
    func runSimulationTick() {
        // A background day is already running; this one would race it for
        // the generator, and it will land on its own in a moment.
        guard !controller.isDayInFlight else { return }
        let before = controller.map
        controller.advanceSimulation()
        onDay?(before)
    }

    private func startDay() {
        guard runsDaysInBackground else {
            runSimulationTick()
            return
        }
        let before = controller.map
        controller.beginDayInBackground { [weak self] applied in
            guard let self else { return }
            if applied { self.onDay?(before) } else { self.retryDay = true }
        }
    }
}
