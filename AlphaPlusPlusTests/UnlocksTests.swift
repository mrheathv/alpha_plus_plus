import XCTest
@testable import AlphaPlusPlus

/// Tests for the unlock ladder — the genre's answer to "why keep playing" in a
/// game with no ending.
@MainActor
final class UnlocksTests: XCTestCase {

    /// A city grown far enough to have earned the water tower.
    ///
    /// Sized deliberately: without water a city is capped at density 2 by
    /// `CitySimulator.waterRequiredFromLevel`, so each 2×2 residential lot
    /// contributes 8 residents and clearing the tower's 100 takes at least
    /// thirteen of them. An earlier version of this fixture used twelve and
    /// peaked at 96 — four residents short, and unable to ever earn the tool
    /// that would let it grow further. A real map has well over a hundred
    /// lots, so this is a fixture size problem rather than a threshold
    /// problem, but it is a neat demonstration of how tight the bootstrap is.
    ///
    /// Uses `SeededRNG` rather than `AlwaysZeroRNG`: the latter fires *every*
    /// hazard on every tick, so the housing here — which has no police cover,
    /// because a brand-new city has not earned a station yet — would be
    /// levelled before it ever grew. Realistic randomness keeps hazards rare
    /// enough for the city to get off the ground, which is the whole point of
    /// the fixture.
    private func grownCity() -> GameController {
        let controller = GameController(rng: SeededRNG(seed: 1))
        for x in 0 ..< 32 {
            controller.selectedTool = .road
            controller.place(at: GridPosition(x: x, y: 4))
        }
        // Two rows of lots either side of the one road: 14 residential, 18
        // commercial. Both numbers are derived rather than picked.
        //
        // Residential has to clear the tower's 100 while still capped at
        // density 2 by `CitySimulator.waterRequiredFromLevel`, and a 2×2 lot
        // houses 4 per level — so 14 lots give 112, with a little margin.
        //
        // The commercial count then follows from what `Demand` considers
        // balanced. A residential level is worth 4 residents and a commercial
        // one 3 jobs, so jobs only keep up with people at roughly 4 commercial
        // lots per 3 residential. Earlier versions of this fixture used all
        // residential, then 2:1, and both drove residential demand to the
        // abandonment floor and shrank instead of growing — the demand model
        // punishes housing-heavy cities much harder than the intuitive "mostly
        // houses" layout suggests.
        var placed = 0
        for y in [2, 5] {
            for x in stride(from: 0, to: 32, by: 2) {
                controller.selectedTool = placed < 14 ? .residential : .commercial
                controller.place(at: GridPosition(x: x, y: y))
                placed += 1
            }
        }
        for _ in 0 ..< 60 { controller.advanceSimulation() }
        return controller
    }


    // MARK: - The ladder itself

    /// The core loop has to be available immediately, or a new city cannot
    /// start at all.
    func testTheStartingToolsAreAvailableFromNothing() {
        for zone in [ZoneType.residential, .commercial, .industrial, .road] {
            XCTAssertTrue(Unlocks.isUnlocked(zone, peakPopulation: 0), "\(zone) should start unlocked")
        }
    }

    /// The bulldozer must never lock — it is the only way out of a mistake, and
    /// a player who cannot undo is stuck.
    func testTheBulldozerIsNeverLocked() {
        XCTAssertEqual(Unlocks.requiredPopulation(for: .empty), 0)
        XCTAssertTrue(Unlocks.isUnlocked(.empty, peakPopulation: 0))
    }

    func testAdvancedToolsStartLocked() {
        for zone in [ZoneType.waterTower, .powerPlant, .subway, .stadium] {
            XCTAssertFalse(Unlocks.isUnlocked(zone, peakPopulation: 0), "\(zone) should start locked")
        }
    }

    /// Each cheap tool must arrive before its pricier counterpart, or the pair
    /// relationship the zones already document is inverted.
    func testUpgradesUnlockAfterTheirCheaperCounterpart() {
        XCTAssertLessThan(
            Unlocks.requiredPopulation(for: .road),
            Unlocks.requiredPopulation(for: .highway)
        )
        XCTAssertLessThan(
            Unlocks.requiredPopulation(for: .publicTransit),
            Unlocks.requiredPopulation(for: .subway)
        )
    }

    /// The utilities have to arrive before the density gates that need them,
    /// or a city would stall at a wall it has no tool to clear.
    func testUtilitiesUnlockBeforeTheDensityThatNeedsThem() {
        // Water gates density 3, so a city capped at density 2 must be able to
        // earn a tower. Thirteen 2×2 lots at density 2 is 104 residents.
        XCTAssertLessThanOrEqual(
            Unlocks.requiredPopulation(for: .waterTower), 120,
            "water unlocks later than a density-2-capped city can reach"
        )
        // Power gates density 4, which a water-served city can build toward.
        XCTAssertLessThan(
            Unlocks.requiredPopulation(for: .powerPlant),
            Unlocks.requiredPopulation(for: .highway)
        )
        XCTAssertGreaterThan(
            Unlocks.requiredPopulation(for: .powerPlant),
            Unlocks.requiredPopulation(for: .waterTower)
        )
    }

