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

    /// How many options fit on one line before the picker wraps.
    ///
    /// **It wraps because it already overflowed once.** Every overlay added
    /// makes this row wider, and the row lives in the dashboard's first panel
    /// — so adding the Crime and Fire Risk maps pushed the Alerts panel narrow
    /// enough to truncate its text to "Next: Police Stati…". The tool rail
    /// above the map learned the same lesson the same way, twice. A row that
    /// grows every time a feature lands needs a wrap in it, not a bigger
    /// window.
    var perRow: Int = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(stride(from: 0, to: options.count, by: perRow)), id: \.self) { start in
                HStack(spacing: 4) {
                    ForEach(options[start ..< min(start + perRow, options.count)], id: \.self) { option in
                        Button(label(option)) { selection = option }
                            .buttonStyle(RetroButtonStyle(accent: accent, isSelected: option == selection))
                    }
                }
            }
        }
    }
}
