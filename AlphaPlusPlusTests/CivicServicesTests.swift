import XCTest
@testable import AlphaPlusPlus

/// Tests for the education/health pair — the mid-game progression axis, and
/// the first real money *sink* in the game.
@MainActor
final class CivicServicesTests: XCTestCase {

    /// A lot with everything it needs to reach density 5 *except* whatever the
    /// test is about. Road frontage, water, power, and a police station for
    /// land value; `school` adds the education coverage the top tier wants.
    private func makeTopTierCity(school: Bool) -> CityMap {
        var map = CityMap(width: 20, height: 20)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 0, y: 0)].density = 4
        map[GridPosition(x: 2, y: 0)].zone = .road
        map.placeBuilding(zone: .policeStation, origin: GridPosition(x: 3, y: 0))

        for y in 1 ... 6 {
            map[GridPosition(x: 2, y: y)].hasPipe = true
            map[GridPosition(x: 2, y: y)].hasPowerLine = true
        }
        map.placeBuilding(zone: .waterPump, origin: GridPosition(x: 3, y: 3))
        map.placeBuilding(zone: .generator, origin: GridPosition(x: 3, y: 5))
        map.waterSupply = Water.computeSupply(for: map)
        map.powerSupply = PowerGrid.computeSupply(for: map, outageActive: false)

        if school {
            map.placeBuilding(zone: .school, origin: GridPosition(x: 0, y: 4))
        }
        return map
    }

    // MARK: - Education gates the top tier

    func testWithoutASchoolAZoneStopsOneShortOfFullDensity() {
        var map = makeTopTierCity(school: false)
        var rng = AlwaysZeroRNG()
        for _ in 0 ..< 5 { map = CitySimulator.advance(map, using: &rng) }

        XCTAssertEqual(
            map[GridPosition(x: 0, y: 0)].density, 4,
            "a lot reached full density with no school in range"
        )
    }

    func testASchoolInRangeUnlocksFullDensity() {
        var map = makeTopTierCity(school: true)
        var rng = AlwaysZeroRNG()
        for _ in 0 ..< 5 { map = CitySimulator.advance(map, using: &rng) }

        XCTAssertEqual(map[GridPosition(x: 0, y: 0)].density, ZoneType.residential.maxDensity)
    }

    /// A school on the far side of the map is not a school in range — the
    /// point is a catchment, not a checkbox on the city as a whole.
    func testASchoolTooFarAwayDoesNotCount() {
        var map = makeTopTierCity(school: false)
        map.placeBuilding(zone: .school, origin: GridPosition(x: 18, y: 18))

        var rng = AlwaysZeroRNG()
        for _ in 0 ..< 5 { map = CitySimulator.advance(map, using: &rng) }

        XCTAssertEqual(map[GridPosition(x: 0, y: 0)].density, 4)
    }

    /// Education sits above water and power on the same ladder, so the gates
    /// stay in a fixed, learnable order.
    func testEducationIsTheLastRungOfTheUtilityLadder() {
        XCTAssertLessThan(CitySimulator.waterRequiredFromLevel, CitySimulator.powerRequiredFromLevel)
        XCTAssertLessThan(CitySimulator.powerRequiredFromLevel, CitySimulator.educationRequiredFromLevel)
        XCTAssertEqual(CitySimulator.educationRequiredFromLevel, ZoneType.residential.maxDensity)
    }

    /// Defunding schools has to bite, since coverage is falloff × funding.
    func testDefundingSchoolsRemovesTheirCoverage() {
        var map = makeTopTierCity(school: true)
        map.serviceFunding.setLevel(0, for: .school)

        var rng = AlwaysZeroRNG()
        for _ in 0 ..< 5 { map = CitySimulator.advance(map, using: &rng) }

        XCTAssertEqual(
            map[GridPosition(x: 0, y: 0)].density, 4,
            "an unfunded school still counted as education coverage"
        )
    }

    // MARK: - Hospitals soften hazards

    /// A hospital does not prevent a strike — coverage by the relevant service
    /// is what does that — but it halves what the strike takes out.
    func testAHospitalHalvesHazardDamage() {
        func remainingDensity(hospital: Bool) -> Int {
            var map = CityMap(width: 20, height: 20)
            map.placeBuilding(zone: .industrial, origin: GridPosition(x: 0, y: 0))
            for cell in map.footprintCells(origin: GridPosition(x: 0, y: 0), size: 2) {
                map[cell].density = 5
            }
            if hospital {
                map.placeBuilding(zone: .hospital, origin: GridPosition(x: 0, y: 4))
            }
            var rng = AlwaysZeroRNG() // every hazard roll succeeds
            let (next, strikes) = CityHazards.apply([CityHazards.fire], to: map, using: &rng)
            XCTAssertFalse(strikes.isEmpty, "the fixture never caught fire")
            return next[GridPosition(x: 0, y: 0)].density
        }

        let unprotected = remainingDensity(hospital: false)
        let covered = remainingDensity(hospital: true)

        XCTAssertLessThan(unprotected, covered, "the hospital did not soften the damage")
        XCTAssertEqual(unprotected, 5 - CityHazards.fire.densityLoss)
        XCTAssertEqual(covered, 5 - max(1, CityHazards.fire.densityLoss / 2))
    }

    /// It softens, never prevents. A risk that already costs a single level
    /// keeps costing one — otherwise a hospital would quietly switch crime off.
    func testAHospitalNeverMakesAHazardFree() {
        var map = CityMap(width: 20, height: 20)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        for cell in map.footprintCells(origin: GridPosition(x: 0, y: 0), size: 2) {
            map[cell].density = 3
        }
        map.placeBuilding(zone: .hospital, origin: GridPosition(x: 0, y: 4))

        var rng = AlwaysZeroRNG()
        let (next, strikes) = CityHazards.apply([CityHazards.crime], to: map, using: &rng)

        XCTAssertFalse(strikes.isEmpty)
        XCTAssertEqual(CityHazards.crime.densityLoss, 1, "this test assumes crime costs one level")
        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 2, "the hospital made a hazard free")
    }

    /// Damage still needs the *relevant* service to repair; a hospital softens
    /// the blow but does not stand in for a fire station.
    func testAHospitalDoesNotRepairDamage() {
        var map = CityMap(width: 20, height: 20)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 2, y: 0)].zone = .road
        for cell in map.footprintCells(origin: GridPosition(x: 0, y: 0), size: 2) {
            map[cell].density = 2
            map[cell].damagedBy = .fireStation
        }
        map.placeBuilding(zone: .hospital, origin: GridPosition(x: 0, y: 4))

        var rng = AlwaysMaxRNG() // fails the unassisted-repair roll
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertTrue(next[GridPosition(x: 0, y: 0)].isDamaged)
    }

    // MARK: - As a money sink

    /// The reason these exist at all, beyond progression: a mature city was
    /// banking millions with nothing to buy. Civic buildings are the heaviest
    /// ongoing cost in the game.
    func testCivicBuildingsAreASubstantialOngoingCost() {
        // The hospital is the single heaviest thing in the game to run.
        let heaviestOther = ZoneType.allCases
            .filter { $0 != .hospital }
            .map(\.upkeepCost)
            .max() ?? 0
        XCTAssertGreaterThan(ZoneType.hospital.upkeepCost, heaviestOther)

        // The school sits below the power plant — a 3×3 plant serving the
        // whole city should cost more than a neighbourhood school — but well
        // above the ordinary stations it stands alongside.
        XCTAssertLessThan(ZoneType.school.upkeepCost, ZoneType.powerPlant.upkeepCost)
        XCTAssertGreaterThan(ZoneType.school.upkeepCost, ZoneType.policeStation.upkeepCost)
    }

    func testCivicUpkeepShowsUpInTheCitysCosts() {
        let controller = GameController(peakPopulation: Unlocks.everythingUnlocked)
        let before = controller.upkeepCost

        controller.selectedTool = .school
        controller.place(at: GridPosition(x: 0, y: 0))
        controller.selectedTool = .hospital
        controller.place(at: GridPosition(x: 4, y: 0))

        XCTAssertEqual(
            controller.upkeepCost,
            before + ZoneType.school.upkeepCost + ZoneType.hospital.upkeepCost
        )
    }

    /// Both are earned rather than available from the start, and in the order
    /// their roles imply — a school before a city is pressing on the density
    /// ceiling it unlocks.
    func testBothUnlockMidGameInTheRightOrder() {
        XCTAssertGreaterThan(Unlocks.requiredPopulation(for: .school), 0)
        XCTAssertLessThan(
            Unlocks.requiredPopulation(for: .school),
            Unlocks.requiredPopulation(for: .hospital)
        )
    }
}
