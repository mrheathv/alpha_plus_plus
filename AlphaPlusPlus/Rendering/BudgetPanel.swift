import SwiftUI

/// The city's budget, as a sheet rather than a toolbar row.
///
/// **Why it moved.** `GameView`'s toolbar had grown to five rows — fifteen
/// zoning tools, simulation controls, overlay and map-size pickers, a tax
/// stepper plus seven funding steppers plus the bond controls, and three
/// ordinance toggles — and its own doc comments had already flagged the
/// overflow risk twice before it actually ran out of room. Playing the game
/// was what settled it.
///
/// A panel is also simply the right shape for this content. Tax rate and
/// funding are things you set occasionally and then leave alone, which is
/// what a settings sheet is for; they were competing for width with the
/// zoning tools you click constantly. Ordinances and bonds live in the City
/// menu, since a toggle and an action translate to menu items cleanly while
/// seven steppers do not.
struct BudgetPanel: View {
    @ObservedObject var controller: GameController
    let dismiss: () -> Void

    /// Every zone with its own funding dial, in the order they appear in the
    /// zoning toolbar so the two read the same way round.
    private static let fundableZones: [ZoneType] = [
        .policeStation, .fireStation, .publicTransit, .subway, .powerPlant, .waterTower, .stadium,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("City Budget")
                .font(.title2.bold())
                .foregroundStyle(RetroUITheme.textPrimary)

            taxSection
            Divider().overlay(RetroUITheme.textSecondary.opacity(0.3))
            fundingSection
            Divider().overlay(RetroUITheme.textSecondary.opacity(0.3))
            summarySection

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(RetroButtonStyle(accent: RetroUITheme.primaryAccent, isSelected: true))
            }
        }
        .padding(24)
        .frame(minWidth: 520)
        .background(RetroUITheme.background)
        .preferredColorScheme(.dark)
    }

    private var taxSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Tax Rate").foregroundStyle(RetroUITheme.textSecondary)
                // 0% is a real setting — a tax holiday — same reasoning as
                // funding's floor below.
                RetroStepper(value: $controller.taxRate, range: 0 ... 2.0, step: 0.25)
            }
            Text("Higher rates earn more per resident but make the city a less "
                 + "attractive place to build — watch the RCI meter sag.")
                .font(.caption)
                .foregroundStyle(RetroUITheme.textSecondary)
        }
    }

    private var fundingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Service Funding").foregroundStyle(RetroUITheme.textSecondary)
            // Two columns: seven steppers in one row is what made this not fit
            // in the toolbar in the first place.
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                ForEach(Self.fundableZones, id: \.self) { zone in
                    HStack(spacing: 6) {
                        Text(RenderPalette.displayName(for: zone))
                            .foregroundStyle(RetroUITheme.textSecondary)
                            .frame(width: 120, alignment: .leading)
                            .lineLimit(1)
                        RetroStepper(
                            value: Binding(
                                get: { controller.fundingLevel(for: zone) },
                                set: { controller.setFundingLevel($0, for: zone) }
                            ),
                            range: 0 ... 2.0,
                            step: 0.25,
                            accent: RetroUITheme.accent(for: zone)
                        )
                    }
                }
            }
            Text("Funding buys both coverage and capacity: a half-funded water "
                 + "budget halves what your towers can carry.")
                .font(.caption)
                .foregroundStyle(RetroUITheme.textSecondary)
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            line("Tax revenue", "+\(controller.taxRevenue)")
            line("Infrastructure", "-\(controller.upkeepCost)")
            line("Civic services", "-\(controller.civicUpkeep)")
            line("Bond interest", "-\(controller.bondInterest)")
            line("Ordinances", "-\(controller.map.ordinances.totalUpkeepCost(population: controller.population))")
            Divider().overlay(RetroUITheme.textSecondary.opacity(0.3))
            line("Net per tick", "\(controller.netRevenue >= 0 ? "+" : "")\(controller.netRevenue)",
                 emphasised: true)
        }
        .font(.callout)
    }

    private func line(_ label: String, _ value: String, emphasised: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(RetroUITheme.textSecondary)
            Spacer()
            Text(value)
                .foregroundStyle(emphasised
                                 ? (controller.netRevenue >= 0 ? Color.green : Color.red)
                                 : RetroUITheme.textPrimary)
                .monospacedDigit()
        }
    }
}
