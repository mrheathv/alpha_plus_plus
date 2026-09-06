import XCTest
@testable import AlphaPlusPlus

/// `CityMap` is the one place row/column arithmetic happens (`index = y *
/// width + x`), so these tests deliberately use a non-square map — a bug
/// that swapped `x` and `y` would still pass on a 20x20 map by coincidence,
/// but not on a 3x5 one.
final class CityMapTests: XCTestCase {

    func testEveryTileStartsEmptyAtItsOwnPosition() {
        let map = CityMap(width: 3, height: 5)
        for y in 0 ..< 5 {
            for x in 0 ..< 3 {
                let position = GridPosition(x: x, y: y)
                XCTAssertEqual(map[position].position, position)
                XCTAssertEqual(map[position].zone, .empty)
            }
        }
    }

    func testSubscriptSetOnlyChangesTheTargetedTile() {
        var map = CityMap(width: 3, height: 5)
        let target = GridPosition(x: 2, y: 0)
        map[target].zone = .residential

        XCTAssertEqual(map[target].zone, .residential)
        // A neighbor sharing the same x but a different y must be untouched —
        // this is exactly what a row/column mix-up in `index(of:)` would break.
        XCTAssertEqual(map[GridPosition(x: 2, y: 1)].zone, .empty)
    }

    func testContainsRespectsBothDimensionsIndependently() {
        let map = CityMap(width: 3, height: 5)
        XCTAssertTrue(map.contains(GridPosition(x: 0, y: 0)))
        XCTAssertTrue(map.contains(GridPosition(x: 2, y: 4)))
        // Width and height differ (3 vs 5), so a swapped-axis bug would let
        // one of these two slip through as "contained".
        XCTAssertFalse(map.contains(GridPosition(x: 3, y: 0)))
        XCTAssertFalse(map.contains(GridPosition(x: 0, y: 5)))
        XCTAssertFalse(map.contains(GridPosition(x: -1, y: 0)))
    }

    // MARK: - footprintCells

    func testFootprintCellsReturnsTheFullBlockWhenItFits() {
        let map = CityMap(width: 5, height: 5)
        let cells = map.footprintCells(origin: GridPosition(x: 1, y: 1), size: 2)

        XCTAssertEqual(Set(cells), Set([
            GridPosition(x: 1, y: 1), GridPosition(x: 2, y: 1),
            GridPosition(x: 1, y: 2), GridPosition(x: 2, y: 2),
        ]))
    }

    /// All-or-nothing: a footprint that would spill off the map returns
    /// empty rather than the cells that *do* fit — a building either fits
    /// entirely or doesn't get placed at all.
    func testFootprintCellsIsEmptyWhenAnyCellWouldBeOffMap() {
        let map = CityMap(width: 5, height: 5)
        let cells = map.footprintCells(origin: GridPosition(x: 4, y: 4), size: 2) // (5,4) and (4,5) fall outside

        XCTAssertTrue(cells.isEmpty)
    }

    func testFootprintCellsOfSizeOneIsJustTheOriginItself() {
        let map = CityMap(width: 5, height: 5)
        let origin = GridPosition(x: 2, y: 2)
        XCTAssertEqual(map.footprintCells(origin: origin, size: 1), [origin])
    }

    func testPlaceBuildingStampsZoneAndBuildingOriginAcrossTheWholeFootprint() {
        var map = CityMap(width: 5, height: 5)
        let origin = GridPosition(x: 1, y: 1)

        map.placeBuilding(zone: .residential, origin: origin)

        for cell in map.footprintCells(origin: origin, size: 2) {
            XCTAssertEqual(map[cell].zone, .residential)
            XCTAssertEqual(map[cell].buildingOrigin, origin)
        }
    }
}
