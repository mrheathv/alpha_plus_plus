import Foundation

/// What the player's routes actually do, given the city as it stands.
///
/// **Why this is separate from `TransitNetwork`.** That type holds what was
/// drawn; this one decides what works. A stop whose station has been
/// bulldozed is still on the line and does nothing here; a line left with one
/// station is still a line and carries nobody. Keeping the two apart is what
/// lets a bulldozed station be rebuilt and the route simply start working
/// again — the same live/dead distinction the conduit overlay draws between a
/// pipe that exists and a pipe that reaches a source.
///
/// **Journeys are measured in minutes, and they can change lines.**
///
/// The first version of this module could not do either. A trip rode only
/// when *one* route served both ends, and it rode whenever that was true
/// regardless of whether riding was any faster than driving. Both were
/// defensible with two modes and neither survives four: a tram feeding a
/// subway feeding a regional train *is* the mechanic, and a line that goes
/// the long way round should not beat a two-tile drive.
///
/// **Why transfers turned out to be affordable**, having been ruled out once
/// on cost. `Traffic.computeLoad` is ~90% of a tick because it runs a
/// breadth-first search *per home* — thousands of searches over thousands of
/// road tiles. The transit graph has **tens of nodes**: one per (station,
/// line) pair, which in a real city is under two hundred. All-pairs shortest
/// paths over that is nothing, computed once per tick rather than once per
/// trip, and the per-home step stays what it always was — an index lookup.
/// The original reasoning was right about the cost of searching per trip and
/// wrong about needing to.
enum Transit {


    /// How far a rider will walk to a bus stop, in orthogonal steps from the
    /// station's own footprint.
    ///
    /// Deliberately *not* `LandValue.transitFalloffDistance`, which measures
    /// something else: how far the amenity is *felt* as desirability. This is
    /// a catchment — whether the people who live here can use the thing — and
    /// conflating the two would tie a balance change in one to a silent
    /// change in the other. Matched to `Water.directSupplyRadius` (4), which
    /// is the game's existing answer to "near enough to count."
    static let busCatchment = 4

    /// Twice a bus stop's, the same "pricier version reaches further"
    /// relationship `.subway` already has with `.publicTransit` and
    /// `.highway` has with `.road`. A doubling rather than a tuned number:
    /// balance belongs to a later phase, and a ratio is easier to re-derive
    /// than a constant nobody can reconstruct the reasoning for.
    static let subwayCatchment = busCatchment * 2

    /// Between the two, and nearer the bus: a tram stop is still something
    /// you walk to along a street, not a station you plan a journey around.
    /// What a tram buys over a bus is the ride, not the reach.
    static let tramCatchment = 5

    /// The stops on `route` that are still a station of its own kind.
    ///
    /// **The one definition of what a line actually calls at.** A stop whose
    /// station has been bulldozed is still on the route and reaches nobody; a
    /// bus route listing a subway entrance does not call there. Four separate
    /// places needed that filter — coverage, capacity, the diagram and the
    /// panel's fault line — and four copies of a rule is how this project has
    /// been bitten before.
    static func workingStops(of route: TransitRoute, in map: CityMap) -> [GridPosition] {
        route.stops.filter { stop in
            map.contains(stop)
                && map[stop].isBuildingAnchor
                && map[stop].zone == route.mode.stationZone
        }
    }

    /// Is this line running at all?
    static func isRunning(_ route: TransitRoute, in map: CityMap) -> Bool {
        workingStops(of: route, in: map).count >= TransitRoute.minimumStops
    }

    static func catchment(for mode: TransitRoute.Mode) -> Int {
        switch mode {
        case .bus: return busCatchment
        case .tram: return tramCatchment
        case .subway: return subwayCatchment
        }
    }

