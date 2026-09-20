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

    /// One chord per bar, MIDI note numbers, root first.
    let progression: [[Int]]
    /// Bass roots, one per bar. Usually the chord roots an octave or two down.
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
    }

    let drums: DrumKit

    enum DrumKit {
        /// Kick, snare and hats — the full pattern.
        case full
        /// Kick and hats, no backbeat. Quieter, and it stops a long loop from
        /// nagging.
        case sparse
        /// Nothing. For the tracks that are mostly weather.
        case none
    }

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
        bassRoots: [33, 29, 24, 31, 33, 29, 24, 31],
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
        drums: .full
    )

    /// The default. Busy enough to build to, no tune to get sick of.
    static let neonGrid = Track(
        name: "neon-grid",
        intent: "Building. The one that plays while you are laying roads and zoning.",
        beatsPerMinute: 112,
        bars: 8,
        progression: [
            [57, 60, 64], [50, 53, 57], [55, 59, 62], [53, 57, 60],
            [57, 60, 64], [50, 53, 57], [55, 59, 62], [52, 55, 59],
        ],
        bassRoots: [33, 26, 31, 29, 33, 26, 31, 28],
        melody: [],
        arpeggio: .init(shape: [0, 1, 2, 1], octave: 2, level: 0.14),
        drums: .full,
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
        arpeggio: .init(shape: [0, 2, 1, 2], octave: 2, level: 0.1),
        drums: .sparse,
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
        bassRoots: [28, 26, 24, 23, 28, 26, 24, 23],
        melody: [],
        // A four-step figure rather than eight, and quieter. At this tempo the
        // longer shape was filling every gap in the bar.
        arpeggio: .init(shape: [0, 1, 2, 1], octave: 2, level: 0.13),
        drums: .full,
        // Both were pushed above 1 in the first version, which against the
        // soft clipper bought loudness by spending headroom — the mix squashed
        // rather than hit harder.
        bassLevel: 1.05,
        drumLevel: 1.0
    )

    /// What plays under a city, in no particular order.
    static let gameplay = [neonGrid, smallHours, overdrive]
    static let all = [theme] + gameplay
}
