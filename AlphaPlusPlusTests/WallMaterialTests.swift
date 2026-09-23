import Foundation
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
        var cells: [MetalSheet.Cell] = []
        for zone in [ZoneType.commercial, .residential] {
            // Skip the landmarks: they are a different pass's subject and
            // they would dominate a row about surfaces.
            let variants = (0 ..< IsoTextureCache.variantCount).filter {
                !ZoneMassing.isLandmark(tier: 3, seed: IsoTextureCache.canonicalSeed(for: $0))
            }.prefix(8)
            cells += variants.map { .init(label: "\(zone.rawValue) v\($0)", zone: zone, density: 5, variant: $0) }
        }
        try MetalSheet.write(cells, columns: 8, cell: CGSize(width: 240, height: 340), greyscale: true,
                             named: "wall-materials")
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
