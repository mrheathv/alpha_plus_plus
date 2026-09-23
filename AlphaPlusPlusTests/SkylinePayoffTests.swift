import XCTest
@testable import AlphaPlusPlus

/// **Does level 6 pay off?** A measurement, not a regression test: it
/// prints, and asserts only that the scenario actually reaches level 6.
///
/// The harness's default cities have no subway or rail, so no lot there can
/// reach level 6 (`CitySimulator.rapidTransitRequiredFromLevel`) and every
/// design playtest measures a city without it. This builds one city with a
/// subway network and runs it twice from the same seed: once as the game
/// plays, once with level 6 taken away. The capped run knocks any level-6
/// lot back to 5 after each day (`setDensityForTesting`) rather than
/// changing a constant, so the simulation code is the same in both. It
/// cannot cancel construction, so a capped lot still climbs to 6 about once
/// every 48 days and spends that one day there before it is knocked back: a
/// small bias toward the capped city.
///
/// Opt-in: `TEST_RUNNER_PLAYTEST_FULL=1`, in Release.
@MainActor
final class SkylinePayoffTests: XCTestCase {

    private struct Outcome {
        let name: String
        let population: Int
        let jobs: Int
        let treasury: Int
        let netRevenue: Double
        let lotsAtSix: Int
        let lotsAtFive: Int
    }

    private func run(_ name: String, spec: PlaytestHarness.CitySpec, ticks: Int, capAtFive: Bool) -> Outcome {
        let controller = GameController(map: PlaytestHarness.buildCity(spec), rng: SeededRNG(seed: 0xA1F4))
        var net: [Int] = []
        for _ in 0 ..< ticks {
            controller.advanceSimulation()
            if capAtFive {
                for tile in controller.map.tiles
                where tile.isBuildingAnchor && tile.zone.maxDensity >= 6 && tile.density >= 6 {
                    controller.setDensityForTesting(5, at: tile.position)
                }
            }
            net.append(controller.netRevenue)
        }
        let anchors = controller.map.tiles.filter { $0.isBuildingAnchor && $0.zone.maxDensity > 0 }
        let tail = net.suffix(max(1, ticks / 4))
        return Outcome(name: name, population: controller.population, jobs: controller.jobs,
                       treasury: controller.treasury,
                       netRevenue: Double(tail.reduce(0, +)) / Double(tail.count),
                       lotsAtSix: anchors.filter { $0.density >= 6 }.count,
                       lotsAtFive: anchors.filter { $0.density == 5 }.count)
    }

    func testDoesLevelSixPayOff() throws {
        try XCTSkipUnless(PlaytestHarness.Profile.current == .full, "a full-profile measurement")
        let size = PlaytestHarness.Profile.current.size
        let ticks = PlaytestHarness.Profile.current.ticks
        var results: [Outcome] = []
        for (label, segregate) in [("mixed", false), ("planned", true)] {
            var spec = PlaytestHarness.CitySpec(size: size, segregateIndustry: segregate)
            spec.transitStations = .subway
            spec.drawTransitRoutes = true
            results.append(run("\(label), subway, level 6", spec: spec, ticks: ticks, capAtFive: false))
            results.append(run("\(label), subway, capped at 5", spec: spec, ticks: ticks, capAtFive: true))
        }
        print("\n=== Does level 6 pay off? (\(size)×\(size), \(ticks) days) ===")
        print("scenario                         population   jobs   treasury   net/day   lots@6  lots@5")
        for r in results {
            print(String(format: "%-32@ %10d %6d %10d %9.0f %8d %7d", r.name as NSString, r.population, r.jobs,
                         r.treasury, r.netRevenue, r.lotsAtSix, r.lotsAtFive))
        }
        XCTAssertGreaterThan(results[0].lotsAtSix, 0, "the subway scenario never reached level 6")
    }

    /// **Why planning stopped winning.** Bisecting the planning scenario put
    /// the change at c29b639, which made roads, pipes and lines wear out
    /// with traffic. The hypothesis: separating industry lengthens every
    /// commute, so a planned city loads, and wears out, its streets harder.
    /// This reports the evidence on today's code rather than asserting it.
    func testWhyPlanningStoppedWinning() throws {
        try XCTSkipUnless(PlaytestHarness.Profile.current == .full, "a full-profile measurement")
        let size = PlaytestHarness.Profile.current.size
        let ticks = PlaytestHarness.Profile.current.ticks
        print("\n=== Wear and congestion, planned vs mixed (\(size)×\(size), \(ticks) days) ===")
        print("layout     population  mean road wear  roads worn out  conduits failed  mean congestion  commute min")
        for (label, segregate) in [("mixed", false), ("planned", true)] {
            let spec = PlaytestHarness.CitySpec(size: size, segregateIndustry: segregate)
            let controller = GameController(map: PlaytestHarness.buildCity(spec), rng: SeededRNG(seed: 0xA1F4))
            _ = PlaytestHarness.run(controller, ticks: ticks)
            let map = controller.map
            let roads = map.tiles.filter { $0.zone == .road || $0.zone == .highway }
            let wear = roads.map { $0.wear ?? 0 }
            let conduits = map.tiles.filter { $0.hasPipe || $0.hasPowerLine }
            let failed = conduits.filter { ($0.wear ?? 0) >= Infrastructure.failureWear }.count
            let congestion = roads.map { Traffic.congestion(at: $0.position, in: map) }
            let commutes = map.tiles.compactMap { map.trafficLoad.commute(at: $0.position)?.minutes }
            print(String(format: "%-10@ %10d %15.2f %15d %16d %16.3f %12.1f", label as NSString, controller.population,
                         wear.reduce(0, +) / Double(max(1, wear.count)),
                         wear.filter { $0 >= Infrastructure.failureWear }.count, failed,
                         congestion.reduce(0, +) / Double(max(1, congestion.count)),
                         commutes.isEmpty ? 0 : commutes.reduce(0, +) / Double(commutes.count)))
        }
    }
}
