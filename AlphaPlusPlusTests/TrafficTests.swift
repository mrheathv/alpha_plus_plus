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

    func testCongestionScalesWithNeighboringDensity() {
        var map = CityMap(width: 3, height: 3)
        let roadPosition = GridPosition(x: 1, y: 1)
        map[roadPosition].zone = .road
        map[GridPosition(x: 0, y: 1)].zone = .residential
        map[GridPosition(x: 0, y: 1)].density = 5 // one neighbor at max density

        // maxPossibleLoad is 4 neighbors * max density 5 = 20; one
        // fully-grown neighbor contributes 5, so congestion = 5/20 = 0.25.
        XCTAssertEqual(Traffic.congestion(at: roadPosition, in: map), 0.25, accuracy: 0.0001)
    }

    func testCongestionCapsAtOneEvenWithMoreLoadThanModeled() {
        // Surround a road on all four sides with maxed-out zones — this is
        // the actual ceiling the model allows for, so it should land at
        // exactly 1.0, not overshoot.
        var map = CityMap(width: 5, height: 5)
        let roadPosition = GridPosition(x: 2, y: 2)
        map[roadPosition].zone = .road
        for neighbor in roadPosition.orthogonalNeighbors() {
            map[neighbor].zone = .commercial
            map[neighbor].density = 5
        }

        XCTAssertEqual(Traffic.congestion(at: roadPosition, in: map), 1.0, accuracy: 0.0001)
    }

    // MARK: - Highway capacity

    /// A `.highway`'s whole reason to exist: the exact same neighboring
    /// load that puts a plain road at 0.25 congestion should put a highway
    /// at half that — it absorbs twice the traffic before feeling it.
    func testHighwayHasHalfTheCongestionOfARoadUnderTheSameLoad() {
        var map = CityMap(width: 3, height: 3)
        let highwayPosition = GridPosition(x: 1, y: 1)
        map[highwayPosition].zone = .highway
        map[GridPosition(x: 0, y: 1)].zone = .residential
        map[GridPosition(x: 0, y: 1)].density = 5

        XCTAssertEqual(Traffic.congestion(at: highwayPosition, in: map), 0.125, accuracy: 0.0001)
    }

    func testHighwayCongestionStillCapsAtOne() {
        var map = CityMap(width: 5, height: 5)
        let highwayPosition = GridPosition(x: 2, y: 2)
        map[highwayPosition].zone = .highway
        for neighbor in highwayPosition.orthogonalNeighbors() {
            map[neighbor].zone = .commercial
            map[neighbor].density = 5
        }

        // Same total load that caps a plain road at 1.0 only reaches half
        // of a highway's doubled capacity.
        XCTAssertEqual(Traffic.congestion(at: highwayPosition, in: map), 0.5, accuracy: 0.0001)
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
