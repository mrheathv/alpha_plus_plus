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

    /// Prints the trajectory, and asserts the thing the rest of the plan has to
    /// break: an unattended city does not meaningfully decline.
    ///
    /// The assertion is deliberately written the way the game behaves *today*,
    /// so it fails the moment decline mechanics land. That is the point — this
    /// is a tripwire on the current behaviour, not a guarantee of it.
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

        XCTAssertGreaterThan(
            retained, 0.9,
            "An unattended city now declines — which is the goal, so update this tripwire "
            + "to the behaviour you intend rather than deleting it."
        )
    }
}
