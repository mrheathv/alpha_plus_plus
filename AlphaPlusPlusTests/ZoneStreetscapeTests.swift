import XCTest
import SpriteKit
@testable import AlphaPlusPlus

/// Renders a block of city — roads, and lots of every zone and tier sitting
/// next to each other — to a single PNG.
///
/// **Why this exists alongside the contact sheet.** `ZoneIconContactSheetTests`
/// draws one building per cell, centred, with air around it. That answers "is
/// this building any good?" and it is the wrong tool for "does this *city*
/// look right?", because every question about art in context is a question
/// about neighbours: whether lots fill their footprint, whether adjacent
/// buildings collide or leave gaps, whether three zones side by side still
/// read as three zones once they are small and touching, whether a row of
/// lots reads as a street or as wallpaper.
///
/// It is not a hypothetical distinction. `TileRenderer.fitIconToTile` measured
/// an icon's frame to scale by it but left the icon at its authoring origin,
/// so short buildings hung roughly a quarter of a lot below their tile and
/// overlapped the neighbour below. The contact sheet could not show that —
/// with one icon per cell there is no neighbour — and it went unnoticed until
/// commercial started drawing strips of shops. This view shows it immediately.
///
/// Deliberately hand-authored rather than grown by `CitySimulator`: the point
/// is to guarantee that every tier of every zone appears, and appears next to
/// the others. A grown city shows whatever it happened to grow.
final class ZoneStreetscapeTests: XCTestCase {

    /// One building: where it sits, what it is, how big.
    private struct Lot {
        let origin: GridPosition
        let zone: ZoneType
        let density: Int
    }

    private static let tilesWide = 21
    private static let tilesHigh = 16
    /// The zoom levels the render covers, as points per tile.
    ///
    /// **Why more than one, and why this was the whole problem.** `GameScene`
    /// draws a 32-point tile (`GridLayout()`'s default) and its camera scales
    /// from 0.5 to 3.0 — so a 2x2 building is 128 points across when a player
    /// zooms all the way in, 64 at rest, and about 21 when zoomed out. This
    /// render used to exist only at the first of those, which is the rarest
    /// one, and it flattered the art badly: detail that reads beautifully at
    /// 128 points is noise at 64 and gone at 21. A building has to be judged
    /// at the size it is actually played at, so the render covers the range.
    ///
    /// The gutter scales with the tile (the game's is 1 point in 32), so each
    /// panel is the game's own proportions rather than a different look that
    /// happens to be bigger.
    private static let zoomLevels: [(name: String, tileSize: CGFloat)] = [
        ("zoomed in (camera 0.5)", 64),
        ("default (camera 1.0)", 32),
        ("zoomed out (camera 3.0)", 11),
    ]

    private static func gap(forTileSize tileSize: CGFloat) -> CGFloat {
        max(1, (tileSize / 32).rounded())
    }

    /// Roads every fifth row and column, leaving 4×4 blocks that hold four
    /// 2×2 lots each — the same shape a player's grid actually takes.
    private static let roadEvery = 5

    private static func isRoad(_ x: Int, _ y: Int) -> Bool {
        x % roadEvery == 0 || y % roadEvery == 0
    }

    /// The zone and density for the block whose corner is at `(bx, by)`.
    ///
    /// Zone cycles along x so the three vocabularies are always adjacent, and
    /// density rises toward the middle of the map the way land value makes it
    /// rise toward a real city's centre — which puts tier 1 next to tier 3
    /// somewhere on every sheet.
    private static func block(bx: Int, by: Int) -> (ZoneType, Int) {
        let zone: ZoneType = [.residential, .commercial, .industrial][(bx + by) % 3]
        let blocksWide = (tilesWide - 1) / roadEvery
        let blocksHigh = (tilesHigh - 1) / roadEvery
        let distance = abs(bx - (blocksWide - 1) / 2) + abs(by - (blocksHigh - 1) / 2)
        let density = [5, 3, 1][min(distance, 2)]
        return (zone, density)
    }

