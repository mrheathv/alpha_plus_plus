import CoreGraphics
import simd

/// **Everything that moves, for the Metal renderer** — migration phase M3.
///
/// Traffic, trams on their rails, ships on their lane, fire engines running
/// to a fire, aircraft rolling down a runway, the flames themselves and the
/// light they throw. The rules for all of it are `CityMotion`'s, shared with
/// SpriteKit; this only turns them into things the GPU draws.
///
/// **Three kinds of output, each drawn the way the thing actually is:**
///
/// - **Traces**: a line segment of light with a width, drawn additively in
///   one instanced batch. A car, a tram, an engine, a flame and an ember are
///   all traces — the streak lesson SpriteKit learned ("a vehicle this small
///   should stop trying to have a shape") carried across, and now brighter
///   than white where it needs to be, so it blooms.
/// - **Solids**: ordinary lit geometry, for the one thing that keeps a shape —
///   a ship's hull, which is the largest moving thing in the game and what
///   makes a seaport read as trading at all.
/// - **Lights**: fire becomes a real light source, flickering, that lights the
///   walls of the buildings around it.
///
/// Rain and factory smoke are not here at all: they are GPU particles, placed
/// by the vertex shader from nothing but an index and the clock, so they cost
/// no CPU per particle.
///
/// **Everything is a function of the motion clock**, which only runs while
/// the city does — so pausing freezes it all with nothing to remember to stop,
/// which is the rule SpriteKit arrived at after "the cars kept driving around
/// a paused map".
final class MetalMotion {

    /// One trace, exactly as the shader reads it: 12 floats.
    ///
    /// `a` is the tail and `b` the head, in world tile units; `width` is in
    /// tiles, with a floor in pixels applied on the GPU so a trace never
    /// vanishes when the camera pulls back. `mode` picks the shape: 0 a
    /// streak brightest at its head, 1 an even line, 2 a flame.
    static let traceFloatCount = 12

    static func trace(from a: SIMD3<Float>, to b: SIMD3<Float>, width: Float, mode: Float,
                      color: SIMD3<Float>, alpha: Float) -> [Float] {
        [a.x, a.y, a.z, width, b.x, b.y, b.z, mode, color.x, color.y, color.z, alpha]
    }

    /// Height of the building standing on an anchor tile, for putting a
    /// flame on its roof. Supplied by the renderer, which knows the meshes.
    /// `nil` while not known yet; see `MetalOverlay.height`.
    var buildingHeight: (Tile) -> Float? = { _ in 1 }

    /// Whether the view up shows ambient traffic at all — the rule
    /// `OverlayMode.showsRoadNetwork` states for SpriteKit.
    var showsTraffic = true

    /// Whether a view is up. A view hides what describes a building — its
    /// flames and its smoke among them — as `applyOverlay` does in SpriteKit.
    var overlayActive = false

    // MARK: - The plan, rebuilt when the city changes

    /// A street, in world units: where it starts, which way it runs, and the
    /// deck height of each of its tiles (a bridge stands over the water).
    private struct Street {
        let motion: CityMotion.Street
        let origin: SIMD3<Float>
        let along: SIMD3<Float>
        let across: SIMD3<Float>
        let decks: [Float]
        let colors: [[SIMD3<Float>]]
    }

    private struct Run {
        let motion: CityMotion.PathRun
        let points: [SIMD3<Float>]
        let color: SIMD3<Float>
        /// The motion clock when this run started, so a line keeps running
        /// through a day that does not change it.
        let startedAt: Double
    }

    private struct Airport {
        let start: SIMD3<Float>
        let end: SIMD3<Float>
        let phase: Double
    }

    private struct Burning {
        /// The middle of the roof.
        let top: SIMD3<Float>
        let footprint: Float
        let seed: Float
    }

