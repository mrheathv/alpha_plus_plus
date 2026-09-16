import XCTest
import SpriteKit
@testable import AlphaPlusPlus

/// Renders a whole city isometrically, through `IsoTileRenderer` and the
/// texture cache, at every zoom the camera has.
///
/// This is the isometric streetscape: the acceptance test for everything the
/// scene has to get right that a per-building contact sheet cannot show —
/// draw order between neighbours, multi-tile buildings sorting against the
/// tiles they cover, roads joining at junctions, and whether three zones still
/// read as three zones at the size they are played at.
///
/// It replaces `IsometricSpikeTests`, whose job — deciding whether isometric
/// was worth the migration, and at what height scale — is done.
final class IsometricCityTests: XCTestCase {

    private static let tilesWide = 21
    private static let tilesHigh = 16
    private static let roadEvery = 5

    private static let zoomLevels: [(name: String, tileWidth: CGFloat)] = [
        ("zoomed in (camera 0.5)", 64),
        ("default (camera 1.0)", 32),
        ("zoomed out (camera 3.0)", 11),
    ]

    /// Height scale stays proportional to tile width, so each panel is the same
    /// city at a different zoom rather than a differently-shaped one.
    private static func projection(tileWidth: CGFloat) -> Isometric {
        Isometric(tileWidth: tileWidth, heightUnit: 32 * tileWidth / 64)
    }

    // MARK: - The city

    /// A hand-built city: roads on a grid, 2×2 lots of every zone and tier
    /// including unbuilt ones, and the services that exercise multi-tile
    /// ordering.
    private static func city() -> CityMap {
        var map = CityMap(width: tilesWide, height: tilesHigh)
        for y in 0 ..< tilesHigh {
            for x in 0 ..< tilesWide where x % roadEvery == 0 || y % roadEvery == 0 {
                map[GridPosition(x: x, y: y)].zone = .road
            }
        }

        func place(_ zone: ZoneType, _ density: Int, at origin: GridPosition) {
            let size = zone.footprintSize
            for dx in 0 ..< size {
                for dy in 0 ..< size {
                    let position = GridPosition(x: origin.x + dx, y: origin.y + dy)
                    guard map.contains(position) else { return }
                    map[position].zone = zone
                    map[position].density = density
                    map[position].buildingOrigin = origin
                }
            }
        }

        var blockIndex = 0
        for blockY in stride(from: 1, to: tilesHigh - 3, by: roadEvery) {
            for blockX in stride(from: 1, to: tilesWide - 3, by: roadEvery) {
                let zone: ZoneType = [.residential, .commercial, .industrial][blockIndex % 3]
                let distance = abs(blockX - 11) / 5 + abs(blockY - 6) / 5
                let density = [5, 3, 1, 0][min(distance, 3)]
                for dy in stride(from: 0, to: 4, by: 2) {
                    for dx in stride(from: 0, to: 4, by: 2) {
                        place(zone, density, at: GridPosition(x: blockX + dx, y: blockY + dy))
                    }
                }
                blockIndex += 1
            }
        }

        // Services, including a 3×3 that has to sort against the tiles it
        // covers — the case a per-building sheet cannot exercise.
        place(.powerPlant, 0, at: GridPosition(x: 16, y: 1))
        place(.waterTower, 0, at: GridPosition(x: 11, y: 11))
        place(.fireStation, 0, at: GridPosition(x: 6, y: 11))
        place(.school, 0, at: GridPosition(x: 1, y: 11))
        return map
    }

    private static func positions(of map: CityMap) -> [GridPosition] {
        (0 ..< map.height).flatMap { y in (0 ..< map.width).map { GridPosition(x: $0, y: y) } }
    }

    // MARK: - Assertions

