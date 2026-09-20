import Foundation

/// **The soundtrack is synthesised, not sampled.**
///
/// This project has exactly one raster asset — the app icon — and CLAUDE.md
/// records that as an admitted exception. A sampled soundtrack would be the
/// first real asset in it. A synthesised one is not: it is the same decision
/// the buildings already make, one medium over.
///
/// It also buys the thing a file cannot. A fixed loop is wallpaper; an
/// instrument can take the city as input the way `Weather` takes the day —
/// pads thickening with density, the bass dropping when you pause, tempo
/// following `SimulationSpeed`. That is the argument the contact light's pulse
/// already won over a blinking beacon: a mark that responds beats a mark that
/// repeats.
///
/// **Everything here is pure arithmetic over `Double`**, with no AVFoundation
/// in sight, for two reasons. It makes the whole synth testable offline — the
/// audio counterpart of rendering a contact sheet rather than playing the
/// game to look at a building. And the live render callback must not allocate
/// or lock, so the code it runs has to be this plain anyway.
enum Synth {

    static let sampleRate = 44_100.0

    // MARK: - Oscillators

    /// **Band-limited, via PolyBLEP** — and this is the one decision in the
    /// file I want to explain, because it protects against a mistake I am
    /// structurally unable to catch.
    ///
    /// A naive saw wave — ramp up, jump down — is trivial to write and aliases
    /// badly: the instantaneous jump contains energy far above Nyquist, which
    /// folds back down as inharmonic whistling that gets worse the higher you
    /// play. It is the single most common reason a hand-written synth sounds
    /// cheap.
    ///
    /// I cannot hear it. So the right move is not to write the naive version
    /// and listen for trouble; it is to use the technique that prevents it and
    /// spend the listening I do not have on things only ears can settle.
    /// PolyBLEP rounds the discontinuity over roughly one sample either side,
    /// which removes most of the aliasing for about ten lines.
    ///
    /// Same reasoning as measuring a render's pixels rather than squinting at
    /// a crop: when you cannot trust the instrument, prefer the method that
    /// cannot go wrong quietly.
    static func saw(phase: Double, increment: Double) -> Double {
        var value = 2 * phase - 1
        value -= polyBLEP(phase: phase, increment: increment)
        return value
    }

    /// A square, built from two offset saw edges so it is band-limited too.
    static func square(phase: Double, increment: Double, width: Double = 0.5) -> Double {
        let value: Double = phase < width ? 1 : -1
        let rising = polyBLEP(phase: phase, increment: increment)
        let falling = polyBLEP(phase: (phase + (1 - width)).truncatingRemainder(dividingBy: 1),
                               increment: increment)
        // **Centred.** A pulse spends `width` of its cycle high and the rest
        // low, so its mean is `2 * width - 1` — at the 32% duty the lead uses
        // that is −0.36 of constant offset, by construction. It wastes
        // headroom, thumps when the note starts and stops, and is completely
        // inaudible as itself, which is precisely the sort of fault an author
        // who cannot listen would ship. `SoundtrackTests` measured it.
        return value + rising - falling - (2 * width - 1)
    }

    static func sine(phase: Double) -> Double { sin(2 * .pi * phase) }

    /// The correction term: a parabola spliced across the discontinuity.
    private static func polyBLEP(phase: Double, increment: Double) -> Double {
        guard increment > 0 else { return 0 }
        if phase < increment {
            let t = phase / increment
            return t + t - t * t - 1
        }
        if phase > 1 - increment {
            let t = (phase - 1) / increment
            return t * t + t + t + 1
        }
        return 0
    }

    // MARK: - Noise

    /// Deterministic noise, for the same reason `RegionalEconomy` is a clock:
    /// **every render in this project has to be reproducible.** A hi-hat
    /// seeded from the system generator would make two renders of the same bar
    /// different files, and then no test could say anything about either.
    struct Noise {
        private var state: UInt64

        init(seed: UInt64 = 0x5EED_1EAF) { state = seed | 1 }

        mutating func next() -> Double {
            // xorshift64*, which is cheap enough for the audio thread and has
            // no allocation or branching worth the name.
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            let bits = state &* 2_685_821_657_736_338_717
            return Double(Int64(bitPattern: bits)) / Double(Int64.max)
        }
    }