    private var streets: [Street] = []
    private var runs: [Run] = []
    private struct RunKey: Hashable {
        let vehicle: IsoTextureCache.Vehicle
        let tiles: [GridPosition]
    }
    private var airports: [Airport] = []
    private var fires: [Burning] = []
    /// x, y, z of a working factory's chimney top, and its density.
    private(set) var smokeEmitters: [SIMD4<Float>] = []

    /// Brings the plan up to date with `map`. Called when the map's revision
    /// moves, so about once a day and once per placement.
    func update(_ map: CityMap, clock: Double, reduceMotion: Bool) {
        streets = []
        let anyFire = Fire.count(in: map) > 0
        if showsTraffic {
            for street in CityMotion.streets(in: map, anyFire: anyFire) {
                let first = street.tiles[0]
                let along: SIMD3<Float> = street.horizontal ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
                let across: SIMD3<Float> = street.horizontal ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
                streets.append(Street(
                    motion: street,
                    origin: SIMD3(Float(first.x), Float(first.y), 0) + across * 0.5,
                    along: along, across: across,
                    decks: street.tiles.map { Self.deck(of: map[$0]) },
                    colors: street.lanes.map { lane in
                        lane.cars.map { MetalCityMesh.linear(RenderPalette.vehicleColor(for: $0.vehicle)) }
                    }))
            }
        }

        // **A run keeps its place when its own route is unchanged**, and only
        // then. Keying every run on one string that included the fires sent
        // every tram and ship back to the start of its line whenever a block
        // caught light or went out; keying on counts missed a seaport rebuilt
        // elsewhere or a track re-routed to the same length. The route itself
        // is the key: same vehicle, same tiles, same place along them.
        let previous = Dictionary(runs.map { (RunKey(vehicle: $0.motion.vehicle, tiles: $0.motion.tiles), $0.startedAt) },
                                  uniquingKeysWith: { first, _ in first })
        runs = CityMotion.pathRuns(in: map).map { run in
            let points = run.tiles.map { tile -> SIMD3<Float> in
                let z: Float = run.vehicle == .ship ? -0.14 : Self.deck(of: map[tile])
                return SIMD3(Float(tile.x) + 0.5, Float(tile.y) + 0.5, z)
            }
            return Run(motion: run, points: points,
                       color: MetalCityMesh.linear(RenderPalette.vehicleColor(for: run.vehicle)),
                       startedAt: previous[RunKey(vehicle: run.vehicle, tiles: run.tiles)] ?? clock)
        }

        airports = map.tiles.filter { $0.zone == .airport && $0.isBuildingAnchor }.map { tile in
            let x = Float(tile.position.x), y = Float(tile.position.y)
            let runway = CityMotion.runway
            return Airport(start: SIMD3(x + Float(runway.start.x), y + Float(runway.start.y), Float(runway.deck)),
                           end: SIMD3(x + Float(runway.end.x), y + Float(runway.end.y), Float(runway.deck)),
                           phase: CityMotion.aircraftPhase(at: tile.position))
        }

        fires = []
        smokeEmitters = []
        for tile in map.tiles where tile.isBuildingAnchor {
            let size = Float(tile.zone.footprintSize)
            let x = Float(tile.position.x) + size / 2, y = Float(tile.position.y) + size / 2
            if overlayActive { continue }
            if tile.isBurning {
                fires.append(Burning(top: SIMD3(x, y, max(0.3, buildingHeight(tile) ?? 0)), footprint: size,
                                     seed: Float(tile.position.x * 31 + tile.position.y * 17)))
            } else if tile.zone == .industrial, tile.density > 0, !reduceMotion,
                      let top = buildingHeight(tile) {
                smokeEmitters.append(SIMD4(x, y, top, Float(tile.density)))
            }
        }
    }

    /// The street surface under a vehicle: a bridge deck stands over the
    /// water, everything else is at street level.
    private static func deck(of tile: Tile) -> Float { tile.isWater ? 0.16 : 0.02 }

    // MARK: - One frame

