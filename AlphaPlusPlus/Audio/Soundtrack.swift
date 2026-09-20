import Foundation

/// **Turning a `Track` into samples.**
///
/// Pure arithmetic: no AVFoundation, no audio session, no device. That makes
/// the whole instrument testable offline — the audio counterpart of
/// `IsoTextureCache` rasterising a building with no game running — and since a
/// live render callback must not allocate or lock, the code it runs has to be
/// this plain anyway.
enum Soundtrack {

    struct Buffer {
        var left: [Float]
        var right: [Float]
        var frames: Int { left.count }
    }

    /// One voice's output before anything is summed.
    ///
    /// Separate buses rather than a single running total, because the effects
    /// are per-voice: the lead wants a delay the bass must not have, the snare
    /// wants a gated reverb nothing else wants, and the kick has to be the one
    /// thing that does not duck under itself.
    struct Bus {
        var left: [Double]
        var right: [Double]
        init(frames: Int) {
            left = [Double](repeating: 0, count: frames)
            right = [Double](repeating: 0, count: frames)
        }
    }

    // MARK: - The mix

    static func render(_ track: Track) -> Buffer {
        let frames = Int(track.duration * Synth.sampleRate)
        var bass = Bus(frames: frames)
        var pad = Bus(frames: frames)
        var lead = Bus(frames: frames)
        var arp = Bus(frames: frames)
        var drums = Bus(frames: frames)
        var snares = Bus(frames: frames)

        renderBass(track, into: &bass)
        renderPad(track, into: &pad)
        renderLead(track, into: &lead)
        renderArpeggio(track, into: &arp)
        let kicks = renderDrums(track, into: &drums, snareBus: &snares)

        // **A dotted-eighth echo** — the delay setting this genre is built on.
        // It lands between the beats rather than on them, so a lead answers
        // itself instead of doubling.
        applyDelay(to: &lead, seconds: track.secondsPerBeat * 0.75, feedback: 0.36, mix: 0.4)
        applyDelay(to: &arp, seconds: track.secondsPerBeat * 0.5, feedback: 0.25, mix: 0.22)

        // **The gated snare.** Held wide open for a tenth of a second and then
        // cut dead — the single most identifiable production signature in this
        // music, and the thing whose absence made a correct drum kit still
        // sound modern.
        applyGatedReverb(to: &snares, hold: 0.105)

        // **Everything ducks under the kick except the kick.** The pump is
        // most of what makes this music move rather than merely play, and the
        // score already knows where every kick is, so there is nothing to
        // detect.
        let duck = Synth.duckEnvelope(frames: frames, kicks: kicks)
        apply(duck, to: &bass)
        apply(duck, to: &pad)
        apply(duck, to: &lead)
        apply(duck, to: &arp)
        apply(duck, to: &snares)

        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        var blockLeft = Synth.DCBlocker(), blockRight = Synth.DCBlocker()
        for index in 0 ..< frames {
            let l = bass.left[index] * track.bassLevel + pad.left[index] * track.padLevel
                + lead.left[index] * track.leadLevel + arp.left[index]
                + (drums.left[index] + snares.left[index]) * track.drumLevel
            let r = bass.right[index] * track.bassLevel + pad.right[index] * track.padLevel
                + lead.right[index] * track.leadLevel + arp.right[index]
                + (drums.right[index] + snares.right[index]) * track.drumLevel
            // **Soft clip rather than hard.** I cannot hear distortion, so the
            // mix must not be able to produce any: `tanh` squashes peaks
            // smoothly instead of shearing them flat, and the tests assert the
            // result never reaches full scale. Hard clipping is the one sound
            // failure that would be obvious to a listener and invisible here.
            left[index] = Float(tanh(blockLeft.process(l) * 0.8))
            right[index] = Float(tanh(blockRight.process(r) * 0.8))
        }
        return Buffer(left: left, right: right)
    }

    private static func frame(_ track: Track, bar: Int, beat: Double) -> Int {
        Int((Double(bar * track.beatsPerBar) + beat) * track.secondsPerBeat * Synth.sampleRate)
    }

    // MARK: - Effects

    private static func apply(_ envelope: [Double], to bus: inout Bus) {
        for index in 0 ..< bus.left.count {
            bus.left[index] *= envelope[index]
            bus.right[index] *= envelope[index]
        }
    }

