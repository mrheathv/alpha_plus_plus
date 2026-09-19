import XCTest
@testable import AlphaPlusPlus

/// How far a civic service reaches — the one number behind "do I have enough
/// police stations", and, until it was separated out, the same number as how
/// far a station projects land value.
@MainActor
final class ServiceCoverageTests: XCTestCase {

    private func cityWithAStation(_ service: ZoneType = .policeStation) -> CityMap {
        var map = CityMap(width: 48, height: 48)
        map.placeBuilding(zone: service, origin: GridPosition(x: 24, y: 24))
        return map
    }

    // MARK: - The shape of a catchment

    func testAStationReachesItsRadiusAndNotOneTileFurther() {
        let map = cityWithAStation()
        let station = GridPosition(x: 24, y: 24)
        let radius = ServiceCoverage.radius

        // Straight out along one axis from the station's own footprint. A
        // station is 2×2, so distance is measured from its nearest cell.
        for step in 0 ... radius {
            let cell = GridPosition(x: station.x, y: station.y - step)
            XCTAssertTrue(ServiceCoverage.serves([cell], .policeStation, in: map),
                          "\(step) tiles out is inside the radius and reads as unserved")
        }
        let justPast = GridPosition(x: station.x, y: station.y - radius - 1)
        XCTAssertFalse(ServiceCoverage.serves([justPast], .policeStation, in: map),
                       "the catchment reaches further than its own radius")
    }

    /// The reach is Manhattan, like every other coverage question in this
    /// game, so a catchment is a diamond rather than a square — the corners
    /// of the bounding box are *not* covered.
    func testTheCatchmentIsADiamond() {
        let map = cityWithAStation()
        let corner = GridPosition(x: 24 + ServiceCoverage.radius, y: 24 + ServiceCoverage.radius)
        XCTAssertFalse(ServiceCoverage.serves([corner], .policeStation, in: map),
                       "the catchment is square, not a diamond")
    }

    /// **The headline the change was made for.** Reported from play as the
    /// radius being "a big problem": at the 8 tiles this worked out to
    /// before, one station covered 145 tiles and a 64×64 map wanted 28 police
    /// stations *and* 28 fire stations at perfect packing — which is not a
    /// decision, it is an obligation.
    ///
    /// Reported rather than only asserted, so the number is visible in a
    /// build log before it is a complaint from a play session. The bound is
    /// deliberately loose at both ends: the point is that covering a large
    /// city is a handful of buildings rather than dozens, and that it still
    /// takes more than one.
    func testHowManyStationsALargeCityNeeds() {
        let radius = ServiceCoverage.radius
        let perStation = 2 * radius * radius + 2 * radius + 1
        for side in [24, 40, 64] {
            let stations = Double(side * side) / Double(perStation)
            print("\(side)×\(side): one station covers \(perStation) tiles, "
                  + String(format: "so the map wants ~%.1f of each service", stations))
        }
        let large = Double(64 * 64) / Double(perStation)
        XCTAssertGreaterThan(large, 3,
                             "one station nearly covers a 64×64 map, so siting them is not a decision")
        XCTAssertLessThan(large, 16,
                          "a 64×64 map needs so many stations that covering it is wallpaper, not a choice")
    }

    // MARK: - Funding

    /// Funding used to multiply into the value and then meet a fixed 0.3
    /// threshold, which made it a cliff rather than a dial: half funding cut
    /// the radius from 8 to 4 — a 72% loss of *area* — and anything at or
    /// below 0.3 protected nothing anywhere, including the station's own lot.
    func testFundingScalesTheRadiusSmoothly() {
        var map = cityWithAStation()
        let full = ServiceCoverage.reach(of: .policeStation, in: map)

        map.serviceFunding.setLevel(0.5, for: .policeStation)
        let half = ServiceCoverage.reach(of: .policeStation, in: map)
        XCTAssertEqual(half, full / 2, accuracy: 0.001,
                       "half the funding does not buy half the reach")

        // The old cliff: at this level the service used to do nothing at all.
        map.serviceFunding.setLevel(0.3, for: .policeStation)
        let station = GridPosition(x: 24, y: 24)
        XCTAssertTrue(ServiceCoverage.serves([station], .policeStation, in: map),
                      "a funded station does not even cover its own lot")
    }

    func testAnUnfundedServiceCoversNothingAtAll() {
        var map = cityWithAStation()
        map.serviceFunding.setLevel(0, for: .policeStation)
        XCTAssertFalse(ServiceCoverage.serves([GridPosition(x: 24, y: 24)], .policeStation, in: map),
                       "a service nobody pays for is still protecting its own lot")
    }

    // MARK: - The gradient agrees with the rule

    /// The Crime and Fire Risk views paint the ground from `strength`, and a
    /// player uses that glow to decide where the next station goes. It was
    /// painted from the *land-value* falloff, which reaches half again as far
    /// as protection does — so the outer third of the glow promised cover
    /// that was not there.
    func testTheGradientIsPositiveExactlyWhereTheServiceReaches() {
        let map = cityWithAStation()
        for step in 0 ... ServiceCoverage.radius + 3 {
            let cell = GridPosition(x: 24, y: 24 - step)
            let serves = ServiceCoverage.serves([cell], .policeStation, in: map)
            let strength = ServiceCoverage.strength(at: cell, from: .policeStation, in: map)
            XCTAssertEqual(serves, strength > 0,
                           "at \(step) tiles the overlay and the rule disagree "
                           + "(serves: \(serves), strength: \(strength))")
        }
    }

    /// Land value is a separate question now, and has to stay one: tuning how
    /// desirable a station makes its neighbourhood must not silently move
    /// every hazard in the game, and vice versa.
    func testReachIsNotTheLandValueFalloff() {
        XCTAssertNotEqual(ServiceCoverage.radius, LandValue.serviceFalloffDistance,
                          "reach and the land-value falloff have collapsed back into one number")
    }
}