    struct Frame {
        var traces: [Float] = []
        /// Flame tongues: traces too, but blended *over* what is behind them
        /// rather than added to it. Five tongues added together under bloom
        /// summed to a white blob every time — a fire is a body of colour,
        /// which is what the SpriteKit plume always was.
        var flames: [Float] = []
        var solids: [Float] = []
        var lights: [Float] = []
    }

    /// Everything that moves, where it is at `clock` seconds of running time.
    func frame(at clock: Double, near: Bool = false, streetLevel: Bool = false,
               visible: SIMD4<Float>? = nil) -> Frame {
        var frame = Frame()
        frame.traces.reserveCapacity(carCount * Self.traceFloatCount * (near ? 2 : 1) + 512)

        // **Traffic.** Brighter than white on purpose: a trace has to be light
        // rather than paint, and in HDR "light" means past the bloom threshold.
        for street in streets {
            let length = Float(street.motion.tiles.count)
            for (laneIndex, lane) in street.motion.lanes.enumerated() {
                // Keep to the right: the lane driving toward the street's end
                // sits on one side of the centre line, the other lane on the
                // other side, as the per-tile cars' lanes did.
                let side = Float(CityMotion.laneOffset) * (lane.forward ? 1 : -1) * (street.motion.horizontal ? 1 : -1)
                let heading = street.along * (lane.forward ? 1 : -1)
                for (carIndex, car) in lane.cars.enumerated() {
                    let (d, visibility) = CityMotion.along(car, on: street.motion, at: clock)
                    guard visibility > 0.01 else { continue }
                    let distance = lane.forward ? Float(d) : length - Float(d)
                    let tile = min(street.decks.count - 1, max(0, Int(distance)))
                    var head = street.origin + street.along * distance + street.across * side
                    head.z = street.decks[tile]
                    let color = street.colors[laneIndex][carIndex]
                    if near, let visible,
                       head.x < visible.x - 1 || head.y < visible.y - 1
                        || head.x > visible.x + visible.z + 1 || head.y > visible.y + visible.w + 1 {
                        continue
                    }
                    if near, car.vehicle == .car {
                        // A stable pick per car: its street, lane and place in
                        // the lane, so it keeps its paint from frame to frame.
                        let first = street.motion.tiles[0]
                        let paint = Self.paints[abs(first.x &* 73 &+ first.y &* 151 &+ laneIndex &* 37
                                                    &+ carIndex &* 11) % Self.paints.count]
                        sportsCar(at: head, heading: heading, paint: paint,
                                  visibility: Float(visibility), into: &frame)
                        if streetLevel { wheels(at: head, heading: heading, length: 0.34, width: 0.15, into: &frame) }
                    } else if near {
                        vehicle(at: head, heading: heading, kind: car.vehicle, color: color,
                                visibility: Float(visibility), into: &frame)
                        if streetLevel {
                            let big = car.vehicle == .lorry || car.vehicle == .fire
                            wheels(at: head, heading: heading, length: big ? 0.42 : 0.28, width: big ? 0.15 : 0.13,
                                   into: &frame)
                        }
                    } else {
                        // **Seven times the car's colour**, found by rendering
                        // rather than reasoning: at 2.2 a trace on a lit street
                        // sat under what the tone map and the bloom lift off
                        // it, and the cars were simply absent. Past about ten
                        // they bleach toward white; seven keeps the hue.
                        frame.traces += Self.trace(from: head - heading * Float(car.length), to: head,
                                                   width: 0.04, mode: 0, color: color * 7,
                                                   alpha: Float(car.alpha * visibility))
                    }
                }
            }
        }

        for run in runs {
            let travelled = CityMotion.travelled(run.motion, after: clock - run.startedAt)
            let step = min(Int(travelled.index), run.points.count - 2)
            let f = Float(travelled.index) - Float(step)
            let from = run.points[step], to = run.points[step + 1]
            let at = from + (to - from) * f
            let heading = simd_normalize(to - from) * (travelled.outbound ? 1 : -1)
            switch run.motion.vehicle {
            case .ship:
                ship(at: at, heading: heading, color: run.color, into: &frame)
            default:
                let isEngine = run.motion.vehicle == .fire
                let length: Float = isEngine ? 0.75 : 0.95
                frame.traces += Self.trace(from: at - heading * length / 2, to: at + heading * length / 2,
                                           width: isEngine ? 0.07 : 0.1, mode: 0, color: run.color * 2.6,
                                           alpha: isEngine ? 0.85 : 0.7)
                if isEngine {
                    // An engine's beacon is a real light, sweeping the walls
                    // it passes — the one vehicle whose arrival should be
                    // seen on the buildings, not just on the road.
                    let beat = 0.5 + 0.5 * sin(Float(clock) * 14)
                    frame.lights += MetalCityRenderer.GPULight(position: at + SIMD3(0, 0, 0.3), radius: 1.4,
                                                               color: run.color * (0.4 + beat)).floats
                }
            }
        }

        for airport in airports {
            let (f, visibility) = CityMotion.aircraft(at: clock, phase: airport.phase)
            guard visibility > 0.01 else { continue }
            let direction = simd_normalize(airport.end - airport.start)
            var at = airport.start + (airport.end - airport.start) * Float(f)
            // It lifts off over the far end of the runway: in 3D, taking off
            // is the one thing an aircraft can do that a car cannot.
            at.z += max(0, Float(f) - 0.55) * 1.6
            frame.traces += Self.trace(from: at - direction * 0.45, to: at + direction * 0.35,
                                       width: 0.09, mode: 0,
                                       color: MetalCityMesh.linear(RenderPalette.vehicleColor(for: .aircraft)) * 2.4,
                                       alpha: Float(visibility))
        }

        for fire in fires { burn(fire, at: Float(clock), into: &frame) }
        return frame
    }

