import XCTest
@testable import AlphaPlusPlus

/// **The last superlinear term in a tick, measured on the city that has it
/// worst.**
///
/// `Traffic.computeLoad` is three quarters of a simulation step, and within it
/// the transit journey lookup was measured at 46% — found by deleting a city's
/// lines and running it again, which is the only way to attribute a cost to a
/// feature rather than to a function.
///
/// The shape was `O(homes × jobs × reach²)`: a journey pairs every boarding
/// point at the home against every boarding point at the job, once per pair.
/// A job's end of that does not vary with the home, so `TransitGraph.arrivals`
/// collapses it once per job and the per-pair work drops to `O(reach)`.
@MainActor
final class JourneyLookupCostTests: XCTestCase {

    /// Opens Apex, which is the largest and most transit-heavy city this
    /// project ships. Skipped rather than faked where it has not been minted:
    /// a smaller fixture would measure a different problem.
    private func apex() throws -> CityMap {
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Apex has not been minted on this machine")
        }
        return try CitySaveFile.read(from: url).map
    }

    func testMeasureWhatRoutingCosts() throws {
        let map = try apex()
        print("Apex: \(map.transit.routes.count) transit routes")

        // **Best of several batches, not the mean.** Every sample is the true
        // cost plus whatever else the machine was doing, so the distribution
        // has a floor and no ceiling — the same estimator `RenderTimingTests`
        // had to adopt when its first version's noise was larger than its
        // signal.
        var best = Double.greatestFiniteMagnitude
        for _ in 0 ..< 3 {
            let started = Date()
            for _ in 0 ..< 3 { _ = Traffic.computeLoad(for: map) }
            best = min(best, Date().timeIntervalSince(started) / 3 * 1000)
        }
        print(String(format: "Traffic.computeLoad: %.1f ms", best))

        // **Attribute it, in one process, rather than reasoning about it.**
        // The 46% this pass set out to remove came from deleting a city's
        // lines and re-running — which removes far more than the journey
        // lookup: the coverage stamp, the all-pairs graph, and every ride
        // option the lottery would have weighed. Measuring the same way again
        // is what says whether the number ever belonged to the pairing.
        var noLines = map
        for route in map.transit.routes { noLines.transit.remove(id: route.id) }
        var bare = Double.greatestFiniteMagnitude
        for _ in 0 ..< 3 {
            let started = Date()
            for _ in 0 ..< 3 { _ = Traffic.computeLoad(for: noLines) }
            bare = min(bare, Date().timeIntervalSince(started) / 3 * 1000)
        }
        print(String(format: "without any lines drawn: %.1f ms — transit is %.0f%% of routing",
                     bare, (best - bare) / best * 100))

        // **Where the transit half actually goes.** CLAUDE.md asserted, without
        // measuring, that "the graph itself is not where that goes: it is
        // built once per tick over tens of nodes". Checking unmeasured
        // assertions is this project's own habit.
        func time(_ label: String, _ work: () -> Void) {
            var ms = Double.greatestFiniteMagnitude
            for _ in 0 ..< 3 {
                let started = Date()
                for _ in 0 ..< 3 { work() }
                ms = min(ms, Date().timeIntervalSince(started) / 3 * 1000)
            }
            print(String(format: "  %@: %.2f ms", label, ms))
        }
        let stamped = Transit.coverage(for: map)
        time("Transit.coverage") { _ = Transit.coverage(for: map) }
        time("Transit.graph") { _ = Transit.graph(for: map, coverage: stamped) }
        print("  network: \(stamped.nodeCount) (station, line) nodes")

        // And how big the pairing ever was. `reach²` is only a cost if `reach`
        // is more than one or two.
        let coverage = Transit.coverage(for: map)
        var reaches: [Int] = []
        for tile in map.tiles where tile.isBuildingAnchor && tile.zone == .residential {
            let cells = map.footprintCells(origin: tile.position, size: tile.zone.footprintSize)
            reaches.append(coverage.reaches(from: cells).count)
        }
        let mean = reaches.isEmpty ? 0 : Double(reaches.reduce(0, +)) / Double(reaches.count)
        print(String(format: "boarding points per home: mean %.2f, max %d, zero for %d of %d",
                     mean, reaches.max() ?? 0, reaches.filter { $0 == 0 }.count, reaches.count))
        XCTAssertGreaterThan(best, 0)
    }

    /// **The answer has to be identical, not merely close**, and that is the
    /// whole risk of this change.
    ///
    /// `computeLoad` has been non-deterministic here once already — route ties
    /// broken by `Set` iteration order, which is not stable between two sets
    /// holding the same elements, so consecutive calls on one unchanged map
    /// disagreed. Collapsing the journey lookup reorders exactly the loop that
    /// breaks those ties, so it is the same hazard in the same place.
    ///
    /// Apex is used rather than a hand-built fixture for the reason that bug
    /// needed: ties only happen on a map complex enough to produce them.
    func testCollapsingTheLookupLeavesEveryCommuteWhereItWas() throws {
        let map = try apex()
        let first = Traffic.computeLoad(for: map)
        for attempt in 1 ... 3 {
            XCTAssertEqual(Traffic.computeLoad(for: map), first,
                           "run \(attempt) routed the same city differently")
        }
        // Both routes through the code, since the collapse changed the loop
        // that phase one runs and phase two reads.
        let wasThreshold = Traffic.parallelRoutingThreshold
        defer { Traffic.parallelRoutingThreshold = wasThreshold }
        Traffic.parallelRoutingThreshold = .max
        let serial = Traffic.computeLoad(for: map)
        Traffic.parallelRoutingThreshold = 0
        let parallel = Traffic.computeLoad(for: map)
        XCTAssertEqual(serial, parallel,
                       "one core and many disagree about where people work")
        XCTAssertEqual(serial, first)
        print("Apex: \(serial.totalRidership ?? 0) boardings/day")
    }
}
