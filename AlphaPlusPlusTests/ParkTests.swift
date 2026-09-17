import XCTest
@testable import AlphaPlusPlus

/// Parks — the one thing in the game whose only job is to make a place nicer.
@MainActor
final class ParkTests: XCTestCase {

    /// A lot with road frontage and nothing else: the baseline every test here
    /// measures against, and the case parks exist to improve.
    private func street(width: Int = 24, height: Int = 24) -> CityMap {
        var map = CityMap(width: width, height: height)
        for x in 0 ..< width { map[GridPosition(x: x, y: 2)].zone = .road }
        return map
    }

    private let lot = GridPosition(x: 4, y: 1)

    private func value(_ map: CityMap, at position: GridPosition? = nil) -> Double {
        LandValue.value(at: position ?? lot, in: map)
    }

    // MARK: - What a park does

    func testAParkMakesTheStreetAroundItMoreDesirable() {
        var map = street()
        let before = value(map)
        map.placeBuilding(zone: .park, origin: GridPosition(x: 4, y: 0))
        XCTAssertGreaterThan(value(map), before, "a park next door changed nothing")
    }

    /// **The point of parks.** Every other positive goes through a `max` —
    /// "how good is the best thing near you" — so a second amenity beside a
    /// police station contributes nothing at all. A park is not competing to
    /// be the best thing nearby; it makes an already-decent block better.
    func testAParkAddsToAnAmenityRatherThanCompetingWithIt() {
        var serviced = street()
        serviced.placeBuilding(zone: .policeStation, origin: GridPosition(x: 8, y: 0))
        let withStation = value(serviced)

        var both = serviced
        both.placeBuilding(zone: .park, origin: GridPosition(x: 4, y: 0))
        XCTAssertGreaterThan(value(both), withStation,
                             "a park beside a police station added nothing — it is competing "
                             + "in the `max` instead of stacking on top of it")
    }

    /// And the gate it exists to help with: plain road frontage tops out below
    /// what the top density tier asks, and a park is what carries an ordinary
    /// street over that line.
    func testAParkCarriesAPlainStreetOverTheTopTiersLandValueGate() {
        var map = street()
        let required = CitySimulator.requiredLandValue(toReach: ZoneType.residential.maxDensity)
        XCTAssertLessThan(value(map), required,
                          "precondition: plain frontage already clears the top gate, so there "
                          + "is nothing for a park to fix")

        map.placeBuilding(zone: .park, origin: GridPosition(x: 4, y: 0))
        XCTAssertGreaterThanOrEqual(value(map), required,
                                    "a park does not lift an ordinary street to the top tier")
    }

    /// Two parks side by side are one park's worth of desirability.
    /// `falloffValue` measures the distance to the *nearest*, which is what
    /// stops a wall of parks being the dominant strategy.
    func testParksDoNotStackWithEachOther() {
        var one = street()
        one.placeBuilding(zone: .park, origin: GridPosition(x: 4, y: 0))
        let single = value(one)

        var many = one
        many.placeBuilding(zone: .park, origin: GridPosition(x: 5, y: 0))
        many.placeBuilding(zone: .park, origin: GridPosition(x: 3, y: 0))
        XCTAssertEqual(value(many), single, accuracy: 1e-9,
                       "parks stack, so paving the map in them is the winning move")
    }

    /// A park serves the streets around it, not a district — which is what
    /// makes covering a neighbourhood take several of them, and turns "make
    /// this area desirable" into a decision about land rather than a purchase.
    func testAParksEffectFadesWithDistanceAndThenStops() {
        var map = street(width: 40, height: 40)
        for x in 0 ..< 40 { map[GridPosition(x: x, y: 2)].zone = .road }
        map.placeBuilding(zone: .park, origin: GridPosition(x: 0, y: 0))

        let near = value(map, at: GridPosition(x: 1, y: 1))
        let mid = value(map, at: GridPosition(x: 3, y: 1))
        XCTAssertGreaterThan(near, mid, "a park's effect does not fade with distance")

        // Well past the falloff, the park contributes nothing and the lot is
        // back to bare road frontage.
        let far = GridPosition(x: LandValue.parkFalloffDistance + 6, y: 1)
        var without = map
        without.placeBuilding(zone: .empty, origin: GridPosition(x: 0, y: 0))
        XCTAssertEqual(value(map, at: far), value(without, at: far), accuracy: 1e-9,
                       "a park is still reaching a lot well outside its falloff")
    }