    /// **A vehicle up close**: a small dark body edged in its kind's colour,
    /// white headlights at the front, red tail lights at the back, a short
    /// red trail behind it and the headlights' wash on the road ahead.
    ///
    /// Only up close, past the zoom where buildings gain their near detail.
    /// Further out a body is a few pixels and stops being a shape — the streak
    /// lesson from SpriteKit — so there a vehicle stays a trace of light.
    private func vehicle(at front: SIMD3<Float>, heading: SIMD3<Float>, kind: IsoTextureCache.Vehicle,
                         color: SIMD3<Float>, visibility: Float, into frame: inout Frame) {
        let big = kind == .lorry || kind == .fire
        let length: Float = big ? 0.42 : 0.28, width: Float = big ? 0.15 : 0.13
        let height: Float = big ? 0.16 : 0.09
        let centre = front - heading * length / 2
        Self.block(centre, along: heading, length: length, width: width, z0: front.z, z1: front.z + height,
                   albedo: SIMD3(0.09, 0.08, 0.12), emissive: .zero, rim: color * 1.3 * visibility,
                   into: &frame.solids)
        // A cabin on a car, set back; a lorry is one box.
        if !big {
            Self.block(centre - heading * 0.02, along: heading, length: length * 0.5, width: width * 0.8,
                       z0: front.z + height, z1: front.z + height + 0.05,
                       albedo: SIMD3(0.07, 0.07, 0.1), emissive: SIMD3(0.35, 0.45, 0.6) * 0.25 * visibility,
                       rim: color * 0.8 * visibility, into: &frame.solids)
        }
        let across = SIMD3<Float>(-heading.y, heading.x, 0)
        let lamp = front.z + height * 0.55
        for side: Float in [-1, 1] {
            let offset = across * width * 0.32 * side
            // Headlights and tail lights are traces: points of light, brighter
            // than white so they bloom.
            let headlight = SIMD3(front.x, front.y, lamp) + offset
            frame.traces += Self.trace(from: headlight, to: headlight + heading * 0.02, width: 0.035, mode: 1,
                                       color: SIMD3(1, 0.95, 0.85) * 6, alpha: visibility)
            let tail = SIMD3(front.x, front.y, lamp) - heading * length + offset
            frame.traces += Self.trace(from: tail - heading * 0.02, to: tail, width: 0.035, mode: 1,
                                       color: SIMD3(1, 0.08, 0.1) * 6, alpha: visibility)
        }
        // The tail-light trail, and the headlights' wash on the street ahead.
        let back = SIMD3(front.x, front.y, front.z + 0.02) - heading * length
        frame.traces += Self.trace(from: back - heading * 0.45, to: back, width: 0.05, mode: 0,
                                   color: SIMD3(1, 0.1, 0.12) * 2.5, alpha: 0.45 * visibility)
        let road = SIMD3(front.x, front.y, front.z + 0.01)
        frame.traces += Self.trace(from: road, to: road + heading * 0.4, width: 0.12, mode: 1,
                                   color: SIMD3(1, 0.92, 0.75) * 0.9, alpha: 0.35 * visibility)
    }

