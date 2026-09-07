import XCTest
@testable import AlphaPlusPlus

/// `@MainActor` because `GameController` is itself `@MainActor`-isolated —
/// its whole point is "everything that touches game state runs on the main
/// thread, checked by the compiler," and these tests call its methods
/// directly rather than going through SwiftUI or SpriteKit.
@MainActor
final class GameControllerTests: XCTestCase {

    func testPlaceChargesCostAndSetsZone() {
        let controller = GameController()
        let position = GridPosition(x: 0, y: 0)
        let startingTreasury = controller.treasury

        controller.selectedTool = .residential
        let outcome = controller.place(at: position)

        XCTAssertEqual(outcome, .placed)
        XCTAssertEqual(controller.map[position].zone, .residential)
        XCTAssertEqual(controller.treasury, startingTreasury - ZoneType.residential.placementCost)
    }

    func testPlaceReturnsUnchangedWhenTileAlreadyHasThatZone() {
        let controller = GameController()
        let position = GridPosition(x: 0, y: 0)
        controller.selectedTool = .residential
        controller.place(at: position)

        let outcome = controller.place(at: position)

        XCTAssertEqual(outcome, .unchanged)
    }

    /// Regression test for the drag-to-paint bug this guard was added for:
    /// `mouseDragged` calls `place(at:)` repeatedly while the cursor sits
    /// over one tile. Re-placing the same zone must be a free no-op, or
    /// holding the mouse still would drain the treasury every frame.
    func testPlacingTheSameZoneTwiceOnlyChargesOnce() {
        let controller = GameController()
        let position = GridPosition(x: 0, y: 0)

        controller.selectedTool = .residential
        controller.place(at: position)
        let treasuryAfterFirstPlacement = controller.treasury

        controller.place(at: position)

        XCTAssertEqual(controller.treasury, treasuryAfterFirstPlacement)
    }

    func testPlaceDoesNothingWhenTreasuryCannotCoverTheCost() {
        let controller = GameController()
        // Drain the treasury by placing roads ($50, the cheapest paid zone)
        // across distinct tiles — one per tile so the "same zone twice is
        // free" guard above never masks a real charge — until funds run out.
        // The 20x20 map has 400 tiles and $10,000 / $50 = 200 placements, so
        // this always stops from running out of money, never from running
        // out of tiles.
        controller.selectedTool = .road
        var remainingTiles = controller.map.tiles.map(\.position).makeIterator()
        while controller.treasury >= ZoneType.road.placementCost, let position = remainingTiles.next() {
            controller.place(at: position)
        }
        let treasuryBeforeAttempt = controller.treasury
        let untouched = remainingTiles.next()!

        let outcome = controller.place(at: untouched)

        XCTAssertEqual(outcome, .insufficientFunds)
        XCTAssertEqual(controller.treasury, treasuryBeforeAttempt)
        XCTAssertEqual(controller.map[untouched].zone, .empty)
    }

    func testBulldozeClearsAZoneForFree() {
        let controller = GameController()
        let position = GridPosition(x: 0, y: 0)
        controller.selectedTool = .commercial
        controller.place(at: position)
        let treasuryAfterPlacing = controller.treasury

        controller.bulldoze(at: position)

        XCTAssertEqual(controller.map[position].zone, .empty)
        XCTAssertEqual(controller.treasury, treasuryAfterPlacing)
    }

    func testBulldozeResetsDensity() {
        let controller = GameController(rng: AlwaysZeroRNG()) // guarantees the growth tick below actually grows
        let position = GridPosition(x: 0, y: 0)
        let roadPosition = GridPosition(x: 2, y: 0) // outside residential's (0,0)-(1,1) footprint
        controller.selectedTool = .road
        controller.place(at: roadPosition)
        controller.selectedTool = .residential
        controller.place(at: position)
        controller.advanceSimulation() // grows density to 1

        controller.bulldoze(at: position)

        XCTAssertEqual(controller.map[position].density, 0)
    }

