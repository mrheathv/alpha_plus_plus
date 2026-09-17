import Foundation

/// The economy *outside* the city, which rises and falls on its own.
///
/// **Why this exists.** `Demand` is a closed loop: it measures the city's own
/// residents against the city's own jobs, adds the tax rate, and that is all.
/// A closed loop settles, which is exactly what `PlateauDiagnosticTests`
/// measured — post-plateau, residential demand moved by 0.05 across fourteen
/// hundred ticks. Phase 2 gave the city consequences for neglect and the
/// headline number barely moved, and the note written at the time said why:
/// "Phase 2 gives the city consequences; it does not give it weather."
///
/// This is the weather. The region the city sits in has its own boom and bust,
/// which pushes on all three demands independently of anything the player
/// does. In a boom there is somewhere new to grow; in a slump the marginal
/// lots — the ones `localDemand` already sorts to the bottom — cross
/// `CitySimulator.abandonmentDemand` and empty out. The city stops being a
/// sum that balances and becomes a thing with a climate.
///
/// **It is a clock, not a dice roll**, and that is deliberate on three counts.
/// A player can only plan against pressure they can read: a random walk that
/// re-rolls every tick is noise, and noise is not a thing you steer against,
/// it is a thing you endure. The playtest harness needs a city to be
/// reproducible tick for tick, and drawing from the simulation's RNG would
/// put a balance measurement at the mercy of how many other rolls happened
/// first. And `AlwaysZeroRNG` — which most fixtures in this project use, and
/// which passes every probability gate — would have pinned a random cycle at
/// one extreme forever, quietly turning every test city into a permanent
/// depression.
struct RegionalEconomy: Equatable, Codable, Sendable {

    /// Ticks since the city was founded. The whole of the state: the cycle is
    /// a pure function of it, so a city's economic history is reproducible and
    /// a save is one integer.
    var elapsed: Int = 0

    /// How far the region can push a sector's demand, either way.
    ///
    /// Sized against the two numbers it has to sit between.
    /// `CitySimulator.abandonmentDemand` is −0.75 and a settled city already
    /// sits near −0.5, so a slump of this depth carries the city average to
    /// the line and the least desirable quarter of lots (which
    /// `CitySimulator.localDemand` offsets by up to 0.3 further) past it —
    /// bad neighbourhoods empty during a downturn, good ones ride it out.
    /// Meanwhile it stays *below* `Demand.taxDemandSensitivity`'s 0.5 ceiling,
    /// so the player's own lever is still the stronger one: the region can
    /// make a bad tax rate hurt, but it cannot overrule a good one.
    static let amplitude: Double = 0.25

    /// How far *this* region swings. Defaults to `amplitude`; zero means a
    /// region with no weather at all.
    ///
    /// An instance value rather than only the static one, because "how
    /// volatile is the world outside" is a real dial — a difficulty setting,
    /// or a sandbox mode, is exactly this number — and because a great many
    /// fixtures are about the city's own arithmetic and need the outside world
    /// to hold still while they measure it. `DemandTests` asserts that a
    /// balanced city reads exactly zero; with weather on, "exactly zero"
    /// becomes "zero plus wherever the cycle is", and a test written that way
    /// would be pinning the cycle's shape rather than the demand formula.
    var swing: Double = RegionalEconomy.amplitude

    /// A region with no economy of its own — the world as it was before phase
    /// 5, for fixtures that want to measure the city and nothing else.
    static let calm = RegionalEconomy(elapsed: 0, swing: 0)

    /// The cycle for one sector: two sine waves of co-prime period, summed.
    ///
    /// One sine is a metronome — a player would learn its half-period and the
    /// mechanic would become a countdown rather than a climate. Two of
    /// co-prime period beat against each other, so consecutive booms differ in
    /// height and spacing and the pattern does not repeat inside any session,
    /// while the thing stays smooth and bounded and always comes back. The
    /// long period sets the era; the short one roughens it.
    ///
    /// Periods are in ticks. At `SimulationSpeed.normal` the long cycles run
    /// somewhere around two to four minutes of play, which is the span a
    /// player can actually notice a trend across and respond to — short enough
    /// to matter this session, long enough that riding one out is a decision
    /// rather than a pause.
    private static func wave(elapsed: Int, long: Int, short: Int, phase: Double) -> Double {
        let t = Double(elapsed)
        let major = sin(2 * .pi * t / Double(long) + phase)
        let minor = sin(2 * .pi * t / Double(short) + phase * 1.7)
        // Normalised by the sum of the weights, so the result is a true ±1
        // rather than something that only reaches its extremes when both
        // waves happen to peak together.
        return (major + 0.6 * minor) / 1.6
    }

