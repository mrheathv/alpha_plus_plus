import XCTest
@testable import AlphaPlusPlus

final class WaterTests: XCTestCase {

    func testNoSupplyAnywhereWithNoPipesAtAll() {
        var map = CityMap(width: 5, height: 5)
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 0, y: 0))

        let supply = Water.computeSupply(for: map)

        for tile in map.tiles {
            XCTAssertFalse(supply.isSupplied(at: tile.position))
        }
    }

    func testNoSupplyAnywhereWithNoTowerAtAll() {
        var map = CityMap(width: 5, height: 5)
        for x in 0 ..< 5 { map[GridPosition(x: x, y: 0)].zone = .pipe }
        // Pipes exist, but nothing is actually a source.

        let supply = Water.computeSupply(for: map)

        for x in 0 ..< 5 {
            XCTAssertFalse(supply.isSupplied(at: GridPosition(x: x, y: 0)))
        }
    }

    /// The whole point of a *network*, not a coverage radius: a pipe run
    /// connecting a tower to a distant building reports supplied along its
    /// entire connected length. `(1,0)` connects for free — it's already
    /// orthogonally adjacent to the tower's own footprint cell `(1,1)` —
    /// no separate "connect the tower" step needed.
    func testAConnectedPipeRunReportsSuppliedAlongItsWholeLength() {
        var map = CityMap(width: 10, height: 3)
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 0, y: 1)) // covers (0,1)-(1,2)
        for x in 1 ..< 8 { map[GridPosition(x: x, y: 0)].zone = .pipe }

        let supply = Water.computeSupply(for: map)

        for x in 1 ..< 8 {
            XCTAssertTrue(supply.isSupplied(at: GridPosition(x: x, y: 0)), "expected (\(x),0) to be supplied")
        }
    }

    /// A gap in the pipe run breaks the network — the far side, even
    /// though it's still literally made of pipe tiles, isn't reachable.
    func testADisconnectedPipeSegmentIsNotSupplied() {
        var map = CityMap(width: 10, height: 3)
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 0, y: 1)) // covers (0,1)-(1,2)
        map[GridPosition(x: 1, y: 0)].zone = .pipe // touches the tower's own footprint cell (1,1)
        map[GridPosition(x: 2, y: 0)].zone = .pipe
        // Gap at x=3 (left `.empty`) breaks the network.
        map[GridPosition(x: 4, y: 0)].zone = .pipe
        map[GridPosition(x: 5, y: 0)].zone = .pipe

        let supply = Water.computeSupply(for: map)

        XCTAssertTrue(supply.isSupplied(at: GridPosition(x: 2, y: 0)))
        XCTAssertFalse(supply.isSupplied(at: GridPosition(x: 4, y: 0)))
        XCTAssertFalse(supply.isSupplied(at: GridPosition(x: 5, y: 0)))
    }

    /// Funding is one city-wide dial (`ServiceFunding`'s own design), not
    /// per-building — defunding the water utility takes every tower
    /// offline at once, even over an otherwise perfectly connected network.
    func testAZeroFundedTowerSuppliesNothing() {
        var map = CityMap(width: 5, height: 3)
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 0, y: 1)) // covers (0,1)-(1,2)
        for x in 1 ..< 5 { map[GridPosition(x: x, y: 0)].zone = .pipe }
        map.serviceFunding.setLevel(0, for: .waterTower)

        let supply = Water.computeSupply(for: map)

        for x in 1 ..< 5 {
            XCTAssertFalse(supply.isSupplied(at: GridPosition(x: x, y: 0)))
        }
    }

    // MARK: - hasSupply

    func testHasSupplyIsTrueForABuildingTouchingAConnectedPipe() {
        var map = CityMap(width: 6, height: 3)
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 0, y: 1)) // covers (0,1)-(1,2)
        map[GridPosition(x: 1, y: 0)].zone = .pipe // touches the tower's own footprint cell (1,1)
        map[GridPosition(x: 2, y: 0)].zone = .pipe
        map[GridPosition(x: 3, y: 0)].zone = .pipe
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 3, y: 1)) // touches (3,0)
        map.waterSupply = Water.computeSupply(for: map)

        XCTAssertTrue(Water.hasSupply(at: GridPosition(x: 3, y: 1), in: map))
    }

    func testHasSupplyIsFalseWithNoConnectedPipeNearby() {
        let map = CityMap(width: 5, height: 5)
        XCTAssertFalse(Water.hasSupply(at: GridPosition(x: 2, y: 2), in: map))
    }
}