    private static func applyDelay(to bus: inout Bus, seconds: Double,
                                   feedback: Double, mix: Double) {
        var leftLine = Synth.Delay(), rightLine = Synth.Delay()
        for index in 0 ..< bus.left.count {
            bus.left[index] = leftLine.process(bus.left[index], seconds: seconds,
                                               feedback: feedback, mix: mix)
            // The right channel echoes very slightly later, which spreads the
            // repeats across the stereo field instead of stacking them dead
            // centre where the lead already is.
            bus.right[index] = rightLine.process(bus.right[index], seconds: seconds * 1.03,
                                                 feedback: feedback, mix: mix)
        }
    }

    /// Reverb the bus, gate the result, mix it back under the dry signal.
    ///
    /// Gated across the bus rather than per hit, which is what a real gate on
    /// a drum bus does: it opens when something loud arrives and slams shut
    /// after a fixed hold, regardless of which drum opened it.
    private static func applyGatedReverb(to bus: inout Bus, hold: Double) {
        var leftRoom = Synth.Reverb(), rightRoom = Synth.Reverb()
        var wetLeft = [Double](repeating: 0, count: bus.left.count)
        var wetRight = [Double](repeating: 0, count: bus.right.count)
        for index in 0 ..< bus.left.count {
            wetLeft[index] = leftRoom.process(bus.left[index])
            wetRight[index] = rightRoom.process(bus.right[index])
        }
        let holdFrames = Int(hold * Synth.sampleRate)
        let cutFrames = max(1, Int(0.02 * Synth.sampleRate))
        var sinceHit = holdFrames + cutFrames
        for index in 0 ..< bus.left.count {
            if abs(bus.left[index]) + abs(bus.right[index]) > 0.08 { sinceHit = 0 }
            else { sinceHit += 1 }
            let open: Double
            if sinceHit < holdFrames { open = 1 } else {
                let through = Double(sinceHit - holdFrames) / Double(cutFrames)
                open = through >= 1 ? 0 : 1 - through
            }
            bus.left[index] += wetLeft[index] * open * 0.85
            bus.right[index] += wetRight[index] * open * 0.85
        }
    }

    // MARK: - Voices

    /// Driving eighths on the root through a filter that opens per note. The
    /// filter movement is the part that matters — held static this is a buzz
    /// that happens to change pitch.
    private static func renderBass(_ track: Track, into bus: inout Bus) {
        let envelope = Synth.Envelope(attack: 0.004, decay: 0.09, sustain: 0.55, release: 0.06)
        for bar in 0 ..< track.bars {
            let root = track.bassRoots[bar % track.bassRoots.count]
            for eighth in 0 ..< 8 {
                // An octave jump on the last eighth, which is what stops a
                // root-note pattern reading as a drone.
                let note = eighth == 7 ? root + 12 : root
                let start = frame(track, bar: bar, beat: Double(eighth) * 0.5)
                let held = 0.5 * track.secondsPerBeat * 0.9
                var phase = 0.0
                var filter = Synth.LowPass()
                let increment = Synth.frequency(ofNote: note) / Synth.sampleRate
                for offset in 0 ..< Int((held + envelope.release) * Synth.sampleRate) {
                    let index = start + offset
                    guard index < bus.left.count else { break }
                    let time = Double(offset) / Synth.sampleRate
                    let level = envelope.level(at: time, heldFor: held)
                    guard level > 0 else { continue }
                    let raw = Synth.saw(phase: phase, increment: increment)
                    let shaped = filter.process(raw, cutoff: 180 + 2_400 * level * level,
                                                resonance: 0.62)
                    let sample = shaped * level * 0.42
                    bus.left[index] += sample
                    bus.right[index] += sample
                    phase += increment
                    if phase >= 1 { phase -= 1 }
                }
            }
        }
    }