    /// How much of a line's capacity a completely jammed corridor takes away,
    /// and what it keeps regardless.
    ///
    /// **This is the three-way split the modes exist for.** A bus is stuck in
    /// the traffic it is trying to relieve. A tram has its own rails down the
    /// middle of the street, so it is slowed a little at junctions and
    /// crossings and not much else. A subway is in a tunnel and does not care
    /// at all.
    ///
    /// The floor is there for the reason `Infrastructure.ruinedCapacityFraction`
    /// is: a line losing capacity pushes riders onto the roads that are
    /// jamming it, and that loop has no bottom without one. In practice only
    /// the bus's binds — a tram's penalty alone never takes it below 0.75 —
    /// and both are declared anyway so that raising a penalty later cannot
    /// quietly remove the bound.
    static func jamEffect(on mode: TransitRoute.Mode) -> (penalty: Double, floor: Double) {
        switch mode {
        case .bus: return (busJamPenalty, busJamFloor)
        case .tram: return (0.25, 0.7)
        case .subway: return (0, 1)
        }
    }

    /// How many people a line carries in a day, at full rate.
    ///
    /// **Per stop, not per line**, so a longer route runs more vehicles and
    /// carries more — which makes extending a line a real alternative to
    /// building a second one, and stops a two-stop shuttle being as good as a
    /// cross-town service.
    static func ratedCapacity(of route: TransitRoute, in map: CityMap) -> Int {
        let stops = workingStops(of: route, in: map)
        guard stops.count >= TransitRoute.minimumStops else { return 0 }
        return stops.count * route.mode.capacityPerStop
    }

    /// What it actually carries today, once the roads are taken into account.
    ///
    /// **This is the whole character of the two modes.** A bus shares the
    /// street: park a line along a jammed arterial and it crawls, exactly when
    /// the city needs it most. A subway has its own tunnel and does not care.
    /// Until now the two differed only in how far they reached and what they
    /// cost, which made the subway a bus with bigger numbers rather than a
    /// different answer to a different problem.
    ///
    /// Congestion is measured at the stops rather than along the line, because
    /// the line has no road path — it is a schematic between stations (see
    /// `IsoTileRenderer.transitDiagram`). A stop on a jammed street is a
    /// jammed stop, which is the part a rider actually experiences.
    ///
    /// Reads last tick's `trafficLoad`, since this is called *from*
    /// `Traffic.computeLoad` while this tick's is still being built. A one
    /// tick lag on a field that moves this slowly is invisible, and the
    /// alternative is a circular definition.
    static func dailyCapacity(of route: TransitRoute, in map: CityMap) -> Int {
        let rated = ratedCapacity(of: route, in: map)
        let jam = jamEffect(on: route.mode)
        guard rated > 0, jam.penalty > 0 else { return rated }

        let stops = workingStops(of: route, in: map)
        let jams = stops.map { stop -> Double in
            map.footprintCells(origin: stop, size: route.mode.stationZone.footprintSize)
                .flatMap { $0.orthogonalNeighbors() }
                .map { Traffic.congestion(at: $0, in: map) }
                .max() ?? 0
        }
        let average = jams.reduce(0, +) / Double(jams.count)
        return Int(Double(rated) * max(jam.floor, 1 - average * jam.penalty))
    }

    /// Every road tile a tram runs down, derived from the lines themselves.
    ///
    /// **A tram is the only mode with a path on the ground**, and it has to
    /// be: the lane it takes is taken from *particular* streets. Everything
    /// else in this module is deliberately schematic — the route is the
    /// infrastructure, there is no track layer, and a bus route's line on the
    /// diagram is a claim about stations rather than a drawing of a road.
    ///
    /// So the track is *derived, not authored*. The player still only clicks
    /// stations; the shortest road run between each consecutive pair is where
    /// the rails go. That keeps the authoring model intact and still gives
    /// the corridor a real identity on the map.
    ///
    /// A pair of stops with no road between them lays no track and takes no
    /// lane. The line still runs — a tram route is not gated on road
    /// connectivity, the same way a bus route is not — it simply costs the
    /// street nothing where there is no street.
    static func tramTracks(in map: CityMap) -> Set<GridPosition> {
        let tramRoutes = map.transit.routes(mode: .tram)
        guard !tramRoutes.isEmpty else { return [] }
        let drivable = Set(map.tiles.filter { $0.zone == .road || $0.zone == .highway }.map(\.position))
        guard !drivable.isEmpty else { return [] }

        var tracks: Set<GridPosition> = []
        for route in tramRoutes {
            let stops = workingStops(of: route, in: map)
            guard stops.count >= TransitRoute.minimumStops else { continue }
            for (from, to) in zip(stops, stops.dropFirst()) {
                tracks.formUnion(roadRun(from: from, to: to, over: drivable, in: map))
            }
        }
        return tracks
    }

