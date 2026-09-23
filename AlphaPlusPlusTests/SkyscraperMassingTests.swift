import XCTest
import Foundation
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
            case .shape(let shape): return max(result, shape.topZ)
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
    ///
    /// Weighed in the Metal renderer's own currency, triangles at the resting
    /// camera's tier, and held relative to the median form: a bound in
    /// absolute triangles would move every time the building vocabulary
    /// grew, where a form three times heavier than its peers is the thing
    /// that goes wrong.
    func testEveryFormStaysWithinTheGeometryBudget() throws {
        for zone in Self.zones {
            var worst: [String: Int] = [:]
            for variant in 0 ..< IsoTextureCache.variantCount {
                let seed = IsoTextureCache.canonicalSeed(for: variant)
                guard !ZoneMassing.isLandmark(tier: 4, seed: seed) else { continue }
                let built = MetalCityMesh.building(.init(zone: zone, density: 6, variant: variant, tier: .standard))
                let triangles = built.vertices.count / MetalCityRenderer.GPUVertex.floatCount / 3
                let form = "\(SkyscraperMassing.form(for: seed))"
                worst[form] = max(worst[form] ?? 0, triangles)
            }
            print("\(zone.rawValue) triangles per form: \(worst.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
            let median = worst.values.sorted()[worst.count / 2]
            for (form, count) in worst {
                XCTAssertLessThan(count, median * 3, "\(zone.rawValue) \(form) is far heavier than anything else")
            }
        }
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
                        case .shape: return "s"
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
        var cells: [MetalSheet.Cell] = []
        for zone in Self.zones {
            func cell(_ label: String, density: Int, where wanted: (GridPosition) -> Bool) throws -> MetalSheet.Cell {
                let variant = try XCTUnwrap(MetalSheet.variant(where: wanted), "no \(label) variant for \(zone)")
                return .init(label: "\(zone == .commercial ? "shops" : "homes") \(label)", zone: zone,
                             density: density, variant: variant, scale: 0.6)
            }
            cells.append(try cell("L5", density: 5) { !ZoneMassing.isLandmark(tier: 3, seed: $0) })
            for form in SkyscraperMassing.Form.allCases {
                cells.append(try cell("\(form)", density: 6) {
                    !ZoneMassing.isLandmark(tier: 4, seed: $0) && SkyscraperMassing.form(for: $0) == form
                })
            }
            cells.append(try cell("supertall", density: 6) { ZoneMassing.isLandmark(tier: 4, seed: $0) })
        }
        try MetalSheet.write(cells, columns: cells.count / Self.zones.count,
                             cell: CGSize(width: 190, height: 620), named: "skyline")
    }
}
