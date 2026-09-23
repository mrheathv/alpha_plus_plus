import AVFoundation
import XCTest
@testable import AlphaPlusPlus

/// **Driving the audio graph with no audio device.**
///
/// `AVAudioEngine`'s manual rendering mode is the audio counterpart of
/// `SKView.texture(from:)`: it runs the real graph — the real player nodes,
/// the real mixers, the real crossfade — and hands back samples, with no
/// output device anywhere. So the plumbing can be asserted on rather than
/// listened to, which matters more here than anywhere else in the project.
@MainActor
final class SoundtrackPlayerTests: XCTestCase {

    /// A cheap stand-in for a rendered track: a steady tone, so a level can
    /// be measured without paying seconds to synthesise a real one. What is
    /// under test is the graph, not the music.
    private func tone(seconds: Double = 20, hertz: Double = 220) -> Soundtrack.Buffer {
        let frames = Int(seconds * Synth.sampleRate)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for index in 0 ..< frames {
            let value = Float(sin(2 * .pi * hertz * Double(index) / Synth.sampleRate) * 0.5)
            left[index] = value
            right[index] = value
        }
        return Soundtrack.Buffer(left: left, right: right)
    }

    /// **Render past the ramp before measuring.** `AVAudioMixerNode` does not
    /// apply a volume change instantly — it ramps it over some frames, which
    /// is what stops a slider crackling. So a single short offline render
    /// measures the *ramp* rather than the level, and the first version of
    /// the volume test duly reported 0.17 at full volume and 0.20 at a
    /// quarter of it: both were averages of a slope, and the second one was
    /// sliding down from the first. Discarding a few buffers first is the
    /// difference between measuring a level and measuring a transition.
    private func settledRMS(_ player: SoundtrackPlayer, frames: AVAudioFrameCount = 4_096) throws -> Double {
        for _ in 0 ..< 8 { _ = try player.renderOffline(frames: frames) }
        return rms(try player.renderOffline(frames: frames))
    }

