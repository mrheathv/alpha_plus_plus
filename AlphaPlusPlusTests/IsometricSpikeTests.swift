import XCTest
import SpriteKit
@testable import AlphaPlusPlus

/// Renders a city block in isometric, so the projection can be judged before
/// the codebase is committed to it.
///
/// **This is a spike, not a feature.** Nothing here is wired into the running
/// game, and the massing below is deliberately crude — a hall and some stacks,
/// a stepped tower, a podium and a tower. The question it exists to answer is
/// "does isometric look better enough to be worth the migration", and that
/// question needs a *block*, not a building: whether volumes read, whether the
/// three zones still separate, and whether the neon has more to do than trace
/// an outline.
///
/// If the answer is yes, the real work is porting the three generators from
/// drawing a front elevation to describing massing — the forms they already
/// pick (a strip of shops, a corner unit, a row of houses, a sawtooth roof)
/// survive that change; only the drawing does not.
final class IsometricSpikeTests: XCTestCase {

    // MARK: - The block

    private static let tilesWide = 11
    private static let tilesHigh = 11
    private static let roadEvery = 5

    private static func isRoad(_ x: Int, _ y: Int) -> Bool {
        x % roadEvery == 0 || y % roadEvery == 0
    }

    private struct Lot {
        let origin: GridPosition
        let zone: ZoneType
        let tier: Int
    }

    private static func lots() -> [Lot] {
        var lots: [Lot] = []
        for (bi, blockY) in [1, 6].enumerated() {
            for (bj, blockX) in [1, 6].enumerated() {
                let zone: ZoneType = [.residential, .commercial, .industrial][(bi + bj) % 3]
                for dy in stride(from: 0, to: 4, by: 2) {
                    for dx in stride(from: 0, to: 4, by: 2) {
                        lots.append(Lot(
                            origin: GridPosition(x: blockX + dx, y: blockY + dy),
                            zone: zone,
                            tier: 1 + (dx / 2 + dy / 2) % 3
                        ))
                    }
                }
            }
        }
        return lots
    }

    // MARK: - Massing

    /// A building as a stack of boxes in tile units, rather than as a drawing.
    ///
    /// This is the shape the real generators would have to move to: say what
    /// the building *is*, and let a projection decide how it is drawn. The
    /// same description would render as a front elevation or as isometric,
    /// which is what makes the migration a rewrite of the drawing rather than
    /// of the design.
    private static func massing(for lot: Lot) -> [Isometric.Box] {
        var random = BuildingRandom(seed: lot.origin, salt: 900 + lot.tier)
        let x = CGFloat(lot.origin.x), y = CGFloat(lot.origin.y)

        func box(_ ix: CGFloat, _ iy: CGFloat, _ iz: CGFloat,
                 _ w: CGFloat, _ d: CGFloat, _ h: CGFloat) -> Isometric.Box {
            Isometric.Box(x: x + ix, y: y + iy, z: iz, width: w, depth: d, height: h)
        }

        switch lot.zone {
        case .industrial:
            // Wide and low, and it spreads: the hall covers nearly the whole
            // lot and the stacks are the tall thing, not the building.
            let hallHeight = CGFloat(random.value(in: 0.35 ... 0.5)) + CGFloat(lot.tier) * 0.12
            var boxes = [box(0.08, 0.08, 0, 1.84, 1.84, hallHeight)]
            for index in 0 ..< random.int(in: 1 ... min(3, lot.tier + 1)) {
                let sx = CGFloat(random.value(in: 0.25 ... 1.4))
                let sy = CGFloat(random.value(in: 0.25 ... 1.4))
                boxes.append(box(sx, sy, hallHeight, 0.28, 0.28,
                                 CGFloat(random.value(in: 0.5 ... 0.5 + Double(lot.tier) * 0.35))))
                _ = index
            }
            return boxes

        case .residential:
            // Steps back as it rises.
            var boxes: [Isometric.Box] = []
            var inset: CGFloat = 0.1
            var z: CGFloat = 0
            for step in 0 ..< (lot.tier == 1 ? 1 : lot.tier) {
                let h = CGFloat(random.value(in: 0.45 ... 0.75)) * CGFloat(lot.tier == 1 ? 1 : 1.1)
                boxes.append(box(inset, inset, z, 2 - inset * 2, 2 - inset * 2, h))
                z += h
                inset += CGFloat(random.value(in: 0.16 ... 0.3))
                _ = step
            }
            return boxes

        case .commercial:
            // A wide glazed podium with a slimmer tower standing on it.
            let podium = CGFloat(random.value(in: 0.3 ... 0.45))
            var boxes = [box(0.06, 0.06, 0, 1.88, 1.88, podium)]
            let inset = CGFloat(random.value(in: 0.3 ... 0.5))
            boxes.append(box(inset, inset, podium, 2 - inset * 2, 2 - inset * 2,
                             CGFloat(random.value(in: 0.5 ... 0.8)) * CGFloat(lot.tier) + 0.2))
            return boxes

        default:
            return [box(0.1, 0.1, 0, 1.8, 1.8, 0.4)]
        }
    }