    /// Two saws per note, detuned against each other and panned apart.
    ///
    /// The detuning *is* the pad: one saw is thin and slightly sour, two a few
    /// cents apart beat against each other and become wide. The same trick
    /// `RegionalEconomy` uses summing two sines of co-prime period — one is a
    /// tone, two are a texture.
    private static func renderPad(_ track: Track, into bus: inout Bus) {
        let envelope = Synth.Envelope(attack: 0.35, decay: 0.4, sustain: 0.6, release: 0.5)
        for bar in 0 ..< track.bars {
            let chord = track.progression[bar % track.progression.count]
            let start = frame(track, bar: bar, beat: 0)
            let held = Double(track.beatsPerBar) * track.secondsPerBeat * 0.95
            let length = Int((held + envelope.release) * Synth.sampleRate)
            for (voiceIndex, note) in chord.enumerated() {
                for (side, cents) in [-7.0, 7.0].enumerated() {
                    var phase = Double(voiceIndex) * 0.11 + Double(side) * 0.37
                    let frequency = Synth.frequency(ofNote: note + 12) * pow(2, cents / 1_200)
                    let increment = frequency / Synth.sampleRate
                    var filter = Synth.LowPass()
                    for offset in 0 ..< length {
                        let index = start + offset
                        guard index < bus.left.count else { break }
                        let time = Double(offset) / Synth.sampleRate
                        let level = envelope.level(at: time, heldFor: held)
                        guard level > 0 else { continue }
                        let raw = Synth.saw(phase: phase, increment: increment)
                        let sample = filter.process(raw, cutoff: 1_500, resonance: 0.2) * level * 0.075
                        // The detuned copies sit on opposite sides, which is
                        // what makes the pad wide rather than merely thick.
                        bus.left[index] += sample * (side == 0 ? 1.3 : 0.7)
                        bus.right[index] += sample * (side == 0 ? 0.7 : 1.3)
                        phase += increment
                        if phase >= 1 { phase -= 1 }
                    }
                }
            }
        }
    }

    private static func renderLead(_ track: Track, into bus: inout Bus) {
        let envelope = Synth.Envelope(attack: 0.012, decay: 0.18, sustain: 0.65, release: 0.22)
        for phrase in track.melody {
            let start = frame(track, bar: phrase.bar, beat: phrase.beat)
            let held = phrase.length * track.secondsPerBeat * 0.85
            let increment = Synth.frequency(ofNote: phrase.note) / Synth.sampleRate
            var phase = 0.0
            var filter = Synth.LowPass()
            for offset in 0 ..< Int((held + envelope.release) * Synth.sampleRate) {
                let index = start + offset
                guard index < bus.left.count else { break }
                let time = Double(offset) / Synth.sampleRate
                let level = envelope.level(at: time, heldFor: held)
                guard level > 0 else { continue }
                // A narrow pulse rather than a plain square: thinner, more
                // nasal, and it cuts through a pad without needing volume.
                let raw = Synth.square(phase: phase, increment: increment, width: 0.32)
                let sample = filter.process(raw, cutoff: 3_200, resonance: 0.3) * level * 0.2
                bus.left[index] += sample * 0.95
                bus.right[index] += sample * 1.05
                phase += increment
                if phase >= 1 { phase -= 1 }
            }
        }
    }

    /// Sixteenths running through the chord — what fills the middle of a track
    /// that has no melody, so the arrangement has a pulse without a hook.
    private static func renderArpeggio(_ track: Track, into bus: inout Bus) {
        guard let arpeggio = track.arpeggio else { return }
        let envelope = Synth.Envelope(attack: 0.002, decay: 0.07, sustain: 0.0, release: 0.03)
        var step = 0
        for bar in 0 ..< track.bars {
            let chord = track.progression[bar % track.progression.count]
            for sixteenth in 0 ..< (track.beatsPerBar * 4) {
                let tone = arpeggio.shape[step % arpeggio.shape.count]
                step += 1
                let note = chord[tone % chord.count] + 12 * arpeggio.octave
                let start = frame(track, bar: bar, beat: Double(sixteenth) * 0.25)
                let held = 0.25 * track.secondsPerBeat * 0.5
                var phase = 0.0
                var filter = Synth.LowPass()
                let increment = Synth.frequency(ofNote: note) / Synth.sampleRate
                for offset in 0 ..< Int((held + envelope.totalDuration) * Synth.sampleRate) {
                    let index = start + offset
                    guard index < bus.left.count else { break }
                    let time = Double(offset) / Synth.sampleRate
                    let level = envelope.level(at: time, heldFor: held)
                    guard level > 0 else { continue }
                    let raw = Synth.square(phase: phase, increment: increment, width: 0.5)
                    let sample = filter.process(raw, cutoff: 2_600, resonance: 0.35)
                        * level * arpeggio.level
                    // Alternating sides, which is the other half of why an arp
                    // reads as movement rather than as a fast note.
                    bus.left[index] += sample * (step % 2 == 0 ? 1.25 : 0.75)
                    bus.right[index] += sample * (step % 2 == 0 ? 0.75 : 1.25)
                    phase += increment
                    if phase >= 1 { phase -= 1 }
                }
            }
        }
    }

