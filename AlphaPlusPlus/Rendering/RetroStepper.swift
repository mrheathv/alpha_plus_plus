import SwiftUI

/// A hand-built stand-in for `Stepper`, matching the rest of the
/// retrowave toolbar. macOS's native stepper chrome (the tiny paired
/// up/down arrows) can't be restyled through `ButtonStyle` the way a
/// plain `Button` can, and this toolbar has eight of them (tax rate plus
/// one per fundable service) — eight native gray steppers would stand
/// out badly against an otherwise fully neon-dark control set.
struct RetroStepper: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var accent: Color = RetroUITheme.primaryAccent

    var body: some View {
        HStack(spacing: 4) {
            Button("\u{2212}") { value = max(range.lowerBound, value - step) }
                .buttonStyle(RetroMiniButtonStyle(accent: accent))
            Text(percentLabel)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(accent)
                .frame(minWidth: 40)
            Button("+") { value = min(range.upperBound, value + step) }
                .buttonStyle(RetroMiniButtonStyle(accent: accent))
        }
    }

    private var percentLabel: String {
        "\(Int((value * 100).rounded()))%"
    }
}
