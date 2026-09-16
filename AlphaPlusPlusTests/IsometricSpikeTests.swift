import XCTest
import SpriteKit
@testable import AlphaPlusPlus

/// Renders a city block in isometric from `BuildingMassing`, at several height
/// scales.
///
/// **Still a spike.** Nothing here is wired into the running game, and the
/// massing is deliberately crude — the real vocabularies (a strip of shops, a
/// corner unit, a row of houses, a sawtooth roof) are ported zone by zone in
/// the phases that follow. What this file is for is deciding things that have
/// to be decided *before* those ports, because every generator would otherwise
/// be written against the wrong answer.
///
/// The open question it exists to answer is `Isometric.heightUnit`: the single
/// knob that decides whether the city reads as a model village or a skyline.
/// It is deliberately independent of `tileHeight` — a storey is not as tall as
/// a lot is wide — which means nothing determines it but looking.
final class IsometricSpikeTests: XCTestCase {

    private static let tilesWide = 11
    private static let tilesHigh = 11
    private static let roadEvery = 5

    /// The candidates, rendered side by side. A tile is 64 points wide.
    private static let heightScales: [(label: String, heightUnit: CGFloat)] = [
        ("heightUnit 22 — low-rise", 22),
        ("heightUnit 30 — the spike's guess", 30),
        ("heightUnit 40 — skyline", 40),
    ]

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

