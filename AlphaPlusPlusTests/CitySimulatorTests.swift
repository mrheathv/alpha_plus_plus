import XCTest
@testable import AlphaPlusPlus

/// Every growable zone (residential/commercial/industrial) is a 2×2
/// footprint (`ZoneType.footprintSize`), so these tests place them with
/// `CityMap.placeBuilding(zone:origin:)` rather than poking a single tile's
/// `.zone` directly — a lone `map[position].zone = .residential` would
/// leave the *other* three cells of that footprint as whatever they
/// defaulted to, which `CitySimulator.advance` would still (correctly, per
/// its own contract) treat as part of the same building. Roads and transit
/// stops stay 1×1, so those are still set directly.
final class CitySimulatorTests: XCTestCase {

    func testRoadAdjacentTileGrowsOneLevelPerAdvance() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0)) // covers (0,0)-(1,1)
        map[GridPosition(x: 2, y: 0)].zone = .road // shares an edge with (1,0), just outside the footprint

        let next = CitySimulator.advance(map)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 1)
    }

    func testTileWithoutRoadAccessDoesNotGrow() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        // No road anywhere on the map.

        let next = CitySimulator.advance(map)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 0)
    }

    /// Locks in "orthogonal only": a road diagonal to the footprint's far
    /// corner touches it only at a point, not an edge, so it must not count
    /// as access.
    func testDiagonalOnlyRoadNeighborDoesNotCount() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0)) // covers (0,0)-(1,1)
        map[GridPosition(x: 2, y: 2)].zone = .road // diagonal to (1,1), the footprint's far corner

        let next = CitySimulator.advance(map)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 0)
    }

    func testDensityStopsGrowingAtMaxDensity() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 0, y: 0)].density = ZoneType.residential.maxDensity
        map[GridPosition(x: 2, y: 0)].zone = .road

        let next = CitySimulator.advance(map)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, ZoneType.residential.maxDensity)
    }

    func testEmptyAndRoadTilesAreUntouchedByAdvance() {
        var map = CityMap(width: 3, height: 3)
        map[GridPosition(x: 1, y: 0)].zone = .road
        // (0,0) stays .empty and is road-adjacent, but .empty has
        // maxDensity 0 — it should never accrue density regardless.

        let next = CitySimulator.advance(map)

        for tile in next.tiles {
            XCTAssertEqual(tile.density, 0)
        }
    }

    func testCommercialAndIndustrialGrowTheSameWayAsResidential() {
        var map = CityMap(width: 6, height: 6)
        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 0, y: 0)) // covers (0,0)-(1,1)
        map[GridPosition(x: 2, y: 0)].zone = .road // touches (1,0)
        map.placeBuilding(zone: .industrial, origin: GridPosition(x: 0, y: 3)) // covers (0,3)-(1,4), nowhere near a road

        let next = CitySimulator.advance(map)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 1)
        XCTAssertEqual(next[GridPosition(x: 0, y: 3)].density, 0)
    }

    // MARK: - Decay

    func testTileDecaysByOneWhenItHasNoRoadAccess() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 0, y: 0)].density = 3
        // No road adjacent — simulates a road that used to be there getting
        // bulldozed out from under an already-developed building.

        let next = CitySimulator.advance(map)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 2)
    }

    func testDecayStopsAtZeroRatherThanGoingNegative() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        // density defaults to 0, no road access.

        let next = CitySimulator.advance(map)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 0)
    }

    /// Sanity check on the growth/decay branch itself: having road access
    /// always means grow (or hold at cap), never decay, no matter what the
    /// building's current density already is.
    func testRoadAdjacentTileGrowsRatherThanDecays() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 0, y: 0)].density = 2
        map[GridPosition(x: 2, y: 0)].zone = .road

        let next = CitySimulator.advance(map)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 3)
    }

    // MARK: - Land value gates the final growth step

    /// A building touching exactly one road and nothing else sits at land
    /// value 0.75, which clears every growth threshold except the last
    /// (0.8) — so it should stall at density 4 despite still having road
    /// access.
    func testTileWithOnlyBareRoadAccessStallsBelowMaxDensity() {
        var map = CityMap(width: 5, height: 5)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0)) // covers (0,0)-(1,1)
        map[GridPosition(x: 0, y: 0)].density = 4
        map[GridPosition(x: 2, y: 0)].zone = .road // touches (1,0)

        let next = CitySimulator.advance(map)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 4)
    }

    /// The same building, but also within reach of a Police Station: land
    /// value climbs to 0.875, clearing the 0.8 threshold for the final level.
    func testTileReachesMaxDensityWhenAlsoNearAService() {
        var map = CityMap(width: 6, height: 6)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0)) // covers (0,0)-(1,1)
        map[GridPosition(x: 0, y: 0)].density = 4
        map[GridPosition(x: 2, y: 0)].zone = .road // touches (1,0)
        map.placeBuilding(zone: .policeStation, origin: GridPosition(x: 0, y: 2)) // covers (0,2)-(1,3), distance 1 from (0,1)

        let next = CitySimulator.advance(map)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 5)
    }

    // MARK: - Transit as an alternate access

    /// A public transit stop alone, with no road anywhere, should be enough
    /// access to start growing — it's a second way to be "connected," not a
    /// lesser one.
    func testPublicTransitAloneProvidesAccessForGrowth() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0)) // covers (0,0)-(1,1)
        map[GridPosition(x: 2, y: 0)].zone = .publicTransit // touches (1,0)

        let next = CitySimulator.advance(map)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 1)
    }

    // MARK: - Highway and subway grant access exactly like their cheaper counterparts

    /// `.highway` is a pricier `.road`, not a different kind of connection —
    /// it must grant access exactly like a plain road does.
    func testHighwayAloneProvidesAccessForGrowth() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 2, y: 0)].zone = .highway

        let next = CitySimulator.advance(map)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 1)
    }

    /// `.subway` is a pricier `.publicTransit`, same relationship.
    func testSubwayAloneProvidesAccessForGrowth() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 2, y: 0)].zone = .subway

        let next = CitySimulator.advance(map)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 1)
    }

    // MARK: - Footprints grow/decay as one unit

    func testAllCellsOfAFootprintShareOneDensityAfterGrowth() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0)) // covers (0,0)-(1,1)
        map[GridPosition(x: 2, y: 0)].zone = .road

        let next = CitySimulator.advance(map)

        for cell in map.footprintCells(origin: GridPosition(x: 0, y: 0), size: 2) {
            XCTAssertEqual(next[cell].density, 1)
        }
    }

    func testAllCellsOfAFootprintShareOneDensityAfterDecay() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 0, y: 0)].density = 3
        // No road: every cell should decay together, not just the anchor.

        let next = CitySimulator.advance(map)

        for cell in map.footprintCells(origin: GridPosition(x: 0, y: 0), size: 2) {
            XCTAssertEqual(next[cell].density, 2)
        }
    }

    /// Access from *any one* corner of a footprint is enough for the whole
    /// building to grow — matches `LandValue`'s own max-not-sum philosophy:
    /// a building is as good as its best-served cell.
    func testAccessFromAnyFootprintCellIsEnoughForTheWholeBuilding() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0)) // covers (0,0)-(1,1)
        map[GridPosition(x: 2, y: 1)].zone = .road // touches (1,1), the *opposite* corner from the anchor

        let next = CitySimulator.advance(map)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 1)
    }
}
