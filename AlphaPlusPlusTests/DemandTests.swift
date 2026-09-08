import XCTest
@testable import AlphaPlusPlus

final class DemandTests: XCTestCase {

    func testBalancedCityHasZeroDemandForEveryType() {
        // No buildings at all: population 0, jobs 0 -- perfectly balanced,
        // if uninteresting.
        let map = CityMap(width: 5, height: 5)

        let demand = Demand.compute(for: map)

        XCTAssertEqual(demand.residential, 0, accuracy: 0.0001)
        XCTAssertEqual(demand.commercial, 0, accuracy: 0.0001)
        XCTAssertEqual(demand.industrial, 0, accuracy: 0.0001)
    }

    /// More jobs than people should pull residential demand positive --
    /// the city has openings nobody's around to fill.
    func testUnfilledJobsRaiseResidentialDemand() {
        var map = CityMap(width: 5, height: 5)
        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 0, y: 0)].density = 5 // covers (0,0)-(1,1): 5 * 3 = 15 jobs, 0 population

        let demand = Demand.compute(for: map)

        XCTAssertGreaterThan(demand.residential, 0)
    }

    /// More people than jobs should pull Commercial/Industrial demand
    /// positive (and equal to each other, in this v1 with no split yet)
    /// -- a workforce with nowhere to work.
    func testJobSeekersRaiseCommercialAndIndustrialDemandEqually() {
        var map = CityMap(width: 5, height: 5)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 0, y: 0)].density = 5 // 5 * 4 = 20 population, 0 jobs

        let demand = Demand.compute(for: map)

        XCTAssertGreaterThan(demand.commercial, 0)
        XCTAssertEqual(demand.commercial, demand.industrial, accuracy: 0.0001)
        // Residential itself should read as oversupplied, not in-demand.
        XCTAssertLessThan(demand.residential, 0)
    }

    /// Demand clamps at the extremes rather than growing without bound --
    /// a city that's wildly out of balance should read the same as one
    /// that's just somewhat out of balance past a point, not an
    /// ever-larger number nothing else interprets differently.
    func testDemandClampsAtPlusOrMinusOne() {
        var map = CityMap(width: 20, height: 20)
        var x = 0
        while x < 18 {
            map.placeBuilding(zone: .commercial, origin: GridPosition(x: x, y: 0))
            map[GridPosition(x: x, y: 0)].density = 5
            x += 2
        }
        // A wall of fully-grown commercial with zero residential: jobs
        // massively outnumber population.

        let demand = Demand.compute(for: map)

        XCTAssertEqual(demand.residential, 1.0, accuracy: 0.0001)
        XCTAssertEqual(demand.commercial, -1.0, accuracy: 0.0001)
        XCTAssertEqual(demand.industrial, -1.0, accuracy: 0.0001)
    }

    func testCityDemandValueIsZeroForNonGrowableZones() {
        let demand = CityDemand(residential: 0.5, commercial: -0.5, industrial: 0.2)

        XCTAssertEqual(demand.value(for: .road), 0)
        XCTAssertEqual(demand.value(for: .policeStation), 0)
        XCTAssertEqual(demand.value(for: .empty), 0)
    }

    func testCityDemandValueReadsTheMatchingField() {
        let demand = CityDemand(residential: 0.5, commercial: -0.25, industrial: 0.1)

        XCTAssertEqual(demand.value(for: .residential), 0.5, accuracy: 0.0001)
        XCTAssertEqual(demand.value(for: .commercial), -0.25, accuracy: 0.0001)
        XCTAssertEqual(demand.value(for: .industrial), 0.1, accuracy: 0.0001)
    }

    // MARK: - Ordinances.businessTaxBreak

    /// The one place Commercial and Industrial demand actually get told
    /// apart (see this file's own top doc comment on why they otherwise
    /// don't yet): an active tax break nudges Commercial up by
    /// `businessTaxBreakBoost` without touching Industrial or Residential
    /// at all.
    func testBusinessTaxBreakBoostsCommercialDemandOnly() {
        var map = CityMap(width: 5, height: 5)
        map.ordinances.businessTaxBreak = true

        let demand = Demand.compute(for: map)

        XCTAssertEqual(demand.commercial, Demand.businessTaxBreakBoost, accuracy: 0.0001)
        XCTAssertEqual(demand.industrial, 0, accuracy: 0.0001)
        XCTAssertEqual(demand.residential, 0, accuracy: 0.0001)
    }

    /// The boost still respects `CityDemand`'s own ±1 range -- a city
    /// already at maximum commercial demand doesn't read as "even more
    /// than maximum" just because the ordinance is also active.
    func testBusinessTaxBreakBoostClampsAtOne() {
        var map = CityMap(width: 20, height: 20)
        var x = 0
        while x < 18 {
            map.placeBuilding(zone: .residential, origin: GridPosition(x: x, y: 0))
            map[GridPosition(x: x, y: 0)].density = 5
            x += 2
        }
        // A wall of fully-grown residential with zero jobs already pins
        // commercial demand at +1.0 on its own, same setup
        // `testDemandClampsAtPlusOrMinusOne` uses for the opposite side.
        map.ordinances.businessTaxBreak = true

        let demand = Demand.compute(for: map)

        XCTAssertEqual(demand.commercial, 1.0, accuracy: 0.0001)
    }

    /// A fresh `CityMap` (or one built directly in a test, never advanced)
    /// reads as perfectly balanced everywhere -- same "nothing computed
    /// yet reads as neutral/empty" default `TrafficLoad`/`WaterSupply`
    /// already use for their own uncomputed state.
    func testCityMapDefaultsToBalancedDemand() {
        let map = CityMap(width: 5, height: 5)

        XCTAssertEqual(map.cityDemand, CityDemand())
    }
}
