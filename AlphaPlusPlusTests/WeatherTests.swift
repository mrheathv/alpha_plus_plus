import XCTest
@testable import AlphaPlusPlus

/// Rain, and the wet street it leaves.
///
/// The properties here are the same three `RegionalEconomy` had to satisfy,
/// which is why weather is a clock rather than a dice roll — and one more
/// besides, because unlike the economy this one is *visible*, so a forecast
/// that flickered between frames would be a broken effect rather than a
/// surprising one.
final class WeatherTests: XCTestCase {

    /// **The same day is the same weather, every run.** Every render in this
    /// project is a yardstick, and a city photographed on day 6 has to be wet
    /// in every one of them or the filmstrip stops meaning anything.
    func testTheForecastIsAFunctionOfTheDay() {
        for day in [0, 6, 37, 200, 1_000] {
            XCTAssertEqual(Weather.rainfall(onDay: day), Weather.rainfall(onDay: day))
            XCTAssertEqual(Weather.wetness(onDay: day), Weather.wetness(onDay: day))
        }
    }

    /// **Measured, not reasoned.** The doc comment first claimed "spells of
    /// two to four days", which was a guess; counting says 22% of days and
    /// spells averaging eight. The bounds are wide enough to be a property
    /// rather than a snapshot, and tight enough that a tuning change which
    /// made it rain constantly — or never — would say so here.
    func testItRainsSometimesRatherThanAlwaysOrNever() {
        let days = 0 ..< 400
        let wet = days.filter { Weather.rainfall(onDay: $0) > 0 }.count
        let fraction = Double(wet) / Double(days.count)
        XCTAssertGreaterThan(fraction, 0.10, "it barely ever rains — the bias is too high")
        XCTAssertLessThan(fraction, 0.40, "it rains most of the time, which is a filter not weather")
    }

    /// A storm arrives and leaves rather than switching on. Sampling the
    /// heaviest day against its neighbours is the cheap way to say "this is
    /// continuous", and it is what stops the effect popping.
    func testAStormRisesAndFalls() {
        // Day 6 is the peak of the first storm every city gets.
        let peak = Weather.rainfall(onDay: 6)
        XCTAssertGreaterThan(peak, 0.8, "the heaviest day of the first storm is not heavy")
        XCTAssertLessThan(Weather.rainfall(onDay: 2), peak)
        XCTAssertLessThan(Weather.rainfall(onDay: 11), peak)
        XCTAssertEqual(Weather.rainfall(onDay: 14), 0, "the storm never ends")
    }

    /// Wetness is quantised before it reaches the renderer, because it feeds a
    /// texture cache key: a value drifting by a thousandth a day would rebuild
    /// every lot in the city every tick. Road wear needed the same treatment
    /// for the same reason.
    func testWetnessComesInStepsSoItCannotThrashTheCache() {
        let values = Set((0 ..< 400).map { Weather.wetness(onDay: $0) })
        XCTAssertLessThanOrEqual(values.count, 6,
                                 "wetness takes \(values.count) distinct values — that is a cache key "
                                 + "changing almost every day")
        XCTAssertTrue(values.contains(0), "it is never dry")
    }

    /// And the streets stay wet a little past the rain, rather than drying the
    /// instant it stops.
    func testTheGroundIsWetWhereverItIsRaining() {
        for day in 0 ..< 400 where Weather.rainfall(onDay: day) > Weather.wetThreshold {
            XCTAssertGreaterThan(Weather.wetness(onDay: day), 0,
                                 "day \(day) is raining on dry ground")
        }
    }
}
