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
/// **Ridership is an index lookup, not a search**, and that is the decision
/// that makes the whole feature affordable. `Traffic.computeLoad` is already
/// ~90% of a tick because it runs a breadth-first search per home; a transit
/// model that searched a second network per trip would double the most
/// expensive thing in the game. Instead every station stamps its catchment
/// once, and asking "can these two places ride the same line?" is a dictionary
/// lookup and a set intersection.
///
/// **No transfers.** A trip rides when *one* route serves both ends.
/// Multi-leg journeys are a routing problem in their own right — which line
/// to change to, where, and at what cost in time — and it would dominate the
/// work of the module while being nearly invisible next to the thing a player
/// actually watches, which is whether their line is carrying anyone. Stated
/// once, in `connection(from:to:)`, rather than assumed in several places.
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

    static func catchment(for mode: TransitRoute.Mode) -> Int {
        switch mode {
        case .bus: return busCatchment
        case .subway: return subwayCatchment
        }
    }

    /// Stamps every working route's catchment onto the tiles it covers.
    ///
    /// Cheap enough to call per tick and per hover: it is stations times
    /// catchment area, not anything that touches the whole map. If it ever
    /// shows up in a profile the answer is to cache it on `CityMap` the way
    /// `waterSupply` is — it is a pure function of the map, so that is a
    /// mechanical change rather than a design one.
    static func coverage(for map: CityMap) -> TransitCoverage {
        var byTile: [GridPosition: [TransitRoute.ID: Int]] = [:]
        var modes: [TransitRoute.ID: TransitRoute.Mode] = [:]

        for route in map.transit.routes {
            // Only stops that are still a station of this route's own kind.
            // A bus route does not call at a subway entrance, and a stop
            // whose station was bulldozed is a gap in the line rather than a
            // reason to throw the line away.
            let working = route.stops.filter { stop in
                map.contains(stop)
                    && map[stop].isBuildingAnchor
                    && map[stop].zone == route.mode.stationZone
            }
            guard working.count >= TransitRoute.minimumStops else { continue }

            let radius = catchment(for: route.mode)
            for (index, stop) in working.enumerated() {
                for cell in map.footprintCells(origin: stop, size: route.mode.stationZone.footprintSize) {
                    for dy in -radius ... radius {
                        for dx in -radius ... radius {
                            let target = GridPosition(x: cell.x + dx, y: cell.y + dy)
                            guard map.contains(target),
                                  cell.manhattanDistance(to: target) <= radius else { continue }
                            // Nearest stop wins where two stops of one line
                            // both reach a tile: a rider boards at the stop
                            // they are standing next to, and counting the
                            // far one would make the line read as longer
                            // than it is.
                            let existing = byTile[target]?[route.id]
                            if existing == nil { byTile[target, default: [:]][route.id] = index }
                        }
                    }
                }
            }
            modes[route.id] = route.mode
        }
        return TransitCoverage(byTile: byTile, modeByRoute: modes)
    }
}

/// Which routes reach which tiles, and at which stop.
///
/// Read-only from the outside — `Transit.coverage(for:)` is the only thing
/// that builds a non-empty one, the same "one place produces this, everything
/// else reads it" contract `TrafficLoad`, `WaterSupply` and `PowerSupply` all
/// already use.
struct TransitCoverage: Equatable, Sendable {

    /// tile -> (route id -> index of the nearest stop of that route).
    private var byTile: [GridPosition: [TransitRoute.ID: Int]] = [:]

    /// Which kind of line each id belongs to.
    ///
    /// Carried here rather than left for callers to look up on the network,
    /// because the alternative was a `mode:` parameter on
    /// `Transit.coverage(for:)` — and then every caller would hold a coverage
    /// silently filtered to one mode, with nothing stopping the Bus overlay
    /// from being handed the subway's. Routing wants all of it (a trip rides
    /// whatever serves both ends) and the overlays want one at a time, so the
    /// filtering belongs at the point of the question.
    private var modeByRoute: [TransitRoute.ID: TransitRoute.Mode] = [:]

    init() {}

    fileprivate init(
        byTile: [GridPosition: [TransitRoute.ID: Int]],
        modeByRoute: [TransitRoute.ID: TransitRoute.Mode]
    ) {
        self.byTile = byTile
        self.modeByRoute = modeByRoute
    }

    var isEmpty: Bool { byTile.isEmpty }

    /// Is anything serving this tile — or, given a mode, anything of that kind?
    func isServed(at position: GridPosition, by mode: TransitRoute.Mode? = nil) -> Bool {
        guard let here = byTile[position] else { return false }
        guard let mode else { return true }
        return here.keys.contains { modeByRoute[$0] == mode }
    }

    /// Every route reaching this tile, and how far along each one it is.
    func stops(at position: GridPosition) -> [TransitRoute.ID: Int] {
        byTile[position] ?? [:]
    }

    /// The same, for a whole building — a 2×2 block counts as served if any
    /// of its cells is, which is the rule every other coverage question in
    /// this game already uses (see `CitySimulator.hasSchooling`).
    func stops(reaching cells: [GridPosition]) -> [TransitRoute.ID: Int] {
        var merged: [TransitRoute.ID: Int] = [:]
        for cell in cells {
            for (route, index) in stops(at: cell) {
                merged[route] = min(merged[route] ?? index, index)
            }
        }
        return merged
    }

    /// One line the player can ride from origin to destination, and how many
    /// stops apart the two ends are on it.
    ///
    /// **This function is the no-transfer rule.** It looks for a route
    /// present at both ends and nothing else — if two lines would together
    /// make the journey, this returns `nil` and the trip drives. Where
    /// several lines serve both ends the shortest ride wins, with the lowest
    /// route id breaking a tie so the answer does not depend on dictionary
    /// iteration order (the same trap `Traffic.reachableTiles` documents at
    /// length, having once made routing genuinely non-deterministic).
    func connection(
        from origin: [TransitRoute.ID: Int], to destination: [TransitRoute.ID: Int]
    ) -> Ride? {
        var best: Ride?
        for (route, boarding) in origin {
            guard let alighting = destination[route] else { continue }
            let ride = Ride(route: route, stops: abs(alighting - boarding))
            guard let current = best else { best = ride; continue }
            if (ride.stops, ride.route) < (current.stops, current.route) { best = ride }
        }
        return best
    }

    /// A trip that rides: which line, and how far along it.
    struct Ride: Equatable, Sendable {
        let route: TransitRoute.ID

        /// How many stops the rider stays on for. Zero is legitimate — both
        /// ends inside one stop's catchment means home and work are within a
        /// few blocks of each other, and those people were never going to
        /// contribute much road load either way.
        let stops: Int
    }
}
