import XCTest
@testable import AlphaPlusPlus

/// **The parallel router has to agree with the serial one, exactly.**
///
/// `Traffic.computeLoad` is the most expensive function in the game and the
/// one the whole economy reads: congestion feeds land value, land value gates
/// growth, and ridership decides whether a line was worth building. Splitting
/// it across cores is worth doing — it measured 35.7 ms down to 11.0 — and it
/// is worth nothing at all if the answer moves.
///
/// **The ordinary suite cannot check this**, which is the point of a test of
/// its own: the quick playtest profile is a 24×24 city with fewer homes than
/// `parallelRoutingThreshold`, so every scenario test in the project takes the
/// serial path and would pass on a broken parallel one.
@MainActor
final class ParallelRoutingTests: XCTestCase {

    private func bigCity() -> CityMap {
        var spec = PlaytestHarness.CitySpec(size: MapSize.large.dimension)
        spec.segregateIndustry = true
        spec.transitStations = .subway
        spec.drawTransitRoutes = true
        var map = PlaytestHarness.buildCity(spec)
        // Grown, or every lot is at density zero and generates no trips —
        // a city with no traffic in it is the shape of fixture this project
        // keeps catching itself on.
        for _ in 0 ..< 40 {
            var rng = SeededRNG(seed: 11)
            map = CitySimulator.advance(map, using: &rng)
        }
        map.trafficLoad = Traffic.computeLoad(for: map)
        return map
    }

    func testBothRoutesProduceTheSameAnswer() {
        let map = bigCity()
        let homes = map.tiles.filter {
            $0.isBuildingAnchor && $0.zone == .residential && $0.density > 0
        }.count
        XCTAssertGreaterThan(homes, Traffic.parallelRoutingThreshold,
                             "this fixture has \(homes) homes, which would take the serial "
                             + "path either way — it cannot test what it claims to")

        let original = Traffic.parallelRoutingThreshold
        defer { Traffic.parallelRoutingThreshold = original }

        Traffic.parallelRoutingThreshold = Int.max     // force serial
        let serial = Traffic.computeLoad(for: map)
        Traffic.parallelRoutingThreshold = 0           // force parallel
        let parallel = Traffic.computeLoad(for: map)

        XCTAssertEqual(serial, parallel,
                       "the parallel router disagrees with the serial one — every balance "
                       + "number this project has measured is taken on the serial answer")
    }

    /// And the same answer every time, which concurrency is the classic way
    /// to lose. A shared generator, a racy accumulator or an order-dependent
    /// tie-break would all show up here and nowhere else — `computeLoad` has
    /// been non-deterministic once before, from `Set` iteration order, and it
    /// took the harness failing its own reproducibility check to notice.
    func testTheParallelRouteIsReproducible() {
        let map = bigCity()
        let original = Traffic.parallelRoutingThreshold
        defer { Traffic.parallelRoutingThreshold = original }
        Traffic.parallelRoutingThreshold = 0

        let first = Traffic.computeLoad(for: map)
        for run in 2 ... 6 {
            XCTAssertEqual(Traffic.computeLoad(for: map), first,
                           "run \(run) of the parallel router disagreed with run 1")
        }
    }
}