    /// Bulldozing any one cell of a multi-tile building clears the *whole*
    /// building, not just the cell that was clicked.
    func testBulldozingAnyCellOfAFootprintClearsTheWholeBuilding() {
        let controller = GameController()
        let origin = GridPosition(x: 0, y: 0)
        controller.selectedTool = .residential
        controller.place(at: origin) // covers (0,0)-(1,1)
        let farCorner = GridPosition(x: 1, y: 1)

        controller.bulldoze(at: farCorner) // click a non-anchor cell

        for cell in controller.map.footprintCells(origin: origin, size: 2) {
            XCTAssertEqual(controller.map[cell].zone, .empty)
        }
    }

    /// Placing a multi-tile building stamps every cell of its footprint with
    /// the same zone and the same `buildingOrigin`, and costs the treasury
    /// once for the whole building, not once per cell.
    func testPlacingAMultiTileBuildingStampsTheWholeFootprintForOneCost() {
        let controller = GameController()
        let origin = GridPosition(x: 0, y: 0)
        let startingTreasury = controller.treasury
        controller.selectedTool = .residential

        let outcome = controller.place(at: origin)

        XCTAssertEqual(outcome, .placed)
        XCTAssertEqual(controller.treasury, startingTreasury - ZoneType.residential.placementCost)
        for cell in controller.map.footprintCells(origin: origin, size: 2) {
            XCTAssertEqual(controller.map[cell].zone, .residential)
            XCTAssertEqual(controller.map[cell].buildingOrigin, origin)
        }
    }

    /// Same as the 2×2 case above, but for a 3×3 zone — confirms the
    /// footprint mechanism itself doesn't care how big a zone is, only
    /// `ZoneType.footprintSize` does.
    func testPlacingAThreeByThreeBuildingStampsAllNineCells() {
        let controller = GameController()
        let origin = GridPosition(x: 0, y: 0)
        let startingTreasury = controller.treasury
        controller.selectedTool = .stadium

        let outcome = controller.place(at: origin)

        XCTAssertEqual(outcome, .placed)
        XCTAssertEqual(controller.treasury, startingTreasury - ZoneType.stadium.placementCost)
        let footprint = controller.map.footprintCells(origin: origin, size: 3)
        XCTAssertEqual(footprint.count, 9)
        for cell in footprint {
            XCTAssertEqual(controller.map[cell].zone, .stadium)
            XCTAssertEqual(controller.map[cell].buildingOrigin, origin)
        }
    }

    /// Placing a new zone directly over an existing multi-tile building
    /// auto-replaces it — clears the old building in full, then stamps the
    /// new one — rather than requiring a separate bulldoze first. Costs
    /// only the new zone's price: the old building's removal was already
    /// free (bulldozing always is), so this only saves a click, not money.
    func testPlacingOverAnExistingMultiTileBuildingAutoReplacesIt() {
        let controller = GameController()
        let origin = GridPosition(x: 0, y: 0)
        controller.selectedTool = .residential
        controller.place(at: origin) // covers (0,0)-(1,1)
        let treasuryAfterFirstPlacement = controller.treasury

        controller.selectedTool = .commercial
        let outcome = controller.place(at: origin)

        XCTAssertEqual(outcome, .placed)
        XCTAssertEqual(controller.map[origin].zone, .commercial)
        XCTAssertEqual(controller.map[origin].density, 0)
        XCTAssertEqual(controller.treasury, treasuryAfterFirstPlacement - ZoneType.commercial.placementCost)
    }