    /// **A park may not add more than a park's worth**, whatever else is
    /// nearby.
    ///
    /// Written this way rather than as "land value stays under 1" — which is
    /// what it said first, and which was wrong. `LandValue` is deliberately
    /// *not* clamped at the top: `falloffValue` scales with funding, and
    /// `testOverfundedServiceProjectsProportionallyMoreLandValue` pins an
    /// over-funded station out-projecting its usual falloff as a real lever.
    /// Adding parks nearly took that away as a side effect. The invariant that
    /// actually matters is that a park's contribution is bounded by its own
    /// constant.
    func testAParkNeverAddsMoreThanItsOwnBonus() {
        var bare = street()
        bare.placeBuilding(zone: .policeStation, origin: GridPosition(x: 6, y: 0))
        bare.placeBuilding(zone: .school, origin: GridPosition(x: 12, y: 0))
        bare.placeBuilding(zone: .stadium, origin: GridPosition(x: 18, y: 0))

        var planted = bare
        for x in stride(from: 0, to: 24, by: 2) {
            planted.placeBuilding(zone: .park, origin: GridPosition(x: x, y: 0))
        }

        for x in 0 ..< bare.width {
            let position = GridPosition(x: x, y: 1)
            let gain = value(planted, at: position) - value(bare, at: position)
            XCTAssertLessThanOrEqual(gain, LandValue.parkBonus + 1e-9,
                                     "parks added more than `parkBonus` at x=\(x)")
            XCTAssertGreaterThanOrEqual(value(planted, at: position), 0)
        }
    }

    // MARK: - What a park is

    /// Available from tick one. The land-value gate bites from density 2,
    /// which a city reaches long before any service unlocks — holding parks
    /// back would repeat the mistake the starter utilities exist to fix.
    func testParksAreAvailableFromTheStart() {
        XCTAssertEqual(Unlocks.requiredPopulation(for: .park), 0)
        XCTAssertTrue(Unlocks.isUnlocked(.park, peakPopulation: 0))
    }

    /// 1×1, unlike every other civic building. A park's cost is the ground it
    /// sits on, and that only reads as a decision if one fits between blocks.
    func testAParkIsASingleTile() {
        XCTAssertEqual(ZoneType.park.footprintSize, 1)
        XCTAssertEqual(ZoneType.park.maxDensity, 0)
        XCTAssertEqual(ZoneType.park.populationPerDensityLevel, 0)
        XCTAssertEqual(ZoneType.park.jobsPerDensityLevel, 0)
    }

    /// Cheap to buy and cheap to keep, but not free to keep — a city that
    /// paves itself in parks should feel it.
    func testAParkIsCheapToBuildAndCostsSomethingToRun() {
        XCTAssertLessThan(ZoneType.park.placementCost, ZoneType.policeStation.placementCost)
        XCTAssertGreaterThan(ZoneType.park.upkeepCost, 0, "parks are free to run")
        XCTAssertLessThan(ZoneType.park.upkeepCost, ZoneType.policeStation.upkeepCost)
    }

    /// It is a place, not a service: nothing about coverage, capacity or
    /// hazards should have grown an opinion about it.
    func testAParkIsNotAServiceInDisguise() {
        var funding = ServiceFunding()
        funding.setLevel(0.1, for: .park)
        XCTAssertEqual(funding.level(for: .park), 1.0, "a park took a funding level")

        XCTAssertFalse(CityHazards.crime.zones.contains(.park))
        XCTAssertFalse(CityHazards.fire.zones.contains(.park))
    }

    /// And it is placeable through the toolbar, which is the only route a
    /// player has to it.
    func testAParkIsOfferedInTheToolbar() {
        let offered = ToolCategory.allCases.flatMap(\.tools)
        XCTAssertTrue(offered.contains(.park), "parks are unreachable from the toolbar")
    }

    // MARK: - End to end

    func testAPlayerCanPlaceAParkAndTheLotBesideItGetsBetter() {
        let controller = GameController(
            map: street(), rng: AlwaysZeroRNG(), peakPopulation: 0
        )
        let before = LandValue.value(at: lot, in: controller.map)
        let treasury = controller.treasury

        controller.selectedTool = .park
        controller.place(at: GridPosition(x: 4, y: 0))

        XCTAssertEqual(controller.map[GridPosition(x: 4, y: 0)].zone, .park)
        XCTAssertEqual(controller.treasury, treasury - ZoneType.park.placementCost)
        XCTAssertGreaterThan(LandValue.value(at: lot, in: controller.map), before)
    }
}
