import AppKit
import XCTest
import simd
@testable import AlphaPlusPlus

/// **M3: everything that moves, on the Metal renderer.**
///
/// The migration plan's bar for this phase is a recording: traffic, transit
/// and weather visibly moving, and pausing freezing them. `testRecordTheCity`
/// is that recording — `build/Recordings/metal-motion.mov` and its filmstrip —
/// and the other tests pin the properties it shows, so they hold without
/// anyone watching a movie.
///
/// ```sh
/// xcodebuild -project AlphaPlusPlus.xcodeproj -scheme AlphaPlusPlus -testPlan Full \
///            -configuration Release -derivedDataPath ./build ENABLE_TESTABILITY=YES \
///            test -only-testing:AlphaPlusPlusTests/MetalMotionTests
/// open ./build/Recordings/metal-motion-filmstrip.png
/// ```
@MainActor
final class MetalMotionTests: XCTestCase {

    /// A river city with one of everything that moves: streets busy enough
    /// to carry traffic, a tram line, a seaport with a way out to sea, an
    /// airport, working factories, and one block alight with a fire station
    /// in reach.
    static func movingCity() -> CityMap {
        var map = CityMap(width: 32, height: 24)
        for y in 17 ..< 24 { for x in 0 ..< 32 { map[GridPosition(x: x, y: y)].isWater = true } }
        for x in 0 ..< 32 {
            map[GridPosition(x: x, y: 5)].zone = .road
            map[GridPosition(x: x, y: 12)].zone = .road
        }
        for x in [4, 18, 27] { for y in 0 ..< 17 { map[GridPosition(x: x, y: y)].zone = .road } }
        // The avenue carries on across the river as a bridge.
        for y in 0 ..< 24 { map[GridPosition(x: 11, y: y)].zone = .road }

        let lots: [(ZoneType, Int, Int, Int)] = [
            (.residential, 0, 3, 4), (.commercial, 2, 3, 5), (.residential, 5, 3, 4), (.commercial, 7, 3, 5),
            (.residential, 9, 3, 3), (.commercial, 12, 3, 4), (.residential, 14, 3, 5), (.industrial, 16, 3, 3),
            (.residential, 19, 3, 4), (.commercial, 21, 3, 5), (.residential, 23, 3, 3), (.industrial, 25, 3, 4),
            (.residential, 0, 6, 3), (.commercial, 2, 6, 4), (.industrial, 5, 6, 4), (.industrial, 7, 6, 5),
            (.residential, 9, 6, 4), (.industrial, 12, 6, 4), (.commercial, 14, 6, 5), (.residential, 16, 6, 4),
            (.commercial, 19, 6, 4), (.residential, 21, 6, 5), (.industrial, 23, 6, 3), (.commercial, 25, 6, 4),
            (.residential, 0, 10, 4), (.commercial, 2, 10, 4), (.residential, 5, 10, 5), (.commercial, 7, 10, 3),
            (.residential, 12, 10, 4), (.commercial, 14, 10, 5), (.residential, 16, 10, 3),
        ]
        for (zone, x, y, density) in lots {
            let origin = GridPosition(x: x, y: y)
            map.placeBuilding(zone: zone, origin: origin)
            for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = density }
        }
        map.placeBuilding(zone: .fireStation, origin: GridPosition(x: 9, y: 10))
        map.placeBuilding(zone: .airport, origin: GridPosition(x: 19, y: 13))
        map.placeBuilding(zone: .seaport, origin: GridPosition(x: 28, y: 14))
        for x in [2, 15, 30] { map.placeBuilding(zone: .tramStop, origin: GridPosition(x: x, y: 5)) }
        _ = map.transit.add(mode: .tram, stops: [
            GridPosition(x: 2, y: 5), GridPosition(x: 15, y: 5), GridPosition(x: 30, y: 5),
        ])
        map.tramTracks = Transit.tramTracks(in: map)
        return map
    }

    /// The city after a few days, so the streets carry routed traffic — an
    /// unticked city has empty streets by construction, which is what the
    /// first SpriteKit motion test measured by mistake — and then set alight.
    static func tickedCity() -> CityMap {
        let controller = GameController(map: movingCity(), rng: SeededRNG(seed: 4),
                                        peakPopulation: Unlocks.everythingUnlocked)
        for _ in 0 ..< 6 { controller.advanceSimulation() }
        var map = controller.map
        map[GridPosition(x: 12, y: 6)].fireTicks = 4
        return map
    }

    private static let size = CGSize(width: 1200, height: 750)
    private static var camera: MetalCityRenderer.Camera {
        MetalCityRenderer.Camera(centre: Isometric().project(15, 11, 0), scale: 1.0, size: size)
    }

    /// Everything is planned: cars on the streets, the tram, the ship and the
    /// engine on their paths, the fire, and smoke from the factories.
    func testEverythingThatMovesIsPlanned() throws {
        let map = Self.tickedCity()
        let renderer = try XCTUnwrap(MetalCityRenderer())
        renderer.update(map, revision: nil)
        let motion = renderer.motion
        XCTAssertGreaterThan(motion.carCount, 20, "the streets carry no traffic")
        XCTAssertEqual(motion.fireCount, 1)
        XCTAssertFalse(motion.smokeEmitters.isEmpty, "no factory smokes")
        let runs = CityMotion.pathRuns(in: map).map(\.vehicle)
        XCTAssertTrue(runs.contains(.transit(.tram)), "no tram")
        XCTAssertTrue(runs.contains(.ship), "no ship")
        XCTAssertTrue(runs.contains(.fire), "no engine running to the fire")
        XCTAssertEqual(motion.runCount, runs.count)

        // The fire is a light: the frame carries more lights than the city.
        let frame = motion.frame(at: 1)
        XCTAssertGreaterThan(frame.lights.count, 0, "the fire throws no light")
        XCTAssertFalse(frame.solids.isEmpty, "the ship has no hull")
    }

    /// **It moves, and it is a function of the clock.** Two frames half a
    /// second apart differ; two frames at the same moment are identical, which
    /// is what makes pausing — holding the clock — freeze everything.
    func testTheCityMovesAndTheSameMomentDrawsTheSame() throws {
        let map = Self.tickedCity()
        let renderer = try XCTUnwrap(MetalCityRenderer())
        func frame(_ clock: Double) throws -> [UInt8] {
            let image = try XCTUnwrap(renderer.render(map, camera: Self.camera, wetness: 0.5, time: 2,
                                                      motionClock: clock, rainfall: 0.7)).image
            return Self.bytes(image)
        }
        let a = try frame(1.0), b = try frame(1.5), again = try frame(1.0)
        let moved = Self.changed(a, b)
        print(String(format: "🟪 metal motion: %.2f%% of the frame changed in half a second", moved * 100))
        XCTAssertGreaterThan(moved, 0.005, "nothing moved in half a second")
        XCTAssertEqual(Self.changed(a, again), 0, "the same moment drew differently")
    }

    /// **Pausing stops the clock and nothing else.** The motion clock only
    /// counts while the city runs; the frames above show that holding it
    /// holds the picture.
    func testThePausedClockHolds() {
        var clock = MotionClock()
        clock.tick(at: 10.0, running: true)
        clock.tick(at: 10.05, running: true)
        XCTAssertEqual(clock.seconds, 0.05, accuracy: 1e-9)
        clock.tick(at: 10.5, running: false)
        clock.tick(at: 12.0, running: false)
        XCTAssertEqual(clock.seconds, 0.05, accuracy: 1e-9, "the clock ran while paused")
        // A stall is clamped, so resuming after one does not jump the city.
        clock.tick(at: 20.0, running: true)
        XCTAssertEqual(clock.seconds, 0.15, accuracy: 1e-9)
    }

    /// Reduced motion takes the smoke and leaves the traffic — one is ambient,
    /// the other says how the streets are doing.
    func testReducedMotionTakesTheSmokeAndKeepsTheTraffic() throws {
        let map = Self.tickedCity()
        let renderer = try XCTUnwrap(MetalCityRenderer())
        let was = VisualStyle.reduceMotion
        defer { VisualStyle.reduceMotion = was }
        VisualStyle.reduceMotion = true
        renderer.update(map, revision: nil)
        XCTAssertTrue(renderer.motion.smokeEmitters.isEmpty)
        XCTAssertGreaterThan(renderer.motion.carCount, 0)
    }

    /// **The recording the plan asks for**: three seconds of the city running
    /// in the rain, then a second and a half paused. The water keeps moving
    /// through the pause — it runs on the wall clock, not the city's — and
    /// everything else stops.
    func testRecordTheCity() throws {
        let map = Self.tickedCity()
        let renderer = try XCTUnwrap(MetalCityRenderer())
        let running = 3.0
        var previous: [UInt8]?
        var movedWhileRunning: [Double] = [], movedWhilePaused: [Double] = []
        let recorder = SceneRecorder(fps: 30) { seconds in
            let clock = min(seconds, running)
            guard let image = renderer.render(map, camera: Self.camera, wetness: 0.75,
                                              time: Float(seconds), motionClock: clock,
                                              rainfall: 0.7)?.image else { return nil }
            let bytes = Self.bytes(image)
            if let previous {
                let moved = Self.changed(previous, bytes)
                if seconds <= running { movedWhileRunning.append(moved) } else { movedWhilePaused.append(moved) }
            }
            previous = bytes
            return image
        }
        recorder.recordFrames(seconds: running + 1.5, keepEvery: 17)
        recorder.writeMovie(named: "metal-motion")
        recorder.writeFilmstrip(named: "metal-motion", columns: 3)

        let run = movedWhileRunning.reduce(0, +) / Double(max(1, movedWhileRunning.count))
        let pause = movedWhilePaused.reduce(0, +) / Double(max(1, movedWhilePaused.count))
        print(String(format: "🟪 per frame, running: %.2f%% changed · paused: %.2f%% (the water)",
                     run * 100, pause * 100))
        XCTAssertGreaterThan(run, pause * 2, "pausing did not visibly stop the city")
    }

    /// **The same city up close**, where a trace has to read as a vehicle
    /// rather than a smear: the fire and its engine, the tram line, the
    /// avenue's traffic — dry, and in the rain.
    func testRenderTheMovingCityCloseUp() throws {
        let map = Self.tickedCity()
        let renderer = try XCTUnwrap(MetalCityRenderer())
        var frames: [(String, NSImage)] = []
        for (label, centre, rain) in [
            ("dry — the waterfront avenue and the fire", Self.centre(Self.exposedBusiestStreet(in: map)), Float(0)),
            ("raining", Self.centre(Self.exposedBusiestStreet(in: map)), Float(0.8)),
            ("the waterfront — ship at the quay, the airport", Isometric().project(25, 17, 0), Float(0)),
            ("the fire, the light it throws, its engine", Isometric().project(12, 7, 1.5), Float(0)),
            // Past the close-up threshold, where a car stops being a streak
            // and becomes a lit body with head and tail lights.
            ("up close — vehicles as bodies", Self.centre(Self.exposedBusiestStreet(in: map)), Float(0)),
        ] as [(String, CGPoint, Float)] {
            let scale: CGFloat = label.hasPrefix("up close") ? 0.22 : 0.45
            let camera = MetalCityRenderer.Camera(centre: centre, scale: scale, size: Self.size)
            let frame = try XCTUnwrap(renderer.render(map, camera: camera, wetness: rain > 0 ? 1 : 0,
                                                      time: 2, motionClock: 1.3, rainfall: rain))
            frames.append((label, NSImage(cgImage: frame.image, size: Self.size)))
        }
        // And the densest city there is, where the streets are genuinely busy:
        // the fixture above is too small for more than a few dozen cars.
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        if FileManager.default.fileExists(atPath: url.path) {
            let apex = try CitySaveFile.read(from: url).map
            let busiest = Self.exposedBusiestStreet(in: apex)
            let apexRenderer = try XCTUnwrap(MetalCityRenderer())
            var apexFrames: [(String, NSImage)] = []
            defer { try? MetalSpikeTests.writeGrid(apexFrames, columns: 1, cell: Self.size, named: "metal-motion-apex") }
            for (label, rain) in [("Apex — the busiest streets", Float(0)), ("Apex — in the rain", Float(0.8))] {
                let camera = MetalCityRenderer.Camera(
                    centre: Isometric().project(CGFloat(busiest.x), CGFloat(busiest.y), 0), scale: 0.5, size: Self.size)
                let frame = try XCTUnwrap(apexRenderer.render(apex, camera: camera, wetness: rain > 0 ? 1 : 0,
                                                              time: 2, motionClock: 1.3, rainfall: rain))
                apexFrames.append((label, NSImage(cgImage: frame.image, size: Self.size)))
            }
        }
        try MetalSpikeTests.writeGrid(frames, columns: 1, cell: Self.size, named: "metal-motion-close")
    }

    /// The road tile with the most traffic around it that nothing stands in
    /// front of — the camera looks from +x, +y, so a tower on the near side
    /// of a street hides its cars, correctly, and a picture of hidden cars
    /// says nothing about how cars look.
    static func exposedBusiestStreet(in map: CityMap) -> GridPosition {
        func isOpen(_ p: GridPosition) -> Bool {
            (0 ... 2).allSatisfy { dy in (0 ... 2).allSatisfy { dx in
                let q = GridPosition(x: p.x + dx, y: p.y + dy)
                return !map.contains(q) || map[q].zone.maxDensity == 0 || map[q].density <= 1
            } }
        }
        func load(_ p: GridPosition) -> Int {
            (-3 ... 3).flatMap { dy in (-3 ... 3).map { dx in GridPosition(x: p.x + dx, y: p.y + dy) } }
                .filter { map.contains($0) }
                .reduce(0) { $0 + CityMotion.cars(at: $1, in: map).count }
        }
        return map.tiles.filter { Traffic.isRoadLike($0.zone) && isOpen($0.position) }
            .max { load($0.position) < load($1.position) }?.position ?? GridPosition(x: 0, y: 0)
    }

    static func centre(_ p: GridPosition) -> CGPoint { Isometric().project(CGFloat(p.x), CGFloat(p.y), 0) }

    /// **A fire does not send the trams back to the start of their line.**
    /// Every run used to be keyed on one string that included the fires, so a
    /// block catching light anywhere restarted every tram and ship. Found by
    /// review; a run now keeps its place while its own route is unchanged.
    func testAFireDoesNotRestartTheTrams() throws {
        var map = Self.movingCity()
        let motion = MetalMotion()
        motion.update(map, clock: 0, reduceMotion: false)
        let before = motion.runStartsForTesting
        XCTAssertFalse(before.isEmpty)
        map[GridPosition(x: 12, y: 6)].fireTicks = 4
        motion.update(map, clock: 7, reduceMotion: false)
        let tram = CityMotion.pathRuns(in: map).firstIndex { $0.vehicle == .transit(.tram) }
        let index = try XCTUnwrap(tram)
        XCTAssertEqual(motion.runStartsForTesting[index], 0, "the tram restarted when a fire began")
    }

    /// Reduce Motion takes effect at once, with no change to the map to
    /// announce it — the revision the live view gates on never moves for it.
    func testReduceMotionTakesEffectWithoutAMapChange() throws {
        let map = Self.tickedCity()
        let renderer = try XCTUnwrap(MetalCityRenderer())
        let was = VisualStyle.reduceMotion
        defer { VisualStyle.reduceMotion = was }
        VisualStyle.reduceMotion = false
        renderer.update(map, revision: 1)
        XCTAssertFalse(renderer.motion.smokeEmitters.isEmpty)
        VisualStyle.reduceMotion = true
        renderer.update(map, revision: 1)
        XCTAssertTrue(renderer.motion.smokeEmitters.isEmpty, "smoke kept drawing after Reduce Motion")
    }

    // MARK: - Pixels

    static func bytes(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    /// The share of pixels whose colour moved by more than a hair.
    static func changed(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var moved = 0
        var index = 0
        while index < a.count {
            let d = abs(Int(a[index]) - Int(b[index])) + abs(Int(a[index + 1]) - Int(b[index + 1]))
                + abs(Int(a[index + 2]) - Int(b[index + 2]))
            if d > 12 { moved += 1 }
            index += 4
        }
        return Double(moved) / Double(a.count / 4)
    }
}
