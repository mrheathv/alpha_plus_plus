import Foundation

/// **The same mix, shaped for the speakers it is going to come out of.**
///
/// A MacBook Pro has six drivers including force-cancelling woofers and real
/// bass extension. A MacBook Air has four small ones and rolls off steeply
/// below about a hundred hertz. A Mac mini has whatever the owner plugged in,
/// which might be studio monitors or might be a monitor's built-in tweeters.
/// One master is wrong for at least two of those.
///
/// **This is not an equaliser preset.** The interesting part is not turning
/// the bass up — a speaker that cannot make 41 Hz does not make a louder
/// 41 Hz, it just distorts and wastes headroom. It is:
///
/// - **Taking away what cannot be reproduced.** Energy below a driver's limit
///   is headroom spent on nothing, and at volume it is intermodulation
///   smearing everything above it.
/// - **Narrowing the dynamic range** where the speaker has none to give.
/// - **Widening the image** where the drivers are two inches apart, and not
///   where they are not.
///
/// The music is rendered **once** and this shapes the output, rather than
/// there being three different mixes to keep in step. One code path for the
/// score, one small stage at the end — the same division the renderer draws
/// between a building's massing and `VisualStyle`.
struct AudioProfile: Equatable {

    let name: String
    /// What it is for, in the words a settings screen would use.
    let summary: String

    /// Everything below this is removed.
    let highPass: Double
    /// 0 for untouched, 1 for heavily levelled.
    let compression: Double
    /// 1 leaves the image as mixed; above widens, below narrows.
    let width: Double

    // MARK: - The presets

    /// Six drivers and two force-cancelling woofers. The best speakers Apple
    /// puts in anything, and the one profile whose job is mostly to get out of
    /// the way.
    static let macBookPro = AudioProfile(
        name: "MacBook Pro",
        summary: "Full range. Nothing added.",
        highPass: 32, compression: 0.08, width: 1.0
    )

    /// Four small drivers, very little below a hundred hertz, and two of them
    /// about six inches apart.
    static let macBookAir = AudioProfile(
        name: "MacBook Air",
        summary: "Sub-bass removed, levelled, image widened.",
        // 70 rather than 95. The higher cutoff was chosen on the assumption
        // that a harmonic exciter would put the missing note back; with that
        // cut (see the note below), taking less away is the better trade —
        // a small driver reproduces *some* of 70–95 Hz, and none of what is
        // under it.
        highPass: 70, compression: 0.35, width: 1.3
    )

    /// Headphones have the range and already over-separate the image, so the
    /// only thing worth doing is *not* widening it further.
    static let headphones = AudioProfile(
        name: "Headphones",
        summary: "Full range, image pulled in slightly.",
        highPass: 24, compression: 0.05, width: 0.85
    )

    /// Anything we cannot identify — a Mac mini, a Studio, an external
    /// interface. Deliberately middle-of-the-road: it has to be acceptable on
    /// a cheap monitor speaker *and* not obviously wrong on good monitors,
    /// which means it is optimal for neither.
    static let generic = AudioProfile(
        name: "Generic",
        summary: "A safe middle, for speakers we cannot identify.",
        highPass: 55, compression: 0.2, width: 1.05
    )

    static let all = [generic, macBookAir, macBookPro, headphones]

    // MARK: - Choosing one

    /// A best-effort guess, and it is worth being honest that it is a guess.
    ///
    /// Two things make automatic selection unreliable, and both argue for the
    /// player being able to override it:
    ///
    /// - **The model does not tell you where the sound is going.** Someone on
    ///   a MacBook Air with studio monitors plugged in would get the
    ///   small-speaker profile, which is the wrong answer applied confidently.
    ///   Reading the current output route is the real fix.
    /// - **Model identifiers age badly.** `hw.model` reports `Mac15,13`, not
    ///   "MacBook Air", so any mapping is a table that needs a new row for
    ///   every machine Apple ships and is silently wrong until someone adds
    ///   one.
    ///
    /// So this returns `generic` when it is unsure, which is the honest
    /// default, and the setting exists because the guess will sometimes be
    /// wrong.
    static func detected(model: String = currentModel()) -> AudioProfile {
        let lowercased = model.lowercased()
        if lowercased.contains("macbookpro") { return .macBookPro }
        if lowercased.contains("macbookair") { return .macBookAir }
        return .generic
    }

