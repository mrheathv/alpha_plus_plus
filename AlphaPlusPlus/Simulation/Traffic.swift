import Foundation

/// How loaded a road tile is, as a number from 0 (empty) to 1 (at capacity).
///
/// A road tile's load is the sum of every actual commute that routes
/// through it: each residential building sends its population toward its
/// *nearest reachable job* (a commercial or industrial building), routed
/// via shortest path over the drivable network (`.road`/`.highway`), not
/// straight-line distance — a real street shared by five houses on the way
/// to one shop carries all five commutes, while a private stub off just
/// one of them doesn't. See `computeLoad(for:)` for exactly how that's
/// computed, and `TrafficLoad` for where the result lives.
///
/// It's visualized (`RenderPalette.trafficColor(for:)`, the "Show Traffic"
/// overlay) before it changes any other mechanic, same order `LandValue`
/// was introduced in: see it first, decide what it should affect once it's
/// something you can actually look at.
enum Traffic {

    /// How much routed commute load one road tile can carry before it
    /// reads as fully congested. Unlike the old local-density version of
    /// this constant, this isn't a bound on a fixed number of neighbors —
    /// a tile's load is the sum of every commute that happens to route
    /// through it, which a busy through-street can legitimately exceed
    /// many times over. A first guess, same "needs playtesting" status as
    /// every other number in this file — recalibrated fresh rather than
    /// reused from the old formula, since the two numbers no longer mean
    /// the same kind of thing.
    private static let capacityPerRoadTile = 40.0

    /// A `.highway` tile's whole reason to cost 4x a plain road: it
    /// absorbs twice the routed commute load before feeling as congested.
    /// Same shape of ceiling as `capacityPerRoadTile`, just a bigger one —
    /// not a different formula, so a highway isn't "immune" to traffic,
    /// just harder to actually jam.
    private static let highwayCapacityMultiplier = 2.0

    /// Is this a tile that carries road traffic — a plain `.road` or the
    /// higher-capacity `.highway`? Shared by `congestion(at:in:)` (deciding
    /// whether a tile has congestion at all), `computeLoad(for:)` (deciding
    /// what counts as part of the drivable network), and
    /// `isHorizontallyOriented(at:in:)` (deciding what counts as a "road
    /// neighbor" for orienting the ambient traffic animation) — one
    /// definition of "road-like," not three that could drift apart.
    private static func isRoadLike(_ zone: ZoneType) -> Bool {
        zone == .road || zone == .highway
    }

    /// How congested this tile is right now, 0 (empty) to 1 (at capacity).
    /// Non-road-like tiles (including tiles off the map) have no
    /// congestion by definition — congestion describes road capacity, not
    /// general busy-ness of a place. A `.subway`/`.publicTransit` stop is
    /// deliberately excluded too: it moves people without adding to what a
    /// road has to carry, which is the whole point of it as an alternative
    /// to one.
    ///
    /// Reads `map.trafficLoad`, a cached snapshot `computeLoad(for:)`
    /// builds once per simulation tick (`GameController.advanceSimulation()`)
    /// rather than recomputing routed trips fresh on every call — real
    /// trip routing is a full network search, not the cheap local lookup
    /// this used to be, so a `CityMap` that never had `computeLoad` run
    /// against it (a fresh map, or one built by hand in a test) simply
    /// reads 0 everywhere, the same as an empty road reads today.
    static func congestion(at position: GridPosition, in map: CityMap) -> Double {
        guard map.contains(position) else { return 0 }
        let zone = map[position].zone
        guard isRoadLike(zone) else { return 0 }
        let capacity = zone == .highway ? capacityPerRoadTile * highwayCapacityMultiplier : capacityPerRoadTile
        return min(1, Double(map.trafficLoad.load(at: position)) / capacity)
    }

