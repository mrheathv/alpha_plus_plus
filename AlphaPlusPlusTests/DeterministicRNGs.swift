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
/// **Careful: this also fires every hazard, every tick.** `CityHazards.apply`
/// rolls against this same generator, so a fixture built on `AlwaysZeroRNG`
/// suffers a fire or a crime on every single tick that any building sits below
/// `CityHazards.Risk.coverageThreshold`. Since hazard damage is now permanent
/// until a covering service repairs it (`Tile.damagedBy`), an unprotected
/// fixture city is levelled within a tick or two and then never recovers —
/// which shows up as "population 0" or "no traffic was routed" in a test that
/// looks like it should be about something else entirely.
///
/// So a fixture that needs to *grow* under this generator needs real service
/// coverage: a police station in range of anything residential or commercial,
/// a fire station in range of anything commercial or industrial. Remember that
/// coverage is falloff × funding, so lowering a service's funding can drop a
/// city below the threshold just as surely as moving the station away.
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

/// A real pseudo-random generator with a fixed, reproducible seed.
///
/// The two generators above are *degenerate* on purpose — they force every
/// probability-gated roll to always succeed or always fail, which is what a
/// test asserting "this gate can block growth" wants. That makes them useless
/// for the opposite question: how often something happens *on average*.
/// `AlwaysZeroRNG` would make every hazard fire every tick regardless of what
/// `CityHazards.chancePerTick` is actually set to, so a balance measurement
/// taken with it would say the same thing at 0.05 and at 0.005.
///
/// `SeededRNG` gives the playtest harness realistic randomness that still
/// reproduces exactly run to run, so a measured rate is both meaningful and
/// stable enough to assert on.
///
/// SplitMix64 — the same small, well-distributed generator Java's
/// `SplittableRandom` and Swift's own `SystemRandomNumberGenerator`
/// documentation-adjacent literature use as a reference. Chosen over a
/// hand-rolled linear congruential generator because a bad LCG's low bits
/// cycle quickly, and `Double.random(in:using:)` reads exactly those bits.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