    /// The whole point of the texture cache: a built-out map must cost about
    /// one sprite per building, not fifty shapes.
    func testACityCostsOneSpritePerBuilding() throws {
        let map = Self.city()
        let projection = Self.projection(tileWidth: 32)
        let renderer = IsoTileRenderer(projection: projection)

        var anchors = 0
        var buildings = 0
        for position in Self.positions(of: map) where map[position].isBuildingAnchor {
            anchors += 1
            let node = renderer.makeNode(for: map[position])
            let sprites = node.children.compactMap { $0 as? SKSpriteNode }
            buildings += sprites.contains { $0.texture != nil && $0.size.width > 8 } ? 1 : 0
            XCTAssertTrue(
                node.children.allSatisfy { !($0 is SKEffectNode) },
                "a tile node must contain no blur pass — the cache is what pays for those, once"
            )
        }
        XCTAssertGreaterThan(buildings, 20, "expected a built-out city")
        XCTAssertLessThanOrEqual(
            renderer.textures.count, BuildingTextureCache.variantCount * 12,
            "the cache should be bounded by variants, not by lots — \(anchors) anchors produced \(renderer.textures.count) textures"
        )
    }

    /// A lot must look the same on every launch. The cache picks a variant from
    /// the lot's position, and if that ever used `hashValue` — which Swift
    /// randomises per process — cities would reshuffle themselves between runs.
    func testVariantChoiceIsStable() {
        for index in 0 ..< 200 {
            let seed = GridPosition(x: index % 17, y: index / 17)
            let first = BuildingTextureCache.variant(for: seed)
            XCTAssertEqual(first, BuildingTextureCache.variant(for: seed))
            XCTAssertTrue((0 ..< BuildingTextureCache.variantCount).contains(first))
        }
        // And it must actually spread: all one variant would be a cache that
        // hits perfectly and renders one building everywhere.
        let spread = Set((0 ..< 120).map { BuildingTextureCache.variant(for: GridPosition(x: $0 % 11, y: $0 / 11)) })
        XCTAssertGreaterThan(spread.count, BuildingTextureCache.variantCount / 2)
    }

    /// Multi-tile buildings must sort in front of the tiles they cover, or a
    /// power plant is painted over by its own footprint.
    func testMultiTileBuildingsSortInFrontOfTheirFootprint() {
        let plant = GridPosition(x: 16, y: 1)
        let plantDepth = Isometric.depth(of: plant, footprint: 3)
        for dx in 0 ..< 3 {
            for dy in 0 ..< 3 {
                let covered = GridPosition(x: plant.x + dx, y: plant.y + dy)
                XCTAssertGreaterThanOrEqual(plantDepth, Isometric.depth(of: covered),
                                            "the plant sorts behind (\(covered.x), \(covered.y)), which it covers")
            }
        }
    }

    /// Re-syncing an unchanged tile must not rebuild anything.
    ///
    /// `GameScene.refreshAll()` runs every decoration for every tile on every
    /// simulation tick. Without cache keys that tears down and rebuilds
    /// thousands of shape nodes a second and re-hangs every building sprite —
    /// which is exactly the churn CLAUDE.md records as "why the map blinked".
    /// The top-down renderer grew its keys after a live playtest surfaced the
    /// problem; this pins them for the isometric one before.
    func testRefreshingAnUnchangedTileRebuildsNothing() {
        let projection = Self.projection(tileWidth: 32)
        let renderer = IsoTileRenderer(projection: projection)
        var tile = Tile(position: GridPosition(x: 3, y: 4), zone: .residential, density: 4)

        let node = renderer.makeNode(for: tile)
        let before = node.children.map { ObjectIdentifier($0) }
        renderer.update(node, for: tile)
        XCTAssertEqual(node.children.map { ObjectIdentifier($0) }, before,
                       "an unchanged tile replaced its own children")

        tile.density = 5
        renderer.update(node, for: tile)
        XCTAssertNotEqual(node.children.map { ObjectIdentifier($0) }, before,
                          "a tile that grew a tier kept its old building")
    }

