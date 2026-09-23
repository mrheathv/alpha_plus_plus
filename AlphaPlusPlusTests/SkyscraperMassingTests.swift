import XCTest
import SpriteKit
@testable import AlphaPlusPlus

/// **Level 6 is drawn as a different kind of building.** A sixth rung nobody
/// can see is not a rung, so these pin that every form turns up in the variants
/// the cache actually draws, and that the whole skyline stands clear of level 5.
@MainActor
final class SkyscraperMassingTests: XCTestCase {

    private static let zones: [ZoneType] = [.commercial, .residential]

    /// The seeds the game draws from, not arbitrary ones: `IsoTextureCache`
    /// quantises every lot to one of these.
    private static var variantSeeds: [GridPosition] {
        (0 ..< IsoTextureCache.variantCount).map { IsoTextureCache.canonicalSeed(for: $0) }
    }

    private static func top(of massing: BuildingMassing) -> CGFloat {
        massing.solids.reduce(0) { result, solid in
            switch solid.volume {
            case .box(let box): return max(result, box.z + box.height)
            case .ridge(let ridge): return max(result, ridge.z + ridge.height)
            case .cylinder(let cylinder): return max(result, cylinder.z + cylinder.height)
            }
        }
    }

    func testEveryFormTurnsUpInTheVariantsTheGameDraws() {
        let forms = Set(Self.variantSeeds
            .filter { !ZoneMassing.isLandmark(tier: 4, seed: $0) }
            .map { "\(SkyscraperMassing.form(for: $0))" })
        XCTAssertEqual(forms.count, SkyscraperMassing.Form.allCases.count,
                       "only \(forms.sorted()) appear among the cached variants")
    }

    /// Stated against the zone's own tallest ordinary level-5 tower rather than
    /// against a number, so it survives a retune of either.
    func testTheShortestSkyscraperOutTopsEveryOrdinaryLevelFiveTower() throws {
        for zone in Self.zones {
            let levelFive = try Self.variantSeeds
                .filter { !ZoneMassing.isLandmark(tier: 3, seed: $0) }
                .map { Self.top(of: try XCTUnwrap(ZoneMassing.make(for: zone, density: 5, seed: $0))) }
                .max() ?? 0
            let skyline = try Self.variantSeeds
                .map { Self.top(of: try XCTUnwrap(ZoneMassing.make(for: zone, density: 6, seed: $0))) }
            let shortest = skyline.min() ?? 0
            print("\(zone.rawValue): level 5 tops out at \(levelFive), level 6 spans \(shortest)…\(skyline.max() ?? 0)")
            XCTAssertGreaterThan(shortest, levelFive, "\(zone.rawValue): a skyscraper is no taller than level 5")
        }
    }

    /// The same forms, walled in each zone's own vocabulary: housing keeps its
    /// punched grid, commerce its bands. Different panel counts on the same
    /// seed are the cheapest honest evidence of that.
    func testHousingAndShopsDressTheSameFormDifferently() throws {
        var differing = 0
        for seed in Self.variantSeeds {
            let shops = try XCTUnwrap(ZoneMassing.make(for: .commercial, density: 6, seed: seed))
            let homes = try XCTUnwrap(ZoneMassing.make(for: .residential, density: 6, seed: seed))
            if shops.panels.count != homes.panels.count { differing += 1 }
        }
        XCTAssertGreaterThan(differing, Self.variantSeeds.count * 3 / 4)
    }

