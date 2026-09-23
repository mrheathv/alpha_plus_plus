import AppKit
import SpriteKit
import XCTest
@testable import AlphaPlusPlus

/// **The spike's verdict, as a picture.** One block, drawn by the game's
/// SpriteKit renderer and by the Metal spike from the *same map at the same
/// moment*, through the same camera — dry, and in the day-6 downpour.
///
/// ```sh
/// xcodebuild -project AlphaPlusPlus.xcodeproj -scheme AlphaPlusPlus -testPlan Full \
///            -configuration Release -derivedDataPath ./build ENABLE_TESTABILITY=YES \
///            test -only-testing:AlphaPlusPlusTests/MetalSpikeTests
/// open ./build/ContactSheet/metal-spike.png
/// ```
@MainActor
final class MetalSpikeTests: XCTestCase {

    /// A dense block: towers of all three zones, a landmark-height office,
    /// civic buildings, a park, streets on three sides and open ground in front
    /// — so the lighting has walls to fall on and the wet street has something
    /// to reflect.
    static func block() -> CityMap {
        var map = CityMap(width: 18, height: 16)
        for x in 0 ..< 18 {
            map[GridPosition(x: x, y: 5)].zone = .road
            map[GridPosition(x: x, y: 10)].zone = .road
        }
        for y in 0 ..< 16 {
            map[GridPosition(x: 4, y: y)].zone = .road
            map[GridPosition(x: 11, y: y)].zone = .road
        }
        let lots: [(ZoneType, GridPosition, Int)] = [
            (.commercial, GridPosition(x: 5, y: 3), 5), (.residential, GridPosition(x: 7, y: 3), 4),
            (.commercial, GridPosition(x: 9, y: 3), 4), (.residential, GridPosition(x: 12, y: 3), 5),
            (.industrial, GridPosition(x: 14, y: 3), 3), (.residential, GridPosition(x: 2, y: 3), 3),
            (.commercial, GridPosition(x: 5, y: 6), 5), (.residential, GridPosition(x: 7, y: 6), 3),
            (.commercial, GridPosition(x: 9, y: 8), 3), (.residential, GridPosition(x: 12, y: 6), 4),
            (.commercial, GridPosition(x: 12, y: 8), 5), (.industrial, GridPosition(x: 14, y: 7), 4),
            (.residential, GridPosition(x: 2, y: 7), 4), (.commercial, GridPosition(x: 5, y: 11), 4),
            (.residential, GridPosition(x: 7, y: 11), 5),
        ]
        for (zone, origin, density) in lots {
            map.placeBuilding(zone: zone, origin: origin)
            for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = density }
        }
        map.placeBuilding(zone: .park, origin: GridPosition(x: 9, y: 6))
        map.placeBuilding(zone: .fireStation, origin: GridPosition(x: 12, y: 11))
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 2, y: 11))
        map.placeBuilding(zone: .powerPlant, origin: GridPosition(x: 14, y: 12))
        for tile in map.tiles where Traffic.isRoadLike(tile.zone) {
            map[tile.position].hasPipe = true
            map[tile.position].hasPowerLine = true
        }
        return map
    }

    private static var timings = ""

    func testRenderTheSpikeBesideSpriteKit() throws {
        let size = CGSize(width: 1200, height: 800)
        let scale: CGFloat = 0.72
        let game = ScenePlaytest(map: Self.block(), size: size)
        game.controller.setFundingLevel(4, for: .waterTower)
        game.controller.setFundingLevel(4, for: .powerPlant)
        let renderer = try XCTUnwrap(MetalCityRenderer(), "no Metal device, or the shaders did not compile")

        func frameBoth(_ label: String, wetness: Float, scale: CGFloat = scale) throws -> [(String, NSImage)] {
            game.scene.centerCameraOnMap()
            game.scene.camera?.setScale(scale)
            game.frame()
            game.frame()
            let texture = try XCTUnwrap(game.scene.view?.texture(from: game.scene,
                                                                crop: CGRect(origin: .zero, size: size)))
            let sprite = NSImage(cgImage: texture.cgImage(), size: size)

            let camera = MetalCityRenderer.Camera(centre: game.scene.cameraPositionForTesting,
                                                  scale: scale, size: size)
            let frame = try XCTUnwrap(renderer.render(game.controller.map, camera: camera, wetness: wetness))
            let line = String(format: "metal %@: %.2f ms GPU, %d triangles, %d lights\n",
                              label, frame.gpuMilliseconds, frame.triangles, frame.lights)
            Self.timings += line
            print(line)
            return [("SpriteKit — \(label)", sprite),
                    ("Metal spike — \(label)", NSImage(cgImage: frame.image, size: size))]
        }

        var frames = try frameBoth("dry", wetness: 0)
        game.play()
        game.tick(6)
        XCTAssertGreaterThan(game.scene.wetnessForTesting, 0, "day 6 should be raining")
        frames += try frameBoth("day 6, raining", wetness: 1)
        // Close in, where SpriteKit is showing pictures magnified and the
        // spike is still drawing geometry — `GameScene.minimumZoomScale`.
        frames += try frameBoth("closest zoom, raining", wetness: 1, scale: 0.5)
        try Self.writeGrid(frames, columns: 2, cell: size, named: "metal-spike")
        try Self.timings.write(to: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/ContactSheet/metal-spike.txt"),
                               atomically: true, encoding: .utf8)
    }

    /// **Reflections, judged where they are strongest**: a waterfront block
    /// facing a street and a river, close in, dry and in rain. Water mirrors
    /// the city always; the street is glossy dry and a mirror wet.
    func testRenderTheWaterfront() throws {
        var map = CityMap(width: 18, height: 16)
        for x in 0 ..< 18 { map[GridPosition(x: x, y: 8)].zone = .road }
        for y in 9 ..< 16 { for x in 0 ..< 18 { map[GridPosition(x: x, y: y)].isWater = true } }
        // The avenue runs on across the river as a bridge.
        for y in 0 ..< 16 { map[GridPosition(x: 8, y: y)].zone = .road }
        let lots: [(ZoneType, GridPosition, Int)] = [
            (.commercial, GridPosition(x: 2, y: 6), 5), (.residential, GridPosition(x: 4, y: 6), 4),
            (.commercial, GridPosition(x: 6, y: 6), 4), (.commercial, GridPosition(x: 9, y: 6), 5),
            (.residential, GridPosition(x: 11, y: 6), 5), (.industrial, GridPosition(x: 13, y: 6), 3),
            (.commercial, GridPosition(x: 15, y: 6), 4), (.residential, GridPosition(x: 4, y: 3), 5),
            (.commercial, GridPosition(x: 10, y: 3), 5),
        ]
        for (zone, origin, density) in lots {
            map.placeBuilding(zone: zone, origin: origin)
            for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = density }
        }
        let renderer = try XCTUnwrap(MetalCityRenderer())
        let size = CGSize(width: 1200, height: 800)
        let centre = Isometric().project(9, 9, 0)
        var frames: [(String, NSImage)] = []
        for (label, wetness) in [("dry — glossy street, mirror river", Float(0)),
                                 ("raining", Float(1))] {
            let camera = MetalCityRenderer.Camera(centre: centre, scale: 0.55, size: size)
            let frame = try XCTUnwrap(renderer.render(map, camera: camera, wetness: wetness, time: 3))
            frames.append(("Metal — \(label)", NSImage(cgImage: frame.image, size: size)))
        }
        try Self.writeGrid(frames, columns: 1, cell: size, named: "metal-waterfront")
    }

    /// Frames in a grid with a caption over each, written beside the other
    /// contact sheets.
    static func writeGrid(_ frames: [(String, NSImage)], columns: Int, cell: CGSize, named name: String) throws {
        let caption: CGFloat = 34
        let rows = (frames.count + columns - 1) / columns
        let canvas = NSSize(width: cell.width * CGFloat(columns),
                            height: (cell.height + caption) * CGFloat(rows))
        let image = NSImage(size: canvas)
        image.lockFocus()
        NSColor(calibratedRed: 0.03, green: 0.02, blue: 0.06, alpha: 1).setFill()
        NSRect(origin: .zero, size: canvas).fill()
        for (index, frame) in frames.enumerated() {
            let column = index % columns, row = index / columns
            let top = canvas.height - CGFloat(row) * (cell.height + caption)
            frame.1.draw(in: NSRect(x: CGFloat(column) * cell.width, y: top - caption - cell.height,
                                    width: cell.width, height: cell.height))
            (frame.0 as NSString).draw(
                at: NSPoint(x: CGFloat(column) * cell.width + 14, y: top - caption + 9),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold),
                                 .foregroundColor: NSColor.white])
        }
        image.unlockFocus()
        let data = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation ?? Data())?
            .representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ContactSheet/\(name).png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        print("🟪 \(url.path)")
    }
}

