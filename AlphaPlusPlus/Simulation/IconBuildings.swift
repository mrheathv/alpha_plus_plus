import Foundation

/// **The icons: prestige, one of each per city.**
///
/// Every other building in this game does something, and that rule is the
/// reason a reward building is a lever rather than a trophy. The icons are the
/// deliberate exception, and the player's call: a city builder's skyline wants
/// a few buildings that exist only to be looked at, and a supertall that also
/// raised demand would turn "where does my city's centrepiece go" into a
/// balance question.
///
/// What keeps them special is scarcity rather than an effect. **One of each
/// per city**, earned by rank like the reward buildings, and priced as a
/// one-off purchase with no upkeep — a sink for the treasury a grown city
/// banks, since there is nothing about an icon to keep paying for.
///
/// They are drawn in the reference imagery's vocabulary: the Hong Kong
/// supertall with its crown of spikes, a Deco spire standing in front of the
/// sun, a dome, a pair of antenna masts, and a night market under pagoda
/// eaves and stacked vertical signs.
enum IconBuildings {

    static let all: [ZoneType] = [.nightMarket, .chromeDome, .twinMasts, .harbourTower, .sunsetSpire]

    static func isIcon(_ zone: ZoneType) -> Bool { all.contains(zone) }

    /// The rank that earns an icon. Spread over the ladder so every rank past
    /// Hamlet adds something to aim at, with the tallest at the top.
    static func requiredRank(for zone: ZoneType) -> Milestone? {
        switch zone {
        case .nightMarket: return .village
        case .chromeDome: return .town
        case .twinMasts, .harbourTower: return .city
        case .sunsetSpire: return .metropolis
        default: return nil
        }
    }

    /// Has this city already built `zone`? For an icon that is the whole
    /// placement rule; for anything else it is never asked.
    static func isBuilt(_ zone: ZoneType, in map: CityMap) -> Bool {
        map.tiles.contains { $0.isBuildingAnchor && $0.zone == zone }
    }
}