    /// The shortest road run between two stations, or nothing if the streets
    /// do not connect them.
    ///
    /// Plain breadth-first, and cheap: it runs once per *segment* of a tram
    /// line rather than once per home, so a city with four tram routes pays
    /// for a dozen searches against the thousands `Traffic.computeLoad`
    /// already runs.
    private static func roadRun(
        from origin: GridPosition, to destination: GridPosition,
        over drivable: Set<GridPosition>, in map: CityMap
    ) -> [GridPosition] {
        let starts = origin.orthogonalNeighbors().filter { drivable.contains($0) }.sortedByPosition()
        let targets = Set(destination.orthogonalNeighbors().filter { drivable.contains($0) })
        guard !starts.isEmpty, !targets.isEmpty else { return [] }

        var parent: [GridPosition: GridPosition] = [:]
        var seen = Set(starts)
        var queue = starts
        var head = 0
        var arrival: GridPosition?
        while head < queue.count {
            let current = queue[head]
            head += 1
            if targets.contains(current) { arrival = current; break }
            for neighbour in current.orthogonalNeighbors()
            where drivable.contains(neighbour) && !seen.contains(neighbour) {
                seen.insert(neighbour)
                parent[neighbour] = current
                queue.append(neighbour)
            }
        }
        guard var node = arrival else { return [] }
        var run = [node]
        while let step = parent[node] {
            run.append(step)
            node = step
        }
        return run
    }

    /// How much of a bus line's capacity fully jammed streets take away.
    static let busJamPenalty = 0.7

    /// And what it keeps regardless. A floor rather than nothing, for the same
    /// reason `Infrastructure.ruinedCapacityFraction` is one: a bus line
    /// pushing riders onto the roads that are jamming it is a loop, and
    /// without a floor it is a spiral with no bottom.
    static let busJamFloor = 0.3

    // MARK: - What a journey costs

    /// **Game minutes, not geographic ones.** A tile reads as about eight
    /// metres, which would make walking one of them seven seconds and every
    /// catchment free — and this map also fits a five-storey tower holding
    /// hundreds of people onto a 2×2 lot. The scale is abstracted, so these
    /// are calibrated against each other and against the decisions they are
    /// meant to create, not against a stopwatch.
    ///
    /// `Traffic.drivingMinutesPerTile` is deliberately **1.0**, so that at
    /// zero congestion a journey in minutes is numerically the journey in
    /// hops the job lottery used before. The change to minutes therefore
    /// moves nothing on an empty road, and every difference it does make is
    /// attributable to congestion or to transit rather than to a silent
    /// re-weighting of where people work.
    /// **Calibrated against one worked example, not against a stopwatch.**
    /// Take a cross-town commute of about twenty tiles on an empty road,
    /// which at `Traffic.drivingMinutesPerTile` is twenty-odd minutes by car:
    ///
    /// - a **bus** should land on roughly the same number, so it is a coin
    ///   flip on a clear road and wins outright the moment the street fills;
    /// - a **subway** should win it comfortably, because that is what the
    ///   price buys;
    /// - and **both should lose a five-tile trip**, because nobody waits for
    ///   a bus to go two blocks.
    ///
    /// The first values put walking and waiting at 12.5 minutes of a 22
    /// minute journey — over half the trip spent not moving — which made even
    /// a subway a coin flip across a whole city. The fixed overhead is what
    /// these numbers are really setting, and it has to be small against the
    /// ride or transit can never win anything.
    static let walkMinutesPerTile = 0.5