/// **M0's two questions, measured on the biggest city there is.**
@MainActor
final class MetalMapTests: XCTestCase {

    /// Switching renderer hides the city in the SpriteKit scene and keeps what
    /// SpriteKit still owns — and switching back restores it exactly.
    func testTheSceneHandsTheCityToMetalAndBack() {
        var map = CityMap(width: 12, height: 12)
        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 4, y: 4))
        let game = ScenePlaytest(map: map)
        game.scene.setDrawsCity(false)
        XCTAssertFalse(game.scene.drawsCity)
        XCTAssertEqual(game.scene.backgroundColor.alphaComponent, 0, "the Metal map would be hidden behind it")
        game.click(.road, at: GridPosition(x: 1, y: 1))
        XCTAssertEqual(game.controller.map[GridPosition(x: 1, y: 1)].zone, .road,
                       "input still goes through the scene")
        // While Metal draws the city the scene does no tile work at all, so
        // a building placed and a day ticked in that time have to be caught
        // up in one pass when the city is handed back.
        game.click(.commercial, at: GridPosition(x: 8, y: 1))
        game.play()
        game.tick(2)
        game.scene.setDrawsCity(true)
        game.check("after handing the city back")
    }

    /// **The live path draws.** The renderer writes the finished frame into
    /// the view's drawable from a compute kernel, which only works when the
    /// drawable allows shader writes — and nothing else in the suite goes
    /// near a drawable. So: the real view, in a real (offscreen) window,
    /// asked for a real frame.
    func testTheLiveViewPresentsFrames() throws {
        var map = CityMap(width: 12, height: 12)
        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 4, y: 4))
        map[GridPosition(x: 4, y: 4)].density = 3
        let game = ScenePlaytest(map: map)
        let coordinator = MetalMapView.Coordinator(controller: game.controller, scene: game.scene)
        let renderer = try XCTUnwrap(coordinator.renderer)
        let view = PassThroughMTKView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.delegate = coordinator
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        // A window made in code frees itself on close by default, and this
        // one is also released when the test ends — a double free.
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.draw()
        view.draw()
        XCTAssertGreaterThan(renderer.framesPresented, 0, "the live view never presented a frame")
        window.close()
    }

    /// The map revision moves on every change, which is how the renderer
    /// knows to rebuild without comparing whole maps.
    func testEveryEditMovesTheRevision() {
        let controller = GameController(rng: AlwaysZeroRNG())
        let start = controller.mapRevision
        controller.selectTool(.road)
        controller.place(at: GridPosition(x: 2, y: 2))
        XCTAssertGreaterThan(controller.mapRevision, start)
        let placed = controller.mapRevision
        controller.advanceSimulation()
        XCTAssertGreaterThan(controller.mapRevision, placed)
    }

    /// **M1's budget, on the biggest city there is.** Apex is the densest
    /// 64×64 fixture, drawn at the full size of a 16-inch Retina panel.
    ///
    /// Each figure is the best of several runs: a sample is the true cost
    /// plus whatever else the machine was doing, so the floor is the honest
    /// estimate and the mean is not (see `RenderTimingTests`). Written to
    /// `metal-apex.txt` as well as asserted, because a number in a file is
    /// what makes a regression visible before it fails a bound.
    func testApexFitsTheFrameBudget() throws {
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "needs Apex")
        var map = try CitySaveFile.read(from: url).map
        let renderer = try XCTUnwrap(MetalCityRenderer())
        let bounds = Isometric().contentBounds(of: map)
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let size = CGSize(width: 2880, height: 1800)
        func ms(_ work: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            work()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }

        let cold = ms { renderer.update(map, revision: nil) }
        let coldChunks = renderer.chunksRebuiltLastUpdate

        // A day that changes nothing drawn: every tile compared, none rebuilt.
        let quiet = (0 ..< 5).map { _ in ms { renderer.update(map, revision: nil) } }.min() ?? 0
        XCTAssertEqual(renderer.chunksRebuiltLastUpdate, 0, "an unchanged city rebuilt chunks")

        // One building placed: only the chunk it lands in, and its neighbours
        // where a lane line or a lot edge reads across the border.
        let spot = map.tiles.first { $0.zone == .empty && !$0.isWater }?.position ?? GridPosition(x: 0, y: 0)
        map.placeBuilding(zone: .park, origin: spot)
        let placed = ms { renderer.update(map, revision: nil) }
        let placedChunks = renderer.chunksRebuiltLastUpdate
        XCTAssertLessThanOrEqual(placedChunks, 4, "one park rebuilt \(placedChunks) chunks")

        var report = String(format: "apex update: cold %.1f ms (%d chunks) · unchanged %.2f ms · one placement %.2f ms (%d chunks)\n",
                            cold, coldChunks, quiet, placed, placedChunks)
        // **Warm the GPU first.** Apple GPUs start at a low clock and ramp up
        // under sustained load, and the first version of this test measured
        // that ramp: 12.5 ms for a frame that costs 7.65 once the GPU is
        // awake. A running game never draws from cold, so neither does this.
        let warm = MetalCityRenderer.Camera(centre: centre, scale: 0.5, size: size)
        for _ in 0 ..< 30 { _ = renderer.render(map, camera: warm, wetness: 1) }

        // M1's target from the migration plan is 8 ms of GPU at the resting
        // camera on the densest city — half a 60 fps frame, leaving the rest
        // for everything M2 to M4 still have to add. It measures 7.7 on this
        // M3. The bound is 9, not 8: a bound that holds by 4% is a coin toss
        // on this machine's timing noise, and this file already records what
        // those cost. `metal-apex.txt` carries the real figure every run.
        for (label, scale, gpuBudget) in [("resting camera", 0.5, 9.0), ("whole city", 3.0, 8.0)]
            as [(String, CGFloat, Double)] {
            let camera = MetalCityRenderer.Camera(centre: centre, scale: scale, size: size)
            var gpu = Double.infinity, cpu = Double.infinity, drawn = 0, lights = 0
            for _ in 0 ..< 10 {
                let frame = try XCTUnwrap(renderer.render(map, camera: camera, wetness: 1))
                gpu = min(gpu, frame.gpuMilliseconds)
                cpu = min(cpu, renderer.lastEncodeMilliseconds)
                drawn = frame.triangles
                lights = frame.lights
            }
            report += String(format: "apex %@: GPU %.2f ms · CPU %.2f ms · %d triangles drawn · %d lights\n",
                             label, gpu, cpu, drawn, lights)
            XCTAssertLessThan(gpu, gpuBudget, "\(label): \(gpu) ms of GPU")
            XCTAssertLessThan(cpu, 2, "\(label): \(cpu) ms of CPU to prepare a frame")
        }
        XCTAssertLessThan(quiet, 2, "checking an unchanged city took \(quiet) ms")
        XCTAssertLessThan(placed, 4, "rebuilding after one placement took \(placed) ms")
        try report.write(to: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/ContactSheet/metal-apex.txt"),
                         atomically: true, encoding: .utf8)
    }
}

