import XCTest
import SpriteKit
@testable import AlphaPlusPlus

/// The isometric contact sheet: every zone `ZoneMassing` can build, at every
/// tier, across enough seeds to judge whether the variety is real.
///
/// The elevation sheet's counterpart, and it grows the same way the migration
/// does — `ZoneMassing` returns `nil` for zones not yet ported, so this renders
/// exactly what exists and nothing else. When the last zone lands, this sheet
/// is the one that stays.
///
/// **Lots are placed at a fixed point in their cell rather than centred on the
/// building.** `TileRenderer.fitIconToTile` had to centre and scale by the
/// drawn frame because an elevation has no real size. Massing does: a building
/// occupies actual space in an actual lot. Anchoring the *lot* instead of the
/// building keeps sizes honest across cells — a tier-1 shed should look small
/// on its lot, and a sheet that quietly scales every cell to fill would hide
/// exactly that.
final class IsometricContactSheetTests: XCTestCase {

    private static let projection = Isometric()
    private static let variantCount = 8
    private static let tierDensities = [1: 1, 2: 3, 3: 5]

    private struct Entry {
        let zone: ZoneType
        let density: Int
        let tier: Int
        let seed: GridPosition
        let label: String
    }

    /// Spread apart rather than consecutive, so neighbouring seeds cannot
    /// flatter the result by accident.
    private static func seeds() -> [GridPosition] {
        (0 ..< variantCount).map { GridPosition(x: $0 * 7, y: $0 * 3) }
    }

    /// Growable zones appear once per tier; everything else appears once.
    ///
    /// A service has no density — `maxDensity` is zero and its massing ignores
    /// the value entirely — so cataloguing it at three "tiers" rendered three
    /// identical copies of every fire station, which is noise pretending to be
    /// coverage.
    private static func catalog() -> [Entry] {
        var entries: [Entry] = []
        for zone in ZoneType.allCases {
            let cases: [(tier: Int, density: Int)] = zone.maxDensity > 0
                ? tierDensities.keys.sorted().map { ($0, tierDensities[$0]!) }
                : [(0, 0)]
            for (tier, density) in cases {
                for (index, seed) in seeds().enumerated() {
                    guard ZoneMassing.make(for: zone, density: density, seed: seed) != nil else { continue }
                    entries.append(Entry(
                        zone: zone, density: density, tier: tier, seed: seed,
                        label: zone.maxDensity > 0
                            ? "\(zone.rawValue) T\(tier).\(index)"
                            : "\(zone.rawValue).\(index)"
                    ))
                }
            }
        }
        return entries
    }

    // MARK: - Assertions

    func testEveryPortedZoneBuildsSomething() {
        let entries = Self.catalog()
        XCTAssertFalse(entries.isEmpty, "nothing has been ported to massing yet")
        for entry in entries {
            let massing = ZoneMassing.make(for: entry.zone, density: entry.density, seed: entry.seed)
            XCTAssertNotNil(massing, "\(entry.label): massing vanished between catalog and render")
            XCTAssertFalse(massing?.solids.isEmpty ?? true, "\(entry.label): no volumes at all")
        }
    }

    /// Nothing may stick out of its own lot. In elevation this was enforced by
    /// rescaling the whole building to fit, which is how a factory's storage
    /// tanks silently shrank the works they were attached to. Massing occupies
    /// real space, so the constraint is a real one and can simply be checked.
    func testMassingStaysInsideItsFootprint() {
        for entry in Self.catalog() {
            guard let massing = ZoneMassing.make(for: entry.zone, density: entry.density, seed: entry.seed) else {
                continue
            }
            let footprint = CGFloat(entry.zone.footprintSize)
            for solid in massing.solids {
                for face in solid.volume.faces {
                    for point in face.points {
                        XCTAssertGreaterThanOrEqual(point.x, -0.01, "\(entry.label): overhangs its lot at -x")
                        XCTAssertGreaterThanOrEqual(point.y, -0.01, "\(entry.label): overhangs its lot at -y")
                        XCTAssertLessThanOrEqual(point.x, footprint + 0.01, "\(entry.label): overhangs its lot at +x")
                        XCTAssertLessThanOrEqual(point.y, footprint + 0.01, "\(entry.label): overhangs its lot at +y")
                        XCTAssertGreaterThanOrEqual(point.z, -0.01, "\(entry.label): sinks below the ground")
                    }
                }
            }
        }
    }

