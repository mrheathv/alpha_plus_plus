import XCTest
@testable import AlphaPlusPlus

/// What is actually *different* about a city at tick 20, 200 and 1500?
///
/// **Why this exists.** `DesignPlaytestTests` measures how far apart different
/// *strategies* end up, and by that measure the game is in good shape — a 33x
/// population spread, real tradeoffs, reachable bankruptcy. But it measures
/// outcomes at the end of a run, which cannot see the thing a play session
/// makes obvious: the city reaches 90% of its final population by **tick 7**
/// and 100% by **tick 16**, then sits perfectly still for the remaining 1,484
/// ticks.
///
/// A city builder that resolves in sixteen ticks is a puzzle you solve once,
/// not a city you manage. Before adding pressure — decline, demand cycles,
/// decay, disasters — this establishes which of the signals the simulation
/// already computes are *alive over time* and which are frozen, so the work
/// goes where the stillness actually is rather than where it is assumed to be.
///
/// The headline number it exists to move is `unattended decline`: what happens
/// to a good city when the player stops touching it. Today, nothing.
@MainActor
final class PlateauDiagnosticTests: XCTestCase {

    private struct Sample {
        let tick: Int
        let population: Int
        let totalDensity: Int
        let meanPollution: Double
        let maxPollution: Double
        let meanCongestion: Double
        let meanLandValue: Double
        let damagedLots: Int
        let demand: (r: Double, c: Double, i: Double)
    }

    private func sample(_ controller: GameController, at tick: Int) -> Sample {
        let map = controller.map
        let distances = ZoneDistanceField.compute(for: map)
        var pollution: [Double] = []
        var congestion: [Double] = []
        var landValue: [Double] = []
        var density = 0
        var damaged = 0

        for y in 0 ..< map.height {
            for x in 0 ..< map.width {
                let position = GridPosition(x: x, y: y)
                let tile = map[position]
                pollution.append(map.pollution.level(at: position))
                if tile.zone == .road || tile.zone == .highway {
                    congestion.append(Traffic.congestion(at: position, in: map))
                }
                guard tile.isBuildingAnchor, tile.zone.maxDensity > 0 else { continue }
                density += tile.density
                if tile.damagedBy != nil { damaged += 1 }
                landValue.append(LandValue.value(at: position, in: map, using: distances))
            }
        }

        func mean(_ values: [Double]) -> Double {
            values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        }

        return Sample(
            tick: tick,
            population: controller.population,
            totalDensity: density,
            meanPollution: mean(pollution),
            maxPollution: pollution.max() ?? 0,
            meanCongestion: mean(congestion),
            meanLandValue: mean(landValue),
            damagedLots: damaged,
            demand: (map.cityDemand.value(for: .residential),
                     map.cityDemand.value(for: .commercial),
                     map.cityDemand.value(for: .industrial))
        )
    }