/// **Where Apex's GPU time goes**, one stage at a time — opt-in, a readout
/// for tuning rather than a check.
@MainActor
final class MetalFrameBreakdownTests: XCTestCase {
    func testWhereTheFrameGoes() throws {
        try XCTSkipUnless(TestReports.enabled, TestReports.skipReason)
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "needs Apex")
        let map = try CitySaveFile.read(from: url).map
        let renderer = try XCTUnwrap(MetalCityRenderer())
        let bounds = Isometric().contentBounds(of: map)
        let camera = MetalCityRenderer.Camera(centre: CGPoint(x: bounds.midX, y: bounds.midY),
                                              scale: 0.5, size: CGSize(width: 2880, height: 1800))
        func best(_ diagnostics: MetalCityRenderer.Diagnostics) -> Double {
            renderer.diagnostics = diagnostics
            _ = renderer.render(map, camera: camera, wetness: 1)
            return (0 ..< 10).compactMap { _ in renderer.render(map, camera: camera, wetness: 1)?.gpuMilliseconds }
                .min() ?? 0
        }
        var report = ""
        // Interleaved twice, so drift in the machine's state shows up as two
        // readings of the same row disagreeing rather than as a stage's cost.
        for round in 1 ... 2 {
            let full = best(.init())
            let noReflection = best(.init(skipReflection: true))
            let noLights = best(.init(skipPointLights: true))
            let noBloom = best(.init(skipBloom: true))
            let bare = best(.init(skipReflection: true, skipPointLights: true, skipBloom: true))
            report += String(format: "round %d: full %.2f · −reflection %.2f · −point lights %.2f · −bloom %.2f · all three off %.2f\n",
                             round, full, noReflection, noLights, noBloom, bare)
        }
        renderer.diagnostics = .init()
        try report.write(to: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/ContactSheet/metal-breakdown.txt"),
                         atomically: true, encoding: .utf8)
    }
}