    /// A new footprint can overlap two *different* existing buildings at
    /// once — both should be cleared in full, not left as two half-erased
    /// buildings sharing space with the new one.
    func testPlacingOverlappingTwoDifferentBuildingsClearsBothInFull() {
        let controller = GameController()
        controller.selectedTool = .residential
        controller.place(at: GridPosition(x: 0, y: 0)) // covers (0,0)-(1,1)
        controller.selectedTool = .commercial
        controller.place(at: GridPosition(x: 3, y: 0)) // covers (3,0)-(4,1), a gap away from the first

        // A 3x3 stadium anchored at (1,0) covers (1,0)-(3,2) — it clips a
        // corner of each existing building without fully containing either.
        controller.selectedTool = .stadium
        let outcome = controller.place(at: GridPosition(x: 1, y: 0))

        XCTAssertEqual(outcome, .placed)
        // The parts of each old building that fall *outside* the stadium's
        // new footprint should be cleared too, not left behind as a stray
        // corner still claiming the old zone.
        XCTAssertEqual(controller.map[GridPosition(x: 0, y: 0)].zone, .empty)
        XCTAssertEqual(controller.map[GridPosition(x: 0, y: 1)].zone, .empty)
        XCTAssertEqual(controller.map[GridPosition(x: 4, y: 0)].zone, .empty)
        XCTAssertEqual(controller.map[GridPosition(x: 4, y: 1)].zone, .empty)
    }

    /// Auto-replace applies just as well when the *incoming* zone is 1×1
    /// (like a road) overwriting part of an existing multi-tile building —
    /// the whole old building goes, not just the one cell that got clicked.
    func testPlacingA1x1ZoneOverPartOfABuildingClearsTheWholeBuilding() {
        let controller = GameController()
        let origin = GridPosition(x: 0, y: 0)
        controller.selectedTool = .residential
        controller.place(at: origin) // covers (0,0)-(1,1)

        controller.selectedTool = .road
        let outcome = controller.place(at: GridPosition(x: 1, y: 1)) // a non-anchor corner

        XCTAssertEqual(outcome, .placed)
        XCTAssertEqual(controller.map[GridPosition(x: 1, y: 1)].zone, .road)
        XCTAssertEqual(controller.map[origin].zone, .empty) // the rest of the old building is gone too
    }

    func testResetMapClearsTilesAndRestoresStartingTreasury() {
        let controller = GameController()
        controller.selectedTool = .industrial
        controller.place(at: GridPosition(x: 1, y: 1))

        controller.resetMap()

        XCTAssertEqual(controller.treasury, GameController.startingTreasury)
        for tile in controller.map.tiles {
            XCTAssertEqual(tile.zone, .empty)
        }
    }

    func testResetMapUsesTheSelectedMapSize() {
        let controller = GameController()
        controller.selectedMapSize = .medium

        controller.resetMap()

        XCTAssertEqual(controller.map.width, MapSize.medium.dimension)
        XCTAssertEqual(controller.map.height, MapSize.medium.dimension)
    }

    // MARK: - History

    func testAdvanceSimulationAppendsOneHistorySnapshotPerStep() {
        let controller = GameController()

        controller.advanceSimulation()
        controller.advanceSimulation()
        controller.advanceSimulation()

        XCTAssertEqual(controller.history.count, 3)
        let last = controller.history.last!
        XCTAssertEqual(last.population, controller.population)
        XCTAssertEqual(last.jobs, controller.jobs)
        XCTAssertEqual(last.treasury, controller.treasury)
    }

    func testResetMapClearsHistory() {
        let controller = GameController()
        controller.advanceSimulation()
        controller.advanceSimulation()
        XCTAssertFalse(controller.history.isEmpty) // sanity check

        controller.resetMap()

        XCTAssertTrue(controller.history.isEmpty)
    }

    /// Mirrors `GameController`'s private `maxHistoryLength` (120) — update
    /// this literal if that constant changes.
    func testHistoryIsCappedRatherThanGrowingForever() {
        let controller = GameController()
        for _ in 0 ..< 125 {
            controller.advanceSimulation()
        }

        XCTAssertEqual(controller.history.count, 120)
    }

