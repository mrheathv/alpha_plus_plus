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

    private func makeScene(_ map: CityMap) -> (GameScene, SKView, GameController) {
        let controller = GameController(map: map, rng: SeededRNG(seed: 4),
                                        peakPopulation: Unlocks.everythingUnlocked)
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

        // **The bound is low because almost nothing in this game moves per
        // frame**, and that is the recorder's first finding rather than a
        // weak test. A single tram is 0.06% of the frame; road traffic, the
        // diagram vehicles and the aircraft are all `SKAction`s, which
        // SpriteKit runs on its own loop and which therefore do not advance
        // here at all. When they move onto the per-frame driver this number
        // should rise by an order of magnitude, and this bound should be
        // raised with it rather than left as a floor nothing can fail.
        XCTAssertGreaterThan(movedWhileRunning, 0.0002,
                             "nothing in the city was redrawn over a full second — the map has "
                             + "frozen, which is how the texture cache once broke the game")
        XCTAssertLessThan(movedWhilePaused, movedWhileRunning / 4,
                          "the city kept moving while paused — the bug where ambient traffic "
                          + "went on driving around a stopped map")
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
            // move that shows the detail tier crossing and whether it pops.
            let eased = progress * progress * (3 - 2 * progress)   // smoothstep
            scene.setCameraScaleForTesting(wide + (close - wide) * eased)
        }
        recorder.writeMovie(named: "\(name)-push-in")
        recorder.writeFilmstrip(named: "\(name)-push-in")
    }
}
