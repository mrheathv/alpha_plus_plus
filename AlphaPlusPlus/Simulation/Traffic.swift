import Foundation

/// How loaded a road tile is, as a number from 0 (empty) to 1 (at capacity).
///
/// A road tile's load is the sum of every actual commute that routes
/// through it: each residential building sends its population toward a
/// job it can actually reach *that still has room* (a commercial or
/// industrial building — see `jobCapacityPerDensityLevel`), routed via
/// shortest path over the drivable network (`.road`/`.highway`), not
/// straight-line distance — a real street shared by five houses on the
/// way to one shop carries all five commutes, while a private stub off
/// just one of them doesn't. See `computeLoad(for:)` for exactly how
/// that's computed, and `TrafficLoad` for where the result lives.
///
/// Which job a home commutes to is a distance-weighted lottery
/// (`chooseJob(from:homeSeed:)`), not simply "the nearest one with room" —
/// employment doesn't actually correlate only with which building happens
/// to be closest, and always routing to the nearest reachable job
/// concentrates commutes onto whichever road segment that job sits on
/// even when a second job with room sits two streets over. Neither
/// SimCity 4 nor Cities: Skylines models this any differently (both are
/// documented, including by their own modding communities, as routing to
/// the nearest matching job) — this is a deliberate departure from genre
/// convention, not a gap relative to it.
///
/// It's visualized (`RenderPalette.trafficColor(for:)`, the "Show Traffic"
/// overlay) before it changes any other mechanic, same order `LandValue`
/// was introduced in: see it first, decide what it should affect once it's
/// something you can actually look at.
enum Traffic {

    /// How much commute weight one job site can absorb per level of its
    /// own density before it stops being a candidate a home's lottery can
    /// draw at all. Without this, a home could route its entire commute
    /// to a job with nowhere left to actually put it — realistic in the
    /// sense that people really do compete for jobs, unrealistic in that
    /// a single shop can't actually employ an entire neighborhood no
    /// matter how the lottery weighs it.
    ///
    /// Generously large (comfortably more than one fully-grown home's
    /// worth of commute weight, which tops out at `ZoneType.maxDensity`,
    /// 5) so a single home never gets blocked by a job that's merely
    /// modest rather than genuinely oversubscribed — capacity is meant to
    /// run out only once *several* dense homes lean on the same small
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