    private static func lots() -> [Lot] {
        var lots: [Lot] = []
        var by = 0
        var blockY = 1
        while blockY + 3 < tilesHigh {
            var bx = 0
            var blockX = 1
            while blockX + 3 < tilesWide {
                let (zone, density) = block(bx: bx, by: by)
                for dy in stride(from: 0, to: 4, by: 2) {
                    for dx in stride(from: 0, to: 4, by: 2) {
                        lots.append(Lot(
                            origin: GridPosition(x: blockX + dx, y: blockY + dy),
                            zone: zone,
                            density: density
                        ))
                    }
                }
                bx += 1
                blockX += roadEvery
            }
            by += 1
            blockY += roadEvery
        }
        return lots
    }

    private static func roadPositions() -> [GridPosition] {
        var positions: [GridPosition] = []
        for y in 0 ..< tilesHigh {
            for x in 0 ..< tilesWide where isRoad(x, y) {
                positions.append(GridPosition(x: x, y: y))
            }
        }
        return positions
    }

    /// The street grid the whole map is laid out on, as a `CityMap` — needed
    /// because `Traffic.roadConnections(at:in:)` is what decides which way a
    /// lane line runs, and a junction has to know it is a junction.
    private static func roadMap() -> CityMap {
        var map = CityMap(width: tilesWide, height: tilesHigh)
        for position in roadPositions() {
            map[position].zone = .road
        }
        return map
    }

    // MARK: - The render

    func testRenderStreetscape() throws {
        // Every panel is rendered at its own tile size rather than by scaling
        // one big bitmap down. Scaling a bitmap answers "what does this look
        // like blurry?"; re-rendering the vectors answers "what does the game
        // actually draw?", and those differ — a hairline stroke survives a
        // downsample as a grey smear and is simply absent at the real size.
        var panels: [(name: String, image: NSImage)] = []
        var lotCount = 0
        for level in Self.zoomLevels {
            let layout = GridLayout(tileSize: level.tileSize, gap: Self.gap(forTileSize: level.tileSize))
            let lotBox = CGSize(width: level.tileSize * 2, height: level.tileSize * 2)

            // One lot at a time, for the same reason the contact sheet does
            // it: a single scene holding this many `withGlow` effect nodes
            // quietly renders only the first few and leaves the rest blank.
            let view = SKView(frame: NSRect(origin: .zero, size: lotBox))
            var rendered: [(Lot, NSImage)] = []
            for lot in Self.lots() {
                rendered.append((lot, try renderLot(lot, size: lotBox, view: view, layout: layout)))
            }
            lotCount = rendered.count

            // Streets go through `TileRenderer` as well, for the same reason
            // the lots do — and because they are half the picture. Painting
            // them by hand meant the render showed flat asphalt while the game
            // drew a glowing network, which is most of what the map's look
            // actually is.
            let roadBox = CGSize(width: level.tileSize, height: level.tileSize)
            let roadView = SKView(frame: NSRect(origin: .zero, size: roadBox))
            var roads: [(GridPosition, NSImage)] = []
            for position in Self.roadPositions() {
                roads.append((position, try renderRoad(at: position, size: roadBox, view: roadView, layout: layout)))
            }

            let canvasSize = CGSize(
                width: CGFloat(Self.tilesWide) * level.tileSize,
                height: CGFloat(Self.tilesHigh) * level.tileSize
            )
            let composed = try XCTUnwrap(
                Self.compose(lots: rendered, roads: roads, canvasSize: canvasSize, tileSize: level.tileSize),
                "failed to compose the \(level.name) panel"
            )
            panels.append((level.name, try postProcess(composed, view: view)))
        }

        let sheet = try XCTUnwrap(Self.stack(panels: panels), "failed to stack the streetscape panels")
        let destination = Self.outputURL()
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try sheet.write(to: destination)
        print("🏙  Streetscape: \(destination.path) (\(lotCount) lots × \(panels.count) zooms, \(sheet.count) bytes)")
        XCTAssertGreaterThan(sheet.count, 0)
    }

    /// Lays the per-zoom panels out top to bottom with a caption each, so one
    /// look covers the whole range the camera can show.
    private static func stack(panels: [(name: String, image: NSImage)]) -> Data? {
        let captionHeight: CGFloat = 26
        let margin: CGFloat = 16
        let width = (panels.map { $0.image.size.width }.max() ?? 0) + margin * 2
        let height = panels.reduce(margin) { $0 + $1.image.size.height + captionHeight } + margin

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = CGSize(width: width, height: height)

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        RenderPalette.background.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        let captionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Menlo-Bold", size: 13) ?? NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor(white: 0.82, alpha: 1),
        ]

