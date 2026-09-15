import Foundation

/// Whether a tile is actually served by the water network — a real pipe
/// network, not a coverage radius: a building needs an unbroken chain of
/// piped tiles (`Tile.hasPipe`) connecting it back to a `.waterTower`, the
/// same way a zone needs an actual road (not just "somewhere nearby") for
/// `CitySimulator.hasAccess`. Modeled after `Traffic.swift`'s shape almost
/// exactly, since it's the same underlying problem: a real network search
/// that's too expensive to redo per single-tile query, so it's computed
/// once (`computeSupply(for:)`) and cached (`CityMap.waterSupply`) rather
/// than threaded as an extra parameter through every caller.
/// How much utility a city consumes, and how much its plants can supply.
///
/// **Why this exists.** Water and power were pure connectivity: one tower and
/// one plant served an infinite city. Growth therefore created no new demands
/// at all, which is the other half of why the game had no pacing — you built
/// the infrastructure once and were done with it forever. Every game in the
/// genre puts a capacity meter on utilities precisely so that a growing city
/// keeps asking for something.
///
/// Demand is the city's total *density* across growable zones, not its
/// building count: a fully-grown tower draws more than a half-empty one, the
/// same way it houses more people and pays more tax. Capacity is what the
/// plants provide, scaled by their funding — so the funding slider now buys
/// throughput rather than only coverage.
struct UtilityLoad: Equatable {
    let demand: Int
    let capacity: Int

    var isOverloaded: Bool { demand > capacity }

    /// How far past capacity the network is, as a fraction of capacity. 0 when
    /// within budget.
    var overloadFraction: Double {
        guard capacity > 0 else { return demand > 0 ? 1 : 0 }
        return max(0, Double(demand - capacity) / Double(capacity))
    }

    /// Total density the city is drawing — the same number for water and for
    /// power, since every developed lot consumes both.
    static func demand(in map: CityMap) -> Int {
        map.totalDensity(of: .residential)
            + map.totalDensity(of: .commercial)
            + map.totalDensity(of: .industrial)
    }

    /// What every plant of `zone` supplies between them, scaled by funding.
    static func capacity(of zone: ZoneType, perBuilding: Int, in map: CityMap) -> Int {
        let plants = map.tiles.filter { $0.isBuildingAnchor && $0.zone == zone }.count
        return Int(Double(plants * perBuilding) * map.serviceFunding.level(for: zone))
    }
}

enum Water {

    /// Every piped tile reachable from *some* funded water tower, and
    /// whether the piped neighbors of a given position are among them —
    /// `hasSupply(at:in:)` is the only thing most callers need.
    ///
    /// Builds the reachable set with a plain flood-fill (unweighted BFS,
    /// no shortest-path bookkeeping): unlike `Traffic`'s routing, this
    /// only ever asks "is this tile connected at all," never "how far,"
    /// so there's nothing to reconstruct a path for.
    /// How many density levels one water tower can serve.
    ///
    /// Sized against a built-out large map, which runs roughly 1,500-2,000
    /// total density: at 200 that is eight to ten towers, enough that a
    /// growing city keeps needing another one without the map turning into
    /// nothing but utilities. Towers are the cheap, small (2×2) half of the
    /// utility pair, so they come in larger numbers than power plants. A first
    /// guess, same status as every other constant here — but one the playtest
    /// harness can now check.
    static let capacityPerTower = 200

    static func load(in map: CityMap) -> UtilityLoad {
        UtilityLoad(
            demand: UtilityLoad.demand(in: map),
            capacity: UtilityLoad.capacity(of: .waterTower, perBuilding: capacityPerTower, in: map)
        )
    }

    static func computeSupply(for map: CityMap) -> WaterSupply {
        // Funding is one city-wide dial per service (`ServiceFunding`'s
        // own design), not per-building — so defunding water takes every
        // tower offline at once, not just some of them.
        guard map.serviceFunding.level(for: .waterTower) > 0 else { return WaterSupply() }

        // Over capacity, the whole network fails rather than some fraction of
        // it. City-wide rather than per-tower for exactly the reason
        // `PowerGrid` already gives for its own outages: it is the simplest
        // version that is still a real, felt consequence, and a deliberate
        // first cut rather than an oversight. The player sees the meter go
        // red, growth stalls, and one more tower fixes it.
        guard !load(in: map).isOverloaded else { return WaterSupply() }

        let pipes = Set(map.tiles.filter { $0.hasPipe }.map(\.position))
        guard !pipes.isEmpty else { return WaterSupply() }

        var frontier: [GridPosition] = []
        for tile in map.tiles where tile.isBuildingAnchor && tile.zone == .waterTower {
            frontier.append(contentsOf: map.footprintCells(origin: tile.position, size: tile.zone.footprintSize)
                .flatMap { $0.orthogonalNeighbors() }
                .filter { pipes.contains($0) })
        }
        guard !frontier.isEmpty else { return WaterSupply() }

        var reachable = Set(frontier)
        var queue = frontier
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            for neighbor in current.orthogonalNeighbors() where pipes.contains(neighbor) && !reachable.contains(neighbor) {
                reachable.insert(neighbor)
                queue.append(neighbor)
            }
        }
        return WaterSupply(reachablePipes: reachable)
    }

    /// Is any tile sharing an edge with `position` a supplied pipe? The
    /// exact shape `CitySimulator.hasAccess` already uses for road
    /// adjacency, just checking the cached reachability set
    /// (`CityMap.waterSupply`) instead of a raw zone — a building doesn't
    /// need to *be* a pipe, just touch one that's actually connected.
    static func hasSupply(at position: GridPosition, in map: CityMap) -> Bool {
        position.orthogonalNeighbors().contains { map.waterSupply.isSupplied(at: $0) }
    }
}

/// The result of `Water.computeSupply(for:)` — read-only from the outside,
/// same "one place produces this, everything else just reads it" contract
/// `TrafficLoad` and `CityHazards.Strike` both already use.
struct WaterSupply: Equatable, Codable, Sendable {
    private var reachablePipes: Set<GridPosition>

    init() {
        self.reachablePipes = []
    }

    fileprivate init(reachablePipes: Set<GridPosition>) {
        self.reachablePipes = reachablePipes
    }

    /// Is `position` a pipe tile actually connected to a funded water
    /// tower? False for every tile on a `CityMap` that never had
    /// `computeSupply` run against it (a fresh map, or one built directly
    /// in a test) — same "nothing until computed" default `TrafficLoad`
    /// uses.
    func isSupplied(at position: GridPosition) -> Bool {
        reachablePipes.contains(position)
    }
}
