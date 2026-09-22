import Foundation

/// **Which track the city has earned.**
///
/// The library was written to states on purpose — a map being founded, one
/// being built, one settled, one under pressure, one in decline, and rain
/// over any of them — so this is the piece that makes those intents real.
/// Without it the tracks are six loops and a shuffle button, which is what
/// the file's own doc comment says a soundtrack must not be.
///
/// **It is a state machine, not a lookup**, and the reason is the listener
/// rather than the city. A visual overlay can change every tick and cost
/// nothing; a track change is the most disruptive thing this whole module can
/// do, and one that fires twice a minute is worse than no track selection at
/// all. So two rules run through everything below:
///
/// - **Hysteresis**, the same device `CitySimulator.declineMargin` and the
///   close-zoom detail tier already use: the condition to *enter* a cue is
///   stricter than the condition to stay in it, so a city sitting on a
///   boundary does not flip back and forth forever.
/// - **A minimum dwell**, because even a correct change is a wrong change if
///   it happens before the last one finished landing.
///
/// And one exception that makes the rest work: **urgency interrupts,
/// ambience waits.** A city catching fire has to be heard now — a soundtrack
/// that gets round to mentioning it in thirty seconds is not scoring the
/// game, it is running late.
struct MusicDirector {

    /// What the music is answering. One case per state the library was
    /// written for, plus the title screen.
    enum Cue: String, Equatable, CaseIterable {
        case title, founding, building, settled, pressure, decline, standby

        var track: Track {
            switch self {
            case .title: return MusicLibrary.theme
            case .founding: return MusicLibrary.firstLight
            case .building: return MusicLibrary.neonGrid
            case .settled: return MusicLibrary.smallHours
            case .pressure: return MusicLibrary.overdrive
            case .decline: return MusicLibrary.vacancy
            case .standby: return MusicLibrary.standby
            }
        }

        /// Whether this cue may interrupt before the minimum dwell is up.
        ///
        /// Three things are allowed to, and they divide the same way the
        /// pause rule already divides the renderer's animations — **what the
        /// player just did happens now; what the city is doing can wait**:
        ///
        /// - `pressure`, because a city alight has to be heard with the fire
        ///   rather than half a minute after it. Leaving it still waits, so
        ///   the last flame going out does not snap the music back.
        /// - `standby` and `title`, because both are answers to a button.
        ///   Music that carried on for forty seconds after a player hit pause
        ///   would read as the control not having worked.
        var interrupts: Bool { self == .pressure || self == .standby || self == .title }
    }

    // MARK: - What the city looks like from here

    /// Everything the choice depends on, as a value.
    ///
    /// A snapshot rather than the live controller, for the reason `LotStatus`
    /// is a value: the rules become something that can be *asked* a question
    /// rather than only run, and every branch below is reachable from a test
    /// without building a city that happens to be in that state.
    struct CityMood: Equatable {
        var hasCity = false
        var population = 0
        var peakPopulation = 0
        var elapsedDays = 0
        var blocksAlight = 0
        var regionalMood: RegionalEconomy.Mood = .steady
        /// The simulation is stopped. Not a mood the city is in — a thing the
        /// player did — which is exactly why it can carry a track: it lasts
        /// as long as they want it to, and nothing else here does.
        var isPaused = false

        /// How far below its own best the city is, 0 to 1. The city's memory
        /// of what it used to be, which is what makes decline *decline*
        /// rather than merely "small".
        var lostFraction: Double {
            guard peakPopulation > 0 else { return 0 }
            return max(0, Double(peakPopulation - population) / Double(peakPopulation))
        }

        static func of(map: CityMap, population: Int, peakPopulation: Int,
                       isRunning: Bool) -> CityMood {
            CityMood(
                hasCity: population > 0 || map.elapsedDays > 0,
                population: population,
                peakPopulation: max(peakPopulation, population),
                elapsedDays: map.elapsedDays,
                blocksAlight: Fire.count(in: map),
                regionalMood: map.regionalEconomy.mood,
                isPaused: !isRunning
            )
        }
    }

    // MARK: - The thresholds

    /// A city is still being founded until it is this old **or** this big.
    ///
    /// Days rather than population alone, and deliberately the same ninety
    /// `CityHazards.gracePeriodDays` uses: that is already this project's
    /// answer to "how long is a city new", and two different numbers meaning
    /// the same thing is how the service radius ended up being four
    /// constants that were all 0.3 by coincidence.
    static let foundingDays = 90
    static let foundingPopulation = 150

    /// Settled is about *stability*, not size: a city can be large and still
    /// climbing, and Small Hours is for the one that has stopped.
    static let settledPopulation = 800
    /// Growth below this share of the peak, over the window below, reads as
    /// having stopped.
    static let settledGrowthFraction = 0.02
    static let stabilityWindowDays = 60

    /// Decline needs the region against you *and* something actually lost.
    /// A slump you are still growing through is not a decline, and this
    /// project has shipped a mechanic that never binds before.
    static let decliningLossFraction = 0.08