        var y = height - margin
        for panel in panels {
            y -= captionHeight
            panel.name.draw(at: NSPoint(x: margin, y: y + 6), withAttributes: captionAttributes)
            y -= panel.image.size.height
            panel.image.draw(in: NSRect(x: margin, y: y,
                                        width: panel.image.size.width,
                                        height: panel.image.size.height))
        }

        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Every lot has to draw *something*. A blank lot in the middle of a
    /// street is the failure this catches — the same class of silent nil the
    /// contact sheet guards, but at the footprint the game really uses.
    func testEveryLotDrawsSomething() {
        for lot in Self.lots() {
            let node = ZoneIcon.makeNode(for: lot.zone, density: lot.density, seed: lot.origin)
            let frame = node?.calculateAccumulatedFrame() ?? .zero
            XCTAssertGreaterThan(
                frame.width * frame.height, 0,
                "lot at (\(lot.origin.x), \(lot.origin.y)) — \(lot.zone.rawValue) density \(lot.density) — draws nothing"
            )
        }
    }

    /// A building must stay inside its own lot once `fitIconToTile` has
    /// scaled and placed it, or it overlaps the neighbour. This is the
    /// regression test for the centring bug described in the type's doc
    /// comment: before the fix a strip of shops sat a quarter of a lot low.
    func testBuildingsStayWithinTheirFootprint() {
        let layout = GridLayout(tileSize: Self.zoomLevels[0].tileSize,
                                gap: Self.gap(forTileSize: Self.zoomLevels[0].tileSize))
        for lot in Self.lots() {
            guard let icon = ZoneIcon.makeNode(for: lot.zone, density: lot.density, seed: lot.origin) else {
                continue
            }
            let footprint = lot.zone.footprintSize
            let sprite = layout.spriteSize(forFootprint: footprint)
            TileRenderer.fitIconToTile(icon, footprintSize: footprint, layout: layout)

            // `fitIconToTile` places the icon relative to the tile sprite's
            // centre, so the lot's own bounds are half a sprite either way.
            let drawn = icon.calculateAccumulatedFrame()
            let label = "\(lot.zone.rawValue) density \(lot.density) at (\(lot.origin.x), \(lot.origin.y))"
            XCTAssertGreaterThanOrEqual(drawn.minX, -sprite.width / 2 - 0.5, "\(label): overhangs its lot to the left")
            XCTAssertLessThanOrEqual(drawn.maxX, sprite.width / 2 + 0.5, "\(label): overhangs its lot to the right")
            XCTAssertGreaterThanOrEqual(drawn.minY, -sprite.height / 2 - 0.5, "\(label): overhangs its lot below")
            XCTAssertLessThanOrEqual(drawn.maxY, sprite.height / 2 + 0.5, "\(label): overhangs its lot above")
        }
    }

    // MARK: - Plumbing

    /// Renders one lot **through `TileRenderer.makeNode(for:)`** — the same
    /// call `GameScene` makes — rather than assembling a plate and an icon by
    /// hand.
    ///
    /// The hand-rolled version drew a flat zone-coloured rectangle with a
    /// building on it, which was a faithful picture of the renderer right up
    /// until the renderer changed. When the palette moved zone identity out of
    /// the tile fill and into light, every mark that carries the new look —
    /// the ground glow, the surveyed-lot outline — was invisible here, because
    /// this file did not know they existed. A yardstick that reimplements the
    /// thing it measures will eventually measure something else.
    private func renderLot(
        _ lot: Lot,
        size: CGSize,
        view: SKView,
        layout: GridLayout
    ) throws -> NSImage {
        let scene = SKScene(size: size)
        scene.backgroundColor = RenderPalette.background

        let tile = Tile(position: lot.origin, zone: lot.zone, density: lot.density)
        let node = TileRenderer(layout: layout).makeNode(for: tile)
        node.position = CGPoint(x: size.width / 2, y: size.height / 2)
        scene.addChild(node)

        view.presentScene(scene)
        let texture = try XCTUnwrap(
            view.texture(from: scene, crop: CGRect(origin: .zero, size: size)),
            "lot at (\(lot.origin.x), \(lot.origin.y)): SKView produced no texture"
        )
        return NSImage(cgImage: texture.cgImage(), size: size)
    }

