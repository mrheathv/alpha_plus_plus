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
        progression: [
            [45, 48, 52], [45, 48, 52], [43, 47, 50], [43, 47, 50],
            [41, 45, 48], [41, 45, 48], [40, 43, 47], [40, 43, 47],
        ],
        bassRoots: [21, 21, 19, 19, 17, 17, 16, 16],
        melody: [],
        arpeggio: .init(shape: [0, 2, 1, 2], octave: 3, level: 0.09),
        drums: .sparse,
        bassLevel: 0.85,
        padLevel: 1.35,
        drumLevel: 0.7
    )

    /// Faster and harder, for when things are going wrong.
    static let overdrive = Track(
        name: "overdrive",
        intent: "Pressure. A big city, or one that is on fire.",
        beatsPerMinute: 126,
        bars: 8,
        progression: [
            [52, 55, 59], [50, 53, 57], [48, 51, 55], [47, 50, 54],
            [52, 55, 59], [50, 53, 57], [48, 51, 55], [55, 58, 62],
        ],
        bassRoots: [28, 26, 24, 23, 28, 26, 24, 31],
        melody: [],
        arpeggio: .init(shape: [0, 1, 2, 1, 2, 1, 0, 1], octave: 2, level: 0.18),
        drums: .full,
        bassLevel: 1.15,
        drumLevel: 1.1
    )

    /// What plays under a city, in no particular order.
    static let gameplay = [neonGrid, smallHours, overdrive]
    static let all = [theme] + gameplay
}
