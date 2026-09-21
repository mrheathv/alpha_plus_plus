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

    /// Every voice on its own, after its effects and the sidechain, before
    /// the sum. The mix engineer's solo button: when a band of the finished
    /// mix is wrong, this is what says which instrument put it there.
    struct Stems {
        var bass: Bus, pad: Bus, lead: Bus, arp: Bus, kicks: Bus, hats: Bus, snares: Bus
        var frames: Int { bass.left.count }

        var named: [(name: String, bus: Bus)] {
            [("bass", bass), ("pad", pad), ("lead", lead), ("arp", arp),
             ("kicks", kicks), ("hats", hats), ("snares", snares)]
        }
    }

    static func render(_ track: Track) -> Buffer {
        let stems = renderStems(track)
        let frames = stems.frames
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        var blockLeft = Synth.DCBlocker(), blockRight = Synth.DCBlocker()
        for index in 0 ..< frames {
            let l = stems.bass.left[index] * track.bassLevel + stems.pad.left[index] * track.padLevel
                + stems.lead.left[index] * track.leadLevel + stems.arp.left[index]
                + (stems.kicks.left[index] + stems.hats.left[index] + stems.snares.left[index]) * track.drumLevel
            let r = stems.bass.right[index] * track.bassLevel + stems.pad.right[index] * track.padLevel
                + stems.lead.right[index] * track.leadLevel + stems.arp.right[index]
                + (stems.kicks.right[index] + stems.hats.right[index] + stems.snares.right[index]) * track.drumLevel
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

    static func renderStems(_ track: Track) -> Stems {
        let frames = Int(track.duration * Synth.sampleRate)
        var bass = Bus(frames: frames)
        var pad = Bus(frames: frames)
        var lead = Bus(frames: frames)
        var arp = Bus(frames: frames)
        var kicks = Bus(frames: frames)
        var hats = Bus(frames: frames)
        var snares = Bus(frames: frames)

        renderBass(track, into: &bass)
        renderPad(track, into: &pad)
        renderLead(track, into: &lead)
        renderArpeggio(track, into: &arp)
        let kickFrames = renderDrums(track, into: &kicks, hatBus: &hats, snareBus: &snares)

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
        let duck = Synth.duckEnvelope(frames: frames, kicks: kickFrames)
        apply(duck, to: &bass)
        apply(duck, to: &pad)
        apply(duck, to: &lead)
        apply(duck, to: &arp)
        apply(duck, to: &snares)

        return Stems(bass: bass, pad: pad, lead: lead, arp: arp, kicks: kicks, hats: hats, snares: snares)
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

    /// One bass note, as the pattern hands them out.
    private struct BassNote {
        let beat: Double
        let note: Int
        let lengthInBeats: Double
    }

    /// What `Track.BassPattern` means in notes, one bar's worth.
    private static func bassNotes(for pattern: Track.BassPattern, root: Int) -> [BassNote] {
        switch pattern {
        case .drivingEighths:
            // An octave jump on the last eighth, which is what stops a
            // root-note pattern reading as a drone.
            return (0 ..< 8).map { BassNote(beat: Double($0) * 0.5, note: $0 == 7 ? root + 12 : root, lengthInBeats: 0.5) }
        case .octaves:
            return (0 ..< 8).map { BassNote(beat: Double($0) * 0.5, note: $0 % 2 == 1 ? root + 12 : root, lengthInBeats: 0.5) }
        case .sixteenths:
            return (0 ..< 16).map { BassNote(beat: Double($0) * 0.25, note: $0 % 4 == 3 ? root + 12 : root, lengthInBeats: 0.25) }
        case .held:
            return [BassNote(beat: 0, note: root, lengthInBeats: 4)]
        }
    }

    /// The root through a filter that opens per note. The filter movement is
    /// the part that matters — held static this is a buzz that happens to
    /// change pitch.
    private static func renderBass(_ track: Track, into bus: inout Bus) {
        for bar in track.bassEntersAtBar ..< track.bars {
            let root = track.bassRoots[bar % track.bassRoots.count]
            for bassNote in bassNotes(for: track.bassPattern, root: root) {
                let frequency = Synth.frequency(ofNote: bassNote.note)

                // **The attack has to be long relative to the note's own
                // period, or it clicks.** This was a flat 4 ms, and Small
                // Hours' lowest note is 41 Hz — a 24 ms cycle — so the
                // envelope opened fully in a sixth of a single cycle. That
                // cannot establish a low pitch; what you hear instead is a
                // transient, which is precisely how it was reported: "the
                // bass is a little clicky".
                //
                // Roughly one period, floored so the faster tracks keep their
                // punch: 41 Hz gets 24 ms, 110 Hz gets 9 ms. A held note
                // swells in over far longer, because it has no beat to hit.
                let held = bassNote.lengthInBeats * track.secondsPerBeat * (track.bassPattern == .held ? 0.97 : 0.9)
                let isHeld = track.bassPattern == .held
                let attack = isHeld ? 0.12 : max(0.006, 1.0 / frequency)
                let envelope = Synth.Envelope(attack: attack, decay: isHeld ? 0.5 : 0.09,
                                              sustain: isHeld ? 0.8 : 0.55, release: isHeld ? 0.2 : 0.06)
                let start = frame(track, bar: bar, beat: bassNote.beat)
                var phase = 0.0
                var filter = Synth.LowPass()
                // The filter gets its own, slower movement. Swept straight off
                // the amplitude envelope it ran 180 Hz to 2,580 Hz in the same
                // few milliseconds, which is a zap laid on top of the click.
                var smoothedCutoff = 180.0
                let increment = frequency / Synth.sampleRate
                for offset in 0 ..< Int((held + envelope.release) * Synth.sampleRate) {
                    let index = start + offset
                    guard index < bus.left.count else { break }
                    let time = Double(offset) / Synth.sampleRate
                    let level = envelope.level(at: time, heldFor: held)
                    guard level > 0 else { continue }
                    // A held bass keeps its filter low and slow: it is a
                    // floor, not a figure.
                    let target = isHeld ? 180 + 700 * level : 180 + 2_400 * level * level
                    smoothedCutoff += (target - smoothedCutoff) * (isHeld ? 0.0004 : 0.0016)
                    let raw = Synth.saw(phase: phase, increment: increment)
                    let shaped = filter.process(raw, cutoff: smoothedCutoff, resonance: 0.62)
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
        let sweepFrames = Double(track.beatsPerBar * 4) * track.secondsPerBeat * Synth.sampleRate
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
                        // **The filter drifts on a four-bar cycle**, computed
                        // from the track's own clock rather than the note's,
                        // so every voice of every chord is on the same sweep
                        // and a chord change does not restart it.
                        let cutoff = track.padCutoff * (1 + 0.5 * track.padSweep * sin(2 * .pi * Double(index) / sweepFrames))
                        let sample = filter.process(raw, cutoff: cutoff, resonance: 0.2) * level * 0.12
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
        let envelope = arpeggio.timbre == .pluck
            ? Synth.Envelope(attack: 0.002, decay: 0.16, sustain: 0.0, release: 0.05)
            : Synth.Envelope(attack: 0.002, decay: 0.07, sustain: 0.0, release: 0.03)
        var step = 0
        for bar in track.arpeggioEntersAtBar ..< track.bars {
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
                    let sample: Double
                    switch arpeggio.timbre {
                    case .square:
                        let raw = Synth.square(phase: phase, increment: increment, width: 0.5)
                        sample = filter.process(raw, cutoff: 2_600, resonance: 0.35) * level * arpeggio.level * 1.5
                    case .saw:
                        let raw = Synth.saw(phase: phase, increment: increment)
                        sample = filter.process(raw, cutoff: 3_400, resonance: 0.3) * level * arpeggio.level * 1.5
                    case .pluck:
                        // A sine with a little second harmonic, and the
                        // harmonic dies first — which is what a plucked
                        // string does, and why it reads as one rather than
                        // as a test tone.
                        let raw = Synth.sine(phase: phase) + 0.35 * level * Synth.sine(phase: (phase * 2).truncatingRemainder(dividingBy: 1))
                        sample = raw * level * arpeggio.level * 2.4
                    }
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
                                    hatBus: inout Bus, snareBus: inout Bus) -> [Int] {
        guard track.drums != .none else { return [] }
        var kicks: [Int] = []
        for bar in track.drumsEnterAtBar ..< track.bars {
            for beat in 0 ..< track.beatsPerBar {
                let position = frame(track, bar: bar, beat: Double(beat))
                if track.drums == .driving || beat == 0 || beat == 2 {
                    kick(at: position, into: &bus)
                    kicks.append(position)
                }
                if track.drums == .full || track.drums == .driving, beat == 1 || beat == 3 {
                    snare(at: position, into: &snareBus, seed: UInt64(bar * 4 + beat))
                }
                for eighth in 0 ..< 2 {
                    let at = frame(track, bar: bar, beat: Double(beat) + Double(eighth) * 0.5)
                    // The off-beat hat is quieter. Eight identical hats a bar
                    // is a metronome; accented on the beat they are a pattern.
                    hat(at: at, open: eighth == 1 && beat == 3, accent: eighth == 0 ? 1 : 0.6,
                        into: &hatBus, seed: UInt64(bar * 8 + beat * 2 + eighth))
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
            // 0.7 rather than 0.9. Soloed, the kick peaked at +2.5 dBFS and
            // sat 10 dB above the pad — a drum machine with a synth behind
            // it, and every peak of it squashed by the master's soft clip.
            let sample = Synth.sine(phase: phase) * exp(-time * 9.5) * 0.7
            bus.left[index] += sample
            bus.right[index] += sample
            // Settles at 56 Hz rather than 48. A laptop cannot make 48 Hz,
            // and a kick that lands there is felt on a subwoofer and heard as
            // a click on everything else.
            phase += (56 + 110 * exp(-time * 38)) / Synth.sampleRate
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
            let sample = (body + crack) * amplitude * 0.75
            bus.left[index] += sample * 1.05
            bus.right[index] += sample * 0.95
            phase += increment
            if phase >= 1 { phase -= 1 }
        }
    }

    private static func hat(at start: Int, open: Bool, accent: Double, into bus: inout Bus, seed: UInt64) {
        // A closed hat rings for a few tens of milliseconds, not nine: at
        // the old 55/s it was gone in a sixth of an eighth note and averaged
        // to almost nothing over the bar, however loud its first sample.
        let decay = open ? 7.0 : 30.0
        var noise = Synth.Noise(seed: 0x4A7 &+ seed)
        var filter = Synth.LowPass()
        for offset in 0 ..< Int((open ? 0.3 : 0.07) * Synth.sampleRate) {
            let index = start + offset
            guard index < bus.left.count else { break }
            let time = Double(offset) / Synth.sampleRate
            // High-passed by subtracting the low-passed part: a hat is what is
            // left of noise once the bottom is gone.
            let low = filter.process(noise.next(), cutoff: 6_000, resonance: 0.05)
            // 0.3 rather than 0.16. At the old level the hats were −20 dB
            // below everything else in the air band, which is to say the
            // mix had no top end at all; measured, not guessed.
            let sample = (noise.next() - low) * exp(-time * decay) * 0.3 * accent
            bus.left[index] += sample * 0.9
            bus.right[index] += sample * 1.1
        }
    }
}
