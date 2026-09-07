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
    /// has to be able to walk to it. Deliberately left short enough that a
    /// stop can never out-value a zone's own road frontage (see
    /// `serviceFalloffDistance`'s doc comment for the arithmetic reason
    /// that matters) — `.publicTransit` is meant to work purely as a
    /// second *access* method alongside `.road` (`CitySimulator.hasAccess`),
    /// not as a competing land-value booster.
    static let transitFalloffDistance = 6

    /// A subway stop's reach, wider than a bus-stop-equivalent
    /// `.publicTransit`'s — the whole reason to pay `.subway`'s higher
    /// price and ongoing upkeep is that it serves a bigger area, the same
    /// "pricier, higher-capacity version" relationship `.highway` has with
    /// `.road`. Tuned to clear the same "must beat bare road frontage"
    /// bar `serviceFalloffDistance` documents, with room to stay the wider
    /// of the two.
    static let subwayFalloffDistance = 14

    /// Coverage from a service building (police/fire) falls off over a
    /// wider radius than road frontage — a station serves a neighborhood,
    /// not just its own tile's edges.
    ///
    /// Playtesting (a synthetic but realistic fully-built, fully-serviced
    /// city, run through `CitySimulator`/`CityHazards`/`Traffic`/`Water`
    /// for 200 ticks) turned up a real problem with the original value of
    /// 8: a station across a *single road* from a zone — the ordinary way
    /// two buildings relate in a road-grid city — sat at exactly distance
    /// 2 from that zone's nearest cell, and `1 - 2/8 == 1 - 1/4`, the exact
    /// same fraction `roadFalloffDistance` (4) gives a zone touching that
    /// same road directly. A station one road-width away therefore never
    /// out-valued the road itself — `value(at:in:)`'s `max()` just kept
    /// the road's own number — so a zone with bare road access, one
    /// nearby service, `and` nothing else could climb to density 4
    /// (`CitySimulator.requiredLandValue`'s 0.65) but never to 5 (0.8): the
    /// "something more" the level-4 doc comment promises turned out to
    /// need a station touching the zone directly, on a side with *no* road
    /// between them, which isn't a placement any normal, road-fronting
    /// city plan produces. Raised to 12 so a station one ordinary road
    /// -width away (distance 2) clears 0.8 outright (`1 - 2/12 ≈ 0.83`),
    /// making the level-5 ceiling reachable by placing a station near the
    /// neighborhood you want maxed out, not by a placement trick. This
    /// also widens `CityHazards`' fire/crime coverage radius by the same
    /// amount, since `CityHazards.apply` reads coverage through this same
    /// falloff — an intentional side effect, not a separate tuning pass:
    /// a station that projects real land value further out should
    /// plausibly protect further out too.
    static let serviceFalloffDistance = 12

    /// A stadium's draw reaches further still — it's a destination people
    /// travel to, not a neighborhood amenity like a station. Kept the
    /// widest of the three service-tier falloffs after the
    /// `serviceFalloffDistance` retuning, for the same "clears 0.8 one
    /// road-width away" reason.
    static let stadiumFalloffDistance = 16

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
    /// to land value, at `Traffic.congestion == 1`: a 25% haircut. Only the
    /// road term is dampened — a station's protection doesn't get worse
    /// because traffic is bad nearby, but frontage on a gridlocked street
    /// is worse frontage than the same street free-flowing.
    ///
    /// Tuned down from an initial 0.4 after playtesting exposed a
    /// self-defeating feedback loop: bare road frontage alone sits at land
    /// value 0.75 (`roadFalloffDistance`), just 0.10 above the 0.65 a zone
    /// needs to reach density level 4 (`CitySimulator.requiredLandValue`).
    /// At 0.4, *any* nearby development pushing congestion past ~30% — which
    /// ordinary growth reaches easily, since the zone's own neighbors share
    /// its road — erased that entire margin, so an ordinary zone with
    /// nothing wrong with it would grow into stalling itself at level 3 the
    /// moment its surroundings got busy. At 0.25, moderate congestion (up to
    /// ~50%) still leaves comfortable room to clear level 4; only a road at
    /// or near true gridlock caps growth below that — a real consequence,
    /// but one that takes actual gridlock to trigger rather than any normal
    /// amount of neighboring traffic.
    static let congestionPenalty = 0.25

    /// `map` is a full `CityMap`, not just a list of positions to measure
    /// against, because that's what every other `Simulation/` function
    /// operating on map data takes (`CitySimulator.hasAccess`,
    /// `CityMap.contains`) — consistent signatures made this a non-decision
    /// rather than a choice.
    static func value(at position: GridPosition, in map: CityMap) -> Double {
        let road = roadValue(at: position, in: map)
        let transit = falloffValue(nearestZone: .publicTransit, falloffDistance: transitFalloffDistance, at: position, in: map)
        let subway = falloffValue(nearestZone: .subway, falloffDistance: subwayFalloffDistance, at: position, in: map)
        let police = falloffValue(nearestZone: .policeStation, falloffDistance: serviceFalloffDistance, at: position, in: map)
        let fire = falloffValue(nearestZone: .fireStation, falloffDistance: serviceFalloffDistance, at: position, in: map)
        let stadium = falloffValue(nearestZone: .stadium, falloffDistance: stadiumFalloffDistance, at: position, in: map)
        let positives = max(road, transit, subway, police, fire, stadium)

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
    ///
    /// `.highway` counts equally alongside `.road` throughout — whichever
    /// one is actually closer wins the base value (via the `max` of both
    /// `falloffValue` calls, same falloff distance for both), and either
    /// one adjacent contributes to the congestion check. A highway isn't a
    /// *different* kind of frontage, just a higher-capacity `.road`.
    private static func roadValue(at position: GridPosition, in map: CityMap) -> Double {
        let base = max(
            falloffValue(nearestZone: .road, falloffDistance: roadFalloffDistance, at: position, in: map),
            falloffValue(nearestZone: .highway, falloffDistance: roadFalloffDistance, at: position, in: map)
        )
        let worstAdjacentCongestion = position.orthogonalNeighbors()
            .filter { map.contains($0) && (map[$0].zone == .road || map[$0].zone == .highway) }
            .map { Traffic.congestion(at: $0, in: map) }
            .max() ?? 0
        return base * (1 - congestionPenalty * worstAdjacentCongestion)
    }

    /// How much one specific zone type (e.g. `.fireStation`) values this
    /// tile, on its own — not folded into `.max` with everything else. Not
    /// `private`: `CityHazards` needs exactly this ("is *fire* coverage
    /// specifically low here?"), not the combined score `value(at:in:)`
    /// gives, where a nearby road could mask a complete lack of fire cover.
    ///
    /// Scaled by `map.serviceFunding.level(for: zone)` — this is the one
    /// place underfunding a service actually does anything. A Police
    /// Station funded at 50% projects half its usual land value *and*
    /// (since `CityHazards.apply` reads coverage through this same
    /// function) covers crime at half strength: one hook, both effects,
    /// rather than two separate "funding matters here too" call sites to
    /// keep in sync. `zone`s that aren't fundable report a funding level of
    /// 1.0 (see `ServiceFunding.level(for:)`), so this is a no-op for
    /// roads and every other non-service falloff.
    static func falloffValue(nearestZone zone: ZoneType, falloffDistance: Int, at position: GridPosition, in map: CityMap) -> Double {
        guard let distance = distanceToNearest(zone, from: position, in: map) else { return 0 }
        let base = max(0, 1 - Double(distance) / Double(falloffDistance))
        return base * map.serviceFunding.level(for: zone)
    }

    private static func distanceToNearest(_ zone: ZoneType, from position: GridPosition, in map: CityMap) -> Int? {
        map.tiles
            .filter { $0.zone == zone }
            .map { position.manhattanDistance(to: $0.position) }
            .min()
    }
}
