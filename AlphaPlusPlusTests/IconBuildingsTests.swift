import Foundation
import XCTest
@testable import AlphaPlusPlus

/// The icons: prestige, earned by rank, one of each per city.
@MainActor
final class IconBuildingsTests: XCTestCase {

    private func city(ranked rank: Milestone?) throws -> GameController {
        let map = CityMap(width: 24, height: 24)
        let controller = GameController(map: map, peakPopulation: Unlocks.everythingUnlocked)
        let save = CitySave(map: map, treasury: 1_000_000, taxRate: 1, bondBalance: 0, history: [],
                            peakPopulation: Unlocks.everythingUnlocked, milestone: rank)
        try controller.restore(from: save)
        return controller
    }

    // MARK: - The rules

    /// Scarcity is the whole of what makes an icon special, so a second one
    /// is refused — and refused as `.blocked`, the way the cursor already
    /// says "not here".
    func testEachIconCanBeBuiltOncePerCity() throws {
        let controller = try city(ranked: .metropolis)
        for (index, icon) in IconBuildings.all.enumerated() {
            controller.selectTool(icon)
            XCTAssertEqual(controller.place(at: GridPosition(x: 2 + index * 4, y: 2)), .placed, "\(icon)")
            XCTAssertEqual(controller.place(at: GridPosition(x: 2 + index * 4, y: 8)), .blocked,
                           "a second \(icon) was allowed")
        }
    }

    /// Bulldozing one gives the right to build it back.
    func testBulldozingAnIconFreesItsSlot() throws {
        let controller = try city(ranked: .metropolis)
        controller.selectTool(.sunsetSpire)
        XCTAssertEqual(controller.place(at: GridPosition(x: 4, y: 4)), .placed)
        controller.bulldoze(at: GridPosition(x: 4, y: 4))
        controller.selectTool(.sunsetSpire)
        XCTAssertEqual(controller.place(at: GridPosition(x: 12, y: 12)), .placed)
    }

    func testEachIconWaitsForItsRank() throws {
        for icon in IconBuildings.all {
            let rank = try XCTUnwrap(IconBuildings.requiredRank(for: icon))
            XCTAssertFalse(try city(ranked: Milestone(rawValue: rank.rawValue - 1)).isUnlocked(icon),
                           "\(icon) is open before \(rank)")
            XCTAssertTrue(try city(ranked: rank).isUnlocked(icon), "\(icon) is locked at \(rank)")
            XCTAssertFalse(Unlocks.isUnlocked(icon, peakPopulation: 1_000_000), "a headcount opened \(icon)")
        }
    }

    /// Prestige only: nothing to run, and nothing in the simulation moves.
    func testAnIconDoesNothingButStandThere() {
        var bare = CityMap(width: 24, height: 24)
        bare.placeBuilding(zone: .road, origin: GridPosition(x: 0, y: 10))
        for icon in IconBuildings.all {
            XCTAssertEqual(icon.upkeepCost, 0, "\(icon) costs something to run")
            var map = bare
            map.placeBuilding(zone: icon, origin: GridPosition(x: 10, y: 10))
            XCTAssertEqual(Demand.compute(for: map), Demand.compute(for: bare), "\(icon) moved demand")
            let lot = GridPosition(x: 4, y: 11)
            XCTAssertEqual(LandValue.value(at: lot, in: map), LandValue.value(at: lot, in: bare),
                           accuracy: 1e-9, "\(icon) moved land value")
        }
    }

    func testEveryIconIsOnTheToolbarInItsOwnGroup() {
        for icon in IconBuildings.all {
            XCTAssertEqual(ToolCategory.containing(icon), .icons)
        }
    }

    // MARK: - The look

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

    /// The Sunset Spire is the building everything else is measured against,
    /// so it has to out-top the broadcast tower and every skyscraper variant,
    /// supertall landmarks included.
    func testTheSunsetSpireIsTheTallestThingInTheGame() throws {
        let spire = Self.top(of: try XCTUnwrap(ZoneMassing.make(for: .sunsetSpire, density: 0,
                                                                 seed: GridPosition(x: 0, y: 0))))
        var others: [CGFloat] = []
        for zone in ZoneType.allCases where zone != .sunsetSpire {
            let densities = zone.maxDensity > 0 ? Array(1 ... zone.maxDensity) : [0]
            for density in densities {
                for variant in 0 ..< IsoTextureCache.variantCount {
                    if let massing = ZoneMassing.make(for: zone, density: density,
                                                      seed: IsoTextureCache.canonicalSeed(for: variant)) {
                        others.append(Self.top(of: massing))
                    }
                }
            }
        }
        let next = others.max() ?? 0
        print("sunset spire tops out at \(spire), the next tallest at \(next)")
        XCTAssertGreaterThan(spire, next * 1.2)
    }

    /// All five, beside a level-6 skyscraper for scale.
    func testRenderTheIcons() throws {
        let cells = [MetalSheet.Cell(label: "L6 for scale", zone: .commercial, density: 6, variant: 0, scale: 0.9)]
            + IconBuildings.all.map { MetalSheet.Cell(label: RenderPalette.displayName(for: $0), zone: $0, scale: 0.9) }
        try MetalSheet.write(cells, columns: cells.count, cell: CGSize(width: 260, height: 900), named: "icons")
    }
}
