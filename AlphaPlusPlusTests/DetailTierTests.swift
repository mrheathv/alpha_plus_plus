import XCTest
import SpriteKit
@testable import AlphaPlusPlus

/// **Level of detail as a property of each part** (`DetailTier`). A part
/// carries the farthest camera it is drawn at; the Metal renderer builds each
/// chunk for the tier its camera is at, and SpriteKit draws what it always did.
@MainActor
final class DetailTierTests: XCTestCase {

    // MARK: - The camera

    func testEachCameraMapsToItsTier() {
        func tier(_ pixels: Float) -> DetailTier { MetalCityRenderer.tier(for: pixels, from: .standard) }
        XCTAssertEqual(tier(43), .far, "the widest camera")
        XCTAssertEqual(tier(128), .standard, "the resting camera must draw exactly what it does today")
        XCTAssertEqual(tier(256), .near, "the old closest camera")
        XCTAssertEqual(tier(640), .street, "the new closest camera")
    }

    /// One number read in both directions makes a pinch resting on a boundary
    /// flip the whole city back and forth; each boundary has a gap.
    func testEveryBoundaryHasHysteresis() {
        XCTAssertEqual(MetalCityRenderer.tier(for: 170, from: .near), .near, "released the near tier too early")
        XCTAssertEqual(MetalCityRenderer.tier(for: 170, from: .standard), .standard, "engaged the near tier too early")
        XCTAssertEqual(MetalCityRenderer.tier(for: 360, from: .street), .street)
        XCTAssertEqual(MetalCityRenderer.tier(for: 360, from: .near), .near)
        XCTAssertEqual(MetalCityRenderer.tier(for: 96, from: .standard), .standard)
        XCTAssertEqual(MetalCityRenderer.tier(for: 96, from: .far), .far)
        // A jump across several boundaries lands in one step.
        XCTAssertEqual(MetalCityRenderer.tier(for: 700, from: .far), .street)
        XCTAssertEqual(MetalCityRenderer.tier(for: 40, from: .street), .far)
    }

    // MARK: - Parts

    private func tagged() -> BuildingMassing {
        var massing = BuildingMassing()
        let box = Box(x: 0.2, y: 0.2, z: 0, width: 1, depth: 1, height: 1)
        massing.add(.box(box))
        massing.add(.box(Box(x: 0.4, y: 0.4, z: 1, width: 0.3, depth: 0.3, height: 0.2)), from: .standard)
        massing.add(.box(Box(x: 0.5, y: 0.5, z: 1.2, width: 0.1, depth: 0.1, height: 0.1)), from: .near)
        massing.panels.append(Panel(box: box, face: .right, u0: 0.2, u1: 0.8, v0: 0.2, v1: 0.8, color: .white))
        massing.panels.append(Panel(box: box, face: .left, u0: 0.4, u1: 0.45, v0: 0.2, v1: 0.8, color: .white)
            .at(.street))
        return massing
    }

    /// Zooming out only ever drops parts that were explicitly tagged: an
    /// untagged part is drawn at every tier.
    func testUntaggedPartsAreDrawnAtEveryTier() {
        let massing = tagged()
        for tier in DetailTier.allCases {
            let drawn = massing.drawn(at: tier)
            XCTAssertEqual(drawn.solids.filter { $0.tier == .far }.count, 1, "\(tier) dropped an untagged solid")
            XCTAssertEqual(drawn.panels.filter { $0.tier == .far }.count, 1, "\(tier) dropped an untagged panel")
        }
        XCTAssertEqual(massing.drawn(at: .far).solids.count, 1)
        XCTAssertEqual(massing.drawn(at: .standard).solids.count, 2)
        XCTAssertEqual(massing.drawn(at: .near).solids.count, 3)
        XCTAssertEqual(massing.drawn(at: .street).panels.count, 2)
    }

    /// The Metal renderer draws a tagged part at its tier and not before.
    func testMetalDrawsATaggedPartOnlyFromItsTier() {
        let key = MetalCityMesh.Cache.Key(zone: .commercial, density: 5, variant: 3)
        var near = key; near.tier = .near
        // No generator tags parts yet, so the difference between the tiers is
        // the renderer's own close-up marks; this pins that the tier reaches
        // the building at all.
        XCTAssertGreaterThan(MetalCityMesh.building(near).vertices.count,
                             MetalCityMesh.building(key).vertices.count)
    }

