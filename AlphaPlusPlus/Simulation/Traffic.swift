import Foundation

/// How loaded a road tile is, as a number from 0 (empty) to 1 (at capacity).
///
/// A road tile's load is the sum of every actual commute that routes
/// through it: each residential building sends its population toward its
/// nearest reachable job *that still has room* (a commercial or industrial
/// building — see `jobCapacityPerDensityLevel`), routed via shortest path
/// over the drivable network (`.road`/`.highway`), not straight-line
/// distance — a real street shared by five houses on the way to one shop
/// carries all five commutes, while a private stub off just one of them
/// doesn't. See `computeLoad(for:)` for exactly how that's computed, and
/// `TrafficLoad` for where the result lives.
///
/// It's visualized (`RenderPalette.trafficColor(for:)`, the "Show Traffic"
/// overlay) before it changes any other mechanic, same order `LandValue`
/// was introduced in: see it first, decide what it should affect once it's
/// something you can actually look at.
enum Traffic {

    /// How much commute weight one job site can absorb per level of its
    /// own density before a home looking for work there gets routed past
    /// it to the next-nearest job with room instead. Without this, every
    /// home in reach of the *same* nearest job piles its commute onto
    /// identical road segments even when a second job sits two streets
    /// over with nobody working there at all — realistic in the sense that
    /// people really do all want the closest job, unrealistic in that a
    /// single shop can't actually employ an entire neighborhood.
    ///
    /// Generously large (comfortably more than one fully-grown home's
    /// worth of commute weight, which tops out at `ZoneType.maxDensity`,
    /// 5) so a single home never gets split or blocked by a job that's
    /// merely modest rather than genuinely oversubscribed — spreading is
    /// meant to kick in once *several* dense homes lean on the same small
    /// job, not the instant any job is less than fully built. A first
    /// guess, same "needs playtesting" status as every other number here.
    private static let jobCapacityPerDensityLevel = 10

    /// One job site's road frontage and how much commute weight it can
    /// still absorb — mutated as `computeLoad(for:)` assigns homes to it,
    /// so processing homes in a different order can send them to different
    /// jobs. Not `Codable`/exposed outside this file: it's scratch state
    /// for one `computeLoad` call, not something any caller needs to hold
    /// onto the way `TrafficLoad` itself is.
    private struct JobSite {
        let frontage: Set<GridPosition>
        var remainingCapacity: Int
    }

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

    /// Routes every residential building's commute to its nearest reachable
    /// job *with room left* and accumulates the result — the one real
    /// computation behind `congestion(at:in:)`. Call once per simulation
    /// tick (`GameController.advanceSimulation()` does this first, before
    /// hazards/growth run) and store the result on `map.trafficLoad`;
    /// everything else reads that cache rather than calling this directly.
    ///
    /// Homes are processed in `map.tiles` order (row-major by position) —
    /// deterministic, so the same map always assigns the same homes to the
    /// same jobs, but otherwise arbitrary: whichever home happens to come
    /// first in that order claims a shared job's capacity before a later
    /// one does. Not modeled as "fair" or "closest home wins" — that would
    /// need sorting every home by distance to every job before assigning
    /// any of them, real complexity for a first cut of spreading commutes
    /// out at all.
    ///
    /// Deliberate v1 simplifications: a home always routes to its single
    /// nearest job with capacity (by road-network hops, via plain
    /// unweighted BFS — every hop costs the same, so there's no need for
    /// Dijkstra), never splits one home's commute across multiple
    /// destinations or reroutes around a congested path. Real traffic
    /// assignment — the kind that would notice a jam and try a different
    /// street — is exactly the individual-agent complexity this project's
    /// aggregate-simulation approach is choosing not to chase (see the
    /// roadmap's genre parity check). Commercial and industrial are both
    /// valid job destinations with no distinction between them, matching
    /// `GameController.jobs` already summing both the same way.
    static func computeLoad(for map: CityMap) -> TrafficLoad {
        let drivable = Set(map.tiles.filter { isRoadLike($0.zone) }.map(\.position))
        guard !drivable.isEmpty else { return TrafficLoad() }

        var jobs = jobSites(in: map, drivable: drivable)
        guard !jobs.isEmpty else { return TrafficLoad() }

        // Every frontage tile maps back to whichever job site(s) it
        // fronts, so the BFS below can answer "is this a job with room
        // left?" with a dictionary lookup instead of scanning every job
        // at every tile it visits.
        var jobIndicesByFrontage: [GridPosition: [Int]] = [:]
        for (index, job) in jobs.enumerated() {
            for tile in job.frontage {
                jobIndicesByFrontage[tile, default: []].append(index)
            }
        }

        var load = TrafficLoad()
        for tile in map.tiles where tile.isBuildingAnchor && tile.zone == .residential && tile.density > 0 {
            let homeFrontage = frontage(ofFootprint: tile.position, size: tile.zone.footprintSize, in: map, drivable: drivable)
            guard !homeFrontage.isEmpty else { continue } // transit-only access: no road trips generated

            var claimedJobIndex: Int?
            let path = shortestPath(from: homeFrontage, over: drivable) { candidate in
                guard let indices = jobIndicesByFrontage[candidate] else { return false }
                guard let openIndex = indices.first(where: { jobs[$0].remainingCapacity > 0 }) else { return false }
                claimedJobIndex = openIndex
                return true
            }
            guard let path, let claimedJobIndex else { continue } // every reachable job is full

            for (index, step) in path.enumerated() {
                // The step *after* this one is the direction a car sitting
                // on this tile, mid-commute, is actually headed -- nil for
                // the path's last step (the job site's own frontage cell),
                // which has no "next" to head toward.
                let heading = index + 1 < path.count
                    ? GridPosition(x: path[index + 1].x - step.x, y: path[index + 1].y - step.y)
                    : nil
                load.add(tile.density, at: step, heading: heading)
            }
            // Claimed *after* routing, by the home's own density — a
            // level-5 home uses five times the room a level-1 home does,
            // the same weight it contributes to road load.
            jobs[claimedJobIndex].remainingCapacity -= tile.density
        }
        return load
    }

