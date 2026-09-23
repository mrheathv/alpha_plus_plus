import XCTest
@testable import AlphaPlusPlus

/// Not a correctness suite — a *design* instrument.
///
/// The question these answer is "does playing well beat playing badly, and by
/// how much." A city builder is only a game if the player's decisions move the
/// outcome; if every strategy converges on the same city, what looks like a
/// game is really just a screensaver with buttons. The harness can settle that
/// empirically: run the same map under different player strategies, and see
/// whether the results actually diverge.
///
/// These print a comparison table rather than asserting much, because the
/// interesting output is the *spread* between strategies, which is a judgement
/// call about game feel rather than a pass/fail. The few assertions that are
/// here pin the floor: that the spread exists at all.
@MainActor
final class DesignPlaytestTests: XCTestCase {

    private struct Strategy {
        let name: String
        var spec: PlaytestHarness.CitySpec
        var configure: (GameController) -> Void = { _ in }
    }

    private struct Outcome {
        let name: String
        let population: Int
        let jobs: Int
        let treasury: Int
        let netRevenue: Double
        let hazards: Double
        let wentBroke: Bool
    }

    private func run(_ strategy: Strategy, ticks: Int) -> Outcome {
        let (controller, result) = PlaytestHarness.runScenario(
            strategy.spec, ticks: ticks, seed: 4242, configure: strategy.configure
        )
        return Outcome(
            name: strategy.name,
            population: controller.population,
            jobs: controller.jobs,
            treasury: controller.treasury,
            netRevenue: result.tail().mean { $0.netRevenue },
            hazards: result.mean { $0.hazardStrikes },
            wentBroke: result.ticks.contains { $0.treasury < 0 }
        )
    }