    private static func massing(for lot: Lot) -> BuildingMassing {
        var random = BuildingRandom(seed: lot.origin, salt: 900 + lot.tier)
        let ox = CGFloat(lot.origin.x), oy = CGFloat(lot.origin.y)
        var massing = BuildingMassing()

        /// Lit panels over both visible walls of a box.
        func glaze(_ box: Box, rows: Int, columns: Int, chance: Double, salt: Int) {
            for face in [Panel.Face.right, .left] {
                for row in 0 ..< rows {
                    for column in 0 ..< columns {
                        guard random.chance(chance) else { continue }
                        massing.panels.append(Panel(
                            box: box, face: face,
                            u0: (CGFloat(column) + 0.24) / CGFloat(columns),
                            u1: (CGFloat(column) + 0.76) / CGFloat(columns),
                            v0: (CGFloat(row) + 0.22) / CGFloat(rows),
                            v1: (CGFloat(row) + 0.7) / CGFloat(rows),
                            color: ZoneIcon.windowColor(row: row, column: column, salt: salt)
                        ))
                    }
                }
            }
        }

        switch lot.zone {
        case .industrial:
            // Wide and low, and it spreads: the hall covers the lot and the
            // chimneys are the tall thing, not the building.
            let height = CGFloat(random.value(in: 0.3 ... 0.42)) + CGFloat(lot.tier) * 0.08
            let hall = Box(x: ox + 0.08, y: oy + 0.08, z: 0, width: 1.84, depth: 1.84, height: height)
            massing.add(.box(hall))
            glaze(hall, rows: 1, columns: 3, chance: 0.5, salt: lot.tier)

            if random.chance(0.6) {
                massing.add(.ridge(Ridge(
                    x: hall.x, y: hall.y, z: height,
                    width: hall.width, depth: hall.depth,
                    height: CGFloat(random.value(in: 0.18 ... 0.3)),
                    axis: .x, ridgePosition: random.chance(0.5) ? 1 : 0.5
                )))
            }
            for _ in 0 ..< random.int(in: 1 ... min(3, lot.tier + 1)) {
                massing.add(.cylinder(Cylinder(
                    x: ox + CGFloat(random.value(in: 0.4 ... 1.6)),
                    y: oy + CGFloat(random.value(in: 0.4 ... 1.6)),
                    z: height,
                    radius: CGFloat(random.value(in: 0.1 ... 0.15)),
                    height: CGFloat(random.value(in: 0.45 ... 0.5 + Double(lot.tier) * 0.3))
                )))
            }
            if lot.tier >= 2, random.chance(0.7) {
                massing.add(.cylinder(Cylinder(
                    x: ox + CGFloat(random.value(in: 0.4 ... 1.6)),
                    y: oy + CGFloat(random.value(in: 0.4 ... 1.6)),
                    z: 0, radius: CGFloat(random.value(in: 0.24 ... 0.32)),
                    height: CGFloat(random.value(in: 0.4 ... 0.6))
                )))
            }
            if lot.tier >= 3 {
                massing.badges.append(Badge(at: Point3(x: ox + 1.7, y: oy + 1.9, z: height * 0.6), size: 16))
            }

        case .residential:
            // Steps back as it rises.
            var inset: CGFloat = 0.12
            var z: CGFloat = 0
            for _ in 0 ..< max(1, lot.tier) {
                let height = CGFloat(random.value(in: 0.42 ... 0.68))
                    * (lot.tier == 1 ? 1 : 1.15)
                let box = Box(x: ox + inset, y: oy + inset, z: z,
                              width: 2 - inset * 2, depth: 2 - inset * 2, height: height)
                massing.add(.box(box))
                glaze(box, rows: max(1, Int(height / 0.3)), columns: 3, chance: 0.66, salt: Int(z * 10))
                z += height
                inset += CGFloat(random.value(in: 0.14 ... 0.26))
            }
            // Rooftop clutter rather than a lit crown: housing's half of the
            // split the elevation generators already draw.
            if random.chance(0.5) {
                massing.add(.ridge(Ridge(
                    x: ox + inset - 0.06, y: oy + inset - 0.06, z: z,
                    width: 2 - (inset - 0.06) * 2, depth: 2 - (inset - 0.06) * 2,
                    height: CGFloat(random.value(in: 0.22 ... 0.34)),
                    axis: random.chance(0.5) ? .x : .y
                )))
            } else {
                massing.add(.cylinder(Cylinder(
                    x: ox + 1, y: oy + 1, z: z,
                    radius: CGFloat(random.value(in: 0.14 ... 0.2)),
                    height: CGFloat(random.value(in: 0.18 ... 0.26))
                )))
            }

        case .commercial:
            // A wide glazed podium with a slimmer tower standing on it.
            let podiumHeight = CGFloat(random.value(in: 0.26 ... 0.36))
            let podium = Box(x: ox + 0.05, y: oy + 0.05, z: 0,
                             width: 1.9, depth: 1.9, height: podiumHeight)
            massing.add(.box(podium))
            // The shopfront: one unbroken slab of light per wall.
            for face in [Panel.Face.right, .left] {
                massing.panels.append(Panel(box: podium, face: face,
                                            u0: 0.06, u1: 0.94, v0: 0.12, v1: 0.62,
                                            color: ZoneIcon.litAccent))
            }

            let inset = CGFloat(random.value(in: 0.28 ... 0.46))
            let towerHeight = CGFloat(random.value(in: 0.45 ... 0.7)) * CGFloat(lot.tier) + 0.15
            let tower = Box(x: ox + inset, y: oy + inset, z: podiumHeight,
                            width: 2 - inset * 2, depth: 2 - inset * 2, height: towerHeight)
            massing.add(.box(tower))
            // Continuous glazing bands, not a punched grid — commerce's half of
            // the contrast with housing.
            let bands = max(1, Int(towerHeight / 0.26))
            for face in [Panel.Face.right, .left] {
                for band in 0 ..< bands where random.chance(0.85) {
                    massing.panels.append(Panel(
                        box: tower, face: face, u0: 0.1, u1: 0.9,
                        v0: (CGFloat(band) + 0.22) / CGFloat(bands),
                        v1: (CGFloat(band) + 0.68) / CGFloat(bands),
                        color: ZoneIcon.windowColor(row: band, column: 0, salt: 7)
                    ))
                }
            }
            // Offices light their tops.
            massing.add(.box(Box(x: tower.x - 0.04, y: tower.y - 0.04, z: tower.z + towerHeight,
                                 width: tower.width + 0.08, depth: tower.depth + 0.08, height: 0.07)),
                        .lit(ZoneIcon.signColor(for: lot.origin)))

        default:
            massing.add(.box(Box(x: ox + 0.1, y: oy + 0.1, z: 0, width: 1.8, depth: 1.8, height: 0.4)))
        }

        return massing
    }

    // MARK: - The render

    func testRenderHeightScaleComparison() throws {
        var panels: [(String, NSImage)] = []
        for scale in Self.heightScales {
            let projection = Isometric(tileWidth: 64, heightUnit: scale.heightUnit)
            panels.append((scale.label, try render(with: projection)))
        }

        let sheet = try XCTUnwrap(Self.compose(panels), "failed to compose the comparison")
        let destination = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ContactSheet/isometric-heights.png")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try sheet.write(to: destination)
        print("📐 Isometric height scales: \(destination.path) (\(sheet.count) bytes)")
        XCTAssertGreaterThan(sheet.count, 0)
    }

