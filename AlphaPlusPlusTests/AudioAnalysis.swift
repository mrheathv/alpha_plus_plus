import Accelerate
import Foundation
@testable import AlphaPlusPlus

/// **A spectrum analyser for an author who cannot listen.**
///
/// Every earlier measurement of the soundtrack was a filtered-energy proxy —
/// run the mix through a low-pass and sum the squares — and `AudioProfile`'s
/// own postmortem on the harmonic exciter ends by asking for "a proper FFT
/// rather than a filtered-energy proxy". This is that. Welch's method: the
/// track is cut into overlapping Hann windows, each is transformed, and the
/// power spectra are averaged, so a band figure is a statement about the whole
/// track rather than about whichever window happened to be looked at.
///
/// It is the audio counterpart of `ZoneIconContactSheetTests`: not a judgement
/// of whether a track is good, but a picture of it that can be compared
/// against the one from before a change.
enum AudioAnalysis {

    /// Averaged power per bin, and what one bin is worth in hertz.
    struct Spectrum {
        let binWidth: Double
        let power: [Double]

        /// Summed power between two frequencies.
        func energy(from low: Double, to high: Double) -> Double {
            let first = max(0, Int(low / binWidth))
            let last = min(power.count - 1, Int(high / binWidth))
            guard first <= last else { return 0 }
            return power[first ... last].reduce(0, +)
        }

        var total: Double { power.reduce(0, +) }

        /// Where the energy sits, as a single frequency — the usual proxy for
        /// "bright" against "dark".
        var centroid: Double {
            var weighted = 0.0
            for (index, value) in power.enumerated() { weighted += Double(index) * binWidth * value }
            return total > 0 ? weighted / total : 0
        }
    }

    static func spectrum(of samples: [Float], windowSize: Int = 4_096) -> Spectrum {
        let hop = windowSize / 2
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                 count: windowSize, isHalfWindow: false)
        let dft = vDSP.DFT(count: windowSize, direction: .forward,
                           transformType: .complexComplex, ofType: Float.self)!

        var accumulated = [Double](repeating: 0, count: windowSize / 2)
        var windows = 0
        var real = [Float](repeating: 0, count: windowSize)
        let imaginary = [Float](repeating: 0, count: windowSize)
        var outReal = [Float](repeating: 0, count: windowSize)
        var outImaginary = [Float](repeating: 0, count: windowSize)

        var start = 0
        while start + windowSize <= samples.count {
            vDSP.multiply(samples[start ..< start + windowSize], window, result: &real)
            dft.transform(inputReal: real, inputImaginary: imaginary,
                          outputReal: &outReal, outputImaginary: &outImaginary)
            for bin in 0 ..< windowSize / 2 {
                let re = Double(outReal[bin]), im = Double(outImaginary[bin])
                accumulated[bin] += re * re + im * im
            }
            windows += 1
            start += hop
        }
        guard windows > 0 else { return Spectrum(binWidth: Synth.sampleRate / Double(windowSize), power: accumulated) }
        return Spectrum(binWidth: Synth.sampleRate / Double(windowSize),
                        power: accumulated.map { $0 / Double(windows) })
    }

    // MARK: - The report

    /// The bands a mix engineer talks in. Sub is what a small speaker cannot
    /// make; bass is the note; low-mid is where a mix goes muddy; presence is
    /// where it cuts; air is where it hisses.
    static let bands: [(name: String, low: Double, high: Double)] = [
        ("sub", 20, 60), ("bass", 60, 150), ("lowmid", 150, 400),
        ("mid", 400, 2_000), ("presence", 2_000, 6_000), ("air", 6_000, 16_000),
    ]

    struct Report {
        /// Peak sample, in dBFS.
        let peak: Double
        /// RMS over the whole track, in dBFS — how loud it *is* rather than
        /// how loud its loudest instant is.
        let rms: Double
        /// Peak over RMS, in dB. Low means squashed, high means dynamic.
        var crest: Double { peak - rms }
        /// Correlation between the channels: 1 is mono, 0 is fully wide, and
        /// negative is out of phase, which collapses on a mono speaker.
        let correlation: Double
        let centroid: Double
        /// Each band's share of the whole, in dB relative to the total.
        let bands: [(name: String, share: Double)]
    }

    static func report(_ buffer: Soundtrack.Buffer) -> Report {
        let frames = buffer.frames
        var mono = [Float](repeating: 0, count: frames)
        vDSP.add(buffer.left, buffer.right, result: &mono)
        vDSP.multiply(0.5, mono, result: &mono)

        let peak = max(vDSP.maximumMagnitude(buffer.left), vDSP.maximumMagnitude(buffer.right))
        let rms = vDSP.rootMeanSquare(mono)

        var dotLR = 0.0, dotLL = 0.0, dotRR = 0.0
        for index in 0 ..< frames {
            let l = Double(buffer.left[index]), r = Double(buffer.right[index])
            dotLR += l * r; dotLL += l * l; dotRR += r * r
        }
        let correlation = (dotLL > 0 && dotRR > 0) ? dotLR / (dotLL * dotRR).squareRoot() : 1

        let spectrum = spectrum(of: mono)
        let total = spectrum.total
        return Report(
            peak: decibels(Double(peak)),
            rms: decibels(Double(rms)),
            correlation: correlation,
            centroid: spectrum.centroid,
            bands: bands.map { ($0.name, powerDecibels(spectrum.energy(from: $0.low, to: $0.high) / max(total, 1e-12))) }
        )
    }

    static func decibels(_ ratio: Double) -> Double { 20 * log10(max(ratio, 1e-9)) }
    /// Bands are power ratios, so 10 rather than 20 — using the amplitude
    /// formula on a power ratio doubles every figure and a −6 dB share reads
    /// as −12.
    static func powerDecibels(_ ratio: Double) -> Double { 10 * log10(max(ratio, 1e-12)) }

    // MARK: - Printing

    static func header() -> String {
        // `%@` ignores its width, so the columns are padded by hand.
        var line = "track".padding(toLength: 18, withPad: " ", startingAt: 0)
        for column in ["peak", "rms", "crest", "corr", "centre"] { line += column.leftPadded(to: 7) }
        for band in bands { line += band.name.leftPadded(to: 9) }
        return line
    }

    static func row(_ name: String, _ report: Report) -> String {
        var line = name.padding(toLength: 18, withPad: " ", startingAt: 0)
        line += String(format: "%7.1f%7.1f%7.1f%7.2f%5.0fHz", report.peak, report.rms,
                       report.crest, report.correlation, report.centroid)
        for band in report.bands { line += String(format: "%9.1f", band.share) }
        return line
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        String(repeating: " ", count: max(0, width - count)) + self
    }
}
