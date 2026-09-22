import SpriteKit
import XCTest
@testable import AlphaPlusPlus

/// **What a frame costs while the camera is moving**, which is a different
/// question from what it costs standing still.
///
/// Reported from play: *"it glitches between the zoom and scroll"* — not a
/// steady low frame rate but a hitch, and specifically while panning or
/// zooming. That points at work which only happens when the view changes, and
/// nothing in this project measured that: every render timing here has been
/// taken on a stationary camera.
@MainActor
final class CameraMotionCostTests: XCTestCase {

    /// **Judder, which is a distribution rather than a mean.**
    ///
    /// Reported from play after the averages had already come down: still
    /// stuttering when scrolling across the map. A steady 19 ms frame does
    /// not stutter — it runs at a steady 52 fps. What stutters is a frame
    /// that costs several times its neighbours, so this records *every* frame
    /// of a pan and reports the spread.
    ///
    /// It also exists to check something the previous pass may have made
    /// worse: quantising the culling to a tile turned a little work on every
    /// frame into a lot of work on one frame in several. Lower total, burstier
    /// delivery — and delivery is what smooth means.
    func testScrollingDeliversFramesEvenly() throws {
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "needs Apex")
        let map = try CitySaveFile.read(from: url).map
        let controller = GameController(map: map, rng: SeededRNG(seed: 1),
                                        peakPopulation: Unlocks.everythingUnlocked)
        let size = CGSize(width: 1280, height: 800)
        let scene = GameScene(controller: controller)
        scene.size = size
        let view = SKView(frame: NSRect(origin: .zero, size: size))
        view.presentScene(scene)
        scene.rebuildEntireGrid()
        scene.refreshAll()
        // **Paused, because this test is about the camera.**
        //
        // With the simulation running the answer is dominated by something
        // else entirely: a tick lands on one frame every couple of seconds
        // and costs 87 ms in Release — 736 in Debug — which swamps everything
        // the camera does and would make this a test of `Traffic.computeLoad`
        // wearing a scroll's clothes. That cost is real, reported, and
        // measured by `testWhatATickCostsTheFrameItLandsOn`; it is not what
        // this one is for.
        controller.isRunning = false
        scene.setCameraScaleForTesting(1.0)
        scene.update(0)
        for _ in 0 ..< 10 { _ = view.texture(from: scene) }   // warm

        // A whole frame: the update *and* the draw, which is what a player
        // waits for. Every measurement in this project until now timed one or
        // the other.
        var clock: TimeInterval = 0
        var samples: [Double] = []
        for _ in 0 ..< 150 {
            let started = Date()
            clock += 1 / 60
            scene.nudgeCameraForTesting(by: CGPoint(x: 9, y: 0))
            scene.update(clock)
            _ = view.texture(from: scene)
            samples.append(Date().timeIntervalSince(started) * 1000)
        }
        let steady = Array(samples.dropFirst(10))
        let mean = steady.reduce(0, +) / Double(steady.count)
        let worst = steady.max() ?? 0
        let sorted = steady.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[Int(Double(sorted.count) * 0.95)]
        let overBudget = steady.filter { $0 > 16.7 }.count

        print("\n=== scrolling a 64x64 city, whole frames ===")
        print(String(format: "  median %6.2f ms   mean %6.2f ms   p95 %6.2f ms",
                     median, mean, p95))
        print(String(format: "  worst  %6.2f ms   (%.1fx the median)", worst,
                     worst / max(median, 0.001)))
        print("  over 16.7 ms: \(overBudget) of \(steady.count) frames")
        // *Where* the spikes are decides what they are: one frame is a
        // one-off, a regular beat is the culling's burst.
        let spikes = samples.enumerated()
            .filter { $0.element > median * 2 }
            .map { "\($0.offset)@\(Int($0.element))ms" }
        print("  spikes: \(spikes.prefix(14).joined(separator: " "))"
              + (spikes.count > 14 ? " …\(spikes.count) total" : ""))