    /// A generator whose thousands of buildings all look alike is no better
    /// than the two hand-drawn ones it replaced. Counted on the massing itself
    /// — volume count, roof kind, height — rather than on pixels, which is both
    /// cheaper and a stricter test of the thing that actually varies.
    ///
    /// **The bar is lower for services, and not in order to make this pass.** A
    /// growable zone tiles the map: hundreds of lots sit side by side, so
    /// repetition reads as wallpaper and real variety is the requirement. A
    /// city has two fire stations. What a service owes the player is an
    /// *identity* — the one silhouette that makes it findable while scanning
    /// for coverage gaps — and demanding eight distinguishable fire stations
    /// would trade that identity for a property nobody can perceive. They still
    /// have to not be literally one building, which is what the lower bound is.
    func testSeedsProduceStructurallyDifferentBuildings() {
        for zone in ZoneType.allCases {
            let cases: [(Int, Int)] = zone.maxDensity > 0
                ? Self.tierDensities.map { ($0.key, $0.value) }
                : [(0, 0)]
            for (tier, density) in cases {
                let signatures = Set(Self.seeds().compactMap { seed -> String? in
                    guard let massing = ZoneMassing.make(for: zone, density: density, seed: seed) else { return nil }
                    let kinds = massing.solids.map { solid -> String in
                        switch solid.volume {
                        case .box: return "b"
                        case .ridge: return "r"
                        case .cylinder: return "c"
                        }
                    }.joined()
                    let height = massing.solids.reduce(CGFloat(0)) { result, solid in
                        switch solid.volume {
                        case .box(let box): return max(result, box.z + box.height)
                        case .ridge(let ridge): return max(result, ridge.z + ridge.height)
                        case .cylinder(let cylinder): return max(result, cylinder.z + cylinder.height)
                        }
                    }
                    return "\(kinds)-\(Int(height * 12))-\(massing.panels.count)"
                })
                guard !signatures.isEmpty else { continue }
                XCTAssertGreaterThanOrEqual(
                    signatures.count, zone.maxDensity > 0 ? 6 : 2,
                    "\(zone.rawValue) tier \(tier): only \(signatures.count) distinct buildings across \(Self.variantCount) seeds"
                )
            }
        }
    }

    /// **The perf question, answered early rather than at the end.** An
    /// isometric building draws three faces per volume where an elevation drew
    /// one flat silhouette, so the node count per building is the thing most
    /// likely to make this migration a regression. Measuring it with one zone
    /// ported is far cheaper than discovering it with six.
    func testNodeCountIsComparableToElevation() {
        var isometricTotal = 0
        var elevationTotal = 0
        var buildings = 0

        for tier in [1, 2, 3] {
            let density = Self.tierDensities[tier]!
            for seed in Self.seeds() {
                guard let massing = ZoneMassing.make(for: .industrial, density: density, seed: seed) else { continue }
                let iso = IsometricBuilding.node(
                    for: massing, accent: .orange, tier: tier, in: Self.projection
                )
                let elevation = ZoneIcon.makeNode(for: .industrial, density: density, seed: seed)
                isometricTotal += Self.nodeCount(iso)
                elevationTotal += elevation.map(Self.nodeCount) ?? 0
                buildings += 1
            }
        }

        let isoAverage = Double(isometricTotal) / Double(buildings)
        let elevationAverage = Double(elevationTotal) / Double(buildings)
        print("🧮 nodes per industrial building — isometric \(String(format: "%.1f", isoAverage)), elevation \(String(format: "%.1f", elevationAverage))")

        XCTAssertLessThan(
            isoAverage, elevationAverage * 2.5,
            "isometric costs \(String(format: "%.1f", isoAverage / elevationAverage))x the nodes of an elevation — " +
            "cheap to fix now with one zone ported, expensive with six"
        )
    }

    private static func nodeCount(_ node: SKNode) -> Int {
        1 + node.children.reduce(0) { $0 + nodeCount($1) }
    }

    // MARK: - The render

