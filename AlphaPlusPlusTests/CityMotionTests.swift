import SpriteKit
import XCTest
@testable import AlphaPlusPlus

/// **Does the city actually move, and does it stop when told?**
///
/// Both halves have failed in this project before, in opposite directions: the
/// texture cache once borrowed the game's own `SKView` and froze the map the
/// first time a building grew, and the ambient traffic once kept driving
/// around a paused city. Neither failed a test, because nothing was asserting
/// on whether anything changed between two frames — there was no second frame.
@MainActor
final class CityMotionTests: XCTestCase {

    /// A city with a tram line in it, because a tram is the one vehicle driven
    /// per frame rather than by an `SKAction` — so it is the one thing a
    /// headless recording can prove is moving. That is a statement about the
    /// fixture *and* a statement about the renderer: see `SceneRecorder`.
    private func cityWithATramLine() -> CityMap {
        var map = CityMap(width: 22, height: 14)
        for x in 1 ..< 21 { map[GridPosition(x: x, y: 6)].zone = .road }
        for x in stride(from: 2, to: 19, by: 4) {
            map.placeBuilding(zone: .commercial, origin: GridPosition(x: x, y: 4))
            map.placeBuilding(zone: .residential, origin: GridPosition(x: x, y: 7))
            for cell in map.footprintCells(origin: GridPosition(x: x, y: 4), size: 2)
                + map.footprintCells(origin: GridPosition(x: x, y: 7), size: 2) {
                map[cell].density = 4
            }
        }
        for x in [3, 11, 19] { map.placeBuilding(zone: .tramStop, origin: GridPosition(x: x, y: 6)) }
        _ = map.transit.add(mode: .tram, stops: [
            GridPosition(x: 3, y: 6), GridPosition(x: 11, y: 6), GridPosition(x: 19, y: 6),
        ])
        map.tramTracks = Transit.tramTracks(in: map)
        return map
    }

    private func makeScene(_ map: CityMap, ticks: Int = 12) -> (GameScene, SKView, GameController) {
        let controller = GameController(map: map, rng: SeededRNG(seed: 4),
                                        peakPopulation: Unlocks.everythingUnlocked)
        // **Ticked, or there is no traffic to watch.** `Traffic.carCount`
        // returns zero for zero congestion, and congestion comes from routed
        // commutes — so an unticked city has empty streets by construction.
        // The first version of this test missed that entirely and measured a
        // city with no cars in it while asking whether the cars moved.
        for _ in 0 ..< ticks { controller.advanceSimulation() }
        let scene = GameScene(controller: controller)
        scene.size = CGSize(width: 700, height: 440)
        let view = SKView(frame: NSRect(origin: .zero, size: scene.size))
        view.presentScene(scene)
        scene.rebuildEntireGrid()
        scene.refreshAll()
        scene.centerCameraOnMap()
        return (scene, view, controller)
    }

