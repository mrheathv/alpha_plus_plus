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

    /// **Is M0 playable on a big city?** Apex is the densest 64×64 fixture.
    /// Two costs: rebuilding the whole mesh, which happens on every tick until
    /// M1, and drawing a Retina-sized frame, at the resting camera and with
    /// the whole city in view.
    func testWhatApexCostsToDraw() throws {
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "needs Apex")
        let map = try CitySaveFile.read(from: url).map
        let renderer = try XCTUnwrap(MetalCityRenderer())
        let projection = Isometric()
        let bounds = projection.contentBounds(of: map)
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let size = CGSize(width: 2880, height: 1800)

        let built = Date()
        renderer.update(map, revision: nil)
        let rebuildCold = Date().timeIntervalSince(built) * 1000
        let rebuiltAgain = Date()
        renderer.update(map, revision: nil)
        let rebuildWarm = Date().timeIntervalSince(rebuiltAgain) * 1000

        var report = String(format: "apex rebuild: %.1f ms cold, %.1f ms with the building cache warm\n",
                            rebuildCold, rebuildWarm)
        for (label, scale) in [("resting camera", 0.5), ("whole city", 3.0)] as [(String, CGFloat)] {
            let camera = MetalCityRenderer.Camera(centre: centre, scale: scale, size: size)
            // Twice, and report the second: the first pays for pipeline and
            // texture set-up that a running game has already paid.
            _ = renderer.render(map, camera: camera, wetness: 1)
            let frame = try XCTUnwrap(renderer.render(map, camera: camera, wetness: 1))
            report += String(format: "apex %@: %.2f ms GPU at 2880×1800, %d triangles, %d lights\n",
                             label, frame.gpuMilliseconds, frame.triangles, frame.lights)
        }
        try report.write(to: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/ContactSheet/metal-apex.txt"),
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