    /// What changing lines costs, on top of the walk between the two
    /// stations. This is the number that decides whether a network of short
    /// connecting lines beats one long one, so it is the main dial on how
    /// much a player is rewarded for building an interchange.
    static let transferPenaltyMinutes = 5.0

    /// How far apart two stations can be and still be one interchange.
    ///
    /// **An interchange is something the player builds**, by siting two
    /// stations near each other — there is no separate "interchange"
    /// building, and there does not need to be. Three tiles is close enough
    /// to read as deliberate on the map and too close to happen by accident.
    static let transferWalkDistance = 3

    /// Stamps every working route's catchment onto the tiles it covers.
    ///
    /// Cheap enough to call per tick and per hover: it is stations times
    /// catchment area, not anything that touches the whole map. If it ever
    /// shows up in a profile the answer is to cache it on `CityMap` the way
    /// `waterSupply` is — it is a pure function of the map, so that is a
    /// mechanical change rather than a design one.
    static func coverage(for map: CityMap) -> TransitCoverage {
        var nodes: [TransitCoverage.Node] = []
        var byTile: [GridPosition: [TransitCoverage.Reach]] = [:]

        for route in map.transit.routes {
            // Only stops that are still a station of this route's own kind.
            // A bus route does not call at a subway entrance, and a stop
            // whose station was bulldozed is a gap in the line rather than a
            // reason to throw the line away.
            let working = workingStops(of: route, in: map)
            guard working.count >= TransitRoute.minimumStops else { continue }

            let radius = catchment(for: route.mode)
            for (index, stop) in working.enumerated() {
                let node = nodes.count
                nodes.append(TransitCoverage.Node(
                    station: stop, route: route.id, mode: route.mode, stopIndex: index
                ))
                for cell in map.footprintCells(origin: stop, size: route.mode.stationZone.footprintSize) {
                    for dy in -radius ... radius {
                        for dx in -radius ... radius {
                            let target = GridPosition(x: cell.x + dx, y: cell.y + dy)
                            let walk = cell.manhattanDistance(to: target)
                            guard map.contains(target), walk <= radius else { continue }
                            // Nearest cell of the station wins, so a lot
                            // touching a stop walks nothing and one at the
                            // edge of the catchment walks the whole way. That
                            // difference is most of why a stop next door is
                            // worth more than a stop four blocks over, and
                            // the old index-only coverage could not express
                            // it at all.
                            if let existing = byTile[target]?.firstIndex(where: { $0.node == node }) {
                                if walk < byTile[target]![existing].walk {
                                    byTile[target]![existing].walk = walk
                                }
                            } else {
                                byTile[target, default: []].append(
                                    TransitCoverage.Reach(node: node, walk: walk)
                                )
                            }
                        }
                    }
                }
            }
        }
        return TransitCoverage(nodes: nodes, byTile: byTile)
    }

    /// The journey planner: every station-to-station cost in the city,
    /// transfers included, worked out once.
    static func graph(for map: CityMap, coverage: TransitCoverage) -> TransitGraph {
        TransitGraph(coverage: coverage, map: map)
    }
}

/// Which lines reach which tiles, and how far you walk to catch them.
///
/// Read-only from the outside — `Transit.coverage(for:)` is the only thing
/// that builds a non-empty one, the same "one place produces this, everything
/// else reads it" contract `TrafficLoad`, `WaterSupply` and `PowerSupply` all
/// already use.
struct TransitCoverage: Equatable, Sendable {

    /// One place you can board: a station, on a particular line.
    ///
    /// **A (station, line) pair rather than a station**, because that is what
    /// makes a transfer cost something. With a station as the node, riding
    /// through an interchange and changing lines there would be the same
    /// journey at the same price, and the whole point of an interchange is
    /// that changing is worse than not having to.
    struct Node: Equatable, Sendable {
        let station: GridPosition
        let route: TransitRoute.ID
        let mode: TransitRoute.Mode
        /// Position along its own line, which is what the diagram and the
        /// ride length are measured in.
        let stopIndex: Int
    }