    /// **The phase-2 promise: neglect has consequences.**
    ///
    /// Build a working city, let it settle, then take its power away and stop
    /// intervening. Before decline landed this did nothing at all — losing
    /// power stalled growth in a city that had finished growing, which is no
    /// consequence whatsoever. The city should now visibly shed density, and
    /// it should do so *gradually*, because the whole point of choosing
    /// recoverable over harsh is that a player who notices has time to act.
    func testLosingPowerMakesACityDecline() {
        // **Two identical cities, one intervention.** Everything else here is
        // held fixed by construction: same spec, same seed, same tick counts,
        // and `RegionalEconomy` is a pure function of elapsed ticks — so the
        // pair see the same weather and differ only in whether the power is on.
        //
        // The single-city version of this measured "the city 120 ticks later",
        // which since phase 5 is the power cut *plus* wherever the regional
        // cycle happened to be, and those are the same size. It reported a 7%
        // loss where a control puts the real figure at more than double that.
        // Third time this file has had to learn it: check whether the thing
        // moved or the yardstick did.
        func settledCity() -> GameController {
            // Weather on: the point of a control pair is that the two cities
            // live in the same world, and a world with weather is the one the
            // player plays in.
            let spec = PlaytestHarness.spec(regionalWeather: true)
            let (controller, _) = PlaytestHarness.runScenario(spec, ticks: 0, seed: 4242)
            // Settled, measured rather than guessed. Sixty ticks was plenty
            // when a lot reached full density in five; with construction it is
            // not even enough for one lot to finish, and any fixed number
            // picked instead would be a guess about a staggered, demand-gated
            // city.
            _ = advanceUntilSettled(controller)
            return controller
        }

        func totalDensity(_ controller: GameController) -> Int {
            controller.map.tiles
                .filter { $0.isBuildingAnchor && $0.zone.maxDensity > 0 }
                .reduce(0) { $0 + $1.density }
        }

        let powered = settledCity()
        let doomed = settledCity()
        XCTAssertEqual(totalDensity(powered), totalDensity(doomed),
                       "precondition: the control and the subject must start identical")

        // **Built stock, not population**, and this took a wrong answer to
        // find. Population counts residents only, and the quick profile's
        // settled city keeps its density where the *jobs* are: sixteen
        // industrial lots at density 4 against six residential ones. Cutting
        // the power caps every lot at `sustainableDensity(hasPower: false)`,
        // i.e. 3 — which moves total density several times as far as it moves
        // population. Reading population alone said "losing a utility costs
        // nothing" about a mechanic that was working correctly the whole time.
        let settled = totalDensity(doomed)
        XCTAssertGreaterThan(settled, 100, "precondition: expected a real city to knock down")
        for zone in [ZoneType.residential, .commercial, .industrial] {
            var histogram = [Int](repeating: 0, count: 6)
            for tile in doomed.map.tiles where tile.isBuildingAnchor && tile.zone == zone {
                histogram[min(5, tile.density)] += 1
            }
            print("  \(zone.rawValue) lots at density 0…5: \(histogram)")
        }

        // Take the grid down by defunding it, and walk away.
        //
        // **Not by bulldozing the plants**, which is what this did first and
        // which measured almost nothing: a power plant carries
        // `LandValue.powerPlantPenaltyStrength` (0.5) over a radius of 8, so
        // demolishing every plant on a 24×24 map lifts a land-value penalty
        // across most of the city at the same moment it cuts the power. Every
        // lot the old land value had capped below density 3 was then free to
        // climb, and that backfill cancelled out almost all of the decline.
        //
        // Defunding is the clean instrument: `PowerGrid.computeSupply` returns
        // an empty grid the moment the dial hits zero, the buildings stay
        // where they are, and nothing else about the city moves.
        doomed.setFundingLevel(0, for: .powerPlant)

        var after10 = 0
        var control10 = 0
        // The tail, not the last tick. Both cities still ride the regional
        // cycle, and a single final reading is one arbitrary point on it —
        // the same reason `PlaytestHarness.report` quotes a tail mean for
        // every steady-state claim it makes.
        var doomedTail: [Int] = []
        var controlTail: [Int] = []
        for tick in 1 ... 240 {
            doomed.advanceSimulation()
            powered.advanceSimulation()
            if tick == 10 {
                after10 = totalDensity(doomed)
                control10 = totalDensity(powered)
            }
            if tick > 180 {
                doomedTail.append(totalDensity(doomed))
                controlTail.append(totalDensity(powered))
            }
        }
        func mean(_ values: [Int]) -> Double {
            Double(values.reduce(0, +)) / Double(values.count)
        }
        let withoutPower = mean(doomedTail)
        let withPower = mean(controlTail)

        print(String(format: "losing power: density %d settled → %d after 10 ticks; "
                     + "tail mean %.0f without power against %.0f with "
                     + "(%.0f%% cost of the outage)",
                     settled, after10, withoutPower, withPower,
                     (1 - withoutPower / withPower) * 100))

        XCTAssertLessThan(
            withoutPower, withPower * 0.9,
            "a city stripped of power ended up no worse than the one that kept it"
        )
        XCTAssertGreaterThan(
            after10, Int(Double(control10) * 0.9),
            "the city collapsed within ten ticks — decline should be gradual enough to notice and fix"
        )
    }

