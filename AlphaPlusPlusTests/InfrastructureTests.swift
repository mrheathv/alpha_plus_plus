import XCTest
@testable import AlphaPlusPlus

/// Roads, pipes and power lines wearing out — phase 6 of making this a city
/// you manage, and the first thing in the game that makes owning
/// infrastructure an ongoing cost rather than a completed purchase.
@MainActor
final class InfrastructureTests: XCTestCase {

    // MARK: - The rates, on their own

    /// **The balance claim of the whole phase**, checkable without building a
    /// city: full funding covers ordinary wear and does not cover congestion.
    /// If either half of that stopped being true the mechanic would collapse
    /// into one of the two things it exists not to be — a bill with no
    /// decision attached, or a cost no budget can meet.
    func testFundingCoversQuietRoadsAndNotBusyOnes() {
        let repair = Infrastructure.repairPerTick(funding: 1)
        XCTAssertGreaterThan(repair, Infrastructure.wearPerTick(congestion: 0),
                             "a quiet street decays even when fully funded")
        XCTAssertLessThan(repair, Infrastructure.wearPerTick(congestion: 1),
                          "full funding holds a saturated arterial — congestion costs nothing")
    }

    func testMoreFundingRepairsFaster() {
        XCTAssertEqual(Infrastructure.repairPerTick(funding: 0), 0)
        XCTAssertGreaterThan(Infrastructure.repairPerTick(funding: 2),
                             Infrastructure.repairPerTick(funding: 1))
    }

    /// Wear is a fraction of the whole, so the rate has to stay sane for
    /// congestion outside 0…1 — `Traffic.congestion` clamps, but this is the
    /// function's own contract rather than a fact about its one caller.
    func testCongestionOutsideItsRangeDoesNotDistortTheRate() {
        XCTAssertEqual(Infrastructure.wearPerTick(congestion: -5),
                       Infrastructure.wearPerTick(congestion: 0))
        XCTAssertEqual(Infrastructure.wearPerTick(congestion: 5),
                       Infrastructure.wearPerTick(congestion: 1))
    }

    // MARK: - What wears

    func testRoadsPipesAndLinesWearAndBareGroundDoesNot() {
        var tile = Tile(position: GridPosition(x: 0, y: 0))
        XCTAssertFalse(Infrastructure.wears(tile), "bare ground wears out")
        tile.zone = .road
        XCTAssertTrue(Infrastructure.wears(tile))

        var buried = Tile(position: GridPosition(x: 1, y: 0))
        buried.hasPipe = true
        XCTAssertTrue(Infrastructure.wears(buried), "a buried main lasts forever")

        var housing = Tile(position: GridPosition(x: 2, y: 0))
        housing.zone = .residential
        XCTAssertFalse(Infrastructure.wears(housing),
                       "a building wears out — that is what `damagedBy` is for, not this")
    }

    // MARK: - The tick

    private func roadMap(funding: Double) -> CityMap {
        var map = CityMap(width: 6, height: 6)
        for x in 0 ..< 6 { map[GridPosition(x: x, y: 0)].zone = .road }
        map.serviceFunding.setLevel(funding, for: .road)
        return map
    }

    func testAnUnfundedNetworkRotsAndAFundedOneDoesNot() {
        let quiet = GridPosition(x: 3, y: 0)

        var funded = roadMap(funding: 1)
        for _ in 0 ..< 50 { funded = Infrastructure.advance(funded) }
        XCTAssertNil(funded[quiet].wear, "a quiet, fully funded road wore out")

        var neglected = roadMap(funding: 0)
        for _ in 0 ..< 50 { neglected = Infrastructure.advance(neglected) }
        XCTAssertEqual(neglected[quiet].wear ?? 0,
                       Infrastructure.baseWearPerTick * 50, accuracy: 1e-9)
    }

    /// The invariant that keeps `Tile: Equatable` honest: a tile repaired back
    /// to perfect has to compare equal to one that was never worn. `nil` is
    /// the only representation of "as new" — 0 is never stored.
    func testARepairedTileIsIndistinguishableFromANewOne() {
        var map = roadMap(funding: 0)
        for _ in 0 ..< 20 { map = Infrastructure.advance(map) }
        XCTAssertNotNil(map[GridPosition(x: 3, y: 0)].wear, "precondition: nothing wore")

        map.serviceFunding.setLevel(2, for: .road)
        for _ in 0 ..< 200 { map = Infrastructure.advance(map) }

        XCTAssertEqual(map[GridPosition(x: 3, y: 0)], roadMap(funding: 2)[GridPosition(x: 3, y: 0)],
                       "a repaired tile is not equal to a fresh one — wear stored 0 instead of nil")
    }

