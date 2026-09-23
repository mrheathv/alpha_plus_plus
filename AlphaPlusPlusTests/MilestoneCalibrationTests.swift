import XCTest
@testable import AlphaPlusPlus

/// **What real cities score, before any milestone asks for a number.**
///
/// A milestone threshold is a balance constant, and this project's rule for
/// those is that they are measured rather than argued. So before the ladder
/// asks "water to 90% of the blocks that want it", this runs the strategies
/// `DesignPlaytestTests` already defines and prints what each one actually
/// scores on every scorecard field, at several points in its life.
///
/// What it is for is reading, so it is opt-in: it runs eight cities to
/// completion, which is exactly the kind of cost that should not ride along
/// with every run of the suite.
///
/// ```sh
/// TEST_RUNNER_PLAYTEST_FULL=1 xcodebuild -project AlphaPlusPlus.xcodeproj \
///   -scheme AlphaPlusPlus -configuration Release -derivedDataPath ./build \
///   ENABLE_TESTABILITY=YES test \
///   -only-testing:AlphaPlusPlusTests/MilestoneCalibrationTests
/// ```
@MainActor
final class MilestoneCalibrationTests: XCTestCase {

    private struct Strategy {
        let name: String
        var spec: PlaytestHarness.CitySpec
        var configure: (GameController) -> Void = { _ in }
    }

    private func strategies(size: Int) -> [Strategy] {
        [
            Strategy(name: "no infra", spec: .init(size: size, includeUtilities: false, includeServices: false)),
            Strategy(name: "services, no utils", spec: .init(size: size, includeUtilities: false, includeServices: true)),
            Strategy(name: "default", spec: .init(size: size)),
            Strategy(name: "industry apart", spec: .init(size: size, segregateIndustry: true)),
            Strategy(name: "apart + subway", spec: .init(
                size: size, segregateIndustry: true, transitStations: .subway, drawTransitRoutes: true)),
            Strategy(name: "dense services", spec: .init(size: size, serviceSpacing: 3)),
            Strategy(name: "services unfunded", spec: .init(size: size), configure: { controller in
                for zone in ZoneType.allCases { controller.setFundingLevel(0, for: zone) }
            }),
            Strategy(name: "max tax", spec: .init(size: size), configure: { $0.taxRate = 2.0 }),
        ]
    }

    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private func row(_ name: String, _ day: Int, _ card: CityScorecard, _ controller: GameController) -> String {
        func pct(_ value: Double) -> String { String(format: "%3.0f%%", value * 100) }
        return pad(name, 20) + pad("\(day)", 6) + pad("\(card.population)", 7)
            + pad(pct(card.waterServed), 7) + pad(pct(card.powerServed), 7) + pad(pct(card.schooled), 7)
            + pad(String(format: "%.3f", card.homePollution), 8)
            + pad(String(format: "%.3f", card.congestion), 8)
            + pad(pct(card.rubble), 7)
            + pad(pct(card.transitShare), 7)
            + pad("\(controller.treasury)", 10) + "\(controller.netRevenue)"
    }

    func testPrintWhatStrategiesScore() throws {
        try XCTSkipUnless(PlaytestHarness.Profile.current == .full,
                          "a calibration readout, run with TEST_RUNNER_PLAYTEST_FULL=1")
        let checkpoints = [60, 150, 300, 600, 1_000, 1_500]
        let header = pad("strategy", 20) + pad("day", 6) + pad("pop", 7) + pad("water", 7)
            + pad("power", 7) + pad("school", 7) + pad("hpoll", 8) + pad("cong", 8)
            + pad("rubble", 7) + pad("trans", 7) + pad("treasury", 10) + "net"

        for size in [MapSize.small.dimension, MapSize.medium.dimension, MapSize.large.dimension] {
            print("\n=== Scorecards, \(size)×\(size) ===")
            print(header)
            for strategy in strategies(size: size) {
                let controller = GameController(map: PlaytestHarness.buildCity(strategy.spec),
                                                rng: SeededRNG(seed: 4242))
                strategy.configure(controller)
                var day = 0
                for checkpoint in checkpoints {
                    while day < checkpoint { controller.advanceSimulation(); day += 1 }
                    let card = CityScorecard.measure(controller.map, population: controller.population)
                    print(row(strategy.name, day, card, controller))
                }
            }
        }
    }

    /// **What scoring the city costs, per tick.** The scorecard runs on every
    /// tick, and a tick is the thing this project has spent the most effort
    /// making cheap — so it is measured on the largest map, settled, and
    /// reported beside the tick it rides on.
    func testWhatMeasuringCosts() throws {
        try XCTSkipUnless(PlaytestHarness.Profile.current == .full,
                          "a timing readout, run with TEST_RUNNER_PLAYTEST_FULL=1")
        let spec = PlaytestHarness.CitySpec(size: MapSize.large.dimension, segregateIndustry: true)
        let controller = GameController(map: PlaytestHarness.buildCity(spec), rng: SeededRNG(seed: 4242))
        for _ in 0 ..< 200 { controller.advanceSimulation() }

        func best(_ work: () -> Void) -> Double {
            (0 ..< 5).map { _ in
                let start = DispatchTime.now().uptimeNanoseconds
                for _ in 0 ..< 10 { work() }
                return Double(DispatchTime.now().uptimeNanoseconds - start) / 10 / 1e6
            }.min() ?? 0
        }
        let scoring = best { _ = CityScorecard.measure(controller.map, population: controller.population) }
        let tick = best { controller.advanceSimulation() }
        print(String(format: "\n⏱  scorecard %.2f ms of a %.2f ms tick (64×64, %.0f%%)\n",
                     scoring, tick, scoring / tick * 100))
    }
}
