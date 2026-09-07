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
        HStack(spacing: 3) {
            Text(label)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            HStack(spacing: 1.5) {
                ForEach(0 ..< Self.segmentCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(index < filledSegments ? fillColor : Color.gray.opacity(0.25))
                        .frame(width: 5, height: 10)
                }
            }
        }
    }
}