    /// A freshly zoned tile is undeveloped (density 0) — this is the
    /// intentional Phase 2 behavior change from Phase 1, where placing a
    /// zone instantly counted as population. See `testPopulationRespondsToSimulatedGrowth`
    /// for the "it does eventually contribute" half of this story.
    /// Residential and commercial are both 2×2 (`ZoneType.footprintSize`),
    /// so these need non-overlapping origins — `(0,0)` and `(3,0)` leave a
    /// clear gap rather than the two footprints colliding.
    func testFreshlyPlacedZonesContributeNoPopulationOrJobsUntilDeveloped() {
        let controller = GameController()
        controller.selectedTool = .residential
        controller.place(at: GridPosition(x: 0, y: 0)) // covers (0,0)-(1,1)
        controller.selectedTool = .commercial
        controller.place(at: GridPosition(x: 3, y: 0)) // covers (3,0)-(4,1)

        XCTAssertEqual(controller.population, 0)
        XCTAssertEqual(controller.jobs, 0)
    }

    func testPopulationRespondsToSimulatedGrowth() {
        // AlwaysZeroRNG guarantees the demand-gated growth roll clears --
        // safe here (unlike a multi-tick test) since hazards can't touch a
        // tile still at density 0 going into this one tick.
        let controller = GameController(rng: AlwaysZeroRNG())
        let residentialOrigin = GridPosition(x: 0, y: 0)
        let roadPosition = GridPosition(x: 2, y: 0) // outside the (0,0)-(1,1) footprint, touching (1,0)
        controller.selectedTool = .road
        controller.place(at: roadPosition)
        controller.selectedTool = .residential
        controller.place(at: residentialOrigin)
        XCTAssertEqual(controller.population, 0) // sanity check: not yet grown

        controller.advanceSimulation()

        XCTAssertEqual(controller.map[residentialOrigin].density, 1)
        XCTAssertEqual(controller.population, 4) // 1 density level * 4 people
    }

    func testJobsCountBothCommercialAndIndustrialDensity() {
        let controller = GameController(rng: AlwaysZeroRNG()) // guarantees this one growth tick clears
        let commercialOrigin = GridPosition(x: 0, y: 0) // covers (0,0)-(1,1)
        let roadPosition = GridPosition(x: 2, y: 0) // touches (1,0)
        let industrialOrigin = GridPosition(x: 3, y: 0) // covers (3,0)-(4,1), touches the road's other side
        controller.selectedTool = .road
        controller.place(at: roadPosition)
        controller.selectedTool = .commercial
        controller.place(at: commercialOrigin)
        controller.selectedTool = .industrial
        controller.place(at: industrialOrigin)

        controller.advanceSimulation()

        XCTAssertEqual(controller.jobs, 6) // (1 + 1) density levels * 3 jobs
    }

    // MARK: - Tax revenue

    func testAdvanceSimulationCollectsTaxFromPopulation() {
        let controller = GameController(rng: AlwaysZeroRNG()) // guarantees this one growth tick clears
        let residentialOrigin = GridPosition(x: 0, y: 0)
        let roadPosition = GridPosition(x: 2, y: 0)
        controller.selectedTool = .road
        controller.place(at: roadPosition)
        controller.selectedTool = .residential
        controller.place(at: residentialOrigin)
        let treasuryBeforeAdvance = controller.treasury

        controller.advanceSimulation()

        // Growth happens before tax, so this taxes the *post-growth*
        // population: density 0 -> 1 -> population 4 -> tax 4 * $1 = $4.
        XCTAssertEqual(controller.treasury, treasuryBeforeAdvance + 4)
    }

    func testAdvanceSimulationTaxesJobsAtAHigherRateThanPopulation() {
        let controller = GameController(rng: AlwaysZeroRNG()) // guarantees this one growth tick clears
        let commercialOrigin = GridPosition(x: 0, y: 0)
        let roadPosition = GridPosition(x: 2, y: 0)
        controller.selectedTool = .road
        controller.place(at: roadPosition)
        controller.selectedTool = .commercial
        controller.place(at: commercialOrigin)
        let treasuryBeforeAdvance = controller.treasury

        controller.advanceSimulation()

        // density 0 -> 1 -> jobs 3 -> tax 3 * $2 = $6.
        XCTAssertEqual(controller.treasury, treasuryBeforeAdvance + 6)
    }

