@testable import AlphaPlusPlus
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

// MARK: - Growth now takes time

/// Advance far enough for the lot at `position` to finish exactly one level.
///
/// **Why almost every growth test needed this.** Growth used to complete in the
/// tick it was approved, so a test could call `advance` once and assert the
/// density went up. Since construction landed, approval and completion are
/// different ticks: one tick starts the work, and
/// `CitySimulator.constructionTicks(toReach:)` more finish it.
///
/// Deliberately the *exact* number of ticks rather than a generous margin.
/// Most of these fixtures use `AlwaysZeroRNG`, which passes every probability
/// gate, so running "plenty of ticks" would not settle at one level — it would
/// keep climbing, and a test asserting a single step would silently become a
/// test asserting five.
func advanceOneLevel(
    _ map: CityMap,
    at position: GridPosition,
    using rng: inout some RandomNumberGenerator,
    levels: Int = 1
) -> CityMap {
    var current = map
    for _ in 0 ..< levels {
        let target = current[position].density + 1
        // One tick to approve and start, then the build itself.
        for _ in 0 ... CitySimulator.constructionTicks(toReach: target) {
            current = CitySimulator.advance(current, using: &rng)
        }
    }
    return current
}

/// `advanceOneLevel`, one layer up: ticks a whole `GameController` far enough
/// for a lot to finish one level of construction.
///
/// It takes the target level rather than reading a position's density, because
/// the controller tests that need it are asserting on the city's *aggregate*
/// numbers — population, jobs, tax — not on one tile, and every lot in those
/// fixtures is growing in lockstep anyway.
@MainActor
func advanceThroughConstruction(_ controller: GameController, toReach level: Int = 1) {
    advanceToTheBrinkOfCompletion(controller, toReach: level)
    controller.advanceSimulation()
}

/// Every tick of `advanceThroughConstruction` except the last one — so the
/// caller can snapshot the treasury and then run the single tick on which the
/// building completes, which is also the tick that first taxes it.
///
/// Splitting it this way keeps the money assertions saying what they used to
/// say. "Growth happens before tax, so this taxes the *post-growth*
/// population" is still the property under test; construction only moved which
/// tick that is.
@MainActor
func advanceToTheBrinkOfCompletion(_ controller: GameController, toReach level: Int = 1) {
    for _ in 0 ..< CitySimulator.constructionTicks(toReach: level) {
        controller.advanceSimulation()
    }
}

/// How many ticks one lot needs to climb from bare ground to `level`, with
/// construction paid for at every step: one tick to approve each level, then
/// `CitySimulator.constructionTicks(toReach:)` to build it.
///
/// For the "run it until it settles, then look" fixtures — the ones that are
/// not asserting on a single step but on where a city ends up. They used to
/// pick a round number like 20 or 60, which was generous when a level was
/// free and is not any more. Deriving it means they stay right if
/// `baseConstructionTicks` moves again.
func ticksToBuild(toLevel level: Int) -> Int {
    (1 ... level).reduce(0) { $0 + 1 + CitySimulator.constructionTicks(toReach: $1) }
}

/// Tick a controller until its city stops growing, and report how long that
/// took.
///
/// For the fixtures whose subject is what happens *after* a city has settled —
/// decline, neglect, losing a utility. A fixed tick count cannot serve them
/// any more: `ticksToBuild` says how long one lot takes, but a whole city
/// staggers its lots behind demand, land value and utility capacity, so the
/// settling point is an emergent number rather than an arithmetic one. Running
/// a "take the power away and watch" test on a city that is still climbing
/// measures growth against decline and reports the difference, which is how a
/// working decline mechanic can read as a broken one.
///
/// `cap` is a hang guard, not a target — a test that hits it is measuring
/// something other than a settled city and should say so.
@MainActor
func advanceUntilSettled(_ controller: GameController, window: Int = 40, cap: Int = 2_000) -> Int {
    var ticks = 0
    var previous = -1
    while ticks < cap {
        for _ in 0 ..< window {
            controller.advanceSimulation()
            ticks += 1
        }
        let now = controller.population
        if now <= previous { break }
        previous = now
    }
    return ticks
}

/// A generator that plays a scripted list of fractions and then holds the last
/// one forever.
///
/// `AlwaysZeroRNG` and `AlwaysMaxRNG` are all-or-nothing, and for `Fire` that
/// is not enough: a fire's life is a *sequence* of rolls against different
/// chances, and the two chances are ordered the wrong way round for any single
/// fixed value to separate them. `burnoutChancePerTick` is 0.25 and
/// `spreadChancePerTick` is 0.18, so "high enough not to burn out" and "low
/// enough to spread" have no overlap — a generator passing every roll burns
/// out on tick one and never spreads, and one failing every roll burns forever
/// and never spreads either. Both report "fire does not spread" about working
/// code.
///
/// `Fire.advance` rolls burnout once for a burning block and then spread once
/// per neighbour, so `ScriptedRNG(first: 0.9, then: 0)` means exactly "this
/// fire is not going out this tick, and everything it reaches catches" — which
/// is the single tick a spread test wants to look at. Longer runs want
/// `SeededRNG` and a measurement across many of them, since both halves are
/// genuinely probabilistic.
struct ScriptedRNG: RandomNumberGenerator {
    private var remaining: [Double]
    private var last: Double

    init(first: Double, then: Double) {
        self.remaining = [first]
        self.last = then
    }

    init(_ values: [Double], then: Double) {
        self.remaining = values
        self.last = then
    }

    mutating func next() -> UInt64 {
        let fraction = remaining.isEmpty ? last : remaining.removeFirst()
        // **Scaled to 2^53, not to `UInt64.max`**, and the difference is not
        // cosmetic. `Double.random(in: 0 ..< 1)` keeps only the low 53 bits of
        // what the generator hands it — it is filling a significand, not
        // dividing a 64-bit range — so `UInt64(0.9 * Double(UInt64.max))`
        // comes back out as **0.2**, the fractional part of 0.9 × 2^11. Which
        // looks exactly like a working generator producing an unlucky roll.
        // `AlwaysZeroRNG` and `AlwaysMaxRNG` are immune to this by accident,
        // being at the ends of the range where the truncation cannot bite.
        return UInt64(fraction * Double(1 << 53))
    }
}