    // MARK: - The floor

    /// A part's largest extent in tiles: a speck is small in every direction,
    /// while a mast or a lit fin is thin but long and reads perfectly well.
    static func largestExtent(of points: [Point3]) -> CGFloat {
        let xs = points.map(\.x), ys = points.map(\.y), zs = points.map(\.z)
        return max(xs.max()! - xs.min()!, ys.max()! - ys.min()!, zs.max()! - zs.min()!)
    }

    /// **No part is smaller than its tier's floor.** Bounded only for parts
    /// with an explicit tier; untagged parts are reported, since today's art
    /// predates tiers and the tagging passes will move them.
    func testNoTaggedPartIsSmallerThanItsTiersFloor() {
        var untaggedBelowFloor = 0, untagged = 0
        for zone in ZoneType.allCases {
            let densities = zone.maxDensity > 0 ? Array(1 ... zone.maxDensity) : [0]
            for density in densities {
                for variant in 0 ..< IsoTextureCache.variantCount {
                    guard let massing = ZoneMassing.make(for: zone, density: density,
                                                         seed: IsoTextureCache.canonicalSeed(for: variant))
                    else { continue }
                    for solid in massing.solids {
                        let extent = Self.largestExtent(of: solid.volume.faces.flatMap(\.points))
                        if solid.tier == .far {
                            untagged += 1
                            if extent < DetailTier.floor(.far) { untaggedBelowFloor += 1 }
                        } else {
                            XCTAssertGreaterThanOrEqual(extent, DetailTier.floor(solid.tier),
                                                        "\(zone) \(density) v\(variant): a \(solid.tier) solid is a speck")
                        }
                    }
                    for panel in massing.panels where panel.tier != .far {
                        XCTAssertGreaterThanOrEqual(Self.largestExtent(of: panel.corners), DetailTier.floor(panel.tier),
                                                    "\(zone) \(density) v\(variant): a \(panel.tier) panel is a speck")
                    }
                }
            }
        }
        print("untagged solids smaller than the far floor: \(untaggedBelowFloor) of \(untagged) — reported, not bounded")
    }

    /// The fixture's own speck fails the bound, so the bound is real.
    func testTheFloorCatchesASpeck() {
        let speck = Box(x: 0, y: 0, z: 0, width: 0.01, depth: 0.01, height: 0.01)
        XCTAssertLessThan(Self.largestExtent(of: Volume.box(speck).faces.flatMap(\.points)), DetailTier.floor(.street))
        let mast = Box(x: 0, y: 0, z: 0, width: 0.02, depth: 0.02, height: 1.2)
        XCTAssertGreaterThanOrEqual(Self.largestExtent(of: Volume.box(mast).faces.flatMap(\.points)),
                                    DetailTier.floor(.far), "a mast is a line, not a speck")
    }

    /// A panel's standoff moves it off its wall in the Metal renderer, so a
    /// dark frame can stand in front of the lit glass it borders.
    func testAStandoffMovesAPanelOffItsWall() {
        let box = Box(x: 0.5, y: 0.5, z: 0, width: 1, depth: 1, height: 1)
        func frontX(_ standoff: CGFloat?) -> Float {
            var massing = BuildingMassing()
            massing.add(.box(box))
            var panel = Panel(box: box, face: .right, u0: 0.2, u1: 0.8, v0: 0.2, v1: 0.8,
                              color: SKColor(white: 0.05, alpha: 1))
            panel.standoff = standoff
            massing.panels.append(panel)
            let built = MetalCityMesh.building(.init(zone: .commercial, density: 3, variant: 0), massing: massing)
            return stride(from: 0, to: built.vertices.count, by: MetalCityRenderer.GPUVertex.floatCount)
                .map { built.vertices[$0] }.max() ?? 0
        }
        XCTAssertEqual(frontX(nil), 1.504, accuracy: 0.0005, "the default dark standoff moved")
        XCTAssertEqual(frontX(0.015), 1.515, accuracy: 0.0005)
    }
}
