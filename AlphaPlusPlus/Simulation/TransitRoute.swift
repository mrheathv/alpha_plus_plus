import Foundation

/// A line the player drew: an ordered list of stations, served in order.
///
/// **The route is the infrastructure.** There is no separate track layer to
/// draw and no vehicles to place — a bus route runs on the roads that are
/// already there, a subway route tunnels under whatever is above it, and what
/// the player actually authors is *which stations are on the same line*. That
/// is the decision the mechanic turns on, and it keeps the whole feature to
/// one new piece of editable state rather than three.
///
/// So a route is not a shape on the map. It is a claim about a set of
/// buildings the player has already paid for, which is why this type holds
/// positions rather than a path: the stations carry the cost, the unlock, the
/// upkeep and the land-value amenity they always did, and the route is the
/// free act of connecting them.
struct TransitRoute: Identifiable, Equatable, Codable, Sendable {

    /// Bus or subway. They are the same mechanic at two scales — `Transit`
    /// gives the subway a wider catchment, the same "pricier version reaches
    /// further" relationship `.subway` already has with `.publicTransit`
    /// everywhere else in the game.
    ///
    /// `String`-backed for the reason `ZoneType` documents: inserting a case
    /// later (trams, which the roadmap defers deliberately) must not renumber
    /// the ones already written into saves.
    enum Mode: String, Equatable, Codable, Sendable, CaseIterable {
        case bus
        case subway

        /// Which building this mode's stations are made of.
        var stationZone: ZoneType {
            switch self {
            case .bus: return .publicTransit
            case .subway: return .subway
            }
        }
    }

    /// Stable for the life of the city, and never reused — ridership is keyed
    /// on it, and an id handed back out after a deletion would attribute one
    /// line's riders to another.
    let id: Int

    let mode: Mode

    /// The stations on this line, in the order they are served. Anchors, not
    /// arbitrary cells: `TransitNetwork` normalises to the building's origin
    /// when a stop is added, so a 1×1 station and a future larger one behave
    /// the same way.
    ///
    /// Order is what makes a route a *line* rather than a set — `Transit`
    /// measures how far apart two places are by how many stops lie between
    /// them, so re-ordering the same stations really is a different route.
    private(set) var stops: [GridPosition]

    /// A line has to go from somewhere to somewhere. One stop is not a route,
    /// and allowing it would mean a single station silently teleporting every
    /// commute inside its own catchment.
    static let minimumStops = 2

    fileprivate init(id: Int, mode: Mode, stops: [GridPosition]) {
        self.id = id
        self.mode = mode
        self.stops = stops
    }

    fileprivate mutating func setStops(_ stops: [GridPosition]) {
        self.stops = stops
    }
}

/// Every route the player has drawn.
///
/// **This stores what was drawn, not what works.** Bulldozing a station drops
/// it from the lines that called there, and a line left with one stop is kept
/// rather than deleted — it simply carries nobody until the player gives it
/// somewhere else to go. Losing a route because you demolished one station is
/// a punishment for rearranging your own city; losing its *service* is just
/// the consequence of having done so.
///
/// Deciding what a route currently *does* is `Transit`'s job, which reads the
/// map. That is the same split the conduit overlay already draws between a
/// pipe that exists and a pipe that is live, and it is there for the same
/// reason: the player needs to see the difference between "I never built
/// that" and "that stopped working."
struct TransitNetwork: Equatable, Codable, Sendable {

    private(set) var routes: [TransitRoute] = []

    /// Never decreases, so an id is never handed out twice. See
    /// `TransitRoute.id`.
    private var nextRouteID: Int = 1

    init() {}

    var isEmpty: Bool { routes.isEmpty }

    func route(id: TransitRoute.ID) -> TransitRoute? {
        routes.first { $0.id == id }
    }

    func routes(mode: TransitRoute.Mode) -> [TransitRoute] {
        routes.filter { $0.mode == mode }
    }

    /// Adds a line and returns its id. Takes whatever stops it is given,
    /// including too few of them — `add` is the player drawing, and a
    /// half-drawn route is a real state the editor needs to hold. What a
    /// route with one stop does is nothing, decided in `Transit`.
    @discardableResult
    mutating func add(mode: TransitRoute.Mode, stops: [GridPosition] = []) -> TransitRoute.ID {
        let id = nextRouteID
        nextRouteID += 1
        routes.append(TransitRoute(id: id, mode: mode, stops: stops))
        return id
    }

    mutating func remove(id: TransitRoute.ID) {
        routes.removeAll { $0.id == id }
    }

    mutating func setStops(_ stops: [GridPosition], forRoute id: TransitRoute.ID) {
        guard let index = routes.firstIndex(where: { $0.id == id }) else { return }
        routes[index].setStops(stops)
    }

    /// Drops `station` from every line that called at it.
    ///
    /// Called when a station is bulldozed. The *line* survives losing a stop,
    /// however few it is left with — see this type's own doc comment for why
    /// an emptied route is kept rather than deleted. Rebuilding the station
    /// does not put it back on the line: the route describes stations that
    /// exist, and a stop the player can see on a line has to be somewhere
    /// they can see a station.
    mutating func removeStop(at station: GridPosition) {
        for index in routes.indices {
            routes[index].setStops(routes[index].stops.filter { $0 != station })
        }
    }
}
