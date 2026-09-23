import Foundation

/// Every word the milestones ladder says, for the reason `InspectorText` and
/// `GuideText` exist: the rules live in `Simulation/`, and the names a player
/// reads are presentation.
enum MilestoneText {

    static func name(_ rank: Milestone) -> String {
        switch rank {
        case .hamlet: return "Hamlet"
        case .village: return "Village"
        case .town: return "Town"
        case .city: return "City"
        case .metropolis: return "Metropolis"
        }
    }

    /// What the city is called before its first rank.
    ///
    /// Not "Unranked", which reads as a score nobody has given you yet. A
    /// place with a few streets and no hundred residents is a settlement.
    static let unranked = "Settlement"

    static func title(for rank: Milestone?) -> String {
        rank.map(name) ?? unranked
    }

    /// A requirement's label, short enough to sit in a two-column grid in the
    /// dashboard. Names the thing a player acts on — "Water", "Clean air" —
    /// rather than the measurement behind it.
    static func label(_ requirement: Milestone.Requirement) -> String {
        switch requirement {
        case .residents: return "Residents"
        case .waterServed: return "Water"
        case .powerServed: return "Power"
        case .schooled: return "Schools"
        case .homePollutionAtMost: return "Clean air"
        case .congestionAtMost: return "Traffic"
        case .rubbleAtMost: return "Rubble"
        case .solvent: return "Budget"
        }
    }

    /// Where the city stands against the bar, as "have / want".
    ///
    /// Water, power and schools read as *coverage*, so they are percentages of
    /// the blocks that want them. Pollution and congestion are 0…1 fields the
    /// player never sees as numbers anywhere else, so they are percentages too
    /// rather than three-decimal readouts — "Traffic 19% / 10%" is something a
    /// player can steer by; "0.187 / 0.100" is a debug view.
    static func status(_ requirement: Milestone.Requirement, card: CityScorecard, netRevenue: Int) -> String {
        func pct(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
        switch requirement {
        case .residents(let n): return "\(card.population) / \(n)"
        case .waterServed(let f): return "\(pct(card.waterServed)) / \(pct(f))"
        case .powerServed(let f): return "\(pct(card.powerServed)) / \(pct(f))"
        case .schooled(let f): return "\(pct(card.schooled)) / \(pct(f))"
        case .homePollutionAtMost(let f): return "\(pct(card.homePollution)) / ≤\(pct(f))"
        case .congestionAtMost(let f): return "\(pct(card.congestion)) / ≤\(pct(f))"
        case .rubbleAtMost(let f): return "\(pct(card.rubble)) / ≤\(pct(f))"
        case .solvent: return netRevenue >= 0 ? "in the black" : "losing money"
        }
    }

    /// The announcement, naming the reward when the rank carries one — the
    /// moment a player earns a building is the moment to tell them it exists.
    static func earned(_ rank: Milestone) -> String {
        let reward = ZoneType.allCases.first { RewardBuildings.requiredRank(for: $0) == rank }
        return "Now a \(name(rank))" + (reward.map { " · \(RenderPalette.displayName(for: $0)) unlocked" } ?? "")
    }

    static let topOfTheLadder = "Every rank earned"
}
