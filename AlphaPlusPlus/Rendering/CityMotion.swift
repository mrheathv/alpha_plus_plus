import CoreGraphics
import Foundation

/// **What moves on the map, and how** — shared by both renderers.
///
/// Everything here is a rule about motion, stated in tile units: which
/// vehicle a street carries, where on a tile a car drives and how long it
/// takes to cross, how fast a tram, a ship or a fire engine goes, when an
/// aircraft rolls. `GameScene` turns these into sprites and `MetalMotion`
/// into light traces.
///
/// **One copy, on purpose.** The Metal migration moves drawing across one
/// piece at a time, and the thing this project keeps paying for is a second
/// implementation of a fact that drifts from the first — a streetscape
/// painting its own tiles, an overlay render carrying its own switch. A car
/// that drives a different lane in Metal than in SpriteKit would be the next
/// one.
enum CityMotion {

    // MARK: - Ambient traffic

    /// One ambient car on one road tile, in the tile's own coordinates.
    struct Car {
        /// Where it enters and leaves the tile, as fractions of the tile.
        let start: CGPoint
        let end: CGPoint
        /// Seconds to cross the tile.
        let crossing: TimeInterval
        /// Where in its cycle it starts, so neighbours do not run in step.
        let phase: TimeInterval
        let vehicle: IsoTextureCache.Vehicle
        /// How long its trace is, in tiles.
        let length: CGFloat
        /// How bright its trace is drawn.
        let alpha: CGFloat
    }

    /// How long a car spends invisible while it returns to the start of its
    /// tile. A car cannot drive its whole routed commute — that is the
    /// individual-agent rendering this project rules out — so it has to reset
    /// somewhere, and fading hides the jump.
    static let carResetSeconds: TimeInterval = 0.2

    /// The cars `position` carries right now: none off the road, and as many
    /// as `Traffic.carCount` says its congestion earns.
    ///
    /// Everything that decides where and how a car drives is here — the lane
    /// it keeps to, the way it heads, how slowly a jam makes it cross, the
    /// seeded stagger that stops a street reading as a conveyor. The reasons
    /// for each are recorded where `GameScene` draws them.
    ///
    /// `anyFire` is whether anything in the city is alight, which decides
    /// whether an engine can be among the traffic. It is a whole-map scan, so
    /// a caller asking about many tiles should work it out once and pass it:
    /// asked per car, it was 95% of planning Apex's traffic.
    static func cars(at position: GridPosition, in map: CityMap, anyFire: Bool? = nil) -> [Car] {
        let zone = map[position].zone
        guard zone == .road || zone == .highway else { return [] }
        let congestion = Traffic.congestion(at: position, in: map)
        let count = Traffic.carCount(forCongestion: congestion)
        guard count > 0 else { return [] }

        let horizontal = Traffic.isHorizontallyOriented(at: position, in: map)
        let flowsPositive = map.trafficLoad.netHeadingIsPositive(at: position, horizontal: horizontal)
        let crossing = 1.2 + congestion * 1.8
        let lane = 0.5 + (flowsPositive ? 0.16 : -0.16)
        let low = horizontal ? CGPoint(x: 0, y: lane) : CGPoint(x: lane, y: 0)
        let high = horizontal ? CGPoint(x: 1, y: lane) : CGPoint(x: lane, y: 1)
        let speed = CGFloat(1 - congestion)
        var phaseRandom = BuildingRandom(seed: position, salt: 911)
        let tilePhase = Double(phaseRandom.value(in: 0 ... 1))
        let anyFire = anyFire ?? (Fire.count(in: map) > 0)

        return (0 ..< count).map { index in
            var random = BuildingRandom(seed: position, salt: 400 + index)
            return Car(start: flowsPositive ? low : high, end: flowsPositive ? high : low,
                       crossing: crossing,
                       phase: crossing * (Double(index) + tilePhase) / Double(count),
                       vehicle: vehicleKind(at: position, in: map, anyFire: anyFire, random: &random),
                       length: 0.18 + speed * 0.8,
                       alpha: 0.3 + speed * 0.35)
        }
    }

    /// Where `car` is at `clock` seconds: how far across its tile, and how
    /// visible — it fades out at the end and in at the start of each
    /// crossing, so the reset is never seen as a backward jump.
    static func progress(of car: Car, at clock: TimeInterval) -> (fraction: CGFloat, visibility: CGFloat) {
        let fade = carResetSeconds
        let cycle = car.crossing + fade * 2
        var t = (clock + car.phase).truncatingRemainder(dividingBy: cycle)
        if t < 0 { t += cycle }
        if t < car.crossing { return (CGFloat(t / car.crossing), 1) }
        if t < car.crossing + fade { return (1, CGFloat(1 - (t - car.crossing) / fade)) }
        return (0, CGFloat((t - car.crossing - fade) / fade))
    }

    /// What is driving down this particular street: an engine near a fire, a
    /// patrol car near a station, freight past industry, and otherwise the
    /// quiet ordinary car.
    static func vehicleKind(at position: GridPosition, in map: CityMap, anyFire: Bool,
                            random: inout BuildingRandom) -> IsoTextureCache.Vehicle {
        if anyFire, isNear(position, in: map, within: 6, { map[$0].isBurning }),
           random.chance(0.6) {
            return .fire
        }
        if isNear(position, in: map, within: 5, { map[$0].zone == .policeStation }),
           random.chance(0.35) {
            return .police
        }
        let servesIndustry = position.orthogonalNeighbors().contains {
            map.contains($0) && map[$0].zone == .industrial
        }
        return random.chance(servesIndustry ? 0.55 : 0.12) ? .lorry : .car
    }