    /// The gap tax revenue closes: before it existed, spending the starting
    /// treasury down was permanent — bulldozing is free but never refunds,
    /// so there was no way to afford anything else without a full Reset.
    /// Confirm a growing, taxed city instead accumulates *more* than it
    /// started with, purely from letting one building develop over time.
    ///
    /// Deliberately left on the real system RNG rather than `AlwaysZeroRNG`:
    /// this runs 20 ticks with density climbing above 0, and `AlwaysZeroRNG`
    /// doesn't just guarantee the demand-gated growth roll clears — it
    /// guarantees `CityHazards`' crime roll clears too, every single tick,
    /// on a fixture with no police coverage at all. That would turn "watch
    /// a city grow" into "watch a city get hit by crime every tick it's
    /// developed," a real behavior change, not a determinism fix. This test
    /// already tolerated real hazard randomness before demand-gating
    /// existed; it now also tolerates real demand-roll randomness the same
    /// way — vanishingly unlikely to flip a 20-tick test from growing to
    /// not, the same bet the original hazard exposure already made.
    func testTreasuryGrowsOverTimeFromAGrowingCityRatherThanOnlyEverDraining() {
        let controller = GameController()
        controller.selectedTool = .road
        controller.place(at: GridPosition(x: 2, y: 0))
        controller.selectedTool = .residential
        controller.place(at: GridPosition(x: 0, y: 0))
        let treasuryAfterPlacing = controller.treasury

        for _ in 0 ..< 20 { controller.advanceSimulation() } // grows toward max density, then keeps collecting tax at that level

        XCTAssertGreaterThan(controller.treasury, treasuryAfterPlacing)
    }

    // MARK: - Upkeep

    func testUpkeepCostIsZeroWithNoServiceBuildingsPlaced() {
        let controller = GameController()
        controller.selectedTool = .road
        controller.place(at: GridPosition(x: 2, y: 0))
        controller.selectedTool = .residential
        controller.place(at: GridPosition(x: 0, y: 0))

        // Zoned land and roads are the tax base, not city spending.
        XCTAssertEqual(controller.upkeepCost, 0)
    }

    func testUpkeepCostSumsEveryPlacedServiceBuildingOnce() {
        let controller = GameController()
        controller.selectedTool = .policeStation
        controller.place(at: GridPosition(x: 0, y: 0))
        controller.selectedTool = .fireStation
        controller.place(at: GridPosition(x: 5, y: 0))

        // Once per *building*, not per cell — a 2x2 station is one upkeep
        // charge, same reasoning as `totalDensity(of:)` for population/jobs.
        XCTAssertEqual(controller.upkeepCost, ZoneType.policeStation.upkeepCost + ZoneType.fireStation.upkeepCost)
    }

    func testNetRevenueSubtractsUpkeepFromTaxRevenue() {
        let controller = GameController()
        controller.selectedTool = .road
        controller.place(at: GridPosition(x: 2, y: 0))
        controller.selectedTool = .residential
        controller.place(at: GridPosition(x: 0, y: 0))
        controller.selectedTool = .policeStation
        controller.place(at: GridPosition(x: 5, y: 0))

        XCTAssertEqual(controller.netRevenue, controller.taxRevenue - controller.upkeepCost)
    }

    /// The whole reason upkeep exists: a service with no tax base behind it
    /// yet should show up as the treasury actually *shrinking* on advance,
    /// not just growing more slowly than before.
    func testAdvanceSimulationCanShrinkTreasuryWhenUpkeepExceedsTaxRevenue() {
        let controller = GameController()
        controller.selectedTool = .policeStation
        controller.place(at: GridPosition(x: 0, y: 0))
        // No zoned land at all: taxRevenue is 0, upkeepCost is not.
        let treasuryBeforeAdvance = controller.treasury

        controller.advanceSimulation()

        XCTAssertEqual(controller.treasury, treasuryBeforeAdvance - ZoneType.policeStation.upkeepCost)
    }

    // MARK: - Player-adjustable tax rate