    func testNewlyUnlockedReportsOnlyWhatWasJustCrossed() {
        let crossed = Unlocks.newlyUnlocked(crossing: 100, from: 40)

        XCTAssertTrue(crossed.contains(.waterTower))
        XCTAssertFalse(crossed.contains(.policeStation), "already earned at 40")
        XCTAssertFalse(crossed.contains(.powerPlant), "not earned until 300")
    }

    func testNewlyUnlockedIsEmptyWhenThePeakDoesNotMove() {
        XCTAssertTrue(Unlocks.newlyUnlocked(crossing: 50, from: 100).isEmpty)
        XCTAssertTrue(Unlocks.newlyUnlocked(crossing: 100, from: 100).isEmpty)
    }

    // MARK: - Enforcement

    func testPlacingALockedToolIsRefusedAndCostsNothing() {
        let controller = GameController()
        let treasuryBefore = controller.treasury
        controller.selectedTool = .stadium

        let outcome = controller.place(at: GridPosition(x: 0, y: 0))

        XCTAssertEqual(outcome, .locked)
        XCTAssertEqual(controller.treasury, treasuryBefore, "a locked tool charged the treasury")
        XCTAssertEqual(controller.map[GridPosition(x: 0, y: 0)].zone, .empty)
    }

    func testPlacingAnUnlockedToolStillWorks() {
        let controller = GameController()
        controller.selectedTool = .residential

        XCTAssertEqual(controller.place(at: GridPosition(x: 0, y: 0)), .placed)
    }

    // MARK: - The high-water mark

    func testGrowingACityEarnsTools() {
        XCTAssertFalse(GameController().isUnlocked(.waterTower), "a new city should not start with water")

        let controller = grownCity()

        XCTAssertGreaterThanOrEqual(controller.peakPopulation, 100)
        XCTAssertTrue(controller.isUnlocked(.waterTower), "a city of \(controller.peakPopulation) never earned water")
    }

    /// The reason the mark is a *peak*: a city that burns down keeps what it
    /// earned. Losing the fire station because your city caught fire would be
    /// exactly backwards.
    func testToolsStayUnlockedWhenTheCityShrinks() {
        let controller = grownCity()
        XCTAssertTrue(controller.isUnlocked(.waterTower))
        let peak = controller.peakPopulation

        // Flatten the city — both lot rows, or the "shrinks" premise is false.
        for y in [2, 5] {
            for x in stride(from: 0, to: 32, by: 2) {
                controller.bulldoze(at: GridPosition(x: x, y: y))
            }
        }
        controller.advanceSimulation()

        XCTAssertEqual(controller.population, 0)
        XCTAssertEqual(controller.peakPopulation, peak, "the high-water mark receded")
        XCTAssertTrue(controller.isUnlocked(.waterTower), "a shrinking city lost a tool it had earned")
    }

    func testResettingTheMapClearsTheMark() {
        let controller = grownCity()
        XCTAssertGreaterThan(controller.peakPopulation, 0)

        controller.resetMap()

        XCTAssertEqual(controller.peakPopulation, 0)
        XCTAssertFalse(controller.isUnlocked(.waterTower))
    }

    // MARK: - Saving

    func testThePeakSurvivesASaveAndLoad() throws {
        let controller = grownCity()
        let peak = controller.peakPopulation
        XCTAssertGreaterThan(peak, 0)

        let data = try JSONEncoder().encode(controller.snapshot())
        let restored = GameController(rng: AlwaysZeroRNG())
        try restored.restore(from: JSONDecoder().decode(CitySave.self, from: data))

        XCTAssertEqual(restored.peakPopulation, peak)
        XCTAssertTrue(restored.isUnlocked(.waterTower))
    }

    /// A save written before unlocks existed has no mark recorded. It must
    /// still load, falling back to what the city currently supports rather
    /// than failing or handing out every tool.
    func testASaveWithoutAPeakFallsBackToCurrentPopulation() throws {
        let controller = grownCity()

        let current = controller.snapshot()
        let legacy = CitySave(
            map: current.map,
            treasury: current.treasury,
            taxRate: current.taxRate,
            bondBalance: current.bondBalance,
            history: current.history,
            peakPopulation: nil
        )

        let restored = GameController(rng: AlwaysZeroRNG())
        try restored.restore(from: legacy)

        XCTAssertEqual(restored.peakPopulation, restored.population)
        XCTAssertGreaterThan(restored.peakPopulation, 0)
    }
}
