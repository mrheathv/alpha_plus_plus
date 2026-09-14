import Foundation

/// One snapshot of the headline stats, recorded after every
/// `GameController.advanceSimulation()` step, so `GameView` can show a trend
/// (`Sparkline`) rather than just the current instant.
///
/// Lives in `Simulation/` rather than nested inside `GameController` (App/)
/// because `CitySave` — which is also `Simulation/`, and Foundation-only by
/// this project's enforcement rule — has to name it to persist a city's stat
/// history across a save. `Simulation/` cannot reach up into `App/`, so a type
/// both need belongs down here. It is pure data (three `Int`s) with no
/// behavior, so nothing about it wanted to be in the controller in the first
/// place; being nested there was just where it was first needed.
struct CityStatSnapshot: Equatable, Codable, Sendable {
    let population: Int
    let jobs: Int
    let treasury: Int

    init(population: Int, jobs: Int, treasury: Int) {
        self.population = population
        self.jobs = jobs
        self.treasury = treasury
    }
}