    /// **Wheels, at street level.** Four dark tyres at the corners, standing
    /// a hair proud of the body's sides — what a car sits on when the camera
    /// is close enough to see what it sits on.
    private func wheels(at front: SIMD3<Float>, heading: SIMD3<Float>, length: Float, width: Float,
                        into frame: inout Frame) {
        let across = SIMD3<Float>(-heading.y, heading.x, 0)
        let tyre = SIMD3<Float>(0.02, 0.02, 0.025)
        for along: Float in [0.2, 0.8] {
            for side: Float in [-1, 1] {
                let centre = front - heading * (length * along) + across * ((width / 2 + 0.004) * side)
                Self.block(centre, along: heading, length: 0.075, width: 0.03, z0: front.z, z1: front.z + 0.05,
                           albedo: tyre, emissive: .zero, rim: SIMD3(0.12, 0.12, 0.16), into: &frame.solids)
            }
        }
    }

    /// **The paint a sports car can wear**, in linear light: Ferrari red,
    /// hot magenta, white, electric cyan, sunset orange and black — the
    /// retrowave set, from the reference the player brought (an F40 under a
    /// slatted sun).
    static let paints: [SIMD3<Float>] = [
        SIMD3(0.92, 0.04, 0.06), SIMD3(0.95, 0.08, 0.55), SIMD3(0.82, 0.82, 0.86),
        SIMD3(0.05, 0.62, 0.9), SIMD3(1.0, 0.36, 0.06), SIMD3(0.025, 0.025, 0.035),
    ].map { SIMD3(powf($0.x, 2.2), powf($0.y, 2.2), powf($0.z, 2.2)) * 1.6 }

