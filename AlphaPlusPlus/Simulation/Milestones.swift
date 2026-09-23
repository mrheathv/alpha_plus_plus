import Foundation

/// **Named ranks a city earns, each asking for more than a headcount.**
///
/// This project's standing findings included *no goals*: nothing to aim at
/// once the city runs itself. `Unlocks` is a progression, but a progression of
/// tools gated on population alone — and population alone is the one number
/// every strategy produces some of, the bad ones included. A city that never
/// laid a pipe reaches 1,500 residents on a big map, and nothing it earned
/// says it was badly run.
///
/// Each rank here adds one new *skill* to the headcount, and the skills climb
/// the way the game's own systems do:
///
/// | rank | asks for | the skill |
/// |---|---|---|
/// | Hamlet | 100 residents | zoning a street |
/// | Village | 400, water to the blocks that want it | utilities |
/// | Town | 900, water & power, schools within reach | serving a city |
/// | City | 2,000, clean air over the homes, not losing money | planning, budgeting |
/// | Metropolis | 3,500, free-flowing roads, little rubble | transit, safety |
///
/// **Every threshold was measured, not picked.** `MilestoneCalibrationTests`
/// runs the design playtest's strategies on three map sizes, and each bar sits
/// between a strategy that clears it and one that does not. Town at 900 is
/// reachable on the smallest map by a planned city (960) and not by the
/// default layout (784); City's pollution bar is cleared by industry zoned
/// apart (0.05) and not by a mixed city (0.35); Metropolis's congestion bar is
/// cleared by a subway city (0.04) and not by the best car-only one (0.19).
/// `MilestoneTests` pins those pairs, so a balance change that moves one of
/// them has to be noticed.
///
/// **A high-water mark, like unlocks.** A city knocked back by a fire keeps
/// the rank it earned. And ranks are earned *in order*: a city has to be a
/// Town before it can be a City, so every rank means every skill below it.
///
/// **All conditions at once.** A rank is earned on a day the city meets every
/// one of its requirements together — which is what makes the ladder a
/// management goal rather than a checklist you can tick off one item at a
/// time while the rest falls apart.
enum Milestone: Int, CaseIterable, Codable, Comparable {
    case hamlet = 1
    case village
    case town
    case city
    case metropolis

    static func < (lhs: Milestone, rhs: Milestone) -> Bool { lhs.rawValue < rhs.rawValue }

    var requirements: [Requirement] {
        switch self {
        case .hamlet:
            return [.residents(100)]
        case .village:
            return [.residents(400), .waterServed(0.9)]
        case .town:
            return [.residents(900), .waterServed(0.9), .powerServed(0.9), .schooled(0.5)]
        case .city:
            return [.residents(2_000), .waterServed(0.9), .powerServed(0.9),
                    .homePollutionAtMost(0.15), .solvent]
        case .metropolis:
            return [.residents(3_500), .homePollutionAtMost(0.15),
                    .congestionAtMost(0.10), .rubbleAtMost(0.05)]
        }
    }

    /// The rank after this one, or `nil` at the top.
    var next: Milestone? { Milestone(rawValue: rawValue + 1) }

    /// The rank a city with `earned` is working toward.
    static func next(after earned: Milestone?) -> Milestone? {
        earned.map(\.next) ?? .hamlet
    }

    /// Every rank `card` newly qualifies for, climbing from `earned`.
    ///
    /// Can return more than one: a loaded city, or a city whose water just
    /// came on, may clear two rungs at once. It stops at the first rank not
    /// met rather than skipping ahead, which is what "earned in order" means.
    static func newlyEarned(after earned: Milestone?, card: CityScorecard,
                            netRevenue: Int) -> [Milestone] {
        var result: [Milestone] = []
        var candidate = next(after: earned)
        while let rank = candidate,
              rank.requirements.allSatisfy({ $0.isMet(by: card, netRevenue: netRevenue) }) {
            result.append(rank)
            candidate = rank.next
        }
        return result
    }

    /// One condition on one rank.
    ///
    /// Fractions are 0…1, as `CityScorecard` measures them. The two "at most"
    /// cases are the ones where lower is better; keeping that in the case name
    /// rather than in a sign convention is what stops a threshold being
    /// written the wrong way round.
    enum Requirement: Equatable {
        case residents(Int)
        case waterServed(Double)
        case powerServed(Double)
        case schooled(Double)
        case homePollutionAtMost(Double)
        case congestionAtMost(Double)
        case rubbleAtMost(Double)
        /// Net revenue at or above zero. The only one that reads money: a rank
        /// for a city that is quietly going bankrupt would reward exactly the
        /// strategy — dense services everywhere — that the budget exists to
        /// punish.
        case solvent

        func isMet(by card: CityScorecard, netRevenue: Int) -> Bool {
            switch self {
            case .residents(let n): return card.population >= n
            case .waterServed(let f): return card.waterServed >= f
            case .powerServed(let f): return card.powerServed >= f
            case .schooled(let f): return card.schooled >= f
            case .homePollutionAtMost(let f): return card.homePollution <= f
            case .congestionAtMost(let f): return card.congestion <= f
            case .rubbleAtMost(let f): return card.rubble <= f
            case .solvent: return netRevenue >= 0
            }
        }
    }
}