    /// Is anything matching `test` within `radius` tiles? Square rather than
    /// a true radius, and small on purpose: the answer only decides a colour.
    static func isNear(_ position: GridPosition, in map: CityMap, within radius: Int,
                       _ test: (GridPosition) -> Bool) -> Bool {
        for dy in -radius ... radius {
            for dx in -radius ... radius {
                let cell = GridPosition(x: position.x + dx, y: position.y + dy)
                if map.contains(cell), test(cell) { return true }
            }
        }
        return false
    }

    // MARK: - Vehicles on real paths

    /// A vehicle whose route is real ground: a tram on its rails, a ship on
    /// its lane, an engine running to a fire.
    struct PathRun {
        let vehicle: IsoTextureCache.Vehicle
        let tiles: [GridPosition]
        /// Tiles per second.
        let speed: CGFloat
        /// An engine runs to the fire and the next leaves the depot; a line
        /// is a there-and-back service.
        let oneWay: Bool
    }

    /// Tiles per second for each kind of run. A ship is slow, because speed
    /// is most of what tells a hull from a tram once both are small; an
    /// engine is fast, because the one thing everybody knows about a fire
    /// engine is that it is in a hurry.
    static let tramTilesPerSecond = 1 / CGFloat(TransitRoute.Mode.tram.minutesPerTile * 0.55)
    static let shipTilesPerSecond: CGFloat = 0.55
    static let fireEngineTilesPerSecond: CGFloat = 2.6

    /// Every path vehicle the city has right now. Two tiles is the shortest
    /// thing that has a direction; a severed line returns nothing, and a tram
    /// gliding across the gap would claim a connection the city lacks.
    static func pathRuns(in map: CityMap) -> [PathRun] {
        var runs: [PathRun] = []
        for route in map.transit.routes(mode: .tram) {
            runs.append(PathRun(vehicle: .transit(.tram), tiles: Transit.tramPath(of: route, in: map),
                                speed: tramTilesPerSecond, oneWay: false))
        }
        runs.append(PathRun(vehicle: .ship, tiles: ShippingLane.path(in: map),
                            speed: shipTilesPerSecond, oneWay: false))
        for route in EmergencyResponse.fireRoutes(in: map) {
            runs.append(PathRun(vehicle: .fire, tiles: route,
                                speed: fireEngineTilesPerSecond, oneWay: true))
        }
        return runs.filter { $0.tiles.count >= 2 }
    }

    /// How far along its tiles, in index units, a run is after `elapsed`
    /// seconds, and which way it is heading.
    static func travelled(_ run: PathRun, after elapsed: TimeInterval) -> (index: CGFloat, outbound: Bool) {
        let last = CGFloat(run.tiles.count - 1)
        let distance = run.speed * CGFloat(max(0, elapsed))
        if run.oneWay { return (distance.truncatingRemainder(dividingBy: last), true) }
        let t = distance.truncatingRemainder(dividingBy: last * 2)
        return t <= last ? (t, true) : (last * 2 - t, false)
    }

    // MARK: - Aircraft

    /// Seconds an aircraft waits at the threshold, invisible, and seconds it
    /// spends rolling down the runway.
    static let aircraftWait: TimeInterval = 2.5
    static let aircraftRoll: TimeInterval = 2.2

    static func aircraftPhase(at airport: GridPosition) -> TimeInterval {
        var random = BuildingRandom(seed: airport, salt: 733)
        return random.value(in: 0 ... (aircraftWait + aircraftRoll))
    }

    /// The runway's two ends, in the airport's own coordinates (tile units
    /// from its anchor), matching `ServiceMassing.airport`.
    static let runway: (start: (x: CGFloat, y: CGFloat), end: (x: CGFloat, y: CGFloat), deck: CGFloat) = {
        let span = CGFloat(ZoneType.airport.footprintSize) - 0.16
        let lane = 0.08 + span * 0.13
        return ((0.2, lane), (span, lane), 0.1)
    }()

    /// Where the aircraft is along its runway, 0…1, and how visible —
    /// invisible except while moving, because parked it is a lump.
    /// `phase` is seeded per airport so two do not launch in step.
    static func aircraft(at clock: TimeInterval, phase: TimeInterval) -> (fraction: CGFloat, visibility: CGFloat) {
        let cycle = aircraftWait + aircraftRoll
        var t = (clock + phase).truncatingRemainder(dividingBy: cycle)
        if t < 0 { t += cycle }
        guard t >= aircraftWait else { return (0, 0) }
        let elapsed = t - aircraftWait
        // Fades up as it accelerates away and out as it goes, so the reset to
        // the threshold happens behind a beat of invisibility rather than as
        // a visible snap back down the runway.
        let visibility = elapsed < 0.3 ? elapsed / 0.3 : elapsed < 1.7 ? 1 : max(0, 1 - (elapsed - 1.7) / 0.5)
        return (CGFloat(elapsed / aircraftRoll), CGFloat(visibility))
    }
}
