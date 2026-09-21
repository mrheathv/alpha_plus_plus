import Foundation

/// **One piece of music, as data.**
///
/// The first version of the soundtrack was a single score hardcoded into the
/// renderer. That is the right shape for finding out whether the instrument
/// works at all, and the wrong shape the moment there is more than one piece
/// — which there has to be, because a title theme and something you listen to
/// for three hours are not the same job.
///
/// So the renderer takes a `Track` and the library holds several, exactly the
/// split `ToolCategory` draws between what a button *does* and the code that
/// lays buttons out.
struct Track {

    /// What it is called, and what the file is named when rendered.
    let name: String
    /// A sentence on what it is *for* — which mood, and where it plays.
    let intent: String

    let beatsPerMinute: Double
    let bars: Int

    /// One chord per bar, MIDI note numbers, root first. Three notes is a
    /// triad; a fourth makes it a seventh or an add-nine, and the pad simply
    /// plays whatever is listed.
    let progression: [[Int]]
    /// Bass roots, one per bar. Usually the chord roots an octave or two down.
    ///
    /// **Nothing below MIDI 28** — E1, 41 Hz. The first library had roots down
    /// to 23 (31 Hz), which is sub-bass: below what any laptop speaker makes,
    /// and a quarter of the mix's total power spent on a note only a
    /// subwoofer would hear. A bass line that leaps up an octave to stay
    /// above that floor is ordinary synth-bass writing; one that sits under it
    /// is inaudible on the machines this game ships on.
    let bassRoots: [Int]

    /// The tune, or nothing.
    ///
    /// **Most gameplay tracks have none**, and that is a design decision
    /// rather than laziness. A memorable melody is exactly what you want from
    /// a theme heard for thirty seconds at a title screen, and exactly what
    /// grates when it comes round for the hundredth time while somebody is
    /// concentrating on a budget. Game music that has to last recedes.
    let melody: [Phrase]

    struct Phrase {
        let bar: Int
        let beat: Double
        let note: Int
        let length: Double
    }

    /// A sixteenth-note figure running through the chord, or nothing.
    ///
    /// This is what fills the middle of a track that has no melody: something
    /// moving between the bass and the pad so the arrangement has a pulse
    /// without having a hook.
    let arpeggio: Arpeggio?

    struct Arpeggio {
        /// Which chord tones, by index, cycled in this order.
        let shape: [Int]
        /// How far up from the chord's written octave.
        let octave: Int
        var level: Double = 0.16
        var timbre: Timbre = .square

        enum Timbre {
            /// Hollow and even. The default, and the one that cuts.
            case square
            /// Brighter and buzzier — reads as urgency.
            case saw
            /// A damped sine with a touch of second harmonic: a plucked
            /// string or a dripping tap, for the tracks that should not push.
            case pluck
        }
    }

    let drums: DrumKit

    enum DrumKit {
        /// Kick on one and three, snare on two and four, hats throughout.
        /// Half-time, which leaves room.
        case full
        /// Four on the floor. Kick on every beat, which is the genre's own
        /// pulse — a `.full` kit at the same tempo reads as slower.
        case driving
        /// Kick and hats, no backbeat. Quieter, and it stops a long loop from
        /// nagging.
        case sparse
        /// Nothing. For the tracks that are mostly weather.
        case none
    }

    /// What the bass does with its root.
    ///
    /// **This is most of the difference between two tracks built from one
    /// instrument.** The first library ran every track on driving eighths,
    /// and a 84 BPM piece and a 120 BPM piece with the same bass figure are
    /// the same piece at two speeds.
    enum BassPattern {
        /// Eighths on the root, an octave jump on the last. The workhorse.
        case drivingEighths
        /// Eighths bouncing root, octave, root, octave — the synthwave bass.
        case octaves
        /// Sixteenths, the octave on every fourth. Relentless; for pressure.
        case sixteenths
        /// One note a bar, swelling in. For the tracks that should breathe.
        case held
    }
    var bassPattern: BassPattern = .drivingEighths

    /// The pad's filter, in hertz, at rest.
    var padCutoff: Double = 3_000
    /// How far the pad's filter drifts around `padCutoff`, 0 to 1, over a
    /// slow four-bar cycle. A pad on a static filter is a held chord; one
    /// whose tone moves is a pad. This is the cheapest thing in the file and
    /// it is the one that makes a chord sound like it is being *played*.
    var padSweep: Double = 0

    /// **Entrances.** Which bar each voice first plays in.
    ///
    /// A track where everything starts on bar one is a loop; one where the
    /// pad is alone for four bars and the drums arrive at eight has a shape.
    /// These are what let the same four voices be an *arrangement*.
    var bassEntersAtBar = 0
    var arpeggioEntersAtBar = 0
    var drumsEnterAtBar = 0