    /// Switching to an overlay and back has to restore the building.
    ///
    /// The cache key is what decides whether a decoration is rebuilt, so an
    /// overlay that removed nodes without invalidating their keys would leave
    /// the map permanently blank once the player looked at land value — and it
    /// would look exactly like the overlay working.
    func testLeavingAnOverlayRestoresTheBuilding() {
        let projection = Self.projection(tileWidth: 32)
        let renderer = IsoTileRenderer(projection: projection)
        let tile = Tile(position: GridPosition(x: 2, y: 2), zone: .commercial, density: 5)

        let node = renderer.makeNode(for: tile)
        func hasBuilding() -> Bool {
            node.children.contains { ($0 as? SKSpriteNode)?.texture != nil && $0.name != nil }
        }
        XCTAssertTrue(hasBuilding())

        renderer.applyOverlay(on: node, color: .green)
        XCTAssertFalse(hasBuilding(), "the overlay left the building showing")

        renderer.update(node, for: tile)
        XCTAssertTrue(hasBuilding(), "leaving the overlay did not bring the building back")
    }

    /// What a fully built-out map actually costs the renderer.
    ///
    /// The number that matters is **nodes in the scene**, not nodes per
    /// building: `SKShapeNode` does not batch, so the scene graph's size is
    /// roughly the frame's draw-call count. Reported rather than merely
    /// asserted, because a number in a build log is what makes a regression
    /// visible before it is a stutter.
    func testBuiltOutMapCost() throws {
        var map = CityMap(width: 40, height: 40)
        for y in 0 ..< map.height {
            for x in 0 ..< map.width {
                let position = GridPosition(x: x, y: y)
                if x % 5 == 0 || y % 5 == 0 {
                    map[position].zone = .road
                } else {
                    let anchor = GridPosition(x: x - (x % 5 - 1) % 2, y: y - (y % 5 - 1) % 2)
                    map[position].zone = [.residential, .commercial, .industrial][(x / 5 + y / 5) % 3]
                    map[position].density = 5
                    map[position].buildingOrigin = anchor
                }
            }
        }

        let projection = Self.projection(tileWidth: 32)
        let renderer = IsoTileRenderer(projection: projection)
        let layer = SKNode()

        var anchors = 0
        for position in Self.positions(of: map) where map[position].isBuildingAnchor {
            anchors += 1
            layer.addChild(renderer.makeNode(for: map[position]))
        }
        let nodes = Self.nodeCount(layer)
        let perAnchor = Double(nodes) / Double(anchors)
        print("🧮 built-out 40×40 — \(anchors) anchors, \(nodes) nodes (\(String(format: "%.1f", perAnchor))/anchor), \(renderer.textures.count) textures")

        XCTAssertLessThan(perAnchor, 6, "a lot should cost a handful of nodes, not a building's worth of shapes")
        XCTAssertLessThan(renderer.textures.count, 260, "the texture cache should be bounded by variants, not lots")
    }

    private static func nodeCount(_ node: SKNode) -> Int {
        1 + node.children.reduce(0) { $0 + nodeCount($1) }
    }

    /// Rasterising a building must not disturb whatever is on screen.
    ///
    /// **The regression this exists for.** `BuildingTextureCache` renders a
    /// building by presenting a scratch scene on an `SKView` — and the first
    /// version took the view as a parameter, so `GameScene` passed its own.
    /// `presentScene` replaces what a view shows, so the first building a
    /// player placed swapped the live game out for a hundred-pixel scratch
    /// scene: the map froze, clicks stopped landing, the simulation stopped
    /// ticking. Nothing crashed and nothing logged.
    ///
    /// Every test passed, too, because a test hands the cache a scratch view of
    /// its own and never looks at it again — the bug was only reachable when
    /// the borrowed view was one somebody was watching. So this asserts the
    /// property that actually matters: a view the renderer was never given
    /// keeps showing what it was showing.
    func testRasterisingABuildingLeavesOtherScenesAlone() {
        let view = SKView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let gameScene = SKScene(size: CGSize(width: 200, height: 200))
        view.presentScene(gameScene)
        XCTAssertIdentical(view.scene, gameScene)

        let renderer = IsoTileRenderer(projection: Self.projection(tileWidth: 32))
        for density in [1, 3, 5] {
            _ = renderer.makeNode(for: Tile(position: GridPosition(x: density, y: 2),
                                            zone: .commercial, density: density))
        }
        XCTAssertIdentical(
            view.scene, gameScene,
            "rasterising a building replaced what a view was showing — this is what froze the game"
        )
    }

