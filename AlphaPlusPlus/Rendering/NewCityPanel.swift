import SwiftUI

/// **Founding a city, as a decision rather than a menu of dimensions.**
///
/// "New City" was a menu of three map sizes, which was fine while size was
/// the only thing to choose. Terrain makes it a matrix — three sizes times
/// four kinds of land is twelve menu items for two questions — and this
/// project has already watched the tool rail and the overlay row outgrow
/// their containers twice. A row that grows every time a feature lands needs
/// somewhere to grow, not a bigger menu.
///
/// It is also the first thing a player ever sees, and "pick 32×32 / 48×48 /
/// 64×64" is a poor opening line for a game about building somewhere. A
/// panel can say what a coastline *is*.
struct NewCityPanel: View {
    @ObservedObject var controller: GameController
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RetroSectionLabel(text: "Found a city", accent: RetroUITheme.primaryAccent)
            // `RetroPanel` sizes to its content, so left alone the three
            // stack up at three different widths — which the render showed
            // at once and which reads as three unrelated boxes rather than
            // one form.
            land.frame(maxWidth: .infinity, alignment: .leading)
            size.frame(maxWidth: .infinity, alignment: .leading)
            seed.frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(18)
        .frame(width: 420)
        .background(RetroUITheme.background)
    }

    // **Split into small properties on purpose.** As one expression this body
    // defeated the type checker outright — "failed to produce diagnostic for
    // expression" — which is SwiftUI's usual way of saying a view is too big
    // to infer in one go. Naming the parts fixes it and reads better anyway.
    private var land: some View {
        RetroPanel(title: "Land") {
                VStack(alignment: .leading, spacing: 8) {
                    RetroSegmentedPicker(
                        options: Terrain.allCases,
                        label: \.displayName,
                        selection: $controller.selectedTerrain
                    )
                    // The one line that turns a word into a decision — a
                    // player choosing "River" should know it will cut the map
                    // in two before they find out by building into it.
                    Text(controller.selectedTerrain.summary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(RetroUITheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

    }

    private var size: some View {
        RetroPanel(title: "Size") {
                RetroSegmentedPicker(
                    options: MapSize.allCases,
                    label: \.displayName,
                    selection: $controller.selectedMapSize
                )
            }

    }

    private var seed: some View {
        RetroPanel(title: "Seed") {
                HStack(spacing: 10) {
                    // Shown, not hidden, so a player who likes a coastline can
                    // write the number down and get it back — the same reason
                    // terrain is generated from a seed rather than from the
                    // simulation's RNG.
                    Text(String(controller.selectedTerrainSeed))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(RetroUITheme.textPrimary)
                    Spacer()
                    Button("Reroll") { controller.rerollTerrainSeed() }
                        .buttonStyle(RetroButtonStyle(accent: RetroUITheme.primaryAccent))
                        .disabled(controller.selectedTerrain == .flat)
                }
            }

    }

    private var actions: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Cancel", action: dismiss)
                    .buttonStyle(RetroButtonStyle(accent: RetroUITheme.textSecondary))
            Button("Found") {
                controller.resetMap()
                dismiss()
            }
            .buttonStyle(RetroButtonStyle(accent: RetroUITheme.primaryAccent))
        }
    }
}
