import SwiftUI

/// City Hall: everything about money, in one sheet.
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
/// zoning tools you click constantly.
///
/// **Ordinances and bonds moved in here too, and it took a while to notice
/// why they had to.** They lived only in the City menu, on the reasoning that
/// a toggle and an action translate to menu items cleanly. They do — but a
/// menu shows a *control*, not a *state*, and both of these are mostly state:
/// an ordinance's upkeep scales with population, so its cost is a number that
/// changes under you, and a bond is a debt with a cap and an interest charge
/// that nothing on screen mentioned at all. A player could be paying interest
/// every tick with no way to see the balance short of opening a menu that
/// does not show it either.
struct CityPanel: View {
    @ObservedObject var controller: GameController
    let dismiss: () -> Void

    /// The ordinances, with their player-facing names.
    ///
    /// The names live here rather than on `Ordinances` for the same reason
    /// `RenderPalette.displayName(for:)` does not live on `ZoneType`: what a
    /// thing is called is a statement about presentation, and the simulation
    /// has no opinion about it.
    private static let ordinances: [(name: String, keyPath: WritableKeyPath<Ordinances, Bool>)] = [
        ("Neighborhood Watch", \.neighborhoodWatch),
        ("Fire Inspections", \.fireInspections),
        ("Business Tax Break", \.businessTaxBreak),
    ]

    /// Every zone with its own funding dial, in the order they appear in the
    /// zoning toolbar so the two read the same way round.
    ///
    /// **`.school` and `.hospital` were missing**, and had been since they
    /// were added — both carry a real dial that `LandValue` and `CityHazards`
    /// read, both are documented as "heavy enough per building that defunding
    /// one is a real lever", and neither had a row anywhere in the UI. A lever
    /// with no control on it is not a lever.
    ///
    /// `.road` is new with phase 6: the public-works budget that keeps the
    /// network from wearing out. It goes first because it is the one a player
    /// cannot ignore — every other dial buys a service, this one stops what
    /// you already own from falling apart.
    private static let fundableZones: [ZoneType] = [
        .road, .policeStation, .fireStation, .school, .hospital,
        .publicTransit, .subway, .powerPlant, .waterTower, .stadium,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("CITY HALL")
                .font(.title2.bold())
                .tracking(3)
                .foregroundStyle(RetroUITheme.textPrimary)

            // **Two columns, and no `ScrollView`.** Adding ordinances and debt
            // roughly doubled this panel's height, which on a laptop screen is
            // a sheet taller than the display. A scroll view solves that and
            // costs something worth more: `ImageRenderer` cannot measure
            // scrolling content, so the panel stopped appearing in its own
            // contact sheet — and a panel nobody can look at is how the
            // truncated treasury readout survived. Splitting the settings from
            // the money halves the height honestly.
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 18) {
                    taxSection
                    sectionDivider
                    fundingSection
                }
                VStack(alignment: .leading, spacing: 18) {
                    ordinanceSection
                    sectionDivider
                    debtSection
                    sectionDivider
                    summarySection
                }
                .frame(width: 300)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(RetroButtonStyle(accent: RetroUITheme.primaryAccent, isSelected: true))
            }
        }
        .padding(24)
        .frame(minWidth: 860)
        .background(RetroUITheme.background)
        .preferredColorScheme(.dark)
    }

    private var sectionDivider: some View {
        Divider().overlay(RetroUITheme.textSecondary.opacity(0.3))
    }

    /// City-wide policies. Each is binary, but each also costs upkeep that
    /// grows with the city — which is the part a menu checkmark cannot say.
    private var ordinanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            RetroSectionLabel(text: "Ordinances")
            // A chip rather than a `Toggle`. A native switch is the one piece
            // of stock AppKit chrome left in a panel that is otherwise entirely
            // hand-drawn neon, and it does not render in the contact sheet
            // either — so the one control whose *state* is the whole point was
            // also the one control nobody could look at.
            ForEach(Self.ordinances, id: \.name) { ordinance in
                let active = controller.isOrdinanceActive(ordinance.keyPath)
                RetroToolChip(
                    title: ordinance.name,
                    cost: Ordinances.costPerOrdinance(population: controller.population),
                    accent: active ? RetroUITheme.primaryAccent : RetroUITheme.textSecondary,
                    isSelected: active,
                    action: { controller.setOrdinance(ordinance.keyPath, active: !active) }
                )
            }
        }
    }

    /// Borrowing, and what it is costing.
    private var debtSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            RetroSectionLabel(text: "Debt")
            HStack(spacing: 16) {
                RetroStatTile(label: "Outstanding", value: "$\(controller.bondBalance)",
                              detail: "cap $\(controller.maxBondBalance)",
                              accent: controller.bondBalance > 0 ? .orange : RetroUITheme.primaryAccent)
                RetroStatTile(label: "Interest", value: "-$\(controller.bondInterest)",
                              detail: "per day", accent: .red)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button("Issue Bond +$\(GameController.bondIssueAmount)") {
                    _ = controller.issueBond()
                }
                .buttonStyle(RetroButtonStyle(accent: .orange))
                .disabled(controller.bondBalance + GameController.bondIssueAmount > controller.maxBondBalance)

                Button("Repay -$\(GameController.bondIssueAmount)") {
                    controller.repayBond(GameController.bondIssueAmount)
                }
                .buttonStyle(RetroButtonStyle(accent: RetroUITheme.primaryAccent))
                .disabled(controller.bondBalance == 0 || controller.treasury < GameController.bondIssueAmount)
            }
            Text("A bond is cash now against interest every tick, and the cap "
                 + "scales with population — a bigger city can carry more debt.")
                .font(.caption)
                .foregroundStyle(RetroUITheme.textSecondary)
        }
    }

    private var taxSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RetroSectionLabel(text: "Tax Rate")
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
            RetroSectionLabel(text: "Service Funding")
            // Two columns: seven steppers in one row is what made this not fit
            // in the toolbar in the first place.
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                ForEach(Self.fundableZones, id: \.self) { zone in
                    HStack(spacing: 6) {
                        Text(zone == .road ? InspectorText.publicWorks : RenderPalette.displayName(for: zone))
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
            Text(InspectorText.fundingNote)
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
            line("Net per day", "\(controller.netRevenue >= 0 ? "+" : "")\(controller.netRevenue)",
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
