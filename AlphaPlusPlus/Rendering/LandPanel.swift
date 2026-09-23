import SwiftUI

/// **What the next parcel costs, and whether the city may buy it.**
///
/// The Land view paints *where* land is for sale; this says the two things a
/// map cannot — the price, and the rank limit. A player clicking an orange
/// parcel and getting a red flash with no reason on screen would be the dead
/// click this project keeps writing down, so the refusal the cursor draws is
/// also named here in words.
///
/// Floats over the map's top-left like the route editor, and only while the
/// Land view is up, which is also the only time clicking the map buys land —
/// so the panel and the mode it describes appear and disappear together.
struct LandPanel: View {
    let land: LandOwnership
    let rank: Milestone?
    let treasury: Int

    private let accent = Color(red: 1.0, green: 0.62, blue: 0.16)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RetroSectionLabel(text: "Land", accent: accent)
            Text("You own \(land.owned.count) of \(land.parcelsAcross * land.parcelsDown) parcels")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(RetroUITheme.textPrimary)
            if land.isComplete {
                line("The whole region is yours.")
            } else {
                line("Next parcel: $\(land.nextPrice)"
                     + (treasury < land.nextPrice ? " — you have $\(treasury)" : ""),
                     alert: treasury < land.nextPrice)
                allowance
                line("Click an orange parcel to buy it. Land has to touch land you own.")
            }
        }
        .padding(RetroMetrics.panelPadding + 2)
        .frame(width: 260, alignment: .leading)
        .background(
            ChamferedRectangle()
                .fill(RetroUITheme.background.opacity(0.93))
                .shadow(color: .black.opacity(0.6), radius: 10)
        )
        .overlay(ChamferedRectangle().stroke(accent.opacity(0.45), lineWidth: 1))
    }

    @ViewBuilder private var allowance: some View {
        let limit = LandOwnership.allowance(for: rank)
        if limit == Int.max {
            line("Your rank lets you buy any of it.")
        } else if land.owned.count >= limit {
            // Names the rank that opens more, because "you can't" with no
            // "until" is a wall, and the whole point of the ladder is that it
            // is not one.
            let next = Milestone.allCases.first { candidate in
                (rank.map { candidate > $0 } ?? true)
                    && LandOwnership.allowance(for: candidate) > land.owned.count
            }
            line("Reach \(next.map(MilestoneText.name) ?? "the next rank") to buy more.", alert: true)
        } else {
            let left = limit - land.owned.count
            line("As a \(MilestoneText.title(for: rank)) you may buy \(left) more.")
        }
    }

    private func line(_ text: String, alert: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(alert ? accent : RetroUITheme.textPrimary.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
    }
}
