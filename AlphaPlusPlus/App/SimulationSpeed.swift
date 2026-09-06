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
        case .slow: return 2.0
        case .normal: return 1.0
        case .fast: return 0.35
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
