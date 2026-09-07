import Foundation

/// A `RandomNumberGenerator` that always returns the minimum possible
/// value, making `Double.random(in:using:)` always land at (or
/// essentially at) the low end of its range. Used across the test suite
/// wherever a test needs to guarantee a probability-gated outcome
/// happens — `CitySimulator.advance`'s demand-driven growth roll
/// (`Demand.swift`) — without asserting anything about the randomness
/// itself. Most of `CitySimulatorTests`/`GameControllerTests` are about
/// the *other* growth gates (access, land value, water); this keeps
/// demand from ever being the reason one of those tests passes or fails,
/// since `CitySimulator.growthChance(for:)` is never exactly 0 for any
/// demand in `-1...1` — the roll always clears with this generator.
struct AlwaysZeroRNG: RandomNumberGenerator {
    mutating func next() -> UInt64 { 0 }
}

/// The opposite of `AlwaysZeroRNG`: always returns the maximum possible
/// value, making `Double.random(in:using:)` always land at (or
/// essentially at) the high end of its range — guaranteed to *fail* any
/// roll against a chance below 1.0. Used by the handful of tests that
/// specifically assert a demand-gated roll can block growth.
struct AlwaysMaxRNG: RandomNumberGenerator {
    mutating func next() -> UInt64 { .max }
}
