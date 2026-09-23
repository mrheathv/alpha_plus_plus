import XCTest
@testable import AlphaPlusPlus

/// The milestones ladder.
///
/// The first group pins each rank's thresholds against the **measured**
/// scorecards they were calibrated on (`MilestoneCalibrationTests`, Release,
/// seed 4242). Each pair is a strategy that should clear a bar and one that
/// should not, so a threshold nudged past either end fails here with the
/// evidence named — which is what keeps a milestone from quietly becoming a
/// headcount again, or a wall nobody can climb.
@MainActor
final class MilestoneTests: XCTestCase {

    private func card(pop: Int, water: Double = 1, power: Double = 1, school: Double = 1,
                      pollution: Double = 0, congestion: Double = 0, rubble: Double = 0) -> CityScorecard {
        var card = CityScorecard()
        card.population = pop
        card.waterServed = water
        card.powerServed = power
        card.schooled = school
        card.homePollution = pollution
        card.congestion = congestion
        card.rubble = rubble
        return card
    }

    private func meets(_ rank: Milestone, _ card: CityScorecard, net: Int = 100) -> Bool {
        rank.requirements.allSatisfy { $0.isMet(by: card, netRevenue: net) }
    }

    // MARK: - Calibrated pairs

    /// 48×48, day 300: a city with no utilities has people and no water.
    func testVillageNeedsWaterNotJustPeople() {
        XCTAssertFalse(meets(.village, card(pop: 912, water: 0, power: 1, school: 0,
                                            pollution: 0.108, congestion: 0.063, rubble: 0.10)))
        XCTAssertTrue(meets(.village, card(pop: 2100, water: 1, power: 1, school: 0.80,
                                           pollution: 0.348, congestion: 0.157, rubble: 0.03)))
    }

    /// 32×32, day 300: the smallest map's Town takes a planned city.
    func testTownOnTheSmallestMapTakesAPlannedCity() {
        let planned = card(pop: 960, water: 1, power: 1, school: 0.95, pollution: 0.076, congestion: 0.123)
        let defaultLayout = card(pop: 784, water: 1, power: 1, school: 0.95, pollution: 0.509, congestion: 0.073)
        XCTAssertTrue(meets(.town, planned))
        XCTAssertFalse(meets(.town, defaultLayout))
    }

    /// 48×48, day 300: industry beside housing fails City on clean air alone.
    func testCityAsksForHousingKeptAwayFromIndustry() {
        let apart = card(pop: 2280, school: 0.76, pollution: 0.046, congestion: 0.132, rubble: 0.05)
        let mixed = card(pop: 2100, school: 0.80, pollution: 0.348, congestion: 0.157, rubble: 0.03)
        XCTAssertTrue(meets(.city, apart))
        XCTAssertFalse(meets(.city, mixed))
    }

    /// 32×32, dense services: every service everywhere, and bankrupt. The one
    /// requirement that reads money is what refuses it.
    func testCityRefusesACityThatIsLosingMoney() {
        let lavish = card(pop: 2100, pollution: 0.08)
        XCTAssertTrue(meets(.city, lavish, net: 1))
        XCTAssertFalse(meets(.city, lavish, net: -514))
    }

    /// 64×64, day 150: the best car-only city is bigger than the subway one
    /// and still not a Metropolis, because its roads are jammed.
    func testMetropolisTakesTransitNotJustSize() {
        let subway = card(pop: 4104, school: 0.94, pollution: 0.032, congestion: 0.036, rubble: 0.02)
        let carOnly = card(pop: 4468, school: 0.95, pollution: 0.031, congestion: 0.187, rubble: 0.01)
        XCTAssertTrue(meets(.metropolis, subway))
        XCTAssertFalse(meets(.metropolis, carOnly))
    }

    // MARK: - The ladder's rules

