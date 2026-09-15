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

    // MARK: - Tax rate as growth pressure

    /// A perfectly balanced city at the default rate has no tax pressure at
    /// all — the baseline every other balance number was tuned against has to
    /// stay exactly where it was.
    func testTheDefaultTaxRateAppliesNoPressure() {
        var map = CityMap(width: 9, height: 9)
        map.taxRate = 1.0

        let demand = Demand.compute(for: map)

        XCTAssertEqual(demand.residential, 0, accuracy: 0.0001)
        XCTAssertEqual(demand.commercial, 0, accuracy: 0.0001)
        XCTAssertEqual(demand.industrial, 0, accuracy: 0.0001)
    }

    /// A high rate makes the whole city less attractive to build in: all three
    /// types drop, by the same amount.
    func testAHighTaxRateSuppressesEveryTypeEqually() {
        var map = CityMap(width: 9, height: 9)
        map.taxRate = 2.0

        let demand = Demand.compute(for: map)
        let expected = -(2.0 - 1.0) * Demand.taxDemandSensitivity

        XCTAssertEqual(demand.residential, expected, accuracy: 0.0001)
        XCTAssertEqual(demand.commercial, expected, accuracy: 0.0001)
        XCTAssertEqual(demand.industrial, expected, accuracy: 0.0001)
    }

    /// Cutting taxes below the default genuinely attracts growth, rather than
    /// just forfeiting income — that is what makes the low end a strategy.
    func testALowTaxRateRaisesDemand() {
        var map = CityMap(width: 9, height: 9)
        map.taxRate = 0.0

        let demand = Demand.compute(for: map)

        XCTAssertEqual(demand.residential, Demand.taxDemandSensitivity, accuracy: 0.0001)
        XCTAssertGreaterThan(demand.residential, 0)
    }

    /// The bound that keeps the tax slider recoverable: even at the maximum
    /// rate, tax pressure alone must not reach
    /// `CitySimulator.abandonmentDemand`. Reaching that still requires real
    /// oversupply on top. A first attempt at sensitivity 1.0 violated this and
    /// wiped a 3,300-person city to zero, with no way back short of undoing
    /// the slider.
    func testMaximumTaxAloneCannotReachTheAbandonmentThreshold() {
        let maximumRate = 2.0
        let pressureAtMaximum = -(maximumRate - 1.0) * Demand.taxDemandSensitivity

        XCTAssertGreaterThan(
            pressureAtMaximum, CitySimulator.abandonmentDemand,
            "tax alone can push a city into irreversible abandonment"
        )
    }

    /// `businessTaxBreak` is what buys commercial an exemption from the
    /// city-wide tax drag — which is exactly what an ordinance of that name
    /// ought to do.
    func testTheBusinessTaxBreakOffsetsTaxPressureForCommercialOnly() {
        var map = CityMap(width: 9, height: 9)
        map.taxRate = 1.5
        map.ordinances.businessTaxBreak = true

        let demand = Demand.compute(for: map)

        XCTAssertGreaterThan(demand.commercial, demand.industrial)
        XCTAssertEqual(
            demand.commercial - demand.industrial,
            Demand.businessTaxBreakBoost,
            accuracy: 0.0001
        )
    }

    // MARK: - Demand scales with the city

    /// The same *proportional* imbalance must read as the same demand whether
    /// the city is small or large.
    ///
    /// Demand used to be measured against a flat scale of 30, so any imbalance
    /// past 30 people pinned it at ±1 — in a city of thousands it was a
    /// boolean rather than a gradient, and anything nudging it by a fraction
    /// of a point was swamped.
    func testDemandIsProportionalRatherThanSaturatedInALargeCity() {
        // A big city with a modest 10% surplus of jobs over people should read
        // as mild positive residential demand, not a pinned +1.
        // 15 residential lots at full density = 300 people; 22 commercial =
        // 330 jobs. A 30-job surplus against a 630-strong city: ~10% out of
        // balance, which under the old flat scale of 30 would have pinned
        // demand at exactly +1.0.
        var big = CityMap(width: 40, height: 40)
        placeBalancedCity(in: &big, residentialLots: 15, commercialLots: 22)

        let demand = Demand.compute(for: big)

        XCTAssertGreaterThan(demand.residential, 0, "a job surplus should want more housing")
        XCTAssertLessThan(
            demand.residential, 1.0,
            "demand is saturated at its maximum from an ordinary imbalance — it is a boolean, not a gradient"
        )
    }

    /// Fills `map` with fully-grown lots along road rows, for demand fixtures
    /// that need a city big enough for proportional scaling to matter.
    private func placeBalancedCity(in map: inout CityMap, residentialLots: Int, commercialLots: Int) {
        for x in 0 ..< map.width {
            map.placeBuilding(zone: .road, origin: GridPosition(x: x, y: 0))
        }
        var placed = 0
        var x = 0
        var y = 1
        func place(_ zone: ZoneType, count: Int) {
            var remaining = count
            while remaining > 0, y + 1 < map.height {
                map.placeBuilding(zone: zone, origin: GridPosition(x: x, y: y))
                for cell in map.footprintCells(origin: GridPosition(x: x, y: y), size: 2) {
                    map[cell].density = 5
                }
                remaining -= 1
                placed += 1
                x += 2
                if x + 1 >= map.width { x = 0; y += 3 }
            }
        }
        place(.residential, count: residentialLots)
        place(.commercial, count: commercialLots)
    }
}