    private func table(_ outcomes: [Outcome]) -> String {
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
        }
        var lines = [
            pad("strategy", 30) + pad("pop", 8) + pad("jobs", 8)
                + pad("treasury", 12) + pad("net/tick", 11) + pad("hazards", 9) + "broke",
            String(repeating: "-", count: 82),
        ]
        for outcome in outcomes {
            lines.append(
                pad(outcome.name, 30)
                + pad("\(outcome.population)", 8)
                + pad("\(outcome.jobs)", 8)
                + pad("\(outcome.treasury)", 12)
                + pad(String(format: "%.0f", outcome.netRevenue), 11)
                + pad(String(format: "%.2f", outcome.hazards), 9)
                + (outcome.wentBroke ? "YES" : "-")
            )
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Does the layout you draw matter?

    /// Roads, zone mix, services, utilities — the things a player actually
    /// draws on the map. If these don't separate, the building half of the
    /// game is decoration.
    func testLayoutStrategiesDiverge() {
        let size = PlaytestHarness.Profile.current.size
        let ticks = PlaytestHarness.Profile.current.ticks

        let strategies: [Strategy] = [
            Strategy(name: "A. all housing, no jobs", spec: PlaytestHarness.CitySpec(
                size: size, includeUtilities: false, includeServices: false,
                zoneMix: [.residential]
            )),
            Strategy(name: "B. balanced, no infra", spec: PlaytestHarness.CitySpec(
                size: size, includeUtilities: false, includeServices: false
            )),
            Strategy(name: "C. + services", spec: PlaytestHarness.CitySpec(
                size: size, includeUtilities: false, includeServices: true
            )),
            Strategy(name: "D. + water & power", spec: PlaytestHarness.CitySpec(
                size: size, includeUtilities: true, includeServices: true
            )),
            Strategy(name: "E. sparse roads", spec: PlaytestHarness.CitySpec(
                size: size, roadSpacing: 6, includeUtilities: true, includeServices: true
            )),
            Strategy(name: "F. dense services", spec: PlaytestHarness.CitySpec(
                size: size, includeUtilities: true, includeServices: true, serviceSpacing: 3
            )),
        ]

        let outcomes = strategies.map { run($0, ticks: ticks) }
        print("\n=== Layout strategies (\(size)×\(size), \(ticks) ticks) ===")
        print(table(outcomes))

        let populations = outcomes.map(\.population)
        let best = populations.max() ?? 0
        let worst = populations.min() ?? 0
        print("\npopulation spread: \(worst) … \(best)  (\(best == 0 ? 0 : best / max(worst, 1))x)\n")

        XCTAssertGreaterThan(
            best, worst,
            "every layout produced the same population — what the player draws does not matter"
        )
    }

    /// The acceptance test for `Pollution`: does *planning* a layout beat
    /// zoning one homogeneous blob?
    ///
    /// Before pollution existed there was no answer to "why not put the
    /// factory next to the houses," because there was no cost to it at all.
    /// If these two come out level, pollution is not doing its job.
    func testAPlannedLayoutBeatsAHomogeneousBlob() {
        let size = PlaytestHarness.Profile.current.size
        let ticks = PlaytestHarness.Profile.current.ticks

        let mixed = PlaytestHarness.CitySpec(size: size)
        let planned = PlaytestHarness.CitySpec(size: size, segregateIndustry: true)

        let outcomes = [
            run(Strategy(name: "mixed (factories by homes)", spec: mixed), ticks: ticks),
            run(Strategy(name: "planned (industry apart)", spec: planned), ticks: ticks),
        ]
        print("\n=== Planning (\(size)×\(size), \(ticks) ticks) ===")
        print(table(outcomes))
        print("")

        XCTAssertGreaterThan(
            outcomes[1].population, outcomes[0].population,
            "separating industry from housing bought nothing — pollution is not creating a planning problem"
        )
    }

    /// Does utility capacity actually gate a growing city?
    ///
    /// The generated cities in `PlaytestHarness` rotate through five service
    /// types at `serviceSpacing`, which on a 64×64 map leaves roughly nineteen
    /// water towers and nineteen power plants — several times what the city
    /// draws, so capacity never binds there and every other scenario in this
    /// file is unchanged by it. That is a fact about the generator, not about
    /// the mechanic, so this scenario thins the utilities down to what a
    /// player would plausibly build and checks that it bites.
    func testUtilityCapacityGatesGrowth() {
        // Always at least 32×32, whatever the profile. A 16×16 city draws less
        // than a single tower plus a single plant supply, so at the quick
        // profile's size "starved" would not actually be starved and the
        // scenario would assert nothing.
        let size = max(32, PlaytestHarness.Profile.current.size)
        let ticks = PlaytestHarness.Profile.current.ticks

        /// Keeps the first `keep` water towers and power plants, clearing the
        /// rest back to empty land.
        func thinUtilities(_ map: CityMap, keep: Int) -> CityMap {
            var next = map
            for zone in [ZoneType.waterTower, .powerPlant] {
                var kept = 0
                for tile in map.tiles where tile.isBuildingAnchor && tile.zone == zone {
                    kept += 1
                    guard kept > keep else { continue }
                    for cell in map.footprintCells(origin: tile.position, size: zone.footprintSize) {
                        next[cell] = Tile(
                            position: cell,
                            hasPipe: next[cell].hasPipe,
                            hasPowerLine: next[cell].hasPowerLine
                        )
                    }
                }
            }
            return next
        }

        func run(keep: Int) -> (population: Int, overloadedTicks: Int) {
            var spec = PlaytestHarness.spec()
            spec.size = size
            let controller = GameController(
                map: thinUtilities(PlaytestHarness.buildCity(spec), keep: keep),
                rng: SeededRNG(seed: 4242)
            )
            var overloaded = 0
            for _ in 0 ..< ticks {
                controller.advanceSimulation()
                if controller.waterLoad.isOverloaded || controller.powerLoad.isOverloaded {
                    overloaded += 1
                }
            }
            return (controller.population, overloaded)
        }

        let starved = run(keep: 1)
        let ample = run(keep: 99)

        print("\n=== Utility capacity (\(size)×\(size), \(ticks) ticks) ===")
        print("1 tower + 1 plant : population \(starved.population), overloaded on \(starved.overloadedTicks) ticks")
        print("all utilities     : population \(ample.population), overloaded on \(ample.overloadedTicks) ticks")
        print("")

        XCTAssertGreaterThan(
            starved.overloadedTicks, 0,
            "a whole city ran on one water tower and one power plant without ever going over capacity"
        )
        XCTAssertGreaterThan(
            ample.population, starved.population,
            "building more utilities bought no growth — capacity is not gating anything"
        )
    }

    // MARK: - Do the budget dials matter?

    /// Tax rate, funding, ordinances, debt — everything the player sets
    /// without drawing anything. These are a whole toolbar row; if they don't
    /// move the outcome they are dead UI.
    func testBudgetLeversDiverge() {
        let size = PlaytestHarness.Profile.current.size
        let ticks = PlaytestHarness.Profile.current.ticks
        let base = PlaytestHarness.CitySpec(size: size)

        let strategies: [Strategy] = [
            Strategy(name: "default (tax 1.0)", spec: base),
            Strategy(name: "tax 0.0 (no tax at all)", spec: base) { $0.taxRate = 0.0 },
            Strategy(name: "tax 2.0 (double)", spec: base) { $0.taxRate = 2.0 },
            Strategy(name: "all services unfunded", spec: base) { controller in
                for zone in ZoneType.allCases { controller.setFundingLevel(0, for: zone) }
            },
            Strategy(name: "all services 2x funded", spec: base) { controller in
                for zone in ZoneType.allCases { controller.setFundingLevel(2.0, for: zone) }
            },
            Strategy(name: "all ordinances on", spec: base) { controller in
                controller.setOrdinance(\.neighborhoodWatch, active: true)
                controller.setOrdinance(\.fireInspections, active: true)
                controller.setOrdinance(\.businessTaxBreak, active: true)
            },
        ]

        let outcomes = strategies.map { run($0, ticks: ticks) }
        print("\n=== Budget levers (\(size)×\(size), \(ticks) ticks) ===")
        print(table(outcomes))

        let treasuries = outcomes.map(\.treasury)
        print("\ntreasury spread: \(treasuries.min() ?? 0) … \(treasuries.max() ?? 0)\n")

        XCTAssertNotEqual(
            treasuries.min(), treasuries.max(),
            "every budget setting produced the same treasury — the budget row is dead UI"
        )
    }

    // MARK: - How long is the game?

    /// When does a city stop changing?
    ///
    /// Growth is the loop — watching a city fill in is the thing a player is
    /// actually there for. Whatever happens after it plateaus is a static
    /// picture with a treasury counter. So "how many ticks until nothing
    /// changes" is close to "how long is this game," and at
    /// `SimulationSpeed.normal` one tick is one second.
    func testHowLongUntilACityStopsGrowing() {
        let size = PlaytestHarness.Profile.current.size
        let spec = PlaytestHarness.CitySpec(size: size)
        let (_, result) = PlaytestHarness.runScenario(spec, ticks: 600, seed: 4242)

        // Measured against the *peak*, not the final reading. Now that deep
        // oversupply abandons buildings, a city can peak and then decline, and
        // measuring against the final value would report "100% of final" on
        // the way up and call a shrinking city plateaued.
        let peakPopulation = result.ticks.map(\.population).max() ?? 0
        func firstTick(reaching fraction: Double) -> Int? {
            result.ticks.first { Double($0.population) >= Double(peakPopulation) * fraction }?.tick
        }

        print("\n=== Time to plateau (\(size)×\(size)) ===")
        print("peak population: \(peakPopulation), final: \(result.final.population)")
        for fraction in [0.5, 0.9, 0.99, 1.0] {
            let tick = firstTick(reaching: fraction).map(String.init) ?? "never"
            print(String(format: "%3.0f%% of peak population at tick %@", fraction * 100, tick))
        }

        // At normal speed one tick is one second.
        if let ninety = firstTick(reaching: 0.9) {
            print("→ 90% built out after \(ninety) ticks ≈ \(ninety / 60) min \(ninety % 60) s at Normal speed")
        }
        print("")
    }

    // MARK: - Can you actually lose?

    /// A game needs a way to fail. This asks whether any plausible bad play
    /// actually puts a city underwater, or whether the economy is so forgiving
    /// that failure isn't reachable.
    func testCanACityFail() {
        let size = PlaytestHarness.Profile.current.size
        let ticks = PlaytestHarness.Profile.current.ticks
        let base = PlaytestHarness.CitySpec(size: size)

        let strategies: [Strategy] = [
            Strategy(name: "no tax, max debt", spec: base) { controller in
                controller.taxRate = 0
                while controller.issueBond() { }
            },
            Strategy(name: "no tax, 2x funding", spec: base) { controller in
                controller.taxRate = 0
                for zone in ZoneType.allCases { controller.setFundingLevel(2.0, for: zone) }
            },
            Strategy(name: "no tax, everything on", spec: base) { controller in
                controller.taxRate = 0
                for zone in ZoneType.allCases { controller.setFundingLevel(2.0, for: zone) }
                controller.setOrdinance(\.neighborhoodWatch, active: true)
                controller.setOrdinance(\.fireInspections, active: true)
                controller.setOrdinance(\.businessTaxBreak, active: true)
                while controller.issueBond() { }
            },
        ]

        let outcomes = strategies.map { run($0, ticks: ticks) }
        print("\n=== Failure modes (\(size)×\(size), \(ticks) ticks) ===")
        print(table(outcomes))
        print("")
    }
}
