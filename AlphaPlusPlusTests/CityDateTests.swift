import XCTest
@testable import AlphaPlusPlus

/// The calendar — one tick is one day, and the player never has to hear the
/// word "tick".
@MainActor
final class CityDateTests: XCTestCase {

    // MARK: - The arithmetic

    func testANewCityStartsOnTheFirstDayOfItsFoundingYear() {
        let start = CityDate(day: 0)
        XCTAssertEqual(start.year, CityDate.foundingYear)
        XCTAssertEqual(start.month, 1)
        XCTAssertEqual(start.dayOfMonth, 1)
        XCTAssertEqual(start.age, 0)
    }

    func testMonthsAndYearsRollOverWhereTheyShould() {
        XCTAssertEqual(CityDate(day: CityDate.daysPerMonth - 1).dayOfMonth, CityDate.daysPerMonth)
        XCTAssertEqual(CityDate(day: CityDate.daysPerMonth - 1).month, 1)

        // First day of the second month.
        let nextMonth = CityDate(day: CityDate.daysPerMonth)
        XCTAssertEqual(nextMonth.month, 2)
        XCTAssertEqual(nextMonth.dayOfMonth, 1)

        // Last day of the first year, then the first of the second.
        XCTAssertEqual(CityDate(day: CityDate.daysPerYear - 1).year, CityDate.foundingYear)
        XCTAssertEqual(CityDate(day: CityDate.daysPerYear - 1).month, CityDate.monthsPerYear)
        XCTAssertEqual(CityDate(day: CityDate.daysPerYear).year, CityDate.foundingYear + 1)
        XCTAssertEqual(CityDate(day: CityDate.daysPerYear).month, 1)
    }

    /// Every day of a long run has to land inside the calendar. An off-by-one
    /// in the month arithmetic shows up as a 13th month or a 0th day, and only
    /// on particular days — exactly the kind of thing a spot check misses.
    func testEveryDayOfFiveYearsIsAValidDate() {
        for day in 0 ..< CityDate.daysPerYear * 5 {
            let date = CityDate(day: day)
            XCTAssertTrue((1 ... CityDate.monthsPerYear).contains(date.month),
                          "day \(day) fell in month \(date.month)")
            XCTAssertTrue((1 ... CityDate.daysPerMonth).contains(date.dayOfMonth),
                          "day \(day) fell on day-of-month \(date.dayOfMonth)")
            XCTAssertGreaterThanOrEqual(date.year, CityDate.foundingYear)
        }
    }

    func testDatesOrderByDay() {
        XCTAssertLessThan(CityDate(day: 5), CityDate(day: 6))
        XCTAssertEqual(CityDate(day: 7), CityDate(day: 7))
    }

    // MARK: - One clock

    /// **The calendar and the economy must not be able to disagree.** The day
    /// count is read from `RegionalEconomy.elapsed` rather than kept beside
    /// it, because two copies of the same fact drifting apart is the mistake
    /// this project keeps paying for.
    func testTheCalendarAdvancesWithTheSimulationAndNotSeparately() {
        let controller = GameController(
            map: CityMap(width: 12, height: 12), rng: AlwaysZeroRNG(),
            peakPopulation: Unlocks.everythingUnlocked
        )
        XCTAssertEqual(controller.map.date, CityDate(day: 0))

        for expected in 1 ... 40 {
            controller.advanceSimulation()
            XCTAssertEqual(controller.map.elapsedDays, expected)
            XCTAssertEqual(controller.map.date.day, controller.map.regionalEconomy.elapsed,
                           "the calendar and the regional cycle are reading different clocks")
        }
    }

    /// A city that is reloaded has to remember how old it is.
    func testTheDateSurvivesASaveRoundTrip() throws {
        let controller = GameController(
            map: CityMap(width: 12, height: 12), rng: AlwaysZeroRNG(),
            peakPopulation: Unlocks.everythingUnlocked
        )
        for _ in 0 ..< 95 { controller.advanceSimulation() }

        let data = try JSONEncoder().encode(controller.snapshot())
        let decoded = try JSONDecoder().decode(CitySave.self, from: data)
        let restored = GameController(map: CityMap(width: 12, height: 12), rng: AlwaysZeroRNG(),
                                      peakPopulation: Unlocks.everythingUnlocked)
        try restored.restore(from: decoded)

        XCTAssertEqual(restored.map.date, controller.map.date)
        XCTAssertEqual(restored.map.date.day, 95)
    }

    // MARK: - What it reads as

    func testTheDateReadsAsADate() {
        XCTAssertEqual(CalendarText.full(CityDate(day: 0)), "1 Jan 1985")
        // Day 0 is 1 Jan, so the 43rd day is 13 Feb.
        XCTAssertEqual(CalendarText.full(CityDate(day: 43)), "14 Feb 1985")
        XCTAssertEqual(CalendarText.monthAndYear(CityDate(day: CityDate.daysPerYear)), "Jan 1986")
    }

    /// A number that grows by one every second cannot keep the same unit
    /// forever — four figures of days is not something anyone reads at a
    /// glance.
    func testAgeChangesUnitsAsTheCityGetsOlder() {
        XCTAssertEqual(CalendarText.age(CityDate(day: 1)), "1 day")
        XCTAssertEqual(CalendarText.age(CityDate(day: 18)), "18 days")
        XCTAssertEqual(CalendarText.age(CityDate(day: CityDate.daysPerMonth * 7)), "7 months")
        XCTAssertEqual(CalendarText.age(CityDate(day: CityDate.daysPerYear)), "1 year")
        XCTAssertEqual(CalendarText.age(CityDate(day: CityDate.daysPerYear * 3 + 40)), "3 years")
    }

    func testSingularsReadCorrectly() {
        XCTAssertEqual(CalendarText.days(1), "1 day")
        XCTAssertEqual(CalendarText.days(0), "0 days")
        XCTAssertEqual(CalendarText.days(12), "12 days")
    }

    // MARK: - The mapping is worth stating

    /// The whole reason one tick is one day: the constants already in the
    /// simulation land on sensible durations under that reading. If any of
    /// them moves far enough that this stops being true, the mapping is what
    /// should be revisited — not quietly tolerated.
    func testTheExistingConstantsReadAsSensibleDurations() {
        // A storey takes between a week and two months to build.
        XCTAssertGreaterThanOrEqual(CitySimulator.constructionTicks(toReach: 1), 7)
        XCTAssertLessThanOrEqual(CitySimulator.constructionTicks(toReach: 5), CityDate.daysPerMonth * 2)

        // The region's boom-and-bust runs on roughly an annual cycle.
        let cycleYears = Double(RegionalEconomy.longestCycle) / Double(CityDate.daysPerYear)
        XCTAssertGreaterThan(cycleYears, 0.5, "the economy turns over faster than twice a year")
        XCTAssertLessThan(cycleYears, 2.0, "the economy takes more than two years to turn over")
    }
}
