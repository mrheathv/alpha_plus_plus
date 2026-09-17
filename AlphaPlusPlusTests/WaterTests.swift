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
        for x in 0 ..< 5 { map[GridPosition(x: x, y: 0)].hasPipe = true }
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
        for x in 1 ..< 8 { map[GridPosition(x: x, y: 0)].hasPipe = true }

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
        map[GridPosition(x: 1, y: 0)].hasPipe = true // touches the tower's own footprint cell (1,1)
        map[GridPosition(x: 2, y: 0)].hasPipe = true
        // Gap at x=3 (left `.empty`) breaks the network.
        map[GridPosition(x: 4, y: 0)].hasPipe = true
        map[GridPosition(x: 5, y: 0)].hasPipe = true

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
        for x in 1 ..< 5 { map[GridPosition(x: x, y: 0)].hasPipe = true }
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
        map[GridPosition(x: 1, y: 0)].hasPipe = true // touches the tower's own footprint cell (1,1)
        map[GridPosition(x: 2, y: 0)].hasPipe = true
        map[GridPosition(x: 3, y: 0)].hasPipe = true
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 3, y: 1)) // touches (3,0)
        map.waterSupply = Water.computeSupply(for: map)

        XCTAssertTrue(Water.hasSupply(at: GridPosition(x: 3, y: 1), in: map))
    }

    func testHasSupplyIsFalseWithNoConnectedPipeNearby() {
        let map = CityMap(width: 5, height: 5)
        XCTAssertFalse(Water.hasSupply(at: GridPosition(x: 2, y: 2), in: map))
    }
}

/// The rule that used to depend on a footprint being wide enough to be
/// adjacent to itself.
@MainActor
final class ConduitUnderneathTests: XCTestCase {

    /// A conduit laid *under* a building supplies it, the same as one beside
    /// it. Tested on a 1×1 lot specifically: every growable zone is 2×2, so on
    /// those this worked by accident — one footprint cell was adjacent to
    /// another — and the inconsistency could only ever have shown up on
    /// something narrower.
    func testAPipeUnderneathSuppliesEvenAOneTileLot() {
        var map = CityMap(width: 12, height: 8)
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 10, y: 6))
        for x in 0 ... 11 { map[GridPosition(x: x, y: 6)].hasPipe = true }
        // Far enough from the tower that `directSupplyRadius` cannot be what
        // answers this — otherwise the test passes without the pipe mattering.
        let under = GridPosition(x: 0, y: 6)
        map.waterSupply = Water.computeSupply(for: map)
        XCTAssertFalse(map.waterSupply.isDirectlyServed(at: under),
                       "precondition: the tower's own radius already covers this tile")

        XCTAssertTrue(Water.hasSupply(at: under, in: map),
                      "a pipe running under a tile does not supply it")
    }

    func testAPowerLineUnderneathSuppliesEvenAOneTileLot() {
        var map = CityMap(width: 12, height: 8)
        map.placeBuilding(zone: .generator, origin: GridPosition(x: 10, y: 6))
        for x in 0 ... 11 { map[GridPosition(x: x, y: 6)].hasPowerLine = true }
        let under = GridPosition(x: 0, y: 6)
        map.powerSupply = PowerGrid.computeSupply(for: map, outageActive: false)
        XCTAssertFalse(map.powerSupply.isDirectlyServed(at: under),
                       "precondition: the generator's own radius already covers this tile")

        XCTAssertTrue(PowerGrid.hasSupply(at: under, in: map),
                      "a line running under a tile does not supply it")
    }

    /// And an orphaned conduit underneath still supplies nothing — the fix is
    /// about where a live conduit counts, not about making dead ones work.
    func testAnOrphanedPipeUnderneathStillSuppliesNothing() {
        var map = CityMap(width: 12, height: 8)
        for x in 0 ... 5 { map[GridPosition(x: x, y: 6)].hasPipe = true }  // no tower anywhere
        map.waterSupply = Water.computeSupply(for: map)
        XCTAssertFalse(Water.hasSupply(at: GridPosition(x: 2, y: 6), in: map),
                       "a pipe connected to nothing supplied the tile it runs under")
    }
}
