import Foundation

/// **The music, as data and arithmetic.**
///
/// Eight bars in A minor over `i – VI – III – VII`, which is the progression
/// this genre is largely made of, at 110 BPM. Written as a score rather than
/// generated, because "procedural music" that wanders is atmosphere and what
/// a title screen and a city need is a *theme* — something recognisable
/// enough that hearing it means you are in this game.
///
/// Rendered offline into a buffer here, and fed to `AVAudioEngine` by
/// `SoundtrackPlayer`. The split is deliberate and the same one the whole
/// project draws: this file is pure arithmetic and can be tested without a
/// speaker, a window, or a run loop — the audio counterpart of
/// `IsoTextureCache` rendering a building with no game running.
enum Soundtrack {

    static let beatsPerMinute = 110.0
    static let beatsPerBar = 4
    static let bars = 8

    static var secondsPerBeat: Double { 60 / beatsPerMinute }
    static var duration: Double { Double(bars * beatsPerBar) * secondsPerBeat }

    // MARK: - The score

    /// One chord per bar. MIDI note numbers, root first.
    ///
    /// A minor, F major, C major, G major — twice. The tonic arrives on the
    /// first bar and the last chord pulls back to it, which is what makes an
    /// eight-bar loop close rather than simply stop.
    private static let progression: [[Int]] = [
        [57, 60, 64],  // Am
        [53, 57, 60],  // F
        [48, 52, 55],  // C
        [55, 59, 62],  // G
        [57, 60, 64],  // Am
        [53, 57, 60],  // F
        [48, 52, 55],  // C
        [55, 59, 62],  // G
    ]

    /// Bass roots, an octave and a half below the pad.
    private static let bassRoots = [33, 29, 24, 31, 33, 29, 24, 31]

    /// The tune. `(bar, beat, note, beats long)` — written out rather than
    /// derived, because a melody is the one part of this that cannot come
    /// from a rule without sounding like it came from a rule.
    private static let melody: [(bar: Int, beat: Double, note: Int, length: Double)] = [
        (0, 0.0, 76, 1.0), (0, 1.0, 74, 0.5), (0, 1.5, 72, 1.5), (0, 3.0, 69, 1.0),
        (1, 0.0, 72, 1.0), (1, 1.0, 69, 0.5), (1, 1.5, 68, 1.5), (1, 3.0, 65, 1.0),
        (2, 0.0, 64, 1.5), (2, 1.5, 67, 0.5), (2, 2.0, 72, 2.0),
        (3, 0.0, 74, 1.0), (3, 1.0, 71, 0.5), (3, 1.5, 74, 2.5),
        (4, 0.0, 81, 1.0), (4, 1.0, 79, 0.5), (4, 1.5, 76, 1.5), (4, 3.0, 74, 1.0),
        (5, 0.0, 77, 1.0), (5, 1.0, 76, 0.5), (5, 1.5, 72, 1.5), (5, 3.0, 69, 1.0),
        (6, 0.0, 76, 1.5), (6, 1.5, 72, 0.5), (6, 2.0, 67, 2.0),
        (7, 0.0, 71, 1.0), (7, 1.0, 74, 1.0), (7, 2.0, 69, 2.0),
    ]

    // MARK: - Rendering

    struct Buffer {
        var left: [Float]
        var right: [Float]
        var frames: Int { left.count }
    }

    /// Render the whole loop.
    ///
    /// Straight-line and allocation-heavy on purpose: this is the *offline*
    /// path, used by the test that writes a WAV to listen to. The live player
    /// reuses the same voice functions inside a preallocated callback.
    static func render() -> Buffer {
        let frames = Int(duration * Synth.sampleRate)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)

        renderBass(into: &left, &right)
        renderPad(into: &left, &right)
        renderLead(into: &left, &right)
        renderDrums(into: &left, &right)

