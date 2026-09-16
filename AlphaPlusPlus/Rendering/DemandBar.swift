import SwiftUI

/// A compact 5-segment bar showing how much the city currently wants more
/// of one RCI type — `CityDemand`'s own -1...1 scale (see `Demand.swift`'s
/// doc comment for what the number means and how it feeds back into
/// growth), filled toward green (positive: the city wants more) or a
/// warm orange (negative: already oversupplied) rather than one fixed
/// color, so the *direction* reads at a glance, not just the magnitude.
/// Used in `GameView`'s stats readout next to Population/Jobs/Treasury —
/// the one place this project's demand-gated growth (`CitySimulator.advance`)
/// was otherwise entirely invisible to the player.
struct DemandBar: View {
    let label: String
    /// -1 (oversupplied) ... 1 (in demand).
    let value: Double

    private static let segmentCount = 5

    private var filledSegments: Int {
        min(Self.segmentCount, Int((abs(value) * Double(Self.segmentCount)).rounded()))
    }

    private var fillColor: Color {
        value >= 0 ? .green : .orange
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .bold).monospaced())
                .foregroundStyle(RetroUITheme.textSecondary)
            // Square segments with an accent-tinted track and a glow on the
            // lit ones — the same language `RetroMeter` uses for utility load.
            // These were rounded rectangles on a grey track, which is the only
            // place in the cockpit that still looked like a progress bar
            // rather than an instrument.
            HStack(spacing: 2) {
                ForEach(0 ..< Self.segmentCount, id: \.self) { index in
                    let lit = index < filledSegments
                    Rectangle()
                        .fill(lit ? fillColor : fillColor.opacity(0.14))
                        .frame(width: 5, height: 11)
                        .shadow(color: lit ? fillColor.opacity(0.8) : .clear, radius: 2)
                }
            }
        }
    }
}