    // MARK: - The render

    func testRenderIsometricCity() throws {
        let map = Self.city()
        var panels: [(String, NSImage)] = []
        for level in Self.zoomLevels {
            panels.append((level.name, try render(map, tileWidth: level.tileWidth)))
        }

        let sheet = try XCTUnwrap(Self.stack(panels), "failed to stack the city panels")
        let destination = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ContactSheet/isometric-city.png")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try sheet.write(to: destination)
        print("🏙  Isometric city: \(destination.path) (\(sheet.count) bytes)")
        XCTAssertGreaterThan(sheet.count, 0)
    }

    private func render(_ map: CityMap, tileWidth: CGFloat) throws -> NSImage {
        let projection = Self.projection(tileWidth: tileWidth)
        let bounds = projection.contentBounds(of: map)
        let margin: CGFloat = 24
        let headroom = 4 * projection.heightUnit
        let size = CGSize(width: bounds.width + margin * 2, height: bounds.height + margin * 2 + headroom)
        let origin = CGPoint(x: -bounds.minX + margin, y: -bounds.minY + margin)

        // One scene for the whole city. With buildings rasterised there is not
        // a single effect node left in it, which is the entire reason the cache
        // exists — the top-down streetscape had to composite in batches because
        // a scene silently stops servicing blur passes past a budget.
        let view = SKView(frame: NSRect(origin: .zero, size: size))
        let renderer = IsoTileRenderer(projection: projection)
        let scene = SKScene(size: size)
        scene.backgroundColor = RenderPalette.background

        let world = SKNode()
        world.position = origin
        for position in Self.positions(of: map) where map[position].isBuildingAnchor {
            let tile = map[position]
            let node = renderer.makeNode(for: tile)
            if tile.zone == ZoneType.road || tile.zone == ZoneType.highway {
                renderer.syncLaneLine(on: node, zone: tile.zone,
                                      connections: Traffic.roadConnections(at: position, in: map))
            }
            world.addChild(node)
        }
        scene.addChild(world)

        let effect = SKEffectNode()
        effect.shouldEnableEffects = true
        let shader = RetroShader.make()
        RetroShader.updateAspect(shader, size: size)
        effect.shader = shader
        scene.removeAllChildren()
        effect.addChild(world)
        scene.addChild(effect)

        view.presentScene(scene)
        let texture = try XCTUnwrap(
            view.texture(from: scene, crop: CGRect(origin: .zero, size: size)),
            "SKView produced no texture"
        )
        return NSImage(cgImage: texture.cgImage(), size: size)
    }

    private static func stack(_ panels: [(String, NSImage)]) -> Data? {
        let captionHeight: CGFloat = 26, margin: CGFloat = 16
        let width = (panels.map { $0.1.size.width }.max() ?? 0) + margin * 2
        let height = panels.reduce(margin) { $0 + $1.1.size.height + captionHeight } + margin
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = CGSize(width: width, height: height)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        RenderPalette.background.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Menlo-Bold", size: 13) ?? NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor(white: 0.82, alpha: 1),
        ]
        var y = height - margin
        for (label, image) in panels {
            y -= captionHeight
            label.draw(at: NSPoint(x: margin, y: y + 6), withAttributes: attributes)
            y -= image.size.height
            image.draw(in: NSRect(x: margin, y: y, width: image.size.width, height: image.size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
