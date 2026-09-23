import XCTest
@testable import AlphaPlusPlus

/// **Does the soundtrack keep still?**
///
/// The interesting failure here is not choosing the wrong track — it is
/// choosing a *correct* one too often. A director that answers every state
/// change faithfully will cut between pieces every few seconds, and that is
/// far more annoying than playing one loop forever.
///
/// So the headline test is a measurement rather than an assertion about a
/// fixture: run a real city's economy past the director for a long game and
/// report how often the music actually changes. That diagnostic is what
/// found the rain cue switching tracks every 65 seconds, and is why there is
/// no rain cue.
final class MusicDirectorTests: XCTestCase {

    /// One second of real time per call, which is roughly how often the
    /// caller will ask.
    private func run(_ director: inout MusicDirector,
                     moods: [MusicDirector.CityMood],
                     secondsPerDay: TimeInterval) -> [MusicDirector.Cue] {
        moods.map { director.update($0, elapsed: secondsPerDay) }
    }

    // MARK: - The measurement

    /// **How often does the music change over a long game?**
    ///
    /// 1,500 days at `SimulationSpeed.normal` is fifty minutes of play, and
    /// the city's shape over it is the arc every scenario in the playtest
    /// harness produces: founded, built, settled, with the region's own
    /// cycle underneath and real weather on top.
    func testTheTrackDoesNotChangeOftenOverALongGame() {
        var director = MusicDirector()
        var economy = RegionalEconomy()
        var peak = 0
        var moods: [MusicDirector.CityMood] = []
        // A plain seeded generator rather than one of `DeterministicRNGs`:
        // those sit at the ends of the range on purpose, and this needs a
        // middle. Deterministic either way, which is the requirement.
        var seed: UInt64 = 0x5EED_1EAF

        for day in 0 ..< 1_500 {
            economy.elapsed = day
            // **The fixture has to be a city where things happen.** The first
            // version climbed a clean exponential to 3,300 and held it, with
            // no fires and nothing lost — and duly reported one track change
            // in fifty minutes, which measures the fixture rather than the
            // director. A real city rides the regional cycle and burns
            // occasionally; `PlateauDiagnosticTests` measures both.
            let trend = 3_300 * (1 - exp(-Double(day) / 55.0))
            let swing: Double
            switch economy.mood {
            case .boom: swing = 1.04
            case .steady: swing = 1.0
            case .slump: swing = 0.90
            }
            let population = Int(trend * swing)
            peak = max(peak, population)

            // **Alight on an eighth of days, and almost always one block.**
            // The first version rolled 0–4 uniformly whenever it caught,
            // which made a four-block emergency forty times more common than
            // the game produces one — so the diagnostic was measuring a city
            // permanently ablaze. `PlateauDiagnosticTests` measures a
            // serviced city alight on 13% of ticks with a *worst moment* of
            // four blocks, so four has to be rare rather than routine.
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let roll = Double(seed >> 11) / Double(1 << 53)
            let blocksAlight: Int
            switch roll {
            case ..<0.008: blocksAlight = 4
            case ..<0.021: blocksAlight = 3
            case ..<0.054: blocksAlight = 2
            case ..<0.130: blocksAlight = 1
            default: blocksAlight = 0
            }

            moods.append(MusicDirector.CityMood(
                hasCity: true,
                population: population,
                peakPopulation: peak,
                elapsedDays: day,
                blocksAlight: blocksAlight,
                regionalMood: economy.mood
            ))
        }

        let secondsPerDay = SimulationSpeed.normal.tickInterval
        let cues = run(&director, moods: moods, secondsPerDay: secondsPerDay)

        var changes = 0
        for index in 1 ..< cues.count where cues[index] != cues[index - 1] { changes += 1 }
        let minutes = Double(moods.count) * secondsPerDay / 60
        let meanDwell = changes > 0 ? minutes / Double(changes) : minutes

        var played: [MusicDirector.Cue: Int] = [:]
        for cue in cues { played[cue, default: 0] += 1 }
        let breakdown = played
            .sorted { $0.value > $1.value }
            .map { "\($0.key.rawValue) \(Int(Double($0.value) / Double(cues.count) * 100))%" }
            .joined(separator: ", ")

        print(String(format: "🎵 %.0f minutes of play: %d track changes, "
                     + "mean %.1f min between them — %@",
                     minutes, changes, meanDwell, breakdown as NSString))

        // **The printed number is the measurement; this is only a tripwire.**
        // It currently reads 1.5 minutes between changes, and the bound sits
        // at 1.0 rather than just under that reading on purpose — a bound
        // that holds by a few percent is a coin toss with a comment on it,
        // which this project has recorded three times in other costumes.
        // What it guards is restlessness, not correctness.
        XCTAssertGreaterThan(meanDwell, 1.0,
                             "the soundtrack changes track more often than once a minute")
        // And it has to actually respond to something: one track for fifty
        // minutes would pass the bound above and fail the point of the
        // director entirely.
        XCTAssertGreaterThan(changes, 1, "the soundtrack never changed at all")
    }

