import Foundation

/// Whether a tile is actually served by the water network — a real pipe
/// network, not a coverage radius: a building needs an unbroken chain of
/// `.pipe` tiles connecting it back to a `.waterTower`, the same way a
/// zone needs an actual road (not just "somewhere nearby") for
/// `CitySimulator.hasAccess`. Modeled after `Traffic.swift`'s shape almost
/// exactly, since it's the same underlying problem: a real network search
/// that's too expensive to redo per single-tile query, so it's computed
/// once (`computeSupply(for:)`) and cached (`CityMap.waterSupply`) rather
/// than threaded as an extra parameter through every caller.
enum Water {

    /// Every `.pipe` tile reachable from *some* funded water tower, and
    /// whether `.pipe` neighbors of a given position are among them —
    /// `hasSupply(at:in:)` is the only thing most callers need.
    ///
    /// Builds the reachable set with a plain flood-fill (unweighted BFS,
    /// no shortest-path bookkeeping): unlike `Traffic`'s routing, this
    /// only ever asks "is this tile connected at all," never "how far,"
    /// so there's nothing to reconstruct a path for.
    static func computeSupply(for map: CityMap) -> WaterSupply {
        // Funding is one city-wide dial per service (`ServiceFunding`'s
        // own design), not per-building — so defunding water takes every
        // tower offline at once, not just some of them.
        guard map.serviceFunding.level(for: .waterTower) > 0 else { return WaterSupply() }

        let pipes = Set(map.tiles.filter { $0.zone == .pipe }.map(\.position))
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