    func testDefaultTaxRateReproducesTheOriginalTaxFormulaExactly() {
        let controller = GameController(rng: AlwaysZeroRNG()) // guarantees this one growth tick clears
        controller.selectedTool = .road
        controller.place(at: GridPosition(x: 2, y: 0))
        controller.selectedTool = .commercial
        controller.place(at: GridPosition(x: 0, y: 0))
        controller.advanceSimulation() // grows to density 1 -> 3 jobs

        // Untouched, taxRate is 1.0: 3 jobs * $2 tax = $6, same as before
        // this lever existed.
        XCTAssertEqual(controller.taxRevenue, 6)
    }

    func testHalvingTheTaxRateHalvesTaxRevenue() {
        let controller = GameController(rng: AlwaysZeroRNG()) // guarantees this one growth tick clears
        controller.selectedTool = .road
        controller.place(at: GridPosition(x: 2, y: 0))
        controller.selectedTool = .commercial
        controller.place(at: GridPosition(x: 0, y: 0))
        controller.advanceSimulation() // 3 jobs, $6 at full rate

        controller.taxRate = 0.5

        XCTAssertEqual(controller.taxRevenue, 3)
    }

    func testRaisingTheTaxRateAboveOneIncreasesRevenue() {
        let controller = GameController(rng: AlwaysZeroRNG()) // guarantees this one growth tick clears
        controller.selectedTool = .road
        controller.place(at: GridPosition(x: 2, y: 0))
        controller.selectedTool = .commercial
        controller.place(at: GridPosition(x: 0, y: 0))
        controller.advanceSimulation() // 3 jobs, $6 at full rate

        controller.taxRate = 1.5

        XCTAssertEqual(controller.taxRevenue, 9)
    }

    func testResetMapRestoresTheTaxRateToDefault() {
        let controller = GameController()
        controller.taxRate = 0.5

        controller.resetMap()

        XCTAssertEqual(controller.taxRate, 1.0)
    }

    // MARK: - Per-service funding control

    func testFundingLevelDefaultsToFullForEveryService() {
        let controller = GameController()
        XCTAssertEqual(controller.fundingLevel(for: .policeStation), 1.0)
        XCTAssertEqual(controller.fundingLevel(for: .fireStation), 1.0)
    }

    func testSetFundingLevelIsReflectedByFundingLevel() {
        let controller = GameController()
        controller.setFundingLevel(0.5, for: .fireStation)

        XCTAssertEqual(controller.fundingLevel(for: .fireStation), 0.5)
        XCTAssertEqual(controller.fundingLevel(for: .policeStation), 1.0) // untouched
    }

    /// The other half of "cheaper and less effective": underfunding a
    /// service must lower what it costs to run, not just weaken its
    /// coverage (that side is `LandValueTests`' job).
    func testUnderfundingAServiceLowersItsUpkeepCost() {
        let controller = GameController()
        controller.selectedTool = .policeStation
        controller.place(at: GridPosition(x: 0, y: 0))

        controller.setFundingLevel(0.5, for: .policeStation)

        XCTAssertEqual(controller.upkeepCost, ZoneType.policeStation.upkeepCost / 2)
    }

    func testOverfundingAServiceRaisesItsUpkeepCostAboveTheBaseline() {
        let controller = GameController()
        controller.selectedTool = .fireStation
        controller.place(at: GridPosition(x: 0, y: 0))

        controller.setFundingLevel(1.5, for: .fireStation)

        XCTAssertEqual(controller.upkeepCost, Int(Double(ZoneType.fireStation.upkeepCost) * 1.5))
    }

    // MARK: - Highway and subway placement

    func testPlacingAHighwayChargesItsOwnCostAndSetsTheZone() {
        let controller = GameController()
        let position = GridPosition(x: 0, y: 0)
        let startingTreasury = controller.treasury
        controller.selectedTool = .highway

        controller.place(at: position)

        XCTAssertEqual(controller.map[position].zone, .highway)
        XCTAssertEqual(controller.treasury, startingTreasury - ZoneType.highway.placementCost)
    }

