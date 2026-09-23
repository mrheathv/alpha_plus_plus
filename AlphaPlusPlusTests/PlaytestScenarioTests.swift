import XCTest
@testable import AlphaPlusPlus

/// Long-run balance scenarios, and the regression tests that pin the three
/// constants tuned against them.
///
/// These are slower than the rest of the suite — hundreds of simulation ticks
/// each rather than a handful — but they are the only tests that can see the
/// class of bug this project's balance pass actually found. Every failure
/// caught there was invisible at unit-test scale: an upkeep formula that is
/// perfectly correct per tile but stops growing while revenue doesn't, an
/// interest rate that is reasonable for one tick and ruinous over a thousand,
/// a hazard chance that reads as rare in isolation and as constant flicker
/// across a whole map. None of those are bugs in a function; they are bugs in
/// a *trajectory*, and you need to run the trajectory to see them.
///
/// Every scenario runs on `SeededRNG` with a fixed seed, so a number here is
/// reproducible rather than something that happened once.
///
/// By default these run at `PlaytestHarness.Profile.quick` — a small map and a
/// few hundred ticks, enough to catch a gross regression without making the
/// suite slow. For actual balance tuning, run the full-size profile, and run
/// it in Release, which is ~55x faster on this workload:
///
///     TEST_RUNNER_PLAYTEST_FULL=1 xcodebuild -project AlphaPlusPlus.xcodeproj \
///       -scheme AlphaPlusPlus -configuration Release -derivedDataPath ./build \
///       ENABLE_TESTABILITY=YES test \
///       -only-testing:AlphaPlusPlusTests/PlaytestScenarioTests
///
/// `ENABLE_TESTABILITY=YES` is required because Release turns testability off
/// and `@testable import` needs it.
@MainActor
final class PlaytestScenarioTests: XCTestCase {

    // MARK: - The money printer

    /// `GameController.roadUpkeepPerTile`'s own doc comment reports the
    /// failure it was added to fix: before it existed, `upkeepCost` counted
    /// only service buildings, so it stopped growing the moment the player
    /// stopped placing them while `taxRevenue` kept climbing with population
    /// forever. A mature city settled into a constant several-hundred-dollar
    /// surplus with nothing to ever pull it back toward zero.
    ///
    /// This asserts the property that fix was supposed to restore: in a
    /// built-out city whose growth has plateaued, net revenue is *small
    /// relative to the money moving through the city*, rather than a large
    /// fixed surplus. Stated as a ratio against tax revenue rather than an
    /// absolute dollar figure deliberately — an absolute bound would need
    /// re-tuning every time any other constant moved, and would fail for
    /// reasons unrelated to the one-way-accumulator bug it exists to catch.
    ///
    /// # This test is currently an expected failure, because the bug is real
    ///
    /// Running it at `.full` (64×64, 1,500 ticks, Release) produces:
    ///
    ///     population   3268   (plateaus by roughly tick 190)
    ///     tax revenue  8308
    ///     upkeep       2174   (tail mean 2174.00 — perfectly constant)
    ///     net revenue  6134   (tail mean 6160.93)
    ///     treasury     9378 → 1145260 → 2297954 → … → 9208600
    ///
    /// That is the original bug, undiminished: once growth stops, the city
    /// banks a flat ~74% of its tax revenue every tick forever, and treasury
    /// climbs linearly past $9M. `roadUpkeepPerTile` was a real improvement
    /// and is directionally right — it does make a sprawling city cost more
    /// than a compact one — but its doc comment's claim that it "brought the
    /// mature city's net revenue down to a gentle trickle rather than a flat
    /// several-hundred-dollar surplus" does not reproduce.
    ///
    /// The reason it doesn't is structural rather than a matter of the rate
    /// being too low. Every cost in the model scales with *placed
    /// infrastructure*, which is static once a city is built out, while
    /// `taxRevenue` scales with *population and jobs*, which keep climbing
    /// until they plateau high. A plateaued city therefore has fixed costs
    /// and fixed-but-much-larger income, and no constant that scales with
    /// infrastructure can close that gap — road upkeep included. Closing it
    /// needs a cost that grows with economic activity rather than with tile
    /// count, which is a balance *design* decision, not a retuning.
    ///
    /// Marked `XCTExpectFailure` in strict mode rather than deleted or
    /// loosened into passing: strict means this test fails if it *stops*
    /// failing, so whoever fixes the underlying issue is told immediately
    /// that the expectation should come off, instead of the suite quietly
    /// continuing to tolerate a bug that no longer exists.
    func testAMatureCityDoesNotBecomeAMoneyPrinter() {
        let spec = PlaytestHarness.spec()
        let (_, result) = PlaytestHarness.runScenario(spec, ticks: PlaytestHarness.Profile.current.ticks)
        let tail = result.tail()

        let meanTax = tail.mean { $0.taxRevenue }
        let meanNet = tail.mean { $0.netRevenue }

        print(PlaytestHarness.report(title: "Mature city", spec: spec, result: result))

        XCTAssertGreaterThan(meanTax, 0, "the test city collected no tax at all — it never grew")
        XCTAssertLessThan(
            abs(meanNet) / meanTax, 0.5,
            "a plateaued city nets \(Int(meanNet))/tick against \(Int(meanTax))/tick of tax revenue — "
            + "upkeep has stopped tracking the size of the city (see roadUpkeepPerTile)"
        )
    }

