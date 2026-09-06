import Foundation

/// How loaded a road tile is, as a number from 0 (empty) to 1 (at capacity).
/// A first, deliberately simple model: load comes from the density of
/// whatever's immediately touching the road, with no notion yet of *where*
/// that traffic is headed or routing along the network to get there — this
/// answers "is this specific intersection busy?" not "how does traffic flow
/// through the city?". It's visualized (`RenderPalette.trafficColor(for:)`,
/// the "Show Traffic" overlay) before it changes any other mechanic, same
/// order `LandValue` was introduced in: see it first, decide what it should
/// affect once it's something you can actually look at.
enum Traffic {

    /// Four orthogonal neighbors, each capable of holding up to the highest
    /// `ZoneType.maxDensity` (5) — the theoretical ceiling `congestion(at:in:)`
    /// normalizes against for a plain `.road` tile.
    private static let maxPossibleLoad = 4.0 * 5.0

    /// A `.highway` tile's whole reason to cost 4x a plain road: it
    /// absorbs twice the neighboring development before feeling as
    /// congested. Same shape of ceiling as `maxPossibleLoad`, just a
    /// bigger one — not a different formula, so a highway isn't "immune"
    /// to traffic, just harder to actually jam.
    private static let highwayMaxPossibleLoad = maxPossibleLoad * 2

    /// Is this a tile that carries road traffic — a plain `.road` or the
    /// higher-capacity `.highway`? Shared by `congestion(at:in:)` (deciding
    /// whether a tile has congestion at all) and `isHorizontallyOriented(at:in:)`
    /// (deciding what counts as a "road neighbor" for orienting the ambient
    /// traffic animation) — one definition of "road-like," not two that
    /// could drift apart.
    private static func isRoadLike(_ zone: ZoneType) -> Bool {
        zone == .road || zone == .highway
    }

    /// How much of its capacity this tile's neighboring development is
    /// using, 0 (empty) to 1 (at capacity). Non-road-like tiles (including
    /// tiles off the map) have no congestion by definition — congestion
    /// describes road capacity, not general busy-ness of a place. A
    /// `.subway`/`.publicTransit` stop is deliberately excluded here too:
    /// it moves people without adding to what a road has to carry, which
    /// is the whole point of it as an alternative to one.
    static func congestion(at position: GridPosition, in map: CityMap) -> Double {
        guard map.contains(position) else { return 0 }
        let zone = map[position].zone
        guard isRoadLike(zone) else { return 0 }
        let capacity = zone == .highway ? highwayMaxPossibleLoad : maxPossibleLoad
        let neighborDensitySum = position.orthogonalNeighbors()
            .filter { map.contains($0) }
            .reduce(0) { $0 + map[$1].density }
        return min(1, Double(neighborDensitySum) / capacity)
    }

    /// How many ambient "cars" `GameScene` should animate driving along a
    /// road tile at this congestion level — 0 for an empty road, rising to
    /// 3 for a jammed one. Pure presentation math (no SpriteKit needed),
    /// but the actual thresholds are graybox first guesses same as
    /// everywhere else in this file — kept here rather than in `Rendering/`
    /// because it's zone-agnostic data derived straight from `congestion`,
    /// not a rendering decision like *what a car looks like*.
    static func carCount(forCongestion congestion: Double) -> Int {
        guard congestion > 0 else { return 0 }
        if congestion < 0.34 { return 1 }
        if congestion < 0.67 { return 2 }
        return 3
    }

    /// Does this road tile connect to another road *horizontally* (left or
    /// right) at least as much as *vertically* (up or down)? `GameScene`
    /// uses this to orient the ambient traffic animation along the road's
    /// actual direction — a car should drive along the street it's on, not
    /// across one it doesn't run along. Ties (an isolated road stub with no
    /// neighbors, or a 4-way intersection with both) default to
    /// horizontal — an arbitrary but simple choice, since there's no
    /// "more correct" direction to prefer at an intersection without real
    /// traffic routing.
    static func isHorizontallyOriented(at position: GridPosition, in map: CityMap) -> Bool {
        func roadNeighborCount(_ positions: [GridPosition]) -> Int {
            positions.filter { map.contains($0) && isRoadLike(map[$0].zone) }.count
        }
        let horizontal = roadNeighborCount([
            GridPosition(x: position.x - 1, y: position.y),
            GridPosition(x: position.x + 1, y: position.y),
        ])
        let vertical = roadNeighborCount([
            GridPosition(x: position.x, y: position.y - 1),
            GridPosition(x: position.x, y: position.y + 1),
        ])
        return horizontal >= vertical
    }
}