    // MARK: - Envelope

    /// A plain ADSR, in seconds.
    ///
    /// Linear rather than exponential segments, which is not the usual choice:
    /// an exponential decay is closer to how a real instrument behaves, and
    /// for the drum voices here — where the decay *is* the sound — that
    /// difference matters. `Voice` applies its own curve where it does.
    struct Envelope {
        var attack: Double = 0.005
        var decay: Double = 0.1
        var sustain: Double = 0.7
        var release: Double = 0.15

        /// Level at `time` seconds after the note started, given how long the
        /// key was held.
        func level(at time: Double, heldFor held: Double) -> Double {
            guard time >= 0 else { return 0 }
            if time < attack { return attack > 0 ? time / attack : 1 }
            if time < attack + decay {
                let through = (time - attack) / max(decay, 1e-9)
                return 1 + (sustain - 1) * through
            }
            if time < held { return sustain }
            let since = time - held
            guard since < release else { return 0 }
            return sustain * (1 - since / max(release, 1e-9))
        }

        var totalDuration: Double { attack + decay + release }
    }

    // MARK: - Filter

    /// A two-pole resonant low-pass — the sound of this genre more than any
    /// oscillator is. A saw through an open filter is a buzz; a saw through a
    /// resonant filter that moves is a synth.
    ///
    /// State-variable rather than a biquad because the cutoff is modulated per
    /// sample here, and a biquad wants its coefficients recomputed for every
    /// change; this one takes the new cutoff directly.
    /// **Topology-preserving transform, not the classic Chamberlin form.**
    ///
    /// The obvious state-variable filter — `low += f * band; high = in - low -
    /// q * band; band += f * high` — is four lines and is only stable while
    /// the cutoff stays below about a sixth of the sample rate. Above that it
    /// does not distort, it *diverges*: the first version of this file clamped
    /// at `0.45 × fs` and a test asking for an absurd cutoff came back with
    /// infinity. At full volume, in headphones, that is not a bad sound, it is
    /// a hazard.
    ///
    /// This form is unconditionally stable for any cutoff below Nyquist, which
    /// removes the whole class rather than moving the clamp — the same
    /// preference for a method that cannot go wrong quietly that put PolyBLEP
    /// on the oscillators.
    struct LowPass {
        private var ic1 = 0.0
        private var ic2 = 0.0

        /// - Parameters:
        ///   - cutoff: hertz, clamped under Nyquist because `tan` runs away
        ///     there whatever the topology.
        ///   - resonance: 0 (gentle) to just under 1 (whistling).
        mutating func process(_ input: Double, cutoff: Double, resonance: Double) -> Double {
            let safeCutoff = min(max(cutoff, 20), Synth.sampleRate * 0.45)
            let g = tan(.pi * safeCutoff / Synth.sampleRate)
            let k = max(0.05, 2 - 2 * min(resonance, 0.96))
            let a1 = 1 / (1 + g * (g + k))
            let a2 = g * a1
            let a3 = g * a2

            let v3 = input - ic2
            let v1 = a1 * ic1 + a2 * v3
            let v2 = ic2 + a2 * ic1 + a3 * v3
            ic1 = 2 * v1 - ic1
            ic2 = 2 * v2 - ic2
            return v2
        }

        mutating func reset() { ic1 = 0; ic2 = 0 }
    }

    /// Removes whatever constant offset survives the voices.
    ///
    /// Belt and braces over centring the pulse: a decaying sine that does not
    /// complete its cycles leaves a little DC too, and every voice added later
    /// is another chance to introduce some. One pole, and it costs two
    /// multiplies a sample.
    struct DCBlocker {
        private var lastInput = 0.0
        private var lastOutput = 0.0

        mutating func process(_ input: Double) -> Double {
            let output = input - lastInput + 0.995 * lastOutput
            lastInput = input
            lastOutput = output
            return output
        }
    }

    // MARK: - Pitch

    /// Hertz for a MIDI note number. 69 is A440, and every note in the score
    /// is written as one of these because naming a bass note "41" is far less
    /// error-prone than writing 87.307 Hz.
    static func frequency(ofNote note: Int) -> Double {
        440 * pow(2, (Double(note) - 69) / 12)
    }
}