    func testRanksAreEarnedInOrder() {
        // Good at everything except water: the headcount alone would say
        // Metropolis, and the ladder stops at the first rung it cannot clear.
        let noWater = card(pop: 5000, water: 0)
        XCTAssertEqual(Milestone.newlyEarned(after: nil, card: noWater, netRevenue: 10), [.hamlet])
    }

    func testSeveralRanksCanArriveTogether() {
        let excellent = card(pop: 5000)
        XCTAssertEqual(Milestone.newlyEarned(after: .village, card: excellent, netRevenue: 10),
                       [.town, .city, .metropolis])
    }

    func testARankIsNotTakenBack() {
        let ruined = card(pop: 0, water: 0, power: 0)
        XCTAssertEqual(Milestone.newlyEarned(after: .city, card: ruined, netRevenue: -1_000), [])
    }

    func testTheTopOfTheLadderHasNoNext() {
        XCTAssertNil(Milestone.next(after: .metropolis))
        XCTAssertEqual(Milestone.next(after: nil), .hamlet)
    }

    /// Every rank's headcount is higher than the one below it — the ladder
    /// climbs rather than asking a Town for fewer people than a Village.
    func testEveryRankAsksForMorePeopleThanTheLast() {
        let heads = Milestone.allCases.map { rank -> Int in
            for case .residents(let n) in rank.requirements { return n }
            return 0
        }
        XCTAssertEqual(heads, heads.sorted())
        XCTAssertEqual(Set(heads).count, heads.count)
        XCTAssertFalse(heads.contains(0), "every rank asks for residents")
    }

    // MARK: - A real city

    /// **Earned by playing, not by a test handing it a scorecard.**
    ///
    /// A serviced city on the quick profile has to reach at least Village —
    /// the rank that asks for water — and the same city without utilities must
    /// not get past Hamlet. Asserted on the controller after real ticks, so the
    /// scorecard, the ladder and the tick hook are all in the loop.
    func testAServicedCityClimbsAndAnUnplumbedOneStalls() {
        let size = PlaytestHarness.Profile.quick.size
        let served = PlaytestHarness.runScenario(.init(size: size), ticks: 240, seed: 4242).controller
        let dry = PlaytestHarness.runScenario(
            .init(size: size, includeUtilities: false, includeServices: false), ticks: 240, seed: 4242
        ).controller

        XCTAssertGreaterThanOrEqual(served.milestone ?? .hamlet, .village,
                                    "a serviced city never earned the water rank")
        XCTAssertEqual(dry.milestone, .hamlet, "a city with no water climbed past Hamlet")
        XCTAssertEqual(served.scorecard.population, served.population)
    }

    // MARK: - Persistence

    func testARankSurvivesASave() throws {
        let size = PlaytestHarness.Profile.quick.size
        let city = PlaytestHarness.runScenario(.init(size: size), ticks: 120, seed: 4242).controller
        let earned = try XCTUnwrap(city.milestone)

        let data = try JSONEncoder().encode(city.snapshot())
        let loaded = GameController()
        try loaded.restore(from: JSONDecoder().decode(CitySave.self, from: data))
        XCTAssertEqual(loaded.milestone, earned)
    }

    func testFoundingAgainClearsTheRank() {
        let size = PlaytestHarness.Profile.quick.size
        let city = PlaytestHarness.runScenario(.init(size: size), ticks: 120, seed: 4242).controller
        XCTAssertNotNil(city.milestone)
        city.resetMap()
        XCTAssertNil(city.milestone)
    }

    // MARK: - Words

    func testEveryRequirementCanBeRead() {
        for rank in Milestone.allCases {
            XCTAssertFalse(MilestoneText.name(rank).isEmpty)
            for requirement in rank.requirements {
                XCTAssertFalse(MilestoneText.label(requirement).isEmpty, "\(requirement)")
                XCTAssertFalse(MilestoneText.status(requirement, card: CityScorecard(), netRevenue: 0).isEmpty)
            }
        }
    }
}
