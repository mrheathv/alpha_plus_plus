import XCTest
@testable import AlphaPlusPlus

final class LandValueTests: XCTestCase {

    func testValueIsZeroWithNoRoadsAnywhereOnTheMap() {
        let map = CityMap(width: 5, height: 5)
        XCTAssertEqual(LandValue.value(at: GridPosition(x: 2, y: 2), in: map), 0)
    }

    func testValueIsMaximumAtTheRoadItself() {
        var map = CityMap(width: 5, height: 5)
        let roadPosition = GridPosition(x: 2, y: 2)
        map[roadPosition].zone = .road

        XCTAssertEqual(LandValue.value(at: roadPosition, in: map), 1.0)
    }

    func testValueFallsOffLinearlyWithDistance() {
        var map = CityMap(width: 10, height: 10)
        map[GridPosition(x: 0, y: 0)].zone = .road

        // roadFalloffDistance is 4: value = 1 - distance/4.
        XCTAssertEqual(LandValue.value(at: GridPosition(x: 1, y: 0), in: map), 0.75, accuracy: 0.0001)
        XCTAssertEqual(LandValue.value(at: GridPosition(x: 2, y: 0), in: map), 0.5, accuracy: 0.0001)
        XCTAssertEqual(LandValue.value(at: GridPosition(x: 4, y: 0), in: map), 0.0, accuracy: 0.0001)
    }

    func testValueNeverGoesNegativeBeyondFalloffDistance() {
        var map = CityMap(width: 10, height: 10)
        map[GridPosition(x: 0, y: 0)].zone = .road

        XCTAssertEqual(LandValue.value(at: GridPosition(x: 9, y: 9), in: map), 0)
    }

    func testValueUsesTheNearestRoadWhenMultipleExist() {
        var map = CityMap(width: 10, height: 10)
        map[GridPosition(x: 0, y: 0)].zone = .road // distance 5 from (5,0)
        map[GridPosition(x: 5, y: 1)].zone = .road // distance 1 from (5,0)

        XCTAssertEqual(LandValue.value(at: GridPosition(x: 5, y: 0), in: map), 0.75, accuracy: 0.0001)
    }

    // MARK: - Service coverage (police/fire)

    func testPoliceStationRaisesNearbyLandValueEvenFarFromAnyRoad() {
        var map = CityMap(width: 20, height: 20)
        map[GridPosition(x: 10, y: 10)].zone = .policeStation
        // No roads anywhere — the station alone should still contribute.

        XCTAssertEqual(LandValue.value(at: GridPosition(x: 10, y: 10), in: map), 1.0)
    }

    func testServiceCoverageFallsOffOverAWiderRadiusThanRoadFrontage() {
        var map = CityMap(width: 20, height: 20)
        map[GridPosition(x: 10, y: 10)].zone = .fireStation

        // serviceFalloffDistance is 8: value = 1 - distance/8.
        XCTAssertEqual(LandValue.value(at: GridPosition(x: 14, y: 10), in: map), 0.5, accuracy: 0.0001)
        XCTAssertEqual(LandValue.value(at: GridPosition(x: 18, y: 10), in: map), 0.0, accuracy: 0.0001)
    }

    /// Locks in the `max`-not-sum combination rule: sitting inside overlapping
    /// road and service coverage shouldn't add up to more than the single
    /// best-covering amenity already gives.
    func testOverlappingRoadAndServiceCoverageTakesTheBetterOneNotTheSum() {
        var map = CityMap(width: 20, height: 20)
        let position = GridPosition(x: 10, y: 10)
        map[GridPosition(x: 11, y: 10)].zone = .road // distance 1 -> road value 0.75
        map[GridPosition(x: 10, y: 12)].zone = .policeStation // distance 2 -> service value 0.75

        XCTAssertEqual(LandValue.value(at: position, in: map), 0.75, accuracy: 0.0001)
    }

    // MARK: - Transit

    func testPublicTransitContributesLandValueWithItsOwnFalloff() {
        var map = CityMap(width: 20, height: 20)
        map[GridPosition(x: 10, y: 10)].zone = .publicTransit

        // transitFalloffDistance is 6: value = 1 - distance/6.
        XCTAssertEqual(LandValue.value(at: GridPosition(x: 13, y: 10), in: map), 0.5, accuracy: 0.0001)
        XCTAssertEqual(LandValue.value(at: GridPosition(x: 16, y: 10), in: map), 0.0, accuracy: 0.0001)
    }

    // MARK: - Stadium (3×3)

    func testStadiumContributesLandValueOverAWiderRadiusThanAService() {
        var map = CityMap(width: 20, height: 20)
        map.placeBuilding(zone: .stadium, origin: GridPosition(x: 10, y: 10)) // covers (10,10)-(12,12)

        // stadiumFalloffDistance is 10: value = 1 - distance/10, measured
        // from the nearest cell of the 3x3 footprint (12,10 or 10,12).
        XCTAssertEqual(LandValue.value(at: GridPosition(x: 17, y: 10), in: map), 0.5, accuracy: 0.0001)
        XCTAssertEqual(LandValue.value(at: GridPosition(x: 22, y: 10), in: map), 0.0, accuracy: 0.0001)
    }

    // MARK: - Power plant (the first negative influence)

    /// Unlike every other service in this file, a power plant *lowers*
    /// nearby land value — checked here by comparing the same location
    /// with and without one nearby, holding everything else fixed.
    func testPowerPlantLowersLandValueThatWouldOtherwiseBeHigher() {
        var map = CityMap(width: 20, height: 20)
        let position = GridPosition(x: 10, y: 10)
        map[GridPosition(x: 11, y: 10)].zone = .road // distance 1 -> road value 0.75
        XCTAssertEqual(LandValue.value(at: position, in: map), 0.75, accuracy: 0.0001) // baseline, sanity check

        map.placeBuilding(zone: .powerPlant, origin: GridPosition(x: 10, y: 12)) // nearest cell (10,12), distance 2 from position

        // powerPlantPenaltyDistance is 8, strength is 0.5:
        // penalty = (1 - 2/8) * 0.5 = 0.375. Expected: 0.75 - 0.375 = 0.375.
        XCTAssertEqual(LandValue.value(at: position, in: map), 0.375, accuracy: 0.0001)
    }

    func testPowerPlantPenaltyFallsOffWithDistance() {
        var map = CityMap(width: 20, height: 20)
        let position = GridPosition(x: 10, y: 10)
        map[position].zone = .road // land value exactly 1.0 at the road itself
        map.placeBuilding(zone: .powerPlant, origin: GridPosition(x: 10, y: 14)) // nearest cell (10,14), distance 4

        // penalty = (1 - 4/8) * 0.5 = 0.25. Expected: 1.0 - 0.25 = 0.75.
        XCTAssertEqual(LandValue.value(at: position, in: map), 0.75, accuracy: 0.0001)
    }

    /// With nothing else nearby to give a tile any positive value, the
    /// power plant's penalty must floor at 0 rather than going negative —
    /// "worthless" is as bad as this model represents.
    func testPowerPlantPenaltyFloorsAtZeroRatherThanGoingNegative() {
        var map = CityMap(width: 20, height: 20)
        map.placeBuilding(zone: .powerPlant, origin: GridPosition(x: 10, y: 10))

        XCTAssertEqual(LandValue.value(at: GridPosition(x: 10, y: 10), in: map), 0)
    }
}