    /// A boarding point within walking distance of a tile.
    struct Reach: Equatable, Sendable {
        let node: Int
        /// Tiles from here to the station — real walking, so a lot touching a
        /// stop pays nothing and one at the edge of the catchment pays for
        /// every tile.
        var walk: Int
    }

    private var nodes: [Node] = []
    private var byTile: [GridPosition: [Reach]] = [:]

    init() {}

    fileprivate init(nodes: [Node], byTile: [GridPosition: [Reach]]) {
        self.nodes = nodes
        self.byTile = byTile
    }

    var isEmpty: Bool { byTile.isEmpty }
    var nodeCount: Int { nodes.count }

    func node(_ index: Int) -> Node { nodes[index] }

    /// Is anything serving this tile — or, given a mode, anything of that kind?
    func isServed(at position: GridPosition, by mode: TransitRoute.Mode? = nil) -> Bool {
        guard let here = byTile[position], !here.isEmpty else { return false }
        guard let mode else { return true }
        return here.contains { nodes[$0.node].mode == mode }
    }

    func reaches(at position: GridPosition) -> [Reach] {
        byTile[position] ?? []
    }

    /// Everywhere a *building* can board, keeping the shortest walk from any
    /// of its cells — the rule every other coverage question in this game
    /// already uses (see `CitySimulator.hasSchooling`).
    func reaches(from cells: [GridPosition]) -> [Reach] {
        var best: [Int: Int] = [:]
        for cell in cells {
            for reach in reaches(at: cell) {
                best[reach.node] = Swift.min(best[reach.node] ?? reach.walk, reach.walk)
            }
        }
        // Sorted, because a tie in the journey search must not be broken by
        // dictionary order. `Traffic.reachableTiles` documents at length what
        // that cost this project the last time it happened.
        return best.sorted { $0.key < $1.key }.map { Reach(node: $0.key, walk: $0.value) }
    }
}

/// Every station-to-station journey in the city, priced in minutes.
///
/// **All-pairs, once**, rather than a search per trip. The graph is one node
/// per (station, line) pair — tens of them in a real city against thousands of
/// road tiles — so the whole table costs less than a single one of the
/// breadth-first searches `Traffic.computeLoad` already runs per home. That is
/// the arithmetic that made transfers affordable after they were once ruled
/// out as too expensive.
struct TransitGraph {

    /// A trip that rides, and what it cost.
    struct Journey: Equatable, Sendable {
        let minutes: Double
        /// The lines used, in order. Every one of them counts a boarding, so
        /// a two-leg trip puts a rider on two lines — which is what a
        /// per-line ridership figure means everywhere outside this game too.
        let legs: [TransitRoute.ID]

        var transfers: Int { Swift.max(0, legs.count - 1) }
    }

    private let coverage: TransitCoverage
    /// `cost[from][to]`, in minutes, riding and transferring only — the walk
    /// at each end and the wait to board are added per query, because they
    /// depend on where the traveller actually is.
    private var cost: [[Double]] = []
    /// `previous[from][to]`, for reading back which lines a journey used.
    private var previous: [[Int]] = []

    private static let unreachable = Double.infinity