    /// How much of the frame changed between two captures, 0…1.
    private func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        var moved = 0, total = 0
        for y in stride(from: 0, to: min(a.pixelsHigh, b.pixelsHigh), by: 3) {
            for x in stride(from: 0, to: min(a.pixelsWide, b.pixelsWide), by: 3) {
                guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                total += 1
                if abs(p.brightnessComponent - q.brightnessComponent) > 0.01 { moved += 1 }
            }
        }
        return total == 0 ? 0 : Double(moved) / Double(total)
    }

    /// Scene time, stepped one frame at a time.
    ///
    /// **It has to be stepped rather than jumped**, and finding that out cost
    /// a confused round trip: `GameScene.update` clamps its own delta with
    /// `min(currentTime - last, 0.1)`, so handing it a time a second later
    /// still advances the world by a tenth of a second. That is correct for
    /// the game — it stops the city lurching after the app is stalled or
    /// dragged between displays — and it means any harness driving the clock
    /// has to supply a real cadence, not a pair of timestamps.
    private var clock: TimeInterval = 0

    private func advance(_ scene: GameScene, _ view: SKView, frames: Int, fps: Double = 60) throws
        -> NSBitmapImageRep {
        for _ in 0 ..< max(1, frames) {
            clock += 1 / fps
            scene.update(clock)
        }
        let texture = try XCTUnwrap(view.texture(from: scene,
                                                 crop: CGRect(origin: .zero, size: scene.size)))
        return NSBitmapImageRep(cgImage: texture.cgImage())
    }

    func testTheCityMovesWhileRunningAndHoldsStillWhenPaused() throws {
        let (scene, view, controller) = makeScene(cityWithATramLine())

        controller.isRunning = true
        let running1 = try advance(scene, view, frames: 2)   // settle: builds the vehicles
        print("driving: \(scene.trafficCarCountForTesting) cars, "
              + "\(scene.pathVehicleCountForTesting) path vehicles")
        let before = scene.pathVehiclePositionsForTesting
        let running2 = try advance(scene, view, frames: 60)  // one second of real cadence
        let after = scene.pathVehiclePositionsForTesting
        let movedWhileRunning = difference(running1, running2)

        // **Two assertions about the same fact, and both are needed.** The
        // positions say the scene advanced its own state; the pixels say it
        // was then *drawn*. Either alone has shipped here: a tram route was
        // computed and nothing drew it, and a frozen map kept drawing a
        // perfectly correct frame from before it stopped.
        XCTAssertEqual(before.count, after.count)
        XCTAssertFalse(before.isEmpty, "the fixture has nothing that moves per frame in it")
        XCTAssertNotEqual(before, after, "the tram did not move over a full second")

        controller.isRunning = false
        let paused1 = try advance(scene, view, frames: 4)    // settle: parks everything
        let paused2 = try advance(scene, view, frames: 60)
        let movedWhilePaused = difference(paused1, paused2)

        print(String(format: "motion over one second: %.3f%% of the frame running, "
                     + "%.3f%% paused", movedWhileRunning * 100, movedWhilePaused * 100))

        // **Raised when the traffic moved onto the per-frame driver**, which
        // is what the earlier version of this comment asked for rather than
        // leaving a floor nothing could fail. A tram alone was 0.06% of the
        // frame; a tram and nine cars is 0.30%. The transit-diagram vehicles
        // and the airport's aircraft are still `SKAction`s and still do not
        // advance here — when they follow, this should be raised again.
        XCTAssertGreaterThan(movedWhileRunning, 0.0015,
                             "nothing in the city was redrawn over a full second — the map has "
                             + "frozen, which is how the texture cache once broke the game")
        XCTAssertLessThan(movedWhilePaused, movedWhileRunning / 4,
                          "the city kept moving while paused — the bug where ambient traffic "
                          + "went on driving around a stopped map")
    }

    /// **Everything that moves is now driven per frame, and this proves it
    /// one at a time.**
    ///
    /// The recorder's finding was that almost nothing advanced in a headless
    /// capture, because SpriteKit runs `SKAction`s on its own loop. Three
    /// families had to move: the ambient cars, the vehicles running a route
    /// diagram, and the airport's aircraft. Each is asserted on its own here
    /// rather than through one "did the frame change" number, because that
    /// number passes as soon as *any* of them works.
    func testEveryKindOfVehicleAdvancesWithoutSpriteKitsLoop() throws {
        var map = CityMap(width: 26, height: 20)
        for x in 1 ..< 25 { map[GridPosition(x: x, y: 8)].zone = .road }
        for x in stride(from: 2, to: 22, by: 4) {
            map.placeBuilding(zone: .commercial, origin: GridPosition(x: x, y: 6))
            map.placeBuilding(zone: .residential, origin: GridPosition(x: x, y: 9))
            for cell in map.footprintCells(origin: GridPosition(x: x, y: 6), size: 2)
                + map.footprintCells(origin: GridPosition(x: x, y: 9), size: 2) {
                map[cell].density = 4
            }
        }
        for x in [3, 12, 21] { map.placeBuilding(zone: .publicTransit, origin: GridPosition(x: x, y: 8)) }
        _ = map.transit.add(mode: .bus, stops: [
            GridPosition(x: 3, y: 8), GridPosition(x: 12, y: 8), GridPosition(x: 21, y: 8),
        ])
        map.placeBuilding(zone: .airport, origin: GridPosition(x: 4, y: 14))

        let (scene, view, controller) = makeScene(map)
        controller.isRunning = true

        func positions(_ name: String) -> [CGPoint] {
            var found: [CGPoint] = []
            scene.enumerateChildNodes(withName: "//\(name)") { node, _ in
                found.append(node.position)
            }
            return found
        }

        // **Two views, because no single one carries all three.** Ambient
        // cars are drawn only where the road network is shown, and the route
        // diagram only in its own line's view — a schematic run between
        // stations would be a lie about where a bus goes if it were drawn
        // over Normal. The first version of this test asked for both at once
        // and measured a city with no cars in it.
        _ = try advance(scene, view, frames: 2)
        var counts = scene.drivenAnimationCountForTesting
        XCTAssertGreaterThan(counts.cars, 0, "no ambient traffic in Normal view")
        XCTAssertEqual(counts.aircraft, 1, "no aircraft in the fixture")
        let cars = positions(GameScene.trafficCarNodeNameForTesting)
        let plane = positions(IsoTileRenderer.aircraftNodeName)

        // Long enough to clear the aircraft's 2.5-second wait at the
        // threshold, which is most of its cycle: it is parked and invisible
        // for more than half of every take-off, deliberately.
        _ = try advance(scene, view, frames: 240)
        XCTAssertNotEqual(cars, positions(GameScene.trafficCarNodeNameForTesting),
                          "the ambient traffic did not advance")
        XCTAssertNotEqual(plane, positions(IsoTileRenderer.aircraftNodeName),
                          "the aircraft never left the threshold")

        controller.overlayMode = .bus
        scene.refreshAll()
        _ = try advance(scene, view, frames: 2)
        counts = scene.drivenAnimationCountForTesting
        print("driven per frame — cars \(cars.count) (Normal), diagram \(counts.diagram), "
              + "aircraft \(counts.aircraft)")
        XCTAssertGreaterThan(counts.diagram, 0, "no vehicle running the route diagram")
        let diagram = positions(GameScene.transitVehicleNodeNameForTesting)
        _ = try advance(scene, view, frames: 120)
        XCTAssertNotEqual(diagram, positions(GameScene.transitVehicleNodeNameForTesting),
                          "the vehicle running the route diagram did not advance")
    }

    /// **What driving the cars in Swift costs**, which the roadmap said to
    /// measure before adopting rather than after.
    ///
    /// The worry was real in shape: `SKAction` evaluation is native, a
    /// built-out city has over a thousand road tiles, and replacing something
    /// the engine does with something this file does is the kind of trade
    /// that has to be checked. It is checked here on the largest city that
    /// exists rather than on a fixture sized to flatter it.
    func testDrivingTheTrafficCostsAlmostNothing() throws {
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "needs the Apex city — mint it with TEST_RUNNER_MINT_CITIES=1")
        let map = try CitySaveFile.read(from: url).map
        let (scene, _, controller) = makeScene(map, ticks: 0)
        controller.isRunning = true
        _ = scene.update(0)
        scene.update(1 / 60)

        let cars = scene.trafficCarCountForTesting
        // The minimum of several batches, for the reason `RenderTimingTests`
        // documents: every sample is the true cost plus whatever else the
        // machine was doing, so the distribution has a floor and no ceiling.
        var best = Double.greatestFiniteMagnitude
        for batch in 0 ..< 5 {
            let started = Date()
            for frame in 0 ..< 60 {
                scene.update(TimeInterval(batch * 60 + frame + 2) / 60)
            }
            best = min(best, Date().timeIntervalSince(started) / 60 * 1000)
        }
        print(String(format: "%d cars driven — %.3f ms per update() on a 64×64 city", cars, best))
        XCTAssertGreaterThan(cars, 200, "the largest city in the project has almost no traffic "
                             + "in it, so this measures nothing")
        XCTAssertLessThan(best, 4.0,
                          "driving the ambient traffic costs \(best) ms a frame, which is a "
                          + "quarter of a 60fps budget — it belonged back on SKAction")
    }

    /// The flythrough, for looking at rather than asserting on.
    ///
    /// Opt-in: a few seconds at this size is a few hundred full renders, which
    /// is a long time to spend inside the ordinary suite for a picture nobody
    /// asked for on that run.
    func testRecordAFlythrough() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RECORD"] != nil,
                          "set TEST_RUNNER_RECORD=1 to write a recording")

        let name = ProcessInfo.processInfo.environment["RECORD_CITY"] ?? "Apex"
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("\(name).alphacity")
        let map: CityMap
        if FileManager.default.fileExists(atPath: url.path) {
            map = try CitySaveFile.read(from: url).map
        } else {
            map = cityWithATramLine()
        }

        let (scene, view, controller) = makeScene(map)
        scene.size = CGSize(width: 1280, height: 800)
        view.frame = NSRect(origin: .zero, size: scene.size)
        controller.isRunning = true
        scene.rebuildEntireGrid()
        scene.refreshAll()
        scene.centerCameraOnMap()

        let content = scene.contentBoundsForTesting
        let wide = max(content.width / scene.size.width, content.height / scene.size.height) * 1.04
        let close: CGFloat = 0.5

        let recorder = SceneRecorder(scene: scene, view: view, fps: 30)
        recorder.record(seconds: 8) { _, progress, scene in
            // A slow push in from the whole city to street level, which is the
            // move that shows the detail tier crossing and whether it pops —
            // and then it *holds* for the last third, because a camera that
            // never stops moving hides whether anything else is moving.
            let travel = min(1, progress / 0.66)
            let eased = travel * travel * (3 - 2 * travel)   // smoothstep
            scene.setCameraScaleForTesting(wide + (close - wide) * eased)
        }
        recorder.writeMovie(named: "\(name)-push-in")
        recorder.writeFilmstrip(named: "\(name)-push-in")
    }
}