    private func render(with projection: Isometric) throws -> NSImage {
        let w = CGFloat(Self.tilesWide), h = CGFloat(Self.tilesHigh)
        let corners = [
            projection.project(0, 0, 0), projection.project(w, 0, 0),
            projection.project(0, h, 0), projection.project(w, h, 0),
        ]
        let margin: CGFloat = 40
        let xs = corners.map { $0.x }, ys = corners.map { $0.y }
        let minX = xs.min()! - margin, maxX = xs.max()! + margin
        let minY = ys.min()! - margin
        let maxY = ys.max()! + margin + 5 * projection.heightUnit
        let size = CGSize(width: maxX - minX, height: maxY - minY)
        let origin = CGPoint(x: -minX, y: -minY)
        let view = SKView(frame: NSRect(origin: .zero, size: size))

        var layers: [NSImage] = [try pass(size: size, view: view) { root in
            for y in 0 ..< Self.tilesHigh {
                for x in 0 ..< Self.tilesWide {
                    let road = Self.isRoad(x, y)
                    let tile = SKShapeNode(path: projection.tileDiamond(
                        x: CGFloat(x), y: CGFloat(y), inset: 0.015
                    ))
                    tile.fillColor = RenderPalette.color(for: road ? .road : .empty, density: 0)
                    tile.strokeColor = road
                        ? RenderPalette.networkAccentColor(for: .road).withAlphaComponent(0.45)
                        : RenderPalette.ground.blended(withFraction: 0.3, of: .white) ?? .clear
                    tile.lineWidth = road ? 1.5 : 0.6
                    tile.position = origin
                    root.addChild(tile)
                }
            }
        }]

        // Depth-sorted batches. Isometric buildings overlap, so they cannot be
        // composited per tile rect the way the top-down streetscape does; and
        // one scene holding every blur pass at once silently drops most of
        // them.
        let sorted = Isometric.sorted(Self.lots()) { (CGFloat($0.origin.x + $0.origin.y), 0) }
        for batch in stride(from: 0, to: sorted.count, by: 6) {
            let slice = Array(sorted[batch ..< min(batch + 6, sorted.count)])
            layers.append(try pass(size: size, view: view) { root in
                for lot in slice {
                    let node = IsometricBuilding.node(
                        for: Self.massing(for: lot),
                        accent: RenderPalette.tierColor(for: lot.zone, tier: lot.tier),
                        tier: lot.tier,
                        in: projection
                    )
                    node.position = origin
                    root.addChild(node)
                }
            })
        }
        return try XCTUnwrap(Self.flatten(layers, size: size), "failed to flatten")
    }

    private func pass(size: CGSize, view: SKView, _ build: (SKNode) -> Void) throws -> NSImage {
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

    private static func flatten(_ layers: [NSImage], size: CGSize) -> NSImage? {
        guard let rep = bitmap(size: size) else { return nil }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        RenderPalette.background.setFill()
        NSRect(origin: .zero, size: size).fill()
        layers.forEach { $0.draw(in: NSRect(origin: .zero, size: size)) }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private static func compose(_ panels: [(String, NSImage)]) -> Data? {
        let labelHeight: CGFloat = 30
        let margin: CGFloat = 16
        let width = panels.reduce(margin) { $0 + $1.1.size.width + margin }
        let height = (panels.map { $0.1.size.height }.max() ?? 0) + labelHeight + margin * 2

        guard let rep = bitmap(size: CGSize(width: width, height: height)) else { return nil }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        RenderPalette.background.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Menlo-Bold", size: 14) ?? NSFont.boldSystemFont(ofSize: 14),
            .foregroundColor: NSColor(white: 0.85, alpha: 1),
        ]
        var x = margin
        for (label, image) in panels {
            image.draw(in: NSRect(x: x, y: margin, width: image.size.width, height: image.size.height))
            label.draw(at: NSPoint(x: x, y: height - labelHeight), withAttributes: attributes)
            x += image.size.width + margin
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func bitmap(size: CGSize) -> NSBitmapImageRep? {
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        rep?.size = size
        return rep
    }
}
