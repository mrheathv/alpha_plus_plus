import Foundation

/// **What each rank's reward building does.**
///
/// A reward that only looked good would be a trophy, and this game's rule is
/// that everything placed on the map does something. Each of the three does
/// one thing nothing else in the game does as well, and each effect answers a
/// question the rank it arrives at is asking:
///
/// - **Neon Arcade (Town)** makes a neighbourhood desirable, like a park but
///   stronger and further-reaching. Town is where the land-value gate on the
///   upper densities starts to bite across a whole district rather than one
///   block.
/// - **Broadcast Tower (City)** raises commercial demand city-wide, the way
///   the airport does. A City has proven it can plan; this is a lever for
///   steering its whole economy.
/// - **Arcology (Metropolis)** houses a small town inside one 3×3 building,
///   with no commute and no pollution. The classic end-game building, and the
///   answer to a Metropolis that has run out of land.
///
/// The numbers are **first guesses sized by argument**, the way the port
/// upkeeps were: each is set against a constant it sits among (`parkBonus`,
/// `RegionalTrade.boostPerPort`), and none has been measured in a playtest
/// yet.
enum RewardBuildings {

    /// The rank that earns `zone`, or `nil` for everything that is not a
    /// reward. The one place this is written down — `Unlocks` asks it, and so
    /// does the toolbar's locked chip.
    static func requiredRank(for zone: ZoneType) -> Milestone? {
        switch zone {
        case .neonArcade: return .town
        case .broadcastTower: return .city
        case .arcology: return .metropolis
        // The icons are earned the same way, and asking one function keeps
        // the toolbar's locked chip and `Unlocks` from needing a second.
        default: return IconBuildings.requiredRank(for: zone)
        }
    }

    // MARK: - Neon Arcade

    /// What an arcade adds to land value near it.
    ///
    /// Additive, like a park, and for the same reason: it is not competing to
    /// be the best thing near a lot, it makes an already-decent block better.
    /// Larger than `LandValue.parkBonus` (0.18), since it is a rank's reward
    /// against a starter tool, and still short of what alone carries plain
    /// road frontage (0.75) over the top tier's 0.8 *and* the next one — so it
    /// helps a district rather than replacing everything else a district
    /// needs.
    static let arcadeBonus = 0.28

    /// And how far it reaches: nearly twice a park's 4, because a park serves
    /// a street and an arcade draws from a district.
    static let arcadeFalloffDistance = 7

    // MARK: - Broadcast Tower

    /// Commercial demand a working tower adds, city-wide.
    ///
    /// Two-thirds of a first airport's `boostPerPort`, so a tower is a lever
    /// rather than a replacement for trade. **A second tower adds nothing** —
    /// one mast already reaches the whole city — which is what stops a large
    /// treasury holding commercial demand at the ceiling by building more.
    static let broadcastBoost = 0.22

    static func commercialBoost(in map: CityMap) -> Double {
        guard map.tiles.contains(where: { $0.isBuildingAnchor && $0.zone == .broadcastTower })
        else { return 0 }
        return broadcastBoost * min(1, map.serviceFunding.level(for: .broadcastTower))
    }

    // MARK: - Arcology

    /// Residents one arcology houses: a 3×3 building holding what about
    /// thirty lots of tier-4 housing would, which is the point of it.
    ///
    /// **Self-contained, deliberately.** They live, work and shop inside, so
    /// they are counted as population — taxed, and counted toward the ladder
    /// — but not in `Demand`, not on the roads and not as a load on the water
    /// network. An arcology that sent five hundred commuters into a
    /// Metropolis's streets would be a traffic problem wearing a reward's
    /// clothes.
    static let arcologyResidents = 500

    static func residents(in map: CityMap) -> Int {
        map.tiles.filter { $0.isBuildingAnchor && $0.zone == .arcology }.count * arcologyResidents
    }
}
