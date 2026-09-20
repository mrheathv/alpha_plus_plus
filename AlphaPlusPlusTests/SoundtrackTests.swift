import XCTest
@testable import AlphaPlusPlus

/// **Listening, for someone who cannot listen.**
///
/// Every art decision in this project goes through "look at the render, don't
/// imagine it". There is no equivalent for sound available to the author of
/// this file, so these tests do the half that measurement can do: they catch
/// *wrong*. They cannot catch *bad*.
///
/// What they check is therefore deliberately not "does it sound good" but the
/// failures that would be obvious to a listener and invisible to a reader —
/// clipping, silence, DC offset, a note landing on the wrong frequency, a
/// buffer the wrong length. The judgement goes to whoever plays the WAV.
final class SoundtrackTests: XCTestCase {

    // MARK: - The instrument

    /// **The saw is band-limited.** A naive saw aliases: its instantaneous
    /// jump carries energy above Nyquist that folds back down as inharmonic
    /// whistling, which is the single most common reason a hand-written synth
    /// sounds cheap — and is exactly the kind of fault an author who cannot
    /// hear would ship.
    ///
    /// Measured rather than trusted: render a high note both ways and compare
    /// energy above the fundamental's harmonic series. PolyBLEP should cut it
    /// substantially.
    func testTheSawIsBandLimited() {
        let frequency = 3_000.0
        let increment = frequency / Synth.sampleRate
        var phase = 0.0
        var naive: [Double] = [], limited: [Double] = []
        for _ in 0 ..< 4_096 {
            naive.append(2 * phase - 1)
            limited.append(Synth.saw(phase: phase, increment: increment))
            phase += increment
            if phase >= 1 { phase -= 1 }
        }
        // Aliasing shows up as sample-to-sample jitter that the band-limited
        // version smooths: compare the mean absolute second difference.
        func roughness(_ samples: [Double]) -> Double {
            var total = 0.0
            for i in 2 ..< samples.count {
                total += abs(samples[i] - 2 * samples[i - 1] + samples[i - 2])
            }
            return total / Double(samples.count - 2)
        }
        XCTAssertLessThan(roughness(limited), roughness(naive) * 0.8,
                          "the band-limited saw is no smoother than the naive one — "
                          + "PolyBLEP is not doing anything")
    }

    /// A note is the note it says it is. Trivial arithmetic, and the one place
    /// a transposition bug would hide: a soundtrack a semitone out is still a
    /// soundtrack, and nothing else here would notice.
    func testMiddleNotesLandOnTheRightFrequencies() {
        XCTAssertEqual(Synth.frequency(ofNote: 69), 440, accuracy: 0.001)
        XCTAssertEqual(Synth.frequency(ofNote: 57), 220, accuracy: 0.001)  // the tonic, A3
        XCTAssertEqual(Synth.frequency(ofNote: 81), 880, accuracy: 0.001)
    }

    /// The filter has to stay stable when asked for something silly. A
    /// state-variable filter driven near the sample rate does not distort, it
    /// explodes — and an explosion is what a listener would get, at full
    /// volume, wearing headphones.
    func testTheFilterCannotBeMadeToExplode() {
        var filter = Synth.LowPass()
        var peak = 0.0
        for index in 0 ..< 10_000 {
            let input = index % 2 == 0 ? 1.0 : -1.0
            let out = filter.process(input, cutoff: 500_000, resonance: 3.0)
            peak = max(peak, abs(out))
        }
        XCTAssertLessThan(peak, 10, "the filter ran away at an absurd cutoff")
        XCTAssertFalse(peak.isNaN, "the filter produced NaN")
    }

    /// Noise is deterministic, for the reason `RegionalEconomy` is a clock:
    /// two renders of the same bar have to be the same file or no test here
    /// can say anything about either.
    func testTheSameSeedGivesTheSameNoise() {
        var a = Synth.Noise(seed: 7), b = Synth.Noise(seed: 7)
        for _ in 0 ..< 500 { XCTAssertEqual(a.next(), b.next()) }
    }

    // MARK: - The mix

    func testTheLoopIsTheLengthItClaims() {
        let buffer = Soundtrack.render()
        let expected = Int(Soundtrack.duration * Synth.sampleRate)
        XCTAssertEqual(buffer.frames, expected)
        XCTAssertEqual(buffer.right.count, buffer.left.count)
        // 8 bars at 110 BPM is a bit over seventeen seconds.
        XCTAssertEqual(Soundtrack.duration, 17.4545, accuracy: 0.01)
    }

    /// **Nothing clips**, which is the one sound failure that would be
    /// glaring to a listener and completely invisible here.
    func testNothingClips() {
        let buffer = Soundtrack.render()
        let peak = max(buffer.left.map(abs).max() ?? 0, buffer.right.map(abs).max() ?? 0)
        XCTAssertLessThan(peak, 0.999, "the mix reaches full scale — that is audible distortion")
        XCTAssertGreaterThan(peak, 0.3, "the mix is so quiet something is probably not playing")
    }

    /// No DC offset. A buffer whose average is off zero wastes headroom,
    /// thumps when it starts and stops, and is inaudible as itself.
    func testTheMixIsCentred() {
        let buffer = Soundtrack.render()
        let mean = buffer.left.reduce(0, +) / Float(buffer.frames)
        XCTAssertEqual(mean, 0, accuracy: 0.02, "the mix has a DC offset")
    }

    /// Every bar has something in it. A voice that silently fails to render —
    /// an off-by-one in a frame index, a chord array read past its end —
    /// leaves a hole that no other assertion here would notice.
    func testEveryBarHasSoundInIt() {
        let buffer = Soundtrack.render()
        let framesPerBar = buffer.frames / Soundtrack.bars
        for bar in 0 ..< Soundtrack.bars {
            let slice = buffer.left[(bar * framesPerBar) ..< ((bar + 1) * framesPerBar)]
            let energy = slice.reduce(0) { $0 + abs($1) } / Float(framesPerBar)
            XCTAssertGreaterThan(energy, 0.01, "bar \(bar + 1) is silent")
        }
    }

    /// And the two channels are not the same signal — the detuned pad and the
    /// panned kit are what make it wide, and a mix that collapsed to mono
    /// would sound flat in a way nothing above would catch.
    func testItIsActuallyInStereo() {
        let buffer = Soundtrack.render()
        var difference: Float = 0
        for index in stride(from: 0, to: buffer.frames, by: 17) {
            difference += abs(buffer.left[index] - buffer.right[index])
        }
        XCTAssertGreaterThan(difference, 1, "both channels carry the same signal")
    }
}
