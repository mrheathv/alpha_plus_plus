import SwiftUI

/// The toolbar's primary button chrome: a dark fill with a neon outline
/// in the button's own accent color, brightening to a solid fill of that
/// color when selected/active — the same "dark silhouette, neon glow"
/// language `ZoneIcon` already uses for every building, just applied to
/// the button that places it rather than the building itself.
struct RetroButtonStyle: ButtonStyle {
    var accent: Color = RetroUITheme.primaryAccent
    var isSelected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isSelected ? Color.black : accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? accent : Color.black.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(accent, lineWidth: 1.4)
            )
            .shadow(color: accent.opacity(isSelected ? 0.85 : 0.3), radius: isSelected ? 5 : 2)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            // The native `.pickerStyle(.segmented)`/`Stepper` this and
            // `RetroSegmentedPicker` replace both got an explicit `.frame`
            // width from their call site, which kept them a fixed size
            // regardless of how crowded the row around them got. A plain
            // `Button` has no such floor — once `zoningRow` (13 zone
            // buttons plus Play/Speed/Advance) needs more width than the
            // window has, a squeezed HStack shrinks the *last* things it
            // lays out first, and without this a control here could
            // compress toward zero width with its label silently clipped
            // to nothing rather than just wrapping or staying readable.
            // `.fixedSize()` refuses that: the button keeps its natural
            // size and the row overflows the window's edge instead,
            // which at least stays visibly readable rather than quietly
            // disappearing.
            .fixedSize()
    }
}

/// A tiny circular +/- button for `RetroStepper` — same "dark fill, neon
/// outline" family as `RetroButtonStyle`, sized down and with no
/// selected-fill state (a stepper button doesn't have an "on" state,
/// only a pressed one).
struct RetroMiniButtonStyle: ButtonStyle {
    var accent: Color = RetroUITheme.primaryAccent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(accent)
            .frame(width: 16, height: 16)
            .background(Circle().fill(Color.black.opacity(0.4)))
            .overlay(Circle().stroke(accent, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}
