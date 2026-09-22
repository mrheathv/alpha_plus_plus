import SpriteKit
import XCTest
@testable import AlphaPlusPlus

/// **The ground under a street, which had never had a pass.**
///
/// 42% of a frame is road or bare land — 1,387 + 353 tiles of 4,096 on the
/// densest city this project ships — and until now all of it was a flat
/// diamond with a lane line on top. A kerb is the first mark ever added to
/// that surface.
@MainActor
final class StreetSurfaceTests: XCTestCase {

    private func cache() -> IsoTextureCache {
        IsoTextureCache(projection: Isometric(tileWidth: 64))
    }

    /// A kerb is a statement about *neighbours*, like a lane line — so the
    /// mask has to reach the texture, and a dead end cannot share a picture
    /// with a crossroads.
    func testTheConnectionMaskReachesTheGroundTexture() throws {
        let textures = cache()
        let crossroads = try XCTUnwrap(
            textures.ground(for: .road, density: 0, footprint: 1, kerbMask: 0b1111))
        let deadEnd = try XCTUnwrap(
            textures.ground(for: .road, density: 0, footprint: 1, kerbMask: 0b0001))
        let island = try XCTUnwrap(
            textures.ground(for: .road, density: 0, footprint: 1, kerbMask: 0))

        XCTAssertNotEqual(crossroads.texture, deadEnd.texture,
                          "a dead end and a crossroads drew the same ground — the mask is not "
                          + "in the key, so no street will ever grow a kerb")
        XCTAssertNotEqual(deadEnd.texture, island.texture)
        XCTAssertEqual(crossroads.size, island.size,
                       "the pavement changed the tile's footprint, which would shift every "
                       + "street half a kerb out of line with the lots beside it")
    }

    /// And nothing that is not a street is affected by it, or every lot in
    /// the city would be keyed on its neighbours for no reason — sixteen
    /// times the ground textures to draw the same picture.
    func testOnlyStreetsCareAboutTheMask() throws {
        let textures = cache()
        for zone in [ZoneType.residential, .empty, .park, .policeStation] {
            let a = try XCTUnwrap(textures.ground(for: zone, density: 0, footprint: 1,
                                                  kerbMask: 0b1111))
            let b = try XCTUnwrap(textures.ground(for: zone, density: 0, footprint: 1,
                                                  kerbMask: 0))
            XCTAssertEqual(a.texture, b.texture,
                           "\(zone) drew two different grounds for two masks it cannot use")
        }
    }

    /// **It costs textures, not nodes**, which is the whole reason a kerb is
    /// in the ground's picture rather than a sprite laid over it. Sixteen
    /// masks against two street zones is a few dozen more entries in a cache
    /// that already holds a hundred; a sprite would have been one more node
    /// on every road tile in the city, and a built-out map has 1,387 of them.
    func testAKerbAddsNoNodes() {
        let renderer = IsoTileRenderer(projection: Isometric(tileWidth: 64))
        let tile = Tile(position: GridPosition(x: 4, y: 4), zone: .road, density: 0)
        let surrounded = renderer.makeNode(for: tile, roadNeighbours: 0b1111)
        let stub = renderer.makeNode(for: tile, roadNeighbours: 0)
        XCTAssertEqual(surrounded.children.count, stub.children.count,
                       "a kerbed street carries more nodes than an uninterrupted one")
        XCTAssertEqual(stub.children.filter { $0 is SKShapeNode }.count, 0,
                       "the pavement arrived as shape nodes, which do not batch")
    }

    /// **The lamp's light has to actually land on the pavement**, and this
    /// asserts the colour rather than the call.
    ///
    /// The reason is a failure this project has shipped twice — an
    /// `SKAction.colorize` on a plain node, and an overlay tint cast to a type
    /// the ground had stopped being. Both compiled, both did nothing, and
    /// nothing failed, because what was being checked was that the call had
    /// been made. Every mark added to the ground now goes into one rasterised
    /// texture through several blend modes, which is more ways for a colour to
    /// silently not arrive, not fewer.
    ///
    /// Measured as warmth — red minus blue — because that is what a sodium
    /// lamp does to a street lit in magenta, and it is the one channel no
    /// other mark on this texture moves in that direction.
    func testTheLampLightsTheFootwayAndNotTheCarriageway() throws {
        let projection = Isometric(tileWidth: 64)
        let textures = IsoTextureCache(projection: projection)
        // A street running east-west, so the footways are north and south.
        let straight = try XCTUnwrap(
            textures.ground(for: .road, density: 0, footprint: 1, kerbMask: 0b0011))

        let view = SKView()
        let scene = SKScene(size: straight.size)
        scene.backgroundColor = .black
        let sprite = SKSpriteNode(texture: straight.texture, size: straight.size)
        sprite.position = CGPoint(x: straight.size.width / 2, y: straight.size.height / 2)
        scene.addChild(sprite)
        view.frame = NSRect(origin: .zero, size: straight.size)
        view.presentScene(scene)
        let shot = try XCTUnwrap(view.texture(from: scene,
                                              crop: CGRect(origin: .zero, size: straight.size)))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(cgImage: shot.cgImage()))
        let pixelsPerPoint = CGFloat(bitmap.pixelsWide) / straight.size.width

        /// Warmth at a point given in *tile* units, which is the only
        /// coordinate system any of this is authored in.
        func warmth(atTile x: CGFloat, _ y: CGFloat) throws -> CGFloat {
            let p = projection.project(x, y, 0)
            // The sprite is centred, so its own centre is the texture's
            // origin offset by whatever the drawing's frame turned out to be.
            let local = CGPoint(x: p.x - straight.offset.x, y: p.y - straight.offset.y)
            let px = Int((straight.size.width / 2 + local.x) * pixelsPerPoint)
            // Bitmap rows run downward; the scene's y runs up.
            let py = Int((straight.size.height / 2 - local.y) * pixelsPerPoint)
            let colour = try XCTUnwrap(bitmap.colorAt(x: px, y: py),
                                       "sampled off the texture at tile (\(x), \(y))")
            return colour.redComponent - colour.blueComponent
        }

