import XCTest
@testable import AlphaPlusPlus

/// **The measurement table for the soundtrack.**
///
/// Prints one row per track and one per speaker profile, so a change to the
/// instrument or the score can be compared against the row from before it —
/// the same job `HarnessTimingTests` does for a tick. Read it the way a mix
/// engineer reads a spectrum analyser: not "is this good" but "did the thing
/// I changed move the band I meant it to, and nothing else".
///
/// ```sh
/// xcodebuild -project AlphaPlusPlus.xcodeproj -scheme AlphaPlusPlus \
///            -configuration Debug -derivedDataPath ./build test \
///            -only-testing:AlphaPlusPlusTests/SoundtrackAnalysisTests \
///   2>&1 | grep '📊'
/// ```
final class SoundtrackAnalysisTests: XCTestCase {

    func testPrintTheSpectrumOfEveryTrack() {
        print("📊 " + AudioAnalysis.header())
        for track in MusicLibrary.all {
            let report = AudioAnalysis.report(Soundtrack.render(track))
            print("📊 " + AudioAnalysis.row(track.name, report))

            // The one property every row has to have: the channels are never
            // out of phase, because a Mac mini's built-in speaker is mono and
            // anti-phase content simply vanishes on it.
            XCTAssertGreaterThan(report.correlation, 0.3,
                                 "\(track.name): the channels are too decorrelated to survive a mono speaker")
        }
    }

    /// Each voice of one track on its own — the solo button. When a band of
    /// the mix is wrong this is what says which instrument put it there,
    /// which is how the hats were found to be full-band noise rather than
    /// the high-passed hiss their comment described.
    func testPrintTheStemsOfOneTrack() {
        let track = MusicLibrary.neonGrid
        let stems = Soundtrack.renderStems(track)
        print("📊 " + AudioAnalysis.header())
        for (name, bus) in stems.named {
            let buffer = Soundtrack.Buffer(left: bus.left.map(Float.init), right: bus.right.map(Float.init))
            print("📊 " + AudioAnalysis.row("\(track.name)/\(name)", AudioAnalysis.report(buffer)))
        }
    }

    func testPrintEveryProfileOnOneTrack() {
        let mix = Soundtrack.render(MusicLibrary.smallHours)
        print("📊 " + AudioAnalysis.header())
        print("📊 " + AudioAnalysis.row("small-hours raw", AudioAnalysis.report(mix)))
        for profile in AudioProfile.all {
            let report = AudioAnalysis.report(profile.apply(to: mix))
            print("📊 " + AudioAnalysis.row("  " + profile.name, report))
        }
    }
}