    /// Where a live player should loop back to once the intro has been heard
    /// — an entrance is something you hear once, not every time round.
    var loopsFromBar: Int { max(bassEntersAtBar, arpeggioEntersAtBar, drumsEnterAtBar) }

    /// Per-voice level trims, so two tracks built from the same instruments
    /// can still be different records.
    var bassLevel: Double = 1
    var padLevel: Double = 1
    var leadLevel: Double = 1
    var drumLevel: Double = 1

    var secondsPerBeat: Double { 60 / beatsPerMinute }
    var beatsPerBar: Int { 4 }
    var duration: Double { Double(bars * beatsPerBar) * secondsPerBeat }
}

/// **The soundtrack: one theme and the tracks that play under a city.**
///
/// The split matters more than the individual pieces. A title theme is heard
/// for half a minute and should be the thing you hum; a gameplay track is
/// heard for hours and should be the thing you stop noticing. Writing them to
/// the same brief is how a game ends up with music people mute.
///
/// **Every gameplay track answers a state the city can be in**, because the
/// plan is for the game to pick between them the way `Weather` picks a day: a
/// city just founded, one being built, one settled, one under pressure, one
/// in decline, and rain over any of them. A track that answers nothing is
/// wallpaper, and the list would grow without ever getting better.
enum MusicLibrary {

    /// The title theme — the one with the tune in it.
    static let theme = Track(
        name: "theme",
        intent: "Title screen. Thirty seconds, and the only one allowed a hook.",
        beatsPerMinute: 110,
        bars: 8,
        progression: [
            [57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62],
            [57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62],
        ],
        // The C is up an octave from the first version's C1, which at 33 Hz
        // was the lowest note in the library and inaudible on the machines
        // this ships on.
        bassRoots: [33, 29, 36, 31, 33, 29, 36, 31],
        melody: [
            .init(bar: 0, beat: 0.0, note: 76, length: 1.0),
            .init(bar: 0, beat: 1.0, note: 74, length: 0.5),
            .init(bar: 0, beat: 1.5, note: 72, length: 1.5),
            .init(bar: 0, beat: 3.0, note: 69, length: 1.0),
            .init(bar: 1, beat: 0.0, note: 72, length: 1.0),
            .init(bar: 1, beat: 1.0, note: 69, length: 0.5),
            .init(bar: 1, beat: 1.5, note: 68, length: 1.5),
            .init(bar: 1, beat: 3.0, note: 65, length: 1.0),
            .init(bar: 2, beat: 0.0, note: 64, length: 1.5),
            .init(bar: 2, beat: 1.5, note: 67, length: 0.5),
            .init(bar: 2, beat: 2.0, note: 72, length: 2.0),
            .init(bar: 3, beat: 0.0, note: 74, length: 1.0),
            .init(bar: 3, beat: 1.0, note: 71, length: 0.5),
            .init(bar: 3, beat: 1.5, note: 74, length: 2.5),
            .init(bar: 4, beat: 0.0, note: 81, length: 1.0),
            .init(bar: 4, beat: 1.0, note: 79, length: 0.5),
            .init(bar: 4, beat: 1.5, note: 76, length: 1.5),
            .init(bar: 4, beat: 3.0, note: 74, length: 1.0),
            .init(bar: 5, beat: 0.0, note: 77, length: 1.0),
            .init(bar: 5, beat: 1.0, note: 76, length: 0.5),
            .init(bar: 5, beat: 1.5, note: 72, length: 1.5),
            .init(bar: 5, beat: 3.0, note: 69, length: 1.0),
            .init(bar: 6, beat: 0.0, note: 76, length: 1.5),
            .init(bar: 6, beat: 1.5, note: 72, length: 0.5),
            .init(bar: 6, beat: 2.0, note: 67, length: 2.0),
            .init(bar: 7, beat: 0.0, note: 71, length: 1.0),
            .init(bar: 7, beat: 1.0, note: 74, length: 1.0),
            .init(bar: 7, beat: 2.0, note: 69, length: 2.0),
        ],
        arpeggio: nil,
        // Four on the floor under a hook is the anthem shape; the half-time
        // kit it used to run on made the title read as a verse.
        drums: .driving,
        bassPattern: .octaves,
        padSweep: 0.35
    )