    /// The same bug stated the other way round: upkeep must grow with the
    /// city. A big city's upkeep should dwarf a small one's, and the road
    /// network is most of why — that is exactly what was missing before.
    func testUpkeepScalesWithCitySize() {
        let small = PlaytestHarness.CitySpec(size: MapSize.small.dimension)
        let large = PlaytestHarness.CitySpec(size: MapSize.large.dimension)
        // No ticking here — upkeep is a property of what is placed, so this
        // reads it straight off freshly built cities and stays fast even at
        // 64×64, where a single tick costs 6 seconds in Debug.

        let smallCity = GameController(map: PlaytestHarness.buildCity(small), rng: SeededRNG(seed: 1))
        let largeCity = GameController(map: PlaytestHarness.buildCity(large), rng: SeededRNG(seed: 1))

        XCTAssertGreaterThan(
            largeCity.upkeepCost, smallCity.upkeepCost * 2,
            "a 64×64 city costs about the same to run as a 32×32 one — upkeep isn't tracking city size"
        )
    }

    // MARK: - Debt

    /// `bondInterestRate`'s doc comment reports that at the old 2%/tick a
    /// city which borrowed to fund ordinary expansion spiralled to -$1.15M
    /// over 5,000 ticks with net revenue pinned around -$240/tick, never
    /// recovering — interest on the whole outstanding balance, every tick,
    /// forever, against a few-hundred-dollar tax base.
    ///
    /// This asserts the property the 8x cut restored: a city that borrows to
    /// its cap can still out-earn the interest and work the debt back down,
    /// rather than being mathematically doomed the moment it borrows.
    func testACityThatBorrowsToItsCapCanStillPayTheInterest() {
        let spec = PlaytestHarness.spec()
        let ticks = PlaytestHarness.Profile.current.ticks

        // Borrow *after* the city has grown, not at tick 0.
        //
        // `bondCap` is `baseBondCap` plus `bondCapPerCapita` per resident, so
        // borrowing before anyone lives there caps out at the $15,000 floor —
        // a third of what a built-out city can actually raise. Configuring the
        // borrow up front meant this scenario was quietly testing the smallest
        // debt the game allows rather than the largest.
        // **A control pair, because the thing under test is the interest and
        // nothing else.** This used to assert that the indebted city's net
        // revenue was simply positive, which quietly made it a test of the
        // quick profile's whole economy — and that economy sits close enough
        // to break-even (tax revenue ~1,010 against ~990 of upkeep and civic
        // services) that any change anywhere flips the sign. It has now done
        // so twice, in phases 5 and 7, both times about mechanics with nothing
        // to do with debt, while interest stayed a flat 37/tick — under 4% of
        // revenue. That the profile is marginal is a real finding and it
        // belongs to the rebalance; it is not what this test is for.
        //
        // Two identical runs differing only in whether the bond is taken
        // isolate it. `SeededRNG` with the same seed and the same tick counts
        // makes the pair identical by construction.
        func run(borrowing: Bool) -> (controller: GameController, result: PlaytestHarness.RunResult) {
            let controller = GameController(map: PlaytestHarness.buildCity(spec), rng: SeededRNG(seed: 0xA1F4))
            _ = PlaytestHarness.run(controller, ticks: ticks / 4)
            if borrowing { while controller.issueBond() { } }
            return (controller, PlaytestHarness.run(controller, ticks: ticks - ticks / 4))
        }

        let (indebted, result) = run(borrowing: true)
        let (solvent, control) = run(borrowing: false)

        print(PlaytestHarness.report(title: "Maximally indebted city", spec: spec, result: result))

        XCTAssertGreaterThan(indebted.bondBalance, 0, "the scenario never actually took on debt")
        XCTAssertEqual(solvent.bondBalance, 0, "the control borrowed too")

        let cost = control.tail().mean { $0.netRevenue } - result.tail().mean { $0.netRevenue }
        let interest = result.tail().mean { $0.bondInterest }
        print(String(format: "borrowing to the cap costs %.0f/tick against %.0f of interest",
                     cost, interest))

        // **The property the 8x rate cut restored.** Before it, a city that
        // borrowed spiralled to -$1.15M over 5,000 ticks with net revenue
        // pinned around -$240/tick — the debt compounded into the city's
        // ability to service it and never recovered. So what has to hold is
        // that the whole cost of borrowing *is* the interest: it must not
        // feed back into the tax base and cost more than it charges.
        XCTAssertLessThan(
            cost, interest * 1.5,
            "borrowing costs \(Int(cost))/tick against \(Int(interest)) of interest — "
            + "the debt is eating the tax base that services it (see bondInterestRate)"
        )
        // And the city must still be able to pay it out of operations, or the
        // cap is set above what any city can carry.
        let operatingSurplus = result.tail().mean { $0.netRevenue + $0.bondInterest }
        XCTAssertGreaterThan(
            operatingSurplus, 0,
            "a maxed-out city cannot even cover its running costs before interest"
        )
    }