    /// **The phase-3 promise: oversupply empties the worst lots first.**
    ///
    /// Over-zone a city and let it settle, then compare what survived in the
    /// least desirable quarter of its lots against the most desirable quarter.
    /// City-wide demand alone thins a city evenly — every residential lot
    /// feels the same number, so the waterfront tower and the lot wedged
    /// between two factories empty at the same rate, and there is no such
    /// thing as a bad neighbourhood.
    func testOversupplyHitsTheWorstNeighbourhoodsHardest() {
        var spec = PlaytestHarness.spec()
        // Housing everywhere: the classic over-zoning mistake, and the one the
        // design playtest already measures as a losing strategy.
        // 4:1:1 rather than all-housing. A city with *no* jobs does not get
        // oversupplied, it dies — demand pins at the floor and every lot
        // empties regardless of desirability, which is a collapse rather than
        // the uneven decline this is about.
        spec.zoneMix = [.residential, .residential, .residential, .residential, .commercial, .industrial]
        let (controller, _) = PlaytestHarness.runScenario(spec, ticks: 0, seed: 4242)
        for _ in 0 ..< 200 { controller.advanceSimulation() }

        let map = controller.map
        let distances = ZoneDistanceField.compute(for: map)
        var lots: [(landValue: Double, density: Int)] = []
        for y in 0 ..< map.height {
            for x in 0 ..< map.width {
                let position = GridPosition(x: x, y: y)
                let tile = map[position]
                guard tile.isBuildingAnchor, tile.zone.maxDensity > 0 else { continue }
                lots.append((LandValue.value(at: position, in: map, using: distances), tile.density))
            }
        }
        XCTAssertGreaterThan(lots.count, 20, "precondition: expected a real city")

        let sorted = lots.sorted { $0.landValue < $1.landValue }
        let quarter = max(1, sorted.count / 4)
        func meanDensity(_ slice: ArraySlice<(landValue: Double, density: Int)>) -> Double {
            slice.reduce(0.0) { $0 + Double($1.density) } / Double(slice.count)
        }
        let worst = meanDensity(sorted.prefix(quarter))
        let best = meanDensity(sorted.suffix(quarter))

        print(String(format: "\noversupplied city: worst quarter mean density %.2f, best quarter %.2f", worst, best))

        XCTAssertGreaterThan(
            best, worst + 0.5,
            "an oversupplied city thinned evenly — the worst neighbourhoods should empty first"
        )
    }

    /// **The phase-5 promise: the region has weather.**
    ///
    /// Phase 1 measured a settled city moving by 72 people across 1,450 ticks
    /// — a steady state so perfect that nothing the player could watch for
    /// ever changed. Phase 2 gave neglect consequences and barely moved that
    /// number, and the note written then said exactly why: decline fires when
    /// a lot's surroundings degrade, and in a city where nothing changes, they
    /// do not. `RegionalEconomy` is the thing that changes them.
    ///
    /// Measured on built density rather than population, for the reason
    /// `testLosingPowerMakesACityDecline` had to learn: population is one
    /// sector's share of the city, and the region pushes on all three.
    func testTheRegionKeepsASettledCityMoving() {
        let spec = PlaytestHarness.spec(regionalWeather: true)
        let (controller, _) = PlaytestHarness.runScenario(spec, ticks: 0, seed: 4242)
        let settleTicks = advanceUntilSettled(controller)

        func totalDensity() -> Int {
            controller.map.tiles
                .filter { $0.isBuildingAnchor && $0.zone.maxDensity > 0 }
                .reduce(0) { $0 + $1.density }
        }

        // A full sweep of the longest sector cycle (211 ticks) and then some,
        // so the sample is guaranteed to contain a boom and a slump rather
        // than however many happen to fall inside a round number of ticks.
        var densities: [Int] = []
        var moods: Set<RegionalEconomy.Mood> = []
        for _ in 0 ..< 600 {
            controller.advanceSimulation()
            densities.append(totalDensity())
            moods.insert(controller.map.regionalEconomy.mood)
        }

        let low = densities.min() ?? 0
        let high = densities.max() ?? 0
        let swing = Double(high - low) / Double(high)
        print(String(format: "\nregional weather: settled after %d ticks, density ranged %d…%d "
                     + "over 600 ticks (%.0f%% swing)", settleTicks, low, high, swing * 100))

        XCTAssertEqual(moods.count, 3, "the sample did not contain all three regional moods")
        XCTAssertGreaterThan(
            swing, 0.05,
            "a settled city still does not move — the region is not reaching the simulation"
        )
        // And the other end: weather, not catastrophe. A city that loses half
        // its stock to an ordinary downturn is not something a player can plan
        // around, it is something that happens to them.
        XCTAssertLessThan(
            swing, 0.5,
            "an ordinary regional slump gutted the city — this is meant to be weather"
        )
    }