    /// **Every form, weighed.** The contact sheet only samples eight seeds,
    /// so a heavy form can hide from `testABuildingsGeometryStaysBounded`
    /// until the day it happens to be drawn. This builds each form in both
    /// zones from the variants the game uses and holds each to the same bound.
    func testEveryFormStaysWithinTheGeometryBudget() throws {
        let projection = Isometric()
        for zone in Self.zones {
            var worst: [String: Int] = [:]
            for seed in Self.variantSeeds where !ZoneMassing.isLandmark(tier: 4, seed: seed) {
                let massing = try XCTUnwrap(ZoneMassing.make(for: zone, density: 6, seed: seed))
                let node = IsometricBuilding.node(for: massing, accent: ZoneMassing.accent(for: zone, density: 6),
                                                  tier: 4, in: projection)
                let form = "\(SkyscraperMassing.form(for: seed))"
                worst[form] = max(worst[form] ?? 0, Self.nodeCount(node))
            }
            print("\(zone.rawValue) nodes per form: \(worst.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
            for (form, count) in worst {
                XCTAssertLessThan(count, 220, "\(zone.rawValue) \(form) is far heavier than anything else")
            }
        }
    }

    private static func nodeCount(_ node: SKNode) -> Int {
        1 + node.children.reduce(0) { $0 + nodeCount($1) }
    }

    /// **Distinct buildings per zone and tier, over the looks the game draws.**
    /// Counted on structure — volume kinds, height, panel count — the same
    /// signature the contact sheet uses, but over all of `variantCount`
    /// canonical seeds rather than eight arbitrary ones, because those are the
    /// only buildings a player will ever see.
    func testReportDistinctMassingsPerZoneAndTier() throws {
        for zone in [ZoneType.residential, .commercial, .industrial] {
            var line: [String] = []
            for density in [1, 3, 5, 6] where density <= zone.maxDensity {
                let signatures = Set(try Self.variantSeeds.map { seed -> String in
                    let massing = try XCTUnwrap(ZoneMassing.make(for: zone, density: density, seed: seed))
                    let kinds = massing.solids.map { solid -> String in
                        switch solid.volume {
                        case .box: return "b"
                        case .ridge: return "r"
                        case .cylinder: return "c"
                        }
                    }.joined()
                    return "\(kinds)-\(Int(Self.top(of: massing) * 12))-\(massing.panels.count)"
                })
                line.append("density \(density): \(signatures.count)")
                if density == 6 {
                    XCTAssertGreaterThanOrEqual(signatures.count, IsoTextureCache.variantCount - 2,
                                                "\(zone.rawValue): the skyline repeats itself")
                }
            }
            print("\(zone.rawValue) distinct of \(IsoTextureCache.variantCount): \(line.joined(separator: ", "))")
        }
    }

    func testIndustryNeverDrawsASkyscraper() {
        XCTAssertLessThan(ZoneType.industrial.maxDensity, 6)
    }

    // MARK: - The sheet

    /// Each form in each zone, the supertall, and an ordinary level-5 tower on
    /// the left for scale — one frame, one ground line, one scale, because a
    /// skyline is defined entirely by contrast with what stands beside it.
    func testRenderTheSkyline() throws {
        let projection = Isometric(tileWidth: 64)
        let cache = IsoTextureCache(projection: projection)
        let view = SKView()

        /// Found by position, for the reason `LandmarkTests` records: the cache
        /// quantises whatever seed it is handed.
        func sprite(_ zone: ZoneType, density: Int,
                    where wanted: (GridPosition) -> Bool) throws -> SKSpriteNode {
            for x in 0 ..< 64 {
                for y in 0 ..< 64 {
                    let position = GridPosition(x: x, y: y)
                    let canonical = IsoTextureCache.canonicalSeed(
                        for: IsoTextureCache.variant(for: position))
                    guard wanted(canonical),
                          let rendered = cache.rendered(for: zone, density: density, seed: position)
                    else { continue }
                    let node = SKSpriteNode(texture: rendered.texture, size: rendered.size)
                    node.setScale(1.1)
                    return node
                }
            }
            throw XCTSkip("no such variant for \(zone)")
        }

        var rows: [NSImage] = []
        for zone in Self.zones {
            var subjects: [SKSpriteNode] = [
                try sprite(zone, density: 5) { !ZoneMassing.isLandmark(tier: 3, seed: $0) }
            ]
            for form in SkyscraperMassing.Form.allCases {
                subjects.append(try sprite(zone, density: 6) {
                    !ZoneMassing.isLandmark(tier: 4, seed: $0) && SkyscraperMassing.form(for: $0) == form
                })
            }
            subjects.append(try sprite(zone, density: 6) { ZoneMassing.isLandmark(tier: 4, seed: $0) })

            let size = CGSize(width: 190, height: 620)
            var panels: [NSImage] = []
            for node in subjects {
                let frame = node.calculateAccumulatedFrame()
                node.position = CGPoint(x: size.width / 2, y: 40 - frame.minY)
                let scene = SKScene(size: size)
                scene.backgroundColor = RenderPalette.background
                let ground = SKSpriteNode(color: SKColor(white: 0.12, alpha: 1),
                                          size: CGSize(width: size.width, height: 1))
                ground.position = CGPoint(x: size.width / 2, y: 40)
                scene.addChild(ground)
                scene.addChild(node)
                view.frame = NSRect(origin: .zero, size: size)
                view.presentScene(scene)
                let texture = try XCTUnwrap(
                    view.texture(from: scene, crop: CGRect(origin: .zero, size: size)))
                panels.append(NSImage(cgImage: texture.cgImage(), size: size))
            }
            let row = NSImage(size: CGSize(width: CGFloat(panels.count) * (size.width + 8) + 8,
                                           height: size.height))
            row.lockFocus()
            RenderPalette.background.setFill()
            NSRect(origin: .zero, size: row.size).fill()
            for (index, panel) in panels.enumerated() {
                panel.draw(at: CGPoint(x: 8 + CGFloat(index) * (size.width + 8), y: 0),
                           from: .zero, operation: .sourceOver, fraction: 1)
            }
            row.unlockFocus()
            rows.append(row)
        }

        let gap: CGFloat = 10
        let sheet = NSImage(size: CGSize(width: rows.map(\.size.width).max() ?? 0,
                                         height: rows.map(\.size.height).reduce(0, +) + gap * CGFloat(rows.count + 1)))
        sheet.lockFocus()
        RenderPalette.background.setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        var y = gap
        for row in rows.reversed() {
            row.draw(at: CGPoint(x: 0, y: y), from: .zero, operation: .sourceOver, fraction: 1)
            y += row.size.height + gap
        }
        sheet.unlockFocus()

        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ContactSheet")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("skyline.png")
        guard let tiff = sheet.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("could not encode the sheet")
        }
        try png.write(to: url)
        print("wrote \(url.path) — level 5, the five forms, and the supertall; shops above, homes below")
    }
}