        // **Soft clip rather than hard.** I cannot hear distortion, so the
        // mix must not be able to produce any: `tanh` squashes peaks smoothly
        // instead of shearing them flat, and `SoundtrackTests` asserts the
        // result never reaches full scale. Hard clipping is the one sound
        // failure that would be obvious to a listener and invisible to me.
        var blockLeft = Synth.DCBlocker(), blockRight = Synth.DCBlocker()
        for index in 0 ..< frames {
            left[index] = Float(tanh(blockLeft.process(Double(left[index])) * 0.8))
            right[index] = Float(tanh(blockRight.process(Double(right[index])) * 0.8))
        }
        return Buffer(left: left, right: right)
    }

    private static func frame(ofBar bar: Int, beat: Double) -> Int {
        Int((Double(bar * beatsPerBar) + beat) * secondsPerBeat * Synth.sampleRate)
    }

    // MARK: - Voices

    /// Driving eighth notes on the root, through a filter that opens across
    /// each bar. The filter movement is the part that matters — a static
    /// filter makes this a buzz that happens to change pitch.
    private static func renderBass(into left: inout [Float], _ right: inout [Float]) {
        let envelope = Synth.Envelope(attack: 0.004, decay: 0.09, sustain: 0.55, release: 0.06)
        for bar in 0 ..< bars {
            let root = bassRoots[bar % bassRoots.count]
            for eighth in 0 ..< 8 {
                let beat = Double(eighth) * 0.5
                // An octave jump on the last eighth of the bar, which is what
                // stops a root-note pattern reading as a drone.
                let note = eighth == 7 ? root + 12 : root
                let start = frame(ofBar: bar, beat: beat)
                let held = 0.5 * secondsPerBeat * 0.9
                var phase = 0.0
                var filter = Synth.LowPass()
                let increment = Synth.frequency(ofNote: note) / Synth.sampleRate
                let length = Int((held + envelope.release) * Synth.sampleRate)
                for offset in 0 ..< length {
                    let index = start + offset
                    guard index < left.count else { break }
                    let time = Double(offset) / Synth.sampleRate
                    let level = envelope.level(at: time, heldFor: held)
                    guard level > 0 else { continue }
                    let raw = Synth.saw(phase: phase, increment: increment)
                    // Cutoff tracks the envelope, so every note has its own
                    // attack rather than the bank sounding like one long note.
                    let cutoff = 180 + 2_400 * level * level
                    let shaped = filter.process(raw, cutoff: cutoff, resonance: 0.62)
                    let sample = Float(shaped * level * 0.42)
                    left[index] += sample
                    right[index] += sample
                    phase += increment
                    if phase >= 1 { phase -= 1 }
                }
            }
        }
    }

    /// Two saws per note, detuned against each other and panned apart.
    ///
    /// The detuning *is* the pad: one saw is thin and slightly sour, two a few
    /// cents apart beat against each other and turn into something wide. Same
    /// trick as `RegionalEconomy` summing two sines of co-prime period, for a
    /// similar reason — one is a tone, two are a texture.
    private static func renderPad(into left: inout [Float], _ right: inout [Float]) {
        let envelope = Synth.Envelope(attack: 0.35, decay: 0.4, sustain: 0.6, release: 0.5)
        for bar in 0 ..< bars {
            let chord = progression[bar % progression.count]
            let start = frame(ofBar: bar, beat: 0)
            let held = Double(beatsPerBar) * secondsPerBeat * 0.95
            let length = Int((held + envelope.release) * Synth.sampleRate)

            for (voiceIndex, note) in chord.enumerated() {
                for (detuneIndex, cents) in [-7.0, 7.0].enumerated() {
                    var phase = Double(voiceIndex) * 0.11 + Double(detuneIndex) * 0.37
                    let frequency = Synth.frequency(ofNote: note + 12) * pow(2, cents / 1_200)
                    let increment = frequency / Synth.sampleRate
                    var filter = Synth.LowPass()
                    for offset in 0 ..< length {
                        let index = start + offset
                        guard index < left.count else { break }
                        let time = Double(offset) / Synth.sampleRate
                        let level = envelope.level(at: time, heldFor: held)
                        guard level > 0 else { continue }
                        let raw = Synth.saw(phase: phase, increment: increment)
                        let shaped = filter.process(raw, cutoff: 1_500, resonance: 0.2)
                        let sample = Float(shaped * level * 0.075)
                        // The two detuned copies sit on opposite sides, which
                        // is what makes the pad wide rather than merely thick.
                        if detuneIndex == 0 { left[index] += sample * 1.3; right[index] += sample * 0.7 }
                        else { left[index] += sample * 0.7; right[index] += sample * 1.3 }
                        phase += increment
                        if phase >= 1 { phase -= 1 }
                    }
                }
            }
        }
    }

    /// The tune, on a narrow square through a bright filter.
    private static func renderLead(into left: inout [Float], _ right: inout [Float]) {
        let envelope = Synth.Envelope(attack: 0.012, decay: 0.18, sustain: 0.65, release: 0.22)
        for entry in melody {
            let start = frame(ofBar: entry.bar, beat: entry.beat)
            let held = entry.length * secondsPerBeat * 0.85
            let increment = Synth.frequency(ofNote: entry.note) / Synth.sampleRate
            var phase = 0.0
            var filter = Synth.LowPass()
            let length = Int((held + envelope.release) * Synth.sampleRate)
            for offset in 0 ..< length {
                let index = start + offset
                guard index < left.count else { break }
                let time = Double(offset) / Synth.sampleRate
                let level = envelope.level(at: time, heldFor: held)
                guard level > 0 else { continue }
                // A narrow pulse rather than a plain square: thinner, more
                // nasal, and it cuts through a pad without needing volume.
                let raw = Synth.square(phase: phase, increment: increment, width: 0.32)
                let shaped = filter.process(raw, cutoff: 3_200, resonance: 0.3)
                let sample = Float(shaped * level * 0.2)
                left[index] += sample * 0.95
                right[index] += sample * 1.05
                phase += increment
                if phase >= 1 { phase -= 1 }
            }
        }
    }

    /// Kick, snare and hats, all synthesised — which is what the genre's own
    /// drum machines did, so this is not an approximation of a sampled kit.
    private static func renderDrums(into left: inout [Float], _ right: inout [Float]) {
        for bar in 0 ..< bars {
            for beat in 0 ..< beatsPerBar {
                let position = frame(ofBar: bar, beat: Double(beat))
                if beat == 0 || beat == 2 { kick(at: position, into: &left, &right) }
                if beat == 1 || beat == 3 { snare(at: position, into: &left, &right, seed: UInt64(bar * 4 + beat)) }
                for eighth in 0 ..< 2 {
                    let at = frame(ofBar: bar, beat: Double(beat) + Double(eighth) * 0.5)
                    hat(at: at, open: eighth == 1 && beat == 3,
                        into: &left, &right, seed: UInt64(bar * 8 + beat * 2 + eighth))
                }
            }
        }
    }

    /// A sine whose pitch falls from a click to a thump. That pitch envelope
    /// is the entire instrument — held at one frequency it is a beep.
    private static func kick(at start: Int, into left: inout [Float], _ right: inout [Float]) {
        let length = Int(0.32 * Synth.sampleRate)
        var phase = 0.0
        for offset in 0 ..< length {
            let index = start + offset
            guard index < left.count else { break }
            let time = Double(offset) / Synth.sampleRate
            let frequency = 48 + 110 * exp(-time * 38)
            let amplitude = exp(-time * 9.5)
            let sample = Float(Synth.sine(phase: phase) * amplitude * 0.9)
            left[index] += sample
            right[index] += sample
            phase += frequency / Synth.sampleRate
            if phase >= 1 { phase -= 1 }
        }
    }

    /// Noise for the snares, plus a tone for the drum under them.
    private static func snare(at start: Int, into left: inout [Float], _ right: inout [Float],
                              seed: UInt64) {
        let length = Int(0.2 * Synth.sampleRate)
        var noise = Synth.Noise(seed: 0xD1CE &+ seed)
        var filter = Synth.LowPass()
        var phase = 0.0
        let increment = 185.0 / Synth.sampleRate
        for offset in 0 ..< length {
            let index = start + offset
            guard index < left.count else { break }
            let time = Double(offset) / Synth.sampleRate
            let amplitude = exp(-time * 22)
            let body = Synth.sine(phase: phase) * 0.35
            let crack = filter.process(noise.next(), cutoff: 7_500, resonance: 0.1)
            let sample = Float((body + crack) * amplitude * 0.5)
            left[index] += sample * 1.05
            right[index] += sample * 0.95
            phase += increment
            if phase >= 1 { phase -= 1 }
        }
    }

    private static func hat(at start: Int, open: Bool, into left: inout [Float], _ right: inout [Float],
                            seed: UInt64) {
        let decay = open ? 9.0 : 55.0
        let length = Int((open ? 0.3 : 0.07) * Synth.sampleRate)
        var noise = Synth.Noise(seed: 0x4A7 &+ seed)
        var filter = Synth.LowPass()
        for offset in 0 ..< length {
            let index = start + offset
            guard index < left.count else { break }
            let time = Double(offset) / Synth.sampleRate
            let amplitude = exp(-time * decay)
            // High-passed by subtracting the low-passed part: a hat is what is
            // left of noise once the bottom is gone.
            let low = filter.process(noise.next(), cutoff: 6_000, resonance: 0.05)
            let sample = Float((noise.next() - low) * amplitude * 0.16)
            left[index] += sample * 0.9
            right[index] += sample * 1.1
        }
    }
}