    /// - Returns: where every kick lands, which the sidechain needs. The score
    ///   already knows, so there is nothing to detect.
    private static func renderDrums(_ track: Track, into bus: inout Bus,
                                    snareBus: inout Bus) -> [Int] {
        guard track.drums != .none else { return [] }
        var kicks: [Int] = []
        for bar in 0 ..< track.bars {
            for beat in 0 ..< track.beatsPerBar {
                let position = frame(track, bar: bar, beat: Double(beat))
                if beat == 0 || beat == 2 {
                    kick(at: position, into: &bus)
                    kicks.append(position)
                }
                if track.drums == .full, beat == 1 || beat == 3 {
                    snare(at: position, into: &snareBus, seed: UInt64(bar * 4 + beat))
                }
                for eighth in 0 ..< 2 {
                    let at = frame(track, bar: bar, beat: Double(beat) + Double(eighth) * 0.5)
                    hat(at: at, open: eighth == 1 && beat == 3,
                        into: &bus, seed: UInt64(bar * 8 + beat * 2 + eighth))
                }
            }
        }
        return kicks
    }

    /// A sine whose pitch falls from a click to a thump. That pitch envelope
    /// is the entire instrument — held at one frequency it is a beep.
    private static func kick(at start: Int, into bus: inout Bus) {
        var phase = 0.0
        for offset in 0 ..< Int(0.32 * Synth.sampleRate) {
            let index = start + offset
            guard index < bus.left.count else { break }
            let time = Double(offset) / Synth.sampleRate
            let sample = Synth.sine(phase: phase) * exp(-time * 9.5) * 0.9
            bus.left[index] += sample
            bus.right[index] += sample
            phase += (48 + 110 * exp(-time * 38)) / Synth.sampleRate
            if phase >= 1 { phase -= 1 }
        }
    }

    private static func snare(at start: Int, into bus: inout Bus, seed: UInt64) {
        var noise = Synth.Noise(seed: 0xD1CE &+ seed)
        var filter = Synth.LowPass()
        var phase = 0.0
        let increment = 185.0 / Synth.sampleRate
        for offset in 0 ..< Int(0.2 * Synth.sampleRate) {
            let index = start + offset
            guard index < bus.left.count else { break }
            let time = Double(offset) / Synth.sampleRate
            let amplitude = exp(-time * 22)
            let body = Synth.sine(phase: phase) * 0.35
            let crack = filter.process(noise.next(), cutoff: 7_500, resonance: 0.1)
            let sample = (body + crack) * amplitude * 0.5
            bus.left[index] += sample * 1.05
            bus.right[index] += sample * 0.95
            phase += increment
            if phase >= 1 { phase -= 1 }
        }
    }

    private static func hat(at start: Int, open: Bool, into bus: inout Bus, seed: UInt64) {
        let decay = open ? 9.0 : 55.0
        var noise = Synth.Noise(seed: 0x4A7 &+ seed)
        var filter = Synth.LowPass()
        for offset in 0 ..< Int((open ? 0.3 : 0.07) * Synth.sampleRate) {
            let index = start + offset
            guard index < bus.left.count else { break }
            let time = Double(offset) / Synth.sampleRate
            // High-passed by subtracting the low-passed part: a hat is what is
            // left of noise once the bottom is gone.
            let low = filter.process(noise.next(), cutoff: 6_000, resonance: 0.05)
            let sample = (noise.next() - low) * exp(-time * decay) * 0.16
            bus.left[index] += sample * 0.9
            bus.right[index] += sample * 1.1
        }
    }
}