    func testRenderIsometricContactSheet() throws {
        let entries = Self.catalog()
        let columns = 6
        let cell = CGSize(width: 190, height: 190)
        let captionHeight: CGFloat = 20
        let rows = Int((Double(entries.count) / Double(columns)).rounded(.up))
        let margin: CGFloat = 20
        let sheetSize = CGSize(
            width: CGFloat(columns) * cell.width + margin * 2,
            height: CGFloat(rows) * (cell.height + captionHeight) + margin * 2 + 34
        )

        let view = SKView(frame: NSRect(origin: .zero, size: cell))
        var cells: [NSImage] = []
        for entry in entries {
            cells.append(try renderCell(entry, size: cell, view: view))
        }

        let sheet = try XCTUnwrap(
            Self.compose(cells: cells, entries: entries, columns: columns,
                         cell: cell, captionHeight: captionHeight, margin: margin, sheetSize: sheetSize),
            "failed to compose the isometric contact sheet"
        )
        let destination = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ContactSheet/isometric-zones.png")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try sheet.write(to: destination)
        print("📐 Isometric zones: \(destination.path) (\(entries.count) buildings, \(sheet.count) bytes)")
        XCTAssertGreaterThan(sheet.count, 0)
    }

    private func renderCell(_ entry: Entry, size: CGSize, view: SKView) throws -> NSImage {
        let projection = Self.projection
        let footprint = CGFloat(entry.zone.footprintSize)
        let scene = SKScene(size: size)
        scene.backgroundColor = RenderPalette.background

        // Anchor the lot, not the building — see the type's doc comment.
        let lotCentre = projection.project(footprint / 2, footprint / 2, 0)
        let origin = CGPoint(x: size.width / 2 - lotCentre.x, y: size.height * 0.34 - lotCentre.y)

        for x in 0 ..< entry.zone.footprintSize {
            for y in 0 ..< entry.zone.footprintSize {
                let tile = SKShapeNode(path: projection.tileDiamond(x: CGFloat(x), y: CGFloat(y), inset: 0.015))
                tile.fillColor = RenderPalette.color(for: entry.zone, density: entry.density)
                tile.strokeColor = RenderPalette.ground.blended(withFraction: 0.3, of: .white) ?? .clear
                tile.lineWidth = 0.6
                tile.position = origin
                scene.addChild(tile)
            }
        }

        if let massing = ZoneMassing.make(for: entry.zone, density: entry.density, seed: entry.seed) {
            let node = IsometricBuilding.node(
                for: massing,
                accent: ZoneMassing.accent(for: entry.zone, density: entry.density),
                tier: entry.tier,
                in: projection
            )
            node.position = origin
            scene.addChild(node)
        }

        view.presentScene(scene)
        let texture = try XCTUnwrap(
            view.texture(from: scene, crop: CGRect(origin: .zero, size: size)),
            "\(entry.label): SKView produced no texture"
        )
        return NSImage(cgImage: texture.cgImage(), size: size)
    }

    private static func compose(
        cells: [NSImage], entries: [Entry], columns: Int,
        cell: CGSize, captionHeight: CGFloat, margin: CGFloat, sheetSize: CGSize
    ) -> Data? {
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(sheetSize.width * scale), pixelsHigh: Int(sheetSize.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = sheetSize
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        RenderPalette.background.setFill()
        NSRect(origin: .zero, size: sheetSize).fill()

        "Isometric massing — \(entries.count) buildings".draw(
            at: NSPoint(x: margin, y: sheetSize.height - margin - 20),
            withAttributes: [
                .font: NSFont(name: "Menlo-Bold", size: 16) ?? NSFont.boldSystemFont(ofSize: 16),
                .foregroundColor: NSColor.white,
            ]
        )
        let captionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Menlo", size: 9) ?? NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor(white: 0.78, alpha: 1),
        ]

        for (index, entry) in entries.enumerated() {
            let column = index % columns, row = index / columns
            let x = margin + CGFloat(column) * cell.width
            let y = sheetSize.height - margin - 34 - CGFloat(row + 1) * (cell.height + captionHeight)
            cells[index].draw(in: NSRect(x: x, y: y + captionHeight, width: cell.width, height: cell.height))
            let caption = entry.label
            let captionSize = caption.size(withAttributes: captionAttributes)
            caption.draw(at: NSPoint(x: x + (cell.width - captionSize.width) / 2, y: y + 4),
                         withAttributes: captionAttributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