    /// **An 80s wedge, up close.** A car here is 30–60 pixels long, so what
    /// makes it read is the silhouette and the lights, not detail: a long low
    /// body with a sloping nose and the cabin set well back, a wing on two
    /// posts, twin round tail lights each side, and real paint that the
    /// street's light falls on. Lorries, patrols and engines keep their boxes,
    /// so the ordinary car is the one that looks like the poster.
    private func sportsCar(at front: SIMD3<Float>, heading: SIMD3<Float>, paint: SIMD3<Float>,
                           visibility: Float, into frame: inout Frame) {
        let length: Float = 0.34, width: Float = 0.15
        let across = SIMD3<Float>(-heading.y, heading.x, 0)
        let rear = front - heading * length
        let z0 = front.z + 0.012
        // The side profile, rear to nose along the top: (distance from the
        // rear, height). Star-shaped from the rear-bottom corner, so a fan
        // from there triangulates it.
        let profile: [(Float, Float)] = [
            (0, 0.052), (0.24, 0.056), (0.34, 0.098), (0.58, 0.1), (0.72, 0.06), (1.0, 0.032),
        ]
        func point(_ t: Float, _ h: Float, _ side: Float) -> SIMD3<Float> {
            var p = rear + heading * (t * length) + across * (width / 2 * side)
            p.z = z0 + h
            return p
        }
        let rim = paint * 0.9 + SIMD3(0.1, 0.1, 0.12)
        let glass = SIMD3<Float>(0.04, 0.05, 0.08)
        // Sides.
        for side: Float in [-1, 1] {
            let outline = [point(0, 0, side), point(1, 0, side)]
                + profile.reversed().map { point($0.0, $0.1, side) }
            MetalCityMesh.appendPolygon(outline, normal: across * side, albedo: paint * visibility,
                                        emissive: paint * 0.08 * visibility, rim: rim * 0.6 * visibility,
                                        ground: 0, into: &frame.solids)
        }
        // The top, one strip per segment of the profile: glass where the
        // cabin is, paint everywhere else.
        for index in 0 ..< profile.count - 1 {
            let (t0, h0) = profile[index], (t1, h1) = profile[index + 1]
            let a = point(t0, h0, -1), b = point(t1, h1, -1), c = point(t1, h1, 1), d = point(t0, h0, 1)
            let slope = simd_normalize(simd_cross(c - b, a - b))
            let normal = slope.z < 0 ? -slope : slope
            let isGlass = index == 1 || index == 3
            MetalCityMesh.appendPolygon([a, b, c, d], normal: normal,
                                        albedo: (isGlass ? glass : paint) * visibility,
                                        emissive: (isGlass ? SIMD3(0.2, 0.3, 0.45) * 0.3 : paint * 0.08) * visibility,
                                        // A faint edge only: a full neon rim on
                                        // every panel striped the body, and
                                        // what sells a sports car is one
                                        // continuous sweep of paint.
                                        rim: rim * 0.25 * visibility, ground: 0, into: &frame.solids)
        }
        // Tail and nose.
        MetalCityMesh.appendPolygon([point(0, 0, -1), point(0, 0, 1), point(0, 0.052, 1), point(0, 0.052, -1)],
                                    normal: -heading, albedo: paint * 0.6 * visibility, emissive: .zero,
                                    rim: rim * 0.5 * visibility, ground: 0, into: &frame.solids)
        MetalCityMesh.appendPolygon([point(1, 0, 1), point(1, 0, -1), point(1, 0.032, -1), point(1, 0.032, 1)],
                                    normal: heading, albedo: paint * 0.6 * visibility, emissive: .zero,
                                    rim: rim * 0.5 * visibility, ground: 0, into: &frame.solids)
        // The wing, on two posts.
        let wing = rear + heading * 0.03
        for side: Float in [-0.6, 0.6] {
            Self.block(wing + across * (width / 2 * side), along: heading, length: 0.02, width: 0.012,
                       z0: z0 + 0.05, z1: z0 + 0.085, albedo: paint * 0.5 * visibility, emissive: .zero,
                       rim: rim * 0.4 * visibility, into: &frame.solids)
        }
        Self.block(wing, along: heading, length: 0.05, width: width * 1.05, z0: z0 + 0.085, z1: z0 + 0.097,
                   albedo: paint * visibility, emissive: paint * 0.08 * visibility, rim: rim * visibility,
                   into: &frame.solids)

        // Twin round tail lights each side — the mark from the poster — and
        // pop-up-era headlights, as points of light bright enough to bloom.
        let lamp = z0 + 0.034
        for side: Float in [-1, 1] {
            for k: Float in [0.26, 0.4] {
                let tail = SIMD3(rear.x, rear.y, lamp) + across * (width * k * side) - heading * 0.004
                frame.traces += Self.trace(from: tail - heading * 0.012, to: tail, width: 0.03, mode: 1,
                                           color: SIMD3(1, 0.1, 0.08) * 7, alpha: visibility)
            }
            let headlight = SIMD3(front.x, front.y, z0 + 0.024) + across * (width * 0.34 * side)
            frame.traces += Self.trace(from: headlight, to: headlight + heading * 0.015, width: 0.03, mode: 1,
                                       color: SIMD3(1, 0.95, 0.85) * 6, alpha: visibility)
        }
        let back = SIMD3(rear.x, rear.y, front.z + 0.02)
        frame.traces += Self.trace(from: back - heading * 0.5, to: back, width: 0.06, mode: 0,
                                   color: SIMD3(1, 0.1, 0.12) * 2.5, alpha: 0.45 * visibility)
        let road = SIMD3(front.x, front.y, front.z + 0.01)
        frame.traces += Self.trace(from: road, to: road + heading * 0.4, width: 0.12, mode: 1,
                                   color: SIMD3(1, 0.92, 0.75) * 0.9, alpha: 0.35 * visibility)
    }

