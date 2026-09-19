import XCTest
@testable import AlphaPlusPlus

/// The shape of the land a city is founded on.
@MainActor
final class TerrainTests: XCTestCase {

    private func generated(_ terrain: Terrain, size: Int = 48, seed: UInt64 = 7) -> CityMap {
        var map = CityMap(width: size, height: size)
        TerrainGenerator.apply(terrain, to: &map, seed: seed)
        return map
    }

    private func waterFraction(_ map: CityMap) -> Double {
        Double(map.tiles.filter(\.isWater).count) / Double(map.width * map.height)
    }

    // MARK: - What each shape produces

    /// Flat is exactly what the game did before terrain existed, which is
    /// what makes this a choice rather than a change forced on every city.
    func testFlatLeavesTheMapDry() {
        XCTAssertEqual(waterFraction(generated(.flat)), 0)
    }

    /// Every shape has to leave a city's worth of buildable ground. Water is
    /// meant to take some away, not to hand back a smaller map.
    func testEveryShapeLeavesMostOfTheMapBuildable() {
        for terrain in Terrain.allCases where terrain != .flat {
            for seed in UInt64(1) ... 12 {
                let fraction = waterFraction(generated(terrain, seed: seed))
                XCTAssertGreaterThan(fraction, 0.01,
                                     "\(terrain.displayName) seed \(seed) produced no water at all")
                XCTAssertLessThan(fraction, 0.35,
                                  "\(terrain.displayName) seed \(seed) drowned the map")
            }
        }
    }

    /// The same seed has to give the same map, for the reason
    /// `RegionalEconomy` is a clock rather than a dice roll — and so a player
    /// who likes a coastline can get it back.
    func testTheSameSeedGivesTheSameCoastline() {
        for terrain in Terrain.allCases {
            let first = generated(terrain, seed: 42)
            let second = generated(terrain, seed: 42)
            XCTAssertEqual(first.tiles.map(\.isWater), second.tiles.map(\.isWater),
                           "\(terrain.displayName) is not reproducible from its seed")
        }
    }

    func testDifferentSeedsGiveDifferentCoastlines() {
        for terrain in Terrain.allCases where terrain != .flat {
            let first = generated(terrain, seed: 1)
            let second = generated(terrain, seed: 2)
            XCTAssertNotEqual(first.tiles.map(\.isWater), second.tiles.map(\.isWater),
                              "\(terrain.displayName) ignores its seed")
        }
    }

    /// A river is the only shape that is *meant* to cut the map in two — that
    /// is the whole reason it needs bridges. Measured as: no land route from
    /// one side to the other.
    func testARiverSplitsTheMapAndTheOthersDoNot() {
        XCTAssertTrue(isSplit(generated(.river, seed: 5)), "a river left the map in one piece")
        XCTAssertFalse(isSplit(generated(.coastal, seed: 5)), "a coast cut the map in two")
        XCTAssertFalse(isSplit(generated(.lakes, seed: 5)), "a lake cut the map in two")
    }

    /// Lakes stay inland, so a lake and a coast never read as the same thing.
    func testLakesDoNotTouchTheEdge() {
        let map = generated(.lakes, seed: 3)
        for tile in map.tiles where tile.isWater {
            let p = tile.position
            XCTAssertFalse(p.x == 0 || p.y == 0 || p.x == map.width - 1 || p.y == map.height - 1,
                           "a lake reached the map edge at \(p), which is a coast")
        }
    }

    // MARK: - Nothing is built on water

    /// Open water refuses everything, and a main will not swim.
    ///
    /// **Restated rather than relaxed.** This was written before bridges and
    /// listed `.road` among the tools water turns away — which bridges
    /// deliberately made false, so the thing moved and the yardstick had to
    /// follow. It failed in a way worth recording, too: the road *succeeded*,
    /// which turned the tile into a bridge, and the pipe and power
    /// assertions after it then legitimately passed placement. One stale
    /// expectation produced three failures, only one of which was about
    /// itself.
    ///
    /// What roads may do is pinned by `testNothingButARoadCrossesWater` and
    /// `testARoadCrossesWaterAndChargesForTheSpan`; this one keeps the other
    /// half, on a tile nothing is carrying.
    func testOpenWaterRefusesEveryPlacement() {
        var map = CityMap(width: 12, height: 12)
        map[GridPosition(x: 5, y: 5)].isWater = true
        let controller = GameController(map: map, rng: SeededRNG(seed: 1),
                                        peakPopulation: Unlocks.everythingUnlocked)
        for tool in [ZoneType.residential, .policeStation, .park, .waterTower] {
            controller.selectTool(tool)
            XCTAssertEqual(controller.place(at: GridPosition(x: 5, y: 5)), .blocked,
                           "\(tool) was built on water")
        }
        XCTAssertEqual(controller.layPipe(at: GridPosition(x: 5, y: 5)), .blocked)
        XCTAssertEqual(controller.layPowerLine(at: GridPosition(x: 5, y: 5)), .blocked)
    }

    /// A 2×2 building must be refused when *any* of its cells is wet, not
    /// only its anchor.
    func testABuildingIsRefusedIfAnyOfItsCellsIsWet() {
        var map = CityMap(width: 12, height: 12)
        map[GridPosition(x: 6, y: 5)].isWater = true
        let controller = GameController(map: map, rng: SeededRNG(seed: 1),
                                        peakPopulation: Unlocks.everythingUnlocked)
        controller.selectTool(.residential)
        XCTAssertEqual(controller.place(at: GridPosition(x: 5, y: 5)), .blocked,
                       "a building straddled the shoreline")
    }

