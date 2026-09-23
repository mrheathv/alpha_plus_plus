import SpriteKit
import XCTest
@testable import AlphaPlusPlus

/// **The low end: most of a city's map area, and the first hour of play.**
///
/// Tiers 1 and 2 used to be two or three forms each, every one a box filling
/// its lot, so a suburb read as a small downtown. These pin that every tier
/// now has several forms among the variants the game draws, and write a sheet
/// of the low end to look at.
@MainActor
final class LowEndMassingTests: XCTestCase {

    private static var variantSeeds: [GridPosition] {
        (0 ..< IsoTextureCache.variantCount).map { IsoTextureCache.canonicalSeed(for: $0) }
    }

    /// A signature for the *shape* of a building rather than its numbers:
    /// what kinds of volume it is made of, and how many of each. Two lots of
    /// one form share it at any size; two forms almost never do.
    private static func shape(_ massing: BuildingMassing) -> String {
        var boxes = 0, ridges = 0, cylinders = 0, lit = 0
        for solid in massing.solids {
            switch solid.volume {
            case .box: boxes += 1
            case .ridge: ridges += 1
            case .cylinder: cylinders += 1
            case .shape: cylinders += 1
            }
            if case .lit = solid.style { lit += 1 }
        }
        return "\(boxes)b\(ridges)r\(cylinders)c\(lit)l"
    }

    /// Counted on the variants the game draws, since a form no variant is
    /// dealt is a form nobody sees.
    func testTheLowEndHasSeveralShapesPerTier() throws {
        for zone in [ZoneType.residential, .commercial, .industrial] {
            for density in [1, 3] {
                let shapes = Set(try Self.variantSeeds.map {
                    Self.shape(try XCTUnwrap(ZoneMassing.make(for: zone, density: density, seed: $0)))
                })
                print("\(zone.rawValue) density \(density): \(shapes.count) shapes over \(IsoTextureCache.variantCount) variants")
                if zone != .industrial {
                    XCTAssertGreaterThanOrEqual(shapes.count, 12, "\(zone.rawValue) density \(density) repeats itself")
                }
            }
        }
    }

    /// Low density should look it: the building on a suburban lot should
    /// leave ground uncovered, where it used to fill the lot to its margins.
    func testASuburbLeavesOpenGround() throws {
        var covered: [Double] = []
        for seed in Self.variantSeeds {
            let massing = try XCTUnwrap(ZoneMassing.make(for: .residential, density: 1, seed: seed))
            // The tallest volume's plan area stands in for the house: palms
            // and pools are small, and it is the house that fills the lot.
            let area = massing.solids.compactMap { solid -> Double? in
                if case .box(let box) = solid.volume, box.height > 0.3 { return Double(box.width * box.depth) }
                return nil
            }.max() ?? 0
            covered.append(area / 4)
        }
        let mean = covered.reduce(0, +) / Double(covered.count)
        print("tier-1 housing: the main building covers \(Int(mean * 100))% of its lot on average")
        XCTAssertLessThan(mean, 0.5)
    }

    // MARK: - The sheet

    /// Eight consecutive variants per row — which, forms being dealt in turn,
    /// shows every form a row has — for housing and shops at tiers 1 and 2,
    /// and industry at tiers 1 to 3.
    func testRenderTheLowEnd() throws {
        let projection = Isometric()
        let rows: [(ZoneType, Int, String)] = [
            (.residential, 1, "housing T1"), (.residential, 3, "housing T2"),
            (.commercial, 1, "shops T1"), (.commercial, 3, "shops T2"),
            (.industrial, 1, "industry T1"), (.industrial, 3, "industry T2"), (.industrial, 5, "industry T3"),
        ]
        let cell = CGSize(width: 170, height: 170)
        let columns = 8
        let view = SKView(frame: NSRect(origin: .zero, size: cell))
        let sheetSize = CGSize(width: CGFloat(columns) * cell.width + 110, height: CGFloat(rows.count) * cell.height)
        let sheet = NSImage(size: sheetSize)
        var images: [[NSImage]] = []
        for (zone, density, _) in rows {
            var row: [NSImage] = []
            for variant in 0 ..< columns {
                let scene = SKScene(size: cell)
                scene.backgroundColor = RenderPalette.background
                let lotCentre = projection.project(1, 1, 0)
                let origin = CGPoint(x: cell.width / 2 - lotCentre.x, y: cell.height * 0.3 - lotCentre.y)
                for x in 0 ..< 2 {
                    for y in 0 ..< 2 {
                        let tile = SKShapeNode(path: projection.tileDiamond(x: CGFloat(x), y: CGFloat(y), inset: 0.015))
                        tile.fillColor = RenderPalette.color(for: zone, density: density)
                        tile.strokeColor = .clear
                        tile.position = origin
                        scene.addChild(tile)
                    }
                }
                let seed = IsoTextureCache.canonicalSeed(for: variant)
                let massing = try XCTUnwrap(ZoneMassing.make(for: zone, density: density, seed: seed))
                let node = IsometricBuilding.node(for: massing, accent: ZoneMassing.accent(for: zone, density: density),
                                                  tier: RenderPalette.growthTier(for: density), in: projection)
                node.position = origin
                scene.addChild(node)
                view.presentScene(scene)
                let texture = try XCTUnwrap(view.texture(from: scene, crop: CGRect(origin: .zero, size: cell)))
                row.append(NSImage(cgImage: texture.cgImage(), size: cell))
            }
            images.append(row)
        }
        sheet.lockFocus()
        RenderPalette.background.setFill()
        NSRect(origin: .zero, size: sheetSize).fill()
        for (index, row) in images.enumerated() {
            let y = sheetSize.height - CGFloat(index + 1) * cell.height
            rows[index].2.draw(at: NSPoint(x: 8, y: y + cell.height / 2),
                               withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                                                .foregroundColor: NSColor.white])
            for (column, image) in row.enumerated() {
                image.draw(at: CGPoint(x: 110 + CGFloat(column) * cell.width, y: y),
                           from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        sheet.unlockFocus()
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ContactSheet")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("low-end.png")
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(sheet.tiffRepresentation))?
            .representation(using: .png, properties: [:]))
        try png.write(to: url)
        print("wrote \(url.path)")
    }
}