    // MARK: - The rules

    /// **The measurement that killed the rain cue**, kept because it is the
    /// reason the library's seventh track answers the pause instead.
    ///
    /// `Weather` is two sines of period 23 and 31 days. Whatever threshold
    /// you pick, the longest wet spell it can produce is **ten days** — and
    /// at `SimulationSpeed.normal` that is twenty seconds, against tracks
    /// that run sixteen to forty. So rain could never have carried one: it
    /// would always cut away from a piece and back before either was heard.
    func testNoRainSpellLastsLongEnoughToCarryATrack() {
        var spells: [Int] = []
        var run = 0
        for day in 0 ..< 1_500 {
            if Weather.rainfall(onDay: day) > Weather.wetThreshold { run += 1 }
            else if run > 0 { spells.append(run); run = 0 }
        }
        let longest = spells.max() ?? 0
        let seconds = Double(longest) * SimulationSpeed.normal.tickInterval
        // Against the track rain was *written for*, which is the sharpest
        // form of the claim: the weather cannot fill even its own piece.
        // (Measured against the shortest track in the library it is a near
        // thing — 20s against Overdrive's 16 — and an assertion that said
        // "shorter than every track" would have been false. The first
        // version of this said exactly that and failed, which is the good
        // version of this failure.)
        let ownTrack = MusicLibrary.standby.duration
        print(String(format: "🎵 longest rain spell %d days = %.0fs of play, "
                     + "against %.0fs for the track it was written for",
                     longest, seconds, ownTrack))
        XCTAssertLessThan(seconds, ownTrack,
                          "rain now outlasts the track written for it, so it could carry "
                          + "one after all — MusicDirector's note about why it does not is stale")
    }

    /// **A pause is heard at once**, because it is a button rather than a
    /// mood: music that carried on for forty seconds would read as the
    /// control not having worked. And unpausing gives the city its music
    /// back just as fast.
    func testPausingAndResumingAreBothImmediate() {
        var director = MusicDirector(cue: .building)
        let running = MusicDirector.CityMood(hasCity: true, population: 400, peakPopulation: 400,
                                             elapsedDays: 200)
        _ = director.update(running, elapsed: 120)
        XCTAssertEqual(director.cue, .building)

        var paused = running
        paused.isPaused = true
        XCTAssertEqual(director.update(paused, elapsed: 0.5), .standby,
                       "the music ignored the pause button")
        XCTAssertEqual(director.update(running, elapsed: 0.5), .building,
                       "the music did not come back when the city did")
    }

    /// A stopped city is not on fire and not in a slump — it is *waiting*,
    /// so the pause outranks every claim about the city itself.
    func testAPausedCityIsScoredAsPausedWhateverElseIsTrue() {
        var director = MusicDirector(cue: .building)
        let burningAndPaused = MusicDirector.CityMood(
            hasCity: true, population: 900, peakPopulation: 1_500, elapsedDays: 400,
            blocksAlight: 9, regionalMood: .slump, isPaused: true
        )
        XCTAssertEqual(director.update(burningAndPaused, elapsed: 1), .standby)
    }