    /// A box standing on the ground, oriented along `along`: its top and four
    /// sides, as lit geometry.
    static func block(_ c: SIMD3<Float>, along: SIMD3<Float>, length: Float, width: Float,
                      z0: Float, z1: Float, albedo: SIMD3<Float>, emissive: SIMD3<Float>,
                      rim: SIMD3<Float>, into solids: inout [Float]) {
        let across = SIMD3<Float>(-along.y, along.x, 0)
        let l = along * length / 2, w = across * width / 2
        let corners = [c - l - w, c + l - w, c + l + w, c - l + w]
        func at(_ p: SIMD3<Float>, _ z: Float) -> SIMD3<Float> { SIMD3(p.x, p.y, z) }
        MetalCityMesh.appendPolygon(corners.map { at($0, z1) }, normal: SIMD3(0, 0, 1), albedo: albedo,
                                    emissive: emissive * 0.4, rim: rim, ground: 0, into: &solids)
        for index in 0 ..< 4 {
            let p = corners[index], q = corners[(index + 1) % 4]
            let mid = (p + q) / 2 - SIMD3(c.x, c.y, p.z)
            let normal = simd_normalize(SIMD3(mid.x, mid.y, 0))
            MetalCityMesh.appendPolygon([at(p, z0), at(q, z0), at(q, z1), at(p, z1)], normal: normal,
                                        albedo: albedo, emissive: emissive, rim: rim, ground: 0,
                                        into: &solids)
        }
    }

    /// A ship: a dark hull with a lit deckhouse and its lights on the water.
    private func ship(at centre: SIMD3<Float>, heading: SIMD3<Float>, color: SIMD3<Float>,
                      into frame: inout Frame) {
        let along = abs(heading.x) > abs(heading.y) ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        func block(_ c: SIMD3<Float>, _ length: Float, _ width: Float, _ z0: Float, _ z1: Float,
                   albedo: SIMD3<Float>, emissive: SIMD3<Float>, rim: SIMD3<Float>) {
            Self.block(c, along: along, length: length, width: width, z0: z0, z1: z1,
                       albedo: albedo, emissive: emissive, rim: rim, into: &frame.solids)
        }
        let hull = SIMD3<Float>(0.08, 0.075, 0.1)
        block(centre, 1.3, 0.42, centre.z - 0.02, centre.z + 0.1, albedo: hull, emissive: .zero, rim: color * 1.2)
        block(centre - along * 0.35, 0.32, 0.3, centre.z + 0.1, centre.z + 0.3,
              albedo: hull, emissive: SIMD3(1.0, 0.8, 0.55) * 0.5, rim: color * 1.4)
        frame.lights += MetalCityRenderer.GPULight(position: centre + SIMD3(0, 0, 0.5), radius: 1.6,
                                                   color: color * 0.7).floats
    }

