import XCTest
@testable import AlphaPlusPlus

/// **Level 6, the skyline**: housing and shops reach it, industry does not,
/// and it needs a subway entrance or a rail station within walking reach on
/// top of everything level 5 needs.
@MainActor
final class SkylineTests: XCTestCase {

    /// A level-5 block with water, power, a school, services and a park — the
    /// best address a city without rapid transit can offer.
    private func topOfTheLadder(_ zone: ZoneType = .residential) -> CityMap {
        var map = CityMap(width: 30, height: 24)
        for x in 0 ..< 30 { map[GridPosition(x: x, y: 2)].zone = .road }
        map.placeBuilding(zone: zone, origin: GridPosition(x: 0, y: 0))
        for cell in map.footprintCells(origin: GridPosition(x: 0, y: 0), size: 2) { map[cell].density = 5 }
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 8, y: 6))
        map.placeBuilding(zone: .generator, origin: GridPosition(x: 12, y: 6))
        for x in 0 ... 13 {
            map[GridPosition(x: x, y: 5)].hasPipe = true
            map[GridPosition(x: x, y: 5)].hasPowerLine = true
        }
        for y in 0 ... 6 {
            map[GridPosition(x: 1, y: y)].hasPipe = true
            map[GridPosition(x: 1, y: y)].hasPowerLine = true
        }
        map.placeBuilding(zone: .school, origin: GridPosition(x: 3, y: 0))
        map.placeBuilding(zone: .policeStation, origin: GridPosition(x: 5, y: 0))
        map.placeBuilding(zone: .fireStation, origin: GridPosition(x: 7, y: 0))
        map.placeBuilding(zone: .park, origin: GridPosition(x: 2, y: 0))
        map.waterSupply = Water.computeSupply(for: map)
        map.powerSupply = PowerGrid.computeSupply(for: map, outageActive: false)
        return map
    }

    private func status(_ map: CityMap) -> LotStatus {
        CitySimulator.status(of: map[GridPosition(x: 0, y: 0)], in: map,
                             using: ZoneDistanceField.compute(for: map))
    }

    func testTheSkylineWaitsForRapidTransit() {
        XCTAssertEqual(status(topOfTheLadder()), .needsRapidTransit)
    }

    func testASubwayEntranceInReachLetsItGrow() {
        var map = topOfTheLadder()
        map.placeBuilding(zone: .subway, origin: GridPosition(x: 6, y: 3))
        guard case .readyToGrow = status(map) else {
            return XCTFail("a subway in reach did not open the skyline: \(status(map))")
        }
        var rng = AlwaysZeroRNG()
        map = advanceOneLevel(map, at: GridPosition(x: 0, y: 0), using: &rng)
        XCTAssertEqual(map[GridPosition(x: 0, y: 0)].density, 6)
    }

    func testARailStationInReachCountsToo() {
        var map = topOfTheLadder()
        map.placeBuilding(zone: .railStation, origin: GridPosition(x: 9, y: 0))
        guard case .readyToGrow = status(map) else {
            return XCTFail("a rail station in reach did not open the skyline: \(status(map))")
        }
    }

    /// A catchment, not a checkbox on the whole city.
    func testAStationOutOfReachDoesNotCount() {
        var map = topOfTheLadder()
        map.placeBuilding(zone: .subway, origin: GridPosition(x: 28, y: 20))
        XCTAssertEqual(status(map), .needsRapidTransit)
    }

    /// Industry stops at five: wide and low is its identity.
    func testIndustryHasNoSkyline() {
        XCTAssertEqual(ZoneType.industrial.maxDensity, 5)
        var map = topOfTheLadder(.industrial)
        map.placeBuilding(zone: .subway, origin: GridPosition(x: 6, y: 3))
        XCTAssertEqual(status(map), .atMaximumDensity)
    }

    /// The skyline is drawn as its own tier, not as a taller level 5.
    func testTheSkylineIsItsOwnTier() {
        XCTAssertEqual(RenderPalette.growthTier(for: 5), 3)
        XCTAssertEqual(RenderPalette.growthTier(for: 6), 4)
    }
}