    // MARK: - Bridges

    /// A channel down the middle of a small map, with a road grid either
    /// side that stops at the bank.
    private func splitTown() -> CityMap {
        var map = CityMap(width: 14, height: 9)
        for y in 0 ..< 9 { map[GridPosition(x: 7, y: y)].isWater = true }
        for x in 0 ..< 14 where x != 7 { map[GridPosition(x: x, y: 4)].zone = .road }
        return map
    }

    private func controller(_ map: CityMap) -> GameController {
        GameController(map: map, rng: SeededRNG(seed: 3),
                       peakPopulation: Unlocks.everythingUnlocked)
    }

    func testARoadCrossesWaterAndChargesForTheSpan() {
        let game = controller(splitTown())
        let before = game.treasury
        game.selectTool(.road)
        XCTAssertEqual(game.place(at: GridPosition(x: 7, y: 4)), .placed,
                       "a road would not bridge the river")
        XCTAssertEqual(before - game.treasury,
                       ZoneType.road.placementCost + (ZoneType.road.bridgeSurcharge ?? 0),
                       "a span cost the same as a street on dry land")
    }

    /// Only roads cross. A river stops being a constraint on where a city can
    /// go the moment anything can be dropped in it.
    func testNothingButARoadCrossesWater() {
        for tool in [ZoneType.residential, .commercial, .industrial, .park,
                     .policeStation, .publicTransit, .waterPump] {
            let game = controller(splitTown())
            game.selectTool(tool)
            XCTAssertEqual(game.place(at: GridPosition(x: 7, y: 4)), .blocked,
                           "\(tool) was built in the river")
        }
    }

    /// A bridge is a road *over* water — the river is still there underneath,
    /// and comes back when the bridge does not.
    func testABridgeDoesNotDryOutTheRiver() {
        let game = controller(splitTown())
        let span = GridPosition(x: 7, y: 4)
        game.selectTool(.road)
        _ = game.place(at: span)
        XCTAssertTrue(game.map[span].isWater, "building a bridge filled in the river")
        XCTAssertEqual(game.map[span].zone, .road)

        game.bulldoze(at: span)
        XCTAssertTrue(game.map[span].isWater, "demolishing a bridge left dry land behind")
        XCTAssertEqual(game.map[span].zone, .empty)
    }

    /// Mains cross under a bridge, never through open water.
    func testAMainFollowsABridgeButDoesNotSwim() {
        let game = controller(splitTown())
        let span = GridPosition(x: 7, y: 2)
        XCTAssertEqual(game.layPipe(at: span), .blocked, "a main was laid across open water")

        game.selectTool(.road)
        _ = game.place(at: span)
        XCTAssertEqual(game.layPipe(at: span), .placed, "a main would not follow a bridge")
        XCTAssertEqual(game.layPowerLine(at: GridPosition(x: 7, y: 3)), .blocked)
    }

    /// **The point of the whole thing.** A river cuts the map in two, so
    /// people on one bank cannot reach work on the other — until something
    /// crosses. Measured through the router rather than asserted about
    /// geometry, because "is there a route" is `Traffic`'s question.
    func testABridgeReconnectsTheTwoBanks() {
        func employed(bridged: Bool) -> Bool {
            var map = splitTown()
            map.placeBuilding(zone: .residential, origin: GridPosition(x: 2, y: 5))
            for cell in map.footprintCells(origin: GridPosition(x: 2, y: 5), size: 2) {
                map[cell].density = 3
            }
            map.placeBuilding(zone: .industrial, origin: GridPosition(x: 10, y: 5))
            for cell in map.footprintCells(origin: GridPosition(x: 10, y: 5), size: 2) {
                map[cell].density = 3
            }
            if bridged { map[GridPosition(x: 7, y: 4)].zone = .road }
            map.trafficLoad = Traffic.computeLoad(for: map)
            return map.trafficLoad.commuteFound(at: GridPosition(x: 2, y: 5)) ?? false
        }

        XCTAssertFalse(employed(bridged: false),
                       "people crossed a river with no bridge on it")
        XCTAssertTrue(employed(bridged: true),
                      "a bridge went in and nobody used it")
    }

    // MARK: - Saves

    /// Water rides as an Optional, so a city saved before terrain existed
    /// loads as dry land rather than failing — no format bump.
    func testACitySavedBeforeTerrainLoadsAsDryLand() throws {
        let dry = CityMap(width: 8, height: 8)
        let data = try JSONEncoder().encode(dry.tiles[0])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("water"),
                       "an all-land tile is writing a water field, so every old save grew one")

        let decoded = try JSONDecoder().decode(Tile.self, from: data)
        XCTAssertFalse(decoded.isWater)
    }

    /// Breadth-first over land only: can the top-left corner reach the
    /// bottom-right without crossing water?
    private func isSplit(_ map: CityMap) -> Bool {
        guard let start = map.tiles.first(where: { !$0.isWater })?.position,
              let goal = map.tiles.last(where: { !$0.isWater })?.position
        else { return false }
        var seen: Set<GridPosition> = [start]
        var queue = [start]
        while let current = queue.popLast() {
            if current == goal { return false }
            for next in current.orthogonalNeighbors()
            where map.contains(next) && !map[next].isWater && !seen.contains(next) {
                seen.insert(next)
                queue.append(next)
            }
        }
        return true
    }
}
