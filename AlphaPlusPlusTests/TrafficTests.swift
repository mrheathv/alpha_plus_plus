import XCTest
@testable import AlphaPlusPlus

final class TrafficTests: XCTestCase {

    func testNonRoadTilesHaveNoCongestionRegardlessOfNeighbors() {
        var map = CityMap(width: 3, height: 3)
        map[GridPosition(x: 0, y: 0)].zone = .residential
        map[GridPosition(x: 0, y: 0)].density = 5
        map[GridPosition(x: 1, y: 0)].zone = .residential
        map[GridPosition(x: 1, y: 0)].density = 5

        // Congestion describes road capacity, not general activity —
        // checking it on a non-road tile should read 0, not "how busy is
        // the neighborhood."
        XCTAssertEqual(Traffic.congestion(at: GridPosition(x: 0, y: 0), in: map), 0)
    }

    func testEmptyRoadHasNoCongestion() {
        var map = CityMap(width: 3, height: 3)
        map[GridPosition(x: 1, y: 1)].zone = .road
        XCTAssertEqual(Traffic.congestion(at: GridPosition(x: 1, y: 1), in: map), 0)
    }

    // MARK: - computeLoad: congestion comes from real routed commutes

    /// Builds a straight one-tile-wide road from `x: 0` to `x: roadLength - 1`
    /// along `y: 0`, with one residential building fronting it at the left
    /// end and one commercial building (the only job in town) fronting it
    /// at the right end — the minimal real "someone commutes along this
    /// street to work" scenario every test in this section routes through.
    private func straightCommuteMap(roadLength: Int, residentialDensity: Int, commercialDensity: Int = 1) -> CityMap {
        var map = CityMap(width: roadLength, height: 3)
        for x in 0 ..< roadLength {
            map[GridPosition(x: x, y: 0)].zone = .road
        }
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 1))
        map[GridPosition(x: 0, y: 1)].density = residentialDensity
        map[GridPosition(x: 1, y: 1)].density = residentialDensity
        map.placeBuilding(zone: .commercial, origin: GridPosition(x: roadLength - 2, y: 1))
        map[GridPosition(x: roadLength - 2, y: 1)].density = commercialDensity
        map[GridPosition(x: roadLength - 1, y: 1)].density = commercialDensity
        return map
    }

    func testCongestionReflectsTheDensityOfARealRoutedCommute() {
        var map = straightCommuteMap(roadLength: 6, residentialDensity: 5)
        map.trafficLoad = Traffic.computeLoad(for: map)

        // capacityPerRoadTile is 40; one fully-grown home's whole commute
        // routes through every tile of this one-street town, so each of
        // them carries load 5 -> congestion 5/40 = 0.125.
        XCTAssertEqual(Traffic.congestion(at: GridPosition(x: 2, y: 0), in: map), 0.125, accuracy: 0.0001)
    }

    /// The scenario the whole rewrite exists to prove: one street serving
    /// two separate houses on the way to one shop carries *both* commutes
    /// on the segment they share, without the houses needing to connect to
    /// each other — only to the street.
    func testTwoHousesSharingOneStreetToTheSameJobAddTheirLoadOnTheSharedSegment() {
        var map = CityMap(width: 14, height: 3)
        for x in 0 ..< 14 {
            map[GridPosition(x: x, y: 0)].zone = .road
        }
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 1))
        map[GridPosition(x: 0, y: 1)].density = 3
        map[GridPosition(x: 1, y: 1)].density = 3
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 4, y: 1))
        map[GridPosition(x: 4, y: 1)].density = 4
        map[GridPosition(x: 5, y: 1)].density = 4
        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 9, y: 1))
        map[GridPosition(x: 9, y: 1)].density = 1
        map[GridPosition(x: 10, y: 1)].density = 1

        map.trafficLoad = Traffic.computeLoad(for: map)

        // (7,0) sits between the second house and the shop -- on *both*
        // commutes -- so it carries the sum, 3 + 4 = 7.
        XCTAssertEqual(map.trafficLoad.load(at: GridPosition(x: 7, y: 0)), 7)
        // (2,0) sits between the first house and the second -- only the
        // first house's commute passes it, not both.
        XCTAssertEqual(map.trafficLoad.load(at: GridPosition(x: 2, y: 0)), 3)
    }

    func testNoLoadAnywhereWhenNoJobIsReachable() {
        var map = CityMap(width: 6, height: 3)
        for x in 0 ..< 6 { map[GridPosition(x: x, y: 0)].zone = .road }
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 1))
        map[GridPosition(x: 0, y: 1)].density = 5
        map[GridPosition(x: 1, y: 1)].density = 5
        // No commercial or industrial anywhere -- nobody has anywhere to commute to.

        let load = Traffic.computeLoad(for: map)

        for x in 0 ..< 6 {
            XCTAssertEqual(load.load(at: GridPosition(x: x, y: 0)), 0)
        }
    }

    /// A home with only transit access -- no road touching it at all --
    /// generates zero road load, even parked right next to a busy road
    /// elsewhere: it has nothing to route from.
    func testResidentialWithOnlyTransitAccessGeneratesNoRoadLoad() {
        var map = CityMap(width: 6, height: 6) // tall enough for a second, unrelated building below
        for x in 0 ..< 6 { map[GridPosition(x: x, y: 0)].zone = .road }
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 1))
        map[GridPosition(x: 0, y: 1)].density = 5
        map[GridPosition(x: 1, y: 1)].density = 5
        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 4, y: 1))
        map[GridPosition(x: 4, y: 1)].density = 1
        map[GridPosition(x: 5, y: 1)].density = 1
        // A second home reachable only by subway, with no road frontage.
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 3))
        map[GridPosition(x: 0, y: 3)].density = 5
        map[GridPosition(x: 1, y: 3)].density = 5
        map[GridPosition(x: 2, y: 3)].zone = .subway

        map.trafficLoad = Traffic.computeLoad(for: map)

        // Every tile's load still comes only from the road-connected home's
        // commute (which reaches the commercial's nearer frontage column at
        // x=4, never needing to cross x=0 or x=5); the transit-only home
        // contributed nothing anywhere.
        var total = 0
        for x in 0 ..< 6 { total += map.trafficLoad.load(at: GridPosition(x: x, y: 0)) }
        XCTAssertEqual(total, 5 * 4) // x=1 through x=4
    }

    func testCongestionCapsAtOneEvenWithLoadWellPastCapacity() {
        // Nine separate homes funnel down one shared street to the same
        // single shop -- 9 * 5 = 45 routed trips through the tile right
        // outside the shop, well past the 40-per-tile *road* capacity.
        // The shop itself is fully built (density 5, so job capacity
        // 5 * 10 = 50) specifically so every trip actually routes there —
        // this test is about the road's ceiling, not the job's, which
        // `testASaturatedJobRedirectsOverflowToTheNextNearestJobWithRoom`
        // below covers on its own.
        var map = CityMap(width: 22, height: 3)
        for x in 0 ..< 22 { map[GridPosition(x: x, y: 0)].zone = .road }
        for house in 0 ..< 9 {
            let origin = GridPosition(x: house * 2, y: 1)
            map.placeBuilding(zone: .residential, origin: origin)
            map[origin].density = 5
            map[GridPosition(x: origin.x + 1, y: origin.y)].density = 5
        }
        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 20, y: 1))
        map[GridPosition(x: 20, y: 1)].density = 5
        map[GridPosition(x: 21, y: 1)].density = 5

        map.trafficLoad = Traffic.computeLoad(for: map)

        XCTAssertEqual(Traffic.congestion(at: GridPosition(x: 19, y: 0), in: map), 1.0, accuracy: 0.0001)
    }

    // MARK: - Spreading commutes across multiple job sites

    /// The behavior this whole mechanic exists for: once the nearest job
    /// runs out of room, the next home in line routes past it to the
    /// *next*-nearest job with capacity, instead of every home in reach
    /// piling onto the one closest job regardless of how small it is.
    func testASaturatedJobRedirectsOverflowToTheNextNearestJobWithRoom() {
        var map = CityMap(width: 20, height: 3)
        for x in 0 ..< 20 { map[GridPosition(x: x, y: 0)].zone = .road }

        // Three fully-grown homes (density 5 each, commute weight 15
        // total) upstream of a small shop whose capacity (density 1 * 10
        // = 10) only covers the first two.
        for x in [0, 3, 6] {
            let origin = GridPosition(x: x, y: 1)
            map.placeBuilding(zone: .residential, origin: origin)
            map[origin].density = 5
            map[GridPosition(x: origin.x + 1, y: origin.y)].density = 5
        }
        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 10, y: 1)) // the near, small job
        map[GridPosition(x: 10, y: 1)].density = 1
        map[GridPosition(x: 11, y: 1)].density = 1
        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 17, y: 1)) // the far, roomy job
        map[GridPosition(x: 17, y: 1)].density = 5
        map[GridPosition(x: 18, y: 1)].density = 5

        map.trafficLoad = Traffic.computeLoad(for: map)

        // Every commute -- whichever job it ends at -- passes this tile,
        // since it sits before both jobs: all 15 units of demand are
        // accounted for somewhere, nobody silently vanished.
        XCTAssertEqual(map.trafficLoad.load(at: GridPosition(x: 8, y: 0)), 15)
        // Strictly between the two jobs, only the third (overflow) home's
        // commute continues -- the first two homes' trips ended at the
        // near job and never reach this tile.
        XCTAssertEqual(map.trafficLoad.load(at: GridPosition(x: 14, y: 0)), 5)
    }

    /// The other half of the same behavior: if every reachable job is
    /// already full, a home generates no commute at all, the same as if
    /// no job existed in the first place
    /// (`testNoLoadAnywhereWhenNoJobIsReachable`) -- it doesn't force
    /// itself onto an already-saturated job just because nothing else is
    /// in range.
    func testNoLoadAnywhereWhenEveryReachableJobIsAtCapacity() {
        var map = CityMap(width: 8, height: 3)
        for x in 0 ..< 8 { map[GridPosition(x: x, y: 0)].zone = .road }
        // Three homes (density 5 each) upstream of one small shop --
        // capacity 1 * 10 = 10 covers exactly the first two.
        for x in [0, 2, 4] {
            let origin = GridPosition(x: x, y: 1)
            map.placeBuilding(zone: .residential, origin: origin)
            map[origin].density = 5
            map[GridPosition(x: origin.x + 1, y: origin.y)].density = 5
        }
        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 6, y: 1))
        map[GridPosition(x: 6, y: 1)].density = 1
        map[GridPosition(x: 7, y: 1)].density = 1

        map.trafficLoad = Traffic.computeLoad(for: map)

        // (5,0) is the last tile before the shop's own frontage -- every
        // successful commute passes through it regardless of which house
        // it started from, so its load is exactly the two houses that fit
        // (5 + 5), not the third that found no job with room left and
        // contributed nothing. (Checking a sum across every tile instead
        // would double- and triple-count each house's commute once per
        // tile of road it crosses, which isn't what "at capacity" means.)
        XCTAssertEqual(map.trafficLoad.load(at: GridPosition(x: 5, y: 0)), 10)
    }

    // MARK: - Highway capacity

    /// A `.highway`'s whole reason to exist: the exact same routed load
    /// that puts a plain road at 0.125 congestion should put a highway at
    /// half that — it absorbs twice the traffic before feeling it.
    func testHighwayHasHalfTheCongestionOfARoadUnderTheSameLoad() {
        var roadMap = straightCommuteMap(roadLength: 6, residentialDensity: 5)
        roadMap.trafficLoad = Traffic.computeLoad(for: roadMap)

        var highwayMap = roadMap
        for x in 0 ..< 6 { highwayMap[GridPosition(x: x, y: 0)].zone = .highway }
        highwayMap.trafficLoad = Traffic.computeLoad(for: highwayMap)

        let roadCongestion = Traffic.congestion(at: GridPosition(x: 2, y: 0), in: roadMap)
        let highwayCongestion = Traffic.congestion(at: GridPosition(x: 2, y: 0), in: highwayMap)
        XCTAssertEqual(highwayCongestion, roadCongestion / 2, accuracy: 0.0001)
    }

    /// The same 45-routed-trip load that fully caps a plain road at 1.0
    /// (`testCongestionCapsAtOneEvenWithLoadWellPastCapacity`) should
    /// leave a highway short of capacity, not also pinned at the ceiling.
    func testHighwaysDoubledCapacityKeepsTheSameLoadBelowAFullCap() {
        var map = CityMap(width: 22, height: 3)
        for x in 0 ..< 22 { map[GridPosition(x: x, y: 0)].zone = .highway }
        for house in 0 ..< 9 {
            let origin = GridPosition(x: house * 2, y: 1)
            map.placeBuilding(zone: .residential, origin: origin)
            map[origin].density = 5
            map[GridPosition(x: origin.x + 1, y: origin.y)].density = 5
        }
        // Fully built (density 5, job capacity 50) so all 45 trips
        // actually route here -- see the matching comment on
        // testCongestionCapsAtOneEvenWithLoadWellPastCapacity.
        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 20, y: 1))
        map[GridPosition(x: 20, y: 1)].density = 5
        map[GridPosition(x: 21, y: 1)].density = 5

        map.trafficLoad = Traffic.computeLoad(for: map)

        XCTAssertEqual(Traffic.congestion(at: GridPosition(x: 19, y: 0), in: map), 0.5625, accuracy: 0.0001)
    }

    /// A subway stop moves people without adding load to any road — it
    /// should report no congestion of its own even sitting in the thick of
    /// dense development, the same as `.publicTransit` already does.
    func testSubwayHasNoCongestionOfItsOwn() {
        var map = CityMap(width: 3, height: 3)
        let subwayPosition = GridPosition(x: 1, y: 1)
        map[subwayPosition].zone = .subway
        for neighbor in subwayPosition.orthogonalNeighbors() {
            map[neighbor].zone = .commercial
            map[neighbor].density = 5
        }

        XCTAssertEqual(Traffic.congestion(at: subwayPosition, in: map), 0)
    }

    /// A highway neighbor must count as a "road neighbor" for orientation
    /// purposes exactly like a plain road would.
    func testIsHorizontallyOrientedCountsHighwayNeighborsLikeRoad() {
        var map = CityMap(width: 3, height: 3)
        let position = GridPosition(x: 1, y: 1)
        map[GridPosition(x: 0, y: 1)].zone = .highway
        map[GridPosition(x: 2, y: 1)].zone = .road

        XCTAssertTrue(Traffic.isHorizontallyOriented(at: position, in: map))
    }

    // MARK: - carCount

    func testCarCountIsZeroWhenCongestionIsZero() {
        XCTAssertEqual(Traffic.carCount(forCongestion: 0), 0)
    }

    func testCarCountRisesInStepsWithCongestion() {
        XCTAssertEqual(Traffic.carCount(forCongestion: 0.1), 1)
        XCTAssertEqual(Traffic.carCount(forCongestion: 0.33), 1)
        XCTAssertEqual(Traffic.carCount(forCongestion: 0.34), 2)
        XCTAssertEqual(Traffic.carCount(forCongestion: 0.66), 2)
        XCTAssertEqual(Traffic.carCount(forCongestion: 0.67), 3)
        XCTAssertEqual(Traffic.carCount(forCongestion: 1.0), 3)
    }

    // MARK: - isHorizontallyOriented

    func testIsHorizontallyOrientedWhenRoadsAreLeftAndRight() {
        var map = CityMap(width: 3, height: 3)
        let position = GridPosition(x: 1, y: 1)
        map[GridPosition(x: 0, y: 1)].zone = .road
        map[GridPosition(x: 2, y: 1)].zone = .road

        XCTAssertTrue(Traffic.isHorizontallyOriented(at: position, in: map))
    }

    func testIsNotHorizontallyOrientedWhenRoadsAreOnlyVertical() {
        var map = CityMap(width: 3, height: 3)
        let position = GridPosition(x: 1, y: 1)
        map[GridPosition(x: 1, y: 0)].zone = .road
        map[GridPosition(x: 1, y: 2)].zone = .road

        XCTAssertFalse(Traffic.isHorizontallyOriented(at: position, in: map))
    }

    /// Ties (an isolated stub with no road neighbors at all, or a 4-way
    /// intersection with both) default to horizontal.
    func testIsHorizontallyOrientedDefaultsTrueOnATieOrNoNeighbors() {
        let isolated = CityMap(width: 3, height: 3)
        XCTAssertTrue(Traffic.isHorizontallyOriented(at: GridPosition(x: 1, y: 1), in: isolated))

        var intersection = CityMap(width: 3, height: 3)
        let position = GridPosition(x: 1, y: 1)
        for neighbor in position.orthogonalNeighbors() {
            intersection[neighbor].zone = .road
        }
        XCTAssertTrue(Traffic.isHorizontallyOriented(at: position, in: intersection))
    }
}