    fileprivate init(coverage: TransitCoverage, map: CityMap) {
        self.coverage = coverage
        let count = coverage.nodeCount
        guard count > 0 else { return }

        // Two kinds of edge, and the difference between them is the whole
        // model: staying on a line costs time proportional to the ground
        // covered, and changing lines costs the walk plus a flat penalty for
        // having to wait all over again.
        var edges = [[(node: Int, minutes: Double)]](repeating: [], count: count)
        for a in 0 ..< count {
            let from = coverage.node(a)
            for b in 0 ..< count where a != b {
                let to = coverage.node(b)
                if from.route == to.route {
                    // Consecutive stops only. A line is a sequence, so riding
                    // from stop 0 to stop 4 has to pass through 1, 2 and 3 —
                    // letting it jump would price an express service nobody
                    // built.
                    guard abs(from.stopIndex - to.stopIndex) == 1 else { continue }
                    let tiles = Double(from.station.manhattanDistance(to: to.station))
                    edges[a].append((b, tiles * from.mode.minutesPerTile))
                } else {
                    let walk = from.station.manhattanDistance(to: to.station)
                    guard walk <= Transit.transferWalkDistance else { continue }
                    edges[a].append((b, Double(walk) * Transit.walkMinutesPerTile
                        + Transit.transferPenaltyMinutes
                        + to.mode.boardingWaitMinutes))
                }
            }
        }

        cost = [[Double]](repeating: [Double](repeating: Self.unreachable, count: count), count: count)
        previous = [[Int]](repeating: [Int](repeating: -1, count: count), count: count)
        for source in 0 ..< count {
            dijkstra(from: source, over: edges, count: count)
        }
    }

    /// Plain O(n²) Dijkstra — no heap, because `n` here is the number of
    /// (station, line) pairs in the city and a heap would cost more in
    /// indirection than it saves in comparisons at this size.
    private mutating func dijkstra(from source: Int, over edges: [[(node: Int, minutes: Double)]], count: Int) {
        var settled = [Bool](repeating: false, count: count)
        cost[source][source] = 0
        for _ in 0 ..< count {
            var current = -1
            var best = Self.unreachable
            for candidate in 0 ..< count where !settled[candidate] && cost[source][candidate] < best {
                best = cost[source][candidate]
                current = candidate
            }
            guard current >= 0 else { break }
            settled[current] = true
            for edge in edges[current] {
                let relaxed = best + edge.minutes
                if relaxed < cost[source][edge.node] {
                    cost[source][edge.node] = relaxed
                    previous[source][edge.node] = current
                }
            }
        }
    }

    var isEmpty: Bool { cost.isEmpty }

    /// The fastest way to get from one building to another by transit, or
    /// `nil` if there is none.
    ///
    /// The walk at each end and the wait to board are added here rather than
    /// baked into the table, because they are properties of the traveller's
    /// position rather than of the network.
    func journey(from origin: [TransitCoverage.Reach], to destination: [TransitCoverage.Reach]) -> Journey? {
        guard !cost.isEmpty, !origin.isEmpty, !destination.isEmpty else { return nil }
        var bestMinutes = Self.unreachable
        var bestPair: (Int, Int)?
        for start in origin {
            let boarding = Double(start.walk) * Transit.walkMinutesPerTile
                + coverage.node(start.node).mode.boardingWaitMinutes
            for end in destination {
                let ride = cost[start.node][end.node]
                guard ride < Self.unreachable else { continue }
                let total = boarding + ride + Double(end.walk) * Transit.walkMinutesPerTile
                // Strictly less, and the arrays are in node order, so an
                // exact tie always resolves to the lower-numbered pair rather
                // than to whichever the iteration reached first.
                if total < bestMinutes {
                    bestMinutes = total
                    bestPair = (start.node, end.node)
                }
            }
        }
        guard let (start, end) = bestPair else { return nil }
        return Journey(minutes: bestMinutes, legs: legs(from: start, to: end))
    }

    /// Which lines a journey actually boards, read back from the search.
    ///
    /// Each *change* of route is a boarding, and the first node is always
    /// one — so a trip that stays on one line reports one leg and a trip that
    /// changes once reports two.
    private func legs(from start: Int, to end: Int) -> [TransitRoute.ID] {
        var chain = [end]
        var node = end
        while node != start {
            let step = previous[start][node]
            guard step >= 0 else { break }
            chain.append(step)
            node = step
        }
        var used: [TransitRoute.ID] = []
        for node in chain.reversed() {
            let route = coverage.node(node).route
            if used.last != route { used.append(route) }
        }
        return used
    }
}