    /// **The phase-6 promise: infrastructure is owned, not bought.**
    ///
    /// A control pair, the same design `testLosingPowerMakesACityDecline`
    /// had to adopt: two identical cities, one of which stops paying for
    /// public works. Everything else — spec, seed, tick counts, the regional
    /// cycle — is common to both, so the gap between them is the maintenance
    /// budget and nothing else.
    ///
    /// Two things have to be true at once for this to be a lever rather than a
    /// tax. Neglect has to *cost* something, or the dial is free money; and
    /// paying has to cost something too, or there is no decision, just a
    /// button you press once.
    func testNeglectingMaintenanceCostsMoreThanItSaves() {
        func city(maintenance: Double) -> GameController {
            let spec = PlaytestHarness.spec(regionalWeather: true)
            let (controller, _) = PlaytestHarness.runScenario(spec, ticks: 0, seed: 4242)
            _ = advanceUntilSettled(controller)
            controller.setFundingLevel(maintenance, for: .road)
            return controller
        }

        func totalDensity(_ controller: GameController) -> Int {
            controller.map.tiles
                .filter { $0.isBuildingAnchor && $0.zone.maxDensity > 0 }
                .reduce(0) { $0 + $1.density }
        }

        let maintained = city(maintenance: 1)
        let neglected = city(maintenance: 0)
        XCTAssertEqual(totalDensity(maintained), totalDensity(neglected),
                       "precondition: the pair must start identical")

        // Long enough for the base wear rate to matter on its own: a quiet
        // road needs 1 / `baseWearPerTick` ticks of total neglect to reach
        // ruin, and the conduits fail at `failureWear` of that.
        let horizon = Int(Infrastructure.failureWear / Infrastructure.baseWearPerTick)
        var maintainedTreasury: [Int] = []
        var neglectedTreasury: [Int] = []
        for tick in 1 ... horizon {
            maintained.advanceSimulation()
            neglected.advanceSimulation()
            if tick > horizon - 60 {
                maintainedTreasury.append(maintained.treasury)
                neglectedTreasury.append(neglected.treasury)
            }
        }

        print(String(format: """

            maintenance over %d ticks:
              funded    density %d, worn %.0f%%, net %+d/tick, treasury %d
              neglected density %d, worn %.0f%%, net %+d/tick, treasury %d
            """,
            horizon,
            totalDensity(maintained), maintained.infrastructureWear * 100,
            maintained.netRevenue, maintainedTreasury.last ?? 0,
            totalDensity(neglected), neglected.infrastructureWear * 100,
            neglected.netRevenue, neglectedTreasury.last ?? 0))

        XCTAssertGreaterThan(
            neglected.infrastructureWear, maintained.infrastructureWear + 0.2,
            "the unfunded city's network is no more worn than the funded one — "
            + "the public-works dial is not reaching `Infrastructure.advance`"
        )
        XCTAssertLessThan(
            totalDensity(neglected), totalDensity(maintained),
            "letting the network rot cost the city nothing — maintenance is a tax, not a lever"
        )
        // And the other half of a decision: paying is not free either. Without
        // this the dial would be one you turn up once and forget, which is the
        // same non-choice a dominant strategy always is.
        XCTAssertGreaterThan(
            maintained.upkeepCost, 0,
            "maintenance costs the funded city nothing"
        )
        // Neglect must not be *strictly* cheaper either. The saving is real —
        // the neglected city stops paying road upkeep entirely — so the test
        // that matters is whether it comes out ahead on money as well as on
        // density. It must not.
        XCTAssertLessThan(
            neglectedTreasury.last ?? 0, maintainedTreasury.last ?? 0,
            "letting the network rot left the city richer — neglect is the dominant strategy"
        )
    }