    /// `.highway` costs money to place but nothing to keep running — a
    /// pricier road, not a service.
    func testHighwayContributesNothingToUpkeepCost() {
        let controller = GameController()
        controller.selectedTool = .highway
        controller.place(at: GridPosition(x: 0, y: 0))

        XCTAssertEqual(controller.upkeepCost, 0)
    }

    /// `.subway` *is* a service (like `.publicTransit`) — placing one
    /// should show up in upkeep, funded at the default 100% until told
    /// otherwise.
    func testSubwayContributesItsUpkeepCostAtDefaultFunding() {
        let controller = GameController()
        controller.selectedTool = .subway
        controller.place(at: GridPosition(x: 0, y: 0))

        XCTAssertEqual(controller.upkeepCost, ZoneType.subway.upkeepCost)
    }

    // MARK: - Pipe (an underground layer, not a ZoneType — see `Tile.hasPipe`)

    func testLayingAPipeChargesItsOwnCostOnce() {
        let controller = GameController()
        let position = GridPosition(x: 0, y: 0)
        let startingTreasury = controller.treasury

        let outcome = controller.layPipe(at: position)

        XCTAssertEqual(outcome, .placed)
        XCTAssertTrue(controller.map[position].hasPipe)
        XCTAssertEqual(controller.treasury, startingTreasury - GameController.pipePlacementCost)
    }

    /// `GameScene` calls `layPipe` on every tile a drag stroke crosses —
    /// re-crossing already-piped ground shouldn't charge a second time.
    func testLayingAPipeOnATileThatAlreadyHasOneIsFreeAndUnchanged() {
        let controller = GameController()
        let position = GridPosition(x: 0, y: 0)
        controller.layPipe(at: position)
        let treasuryAfterFirstPipe = controller.treasury

        let outcome = controller.layPipe(at: position)

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(controller.treasury, treasuryAfterFirstPipe)
    }

    func testRemovingAPipeIsFreeAndClearsIt() {
        let controller = GameController()
        let position = GridPosition(x: 0, y: 0)
        controller.layPipe(at: position)
        let treasuryAfterPlacing = controller.treasury

        controller.removePipe(at: position)

        XCTAssertFalse(controller.map[position].hasPipe)
        XCTAssertEqual(controller.treasury, treasuryAfterPlacing)
    }

    /// The regression test for the exact bug pipes-as-a-layer exists to
    /// avoid: placing a normal zone on top of a piped tile must never
    /// silently erase the pipe underneath it (`CityMap.placeBuilding`
    /// carries `hasPipe` forward instead of defaulting it away).
    func testPlacingAZoneOverAPipedTilePreservesThePipe() {
        let controller = GameController()
        let position = GridPosition(x: 0, y: 0)
        controller.layPipe(at: position)
        controller.selectedTool = .road

        controller.place(at: position)

        XCTAssertEqual(controller.map[position].zone, .road)
        XCTAssertTrue(controller.map[position].hasPipe)
    }

    /// Same regression, the bulldoze path (`GameController.clearBuilding`
    /// carries `hasPipe` forward the same way).
    func testBulldozingAPipedTilePreservesThePipe() {
        let controller = GameController()
        let position = GridPosition(x: 0, y: 0)
        controller.selectedTool = .road
        controller.place(at: position)
        controller.layPipe(at: position)

        controller.bulldoze(at: position)

        XCTAssertEqual(controller.map[position].zone, .empty)
        XCTAssertTrue(controller.map[position].hasPipe)
    }

    /// `.waterTower` *is* a service (like Police/Fire) — placing one
    /// should show up in upkeep, funded at the default 100% until told
    /// otherwise.
    func testWaterTowerContributesItsUpkeepCostAtDefaultFunding() {
        let controller = GameController()
        controller.selectedTool = .waterTower
        controller.place(at: GridPosition(x: 0, y: 0))

        XCTAssertEqual(controller.upkeepCost, ZoneType.waterTower.upkeepCost)
    }
}
