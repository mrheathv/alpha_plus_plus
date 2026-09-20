import Foundation

/// **Engines that actually drive to the fire.**
///
/// Traffic already turns red near a burning block, which is a *hint*: a
/// vehicle that happens to be the right colour because it is standing near
/// the right thing. This is the real version — a route from a fire station,
/// along streets that exist, to the building that is alight.
///
/// The difference is not decoration. A hint tells you a fire is roughly over
/// there; an engine leaving a station and running across the map tells you
/// **which station is covering it**, and — when no engine appears at all —
/// that nothing is. That is the same information the Fire Risk overlay
/// carries, except you get it without going to look for it.
///
/// In `Rendering/` for the reason `ShippingLane` and `Weather` are: nothing in
/// the simulation reads it. `ServiceCoverage` already decides whether a fire
/// is contained and `Fire` already decides whether it spreads; drawing an
/// engine changes neither, and putting this in `Simulation/` would claim a
/// mechanic the game does not have.
enum EmergencyResponse {

    /// At most this many engines on the map at once.
    ///
    /// A citywide conflagration is exactly when you least want forty vehicles
    /// added to the scene, and past three or four converging streaks the mark
    /// stops reading as "the response" and starts reading as noise — the same
    /// argument `NeonStyle.minimumDetailSize` makes about density, one level
    /// up from individual marks.
    static let simultaneousEngines = 4

    /// Road paths from a fire station to each fire it can reach, nearest
    /// fires first.
    ///
    /// Searched **from the fire outward**, which is the cheaper direction:
    /// there are usually more fires than stations in a bad moment, but a
    /// search from the fire stops the instant it meets any station, where a
    /// search from each station would have to run to completion to find out
    /// which fire is nearest. One breadth-first walk per burning block, and
    /// only while something is burning at all.
    static func fireRoutes(in map: CityMap) -> [[GridPosition]] {
        let burning = map.tiles
            .filter { $0.isBuildingAnchor && $0.isBurning }
            .map(\.position)
            .sortedByPosition()
        guard !burning.isEmpty else { return [] }

        let drivable = Set(map.tiles.filter { $0.zone == .road || $0.zone == .highway }
            .map(\.position))
        guard !drivable.isEmpty else { return [] }

        let stationCells = Set(map.tiles.filter { map[$0.position].zone == .fireStation }
            .map(\.position))
        guard !stationCells.isEmpty else { return [] }
        // The streets a station fronts onto — where an engine comes out.
        let depots = Set(stationCells.flatMap { $0.orthogonalNeighbors() }
            .filter { drivable.contains($0) })
        guard !depots.isEmpty else { return [] }

        var routes: [[GridPosition]] = []
        for fire in burning {
            guard routes.count < simultaneousEngines else { break }
            if let run = road(from: fire, toAnyOf: depots, over: drivable, in: map) {
                // **Not reversed**, and it is worth saying why, because the
                // instinct is to reverse it: the search starts at the fire but
                // *builds* its path by walking back from the arrival, which is
                // the depot. So it already comes out station-first, which is
                // the direction an engine travels. Reversing it would send
                // every engine away from the emergency.
                routes.append(run)
            }
        }
        return routes
    }

    /// Shortest road run from the streets around `origin` to any of `targets`.
    private static func road(
        from origin: GridPosition, toAnyOf targets: Set<GridPosition>,
        over drivable: Set<GridPosition>, in map: CityMap
    ) -> [GridPosition]? {
        let footprint = map.footprintCells(origin: origin, size: map[origin].zone.footprintSize)
        let starts = footprint.flatMap { $0.orthogonalNeighbors() }
            .filter { drivable.contains($0) }
            .sortedByPosition()
        guard !starts.isEmpty else { return nil }

        var parent: [GridPosition: GridPosition] = [:]
        var seen = Set(starts)
        var queue = starts
        var head = 0
        var arrival: GridPosition?
        while head < queue.count {
            let current = queue[head]
            head += 1
            if targets.contains(current) { arrival = current; break }
            for next in current.orthogonalNeighbors().sortedByPosition()
            where drivable.contains(next) && !seen.contains(next) {
                seen.insert(next)
                parent[next] = current
                queue.append(next)
            }
        }
        guard var node = arrival else { return nil }

        var run = [node]
        while let step = parent[node] {
            run.append(step)
            node = step
        }
        // `run` is station-first at this point, because it walks back from the
        // arrival — which is the depot — toward the fire.
        return run
    }
}