/// **The player's own city, through both renderers.** A diagnostic for a
/// report from play, reading the autosave — so it skips on any machine that
/// has not played, and lives only in the Full plan.
@MainActor
final class MetalAutosaveDiagnosticTests: XCTestCase {
    func testRenderTheAutosaveBothWays() throws {
        guard let autosave = CityAutosave.standard(), autosave.available != nil else {
            throw XCTSkip("no autosave on this machine")
        }
        let map = try autosave.read().map
        // The live view: 1440×932 points on a 2880×1864 Retina panel, less
        // the chrome — about the map area a player actually sees.
        let points = CGSize(width: 1440, height: 640)
        let game = ScenePlaytest(map: map, size: points)
        game.scene.centerCameraOnMap()
        game.frame()
        game.frame()
        let texture = try XCTUnwrap(game.scene.view?.texture(from: game.scene,
                                                            crop: CGRect(origin: .zero, size: points)))
        let renderer = try XCTUnwrap(MetalCityRenderer())
        // The same camera the live view builds: scene points per *pixel*, on
        // a 2× panel.
        let camera = MetalCityRenderer.Camera(centre: game.scene.cameraCentre,
                                              scale: game.scene.cameraScale / 2,
                                              size: CGSize(width: points.width * 2, height: points.height * 2))
        let wetness = Float(Weather.wetness(onDay: map.elapsedDays))
        let frame = try XCTUnwrap(renderer.render(map, camera: camera, wetness: wetness))
        try MetalSpikeTests.writeGrid(
            [("SpriteKit — your city, day \(map.elapsedDays), camera \(game.scene.cameraScale)",
              NSImage(cgImage: texture.cgImage(), size: points)),
             ("Metal — same city, same camera", NSImage(cgImage: frame.image, size: points))],
            columns: 1, cell: points, named: "metal-autosave")
    }
}