        // The middle of the north footway, and the middle of the carriageway.
        let footway = try warmth(atTile: 0.5, 0.9)
        let carriageway = try warmth(atTile: 0.5, 0.5)
        print(String(format: "warmth: footway %+.3f, carriageway %+.3f", footway, carriageway))
        XCTAssertGreaterThan(footway, carriageway + 0.02,
                             "the footway is no warmer than the road beside it — the lamp's "
                             + "pool is not reaching the texture")

        // And a crossroads has no footway, so it must have no lamp either —
        // otherwise light would be falling in the middle of a junction.
        let crossroads = try XCTUnwrap(
            textures.ground(for: .road, density: 0, footprint: 1, kerbMask: 0b1111))
        XCTAssertNotEqual(crossroads.texture, straight.texture)
    }

    // MARK: - Looking at it

    /// **The street surface, at the size it is played at and magnified.**
    ///
    /// Every render this project has is of a *building*. The ground under one
    /// has never been photographed, which is how it went eleven phases as a
    /// flat diamond without anybody noticing — and it is 42% of the frame.
    ///
    /// Both columns matter and they answer different questions. The left one
    /// is a tile at `Isometric(tileWidth: 64)`, which is what a lot is at the
    /// resting camera: the only place `NeonStyle.minimumDetailSize`'s rule can
    /// be applied, because a mark that reads here reads in play. The right one
    /// is the same tile at 4×, which is the closest camera on a Retina
    /// display — and what it is for is telling "this mark is too small" apart
    /// from "this mark is not being drawn at all", which the left column
    /// cannot do and which is exactly the question a missing mark raises.
    ///
    /// Drawn through `IsoTileRenderer.makeNode`, the same call `GameScene`
    /// makes, rather than by asking the cache for a ground texture — and then
    /// `syncLaneLine` on top of it, which `update` does *not* do because it
    /// needs the map to work out its connections and the renderer only has a
    /// tile. The neon runs straight over the middle of every mark added here,
    /// so a picture of the surface without it is a picture of a frame the game
    /// never draws.
    func testRenderTheStreetSurface() throws {
        let renderer = IsoTileRenderer(projection: Isometric(tileWidth: 64))
        let view = SKView()

        // The shapes a grid actually produces, named for what they are.
        let subjects: [(String, Int)] = [
            ("crossroads", 0b1111),
            ("T junction", 0b1011),
            ("corner", 0b0101),
            ("straight", 0b0011),
            ("dead end", 0b0001),
            ("island", 0b0000),
        ]

        func panel(_ mask: Int, magnification: CGFloat) -> NSImage? {
            let tile = Tile(position: GridPosition(x: 0, y: 0), zone: .road, density: 0)
            let node = renderer.makeNode(for: tile, roadNeighbours: mask)
            renderer.syncLaneLine(
                on: node, zone: .road,
                connections: Traffic.RoadConnections(
                    north: mask & 4 != 0, south: mask & 8 != 0,
                    east: mask & 1 != 0, west: mask & 2 != 0))
            node.position = .zero
            node.setScale(magnification)
            let frame = node.calculateAccumulatedFrame()
            let size = CGSize(width: ceil(frame.width), height: ceil(frame.height))
            node.position = CGPoint(x: -frame.minX, y: -frame.minY)

            let scene = SKScene(size: size)
            scene.backgroundColor = SKColor(white: 0.04, alpha: 1)
            scene.addChild(node)
            view.frame = NSRect(origin: .zero, size: size)
            view.presentScene(scene)
            guard let texture = view.texture(from: scene,
                                             crop: CGRect(origin: .zero, size: size))
            else { return nil }
            return NSImage(cgImage: texture.cgImage(), size: size)
        }

        var rows: [(String, NSImage, NSImage)] = []
        for (name, mask) in subjects {
            guard let rest = panel(mask, magnification: 1),
                  let near = panel(mask, magnification: 4) else {
                return XCTFail("\(name) drew nothing at all")
            }
            rows.append((name, rest, near))
        }

        let gap: CGFloat = 16
        let restWidth = rows.map(\.1.size.width).max() ?? 0
        let nearWidth = rows.map(\.2.size.width).max() ?? 0
        let rowHeight = rows.map { max($0.1.size.height, $0.2.size.height) }.max() ?? 0
        let sheet = NSImage(size: CGSize(width: gap * 3 + restWidth + nearWidth,
                                         height: (rowHeight + gap) * CGFloat(rows.count) + gap))
        sheet.lockFocus()
        NSColor(white: 0.04, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        var y = sheet.size.height - gap - rowHeight
        for (_, rest, near) in rows {
            rest.draw(at: CGPoint(x: gap + (restWidth - rest.size.width) / 2,
                                  y: y + (rowHeight - rest.size.height) / 2),
                      from: .zero, operation: .sourceOver, fraction: 1)
            near.draw(at: CGPoint(x: gap * 2 + restWidth + (nearWidth - near.size.width) / 2,
                                  y: y + (rowHeight - near.size.height) / 2),
                      from: .zero, operation: .sourceOver, fraction: 1)
            y -= rowHeight + gap
        }
        sheet.unlockFocus()

        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ContactSheet")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("street-surface.png")
        guard let tiff = sheet.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("could not encode the sheet")
        }
        try png.write(to: url)
        print("wrote \(url.path) — \(subjects.map(\.0).joined(separator: ", ")), "
              + "at rest and at 4×")
    }
}