    // MARK: - Drawing

    /// Draws one box as three lit faces plus its creases.
    ///
    /// The faces take three different values — top lightest, then the
    /// down-right side, then the down-left — which is what actually makes the
    /// shape read as solid. The neon then has real edges to sit on rather than
    /// just a silhouette to trace, which is the whole argument for isometric
    /// in this art direction.
    private static func node(for box: Isometric.Box, accent: SKColor, tier: Int) -> SKNode {
        let faces = Isometric.faces(of: box)
        let container = SKNode()

        func face(_ path: CGPath, tint: CGFloat) -> SKShapeNode {
            let node = SKShapeNode(path: path)
            node.fillColor = ZoneIcon.silhouetteFill.blended(withFraction: tint, of: accent)
                ?? ZoneIcon.silhouetteFill
            node.strokeColor = accent
            node.lineWidth = 2
            return node
        }

        let shapes = [
            face(faces.left, tint: 0.04),
            face(faces.right, tint: 0.12),
            face(faces.top, tint: 0.26),
        ]
        container.addChild(ZoneIcon.withGlow(
            shapes, color: accent, blurRadius: 6,
            intensity: ZoneIcon.glowIntensity(forTier: tier)
        ))
        container.addChild(contentsOf: windows(on: box, tier: tier))
        return container
    }

    /// Lit panels on the two visible side faces, projected onto the face plane
    /// rather than drawn as screen-space rectangles — the thing that stops an
    /// isometric building reading as a plain crate.
    private static func windows(on box: Isometric.Box, tier: Int) -> [SKNode] {
        guard box.height > 0.3, box.width > 0.4 else { return [] }
        var random = BuildingRandom(seed: GridPosition(x: Int(box.x * 16), y: Int(box.y * 16)), salt: tier)

        let rows = max(1, Int(box.height / 0.34))
        var parts: [SKNode] = []

        for face in 0 ..< 2 {
            let columns = max(1, Int((face == 0 ? box.depth : box.width) / 0.42))
            for row in 0 ..< rows {
                for column in 0 ..< columns {
                    guard random.chance(0.6) else { continue }
                    let u0 = (CGFloat(column) + 0.28) / CGFloat(columns)
                    let u1 = (CGFloat(column) + 0.72) / CGFloat(columns)
                    let v0 = box.z + box.height * (CGFloat(row) + 0.26) / CGFloat(rows)
                    let v1 = box.z + box.height * (CGFloat(row) + 0.66) / CGFloat(rows)

                    let path = CGMutablePath()
                    let corners: [CGPoint] = face == 0
                        ? [Isometric.project(box.x + box.width, box.y + box.depth * u0, v0),
                           Isometric.project(box.x + box.width, box.y + box.depth * u1, v0),
                           Isometric.project(box.x + box.width, box.y + box.depth * u1, v1),
                           Isometric.project(box.x + box.width, box.y + box.depth * u0, v1)]
                        : [Isometric.project(box.x + box.width * u0, box.y + box.depth, v0),
                           Isometric.project(box.x + box.width * u1, box.y + box.depth, v0),
                           Isometric.project(box.x + box.width * u1, box.y + box.depth, v1),
                           Isometric.project(box.x + box.width * u0, box.y + box.depth, v1)]
                    path.move(to: corners[0])
                    corners.dropFirst().forEach { path.addLine(to: $0) }
                    path.closeSubpath()

                    let pane = SKShapeNode(path: path)
                    pane.fillColor = ZoneIcon.windowColor(row: row, column: column, salt: face)
                    pane.strokeColor = .clear
                    parts.append(pane)
                }
            }
        }
        return parts
    }

