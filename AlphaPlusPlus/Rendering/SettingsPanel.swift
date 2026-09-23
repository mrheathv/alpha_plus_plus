import SwiftUI

/// **The settings this game had none of.**
///
/// There was no panel at all: the one thing a player could change about how
/// the game looks lived in a menu, and nothing about motion or the keyboard
/// was reachable or even written down on screen. That is a storefront
/// expectation before it is a nicety.
///
/// **What is deliberately not here is a volume control.** There is no audio in
/// the app yet — the synthesiser is written and tested and nothing plays it —
/// and a slider that moved nothing would be exactly the failure this project
/// has shipped twice and recorded twice: a control that compiles and does
/// nothing. It arrives with the sound, in one change, or not at all.
struct SettingsPanel: View {
    @ObservedObject var controller: GameController
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RetroSectionLabel(text: "Settings", accent: RetroUITheme.primaryAccent)
            visuals.frame(maxWidth: .infinity, alignment: .leading)
            renderer.frame(maxWidth: .infinity, alignment: .leading)
            motion.frame(maxWidth: .infinity, alignment: .leading)
            keyboard.frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(18)
        .frame(width: 440)
        .background(RetroUITheme.background)
    }

    // Small named properties rather than one expression, for the reason
    // `NewCityPanel` records: as a single body this defeats the type checker
    // and reports it as a diagnostic it cannot produce.
    private var visuals: some View {
        RetroPanel(title: "Visuals") {
            VStack(alignment: .leading, spacing: 8) {
                RetroSegmentedPicker(
                    options: VisualStyle.allCases,
                    label: \.displayName,
                    selection: $controller.visualStyle
                )
                Text(controller.visualStyle.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(RetroUITheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// For the length of the Metal migration only. See `MapRenderer`.
    private var renderer: some View {
        RetroPanel(title: "Renderer") {
            VStack(alignment: .leading, spacing: 8) {
                RetroSegmentedPicker(
                    options: MapRenderer.allCases,
                    label: \.displayName,
                    selection: $controller.mapRenderer
                )
                Text(controller.mapRenderer.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(RetroUITheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var motion: some View {
        RetroPanel(title: "Motion") {
            VStack(alignment: .leading, spacing: 8) {
                RetroToolChip(
                    title: "Reduce motion",
                    accent: RetroUITheme.primaryAccent,
                    isSelected: controller.reduceMotion
                ) { controller.reduceMotion.toggle() }
                Text("Stops the rain, the factory smoke and the slow pulse in a building's "
                     + "light. Traffic, transit and fire keep moving — those are the city "
                     + "telling you something, not atmosphere.")
                    .font(.system(size: 11))
                    .foregroundStyle(RetroUITheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// **Read off `KeyboardControls`, not retyped.** A printed list of keys
    /// that is maintained by hand is a second copy of the mapping, and this
    /// project pays for those — it is the same reason the toolbar renders
    /// `ToolCategory.entries` rather than a hand-written row.
    private var keyboard: some View {
        RetroPanel(title: "Keyboard") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(KeyboardControls.reference, id: \.keys) { binding in
                    HStack(alignment: .firstTextBaseline) {
                        Text(binding.keys)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(RetroUITheme.primaryAccent)
                        Spacer()
                        Text(binding.does)
                            .font(.system(size: 11))
                            .foregroundStyle(RetroUITheme.textSecondary)
                    }
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Done", action: dismiss)
                .buttonStyle(RetroButtonStyle(accent: RetroUITheme.primaryAccent))
        }
    }
}
