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

    // MARK: - Service funding scales coverage strength

    /// The one place underfunding a service actually does anything: a
    /// station funded at half strength should project half its usual land
    /// value, not the same falloff a fully-funded station gives.
    func testUnderfundedServiceProjectsProportionallyLessLandValue() {
        var map = CityMap(width: 20, height: 20)
        map[GridPosition(x: 10, y: 10)].zone = .fireStation
        map.serviceFunding.setLevel(0.5, for: .fireStation)

        // Fully funded, distance 4 on an 8-tile falloff would be 0.5; at
        // half funding it should be half of that.
        XCTAssertEqual(LandValue.value(at: GridPosition(x: 14, y: 10), in: map), 0.25, accuracy: 0.0001)
    }

    /// Funding above 1.0 is a real lever too, not clamped — a station
    /// funded above the norm should out-project its usual falloff.
    func testOverfundedServiceProjectsProportionallyMoreLandValue() {
        var map = CityMap(width: 20, height: 20)
        map[GridPosition(x: 10, y: 10)].zone = .policeStation
        map.serviceFunding.setLevel(1.5, for: .policeStation)

        XCTAssertEqual(LandValue.value(at: GridPosition(x: 10, y: 10), in: map), 1.5, accuracy: 0.0001)
    }

    /// Funding is per-service: underfunding Fire must never touch Police's
    /// contribution, even measured at the exact same tile.
    func testFundingOneServiceDoesNotAffectAnother() {
        var map = CityMap(width: 20, height: 20)
        let position = GridPosition(x: 10, y: 10)
        map[position].zone = .policeStation
        map.serviceFunding.setLevel(0.2, for: .fireStation) // unrelated service, starved

        XCTAssertEqual(LandValue.value(at: position, in: map), 1.0, accuracy: 0.0001)
    }

    /// Road frontage isn't a fundable service — `ServiceFunding.level(for:)`
    /// always reports 1.0 for `.road` — so it must stay unaffected no
    /// matter how every actual service is funded.
    func testRoadValueIsUnaffectedByServiceFundingLevels() {
        var map = CityMap(width: 20, height: 20)
        map[GridPosition(x: 0, y: 0)].zone = .road
        map.serviceFunding.setLevel(0.1, for: .policeStation)
        map.serviceFunding.setLevel(0.1, for: .fireStation)

        XCTAssertEqual(LandValue.value(at: GridPosition(x: 1, y: 0), in: map), 0.75, accuracy: 0.0001)
    }

    /// The congestion-dampening feedback loop applies through a `.highway`
    /// neighbor exactly like a `.road` neighbor — it's the same frontage
    /// mechanic, just on a higher-capacity road.
    func testCongestionOnAnAdjacentHighwayDampensItsOwnFrontageValue() {
        var map = CityMap(width: 5, height: 5)
        let position = GridPosition(x: 0, y: 0)
        let highwayPosition = GridPosition(x: 1, y: 0)
        map[highwayPosition].zone = .highway
        map[GridPosition(x: 2, y: 0)].zone = .commercial
        map[GridPosition(x: 2, y: 0)].density = 5 // loads the highway with congestion

        let dampenedValue = LandValue.value(at: position, in: map)

        XCTAssertLessThan(dampenedValue, 0.75) // below the undampened frontage value
        XCTAssertGreaterThan(dampenedValue, 0) // but not wiped out
    }

    // MARK: - Congestion dampens road value, but not enough to defeat growth

    /// Caught by hands-on testing, not a unit test: a zone with only bare
    /// road frontage sits at land value 0.75 (`roadFalloffDistance`), just
    /// 0.10 above the 0.65 `CitySimulator` requires for density level 4. At
    /// the old `congestionPenalty` of 0.4, *ordinary* nearby development —
    /// just another building sharing the same road, nothing pathological —
    /// pushed congestion past ~30% and erased that whole margin, so a zone
    /// with nothing wrong with it would stall one level short of the ceiling
    /// the moment its street got busy. This pins the fix: moderate
    /// congestion (50%, here from one fully-grown neighbor sharing the same
    /// road tile) must still leave bare road frontage clearing 0.65.
    func testBareRoadFrontageClearsTheLevel4ThresholdEvenUnderModerateNearbyCongestion() {
        var map = CityMap(width: 5, height: 5)
        let position = GridPosition(x: 1, y: 0)
        let roadPosition = GridPosition(x: 2, y: 0)
        map[position].zone = .residential
        map[position].density = 5 // this zone's own share of its road's load
        map[roadPosition].zone = .road
        map[GridPosition(x: 3, y: 0)].zone = .commercial
        map[GridPosition(x: 3, y: 0)].density = 5 // a neighbor sharing the same road tile

        // (5 + 5) / 20 = 0.5 congestion: busy, but nowhere near gridlock.
        XCTAssertEqual(Traffic.congestion(at: roadPosition, in: map), 0.5, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(LandValue.value(at: position, in: map), 0.65)
    }

    /// The flip side of the fix: congestion is still a real, felt penalty —
    /// a road at true gridlock should cap a zone below level 4, not be
    /// softened into meaninglessness.
    func testGridlockedRoadFrontageFallsBelowTheLevel4Threshold() {
        var map = CityMap(width: 5, height: 5)
        let position = GridPosition(x: 1, y: 0)
        let roadPosition = GridPosition(x: 2, y: 0)
        map[position].zone = .residential
        map[position].density = 5
        map[roadPosition].zone = .road
        map[GridPosition(x: 3, y: 0)].zone = .commercial
        map[GridPosition(x: 3, y: 0)].density = 5
        map[GridPosition(x: 2, y: 1)].zone = .industrial
        map[GridPosition(x: 2, y: 1)].density = 5

        // 3 fully-grown neighbors is as congested as this edge road tile can
        // get (a 4th neighbor would be off the map): (5+5+5)/20 = 0.75.
        XCTAssertEqual(Traffic.congestion(at: roadPosition, in: map), 0.75, accuracy: 0.0001)
        XCTAssertLessThan(LandValue.value(at: position, in: map), 0.65)
    }

    // MARK: - Highway (a pricier, higher-capacity road)

    /// Same falloff distance, same formula — a highway one tile away
    /// should value a tile identically to a plain road one tile away.
    func testHighwayContributesLandValueWithTheSameFalloffAsARoad() {
        var map = CityMap(width: 10, height: 10)
        map[GridPosition(x: 0, y: 0)].zone = .highway

        XCTAssertEqual(LandValue.value(at: GridPosition(x: 1, y: 0), in: map), 0.75, accuracy: 0.0001)
    }

    /// Whichever of a road or a highway is actually closer should win —
    /// mirroring `testValueUsesTheNearestRoadWhenMultipleExist`, just with
    /// the two zone types mixed instead of two roads.
    func testValueUsesWhicheverOfRoadOrHighwayIsNearer() {
        var map = CityMap(width: 10, height: 10)
        map[GridPosition(x: 0, y: 0)].zone = .road // distance 5 from (5,0)
        map[GridPosition(x: 5, y: 1)].zone = .highway // distance 1 from (5,0)

        XCTAssertEqual(LandValue.value(at: GridPosition(x: 5, y: 0), in: map), 0.75, accuracy: 0.0001)
    }

    // MARK: - Subway (a pricier, wider-reaching transit stop)

    func testSubwayContributesLandValueOverAWiderRadiusThanPublicTransit() {
        var map = CityMap(width: 20, height: 20)
        map[GridPosition(x: 10, y: 10)].zone = .subway

        // subwayFalloffDistance is 9: value = 1 - distance/9.
        XCTAssertEqual(LandValue.value(at: GridPosition(x: 13, y: 10), in: map), 1 - 3.0 / 9.0, accuracy: 0.0001)

        // Distance 7 sits *beyond* transitFalloffDistance (6) -- a plain
        // publicTransit stop this far away would already contribute 0 --
        // but is still within subwayFalloffDistance (9), the whole point
        // of paying more for a subway.
        XCTAssertGreaterThan(LandValue.value(at: GridPosition(x: 17, y: 10), in: map), 0)
        XCTAssertLessThan(LandValue.transitFalloffDistance, 7)
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
