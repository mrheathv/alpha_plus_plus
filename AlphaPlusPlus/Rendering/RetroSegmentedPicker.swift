import SwiftUI

/// A hand-built stand-in for `Picker` with `.pickerStyle(.segmented)`,
/// styled to match the rest of the retrowave toolbar. SwiftUI's native
/// segmented control keeps its own OS chrome (light gray segments,
/// system font) regardless of `.tint()` on macOS — fine on a light
/// toolbar, but it would leave exactly one control looking stock in an
/// otherwise fully neon-dark one, the same reasoning `RetroStepper`
/// documents for replacing `Stepper`.
struct RetroSegmentedPicker<Value: Hashable>: View {
    let options: [Value]
    let label: (Value) -> String
    @Binding var selection: Value
    var accent: Color = RetroUITheme.primaryAccent

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                Button(label(option)) { selection = option }
                    .buttonStyle(RetroButtonStyle(accent: accent, isSelected: option == selection))
            }
        }
    }
}
