import Foundation
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
    /// The low end, eight variants a row, drawn by the Metal renderer the
    /// game uses (`MetalSheet`).
    func testRenderTheLowEnd() throws {
        let rows: [(ZoneType, Int, String)] = [
            (.residential, 1, "housing T1"), (.residential, 3, "housing T2"),
            (.commercial, 1, "shops T1"), (.commercial, 3, "shops T2"),
            (.industrial, 1, "industry T1"), (.industrial, 3, "industry T2"), (.industrial, 5, "industry T3"),
        ]
        var cells: [MetalSheet.Cell] = []
        for (zone, density, name) in rows {
            for variant in 0 ..< 8 {
                cells.append(MetalSheet.Cell(label: "\(name) v\(variant)", zone: zone, density: density, variant: variant))
            }
        }
        try MetalSheet.write(cells, columns: 8, cell: CGSize(width: 240, height: 220), named: "low-end")
    }
}