    /// The default. Busy enough to build to, no tune to get sick of.
    static let neonGrid = Track(
        name: "neon-grid",
        intent: "Building. The one that plays while you are laying roads and zoning.",
        beatsPerMinute: 112,
        // Sixteen bars, reported from listening: at eight the loop came
        // round every seventeen seconds, and this is the track that plays
        // *most*. The second half is the same four chords with the sevenths
        // added and the turnaround changed, so it lifts rather than repeats
        // and the seam is half a minute away instead of a quarter.
        bars: 16,
        progression: [
            [57, 60, 64], [50, 53, 57], [55, 59, 62], [53, 57, 60],
            [57, 60, 64], [50, 53, 57], [55, 59, 62], [52, 55, 59],
            [57, 60, 64, 67], [50, 53, 57, 60], [55, 59, 62, 65], [53, 57, 60, 64],
            [57, 60, 64, 67], [50, 53, 57, 60], [53, 57, 60, 64], [52, 56, 59, 62],
        ],
        bassRoots: [33, 38, 31, 29, 33, 38, 31, 28, 33, 38, 31, 29, 33, 38, 29, 28],
        melody: [],
        arpeggio: .init(shape: [0, 1, 2, 1], octave: 2, level: 0.14),
        drums: .driving,
        bassPattern: .octaves,
        padSweep: 0.5,
        padLevel: 1.15
    )

    /// Slow and wide, for a city that is running itself.
    static let smallHours = Track(
        name: "small-hours",
        intent: "Late game. A settled city, the player watching rather than building.",
        beatsPerMinute: 84,
        bars: 8,
        // Am – G – F – E, the descending line, with the last chord turned
        // **major**. Its G♯ is the leading note back to A, so eight bars
        // actually cadence instead of merely stopping — the first version
        // ended on E minor and just ran out.
        progression: [
            [45, 48, 52], [45, 48, 52], [43, 47, 50], [43, 47, 50],
            [41, 45, 48], [41, 45, 48], [40, 43, 47], [40, 44, 47],
        ],
        // **An octave up from the first version, which was inaudible.** Those
        // roots were MIDI 21 down to 16 — A0 at 27.5 Hz to E0 at 20.6 Hz,
        // which is sub-bass: below most speakers, and an octave under where
        // every other track in the library sits. The track was leaning
        // entirely on its pad because its bass was being felt at best.
        bassRoots: [33, 33, 31, 31, 29, 29, 28, 28],
        melody: [],
        // Down an octave too. At `octave: 3` this sat around 880 Hz, which is
        // tinkly rather than warm — the wrong register for the one track whose
        // job is to recede.
        arpeggio: .init(shape: [0, 2, 1, 2], octave: 2, level: 0.1, timbre: .pluck),
        drums: .sparse,
        // A held root that swells in, rather than eighths. This is the track
        // about watching, and a bass that keeps pushing is a bass that keeps
        // asking for something.
        bassPattern: .held,
        padCutoff: 1_900,
        padSweep: 0.4,
        bassLevel: 0.95,
        padLevel: 1.3,
        drumLevel: 0.7
    )

    /// Faster and harder, for when things are going wrong.
    static let overdrive = Track(
        name: "overdrive",
        intent: "Pressure. A big city, or one that is on fire.",
        // 120 rather than 126. With eighth-note bass *and* a sixteenth
        // arpeggio, the extra six beats a minute stopped reading as urgency
        // and started reading as clutter.
        beatsPerMinute: 120,
        bars: 8,
        // **Em – D – C – B, and the B is major.** The first version ran
        // Em – Dm – Cm – Bm, a parallel-minor slide whose C minor and closing
        // G minor are simply outside the key: not spicy, sour. This is the
        // descending tetrachord the genre actually uses, and B major's D♯ is
        // the leading note that pulls hard back to E minor — which is what
        // makes a loop about pressure feel like it is under some.
        progression: [
            [52, 55, 59], [50, 54, 57], [48, 52, 55], [47, 51, 54],
            [52, 55, 59], [50, 54, 57], [48, 52, 55], [47, 51, 54],
        ],
        // E1, then D, C and B *above* it. Written as a straight descent from
        // E1 the last three were 37, 33 and 31 Hz — the three lowest notes in
        // the library, on the one track whose bass is supposed to be felt.
        bassRoots: [28, 38, 36, 35, 28, 38, 36, 35],
        melody: [],
        // A four-step figure rather than eight, and quieter. At this tempo the
        // longer shape was filling every gap in the bar.
        arpeggio: .init(shape: [0, 1, 2, 1], octave: 2, level: 0.11, timbre: .saw),
        drums: .driving,
        // Sixteenths, which is the one pattern that reads as pressure rather
        // than pulse. Paired with the sparser arpeggio so the two do not fill
        // every sixteenth between them.
        bassPattern: .sixteenths,
        padSweep: 0.6,
        // Both were pushed above 1 in the first version, which against the
        // soft clipper bought loudness by spending headroom — the mix squashed
        // rather than hit harder.
        bassLevel: 1.05,
        drumLevel: 1.0
    )

