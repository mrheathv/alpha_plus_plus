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
        let spec = PlaytestHarness.spec()
        let (controller, _) = PlaytestHarness.runScenario(spec, ticks: 0, seed: 4242)
        // Settled, measured rather than guessed. Sixty ticks was plenty when
        // a lot reached full density in five; with construction it is not
        // even enough for one lot to finish, and any fixed number picked
        // instead would be a guess about a staggered, demand-gated city. A
        // city still climbing goes on climbing after you take its power away,
        // which is exactly how a working decline mechanic reads as a broken
        // one: the first attempt here reported a 5% loss because growth was
        // still cancelling most of the decline out.
        let settleTicks = advanceUntilSettled(controller)

        // **Built stock, not population**, and this took a wrong answer to
        // find. Population counts residents only, and the quick profile's
        // settled city keeps its density where the *jobs* are: sixteen
        // industrial lots sit at density 4 against six residential ones. So
        // cutting the power — which caps every lot at
        // `sustainableDensity(hasPower: false)`, i.e. 3 — knocks 14% off the
        // city's total density while moving population by 3%. Reading
        // population alone said "losing a utility costs nothing" about a
        // mechanic that was working correctly the whole time.
        func totalDensity() -> Int {
            controller.map.tiles
                .filter { $0.isBuildingAnchor && $0.zone.maxDensity > 0 }
                .reduce(0) { $0 + $1.density }
        }

        let settled = totalDensity()
        print("\nlosing power: city settled after \(settleTicks) ticks "
              + "at density \(settled), population \(controller.population)")
        for zone in [ZoneType.residential, .commercial, .industrial] {
            var histogram = [Int](repeating: 0, count: 6)
            for tile in controller.map.tiles where tile.isBuildingAnchor && tile.zone == zone {
                histogram[min(5, tile.density)] += 1
            }
            print("  \(zone.rawValue) lots at density 0…5: \(histogram)")
        }
        XCTAssertGreaterThan(settled, 100, "precondition: expected a real city to knock down")

        // Take the grid down by defunding it, and walk away.
        //
        // **Not by bulldozing the plants**, which is what this did first and
        // which measured almost nothing: a power plant carries
        // `LandValue.powerPlantPenaltyStrength` (0.5) over a radius of 8, so
        // demolishing every plant on a 24×24 map lifts a land-value penalty
        // across most of the city at the same moment it cuts the power. Every
        // lot the old land value had capped below density 3 was then free to
        // climb, and that backfill cancelled out almost all of the decline —
        // 3% lost, which reads exactly like "decline does not work".
        //
        // Defunding is the clean instrument: `PowerGrid.computeSupply` returns
        // an empty grid the moment the dial hits zero, the buildings stay
        // where they are, and nothing else about the city moves. The general
        // form of this is already in this file's own history — when a
        // measurement changes, check whether the thing moved or the yardstick
        // did.
        controller.setFundingLevel(0, for: .powerPlant)

        var after10 = 0
        for tick in 1 ... 120 {
            controller.advanceSimulation()
            if tick == 10 { after10 = totalDensity() }
        }
        let after120 = totalDensity()

        print(String(format: "losing power: density %d settled → %d after 10 ticks → %d after 120 (%.0f%% lost)",
                     settled, after10, after120,
                     (1 - Double(after120) / Double(settled)) * 100))

        XCTAssertLessThan(
            after120, Int(Double(settled) * 0.9),
            "a city stripped of power did not shed density — losing a utility should cost something"
        )
        XCTAssertGreaterThan(
            after10, Int(Double(settled) * 0.9),
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