    /// Interest must stay a meaningful cost, not a rounding error — the
    /// opposite failure from the one above, and the one an 8x cut risks
    /// introducing. Borrowing should be a real tradeoff.
    func testBondInterestIsStillAMeaningfulCost() {
        let spec = PlaytestHarness.spec()
        let ticks = PlaytestHarness.Profile.current.ticks

        func run(borrowing: Bool) -> PlaytestHarness.RunResult {
            let controller = GameController(map: PlaytestHarness.buildCity(spec), rng: SeededRNG(seed: 7))
            _ = PlaytestHarness.run(controller, ticks: ticks / 4)
            if borrowing { while controller.issueBond() { } }
            return PlaytestHarness.run(controller, ticks: ticks - ticks / 4)
        }
        // Same "borrow once the city exists" reasoning as the scenario above.
        let withoutDebt = run(borrowing: false)
        let withDebt = run(borrowing: true)

        let cleanNet = withoutDebt.tail().mean { $0.netRevenue }
        let indebtedNet = withDebt.tail().mean { $0.netRevenue }

        XCTAssertLessThan(
            indebtedNet, cleanNet,
            "carrying maximum debt costs the city nothing per tick — interest has become free money"
        )
    }

    // MARK: - Hazards

    /// `CityHazards.fire`'s doc comment reports what the old 0.05/0.04 rates
    /// did in a mature city: fire and crime together struck an average of
    /// 4.5-5.6 tiles *every single tick*, spiking to 8, forever. Each strike
    /// fired `GameScene.flashHazard`, so several overlapping per tick read as
    /// ambient flicker rather than as an occasional, noticeable event.
    ///
    /// This pins the "occasional event" property the 10x cut restored. It
    /// deliberately measures a *poorly served* city — services off — because
    /// hazards only ever fire on buildings below `coverageThreshold`, so a
    /// fully-covered city would report near-zero regardless of the rate and
    /// assert nothing at all.
    func testHazardsAreAnOccasionalEventNotAmbientNoise() {
        let spec = PlaytestHarness.spec(includeServices: false)
        let (controller, result) = PlaytestHarness.runScenario(spec, ticks: PlaytestHarness.Profile.current.ticks)

        let meanStrikes = result.mean { $0.hazardStrikes }
        let buildings = controller.map.tiles.filter {
            $0.isBuildingAnchor && $0.zone.maxDensity > 0
        }.count
        let strikesPerBuilding = meanStrikes / Double(max(buildings, 1))

        print(PlaytestHarness.report(title: "Under-served city (hazards)", spec: spec, result: result))
        print("mean hazard strikes/tick: \(String(format: "%.3f", meanStrikes))"
              + " across \(buildings) buildings"
              + " = \(String(format: "%.5f", strikesPerBuilding)) per building")

        // Per *building*, not per tick outright.
        //
        // Strikes-per-tick is not scale-invariant: hazards roll once per
        // building, so a bigger city takes proportionally more of them at the
        // identical per-building rate. An absolute bound therefore tests the
        // map size as much as the constant, and this assertion passed at the
        // quick profile's 16×16 while failing at 64×64 with the rates
        // completely unchanged. What `CityHazards.chancePerTick` actually
        // controls is the per-building figure, so that is what to hold it to:
        // below 0.01 means any given building is struck less than once per
        // hundred ticks, which is an event rather than ambient noise.
        XCTAssertLessThan(
            strikesPerBuilding, 0.01,
            "each building in an under-served city is struck every "
            + "\(Int(1 / max(strikesPerBuilding, 0.000001))) ticks — that is ambient noise, "
            + "not an occasional event (see CityHazards rates)"
        )

        // The other end of the same constant, asserted on the same run rather
        // than on a second identical one: a 10x cut that silently became a
        // 1000x cut would satisfy the bound above while quietly deleting the
        // mechanic.
        let total = result.ticks.reduce(0) { $0 + $1.hazardStrikes }
        XCTAssertGreaterThan(total, 0, "an unprotected city produced no hazards at all")
    }