    private func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var total = 0.0
        for index in 0 ..< Int(buffer.frameLength) {
            total += Double(channel[index]) * Double(channel[index])
        }
        return (total / Double(buffer.frameLength)).squareRoot()
    }

    // MARK: - The fade

    /// **A linear crossfade has a hole in the middle**, and this is the test
    /// that would catch one. Two uncorrelated signals summed at half gain
    /// each land 3 dB down at the halfway point — audible as a dip, and the
    /// single most likely way for a track change to sound broken.
    func testTheCrossfadeHoldsItsLevelAllTheWayThrough() {
        var worst = 1.0
        for step in 0 ... 100 {
            let (rising, falling) = SoundtrackPlayer.crossfadeGains(through: Double(step) / 100)
            let power = rising * rising + falling * falling
            worst = min(worst, power)
            XCTAssertEqual(power, 1, accuracy: 0.001,
                           "the crossfade does not conserve power at \(step)%")
        }

        // And the naive version really would fail it, which is what makes the
        // assertion above worth having rather than a restatement of sin²+cos².
        let linear = 0.5 * 0.5 + 0.5 * 0.5
        XCTAssertLessThan(linear, 0.99, "a linear fade no longer dips, so this test proves nothing")
        print(String(format: "🎚 equal-power fade holds %.3f at its worst; linear would be %.3f",
                     worst, linear))
    }

    /// The ends are the ends: fully the old track at the start, fully the new
    /// one at the finish.
    func testTheFadeStartsAndEndsWhereItShould() {
        let start = SoundtrackPlayer.crossfadeGains(through: 0)
        XCTAssertEqual(start.rising, 0, accuracy: 0.001)
        XCTAssertEqual(start.falling, 1, accuracy: 0.001)
        let end = SoundtrackPlayer.crossfadeGains(through: 1)
        XCTAssertEqual(end.rising, 1, accuracy: 0.001)
        XCTAssertEqual(end.falling, 0, accuracy: 0.001)
    }

    // MARK: - The loop

    /// **A track loops from where its arrangement says**, not from the top.
    /// First Light is alone on a pad for four bars and gets its drums at
    /// eight; replaying that introduction every time round is the surest way
    /// to make an arrangement sound like a loop.
    func testATrackWithAnIntroductionLoopsPastIt() {
        let player = SoundtrackPlayer()
        let firstLight = MusicDirector.Cue.founding.track
        XCTAssertGreaterThan(firstLight.loopsFromBar, 0, "First Light lost its introduction")

        let loopStart = player.loopStartFrame(of: firstLight)
        let expected = Double(firstLight.loopsFromBar * firstLight.beatsPerBar)
            * firstLight.secondsPerBeat * Synth.sampleRate
        XCTAssertEqual(Double(loopStart), expected, accuracy: 1)
        XCTAssertLessThan(Double(loopStart), firstLight.duration * Synth.sampleRate,
                          "the loop starts after the track ends")
    }

    /// A track with no introduction loops from the top, and must not be
    /// handed a zero-length slice to loop instead.
    func testATrackWithNoIntroductionLoopsFromTheStart() {
        let player = SoundtrackPlayer()
        let neonGrid = MusicDirector.Cue.building.track
        XCTAssertEqual(neonGrid.loopsFromBar, 0)
        XCTAssertEqual(player.loopStartFrame(of: neonGrid), 0)
    }

    // MARK: - The graph

    /// It makes a sound at all — the end-to-end check that the nodes are
    /// connected, the buffer is scheduled and the level reaches the output.
    func testPlayingACueProducesAudio() throws {
        let player = SoundtrackPlayer()
        player.preload(.building, with: tone())
        try player.enableOfflineRendering()
        player.play(.building)
        player.update(elapsed: SoundtrackPlayer.crossfade)

        let rendered = try player.renderOffline(frames: 4_096)
        XCTAssertGreaterThan(rms(rendered), 0.01, "the player produced silence")
    }

    /// **Volume and mute actually move the output**, which is the one thing
    /// this project has shipped broken twice — a colorize on a plain node and
    /// an overlay tint casting to a type the ground had stopped being. Both
    /// compiled; neither did anything. A volume slider is the same trap.
    func testVolumeAndMuteReachTheOutput() throws {
        let player = SoundtrackPlayer()
        player.preload(.building, with: tone())
        try player.enableOfflineRendering()
        player.volume = 1
        player.play(.building)
        player.update(elapsed: SoundtrackPlayer.crossfade)
        let loud = try settledRMS(player)

        player.volume = 0.25
        let quiet = try settledRMS(player)

        player.isMuted = true
        let silent = try settledRMS(player)

        print(String(format: "🎚 rms at volume 1.0 %.4f, at 0.25 %.4f, muted %.4f", loud, quiet, silent))
        // A quarter of the level, give or take the tone's own phase within
        // the window: the bound is generous because what would fail it is a
        // control that does nothing, not one that is a few percent off.
        XCTAssertLessThan(quiet, loud * 0.5, "turning the volume down did not turn it down")
        XCTAssertGreaterThan(quiet, loud * 0.1, "turning the volume down silenced it instead")
        XCTAssertLessThan(silent, 0.001, "mute did not mute")
    }

    /// Asking for a cue that has not been rendered yet must not play silence
    /// over the top of what is on, and must not crash. It starts the render
    /// and leaves the current track alone.
    func testAnUnrenderedCueLeavesTheCurrentOnePlaying() throws {
        let player = SoundtrackPlayer()
        player.preload(.building, with: tone())
        try player.enableOfflineRendering()
        player.play(.building)
        player.update(elapsed: SoundtrackPlayer.crossfade)
        XCTAssertEqual(player.cue, .building)

        // Nothing has rendered Overdrive, so this is a request rather than a
        // change.
        player.play(.pressure)
        XCTAssertEqual(player.cue, .building, "an unrendered cue took over and played nothing")
        XCTAssertGreaterThan(rms(try player.renderOffline(frames: 4_096)), 0.01,
                             "the music stopped while waiting for a track to render")
    }

    /// Changing speakers re-shapes what is playing rather than carrying on
    /// with the old mix — and keeps the raw render, so it costs a pass over a
    /// buffer rather than synthesising the track again.
    func testChangingProfileRestartsTheCurrentTrack() throws {
        let player = SoundtrackPlayer(profile: .fullRange)
        player.preload(.building, with: tone())
        try player.enableOfflineRendering()
        player.play(.building)
        player.update(elapsed: SoundtrackPlayer.crossfade)

        player.setProfile(.monoSpeaker)
        XCTAssertEqual(player.profile, .monoSpeaker)
        XCTAssertEqual(player.cue, .building, "the track was dropped rather than re-shaped")
        XCTAssertTrue(player.isReady(.building), "the raw mix was thrown away with the profile")
    }

    /// **A wanted track jumps the warm-up queue.** Rendering is serial, and
    /// the library takes 46 seconds in Debug — longer than the 40 seconds a
    /// cue is guaranteed to hold. So a change that arrives while the warm-up
    /// is still working has to go to the front, or the player could never
    /// catch up with the director on a slow machine.
    func testAWantedTrackIsRenderedBeforeTheRestOfTheWarmUp() async throws {
        let player = SoundtrackPlayer()
        // Everything queued, none of it rendered.
        player.warmUp()
        XCTAssertFalse(player.isReady(.pressure))

        // Ask for one from the back of that queue.
        player.play(.pressure)

        // One render, not seven: it must arrive well inside the time the
        // whole library would take.
        let deadline = Date().addingTimeInterval(MusicDirector.minimumDwell)
        while !player.isReady(.pressure), Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(player.isReady(.pressure),
                      "a wanted track waited behind the rest of the warm-up")
    }

    /// **What warming up costs**, which is the number the whole cache design
    /// rests on. If a track rendered in milliseconds there would be no need
    /// for a background queue at all; if the whole library cost a minute,
    /// rendering everything at launch would be wrong even in the background.
    ///
    /// Reported rather than asserted tightly, the way `HarnessTimingTests`
    /// reports a tick: a number in a build log is what makes a regression
    /// visible before it is a stutter.
    func testMeasureWhatRenderingTheLibraryCosts() throws {
        try XCTSkipUnless(TestReports.enabled, TestReports.skipReason)
        var total = 0.0
        for cue in MusicDirector.Cue.allCases {
            let track = cue.track
            let started = Date()
            _ = Soundtrack.render(track)
            let seconds = Date().timeIntervalSince(started)
            total += seconds
            print(String(format: "🎚 %-12@ %5.1fs of music rendered in %5.2fs  (%.1fx real time)",
                         track.name as NSString, track.duration, seconds, track.duration / seconds))
        }
        print(String(format: "🎚 whole library: %.1fs in this configuration", total))

        // The bound is loose and is about the *shape* of the answer: if a
        // single track ever costs more than the dwell a cue is guaranteed,
        // a change could ask for a track and still be waiting when the next
        // change arrives, and the player would sit on one piece forever.
        let worst = MusicDirector.Cue.allCases
            .map { track -> Double in
                let started = Date()
                _ = Soundtrack.render(track.track)
                return Date().timeIntervalSince(started)
            }
            .max() ?? 0
        XCTAssertLessThan(worst, MusicDirector.minimumDwell,
                          "a track takes longer to render than a cue is guaranteed to hold, "
                          + "so the player could never catch up with the director")
    }

    /// The engine has to survive there being no output device, because a game
    /// that will not launch without speakers is worse than a silent one.
    func testAPlayerThatCannotOpenADeviceIsSilentRatherThanFatal() {
        let player = SoundtrackPlayer()
        // Never started, so nothing is available — and every call still has
        // to be safe.
        XCTAssertFalse(player.isAvailable)
        player.play(.building)
        player.update(elapsed: 1)
        player.stop()
    }
}