    /// One block alight is an incident; this many is the city's problem.
    ///
    /// **Four, because that is the worst a well-run city ever sees.**
    /// `PlateauDiagnosticTests` measures a serviced city peaking at four
    /// blocks alight and an unserviced one at five, so this is the line
    /// between "there is a fire" and "this city is in trouble". At three it
    /// was neither: the diagnostic measured Overdrive filling **42%** of a
    /// fifty-minute session, because an interrupting cue that then holds for
    /// the full dwell turns every brief incident into forty seconds of
    /// emergency — and a soundtrack that is urgent nearly half the time is
    /// not urgent at all.
    static let pressureBlocksAlight = 4

    /// **Nothing ambient changes inside this.** Forty seconds is a little
    /// over one loop of the longest gameplay track, so every change lands
    /// after a piece has at least been heard through once.
    static let minimumDwell: TimeInterval = 40

    // MARK: - Why the weather is not in this list
    //
    // **Rain cannot carry a track, and that is measurable rather than a
    // matter of taste.** `Weather` is two sines of period 23 and 31 days, so
    // the longest wet spell it can produce is **ten days** — twenty seconds
    // at `SimulationSpeed.normal`, against tracks that run sixteen to forty.
    // There is no threshold that rescues it: even the maximum shower is
    // shorter than one loop of most of the library, so scoring rain means
    // cutting away from a piece and back before either has been heard. Built
    // that way first, it took the music on 29% of days and handed it back
    // every time; the diagnostic in `MusicDirectorTests` is what said so.
    //
    // It is the rule `RegionalEconomy` already records, met from the other
    // end: *a cycle has to be long compared to whatever responds to it.*
    // There it was booms too short to build into; here it is weather too
    // short to score. The track that was written for rain now answers the
    // pause instead — the one state a player holds for as long as they like.

    // MARK: - Choosing

    private(set) var cue: Cue = .title
    /// Seconds the current cue has been playing.
    private(set) var dwell: TimeInterval = 0

    init(cue: Cue = .title) { self.cue = cue }

    /// Advance the director and return what should be playing.
    ///
    /// - Parameter elapsed: real seconds since the last call. Real rather
    ///   than simulated, because the rule it feeds is about how long a
    ///   listener has been hearing something — which `SimulationSpeed` must
    ///   not be able to change.
    mutating func update(_ mood: CityMood, elapsed: TimeInterval) -> Cue {
        dwell += elapsed

        let wanted = want(mood)
        guard wanted != cue else { return cue }
        // Leaving an interrupting cue is immediate too when the thing that
        // justified it is a button: unpausing has to give the city its music
        // back at once, or the play button reads as broken.
        let immediate = wanted.interrupts || cue == .standby || cue == .title
        guard dwell >= Self.minimumDwell || immediate else { return cue }

        cue = wanted
        dwell = 0
        return cue
    }

    /// The cue the city deserves, ignoring how long the last one has run.
    /// Ranked, highest first, so that two things being true at once has one
    /// answer rather than depending on the order the checks were written in.
    private func want(_ mood: CityMood) -> Cue {
        guard mood.hasCity else { return .title }
        // Above everything, because it is not a claim about the city at all:
        // a stopped city is not on fire or in a slump, it is *waiting*.
        if mood.isPaused { return .standby }
        if isUnderPressure(mood) { return .pressure }
        if isDeclining(mood) { return .decline }
        if isFounding(mood) { return .founding }
        if isSettled(mood) { return .settled }
        return .building
    }

    // Each test is written so that the *exit* condition is looser than the
    // entry one, by asking whether this cue is already playing. That is the
    // hysteresis, and keeping it inside each predicate is what stops it
    // being a margin somebody has to remember to apply at the call site.

    private func isUnderPressure(_ mood: CityMood) -> Bool {
        let needed = cue == .pressure ? 1 : Self.pressureBlocksAlight
        return mood.blocksAlight >= needed
    }

    private func isDeclining(_ mood: CityMood) -> Bool {
        guard mood.regionalMood == .slump || cue == .decline else { return false }
        let needed = cue == .decline ? Self.decliningLossFraction / 2 : Self.decliningLossFraction
        return mood.lostFraction >= needed
    }

    private func isFounding(_ mood: CityMood) -> Bool {
        guard cue != .founding else {
            // Once a city is being built it does not go back to being
            // founded, however small a fire leaves it.
            return mood.elapsedDays < Self.foundingDays && mood.population < Self.foundingPopulation * 2
        }
        return mood.elapsedDays < Self.foundingDays && mood.population < Self.foundingPopulation
    }

    private func isSettled(_ mood: CityMood) -> Bool {
        guard mood.population >= Self.settledPopulation else { return false }
        // Having been at its peak recently is the proxy for "has stopped
        // climbing": a city still growing is above where it was, and one that
        // has fallen away is the decline case above.
        return mood.lostFraction <= Self.settledGrowthFraction
    }
}