    /// **Fire interrupts; everything else waits.** A city alight has to be
    /// heard now — the whole point of scoring a state is that it arrives with
    /// the state rather than half a minute later.
    func testAFireCutsInImmediatelyAndEverythingElseDoesNot() {
        var director = MusicDirector(cue: .building)
        let burning = MusicDirector.CityMood(hasCity: true, population: 900, peakPopulation: 900,
                                             elapsedDays: 200, blocksAlight: 4)
        XCTAssertEqual(director.update(burning, elapsed: 1), .pressure,
                       "a city on fire waited for the dwell timer")

        // And the way back out is not immediate, so the music does not snap
        // back the instant the last flame goes out.
        var calm = burning
        calm.blocksAlight = 0
        XCTAssertEqual(director.update(calm, elapsed: 1), .pressure)
        XCTAssertEqual(director.update(calm, elapsed: MusicDirector.minimumDwell), .settled)
    }

    /// Hysteresis: a city hovering on a boundary does not flip. One block
    /// alight keeps `pressure` once it has started, and does not start it.
    func testOneBurningBlockDoesNotStartOrStopTheUrgentTrack() {
        var quiet = MusicDirector(cue: .building)
        let oneAlight = MusicDirector.CityMood(hasCity: true, population: 900, peakPopulation: 900,
                                               elapsedDays: 200, blocksAlight: 1)
        XCTAssertNotEqual(quiet.update(oneAlight, elapsed: 120), .pressure,
                          "a single incident became the city's headline")

        var busy = MusicDirector(cue: .pressure)
        XCTAssertEqual(busy.update(oneAlight, elapsed: 120), .pressure,
                       "the urgent track dropped out while a block was still alight")
    }

    /// A new map gets the founding track, and does not go back to it once
    /// the city is real — however badly the city then does.
    func testACityIsOnlyFoundedOnce() {
        var director = MusicDirector(cue: .title)
        let new = MusicDirector.CityMood(hasCity: true, population: 20, peakPopulation: 20, elapsedDays: 5)
        XCTAssertEqual(director.update(new, elapsed: 1), .founding)

        let grown = MusicDirector.CityMood(hasCity: true, population: 900, peakPopulation: 900, elapsedDays: 200)
        XCTAssertEqual(director.update(grown, elapsed: MusicDirector.minimumDwell), .settled)

        // Burned back down to nothing, but it is still not a new city.
        let ruined = MusicDirector.CityMood(hasCity: true, population: 10, peakPopulation: 900, elapsedDays: 400)
        let after = director.update(ruined, elapsed: MusicDirector.minimumDwell)
        XCTAssertNotEqual(after, .founding, "a ruined city was scored as a brand new one")
    }

    /// Decline needs the region against you *and* something actually lost.
    /// A slump a city is growing through is not a decline.
    func testASlumpYouAreGrowingThroughIsNotADecline() {
        var director = MusicDirector(cue: .building)
        let growing = MusicDirector.CityMood(hasCity: true, population: 1_000, peakPopulation: 1_000,
                                             elapsedDays: 300, regionalMood: .slump)
        XCTAssertNotEqual(director.update(growing, elapsed: 120), .decline)

        let losing = MusicDirector.CityMood(hasCity: true, population: 700, peakPopulation: 1_000,
                                            elapsedDays: 400, regionalMood: .slump)
        XCTAssertEqual(director.update(losing, elapsed: 120), .decline)
    }

    /// With no city there is nothing to score but the title.
    func testAnEmptyMapPlaysTheTheme() {
        var director = MusicDirector(cue: .building)
        XCTAssertEqual(director.update(.init(), elapsed: 120), .title)
    }

    /// Every cue names a track, and no two cues name the same one — a cue
    /// that shares a track with another is a state the player cannot hear.
    func testEveryCueHasItsOwnTrack() {
        let names = MusicDirector.Cue.allCases.map(\.track.name)
        XCTAssertEqual(Set(names).count, names.count, "two cues play the same track")
    }
}