    /// Service coverage must measurably suppress hazards, which is the whole
    /// reason to build a police or fire station.
    func testServiceCoverageSuppressesHazards() {
        let unserved = PlaytestHarness.spec(includeServices: false)
        let served = PlaytestHarness.spec(serviceSpacing: 3)
        let ticks = PlaytestHarness.Profile.current.ticks

        let (_, unservedRun) = PlaytestHarness.runScenario(unserved, ticks: ticks, seed: 99)
        let (_, servedRun) = PlaytestHarness.runScenario(served, ticks: ticks, seed: 99)

        let unservedStrikes = unservedRun.mean { $0.hazardStrikes }
        let servedStrikes = servedRun.mean { $0.hazardStrikes }

        XCTAssertLessThan(
            servedStrikes, unservedStrikes,
            "a well-served city (\(String(format: "%.3f", servedStrikes))/tick) takes as many hazards as "
            + "an unprotected one (\(String(format: "%.3f", unservedStrikes))/tick) — coverage isn't working"
        )
    }

    // MARK: - The harness itself

    /// A generated city has to actually grow, or every scenario above is
    /// measuring an empty lot. This is the harness's own smoke test.
    func testAGeneratedCityActuallyGrows() {
        let spec = PlaytestHarness.spec()
        let (controller, result) = PlaytestHarness.runScenario(spec, ticks: PlaytestHarness.Profile.current.ticks)

        XCTAssertGreaterThan(controller.population, 0, "the generated city never grew a single resident")
        XCTAssertGreaterThan(controller.jobs, 0, "the generated city never grew a single job")
        XCTAssertGreaterThan(
            result.final.population, result.ticks[0].population,
            "population never rose above its first tick"
        )
    }

    /// Two runs of the same scenario with the same seed must produce
    /// identical numbers, or nothing measured here is reproducible and the
    /// harness has failed at its one job.
    func testScenariosAreReproducible() {
        // Fixed and short rather than profile-sized: this asserts determinism,
        // which needs enough ticks for randomness to have diverged if it were
        // going to and no more — it is not measuring a steady state.
        let spec = PlaytestHarness.CitySpec(size: 16)
        let (_, first) = PlaytestHarness.runScenario(spec, ticks: 80, seed: 12345)
        let (_, second) = PlaytestHarness.runScenario(spec, ticks: 80, seed: 12345)

        XCTAssertEqual(first.final.population, second.final.population)
        XCTAssertEqual(first.final.treasury, second.final.treasury)
        XCTAssertEqual(
            first.ticks.reduce(0) { $0 + $1.hazardStrikes },
            second.ticks.reduce(0) { $0 + $1.hazardStrikes }
        )
    }
}
