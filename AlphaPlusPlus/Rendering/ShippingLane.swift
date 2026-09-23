import Foundation

/// **Where a ship sails**: the water between a working dock and open sea.
///
/// In `Rendering/` for the same reason `Weather` is — nothing in the city's
/// economics reads it. `RegionalTrade` already decides what a seaport *does*;
/// this only decides where to draw something moving, and putting it in
/// `Simulation/` would claim a mechanic that does not exist.
///
/// **A ship only sails for a port that works.** A vessel gliding past a
/// coastline with no dock on it would be scenery, and this game does not draw
/// scenery — every mark on the map says something about the city. A ship says
/// *that quay is trading*, which is the one thing a seaport had no way of
/// showing: it was the only building in the game whose entire purpose was
/// invisible once built.
enum ShippingLane {

    /// The water a ship travels, ordered from the quay out toward the edge of
    /// the map.
    ///
    /// Breadth-first over water tiles, which is the same shape as
    /// `Transit.tramPath`'s search over roads and costs about as little: it
    /// runs once when the lane is rebuilt rather than per frame, and open
    /// water is a fraction of a map.
    ///
    /// Empty when there is no working dock, or when the dock sits on a pond
    /// with no way out — a lake counts as water and is not a sea route, and
    /// drawing a ship that sails into a dead end would claim a connection the
    /// map does not have. Same honesty as a severed tram line getting no
    /// vehicle.
    static func path(in map: CityMap) -> [GridPosition] {
        let docks = map.tiles
            .filter { $0.isBuildingAnchor && $0.zone == .seaport }
            .map(\.position)
            .sortedByPosition()
        guard let dock = docks.first else { return [] }

        let water = Set(map.tiles.filter(\.isWater).map(\.position))
        guard !water.isEmpty else { return [] }

        // Start from the wet tile the quay actually touches.
        let berths = map.footprintCells(origin: dock, size: ZoneType.seaport.footprintSize)
            .flatMap { $0.orthogonalNeighbors() }
            .filter { water.contains($0) }
            .sortedByPosition()
        guard let start = berths.first else { return [] }

        var parent: [GridPosition: GridPosition] = [:]
        var seen: Set<GridPosition> = [start]
        var queue = [start]
        var head = 0
        var exit: GridPosition?
        while head < queue.count {
            let current = queue[head]
            head += 1
            if isOnTheEdge(current, of: map) { exit = current; break }
            for next in current.orthogonalNeighbors().sortedByPosition()
            where water.contains(next) && !seen.contains(next) {
                seen.insert(next)
                parent[next] = current
                queue.append(next)
            }
        }
        guard var node = exit else { return [] }

        var run = [node]
        while let step = parent[node] {
            run.append(step)
            node = step
        }
        // Built backwards from the sea, so reversed it runs quay-first — which
        // is the direction a ship arriving is travelling in reverse, and the
        // direction the renderer's there-and-back expects to start from.
        return run.reversed()
    }

    private static func isOnTheEdge(_ position: GridPosition, of map: CityMap) -> Bool {
        position.x == 0 || position.y == 0
            || position.x == map.width - 1 || position.y == map.height - 1
    }
}