    private func renderRoad(
        at position: GridPosition,
        size: CGSize,
        view: SKView,
        layout: GridLayout
    ) throws -> NSImage {
        let scene = SKScene(size: size)
        scene.backgroundColor = RenderPalette.ground

        let map = Self.roadMap()
        let renderer = TileRenderer(layout: layout)
        let node = renderer.makeNode(for: map[position])
        node.position = CGPoint(x: size.width / 2, y: size.height / 2)
        renderer.syncLaneLine(
            on: node,
            zone: .road,
            connections: Traffic.roadConnections(at: position, in: map)
        )
        scene.addChild(node)

        view.presentScene(scene)
        let texture = try XCTUnwrap(
            view.texture(from: scene, crop: CGRect(origin: .zero, size: size)),
            "road at (\(position.x), \(position.y)): SKView produced no texture"
        )
        return NSImage(cgImage: texture.cgImage(), size: size)
    }

    /// Runs the composed panel back through `RetroShader` — the same
    /// full-scene pass `GameScene` puts every frame through.
    ///
    /// **Why the render has to include it.** The shader only ever multiplies
    /// brightness *down*: scanlines take up to 11%, the vignette up to 35% at
    /// the edges. Those values were chosen when every tile was a bright
    /// saturated fill with plenty of headroom to lose. The ground rewrite took
    /// that headroom away, so a render without the shader is a render of a
    /// frame the game never actually draws — and the question "is the dark
    /// palette still legible after the post-process crushes it" is exactly the
    /// one a redesign like that has to answer.
    ///
    /// The panel stands in for a screenful, which is what the shader operates
    /// on in game, so the vignette lands where it would in play.
    private func postProcess(_ image: NSImage, view: SKView) throws -> NSImage {
        let size = image.size
        let scene = SKScene(size: size)
        scene.backgroundColor = RenderPalette.background

        let effect = SKEffectNode()
        effect.shouldEnableEffects = true
        let shader = RetroShader.make()
        RetroShader.updateAspect(shader, size: size)
        effect.shader = shader

        let sprite = SKSpriteNode(texture: SKTexture(image: image))
        sprite.size = size
        sprite.position = CGPoint(x: size.width / 2, y: size.height / 2)
        effect.addChild(sprite)
        scene.addChild(effect)

        view.frame = NSRect(origin: .zero, size: size)
        view.presentScene(scene)
        let texture = try XCTUnwrap(
            view.texture(from: scene, crop: CGRect(origin: .zero, size: size)),
            "post-process pass produced no texture"
        )
        return NSImage(cgImage: texture.cgImage(), size: size)
    }

    /// Core Graphics, like the contact sheet's composer and for the same
    /// reason: this stage only blits already-rasterized images, so none of
    /// SpriteKit's effect-node budget applies.
    private static func compose(
        lots: [(Lot, NSImage)],
        roads: [(GridPosition, NSImage)],
        canvasSize: CGSize,
        tileSize: CGFloat
    ) -> NSImage? {
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvasSize.width * scale),
            pixelsHigh: Int(canvasSize.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = canvasSize

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        RenderPalette.ground.setFill()
        NSRect(origin: .zero, size: canvasSize).fill()

        for (position, image) in roads {
            image.draw(in: NSRect(x: CGFloat(position.x) * tileSize, y: CGFloat(position.y) * tileSize,
                                  width: tileSize, height: tileSize))
        }

        for (lot, image) in lots {
            image.draw(in: NSRect(
                x: CGFloat(lot.origin.x) * tileSize,
                y: CGFloat(lot.origin.y) * tileSize,
                width: tileSize * 2,
                height: tileSize * 2
            ))
        }

        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: canvasSize)
        image.addRepresentation(rep)
        return image
    }

    /// `$STREETSCAPE_PATH` when set (needs a `TEST_RUNNER_` prefix through
    /// xcodebuild — see `ZoneIconContactSheetTests.outputURL`), otherwise
    /// alongside the contact sheet under the gitignored `build/`.
    private static func outputURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["STREETSCAPE_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.appendingPathComponent("build/ContactSheet/streetscape.png")
    }
}