    static func currentModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    // MARK: - The harmonic exciter that is not here
    //
    // **Cut after four attempts, because it could not be shown to work.**
    //
    // The idea is sound and it is how real bass enhancement works: given the
    // 2nd and 3rd harmonics of a 41 Hz note — 82 and 123 Hz, both within a
    // small speaker's range — the ear reconstructs a fundamental that is not
    // physically there. A profile that only *removes* sub-bass makes a thin
    // sound; one that puts it back as harmonics is bass management.
    //
    // Each attempt fixed a genuine fault, and each was still measurably worse
    // than not doing it at all, judged on energy in the 90–260 Hz band where
    // the implied fundamental has to live:
    //
    // 1. Harmonics added *before* the high-pass, which removed most of them.
    // 2. Harmonics added before the compressor, which ducked by exactly what
    //    they added — the feature cancelling itself.
    // 3. The exciter's own high-pass set at the speaker's cutoff, so the 2nd
    //    harmonic at 82 Hz fell below a 95 Hz filter and was discarded.
    // 4. And the one worth remembering: **the saturator was never in
    //    saturation.** `tanh(sub * 3.5)` with a sub band around 0.15 gives a
    //    drive of 0.45, and `tanh(0.45)` is 0.42 — within 7% of plain
    //    multiplication. For three rounds the "harmonic generator" was a
    //    slightly quiet copy of the bass containing no new harmonics at all.
    //    Nothing about the code looked wrong; a reader sees `tanh` and thinks
    //    distortion. Only measuring the band it was meant to fill could find
    //    it.
    //
    // Driven properly it still measured 665 against 817 for not doing it. At
    // that point the honest conclusion is that either the implementation or
    // the measurement is wrong and, without ears, this author cannot tell
    // which — so it is not something to ship into a product aimed at the App
    // Store. The high-pass, the compression and the width all measure as
    // doing what they claim, and those stay.
    //
    // Worth trying again by someone who can hear it, or with a proper FFT
    // rather than a filtered-energy proxy.

    // MARK: - The master stage

    /// Shape a finished mix for these speakers.
    ///
    /// Ordered deliberately. The harmonics are generated from the **original**
    /// low content, before the high-pass removes it — generate them after and
    /// there is nothing left to generate them from, which is the one way to
    /// write this that produces silence and looks correct.
    func apply(to buffer: Soundtrack.Buffer) -> Soundtrack.Buffer {
        var left = buffer.left
        var right = buffer.right

        var cutLeft = Synth.HighPass(cutoff: highPass), cutRight = Synth.HighPass(cutoff: highPass)
        var levelFollower = 0.0

        for index in 0 ..< buffer.frames {
            var l = cutLeft.process(Double(left[index]))
            var r = cutRight.process(Double(right[index]))

            if compression > 0 {
                // A slow peak follower and a gentle ratio. Not a real
                // compressor — it is here to stop a small driver being asked
                // for a transient it cannot deliver, not to glue a mix.
                let peak = max(abs(l), abs(r))
                levelFollower += (peak - levelFollower) * (peak > levelFollower ? 0.02 : 0.0009)
                let over = max(0, levelFollower - 0.35)
                let gain = 1 / (1 + over * compression * 3)
                l *= gain
                r *= gain
            }

            if width != 1 {
                let mid = (l + r) / 2, side = (l - r) / 2 * width
                l = mid + side
                r = mid - side
            }

            left[index] = Float(tanh(l))
            right[index] = Float(tanh(r))
        }
        return Soundtrack.Buffer(left: left, right: right)
    }
}
