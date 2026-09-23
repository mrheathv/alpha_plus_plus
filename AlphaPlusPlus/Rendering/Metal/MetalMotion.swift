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
    var buildingHeight: (Tile) -> Float = { _ in 1 }

    /// Whether the view up shows ambient traffic at all — the rule
    /// `OverlayMode.showsRoadNetwork` states for SpriteKit.
    var showsTraffic = true

    /// Whether a view is up. A view hides what describes a building — its
    /// flames and its smoke among them — as `applyOverlay` does in SpriteKit.
    var overlayActive = false

    // MARK: - The plan, rebuilt when the city changes

    private struct Car {
        let start: SIMD3<Float>
        let end: SIMD3<Float>
        let motion: CityMotion.Car
        let color: SIMD3<Float>
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

    private var cars: [Car] = []
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
        cars = []
        let anyFire = Fire.count(in: map) > 0
        if showsTraffic {
            for tile in map.tiles where tile.zone == .road || tile.zone == .highway {
                let deck = Self.deck(of: tile)
                let x = Float(tile.position.x), y = Float(tile.position.y)
                for car in CityMotion.cars(at: tile.position, in: map, anyFire: anyFire) {
                    cars.append(Car(
                        start: SIMD3(x + Float(car.start.x), y + Float(car.start.y), deck),
                        end: SIMD3(x + Float(car.end.x), y + Float(car.end.y), deck),
                        motion: car,
                        color: MetalCityMesh.linear(RenderPalette.vehicleColor(for: car.vehicle))))
                }
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
                fires.append(Burning(top: SIMD3(x, y, max(0.3, buildingHeight(tile))), footprint: size,
                                     seed: Float(tile.position.x * 31 + tile.position.y * 17)))
            } else if tile.zone == .industrial, tile.density > 0, !reduceMotion {
                smokeEmitters.append(SIMD4(x, y, buildingHeight(tile), Float(tile.density)))
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
    func frame(at clock: Double) -> Frame {
        var frame = Frame()
        frame.traces.reserveCapacity(cars.count * Self.traceFloatCount + 512)

        // **Traffic.** Brighter than white on purpose: a trace has to be light
        // rather than paint, and in HDR "light" means past the bloom threshold.
        for car in cars {
            let (f, visibility) = CityMotion.progress(of: car.motion, at: clock)
            guard visibility > 0.01 else { continue }
            let direction = simd_normalize(car.end - car.start)
            let head = car.start + (car.end - car.start) * Float(f)
            let tail = head - direction * Float(car.motion.length)
            // **Seven times the car's colour**, found by rendering rather than
            // reasoning: at 2.2 a trace on a lit street sat under what the tone
            // map and the bloom lift off it, and the cars were simply absent.
            // Past about ten they bleach toward white, which is the saturation
            // this project has walked into four times; seven keeps the hue.
            frame.traces += Self.trace(from: tail, to: head, width: 0.04, mode: 0, color: car.color * 7,
                                       alpha: Float(car.motion.alpha * visibility))
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

    /// A ship: a dark hull with a lit deckhouse and its lights on the water.
    private func ship(at centre: SIMD3<Float>, heading: SIMD3<Float>, color: SIMD3<Float>,
                      into frame: inout Frame) {
        let along = abs(heading.x) > abs(heading.y) ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        let across = SIMD3<Float>(-along.y, along.x, 0)
        func block(_ c: SIMD3<Float>, _ length: Float, _ width: Float, _ z0: Float, _ z1: Float,
                   albedo: SIMD3<Float>, emissive: SIMD3<Float>, rim: SIMD3<Float>) {
            let l = along * length / 2, w = across * width / 2
            let corners = [c - l - w, c + l - w, c + l + w, c - l + w]
            func at(_ p: SIMD3<Float>, _ z: Float) -> SIMD3<Float> { SIMD3(p.x, p.y, z) }
            MetalCityMesh.appendPolygon(corners.map { at($0, z1) }, normal: SIMD3(0, 0, 1), albedo: albedo,
                                        emissive: emissive * 0.4, rim: rim, ground: 0, into: &frame.solids)
            for index in 0 ..< 4 {
                let p = corners[index], q = corners[(index + 1) % 4]
                let mid = (p + q) / 2 - c
                let normal = simd_normalize(SIMD3(mid.x, mid.y, 0))
                MetalCityMesh.appendPolygon([at(p, z0), at(q, z0), at(q, z1), at(p, z1)], normal: normal,
                                            albedo: albedo, emissive: emissive, rim: rim, ground: 0,
                                            into: &frame.solids)
            }
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
        for car in cars {
            plan.cars += [car.start.x, car.start.y, car.start.z, car.end.x, car.end.y, car.end.z,
                          Float(car.motion.crossing), Float(car.motion.phase), Float(car.motion.length),
                          Float(car.motion.alpha), car.color.x, car.color.y, car.color.z]
        }
        plan.runs = runs.map(\.motion.tiles)
        for airport in airports { plan.airports += [airport.start.x, airport.start.y, Float(airport.phase)] }
        for fire in fires { plan.fires += [fire.top.x, fire.top.y, fire.top.z, fire.footprint] }
        plan.smoke = smokeEmitters
        return plan
    }

    var carCount: Int { cars.count }
    /// When each run started, for the test that a line keeps its place.
    var runStartsForTesting: [Double] { runs.map(\.startedAt) }
    var runCount: Int { runs.count }
    var fireCount: Int { fires.count }
}