    /// Every commercial/industrial building with road frontage, as a job
    /// site with its starting capacity (`density * jobCapacityPerDensityLevel`)
    /// — the pool `computeLoad(for:)` draws down as homes claim a share of
    /// it.
    private static func jobSites(in map: CityMap, drivable: Set<GridPosition>) -> [JobSite] {
        var sites: [JobSite] = []
        for tile in map.tiles where tile.isBuildingAnchor && (tile.zone == .commercial || tile.zone == .industrial) && tile.density > 0 {
            let siteFrontage = frontage(ofFootprint: tile.position, size: tile.zone.footprintSize, in: map, drivable: drivable)
            guard !siteFrontage.isEmpty else { continue } // no road access: not a reachable job at all
            sites.append(JobSite(frontage: siteFrontage, remainingCapacity: tile.density * jobCapacityPerDensityLevel))
        }
        return sites
    }

    /// Every drivable tile orthogonally touching any building anchored at
    /// `position` — a building's "driveway" onto the network.
    private static func frontage(ofFootprint position: GridPosition, size: Int, in map: CityMap, drivable: Set<GridPosition>) -> Set<GridPosition> {
        Set(map.footprintCells(origin: position, size: size)
            .flatMap { $0.orthogonalNeighbors() }
            .filter { drivable.contains($0) })
    }

    /// Plain multi-source breadth-first search over `drivable`, starting
    /// from every tile in `sources` at once (so a building fronting a road
    /// on more than one side doesn't bias toward whichever side happens to
    /// be checked first) and stopping at the first tile satisfying
    /// `isDestination` — that's the nearest one, since every hop costs the
    /// same. Returns the full path (sources' entry point through the
    /// destination reached), or `nil` if nothing satisfying `isDestination`
    /// is reachable at all.
    ///
    /// `isDestination` is a predicate rather than a static
    /// `Set<GridPosition>` specifically so `computeLoad(for:)` can route
    /// around a job that's already at capacity without a second, separate
    /// search — the closure re-checks each job's *current* remaining
    /// capacity as the search reaches it, which a plain set membership
    /// test can't express.
    private static func shortestPath(from sources: Set<GridPosition>, over drivable: Set<GridPosition>, to isDestination: (GridPosition) -> Bool) -> [GridPosition]? {
        var visited = sources
        var parent: [GridPosition: GridPosition] = [:]
        var queue = Array(sources)
        var head = 0

        while head < queue.count {
            let current = queue[head]
            head += 1
            if isDestination(current) {
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
    /// "more correct" *axis* to prefer at an intersection from geometry
    /// alone. `TrafficLoad.netHeading(at:)` is the answer to the
    /// follow-up question this doc comment used to say there was no real
    /// data for — which *way along* that axis most routed traffic is
    /// actually headed, now that real routing exists.
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

    /// Net direction routed trips are headed while crossing this tile,
    /// one signed accumulator per axis: positive `x` means more
    /// trip-weight headed east than west through here, positive `y` more
    /// headed north than south. Two independent axes, not one heading,
    /// because a tile can legitimately carry both a horizontal and a
    /// vertical flow at once (a junction) — `netHeading(at:)` collapses
    /// this to the single dominant axis `GameScene` actually needs for
    /// its (already axis-picked, via `Traffic.isHorizontallyOriented`)
    /// car animation.
    private var netHeadingXByTile: [GridPosition: Int] = [:]
    private var netHeadingYByTile: [GridPosition: Int] = [:]

    /// How many routed trip-units pass through `position` — 0 for a tile
    /// nothing routes through, including every tile on a `CityMap` that
    /// never had `computeLoad` called against it (a fresh map, or one
    /// built directly in a test).
    func load(at position: GridPosition) -> Int {
        loadByTile[position, default: 0]
    }

    /// Which way *most* routed traffic through `position` is actually
    /// headed, along whichever single axis (`horizontal`) the caller
    /// already picked for it — `true` for the positive-axis direction
    /// (east or north), `false` for negative (west or south). Falls back
    /// to `true` when there's no net bias on that axis (equal split, or
    /// no routed load at all) — an arbitrary but stable default, the
    /// same spirit `Traffic.isHorizontallyOriented`'s own tie-break
    /// already has, so a car still points *somewhere* consistent rather
    /// than needing a third "undetermined" state nothing renders
    /// differently for anyway.
    func netHeadingIsPositive(at position: GridPosition, horizontal: Bool) -> Bool {
        let net = horizontal ? netHeadingXByTile[position, default: 0] : netHeadingYByTile[position, default: 0]
        return net >= 0
    }

    fileprivate mutating func add(_ amount: Int, at position: GridPosition, heading: GridPosition?) {
        loadByTile[position, default: 0] += amount
        guard let heading else { return }
        if heading.x != 0 { netHeadingXByTile[position, default: 0] += amount * heading.x }
        if heading.y != 0 { netHeadingYByTile[position, default: 0] += amount * heading.y }
    }
}
