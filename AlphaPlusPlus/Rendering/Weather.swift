import Foundation

/// **When it rains, and how hard.**
///
/// A rendering concern driven by simulation time, which is why it lives here
/// rather than in `Simulation/`: nothing in the city's economics reads it, and
/// putting it there would claim a mechanic the game does not have. It takes
/// the one clock that already exists — `CityMap.elapsedDays` — rather than
/// starting a second one beside it, the same rule `CityDate` follows.
///
/// **A clock, not a dice roll**, for the three reasons `RegionalEconomy` is
/// one and which apply here unchanged:
///
/// - A player can only read a trend. Weather that re-rolled every tick would
///   be noise — and worse here than there, because this one is *visible*: a
///   downpour flickering on and off between frames is a broken effect rather
///   than a bad forecast.
/// - Every render test in this project has to be reproducible. A city
///   photographed on day 200 must look the same every run, or the filmstrip
///   stops being a yardstick.
/// - `AlwaysZeroRNG` passes every probability gate and most fixtures use it,
///   so a random cycle would leave every test city in a permanent storm.
///
/// Two sines of co-prime period, summed and biased below zero. One sine is a
/// metronome; two that beat against each other give storms of differing depth
/// and spacing that never repeat inside a session. The bias is what makes
/// rain *occasional* — without it the sum spends half its time positive and
/// the city is wet more often than it is dry.
enum Weather {

    /// Days per cycle. Co-prime, and far shorter than
    /// `RegionalEconomy`'s 293–421: an economy turns over across a year and
    /// weather should pass in a week, or every session is one long storm.
    private static let shortCycle = 23.0
    private static let longCycle = 31.0

    /// How much of the sum is thrown away before anything falls.
    ///
    /// Raising it makes rain rarer and shorter. **Measured over 400 days at
    /// 0.35: it rains on 22% of them, in spells averaging 8 days** — which at
    /// `SimulationSpeed.normal`'s two seconds a day is about sixteen seconds
    /// of rain every couple of minutes. Often enough to be a thing the city
    /// does, rare enough that arriving in one still reads as weather rather
    /// than a filter somebody left switched on.
    ///
    /// The first guess at this comment said "spells of two to four", which
    /// was reasoning rather than counting; the numbers above are what the
    /// function actually produces.
    private static let dryBias = 0.35

    /// 0 for a clear night, 1 for the heaviest this gets.
    static func rainfall(onDay day: Int) -> Double {
        let d = Double(day)
        let sum = (sin(2 * .pi * d / shortCycle) + sin(2 * .pi * d / longCycle)) / 2
        return max(0, sum - dryBias) / (1 - dryBias)
    }

    /// Past this the streets are wet, which is a different thing from rain
    /// falling: asphalt stays wet after a shower passes, and the reflection is
    /// the part worth looking at. Deliberately below any rainfall worth
    /// drawing, so the ground is already shining as the first drops land
    /// rather than snapping on underneath them.
    static let wetThreshold = 0.05

    /// How reflective the ground is on a given day — the wetness the renderer
    /// actually draws with, eased so it arrives and leaves rather than
    /// switching.
    static func wetness(onDay day: Int) -> Double {
        let rain = rainfall(onDay: day)
        guard rain > wetThreshold else { return 0 }
        // Quantised into steps, because this feeds a texture cache key and a
        // value moving by a thousandth a day would rebuild every building in
        // the city every tick — the same reason road wear is quantised into
        // five bands before it reaches a key.
        //
        // Floored at one step rather than rounded to the nearest, because
        // rounding sent the first and last day of every shower to zero: it
        // was raining on dry ground, which is not a thing.
        return max(1, (min(1, rain / 0.6) * 4).rounded()) / 4
    }
}