    /// Routes every residential building's commute to its nearest
    /// reachable job and accumulates the result — the one real computation
    /// behind `congestion(at:in:)`. Call once per simulation tick
    /// (`GameController.advanceSimulation()` does this first, before
    /// hazards/growth run) and store the result on `map.trafficLoad`;
    /// everything else reads that cache rather than calling this directly.
    ///
    /// Deliberate v1 simplifications: a home always routes to its single
    /// *nearest* job (by road-network hops, via plain unweighted BFS —
    /// every hop costs the same, so there's no need for Dijkstra), never
    /// splits trips across multiple destinations or reroutes around a
    /// congested path. Real traffic assignment — the kind that would
    /// notice a jam and try a different street — is exactly the
    /// individual-agent complexity this project's aggregate-simulation
    /// approach is choosing not to chase (see the roadmap's genre parity
    /// check). Commercial and industrial are both valid job destinations
    /// with no distinction between them, matching `GameController.jobs`
    /// already summing both the same way.
    static func computeLoad(for map: CityMap) -> TrafficLoad {
        let drivable = Set(map.tiles.filter { isRoadLike($0.zone) }.map(\.position))
        guard !drivable.isEmpty else { return TrafficLoad() }

        let jobFrontage = frontage(
            ofBuildingsWhere: { $0.zone == .commercial || $0.zone == .industrial },
            in: map,
            drivable: drivable
        )
        guard !jobFrontage.isEmpty else { return TrafficLoad() }

        var load = TrafficLoad()
        for tile in map.tiles where tile.isBuildingAnchor && tile.zone == .residential && tile.density > 0 {
            let homeFrontage = frontage(ofFootprint: tile.position, size: tile.zone.footprintSize, in: map, drivable: drivable)
            guard !homeFrontage.isEmpty else { continue } // transit-only access: no road trips generated
            guard let path = shortestPath(from: homeFrontage, to: jobFrontage, over: drivable) else { continue } // no reachable job

            for step in path {
                load.add(tile.density, at: step)
            }
        }
        return load
    }

    /// Every drivable tile orthogonally touching any building anchored at
    /// `position` — a building's "driveway" onto the network.
    private static func frontage(ofFootprint position: GridPosition, size: Int, in map: CityMap, drivable: Set<GridPosition>) -> Set<GridPosition> {
        Set(map.footprintCells(origin: position, size: size)
            .flatMap { $0.orthogonalNeighbors() }
            .filter { drivable.contains($0) })
    }

    /// The combined frontage of every building matching `predicate` — used
    /// to gather every job site's driveways into one set of BFS targets at
    /// once, rather than one destination search per job.
    private static func frontage(ofBuildingsWhere predicate: (Tile) -> Bool, in map: CityMap, drivable: Set<GridPosition>) -> Set<GridPosition> {
        var result: Set<GridPosition> = []
        for tile in map.tiles where tile.isBuildingAnchor && predicate(tile) && tile.density > 0 {
            result.formUnion(frontage(ofFootprint: tile.position, size: tile.zone.footprintSize, in: map, drivable: drivable))
        }
        return result
    }

    /// Plain multi-source breadth-first search over `drivable`, starting
    /// from every tile in `sources` at once (so a building fronting a road
    /// on more than one side doesn't bias toward whichever side happens to
    /// be checked first) and stopping at the first tile in `destinations`
    /// reached — that's the nearest one, since every hop costs the same.
    /// Returns the full path (sources' entry point through the destination
    /// reached), or `nil` if nothing in `destinations` is reachable at all.
    private static func shortestPath(from sources: Set<GridPosition>, to destinations: Set<GridPosition>, over drivable: Set<GridPosition>) -> [GridPosition]? {
        var visited = sources
        var parent: [GridPosition: GridPosition] = [:]
        var queue = Array(sources)
        var head = 0

        while head < queue.count {
            let current = queue[head]
            head += 1
            if destinations.contains(current) {
                var path = [current]
                var node = current
                while let previous = parent[node] {
                    path.append(previous)
                    node = previous
                }
                return path.reversed()
            }
            for neighbor in current.orthogonalNeighbors() where drivable.contains(neighbor) && !visited.contains(neighbor) {
                visited.insert(neighbor)
                parent[neighbor] = current
                queue.append(neighbor)
            }
        }
        return nil
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

/// Routed commute load per drivable tile, as computed by
/// `Traffic.computeLoad(for:)` — the cache `Traffic.congestion(at:in:)`
/// reads instead of recomputing trip routing on every call. Read-only from
/// the outside: the only way to build a non-empty one is `computeLoad`,
/// the same "one place produces this, everything else just reads it"
/// shape `CityHazards.Strike` uses for hazard results.
struct TrafficLoad: Equatable, Codable, Sendable {
    private var loadByTile: [GridPosition: Int] = [:]

    /// How many routed trip-units pass through `position` — 0 for a tile
    /// nothing routes through, including every tile on a `CityMap` that
    /// never had `computeLoad` called against it (a fresh map, or one
    /// built directly in a test).
    func load(at position: GridPosition) -> Int {
        loadByTile[position, default: 0]
    }

    fileprivate mutating func add(_ amount: Int, at position: GridPosition) {
        loadByTile[position, default: 0] += amount
    }
}
