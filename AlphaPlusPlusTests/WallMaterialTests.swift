import SpriteKit
import XCTest
@testable import AlphaPlusPlus

/// **Every wall in this game was made of the same thing.**
///
/// Stripped of hue, a built-out city came back as exactly two values: one
/// near-black face and one white window, on every building in it. The zones
/// tell apart — commerce's continuous bands against housing's punched grid is
/// a distinction that survives greyscale, and that was the whole point of the
/// massing port — but *within* a zone every tower was the same tower. The
/// variety was all in the outline and none of it in the surface.
@MainActor
final class WallMaterialTests: XCTestCase {

    /// **Judged in greyscale, because that is what found the problem.**
    ///
    /// Hue is the channel this game has most of and leans on hardest, and it
    /// will happily hide a facade that carries no information at all — which
    /// is exactly what it was doing. A row of consecutive variants with the
    /// colour taken out answers the only question here: looking along it, are
    /// these different buildings or one building at different widths?
    ///
    /// Consecutive *variants* rather than arbitrary seeds, because those are
    /// the thirty-two looks the cache actually draws from. Counting or
    /// photographing anything else measures a generator nobody renders.
    func testRenderWallMaterialsInGreyscale() throws {
        let projection = Isometric(tileWidth: 64)
        let cache = IsoTextureCache(projection: projection)
        let view = SKView()
        let cell = CGSize(width: 240, height: 340)
        let zones: [ZoneType] = [.commercial, .residential]
        let perRow = 8

        var rows: [[NSImage]] = []
        for zone in zones {
            var row: [NSImage] = []
            var drawn = 0
            for x in 0 ..< 64 where drawn < perRow {
                let position = GridPosition(x: x * 7, y: x * 3)
                // Skip the landmarks: they are a different pass's subject and
                // they would dominate a row about surfaces.
                let canonical = IsoTextureCache.canonicalSeed(
                    for: IsoTextureCache.variant(for: position))
                guard !ZoneMassing.isLandmark(tier: 3, seed: canonical),
                      let rendered = cache.rendered(for: zone, density: 5, seed: position)
                else { continue }
                drawn += 1

                let node = SKSpriteNode(texture: rendered.texture, size: rendered.size)
                node.setScale(1.1)
                let frame = node.calculateAccumulatedFrame()
                node.position = CGPoint(x: cell.width / 2, y: 24 - frame.minY)
                let scene = SKScene(size: cell)
                scene.backgroundColor = RenderPalette.background
                scene.addChild(node)
                view.frame = NSRect(origin: .zero, size: cell)
                view.presentScene(scene)
                let texture = try XCTUnwrap(
                    view.texture(from: scene, crop: CGRect(origin: .zero, size: cell)))
                row.append(NSImage(cgImage: texture.cgImage(), size: cell))
            }
            rows.append(row)
        }

        let gap: CGFloat = 8
        let sheet = NSImage(size: CGSize(
            width: cell.width * CGFloat(perRow) + gap * CGFloat(perRow + 1),
            height: (cell.height + gap) * CGFloat(rows.count) + gap))
        sheet.lockFocus()
        RenderPalette.background.setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        var y = sheet.size.height - gap - cell.height
        for row in rows {
            var x = gap
            for panel in row {
                panel.draw(at: CGPoint(x: x, y: y), from: .zero,
                           operation: .sourceOver, fraction: 1)
                x += cell.width + gap
            }
            y -= cell.height + gap
        }
        sheet.unlockFocus()

        // Desaturated here rather than by hand afterwards, so the sheet this
        // writes *is* the one the decision was taken on.
        guard let tiff = sheet.tiffRepresentation,
              let colour = NSBitmapImageRep(data: tiff) else {
            return XCTFail("could not encode the sheet")
        }
        let grey = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: colour.pixelsWide, pixelsHigh: colour.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false, isPlanar: false,
            colorSpaceName: .calibratedWhite, bytesPerRow: colour.pixelsWide, bitsPerPixel: 8)
        guard let grey else { return XCTFail("could not make a greyscale target") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: grey)
        colour.draw(in: NSRect(x: 0, y: 0, width: colour.pixelsWide, height: colour.pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()

        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ContactSheet")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("wall-materials.png")
        guard let png = grey.representation(using: .png, properties: [:]) else {
            return XCTFail("could not encode the sheet")
        }
        try png.write(to: url)
        print("wrote \(url.path) — \(perRow) consecutive variants per zone, colour removed")
    }

    /// **The material has to reach the wall**, and this asserts the marks
    /// arrive rather than that the call was made.
    ///
    /// Two failures of exactly this shape are already recorded in this
    /// project — an `SKAction.colorize` on a plain node and an overlay tint
    /// cast to a type the ground had stopped being — and cladding is the same
    /// risk: a `switch` whose default case is "draw nothing" compiles and does
    /// nothing whatever it is handed.
    func testSomeVariantsAreCladAndSomeAreNot() throws {
        for zone in [ZoneType.commercial, .residential] {
            var clad = 0, plain = 0
            for variant in 0 ..< IsoTextureCache.variantCount {
                let seed = IsoTextureCache.canonicalSeed(for: variant)
                guard !ZoneMassing.isLandmark(tier: 3, seed: seed),
                      let massing = ZoneMassing.make(for: zone, density: 5, seed: seed)
                else { continue }
                let marks = massing.panels.filter { $0.color == NeonStyle.claddingAccent }.count
                if marks > 0 { clad += 1 } else { plain += 1 }
            }
            print("\(zone): \(clad) variants carry a wall material, \(plain) are bare glass")
            XCTAssertGreaterThan(clad, 0, "\(zone) never draws a material — the wall is one "
                                 + "surface again and nothing failed")
            XCTAssertGreaterThan(plain, 0, "\(zone) draws a material on every variant, which is "
                                 + "one surface again wearing a different texture")
        }
    }
}
