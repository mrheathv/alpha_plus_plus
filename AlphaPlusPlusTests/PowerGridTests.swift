import XCTest
@testable import AlphaPlusPlus

final class PowerGridTests: XCTestCase {

    func testNoSupplyAnywhereWithNoPowerLinesAtAll() {
        var map = CityMap(width: 6, height: 6)
        map.placeBuilding(zone: .powerPlant, origin: GridPosition(x: 0, y: 0))

        let supply = PowerGrid.computeSupply(for: map, outageActive: false)

        for tile in map.tiles {
            XCTAssertFalse(supply.isSupplied(at: tile.position))
        }
    }

    func testNoSupplyAnywhereWithNoPlantAtAll() {
        var map = CityMap(width: 5, height: 5)
        for x in 0 ..< 5 { map[GridPosition(x: x, y: 0)].hasPowerLine = true }
        // Power lines exist, but nothing is actually a source.

        let supply = PowerGrid.computeSupply(for: map, outageActive: false)

        for x in 0 ..< 5 {
            XCTAssertFalse(supply.isSupplied(at: GridPosition(x: x, y: 0)))
        }
    }

    /// The whole point of a *network*, not a coverage radius: a power-line
    /// run connecting a plant to a distant building reports supplied along
    /// its entire connected length. The plant is 3×3 (unlike the water
    /// tower's 2×2), placed at origin `(0,1)`, so its footprint runs
    /// `(0,1)-(2,3)` — `(2,0)` connects for free, already orthogonally
    /// adjacent to the plant's own footprint cell `(2,1)`.
    func testAConnectedPowerLineRunReportsSuppliedAlongItsWholeLength() {
        var map = CityMap(width: 10, height: 4)
        map.placeBuilding(zone: .powerPlant, origin: GridPosition(x: 0, y: 1)) // covers (0,1)-(2,3)
        for x in 2 ..< 9 { map[GridPosition(x: x, y: 0)].hasPowerLine = true }

        let supply = PowerGrid.computeSupply(for: map, outageActive: false)

        for x in 2 ..< 9 {
            XCTAssertTrue(supply.isSupplied(at: GridPosition(x: x, y: 0)), "expected (\(x),0) to be supplied")
        }
    }

    /// A gap in the power-line run breaks the network — the far side, even
    /// though it's still literally made of power-line tiles, isn't reachable.
    func testADisconnectedPowerLineSegmentIsNotSupplied() {
        var map = CityMap(width: 10, height: 4)
        map.placeBuilding(zone: .powerPlant, origin: GridPosition(x: 0, y: 1)) // covers (0,1)-(2,3)
        map[GridPosition(x: 2, y: 0)].hasPowerLine = true // touches the plant's own footprint cell (2,1)
        map[GridPosition(x: 3, y: 0)].hasPowerLine = true
        // Gap at x=4 (left `.empty`) breaks the network.
        map[GridPosition(x: 5, y: 0)].hasPowerLine = true
        map[GridPosition(x: 6, y: 0)].hasPowerLine = true

        let supply = PowerGrid.computeSupply(for: map, outageActive: false)

        XCTAssertTrue(supply.isSupplied(at: GridPosition(x: 3, y: 0)))
        XCTAssertFalse(supply.isSupplied(at: GridPosition(x: 5, y: 0)))
        XCTAssertFalse(supply.isSupplied(at: GridPosition(x: 6, y: 0)))
    }

    /// Funding is one city-wide dial (`ServiceFunding`'s own design), not
    /// per-building — defunding the power utility takes every plant offline
    /// at once, even over an otherwise perfectly connected network.
    func testAZeroFundedPlantSuppliesNothing() {
        var map = CityMap(width: 6, height: 4)
        map.placeBuilding(zone: .powerPlant, origin: GridPosition(x: 0, y: 1)) // covers (0,1)-(2,3)
        for x in 2 ..< 6 { map[GridPosition(x: x, y: 0)].hasPowerLine = true }
        map.serviceFunding.setLevel(0, for: .powerPlant)

        let supply = PowerGrid.computeSupply(for: map, outageActive: false)

        for x in 2 ..< 6 {
            XCTAssertFalse(supply.isSupplied(at: GridPosition(x: x, y: 0)))
        }
    }

    /// An active outage takes the whole grid down regardless of how well
    /// connected it otherwise is — the same "one dial, city-wide" shape as
    /// zero funding, but modeling a transient event rather than a policy.
    func testAnActiveOutageSuppliesNothing() {
        var map = CityMap(width: 6, height: 4)
        map.placeBuilding(zone: .powerPlant, origin: GridPosition(x: 0, y: 1)) // covers (0,1)-(2,3)
        for x in 2 ..< 6 { map[GridPosition(x: x, y: 0)].hasPowerLine = true }

        let supply = PowerGrid.computeSupply(for: map, outageActive: true)

        for x in 2 ..< 6 {
            XCTAssertFalse(supply.isSupplied(at: GridPosition(x: x, y: 0)))
        }
    }

    // MARK: - hasSupply

    func testHasSupplyIsTrueForABuildingTouchingAConnectedPowerLine() {
        var map = CityMap(width: 8, height: 4)
        map.placeBuilding(zone: .powerPlant, origin: GridPosition(x: 0, y: 1)) // covers (0,1)-(2,3)
        map[GridPosition(x: 2, y: 0)].hasPowerLine = true // touches the plant's own footprint cell (2,1)
        map[GridPosition(x: 3, y: 0)].hasPowerLine = true
        map[GridPosition(x: 4, y: 0)].hasPowerLine = true
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 4, y: 1)) // touches (4,0)
        map.powerSupply = PowerGrid.computeSupply(for: map, outageActive: false)

        XCTAssertTrue(PowerGrid.hasSupply(at: GridPosition(x: 4, y: 1), in: map))
    }

    func testHasSupplyIsFalseWithNoConnectedPowerLineNearby() {
        let map = CityMap(width: 5, height: 5)
        XCTAssertFalse(PowerGrid.hasSupply(at: GridPosition(x: 2, y: 2), in: map))
    }
}