    /// Each sector gets its own periods and phase, so they do not move
    /// together.
    ///
    /// This is the part that makes the mechanic a decision rather than a
    /// volume knob. If all three rose and fell in step, a slump would just be
    /// "everything is worse for a while" and there would be nothing to do
    /// about it but wait. Decoupled, a city can be short of jobs while housing
    /// is oversupplied — which is a thing the player answers by *re-zoning*,
    /// using the RCI meter they already have, rather than by waiting.
    ///
    /// Every period is prime, so no two sectors share a beat.
    /// The longest period any sector runs on.
    ///
    /// Exposed because a mean taken over less than this is a mean of the
    /// weather, not of the city — which is a trap every steady-state
    /// measurement in the playtest harness now has to avoid. See
    /// `PlaytestHarness.RunResult.tail`.
    static let longestCycle = 421

    private static func cycle(for zone: ZoneType, elapsed: Int) -> Double {
        switch zone {
        case .residential: return wave(elapsed: elapsed, long: 347, short: 139, phase: 0)
        case .commercial: return wave(elapsed: elapsed, long: 421, short: 173, phase: 2.1)
        case .industrial: return wave(elapsed: elapsed, long: 293, short: 199, phase: 4.2)
        // Same "always has an answer, never an optional" contract
        // `CityDemand.value(for:)` and `ServiceFunding.level(for:)` keep: the
        // region has no opinion about how many police stations you want.
        default: return 0
        }
    }

    /// What the region is doing to demand for `zone` right now, in the same
    /// −1…1 units `CityDemand` uses.
    func strength(for zone: ZoneType) -> Double {
        Self.cycle(for: zone, elapsed: elapsed) * swing
    }

    /// One tick older. Called from `GameController.advanceSimulation()` next
    /// to the whole-map caches, immediately before `Demand.compute` reads it.
    func advanced() -> RegionalEconomy {
        RegionalEconomy(elapsed: elapsed + 1, swing: swing)
    }

    /// What the region is doing, in one word, for the player.
    ///
    /// The RCI meter already shows demand, so a player can see the bars sag —
    /// but not *why*, and "the region is in a slump" and "you over-zoned
    /// housing" call for opposite responses. A city builder that punishes you
    /// for something it never told you about is just unfair, and this project
    /// has a standing rule that every warning the game raises has to have an
    /// answer the player can act on right now. The answer to a slump is: stop
    /// zoning, cut the tax rate, and wait — so the slump has to be visible.
    enum Mood: String, Equatable, Codable, Sendable {
        case boom, steady, slump

        var label: String {
            switch self {
            case .boom: return "BOOM"
            case .steady: return "STEADY"
            case .slump: return "SLUMP"
            }
        }
    }

    /// Averaged across the three sectors, because the headline is about the
    /// region rather than about any one industry — a player who wants the
    /// per-sector detail is already looking at the RCI meter, which now
    /// carries this inside it.
    var mood: Mood {
        let mean = [ZoneType.residential, .commercial, .industrial]
            .reduce(0.0) { $0 + strength(for: $1) } / 3
        // **Measured, not guessed.** The first value was half of full
        // amplitude, on the reasoning that "steady" should be the common case.
        // It was — far too much so: the mean of three *decoupled* sectors has
        // roughly a third of the variance of any one of them, so the region
        // read boom or slump on 12% of ticks and a player could finish a
        // session without meeting either. At 0.35 it is named on about a third
        // of ticks, which is often enough to be a thing that happens to you
        // and still rare enough that the badge means something when it lights.
        let threshold = swing * 0.35
        if mean > threshold { return .boom }
        if mean < -threshold { return .slump }
        return .steady
    }
}