    /// Flames on a roof, the embers above them, and the light they throw.
    ///
    /// **Fire is a light source now**, which is the thing a sprite could only
    /// paint: the walls either side of a burning block turn orange and
    /// flicker, so a fire reads from the street around it before the flame
    /// itself is found.
    private func burn(_ fire: Burning, at clock: Float, into frame: inout Frame) {
        let s = fire.seed
        let spread = fire.footprint * 0.28
        for tongue in 0 ..< 5 {
            let k = Float(tongue)
            let angle = s * 1.7 + k * 2.4
            let base = fire.top + SIMD3(cos(angle), sin(angle), 0) * spread * (0.3 + 0.2 * k.truncatingRemainder(dividingBy: 3))
            let flicker = 0.65 + 0.2 * sin(clock * (7 + k) + s) + 0.15 * sin(clock * (13.3 - k) + k)
            let height = fire.footprint * 0.85 * flicker
            let lean = SIMD3<Float>(0.08 * sin(clock * 3 + k), 0.06 * cos(clock * 2.3 + k), 0)
            frame.flames += Self.trace(from: base, to: base + SIMD3(0, 0, height) + lean,
                                       width: fire.footprint * 0.2, mode: 2, color: SIMD3(1, 1, 1) * 1.6,
                                       alpha: 1)
        }
        // Embers: rising, drifting, fading. Twelve per fire, each on its own
        // beat so they never rise as one.
        for ember in 0 ..< 12 {
            let k = Float(ember)
            let age = (clock * (0.35 + 0.03 * k) + k * 0.618 + s * 0.13).truncatingRemainder(dividingBy: 1)
            let drift = SIMD3<Float>(sin(k * 3.1 + s) * 0.35 + age * 0.3, cos(k * 1.7 + s) * 0.35, 0) * fire.footprint * 0.4
            let at = fire.top + drift + SIMD3(0, 0, fire.footprint * (0.3 + age * 1.4))
            frame.traces += Self.trace(from: at, to: at + SIMD3(0, 0, 0.06), width: 0.03, mode: 1,
                                       color: SIMD3(1.0, 0.45, 0.15) * 4, alpha: 1 - age)
        }
        let flicker = 1.6 + 0.5 * sin(clock * 9 + s) + 0.3 * sin(clock * 23 + s * 2)
        frame.lights += MetalCityRenderer.GPULight(position: fire.top + SIMD3(0, 0, fire.footprint * 0.35),
                                                   radius: fire.footprint * 1.6 + 1.2,
                                                   color: SIMD3(1.0, 0.38, 0.1) * flicker * 2.2).floats
    }

    // MARK: - For the tests

    /// Everything the plan holds that does not depend on when it was made —
    /// for `MetalAgreement`. A run's *position* along its line does (a line
    /// keeps running through a day that does not change it), so a run is
    /// compared by its route.
    struct PlanSnapshot: Equatable {
        var cars: [Float] = []
        var runs: [[GridPosition]] = []
        var airports: [Float] = []
        var fires: [Float] = []
        var smoke: [SIMD4<Float>] = []
    }

    var planForTesting: PlanSnapshot {
        var plan = PlanSnapshot()
        for street in streets {
            plan.cars += [Float(street.motion.tiles[0].x), Float(street.motion.tiles[0].y),
                          Float(street.motion.tiles.count), street.motion.horizontal ? 1 : 0,
                          Float(street.motion.speed)]
            for (laneIndex, lane) in street.motion.lanes.enumerated() {
                for (carIndex, car) in lane.cars.enumerated() {
                    let color = street.colors[laneIndex][carIndex]
                    plan.cars += [Float(car.offset), Float(car.length), Float(car.alpha),
                                  color.x, color.y, color.z]
                }
            }
        }
        plan.runs = runs.map(\.motion.tiles)
        for airport in airports { plan.airports += [airport.start.x, airport.start.y, Float(airport.phase)] }
        for fire in fires { plan.fires += [fire.top.x, fire.top.y, fire.top.z, fire.footprint] }
        plan.smoke = smokeEmitters
        return plan
    }

    var carCount: Int { streets.reduce(0) { $0 + $1.motion.lanes.reduce(0) { $0 + $1.cars.count } } }
    /// When each run started, for the test that a line keeps its place.
    var runStartsForTesting: [Double] { runs.map(\.startedAt) }
    var runCount: Int { runs.count }
    var fireCount: Int { fires.count }
}