        // **The spread is the claim, not the mean.** A frame several times its
        // neighbours is a visible stutter however good the average is — and
        // the median being over a 60fps budget is a separate complaint about
        // how much there is to draw, not about smoothness.
        XCTAssertLessThan(worst / max(median, 0.001), 3.0,
                          "one frame of a scroll cost \(worst) ms against a median of "
                          + "\(median) — that is judder, whatever the average says")
    }

    /// **What a simulation tick costs the frame it lands on.**
    ///
    /// The scroll judder turned out to be one spike at frame 120 of a 150
    /// frame pan — 2.0 seconds in, which is exactly `SimulationSpeed.normal`'s
    /// interval. Not the camera at all: the tick, and whatever the renderer
    /// does about it, landing on a single frame every couple of seconds.
    func testWhatATickCostsTheFrameItLandsOn() throws {
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "needs Apex")
        let map = try CitySaveFile.read(from: url).map
        let controller = GameController(map: map, rng: SeededRNG(seed: 1),
                                        peakPopulation: Unlocks.everythingUnlocked)
        let size = CGSize(width: 1280, height: 800)
        let scene = GameScene(controller: controller)
        scene.size = size
        let view = SKView(frame: NSRect(origin: .zero, size: size))
        view.presentScene(scene)
        scene.rebuildEntireGrid()
        scene.refreshAll()
        // **Culling has to have run**, or every tile on the map is still
        // attached and this measures a state the game is never in. The first
        // version of this did exactly that and reported no improvement from a
        // change that only helps off-screen tiles, because it had not let any
        // tile go off screen.
        scene.setCameraScaleForTesting(1.0)
        scene.update(1.0 / 60)
        _ = view.texture(from: scene)
        var attached = 0
        for node in scene.tileNodesForTesting.values where node.parent != nil { attached += 1 }
        print("\n  \(attached) of \(scene.tileNodesForTesting.count) tiles on screen")

        func best(_ label: String, _ body: () -> Void) -> Double {
            var best = Double.greatestFiniteMagnitude
            for _ in 0 ..< 3 {
                let started = Date()
                body()
                best = min(best, Date().timeIntervalSince(started) * 1000)
            }
            print(String(format: "  %-30@ %8.1f ms", label as NSString, best))
            return best
        }

        print("\n=== the two halves of a tick, 64x64 Debug ===")
        let sim = best("controller.advanceSimulation()") { controller.advanceSimulation() }
        // The whole tick as the game runs it, which is the number that lands
        // on a frame — `refreshAll` is what it *used* to do, kept alongside so
        // the saving is visible rather than asserted.
        let draw = best("the tick's redraw") { scene.runSimulationTick() }
        _ = best("scene.refreshAll() (what it replaced)") { scene.refreshAll() }
        print("  redrew \(scene.lastTickRedrewForTesting) lots of "
              + "\(scene.tileNodesForTesting.count)")
        print(String(format: "  together %.0f ms — %.0f dropped frames at 60fps",
                     sim + draw, (sim + draw) / 16.7))
    }

    /// **Where a tick's 50 ms goes on the city the game ships.**
    ///
    /// `HarnessTimingTests` measures generated cities; this measures Apex,
    /// which is denser than any of them and carries twenty-two subway routes —
    /// and it is the city the stutter was reported on.
    func testWhereATicksTimeGoes() throws {
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "needs Apex")
        let map = try CitySaveFile.read(from: url).map

        func best(_ label: String, _ body: () -> Void) -> Double {
            var best = Double.greatestFiniteMagnitude
            for _ in 0 ..< 5 {
                let started = Date()
                body()
                best = min(best, Date().timeIntervalSince(started) * 1000)
            }
            print(String(format: "  %-34@ %7.1f ms", label as NSString, best))
            return best
        }

        print("\n=== one tick on Apex, by component ===")
        let distances = ZoneDistanceField.compute(for: map)
        _ = best("ZoneDistanceField.compute") { _ = ZoneDistanceField.compute(for: map) }
        let traffic = best("Traffic.computeLoad") { _ = Traffic.computeLoad(for: map) }
        _ = best("Pollution.compute") { _ = Pollution.compute(for: map) }
        _ = distances
        let whole = best("the whole tick") {
            var rng = SeededRNG(seed: 9)
            _ = CitySimulator.advance(map, using: &rng)
        }
        print(String(format: "  traffic is %.0f%% of the tick", traffic / max(whole, 0.001) * 100))
    }

    /// **What one core is being asked to do, and how much of it is parallel.**
    ///
    /// Asked while playing: what is the point of all these cores if a game
    /// like this struggles. A fair question, and the answer is a measurement
    /// rather than an opinion — the dominant cost is a loop whose expensive
    /// half is independent per iteration and which runs on exactly one of
    /// eight cores.
    func testHowMuchOfATickCouldUseMoreThanOneCore() throws {
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "needs Apex")
        let map = try CitySaveFile.read(from: url).map

        let homes = map.tiles.filter {
            $0.isBuildingAnchor && $0.zone == .residential && $0.density > 0
        }
        let roads = map.tiles.filter { $0.zone == .road || $0.zone == .highway }.count
        print("\n=== the shape of the work ===")
        print("  cores available:      \(ProcessInfo.processInfo.activeProcessorCount)")
        print("  homes to route:       \(homes.count)")
        print("  road tiles to search: \(roads)")

        func best(_ label: String, _ body: () -> Void) -> Double {
            var best = Double.greatestFiniteMagnitude
            for _ in 0 ..< 5 {
                let started = Date()
                body()
                best = min(best, Date().timeIntervalSince(started) * 1000)
            }
            print(String(format: "  %-36@ %7.1f ms", label as NSString, best))
            return best
        }

        let whole = best("Traffic.computeLoad (one core)") { _ = Traffic.computeLoad(for: map) }

        // **The same city with its transit lines deleted.** Apex carries 22
        // subway routes, and the per-(home, job) journey lookup walks the
        // boarding points at each end — the O(homes x jobs x reach^2) term
        // this project's own notes name as the thing to profile first. The
        // difference between these two numbers is that term, measured rather
        // than assumed, which is the fourth assumption about this file today
        // that wanted checking.
        var withoutTransit = map
        withoutTransit.transit = TransitNetwork()
        let noLines = best("the same city with no lines") {
            _ = Traffic.computeLoad(for: withoutTransit)
        }
        print(String(format: "  the transit half is %.0f%% of it", (whole - noLines) / whole * 100))

        // The same searches, run across the cores the machine has. Nothing is
        // shared and nothing is written, so this is the honest ceiling for
        // what parallelising the search half would buy — not a working
        // implementation, a measurement of the headroom.
        let drivable = Set(map.tiles.filter { $0.zone == .road || $0.zone == .highway }
            .map(\.position))
        let starts = homes.map { home -> Set<GridPosition> in
            var cells: Set<GridPosition> = []
            for cell in map.footprintCells(origin: home.position, size: home.zone.footprintSize) {
                for n in cell.orthogonalNeighbors() where drivable.contains(n) { cells.insert(n) }
            }
            return cells
        }.filter { !$0.isEmpty }

        func flood(_ sources: Set<GridPosition>) -> Int {
            var seen = sources
            var frontier = Array(sources)
            var reached = 0
            while !frontier.isEmpty {
                var next: [GridPosition] = []
                for cell in frontier {
                    reached += 1
                    for n in cell.orthogonalNeighbors()
                    where drivable.contains(n) && seen.insert(n).inserted {
                        next.append(n)
                    }
                }
                frontier = next
            }
            return reached
        }

        let serial = best("the searches alone, one core") {
            var total = 0
            for s in starts { total &+= flood(s) }
            XCTAssertGreaterThan(total, 0)
        }
        let parallel = best("the searches alone, all cores") {
            let counts = UnsafeMutableBufferPointer<Int>.allocate(capacity: starts.count)
            defer { counts.deallocate() }
            DispatchQueue.concurrentPerform(iterations: starts.count) { index in
                counts[index] = flood(starts[index])
            }
        }
        print(String(format: """
          the searches are %.0f%% of the tick, and go %.1fx faster on %d cores
        """, serial / max(whole, 0.001) * 100, serial / max(parallel, 0.001),
        ProcessInfo.processInfo.activeProcessorCount))
    }

    /// **How much of the map actually changes in a tick.**
    ///
    /// The renderer refreshes every visible tile after every tick, at 37 ms.
    /// That is only worth replacing with change-detection if the change is
    /// small — and change-detection is the most dangerous kind of cache,
    /// because getting it wrong shows as a map that is quietly out of date
    /// rather than as anything failing.
    func testHowMuchOfTheMapATickChanges() throws {
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "needs Apex")
        let controller = GameController(map: try CitySaveFile.read(from: url).map,
                                        rng: SeededRNG(seed: 1),
                                        peakPopulation: Unlocks.everythingUnlocked)
        print("\n=== what a tick actually changes ===")
        for tick in 1 ... 5 {
            let before = controller.map
            controller.advanceSimulation()
            let after = controller.map
            var tiles = 0, congestion = 0
            for index in before.tiles.indices {
                if before.tiles[index] != after.tiles[index] { tiles += 1 }
                let position = before.tiles[index].position
                let a = Traffic.congestion(at: position, in: before)
                let b = Traffic.congestion(at: position, in: after)
                // Quantised the way the renderer reads it — a lane's dimming
                // and a tile's car count are steps, not a continuum.
                if Int(a * 20) != Int(b * 20) { congestion += 1 }
            }
            print(String(format: "  tick %d: %4d tiles changed, %4d congestion steps moved, of %d",
                         tick, tiles, congestion, before.tiles.count))
        }
    }

    /// **What placing a zone costs**, which is a different path from a tick
    /// and had never been measured on a built-out city.
    ///
    /// Reported from play: lag when placing zones, and having to wait for the
    /// game to catch up. A placement does not tick the simulation — it goes
    /// through `rebuildRegion`, which is supposed to be a bounded nine-by-nine
    /// window and was measured at 4.9 ms when it was written.
    func testWhatPlacingAZoneCosts() throws {
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "needs Apex")
        let save = try CitySaveFile.read(from: url)
        let controller = GameController(map: save.map, rng: SeededRNG(seed: 1),
                                        peakPopulation: Unlocks.everythingUnlocked)
        // Restored rather than constructed, so the treasury comes with it —
        // a broke city refuses placements, and this would measure a red flash
        // rather than a rebuild.
        try controller.restore(from: save)
        let size = CGSize(width: 1280, height: 800)
        let scene = GameScene(controller: controller)
        scene.size = size
        let view = SKView(frame: NSRect(origin: .zero, size: size))
        view.presentScene(scene)
        scene.rebuildEntireGrid()
        scene.refreshAll()
        scene.setCameraScaleForTesting(1.0)
        scene.update(1.0 / 60)

        // **A road, because Apex has no room for anything bigger.** It is
        // built out by construction — zero free 2x2 lots — and a 1x1 tool on
        // the free cells exercises the same path a zone does:
        // `GameController.place`, then `GameScene.rebuildRegion`.
        controller.selectTool(.road)
        // **Cells that are actually free**, and checked afterwards. The first
        // version picked a stride across a built-out city, every placement was
        // refused, and it reported 0.00 ms — a benchmark measuring a refusal.
        // Residential is 2x2, so a scattered free *cell* is not a free
        // *lot* — the second version of this fixture found 195 single cells
        // and still placed nothing.
        let map0 = controller.map
        let free = map0.tiles
            .filter { $0.zone == .empty && !$0.isWater }
            .map(\.position)
            .filter { $0.x > 2 && $0.y > 2 && $0.x < 60 && $0.y < 60 }
        if let first = free.first {
            print("\n  refusal at \(first): "
                  + String(describing: controller.placementRefusal(of: .road, at: first)))
        }
        print("  \(free.count) free cells to lay road on")
        XCTAssertGreaterThan(free.count, 20, "nowhere to place: this measures nothing")

        // What a placement is made of, before timing the whole thing.
        func best(_ label: String, _ body: () -> Void) {
            var best = Double.greatestFiniteMagnitude
            for _ in 0 ..< 5 {
                let started = Date()
                body()
                best = min(best, Date().timeIntervalSince(started) * 1000)
            }
            print(String(format: "  %-34@ %7.2f ms", label as NSString, best))
        }
        let m = controller.map
        print("  — the pieces of one placement —")
        best("Water.computeSupply") { _ = Water.computeSupply(for: m) }
        best("Transit.tramTracks") { _ = Transit.tramTracks(in: m) }
        best("controller.recomputeUtilitySupply") { controller.recomputeUtilitySupply() }
        if let spot = free.first {
            best("scene.refresh + neighbours") {
                scene.refreshForTesting(at: spot)
            }
        }

        var samples: [Double] = []
        var clock: TimeInterval = 1
        var placed = 0
        for position in free.prefix(30) {
            let before = controller.map[position].zone
            let started = Date()
            scene.place(at: position)
            clock += 1.0 / 60
            scene.update(clock)
            samples.append(Date().timeIntervalSince(started) * 1000)
            if controller.map[position].zone != before { placed += 1 }
        }
        XCTAssertGreaterThan(placed, 20, "only \(placed) of 30 placements landed")
        let steady = Array(samples.dropFirst(3))
        let mean = steady.reduce(0, +) / Double(steady.count)
        let worst = steady.max() ?? 0
        print("\n=== placing a zone on a built-out 64x64 city ===")
        print(String(format: "  mean %6.2f ms   worst %6.2f ms   over 16.7ms: %d of %d",
                     mean, worst, steady.filter { $0 > 16.7 }.count, steady.count))
    }

    func testWhatMovingTheCameraCosts() throws {
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "needs Apex")
        let map = try CitySaveFile.read(from: url).map
        let controller = GameController(map: map, rng: SeededRNG(seed: 1),
                                        peakPopulation: Unlocks.everythingUnlocked)
        let size = CGSize(width: 1280, height: 800)
        let scene = GameScene(controller: controller)
        scene.size = size
        let view = SKView(frame: NSRect(origin: .zero, size: size))
        view.presentScene(scene)
        scene.rebuildEntireGrid()
        scene.refreshAll()
        controller.isRunning = true
        scene.setCameraScaleForTesting(1.0)
        scene.update(0)

        var clock: TimeInterval = 0

        /// Minimum of several batches, for the reason `RenderTimingTests`
        /// documents: a sample is the true cost plus whatever else the
        /// machine was doing, so the distribution has a floor and no ceiling.
        func best(_ label: String, batches: Int = 4, frames: Int = 30,
                  _ body: (Int) -> Void) -> Double {
            var best = Double.greatestFiniteMagnitude
            for _ in 0 ..< batches {
                let started = Date()
                for frame in 0 ..< frames { body(frame) }
                best = min(best, Date().timeIntervalSince(started) / Double(frames) * 1000)
            }
            print(String(format: "  %-34@ %8.3f ms", label as NSString, best))
            return best
        }

        // **Measured first, on a scene nothing else has poked.** The
        // phase breakdown below drives the camera while running only one
        // phase at a time, which leaves the scene owing a large catch-up
        // — and a run of this that measured *after* it reported 768 ms
        // for a frame that costs five. A benchmark that disturbs the
        // thing it measures is measuring itself.
        //
        // **The frame that crosses the detail threshold**, which is a
        // one-off and therefore invisible to any average. A hitch is not a
        // high mean; it is one frame that takes far too long, and the player
        // feels exactly that frame.
        print("\n=== crossing the near-detail threshold ===")
        for pass in 1 ... 2 {
            scene.setCameraForTesting(scale: 1.0)
            clock += 1 / 60
            scene.update(clock)
            var worst = 0.0
            var worstAt: CGFloat = 0
            for step in 0 ..< 40 {
                let target = 1.0 - CGFloat(step) * 0.0125   // 1.0 down to 0.5
                scene.setCameraScaleForTesting(target)
                clock += 1 / 60
                let started = Date()
                scene.update(clock)
                let ms = Date().timeIntervalSince(started) * 1000
                if ms > worst { worst = ms; worstAt = target }
            }
            print(String(format: "  pass %d: worst frame %7.1f ms at camera %.3f",
                         pass, worst, worstAt))
            // **A hitch is one frame, not an average**, which is why this
            // asserts on the maximum. Sixteen milliseconds is one frame at
            // 60fps: past it the player has visibly dropped one, and at the
            // 49 ms this measured before the refresh queue they dropped three
            // every time they crossed the threshold.
            XCTAssertLessThan(worst, 16,
                              "a frame of a pinch took \(worst) ms — zooming is dropping "
                              + "frames, which is what 'it glitches between the zoom and "
                              + "scroll' means")
        }


        print("\n=== update() only, 64×64 ===")
        scene.setCameraForTesting(scale: 1.0)
        let still = best("camera still") { _ in
            clock += 1 / 60
            scene.update(clock)
        }
        let panning = best("panning") { frame in
            clock += 1 / 60
            // A steady drag, the speed a player actually scrolls at.
            scene.nudgeCameraForTesting(by: CGPoint(x: frame.isMultiple(of: 2) ? 9 : 9, y: 0))
            scene.update(clock)
        }
        scene.setCameraForTesting(scale: 1.0)
        let zooming = best("zooming") { frame in
            clock += 1 / 60
            // A pinch across the middle of the range and back.
            let t = Double(frame) / 30
            scene.setCameraScaleForTesting(CGFloat(0.9 + 0.5 * sin(t * .pi)))
            scene.update(clock)
        }

        // Which phase a zoom is paying for. Each is driven with the same
        // camera movement, so the numbers are comparable to each other.
        print("\n=== a zooming frame, phase by phase ===")
        func phase(_ label: String, _ body: @escaping () -> Void) {
            scene.setCameraForTesting(scale: 1.0)
            var frame = 0
            _ = best(label) { _ in
                frame += 1
                let t = Double(frame % 30) / 30
                scene.setCameraScaleForTesting(CGFloat(0.9 + 0.5 * sin(t * .pi)))
                body()
            }
        }
        phase("camera move alone") {}
        phase("+ culling") { scene.runCullingForTesting() }
        phase("+ backdrop clip") { scene.runBackdropClipForTesting() }
        phase("+ bloom reach") { scene.runBloomReachForTesting() }
        phase("+ detail tier") { scene.runDetailTierForTesting() }

        print("""

          still   \(String(format: "%.3f", still)) ms
          panning \(String(format: "%.3f", panning)) ms  (\(String(format: "%.1f", panning / max(still, 0.001)))× still)
          zooming \(String(format: "%.3f", zooming)) ms  (\(String(format: "%.1f", zooming / max(still, 0.001)))× still)
        """)
    }
}