    func testWearNeverExceedsTotalRuin() {
        var map = roadMap(funding: 0)
        for _ in 0 ..< 2_000 { map = Infrastructure.advance(map) }
        let wear = map[GridPosition(x: 3, y: 0)].wear ?? 0
        XCTAssertEqual(wear, 1, accuracy: 1e-9)
        XCTAssertEqual(Infrastructure.condition(of: map[GridPosition(x: 3, y: 0)]), 0, accuracy: 1e-9)
    }

    /// Traffic is what actually wears a city out, so a road carrying commuters
    /// has to degrade faster than one carrying nobody — on the same map, in
    /// the same tick, with the same budget.
    func testABusyRoadWearsFasterThanAQuietOne() {
        var map = CityMap(width: 14, height: 8)
        // One spine everything routes along, and a stub nothing uses.
        for x in 0 ..< 12 { map[GridPosition(x: x, y: 2)].zone = .road }
        for y in 4 ..< 8 { map[GridPosition(x: 12, y: y)].zone = .road }
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 10, y: 0))
        for cell in map.footprintCells(origin: GridPosition(x: 0, y: 0), size: 2) { map[cell].density = 5 }
        for cell in map.footprintCells(origin: GridPosition(x: 10, y: 0), size: 2) { map[cell].density = 5 }
        map.trafficLoad = Traffic.computeLoad(for: map)

        let busy = GridPosition(x: 5, y: 2)
        let idle = GridPosition(x: 12, y: 6)
        XCTAssertGreaterThan(Traffic.congestion(at: busy, in: map), 0,
                             "precondition: the spine is carrying nothing, so there is nothing to measure")

        map.serviceFunding.setLevel(0, for: .road)
        let next = Infrastructure.advance(map)
        XCTAssertGreaterThan(next[busy].wear ?? 0, next[idle].wear ?? 0,
                             "a commuter route wore no faster than an empty stub")
    }

    // MARK: - What wear does

    func testAWornRoadIsMoreCongestedThanANewOneCarryingTheSameTraffic() {
        var map = CityMap(width: 14, height: 8)
        for x in 0 ..< 12 { map[GridPosition(x: x, y: 2)].zone = .road }
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 10, y: 0))
        for cell in map.footprintCells(origin: GridPosition(x: 0, y: 0), size: 2) { map[cell].density = 5 }
        for cell in map.footprintCells(origin: GridPosition(x: 10, y: 0), size: 2) { map[cell].density = 5 }
        map.trafficLoad = Traffic.computeLoad(for: map)

        let spine = GridPosition(x: 5, y: 2)
        let asNew = Traffic.congestion(at: spine, in: map)
        map[spine].wear = 1
        let ruined = Traffic.congestion(at: spine, in: map)

        XCTAssertGreaterThan(ruined, asNew, "wearing a road out did not cost it any capacity")
        // And the floor holds, which is what keeps the wear/congestion loop
        // recoverable rather than a spiral no budget can reverse.
        XCTAssertEqual(Infrastructure.capacityFraction(of: map[spine]),
                       Infrastructure.ruinedCapacityFraction, accuracy: 1e-9)
    }

    /// A burst main cuts the network exactly where it burst — the player's fix
    /// is the same as for a missing pipe, so the behaviour should be too.
    func testAFailedPipeCutsTheWaterNetwork() {
        var map = CityMap(width: 12, height: 6)
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 0, y: 0))
        for x in 0 ..< 11 { map[GridPosition(x: x, y: 2)].hasPipe = true }
        map[GridPosition(x: 0, y: 1)].hasPipe = true
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 9, y: 3))

        map.waterSupply = Water.computeSupply(for: map)
        XCTAssertTrue(Water.hasSupply(at: GridPosition(x: 9, y: 3), in: map),
                      "precondition: the far end is not connected even before anything fails")

        map[GridPosition(x: 5, y: 2)].wear = Infrastructure.failureWear
        map.waterSupply = Water.computeSupply(for: map)
        XCTAssertFalse(Water.hasSupply(at: GridPosition(x: 9, y: 3), in: map),
                       "a burst main went on carrying water")
    }

    func testAFailedLineCutsTheGrid() {
        var map = CityMap(width: 12, height: 6)
        map.placeBuilding(zone: .generator, origin: GridPosition(x: 0, y: 0))
        for x in 0 ..< 11 { map[GridPosition(x: x, y: 2)].hasPowerLine = true }
        map[GridPosition(x: 0, y: 1)].hasPowerLine = true
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 9, y: 3))

        map.powerSupply = PowerGrid.computeSupply(for: map, outageActive: false)
        XCTAssertTrue(PowerGrid.hasSupply(at: GridPosition(x: 9, y: 3), in: map),
                      "precondition: the far end is not connected even before anything fails")

        map[GridPosition(x: 5, y: 2)].wear = Infrastructure.failureWear
        map.powerSupply = PowerGrid.computeSupply(for: map, outageActive: false)
        XCTAssertFalse(PowerGrid.hasSupply(at: GridPosition(x: 9, y: 3), in: map),
                       "a failed line went on carrying power")
    }

    /// Failure arrives *before* total ruin, so the overlay has a warning band
    /// rather than the player falling off a cliff they cannot see coming.
    func testAConduitFailsBeforeItIsCompletelyRuined() {
        XCTAssertLessThan(Infrastructure.failureWear, 1)
        var tile = Tile(position: GridPosition(x: 0, y: 0))
        tile.hasPipe = true
        tile.wear = Infrastructure.failureWear - 0.01
        XCTAssertFalse(Infrastructure.hasFailed(tile))
        tile.wear = Infrastructure.failureWear
        XCTAssertTrue(Infrastructure.hasFailed(tile))
    }

    // MARK: - The money

    func testThePublicWorksDialChangesWhatTheCityCosts() {
        let controller = GameController(
            map: roadMap(funding: 1),
            rng: AlwaysZeroRNG(),
            peakPopulation: Unlocks.everythingUnlocked
        )
        let atFullFunding = controller.upkeepCost
        XCTAssertGreaterThan(atFullFunding, 0, "precondition: roads cost nothing to own")

        controller.setFundingLevel(0, for: .road)
        XCTAssertEqual(controller.upkeepCost, 0, "defunding public works still charged for it")

        controller.setFundingLevel(2, for: .road)
        XCTAssertEqual(controller.upkeepCost, atFullFunding * 2)
    }

    /// Roads had no dial at all until this phase, so every caller that asked
    /// got the neutral 1.0 — this is the one that would silently go back to
    /// that if the switch in `ServiceFunding` lost its case.
    func testRoadsAndHighwaysShareOneDial() {
        var funding = ServiceFunding()
        funding.setLevel(0.25, for: .road)
        XCTAssertEqual(funding.level(for: .road), 0.25)
        XCTAssertEqual(funding.level(for: .highway), 0.25,
                       "a highway is still a road as far as the public-works budget goes")
        funding.setLevel(0.75, for: .highway)
        XCTAssertEqual(funding.level(for: .road), 0.75)
    }

    // MARK: - Wiring

    func testTheControllerWearsTheNetworkDownAsItTicks() {
        var map = roadMap(funding: 0)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 1))
        let controller = GameController(map: map, rng: AlwaysZeroRNG(),
                                        peakPopulation: Unlocks.everythingUnlocked)
        XCTAssertNil(controller.map[GridPosition(x: 3, y: 0)].wear)

        for _ in 0 ..< 30 { controller.advanceSimulation() }

        XCTAssertNotNil(controller.map[GridPosition(x: 3, y: 0)].wear,
                        "thirty ticks of zero maintenance left the roads untouched")
        XCTAssertGreaterThan(controller.infrastructureWear, 0 - 1e-9)
    }

    func testWearSurvivesASaveRoundTrip() throws {
        var map = roadMap(funding: 0)
        map[GridPosition(x: 3, y: 0)].wear = 0.6
        let controller = GameController(map: map, rng: AlwaysZeroRNG(),
                                        peakPopulation: Unlocks.everythingUnlocked)

        let data = try JSONEncoder().encode(controller.snapshot())
        let decoded = try JSONDecoder().decode(CitySave.self, from: data)
        let restored = GameController(map: CityMap(width: 6, height: 6), rng: AlwaysZeroRNG(),
                                      peakPopulation: Unlocks.everythingUnlocked)
        try restored.restore(from: decoded)

        XCTAssertEqual(restored.map[GridPosition(x: 3, y: 0)].wear, 0.6)
        XCTAssertEqual(restored.map.serviceFunding.level(for: .road), 0)
    }

    /// The meter the cockpit shows: 0 for a new city, rising as things rot.
    func testTheDegradedFractionReportsWhatIsAboutToStopWorking() {
        var map = roadMap(funding: 0)
        XCTAssertEqual(Infrastructure.degradedFraction(in: map), 0)

        for x in 0 ..< 3 { map[GridPosition(x: x, y: 0)].wear = Infrastructure.failureWear }
        XCTAssertEqual(Infrastructure.degradedFraction(in: map), 0.5, accuracy: 1e-9)

        // A city with no infrastructure at all reports 0 rather than dividing
        // by zero — a new map shows an empty bar, not a broken one.
        XCTAssertEqual(Infrastructure.degradedFraction(in: CityMap(width: 4, height: 4)), 0)
    }
}