    /// Prints the trajectory, and pins the shape the plan is aiming at: an
    /// unattended city loses ground, but slowly enough to be rescued.
    ///
    /// This started life as a tripwire on the *old* behaviour — `retained >
    /// 0.9`, asserting that a city left alone never declined — written so it
    /// would fail the moment decline landed. It has now done that job: the
    /// same city retains 89% instead of 100%. The assertion is rewritten
    /// rather than deleted, and it is now two-sided, because both ends matter.
    /// A city that never slips has no reason for the player to stay; a city
    /// that collapses while nobody is looking is a punishment, not a game.
    func testWhatChangesAfterThePlateau() {
        let size = PlaytestHarness.Profile.current.size
        let ticks = PlaytestHarness.Profile.current.ticks
        let spec = PlaytestHarness.spec()
        let (controller, _) = PlaytestHarness.runScenario(spec, ticks: 0, seed: 4242)

        let checkpoints = [10, 20, 50, 100, 200, 500, 1000, ticks].filter { $0 <= ticks }
        var samples: [Sample] = []
        var peak = 0
        var tick = 0
        for checkpoint in checkpoints {
            while tick < checkpoint {
                controller.advanceSimulation()
                peak = max(peak, controller.population)
                tick += 1
            }
            samples.append(sample(controller, at: tick))
        }

        print("\n=== What changes after the plateau (\(size)×\(size)) ===")
        print("tick     pop   density   pollution(mean/max)   congestion   landValue   damaged   demand R/C/I")
        for s in samples {
            print(String(
                format: "%5d  %6d   %7d        %.3f / %.3f          %.3f       %.3f      %4d    %+.2f %+.2f %+.2f",
                s.tick, s.population, s.totalDensity,
                s.meanPollution, s.maxPollution, s.meanCongestion,
                s.meanLandValue, s.damagedLots,
                s.demand.r, s.demand.c, s.demand.i
            ))
        }

        // Which signals are alive after the city has settled? A signal whose
        // spread across the post-plateau checkpoints is ~0 is frozen, and
        // cannot be something the player responds to.
        let settled = samples.filter { $0.tick >= 50 }
        func spread(_ value: (Sample) -> Double) -> Double {
            let values = settled.map(value)
            return (values.max() ?? 0) - (values.min() ?? 0)
        }
        print("\npost-plateau spread (tick 50 onward):")
        print(String(format: "  population   %.0f", spread { Double($0.population) }))
        print(String(format: "  density      %.0f", spread { Double($0.totalDensity) }))
        print(String(format: "  pollution    %.3f", spread(\.meanPollution)))
        print(String(format: "  congestion   %.3f", spread(\.meanCongestion)))
        print(String(format: "  land value   %.3f", spread(\.meanLandValue)))
        print(String(format: "  demand (R)   %.3f", spread { $0.demand.r }))

        let final = samples.last!
        let retained = Double(final.population) / Double(max(peak, 1))
        print(String(format: "\nunattended decline: peak %d → final %d (%.0f%% retained)\n",
                     peak, final.population, retained * 100))

        XCTAssertLessThan(
            retained, 0.98,
            "an unattended city held its peak — neglect is supposed to cost something"
        )
        XCTAssertGreaterThan(
            retained, 0.6,
            "an unattended city fell apart — decline is meant to be recoverable, "
            + "something a player who looks up in time can still fix"
        )
    }
}
