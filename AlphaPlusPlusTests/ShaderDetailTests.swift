import XCTest
@testable import AlphaPlusPlus

/// **P6: detail in the shader.** The shader varies every lit window by a seed
/// carried in its surface tag; these pin that the seed is there and that two
/// lots drawing the same building design do not light the same panes the
/// same way.
@MainActor
final class ShaderDetailTests: XCTestCase {

    private func windowTags(in built: MetalCityMesh.Built) -> [Float] {
        stride(from: 19, to: built.vertices.count, by: MetalCityRenderer.GPUVertex.floatCount)
            .map { built.vertices[$0] }
            .filter { MetalCityMesh.isWindowTag($0) }
    }

    /// Every window tag stays inside the band the shader reads as a window,
    /// or a window would quietly stop being one (and lose its calming from
    /// afar, its blinds and its warmth).
    func testEveryWindowTagIsInTheWindowBand() {
        let built = MetalCityMesh.build(MetalMotionTests.tickedCity())
        let tags = windowTags(in: built)
        XCTAssertFalse(tags.isEmpty, "no lit windows at all")
        XCTAssertTrue(tags.allSatisfy { $0 > 0.2 && $0 < 0.3 })
    }

    /// Two lots drawing the same variant light different panes differently:
    /// the lot is mixed into each window's seed.
    func testTheSameDesignOnTwoLotsIsLitDifferently() {
        var map = CityMap(width: 40, height: 8)
        // Two lots the texture cache quantises to the same variant.
        let first = GridPosition(x: 1, y: 1)
        let variant = IsoTextureCache.variant(for: first)
        let second = (4 ..< 38).lazy.map { GridPosition(x: $0, y: 1) }
            .first { IsoTextureCache.variant(for: $0) == variant && $0.x > first.x + 2 }!
        for origin in [first, second] {
            map.placeBuilding(zone: .commercial, origin: origin)
            for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = 5 }
        }
        let a = windowTags(in: MetalCityMesh.build(map, region: .init(x0: first.x, y0: 0, x1: first.x + 2, y1: 8)))
        let b = windowTags(in: MetalCityMesh.build(map, region: .init(x0: second.x, y0: 0, x1: second.x + 2, y1: 8)))
        XCTAssertEqual(a.count, b.count, "not the same design")
        XCTAssertNotEqual(a, b, "two lots of the same design light every pane identically")
    }
}
