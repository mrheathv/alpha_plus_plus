import XCTest
@testable import AlphaPlusPlus

/// A pipe goes under anything — and, until this, was invisible wherever it did.
///
/// **Reported from play as "you can't put a pipe under a building".** It was
/// never a placement rule: the pipe was laid, it was live, and it supplied
/// water. It simply had nowhere to be *drawn*, because a scene node exists per
/// building rather than per tile, so the three cells of a 2×2 that are not its
/// anchor had no node of their own. A run laid across a block appeared on the
/// bare ground either side and vanished in the middle — and the visible
/// neighbours still drew a stub pointing into the gap, so it read as severed
/// rather than hidden.
@MainActor
final class BuriedUnderBuildingsTests: XCTestCase {

    private let projection = Isometric(tileWidth: 32)

    /// A tower at the left, a 2×2 block in the middle, and bare ground either
    /// side — so a run straight across covers both kinds of tile.
    private func blockOnAStreet() -> CityMap {
        var map = CityMap(width: 20, height: 12)
        for x in 0 ..< 20 { map[GridPosition(x: x, y: 0)].zone = .road }
        // Sitting *on* the run, so the main it feeds is actually connected —
        // and far enough from the block that `directSupplyRadius` cannot
        // supply it, which would make the pipe irrelevant to the test.
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 0, y: 2))
        let home = GridPosition(x: 6, y: 3)
        map.placeBuilding(zone: .residential, origin: home)
        for cell in map.footprintCells(origin: home, size: 2) { map[cell].density = 3 }
        return map
    }

    private let block = GridPosition(x: 6, y: 3)
    private var covered: GridPosition { GridPosition(x: 7, y: 3) }  // not the anchor

    // MARK: - It always worked; it was never drawn

    /// The half that was never broken, pinned so a future "fix" cannot make
    /// it a placement rule by mistake.
    func testAPipeGoesUnderABuildingAndCarriesWater() {
        let controller = GameController(map: blockOnAStreet(), rng: AlwaysZeroRNG(),
                                        peakPopulation: Unlocks.everythingUnlocked)
        for x in 0 ... 8 {
            XCTAssertEqual(controller.layPipe(at: GridPosition(x: x, y: 3)), .placed,
                           "laying pipe at x=\(x) was refused")
        }

        XCTAssertTrue(controller.map[covered].hasPipe)
        XCTAssertFalse(controller.map[covered].isBuildingAnchor, "precondition: this cell has a node")
        XCTAssertTrue(controller.map.waterSupply.isSupplied(at: covered),
                      "a pipe under a building is not part of the network")
        XCTAssertTrue(Water.hasSupply(at: block, in: controller.map))
    }
}
