import SwiftUI

/// The toolbar's primary button chrome: a dark fill with a neon outline
/// in the button's own accent color, brightening to a solid fill of that
/// color when selected/active — the same "dark silhouette, neon glow"
/// language `NeonStyle` already gives every building, just applied to
/// the button that places it rather than the building itself.
struct RetroButtonStyle: ButtonStyle {
    var accent: Color = RetroUITheme.primaryAccent
    var isSelected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isSelected ? Color.black : accent)
            .padding(.horizontal, RetroMetrics.chipPaddingH)
            .padding(.vertical, RetroMetrics.chipPaddingV)
            .background(
                // Chamfered, not rounded. A cut corner is the 80s tech-panel
                // corner, and it is the single cheapest thing that stops this
                // chrome reading as a dark-mode macOS button.
                ChamferedRectangle()
                    .fill(isSelected ? accent : Color.black.opacity(0.45))
            )
            .overlay(
                ChamferedRectangle()
                    .stroke(accent, lineWidth: 1.4)
            )
            // Two shadows: a tight one that reads as the tube's own edge, and
            // a wide faint one that reads as light spilling onto the panel
            // behind it. One shadow can be either a glow or a bloom; neon is
            // both at once, which is why the buildings on the map draw a
            // crisp stroke over a blurred copy of themselves.
            .shadow(color: accent.opacity(isSelected ? 0.9 : 0.35), radius: isSelected ? 4 : 2)
            .shadow(color: accent.opacity(isSelected ? 0.5 : 0.12), radius: isSelected ? 12 : 7)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            // The native controls this replaced got an explicit `.frame` width
            // from their call site, which kept them a fixed size however
            // crowded the row got. A plain `Button` has no such floor: a
            // squeezed `HStack` shrinks the last things it lays out first, and
            // without this a control could compress toward zero width with its
            // label silently clipped to nothing. `.fixedSize()` refuses that —
            // the row overflows visibly instead of quietly disappearing.
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