        var load = TrafficLoad()
        for tile in map.tiles where tile.isBuildingAnchor && tile.zone == .residential && tile.density > 0 {
            let homeFrontage = frontage(ofFootprint: tile.position, size: tile.zone.footprintSize, in: map, drivable: drivable)
            guard !homeFrontage.isEmpty else { continue } // transit-only access: no road trips generated

            // The *whole* reachable network from this home, not just the
            // nearest job — `chooseJob` needs every reachable candidate's
            // distance to weigh against each other, which stopping early
            // at the first job with room (the old approach) can't provide.
            let (distance, parent) = reachableTiles(from: homeFrontage, over: drivable)

            var candidates: [JobCandidate] = []
            for (index, job) in jobs.enumerated() where job.remainingCapacity > 0 {
                // A job can front more than one drivable tile; this home's
                // distance to it is the closest of those it actually reached.
                // `sortedByPosition` rather than iterating the `Set` directly:
                // when two frontage cells are equidistant, `min(by:)` keeps
                // whichever it saw first, so `Set` iteration order would decide
                // the route — and that is not stable between two `Set`
                // instances holding the same elements. See
                // `reachableTiles(from:over:)` for the full story.
                guard let nearest = job.frontage.sortedByPosition()
                    .compactMap({ cell in distance[cell].map { (cell, $0) } })
                    .min(by: { $0.1 < $1.1 }) else { continue }
                candidates.append(JobCandidate(jobIndex: index, frontageCell: nearest.0, distance: nearest.1))
            }
            guard let chosen = chooseJob(from: candidates, homeSeed: tile.position) else { continue } // no reachable job has room

            let path = reconstructPath(to: chosen.frontageCell, parent: parent)
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
            jobs[chosen.jobIndex].remainingCapacity -= tile.density
        }
        return load
    }

    /// One reachable job a home's lottery could draw: which job (`jobIndex`
    /// into `computeLoad(for:)`'s own `jobs` array), the closest of that
    /// job's frontage cells this home actually reached (`frontageCell`,
    /// where `reconstructPath(to:parent:)` routes to), and the hop count
    /// to get there (`distance`, what `chooseJob(from:homeSeed:)` weighs).
    private struct JobCandidate {
        let jobIndex: Int
        let frontageCell: GridPosition
        let distance: Int
    }

    /// Which job a home actually commutes to: a distance-weighted lottery
    /// among every candidate with room, not always the nearest one — see
    /// this file's own top-of-file doc comment for why. Weight is
    /// `1 / (distance + 1)`, so a job twice as far is half as likely to be
    /// drawn rather than simply less likely by some unbounded amount — near
    /// jobs still win more often in aggregate, they just aren't the *only*
    /// possible outcome the way "always nearest" made them.
    ///
    /// The draw itself is `pseudoRandomUnitValue(for:)`, seeded from the
    /// home's own position rather than `GameController`'s shared RNG — the
    /// same "stable per-lot, not re-rolled every tick" shape
    /// `ZoneIcon.variant(for:optionCount:)` already uses to pick a
    /// building's look. A home keeps commuting to the same job tick after
    /// tick unless the map itself changes (a road, a job filling up),
    /// rather than its ambient traffic car flickering to a new destination
    /// on a clock it has no reason to change.
    private static func chooseJob(from candidates: [JobCandidate], homeSeed: GridPosition) -> JobCandidate? {
        guard !candidates.isEmpty else { return nil }
        let weights = candidates.map { 1.0 / Double($0.distance + 1) }
        let totalWeight = weights.reduce(0, +)
        let roll = pseudoRandomUnitValue(for: homeSeed) * totalWeight
        var cumulative = 0.0
        for (candidate, weight) in zip(candidates, weights) {
            cumulative += weight
            if roll < cumulative { return candidate }
        }
        return candidates.last // floating-point rounding safety net
    }

    /// A simple, stable mix of `x`/`y` into a value in `0..<1` — not a real
    /// hash function (same disclaimer `ZoneIcon.variant(for:optionCount:)`
    /// makes about its own position mix, and deliberately not
    /// `GridPosition`'s `Hashable` conformance, which Swift randomizes per
    /// process launch), just enough spread that different homes draw
    /// visibly different lottery numbers instead of clustering on similar
    /// ones.
    private static func pseudoRandomUnitValue(for seed: GridPosition) -> Double {
        let mixed = abs(seed.x &* 928_371 &+ seed.y &* 123_457 &+ 17)
        return Double(mixed % 1_000_003) / 1_000_003.0
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

    /// Multi-source breadth-first search over `drivable`, starting from
    /// every tile in `sources` at once (so a building fronting a road on
    /// more than one side doesn't bias toward whichever side happens to be
    /// checked first) — but run to completion rather than stopping at the
    /// first match, since `computeLoad(for:)` needs *every* reachable
    /// job's distance to weigh in `chooseJob(from:homeSeed:)`'s lottery,
    /// not just the nearest one. Returns each reached tile's hop count
    /// from its nearest source, plus a parent pointer back toward the
    /// source `reconstructPath(to:parent:)` walks to rebuild an actual
    /// route once a destination is chosen.
    private static func reachableTiles(from sources: Set<GridPosition>, over drivable: Set<GridPosition>) -> (distance: [GridPosition: Int], parent: [GridPosition: GridPosition]) {
        // Seeded from a *sorted* array, not straight from the `Set`.
        //
        // The order sources enter the queue decides which of several equally
        // short routes a tile's `parent` pointer ends up describing, and
        // therefore which road tiles the commute is drawn onto. Taking that
        // order from `Set` iteration made `computeLoad` genuinely
        // non-deterministic: two calls on the *same* map returned different
        // loads, alternating between two answers on repeated calls. It went
        // unnoticed because it needs a map complex enough to produce ties —
        // a small hand-built fixture is stable, a generated city is not — and
        // it quietly added noise to every measurement the playtest harness
        // has ever taken, including the ones this project tuned balance
        // constants against.
        let orderedSources = sources.sortedByPosition()
        var distance: [GridPosition: Int] = Dictionary(uniqueKeysWithValues: orderedSources.map { ($0, 0) })
        var parent: [GridPosition: GridPosition] = [:]
        var queue = orderedSources
        var head = 0

        while head < queue.count {
            let current = queue[head]
            head += 1
            let nextDistance = distance[current]! + 1
            for neighbor in current.orthogonalNeighbors() where drivable.contains(neighbor) && distance[neighbor] == nil {
                distance[neighbor] = nextDistance
                parent[neighbor] = current
                queue.append(neighbor)
            }
        }
        return (distance, parent)
    }

    /// Walks `parent` pointers from `destination` back to whichever source
    /// `reachableTiles(from:over:)` reached it from, then reverses the
    /// result into a source-to-destination route — the same path shape
    /// the old single-destination search used to return directly, just
    /// reconstructed after the fact now that the search itself no longer
    /// stops at any one destination.
    private static func reconstructPath(to destination: GridPosition, parent: [GridPosition: GridPosition]) -> [GridPosition] {
        var path = [destination]
        var node = destination
        while let previous = parent[node] {
            path.append(previous)
            node = previous
        }
        return path.reversed()
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

    /// Which of a road tile's four orthogonal neighbors are also road-like
    /// — the actual shape of the street network at this tile (a straight
    /// run, a turn, a T-junction, a 4-way crossroads, a dead end, or an
    /// isolated stub with no connections at all yet), not just the single
    /// "horizontal or vertical" axis `isHorizontallyOriented(at:in:)`
    /// picks for orienting the ambient traffic animation. `TileRenderer`
    /// reads this to draw the glowing lane line as that actual shape
    /// instead of always a straight line through the tile regardless of
    /// what's really connected to it.
    struct RoadConnections: Equatable {
        let north: Bool
        let south: Bool
        let east: Bool
        let west: Bool

        /// How many of the four directions are actually connected — 0
        /// (isolated stub) through 4 (a full crossroads).
        var count: Int { [north, south, east, west].filter { $0 }.count }
    }

    static func roadConnections(at position: GridPosition, in map: CityMap) -> RoadConnections {
        func connected(_ neighbor: GridPosition) -> Bool {
            map.contains(neighbor) && isRoadLike(map[neighbor].zone)
        }
        return RoadConnections(
            north: connected(GridPosition(x: position.x, y: position.y + 1)),
            south: connected(GridPosition(x: position.x, y: position.y - 1)),
            east: connected(GridPosition(x: position.x + 1, y: position.y)),
            west: connected(GridPosition(x: position.x - 1, y: position.y))
        )
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