    /// The empty map. Somewhere to start from.
    static let firstLight = Track(
        name: "first-light",
        intent: "A new city. The empty map after the title, before the first road.",
        beatsPerMinute: 96,
        bars: 16,
        // **The one major-key track in the library**, and it is major on
        // purpose: everything else sits in A minor or E minor, because the
        // city is permanently night and neon is a minor-key colour. A blank
        // map is the one moment that is about what *could* be there. C is
        // A minor's relative major, so the palette does not change — the
        // same notes, read the hopeful way round. Sevenths and add-nines
        // rather than triads, because a bare major triad in this
        // instrument reads as a jingle.
        progression: [
            [48, 52, 55, 59], [43, 47, 50, 57], [45, 48, 52, 55], [41, 45, 48, 52],
            [48, 52, 55, 59], [43, 47, 50, 57], [45, 48, 52, 55], [41, 45, 48, 52],
        ],
        bassRoots: [36, 31, 33, 29, 36, 31, 33, 29],
        melody: [],
        arpeggio: .init(shape: [0, 2, 1, 3, 2, 3], octave: 2, level: 0.1, timbre: .pluck),
        drums: .sparse,
        bassPattern: .octaves,
        padSweep: 0.5,
        // Sixteen bars because this one is an *arrangement*: the pad alone,
        // then the bass and arpeggio, then a kick. A player hears the whole
        // shape once, and it loops from where the drums come in.
        bassEntersAtBar: 4,
        arpeggioEntersAtBar: 4,
        drumsEnterAtBar: 8,
        padLevel: 1.2,
        drumLevel: 0.75
    )

    /// It is raining. Over whatever else is happening.
    static let rainfall = Track(
        name: "rainfall",
        intent: "Weather. Plays while it rains, whichever state the city is in.",
        beatsPerMinute: 72,
        bars: 8,
        // D minor with add-nines, one flat away from the rest of the library.
        // Dm(add9) – B♭maj7 – Fmaj7 – C(add9): every chord shares two notes
        // with the next, so the progression drifts rather than moves. Rain
        // does not go anywhere either.
        progression: [
            [50, 53, 57, 64], [46, 50, 53, 57], [41, 45, 48, 52], [48, 52, 55, 62],
            [50, 53, 57, 64], [46, 50, 53, 57], [41, 45, 48, 52], [48, 52, 55, 62],
        ],
        bassRoots: [38, 34, 29, 36, 38, 34, 29, 36],
        melody: [],
        // The plucked arpeggio is the rain: a six-note shape over a four-note
        // chord, so it takes twelve steps to come back round and never lands
        // on the beat the same way twice.
        arpeggio: .init(shape: [0, 3, 2, 3, 1, 3], octave: 2, level: 0.09, timbre: .pluck),
        // No drums at all. This is the one track that is mostly weather, and
        // a kick under it would turn rain into a beat.
        drums: .none,
        bassPattern: .held,
        padCutoff: 2_000,
        padSweep: 0.7,
        padLevel: 1.4
    )

    /// Blocks emptying. The region in a slump.
    static let vacancy = Track(
        name: "vacancy",
        intent: "Decline. A slump, buildings emptying, the player deciding what to do about it.",
        beatsPerMinute: 92,
        bars: 8,
        // A minor again, and deliberately the same key as Small Hours: a
        // slump is the settled city gone wrong, and it should sound like the
        // same place. What changes is the harmony under it — Am(add9),
        // Fmaj7, Dm7, then E suspended and resolving — which never gets to
        // rest on the tonic for long. Small Hours descends home; this one
        // circles.
        progression: [
            [45, 48, 52, 59], [45, 48, 52, 59], [41, 45, 48, 52], [41, 45, 48, 52],
            [38, 41, 45, 48], [38, 41, 45, 48], [40, 45, 47, 52], [40, 44, 47, 52],
        ],
        bassRoots: [33, 33, 29, 29, 38, 38, 28, 28],
        melody: [],
        arpeggio: .init(shape: [0, 1, 2, 1], octave: 2, level: 0.08, timbre: .saw),
        drums: .sparse,
        bassPattern: .drivingEighths,
        // Darker than everything else, with barely any movement — a filter
        // that does not open is what "hollow" is in this instrument.
        padCutoff: 1_500,
        padSweep: 0.25,
        arpeggioEntersAtBar: 4,
        bassLevel: 0.85,
        padLevel: 1.2,
        drumLevel: 0.6
    )

    /// What plays under a city, in no particular order.
    static let gameplay = [firstLight, neonGrid, smallHours, overdrive, vacancy, rainfall]
    static let all = [theme] + gameplay
}
