import SwiftUI

/// The cockpit's primary button chrome: a dark fill with a neon outline in the
/// button's own accent colour, brightening to a solid fill of that colour when
/// selected — the same "dark silhouette, neon glow" language `NeonStyle` gives
/// every building, applied to the button that places it.
struct RetroButtonStyle: ButtonStyle {
    var accent: Color = RetroUITheme.primaryAccent
    var isSelected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        // A `ButtonStyle` cannot hold `@State`, so the hover response lives in
        // a small view of its own. Worth the indirection: a neon sign that does
        // not answer the cursor reads as a picture of a control rather than a
        // control.
        Chrome(configuration: configuration, accent: accent, isSelected: isSelected)
    }

    private struct Chrome: View {
        let configuration: Configuration
        let accent: Color
        let isSelected: Bool
        @State private var isHovered = false

        /// How hard the sign burns. Selected is bright and stays bright;
        /// hovering lifts an unselected button most of the way there, which is
        /// what makes the row feel alive under the cursor.
        private var glow: Double {
            if isSelected { return isHovered ? 1.0 : 0.9 }
            return isHovered ? 0.7 : 0.35
        }

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? Color.black : accent)
                .padding(.horizontal, RetroMetrics.chipPaddingH)
                .padding(.vertical, RetroMetrics.chipPaddingV)
                .background(
                    // Chamfered, not rounded. A cut corner is the 80s
                    // tech-panel corner, and the cheapest single thing that
                    // stops this reading as a dark-mode macOS button.
                    ChamferedRectangle()
                        .fill(isSelected ? accent : Color.black.opacity(isHovered ? 0.3 : 0.45))
                )
                .overlay(ChamferedRectangle().stroke(accent, lineWidth: 1.4))
                // Two shadows: a tight one that reads as the tube's own edge,
                // and a wide faint one that reads as light spilling onto the
                // panel behind it. One shadow can be a glow or a bloom; neon is
                // both at once, which is why every building on the map draws a
                // crisp stroke over a blurred copy of itself.
                .shadow(color: accent.opacity(glow), radius: isSelected ? 4 : 2)
                .shadow(color: accent.opacity(glow * 0.55), radius: isSelected || isHovered ? 12 : 7)
                .opacity(configuration.isPressed ? 0.75 : 1.0)
                // The native controls this replaced took an explicit `.frame`
                // width from their call site, which kept them a fixed size
                // however crowded the row got. A plain `Button` has no such
                // floor: a squeezed `HStack` shrinks the last things it lays
                // out first, and without this a control could compress toward
                // zero width with its label silently clipped to nothing.
                .fixedSize()
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
    }
}

/// A tiny circular +/- button for `RetroStepper` — the same "dark fill, neon
/// outline" family, sized down, with no selected state (a stepper button has
/// no "on", only a pressed).
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
