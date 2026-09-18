import Foundation

/// How fast the simulation clock ticks while `GameController.isRunning`.
///
/// Lives in `App/`, not `Simulation/`: like `GameController` itself, this is
/// about *pacing the player's view* of the simulation, not a rule the
/// simulation follows — `CitySimulator.advance(_:)` has no concept of real
/// time at all, it just computes "the next step." Only `GameScene`'s clock
/// cares how often "next step" gets called.
enum SimulationSpeed: String, CaseIterable, Identifiable, Hashable {
    case slow
    case normal
    case fast

    var id: String { rawValue }

    /// Seconds between simulation steps at this speed. `.normal` (1.0) is
    /// the interval every earlier increment was tuned and tested against;
    /// `.slow`/`.fast` are guesses at a sensible range around it, same as
    /// every other placeholder economy number in this project so far.
    var tickInterval: TimeInterval {
        switch self {
        // **Slowed across the board**, reported from play as "everything is
        // happening so fast". The systems this game grew are all long-horizon
        // — a storey takes 8 to 40 days, maintenance and the regional cycle
        // run over hundreds — and at one second a day the whole range was
        // compressed into minutes: a boom and bust inside five, a decision and
        // its consequence inside eight seconds. `.slow` doubling `.normal` was
        // not much of a slow for any of that.
        //
        // Now roughly a 2x ladder with `.normal` at two seconds a day: a year
        // is twelve minutes, the economy turns over in twenty, and `.slow` is
        // genuinely a watch-the-city-breathe speed rather than a slightly
        // patient one.
        case .slow: return 4.0
        case .normal: return 2.0
        case .fast: return 0.75
        }
    }

    var displayName: String {
        switch self {
        case .slow: return "Slow"
        case .normal: return "Normal"
        case .fast: return "Fast"
        }
    }
}
