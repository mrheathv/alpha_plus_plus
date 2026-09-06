import Foundation

/// How desirable a tile is, as a number from 0 (worthless) to 1 (maximum).
/// Combines every service that currently exists — roads, transit stops,
/// police coverage, fire coverage — by taking whichever one values the tile
/// most highly. `max` rather than summing: standing near multiple services
/// should never push a tile's value past what its single best amenity
/// already gives it, which keeps the number meaningful (a tile blanketed in
/// overlapping coverage doesn't quietly become indistinguishable from one
/// with just a single well-placed road) and keeps this formula simple to
/// extend — a new service is one more term in the `max`, not a rebalancing
/// of how terms combine.
///
/// A derived value, computed fresh from the current map rather than stored
/// on `Tile`: it's fully determined by where the roads/stations currently
/// are, so storing it would mean recomputing and writing it to every tile on
/// every change to the map anyway — no cheaper than computing it on demand,
/// and one more piece of state that could quietly drift out of sync with
/// reality (the Reset-not-refreshing bug earlier this project was exactly
/// that kind of mistake, just for rendering instead of data).
enum LandValue {

    /// Land value from road frontage falls linearly from 1 at the road
    /// itself to 0 at this many tiles away. Deliberately larger than the
    /// 1-tile radius `CitySimulator` requires for actual growth, so the
    /// land-value overlay reads as a smooth gradient rather than looking
    /// identical to the road-adjacency map.
    static let roadFalloffDistance = 4

    /// A transit stop's reach sits between road frontage and a full service
    /// building: it serves more than its own doorstep, but a rider still
    /// has to be able to walk to it.
    static let transitFalloffDistance = 6

    /// Coverage from a service building (police/fire) falls off over a
    /// wider radius than road frontage — a station serves a neighborhood,
    /// not just its own tile's edges.
    static let serviceFalloffDistance = 8

    /// A stadium's draw reaches further still — it's a destination people
    /// travel to, not a neighborhood amenity like a station.
    static let stadiumFalloffDistance = 10

    /// How far a power plant's *negative* pull on land value reaches.
    /// Every other service in this file only ever raises value; a power
    /// plant is the first to lower it — nobody wants to live next to one,
    /// same falloff shape as everything else, just subtracted instead of
    /// competing in the `max`.
    static let powerPlantPenaltyDistance = 8

    /// How much land value a power plant subtracts at distance 0 (standing
    /// right next to it): a real hit, but not enough to always cancel out a
    /// strong nearby road or station — it's an eyesore, not automatically a
    /// dealbreaker. A first guess, same as every other number in this file.
    static let powerPlantPenaltyStrength = 0.5

    /// How much a jammed adjacent road cuts into that road's contribution
    /// to land value, at `Traffic.congestion == 1`: a 40% haircut. Only the
    /// road term is dampened — a station's protection doesn't get worse
    /// because traffic is bad nearby, but frontage on a gridlocked street
    /// is worse frontage than the same street free-flowing.
    static let congestionPenalty = 0.4

    /// `map` is a full `CityMap`, not just a list of positions to measure
    /// against, because that's what every other `Simulation/` function
    /// operating on map data takes (`CitySimulator.hasAccess`,
    /// `CityMap.contains`) — consistent signatures made this a non-decision
    /// rather than a choice.
    static func value(at position: GridPosition, in map: CityMap) -> Double {
        let road = roadValue(at: position, in: map)
        let transit = falloffValue(nearestZone: .publicTransit, falloffDistance: transitFalloffDistance, at: position, in: map)
        let police = falloffValue(nearestZone: .policeStation, falloffDistance: serviceFalloffDistance, at: position, in: map)
        let fire = falloffValue(nearestZone: .fireStation, falloffDistance: serviceFalloffDistance, at: position, in: map)
        let stadium = falloffValue(nearestZone: .stadium, falloffDistance: stadiumFalloffDistance, at: position, in: map)
        let positives = max(road, transit, police, fire, stadium)

        // The power plant penalty is subtracted from the combined positive
        // score, not folded into the same `max` — it's not competing to be
        // the best amenity, it's dragging down whatever score the tile
        // already has. Floored at 0 rather than allowed to go negative:
        // "worthless" is as bad as this model represents, not "worse than
        // worthless."
        let powerPlantPenalty = falloffValue(nearestZone: .powerPlant, falloffDistance: powerPlantPenaltyDistance, at: position, in: map) * powerPlantPenaltyStrength
        return max(0, positives - powerPlantPenalty)
    }

    /// Road frontage value, dampened by whichever adjacent road is most
    /// congested. Deliberately checks only the *orthogonal* neighbors, not
    /// "the nearest road" `falloffValue` would use — that's the same
    /// adjacency `CitySimulator.hasAccess` requires for actual road access,
    /// so this asks "how good is the specific road frontage this tile
    /// relies on," not some other road four tiles away.
    ///
    /// This is a real feedback loop, not just a cosmetic penalty: a tile's
    /// own growth adds to its road's congestion, which can dampen that same
    /// tile's land value enough to stall further growth — "you built too
    /// much around one road" becomes a real, felt consequence instead of
    /// something only `Traffic`'s overlay shows.
    private static func roadValue(at position: GridPosition, in map: CityMap) -> Double {
        let base = falloffValue(nearestZone: .road, falloffDistance: roadFalloffDistance, at: position, in: map)
        let worstAdjacentCongestion = position.orthogonalNeighbors()
            .filter { map.contains($0) && map[$0].zone == .road }
            .map { Traffic.congestion(at: $0, in: map) }
            .max() ?? 0
        return base * (1 - congestionPenalty * worstAdjacentCongestion)
    }

    /// How much one specific zone type (e.g. `.fireStation`) values this
    /// tile, on its own — not folded into `.max` with everything else. Not
    /// `private`: `CityHazards` needs exactly this ("is *fire* coverage
    /// specifically low here?"), not the combined score `value(at:in:)`
    /// gives, where a nearby road could mask a complete lack of fire cover.
    static func falloffValue(nearestZone zone: ZoneType, falloffDistance: Int, at position: GridPosition, in map: CityMap) -> Double {
        guard let distance = distanceToNearest(zone, from: position, in: map) else { return 0 }
        return max(0, 1 - Double(distance) / Double(falloffDistance))
    }

    private static func distanceToNearest(_ zone: ZoneType, from position: GridPosition, in map: CityMap) -> Int? {
        map.tiles
            .filter { $0.zone == zone }
            .map { position.manhattanDistance(to: $0.position) }
            .min()
    }
}
