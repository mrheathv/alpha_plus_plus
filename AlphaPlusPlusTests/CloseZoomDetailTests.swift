import XCTest
import SpriteKit
@testable import AlphaPlusPlus

/// **What zooming in actually shows, at the size it is actually shown at.**
///
/// Every other render in this project photographs a building at whatever size
/// is convenient, which is the mistake `NeonStyle.minimumDetailSize` was
/// written about one level up. The question here is narrower and needs its own
/// instrument: at `GameScene.minimumZoomScale` on a Retina display a lot is
/// magnified **four times**, and what is being asked is whether what arrives
/// there is a building or a photograph of one.
///
/// So both panels are captured at 4×, side by side, from the same massing —
/// the standard texture on the left, the near-detail one on the right.
@MainActor
final class CloseZoomDetailTests: XCTestCase {

    /// Retina (2×) times the closest camera (`GameScene.minimumZoomScale`,
    /// 0.5). The worst case the game can actually put on a screen.
    private let magnification: CGFloat = 4

    private static var sheetDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ContactSheet")
    }

    private func capture(_ node: SKNode, size: CGSize, view: SKView) -> NSImage? {
        let scene = SKScene(size: size)
        scene.backgroundColor = SKColor(white: 0.04, alpha: 1)
        scene.addChild(node)
        view.frame = NSRect(origin: .zero, size: size)
        view.presentScene(scene)
        guard let texture = view.texture(from: scene,
                                         crop: CGRect(origin: .zero, size: size)) else { return nil }
        return NSImage(cgImage: texture.cgImage(), size: size)
    }

    /// The building magnified the way the camera magnifies it.
    private func shot(_ zone: ZoneType, _ density: Int,
                      detail: IsometricBuilding.Detail,
                      cache: IsoTextureCache, view: SKView) -> (NSImage, CGSize)? {
        guard let rendered = cache.rendered(for: zone, density: density,
                                            seed: GridPosition(x: 0, y: 0),
                                            detail: detail) else { return nil }
        let pixels = CGSize(width: rendered.size.width * magnification,
                            height: rendered.size.height * magnification)
        let sprite = SKSpriteNode(texture: rendered.texture, size: rendered.size)
        sprite.setScale(magnification)
        sprite.position = CGPoint(x: pixels.width / 2, y: pixels.height / 2)
        guard let image = capture(sprite, size: pixels, view: view) else { return nil }
        return (image, rendered.size)
    }

    func testNearDetailAtTheZoomTheGameCanReach() throws {
        let projection = Isometric(tileWidth: 64)
        let cache = IsoTextureCache(projection: projection)
        let view = SKView()

        // Top tier of each growable zone — the buildings carrying the most
        // marks, which is where a detail tier has the most to add.
        let subjects: [(ZoneType, Int)] = [(.residential, 5), (.commercial, 5), (.industrial, 5)]

        var panels: [NSImage] = []
        for (zone, density) in subjects {
            guard let far = shot(zone, density, detail: .standard, cache: cache, view: view),
                  let near = shot(zone, density, detail: .near, cache: cache, view: view) else {
                return XCTFail("\(zone) \(density) produced no building")
            }
            print("\(zone) tier \(RenderPalette.growthTier(for: density)): "
                  + "\(Int(far.1.width))×\(Int(far.1.height)) points, "
                  + "shown at \(Int(far.1.width * magnification))×"
                  + "\(Int(far.1.height * magnification)) pixels")
            panels.append(far.0)
            panels.append(near.0)
        }

        let gap: CGFloat = 12
        let width = panels.map(\.size.width).reduce(0, +) + gap * CGFloat(panels.count + 1)
        let height = (panels.map(\.size.height).max() ?? 0) + gap * 2
        let sheet = NSImage(size: CGSize(width: width, height: height))
        sheet.lockFocus()
        NSColor(white: 0.04, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        var x = gap
        for panel in panels {
            panel.draw(at: CGPoint(x: x, y: gap), from: .zero, operation: .sourceOver, fraction: 1)
            x += panel.size.width + gap
        }
        sheet.unlockFocus()

        let directory = Self.sheetDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("close-zoom-detail.png")
        guard let tiff = sheet.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("could not encode the sheet")
        }
        try png.write(to: url)
        print("wrote \(url.path)")
    }

    /// The near tier has to actually add marks, and has to stay the *same
    /// building* while doing it.
    ///
    /// The second half is the one that would fail silently. `rendered` draws
    /// from `canonicalSeed(for: variant(for:))`, so if the near path ever took
    /// the lot's own seed instead, every building in sight would change shape
    /// as the player zoomed in — which is not a detail tier, it is the city
    /// rearranging itself.
    func testNearDetailAddsMarksToTheSameBuilding() throws {
        let projection = Isometric(tileWidth: 64)
        let seed = GridPosition(x: 3, y: 7)
        let canonical = IsoTextureCache.canonicalSeed(for: IsoTextureCache.variant(for: seed))
        let massing = try XCTUnwrap(ZoneMassing.make(for: .commercial, density: 5, seed: canonical))
        let accent = ZoneMassing.accent(for: .commercial, density: 5)

        func node(_ detail: IsometricBuilding.Detail) -> SKNode {
            IsometricBuilding.node(for: massing, accent: accent, tier: 3,
                                   in: projection, detail: detail)
        }
        let far = node(.standard)
        let near = node(.near)

        XCTAssertGreaterThan(near.children.count, far.children.count,
                             "the near tier drew no more marks than the standard one")

        // Same building: the marks sit on it rather than replacing it, so the
        // silhouette must not move.
        let a = far.calculateAccumulatedFrame(), b = near.calculateAccumulatedFrame()
        XCTAssertEqual(a.minX, b.minX, accuracy: 0.5, "the near tier moved the silhouette")
        XCTAssertEqual(a.maxX, b.maxX, accuracy: 0.5, "the near tier moved the silhouette")
        XCTAssertEqual(a.minY, b.minY, accuracy: 0.5, "the near tier moved the silhouette")
        XCTAssertEqual(a.maxY, b.maxY, accuracy: 0.5, "the near tier moved the silhouette")

        let cache = IsoTextureCache(projection: projection)
        let standard = try XCTUnwrap(cache.rendered(for: .commercial, density: 5, seed: seed))
        let detailed = try XCTUnwrap(cache.rendered(for: .commercial, density: 5, seed: seed,
                                                    detail: .near))
        XCTAssertNotEqual(standard.texture, detailed.texture,
                          "both detail levels came back with one texture — the key ignores detail")
        XCTAssertEqual(standard.size.width, detailed.size.width, accuracy: 0.5)
        XCTAssertEqual(standard.size.height, detailed.size.height, accuracy: 0.5)
    }

    // MARK: - The camera drives the tier

    private func cityWithATower() -> CityMap {
        var map = CityMap(width: 12, height: 12)
        for x in 2 ..< 10 { map[GridPosition(x: x, y: 5)].zone = .road }
        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 4, y: 6))
        for cell in map.footprintCells(origin: GridPosition(x: 4, y: 6), size: 2) {
            map[cell].density = 5
        }
        return map
    }

    /// The tier has to be driven by the camera, and it has to *reach the map*.
    ///
    /// Both halves matter and the second is the one that would fail quietly.
    /// This project has shipped a control that compiled and changed nothing
    /// twice — `SKAction.colorize` on a plain node, and an overlay tint cast
    /// to a type the ground had stopped being — and a detail tier is exactly
    /// that shape of risk, because the sprite on screen comes out of a cache
    /// that would happily hand back the texture it already had.
    func testZoomingInSwapsTheBuildingsForTheirDetailedTexture() {
        let controller = GameController(map: cityWithATower(), rng: SeededRNG(seed: 4))
        let scene = GameScene(controller: controller)
        scene.size = CGSize(width: 900, height: 700)
        let view = SKView(frame: NSRect(origin: .zero, size: scene.size))
        view.presentScene(scene)
        scene.rebuildEntireGrid()
        scene.refreshAll()

        func towerTexture() -> SKTexture? {
            let node = scene.tileNodesForTesting[GridPosition(x: 4, y: 6)]
            let building = node?.children.first {
                $0.name == IsoTileRenderer.buildingNodeName
            }
            return (building as? SKSpriteNode)?.texture
        }

        // **The swap is spread over frames now, and the test says how many.**
        //
        // A tier change used to redraw every visible lot on the frame the
        // camera crossed the threshold, which measured as a 49 ms hitch —
        // three dropped frames, felt in play as the game glitching during a
        // zoom. The lots queue instead, a few per frame. So the property is
        // no longer "it happened instantly" but "it happened *promptly*", and
        // a bound is what makes that a claim rather than a shrug.
        var clock: TimeInterval = 0
        /// Runs frames until the queue is empty, and says how many it took.
        /// A bound rather than a fixed count, because how long the queue is
        /// depends on how many lots the fixture has — and what the test wants
        /// to pin is that it *ends*, promptly, not that it ends in exactly
        /// thirty frames of some particular city.
        @discardableResult
        func settle(within frames: Int = 90) -> Int {
            for spent in 0 ..< frames {
                clock += 1.0 / 60
                scene.update(clock)
                if scene.pendingRefreshCountForTesting == 0 { return spent + 1 }
            }
            return frames
        }

        scene.setCameraScaleForTesting(1.0)
        settle()
        XCTAssertEqual(scene.buildingDetailForTesting, .standard)
        let far = towerTexture()
        XCTAssertNotNil(far, "the tower drew no sprite to compare")

        scene.setCameraScaleForTesting(0.5)
        clock += 1.0 / 60
        scene.update(clock)
        XCTAssertEqual(scene.buildingDetailForTesting, .near,
                       "zooming to the closest camera did not reach the near tier")
        let framesToSwap = settle()
        print("the detail swap finished in \(framesToSwap) frames")
        XCTAssertEqual(scene.pendingRefreshCountForTesting, 0,
                       "a second and a half of frames did not finish redrawing the lots")
        // Prompt, not instant. Ninety frames would be a second and a half of
        // visibly mixed detail; this should be a fraction of that.
        XCTAssertLessThan(framesToSwap, 60,
                          "the detail swap took \(framesToSwap) frames to finish")
        let near = towerTexture()
        XCTAssertNotNil(near)
        XCTAssertNotEqual(far, near,
                          "the tier changed and the sprite kept the texture it already had")

        // And back again, so the far view is not left paying for marks it
        // cannot resolve.
        scene.setCameraScaleForTesting(1.4)
        settle()
        XCTAssertEqual(scene.buildingDetailForTesting, .standard)
        XCTAssertEqual(towerTexture(), far, "coming back out did not restore the far texture")
    }

    /// A pinch resting on the boundary must not flip the map back and forth.
    ///
    /// Same property `CitySimulator.declineMargin` exists for, and the same
    /// failure: read one number in both directions and a value sitting on it
    /// oscillates forever — here at the cost of a full refresh every frame.
    func testTheBoundaryHasHysteresis() {
        let controller = GameController(map: cityWithATower(), rng: SeededRNG(seed: 4))
        let scene = GameScene(controller: controller)
        scene.size = CGSize(width: 900, height: 700)
        let view = SKView(frame: NSRect(origin: .zero, size: scene.size))
        view.presentScene(scene)
        scene.rebuildEntireGrid()
        scene.refreshAll()

        scene.setCameraScaleForTesting(0.5)
        scene.update(0)
        XCTAssertEqual(scene.buildingDetailForTesting, .near)

        // Just past the engage point, which a single threshold would read as
        // "far" immediately.
        scene.setCameraScaleForTesting(0.75)
        scene.update(1)
        XCTAssertEqual(scene.buildingDetailForTesting, .near,
                       "the tier flipped inside the dead band")

        scene.setCameraScaleForTesting(0.9)
        scene.update(2)
        XCTAssertEqual(scene.buildingDetailForTesting, .standard)
    }
}