    // MARK: - The render

    func testRenderIsometricBlock() throws {
        // Bounds, from the projected corners of the whole grid plus headroom
        // for the tallest building.
        let w = CGFloat(Self.tilesWide), h = CGFloat(Self.tilesHigh)
        let corners = [
            Isometric.project(0, 0, 0), Isometric.project(w, 0, 0),
            Isometric.project(0, h, 0), Isometric.project(w, h, 0),
        ]
        let margin: CGFloat = 60
        let xs = corners.map { $0.x }
        let ys = corners.map { $0.y }
        let minX = xs.min()! - margin
        let maxX = xs.max()! + margin
        let minY = ys.min()! - margin
        let maxY = ys.max()! + margin + 4 * Isometric.heightUnit
        let size = CGSize(width: maxX - minX, height: maxY - minY)
        let origin = CGPoint(x: -minX, y: -minY)

        let view = SKView(frame: NSRect(origin: .zero, size: size))

        // Ground first: one pass, no glow, so it costs nothing.
        var layers: [NSImage] = [try render(size: size, view: view) { root in
            for y in 0 ..< Self.tilesHigh {
                for x in 0 ..< Self.tilesWide {
                    let tile = SKShapeNode(path: Isometric.tileDiamond(
                        x: CGFloat(x), y: CGFloat(y), inset: 0.02
                    ))
                    tile.fillColor = RenderPalette.color(
                        for: Self.isRoad(x, y) ? .road : .empty, density: 0
                    )
                    tile.strokeColor = Self.isRoad(x, y)
                        ? RenderPalette.networkAccentColor(for: .road).withAlphaComponent(0.5)
                        : RenderPalette.ground.blended(withFraction: 0.35, of: .white) ?? .clear
                    tile.lineWidth = Self.isRoad(x, y) ? 1.5 : 0.6
                    tile.position = origin
                    root.addChild(tile)
                }
            }
        }]

        // Buildings in depth-sorted batches. Isometric buildings overlap, so
        // they cannot be rendered to their own tile rect and composited the way
        // the top-down streetscape does; and one scene holding every `withGlow`
        // effect node at once silently drops most of them. Batches of six,
        // composited back to front, satisfy both.
        let sorted = Isometric.sorted(Self.lots()) { CGFloat($0.origin.x + $0.origin.y) }
        for batch in stride(from: 0, to: sorted.count, by: 6) {
            let slice = Array(sorted[batch ..< min(batch + 6, sorted.count)])
            layers.append(try render(size: size, view: view) { root in
                for lot in slice {
                    let accent = RenderPalette.tierColor(for: lot.zone, tier: lot.tier)
                    for box in Self.massing(for: lot) {
                        let node = Self.node(for: box, accent: accent, tier: lot.tier)
                        node.position = origin
                        root.addChild(node)
                    }
                }
            })
        }

        let sheet = try XCTUnwrap(Self.flatten(layers, size: size), "failed to flatten the isometric block")
        let destination = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ContactSheet/isometric-spike.png")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try sheet.write(to: destination)
        print("📐 Isometric spike: \(destination.path) (\(sorted.count) lots, \(sheet.count) bytes)")
        XCTAssertGreaterThan(sheet.count, 0)
    }

    private func render(size: CGSize, view: SKView, _ build: (SKNode) -> Void) throws -> NSImage {
        let scene = SKScene(size: size)
        scene.backgroundColor = .clear
        let root = SKNode()
        build(root)
        scene.addChild(root)
        view.allowsTransparency = true
        view.presentScene(scene)
        let texture = try XCTUnwrap(
            view.texture(from: scene, crop: CGRect(origin: .zero, size: size)),
            "SKView produced no texture"
        )
        return NSImage(cgImage: texture.cgImage(), size: size)
    }

    private static func flatten(_ layers: [NSImage], size: CGSize) -> Data? {
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        RenderPalette.background.setFill()
        NSRect(origin: .zero, size: size).fill()
        for layer in layers {
            layer.draw(in: NSRect(origin: .zero, size: size))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

private extension SKNode {
    func addChild(contentsOf nodes: [SKNode]) { nodes.forEach(addChild) }
}
