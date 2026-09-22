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
/// **A commute that can ride does not drive.** Where one of the player's
/// transit routes serves both a home and the job its residents commute to,
/// the trip rides it: no road load anywhere along the way, and the route
/// counts the riders. That is the one thing transit does to this file, and it
/// is deliberately the only thing — the job lottery is untouched, so a bus
/// line changes how people get to work and not who employs them. See
/// `Transit` for the coverage index and the no-transfer rule.
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
        /// Every cell the building occupies — what transit coverage is asked
        /// about, since a line reaches a *place*, not a driveway.
        let cells: [GridPosition]

        /// The drivable tiles it fronts. Empty for a job reachable only by
        /// transit, which is a real state now that a route can carry a
        /// commute: such a site simply never appears among the driving
        /// candidates, because no path reaches it.
        let frontage: Set<GridPosition>

        /// The same cells, in the order ties are broken in.
        ///
        /// **Sorted once per job rather than once per (home, job) pair**, and
        /// it is worth saying why it needed saying. The `reach` below already
        /// carries a comment about being computed once per job "which is what
        /// keeps the transit half of the inner loop to a handful of array
        /// reads" — and the *driving* half never got the same treatment. It
        /// called `frontage.sortedByPosition()` inside the loop, so a city of
        /// 233 homes and 200 jobs re-sorted the same unchanging sets about
        /// forty-six thousand times a tick.
        ///
        /// The sort is not decoration: when two frontage cells are
        /// equidistant, `min(by:)` keeps whichever it saw first, and `Set`
        /// iteration order is not stable between two sets holding the same
        /// elements — which is how `computeLoad` was once non-deterministic.
        /// The order has to be fixed; it just does not have to be *re*-fixed
        /// for every home in the city.
        let sortedFrontage: [GridPosition]

        /// Where someone arriving by transit gets off, and how far they then
        /// walk. Computed once per job rather than once per (home, job) pair,
        /// which is what keeps the transit half of the inner loop to a
        /// handful of array reads.
        let reach: [TransitCoverage.Reach]

        /// Time on top of the journey to this site. Zero for a building; for
        /// the region it is the off-map half of the trip, without which a
        /// regional terminus would read as a job sitting right there.
        let extraMinutes: Double

        /// Is this the region rather than a building in the city? The one
        /// thing the loop below needs to know it apart for, since a trip to
        /// the region is still a trip and still rides a line.
        let isOutsideTheCity: Bool
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

    /// How long one tile of empty road takes to drive.
    ///
    /// **Exactly 1.0, and that is a measurement decision.** The job lottery
    /// used to weigh candidates by road hops; it now weighs them by minutes,
    /// and at this value the two are numerically identical on an empty road.
    /// So moving to minutes moves *nothing* by itself, and every difference
    /// it makes is attributable to congestion or to transit rather than to a
    /// silent re-weighting of where the city works. Change it and that
    /// property goes with it.
    static let drivingMinutesPerTile = 1.0

    /// How much slower a fully jammed tile is than an empty one — at 2.0, a
    /// tile at capacity takes three minutes instead of one.
    ///
    /// This is the number that makes transit worth building. Driving gets
    /// slower as the roads fill, so trips move onto the lines, so the roads
    /// empty — a loop the module did not have while transit was taken
    /// whenever it was merely *available* rather than when it was faster.
    static let congestionDelay = 2.0

    /// How much a jam slows this home's driving, from the streets it fronts.
    ///
    /// **Measured at the doorstep rather than along the route**, which is an
    /// approximation and a deliberate one. The exact answer needs the
    /// congestion of every tile on the path, and the path is only known once
    /// a job has been chosen — while the congestion is one of the things
    /// deciding *which* job. Running a weighted search per home instead of a
    /// plain breadth-first one would make the most expensive loop in the game
    /// several times more expensive to buy a second decimal place.
    ///
    /// It also reads correctly as a story: the street outside your house is
    /// jammed, so you take the bus. A driver on a quiet cul-de-sac who joins
    /// a jammed arterial two tiles later is undercharged, and that is the
    /// error this accepts.
    private static func drivingDelay(atFrontage frontage: Set<GridPosition>, in map: CityMap) -> Double {
        guard !frontage.isEmpty else { return 1 }
        let jam = frontage.reduce(0.0) { $0 + congestion(at: $1, in: map) } / Double(frontage.count)
        return 1 + jam * congestionDelay
    }

    /// A `.highway` tile's whole reason to cost 4x a plain road: it
    /// absorbs twice the routed commute load before feeling as congested.
    /// Same shape of ceiling as `capacityPerRoadTile`, just a bigger one —
    /// not a different formula, so a highway isn't "immune" to traffic,
    /// just harder to actually jam.
    private static let highwayCapacityMultiplier = 2.0

    /// How much of a street's capacity a tram line running down it takes.
    ///
    /// **The only thing in this game that makes a transit building cost the
    /// road something.** Every other mode is a pure addition: build it, and
    /// trips move off the street. A tram takes a lane to put its rails in, so
    /// the corridor it relieves is also the corridor it narrows — and that
    /// is what turns "which mode" from a price comparison into a placement
    /// decision. Put a tram down your busiest arterial and you may find you
    /// have made it worse.
    ///
    /// A quarter, so a tram has to carry more than a quarter of a street's
    /// traffic to be worth running down it. Under that it is a tax on the
    /// corridor; over it, a bargain.
    static let tramLaneShare = 0.25

    /// Is this a tile that carries road traffic — a plain `.road` or the
    /// higher-capacity `.highway`? Shared by `congestion(at:in:)` (deciding
    /// whether a tile has congestion at all), `computeLoad(for:)` (deciding
    /// what counts as part of the drivable network), and
    /// `isHorizontallyOriented(at:in:)` (deciding what counts as a "road
    /// neighbor" for orienting the ambient traffic animation) — one
    /// definition of "road-like," not three that could drift apart.
    /// Not `private`: the renderer asks the same question, because a kerb is
    /// drawn where a street stops and "is this a street" must have exactly one
    /// answer on both sides of the simulation/rendering split.
    static func isRoadLike(_ zone: ZoneType) -> Bool {
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
        let designed = zone == .highway ? capacityPerRoadTile * highwayCapacityMultiplier : capacityPerRoadTile
        // A worn road carries less than it was built to. That closes a loop on
        // purpose — less capacity means more congestion, and congestion is
        // what wears a road out (see `Infrastructure.congestionWearPerTick`)
        // — so a neglected arterial degrades faster the worse it gets.
        // `Infrastructure.ruinedCapacityFraction` is the floor that keeps that
        // spiral recoverable rather than terminal.
        // And a tram running down it has taken a lane to lay rails in — see
        // `tramLaneShare`, which is the one place a transit building costs
        // the road network anything.
        let lanes = map.tramTracks.contains(position) ? 1 - tramLaneShare : 1
        let capacity = designed * Infrastructure.capacityFraction(of: map[position]) * lanes
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
    ///
    /// **Transit is a way of getting there, weighed against driving.** Every
    /// candidate job carries how long it takes by car and how long by line,
    /// and the faster one wins — so a bus that goes the long way round loses
    /// to a short drive, and wins the same trip once the street jams. See
    /// `Transit` for the journey planner, and this file's top comment for the
    /// loop that creates.
    /// Everything about one home's commute that does not depend on what any
    /// other home chose.
    ///
    /// **This split is what lets the expensive part use more than one core.**
    /// Working out what every job would cost this household reads only the
    /// road network, the transit graph and the job sites — all fixed for the
    /// duration of a tick — so it is independent per home. What is *not*
    /// independent is the assignment: a job has room for a limited number of
    /// people and a line has seats, so whether this home can take a place
    /// depends on who was served before it.
    ///
    /// Splitting the loop in two along that line leaves the costly half
    /// parallel and the sequential half cheap. It also leaves the sequential
    /// half in exactly the order it ran in before, which is what keeps the
    /// result identical: `chooseJob` is seeded from the home's own position
    /// rather than from a shared generator, so nothing about the outcome
    /// depends on which core got there first.
    private struct HomeRouting {
        let tile: Tile
        /// What every job would cost this home, *before* capacity is
        /// considered. Filtering by room has to happen during assignment,
        /// because that is the only place the answer is known.
        let candidates: [JobCandidate]
        /// The search tree this home's drive was measured over, kept so the
        /// chosen route can be walked once the job is settled.
        let parents: [GridPosition: GridPosition]
    }

    /// Below this many homes, spreading the work costs more than it saves.
    ///
    /// **Gated on the size of the problem, not on the size of the machine.**
    /// `DispatchQueue.concurrentPerform` already adapts to however many cores
    /// it finds — this binary runs on every Apple Silicon Mac from a
    /// four-plus-four M1 to a sixteen-core Max, and nothing here should know
    /// which. What it does need to know is that handing out forty homes costs
    /// more in scheduling than doing them here.
    ///
    /// Not `private`, so a test can force both paths on one city and compare
    /// them. Making the hottest function in the game concurrent without
    /// proving the two routes agree would be the least defensible change in
    /// this project.
    static var parallelRoutingThreshold = 64

    /// Works out what each job would cost one home. Pure: it reads the world
    /// and writes nothing, which is the whole reason it can run anywhere.
    /// - Parameter arrivals: each job's end of the transit journey, collapsed
    ///   once by the caller. It does not vary with the home, and pairing the
    ///   boarding points at both ends *inside* this loop is what made the
    ///   journey lookup 46% of `computeLoad`. Same move `sortedFrontage`
    ///   makes for the drive.
    private static func route(
        home tile: Tile, in map: CityMap, drivable: Set<GridPosition>,
        coverage: TransitCoverage, network: TransitGraph, jobs: [JobSite],
        arrivals: [TransitGraph.Arrivals?]
    ) -> HomeRouting? {
        let homeCells = map.footprintCells(origin: tile.position, size: tile.zone.footprintSize)
        let homeReach = coverage.reaches(from: homeCells)
        let homeFrontage = frontage(ofFootprint: tile.position,
                                    size: tile.zone.footprintSize, in: map, drivable: drivable)
        guard !homeFrontage.isEmpty || !homeReach.isEmpty else {
            return nil // no street and no line: this block generates no trips
        }

        // The *whole* reachable network from this home, not just the nearest
        // job — the lottery needs every reachable candidate's cost to weigh
        // against each other, which stopping early at the first job with room
        // (the original approach) cannot provide.
        var parents: [GridPosition: GridPosition] = [:]
        var hops: [GridPosition: Int] = [:]
        if !homeFrontage.isEmpty {
            let reachable = reachableTiles(from: homeFrontage, over: drivable)
            parents = reachable.parent
            hops = reachable.distance
        }
        let delay = drivingDelay(atFrontage: homeFrontage, in: map)

        var candidates: [JobCandidate] = []
        candidates.reserveCapacity(jobs.count)
        for (index, job) in jobs.enumerated() {
            // A job can front more than one drivable tile; this home's
            // distance to it is the closest of those it actually reached.
            // `sortedFrontage` rather than the `Set`: when two frontage cells
            // are equidistant, `min(by:)` keeps whichever it saw first, so
            // `Set` iteration order would decide the route — and that is not
            // stable between two `Set` instances holding the same elements.
            // See `reachableTiles(from:over:)` for the full story.
            let nearest = job.sortedFrontage
                .compactMap { cell in hops[cell].map { (cell, $0) } }
                .min { $0.1 < $1.1 }
            let drive = nearest.map {
                (minutes: Double($0.1) * drivingMinutesPerTile * delay + job.extraMinutes,
                 frontageCell: $0.0)
            }
            let ride = arrivals[index]
                .flatMap { network.ride(from: homeReach, to: $0) }
                .map { (minutes: $0.minutes + job.extraMinutes, start: $0.start, end: $0.end) }
            guard let best = [drive?.minutes, ride?.minutes].compactMap({ $0 }).min() else { continue }
            candidates.append(JobCandidate(jobIndex: index, minutes: best, drive: drive, ride: ride))
        }
        return HomeRouting(tile: tile, candidates: candidates, parents: parents)
    }

    static func computeLoad(for map: CityMap) -> TrafficLoad {
        let drivable = Set(map.tiles.filter { isRoadLike($0.zone) }.map(\.position))
        let coverage = Transit.coverage(for: map)
        guard !drivable.isEmpty || !coverage.isEmpty else { return TrafficLoad() }
        let network = Transit.graph(for: map, coverage: coverage)

        var load = TrafficLoad()
        // Routed *before* the early return below, so a city with housing and
        // no jobs reports its homes as jobless rather than as unknown — which
        // is the single most useful thing the inspector can say about a city
        // that has only zoned housing.
        load.beginRouting()

        var jobs = jobSites(in: map, drivable: drivable, coverage: coverage)
        guard !jobs.isEmpty else { return load }

        // What each line can still carry today. Drawn down as trips are
        // assigned, exactly the way a job site's room is — a full line stops
        // being an option and its would-be riders drive instead, which is the
        // pressure that makes a second line or a subway worth paying for.
        var seats: [TransitRoute.ID: Int] = [:]
        for route in map.transit.routes {
            seats[route.id] = Transit.dailyCapacity(of: route, in: map)
        }

        // **Phase one: what every commute would cost, worked out in
        // parallel.** Nothing here reads how much room is left anywhere, so
        // no home's answer depends on any other home's — see `HomeRouting`.
        let homes = map.tiles.filter {
            $0.isBuildingAnchor && $0.zone == .residential && $0.density > 0
        }
        let fixedJobs = jobs   // read-only for the duration of phase one
        // Collapsed once per job rather than once per (home, job) pair. See
        // `TransitGraph.Arrivals` for what that is worth and why it is safe.
        let arrivals = fixedJobs.map { network.arrivals(to: $0.reach) }
        var routings = [HomeRouting?](repeating: nil, count: homes.count)
        if homes.count >= parallelRoutingThreshold {
            routings.withUnsafeMutableBufferPointer { buffer in
                DispatchQueue.concurrentPerform(iterations: homes.count) { index in
                    buffer[index] = route(home: homes[index], in: map, drivable: drivable,
                                          coverage: coverage, network: network, jobs: fixedJobs,
                                          arrivals: arrivals)
                }
            }
        } else {
            for index in homes.indices {
                routings[index] = route(home: homes[index], in: map, drivable: drivable,
                                        coverage: coverage, network: network, jobs: fixedJobs,
                                        arrivals: arrivals)
            }
        }

        // **Phase two: who actually gets the place, in the order they always
        // were.** A job has room for so many people and a line has so many
        // seats, so this half has to stay sequential — and staying in the
        // original order is what keeps the result bit-for-bit what it was.
        for routing in routings {
            guard let routing else { continue }
            let tile = routing.tile
            let parents = routing.parents
            // Room is only known here, which is why the filter is here rather
            // than in the costing. The set this leaves is exactly the set the
            // single loop used to build.
            let candidates = routing.candidates.filter {
                jobs[$0.jobIndex].remainingCapacity > 0
            }
            guard let chosen = chooseJob(from: candidates, homeSeed: tile.position) else { continue } // no reachable job has room
            // **The router already knew this and was discarding it.** Whether
            // a home found work is decided right here, on the line above, and
            // until now nothing kept the answer — so "can the people who live
            // here reach a job?" was a question the simulation computed every
            // tick and could not be asked. It is the one thing about a
            // residential lot that no overlay shows and no other field
            // implies.
            load.recordEmployed(tile.position)

            // **The legs, built here and nowhere else.** Working out which
            // lines a trip boards walks the predecessor chain and allocates,
            // and phase one asked for a journey once per (home, job) pair —
            // 48,000 times a tick on a built-out city, for an answer only the
            // winner ever needed. One home, one call.
            let ride = chosen.ridesTransit
                ? chosen.ride.map { network.journey(minutes: $0.minutes,
                                                    from: $0.start, to: $0.end) }
                : nil
            load.recordCommute(
                TrafficLoad.Commute(
                    minutes: chosen.minutes,
                    boarding: ride?.legs.first,
                    transfers: ride?.transfers ?? 0
                ),
                at: tile.position
            )

            // **People, not density units.** Road load is an abstract weight
            // and density is the right currency for it; ridership is a number
            // the player reads, and "31 riders/day" for a line serving a
            // neighbourhood of hundreds reads as broken. Same conversion
            // `GameController.population` uses, so the two agree.
            let riders = tile.density * ZoneType.residential.populationPerDensityLevel
            let ridesWithRoom = ride?.legs.allSatisfy { seats[$0, default: 0] > 0 } ?? false

            if ridesWithRoom, let ride {
                // **Every leg counts a boarding.** A trip that changes from a
                // bus to a subway puts a rider on both lines, which is what a
                // per-line ridership figure means everywhere outside this game
                // too — and what makes a feeder line's number reflect the work
                // it is actually doing.
                for leg in ride.legs {
                    load.recordRiders(riders, on: leg)
                    // Claimed after the fact and allowed to overshoot by one
                    // home's worth, the same way a job site's room is:
                    // splitting a single building's commute across two lines
                    // is detail this aggregate model deliberately does not
                    // carry.
                    seats[leg, default: 0] -= riders
                }
            } else if let destination = chosen.drive?.frontageCell {
                // Either driving was faster, or the line that would have been
                // faster is full. A full line turns the trip onto the road
                // rather than rerouting it around the jam — rerouting would
                // need a search per trip against a table built without that
                // line, and in the aggregate the answer is the same: this
                // trip is not on transit.
                let path = reconstructPath(to: destination, parent: parents)
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
            }
            // Claimed *after* routing, by the home's own density — a
            // level-5 home uses five times the room a level-1 home does,
            // the same weight it contributes to road load.
            jobs[chosen.jobIndex].remainingCapacity -= tile.density
        }
        return load
    }

    /// One job a home could take, and the best way of getting there.
    ///
    /// **One currency, minutes.** This used to carry a `distance` that meant
    /// road hops for a driving candidate and stops-along-a-line for a riding
    /// one, and the two were never allowed into the same lottery because they
    /// could not be compared — a road-fronted home picked jobs by hops and a
    /// transit-only one by stops, in separate code paths that never met. That
    /// split was tolerable with one line between two places and is untenable
    /// with a network: "is this journey any good" has one answer, and it is
    /// how long it takes.
    private struct JobCandidate {
        let jobIndex: Int

        /// The fastest way there, whichever mode that is — what the lottery
        /// weighs.
        let minutes: Double

        /// Driving it, if the roads reach: how long, and where on the network
        /// the trip ends.
        let drive: (minutes: Double, frontageCell: GridPosition)?

        /// Riding it, if the network reaches: how long, and the two nodes it
        /// runs between. **Not which lines it boards** — see
        /// `TransitGraph.ride(from:to:)` for why that is deferred to the one
        /// job this home actually takes.
        let ride: (minutes: Double, start: Int, end: Int)?

        /// Which one actually happens. **Driving takes an exact tie**,
        /// because a journey that is no faster is not worth a walk and a
        /// wait — and because it keeps a network with no advantage from
        /// silently emptying the roads.
        var ridesTransit: Bool {
            guard let ride else { return false }
            guard let drive else { return true }
            return ride.minutes < drive.minutes
        }
    }

    /// Which job a home actually commutes to: a distance-weighted lottery
    /// among every candidate with room, not always the nearest one — see
    /// this file's own top-of-file doc comment for why. Weight is
    /// `1 / (distance + 1)`, so a job twice as far is half as likely to be
    /// drawn rather than simply less likely by some unbounded amount — near
    /// jobs still win more often in aggregate, they just aren't the *only*
    /// possible outcome the way "always nearest" made them.
    ///
    /// Weight is `1 / (minutes + 1)`, which at
    /// `drivingMinutesPerTile` of 1.0 and an empty road is *numerically the
    /// same* weighting the old hop count produced — so moving the lottery to
    /// minutes moved nothing by itself, and every difference it makes comes
    /// from congestion or from a faster transit option.
    ///
    /// The draw itself is `pseudoRandomUnitValue(for:)`, seeded from the
    /// home's own position rather than `GameController`'s shared RNG — the
    /// same "stable per-lot, not re-rolled every tick" shape
    /// `NeonStyle.variant(for:optionCount:)` already uses to pick a
    /// building's look. A home keeps commuting to the same job tick after
    /// tick unless the map itself changes (a road, a job filling up),
    /// rather than its ambient traffic car flickering to a new destination
    /// on a clock it has no reason to change.
    private static func chooseJob(from candidates: [JobCandidate], homeSeed: GridPosition) -> JobCandidate? {
        guard !candidates.isEmpty else { return nil }
        let weights = candidates.map { 1.0 / ($0.minutes + 1) }
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
    /// hash function (same disclaimer `NeonStyle.variant(for:optionCount:)`
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
    private static func jobSites(
        in map: CityMap, drivable: Set<GridPosition>, coverage: TransitCoverage
    ) -> [JobSite] {
        var sites: [JobSite] = []
        for tile in map.tiles where tile.isBuildingAnchor && (tile.zone == .commercial || tile.zone == .industrial) && tile.density > 0 {
            // A site with no road frontage used to be dropped here as "not a
            // reachable job at all", which stopped being true the moment a
            // route could carry someone to it. It is kept and left
            // unreachable by car instead — no path reaches an empty frontage,
            // so the driving lottery skips it exactly as before.
            let cells = map.footprintCells(origin: tile.position, size: tile.zone.footprintSize)
            let siteFrontage = frontage(ofFootprint: tile.position,
                                        size: tile.zone.footprintSize,
                                        in: map, drivable: drivable)
            sites.append(JobSite(
                cells: cells,
                frontage: siteFrontage,
                sortedFrontage: siteFrontage.sortedByPosition(),
                reach: coverage.reaches(from: cells),
                extraMinutes: 0,
                isOutsideTheCity: false,
                remainingCapacity: tile.density * jobCapacityPerDensityLevel
            ))
        }

        // **The region, as a job site you cannot drive to.**
        //
        // Modelled as one more entry in this list rather than as a branch in
        // the loop below, which is what makes it cost almost nothing: every
        // rule already here — the lottery, the capacity draw-down, riding
        // versus driving, ridership per leg — applies to it unchanged. Its
        // frontage is deliberately empty, so no path ever reaches it and the
        // only way out of the city is the train. There are no off-map roads
        // in this game, and making the rail the sole way out is what gives a
        // regional connection its point.
        let outside = Transit.outsideJobs(in: map)
        if outside > 0 {
            let termini = Transit.regionalTermini(in: map)
            let cells = termini.flatMap {
                map.footprintCells(origin: $0, size: TransitRoute.Mode.rail.stationZone.footprintSize)
            }
            sites.append(JobSite(
                cells: cells,
                frontage: [],
                sortedFrontage: [],
                reach: coverage.reaches(from: cells),
                extraMinutes: Transit.outsideCommuteMinutes,
                isOutsideTheCity: true,
                // Held in the same density units every other site's room is,
                // so the draw-down below needs no special case.
                remainingCapacity: outside / ZoneType.residential.populationPerDensityLevel
            ))
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
    /// picks for orienting the ambient traffic animation. The renderer
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

    /// Homes whose commute found a job with room, by building anchor.
    ///
    /// `Optional` for save compatibility rather than for meaning: `CityMap`
    /// decodes through the synthesised `Codable` conformance, which throws on
    /// a missing key, so every non-optional field added here breaks saves
    /// written before it (see `CitySave.minimumSupportedFormatVersion`). This
    /// one is genuinely optional anyway — a map that has never had
    /// `computeLoad` run against it does not know who is employed, and `nil`
    /// says exactly that rather than claiming everyone is jobless.
    private var employedHomes: Set<GridPosition>?

    /// How long the commute from this building takes, and on what.
    ///
    /// **The router already knows this and used to throw it away**, exactly
    /// as it once threw away whether a job was found at all. It is now the
    /// single most legible thing the inspector can say about a house — "18
    /// minutes to work, by bus" is a sentence a player understands without
    /// being taught anything about the model, and it is the only place the
    /// mode decision surfaces at all.
    private var commutesByHome: [GridPosition: Commute]?

    struct Commute: Equatable, Codable, Sendable {
        let minutes: Double
        /// The line a rider boards first, or `nil` for a drive.
        let boarding: TransitRoute.ID?
        let transfers: Int
    }

    func commute(at position: GridPosition) -> Commute? {
        commutesByHome?[position]
    }

    fileprivate mutating func recordCommute(_ commute: Commute, at position: GridPosition) {
        commutesByHome = commutesByHome ?? [:]
        commutesByHome?[position] = commute
    }

    /// Did the people living at this building find work they can reach?
    ///
    /// `nil` when no routing has happened yet — a fresh map, or one built by
    /// hand in a test. Records the *successes* rather than the failures on
    /// purpose: a city with no jobs at all returns early from `computeLoad`
    /// before any home is considered, and a set of failures would come back
    /// empty and report full employment.
    func commuteFound(at position: GridPosition) -> Bool? {
        employedHomes.map { $0.contains(position) }
    }

    /// How many riders each route carried, by route id.
    ///
    /// **A day's ridership, with no conversion anywhere**, because one tick is
    /// one day (`CityDate`) — the number the player reads is the number the
    /// router produced.
    ///
    /// `Optional` for the same save-compatibility reason `employedHomes` is,
    /// and genuinely optional for the same reason too: a map that has never
    /// been routed does not know what its lines carried, and `nil` says that
    /// rather than claiming every route is empty.
    ///
    /// Kept here, on the routing *result*, rather than on `TransitNetwork`
    /// beside the routes themselves. Ridership is an output; the route is
    /// state the player authored. Storing it on the route would mean editing
    /// a line carried a stale number along with it, and would put a value
    /// that changes every tick into the thing that is saved.
    private var ridershipByRoute: [TransitRoute.ID: Int]?

    /// How many people rode this line today, or `nil` if routing has not run.
    func ridership(onRoute id: TransitRoute.ID) -> Int? {
        ridershipByRoute.map { $0[id, default: 0] }
    }

    /// How many people rode anything today, or `nil` if routing has not run.
    var totalRidership: Int? {
        ridershipByRoute.map { $0.values.reduce(0, +) }
    }

    fileprivate mutating func recordRiders(_ amount: Int, on route: TransitRoute.ID) {
        ridershipByRoute = ridershipByRoute ?? [:]
        ridershipByRoute?[route, default: 0] += amount
    }

    /// Marks that routing ran, so "nobody found work" is distinguishable
    /// from "nobody has looked yet".
    fileprivate mutating func beginRouting() {
        employedHomes = employedHomes ?? []
        ridershipByRoute = ridershipByRoute ?? [:]
    }

    fileprivate mutating func recordEmployed(_ position: GridPosition) {
        employedHomes = (employedHomes ?? []).union([position])
    }

    /// A load with every road in `map` at capacity.
    ///
    /// For tests only, and it earns its place: `Transit.dailyCapacity` reads
    /// congestion to decide how badly a bus line is slowed, and the only other
    /// way to produce a jam is to build a city that jams — which would
    /// re-measure the router rather than pin the *response* to it.
    static func jammed(everyRoadIn map: CityMap) -> TrafficLoad {
        loaded(10_000, everyRoadIn: map)
    }

    /// The same, at a chosen load — for the tram's lane, where the whole
    /// point is that a *partly* loaded street gets worse rather than that a
    /// saturated one stays saturated. `congestion` clamps at 1, so a jammed
    /// street cannot show a capacity change at all.
    static func loaded(_ amount: Int, everyRoadIn map: CityMap) -> TrafficLoad {
        var load = TrafficLoad()
        for tile in map.tiles where tile.zone == .road || tile.zone == .highway {
            load.loadByTile[tile.position] = amount
        }
        return load
    }

    fileprivate mutating func add(_ amount: Int, at position: GridPosition, heading: GridPosition?) {
        loadByTile[position, default: 0] += amount
        guard let heading else { return }
        if heading.x != 0 { netHeadingXByTile[position, default: 0] += amount * heading.x }
        if heading.y != 0 { netHeadingYByTile[position, default: 0] += amount * heading.y }
    }
}
