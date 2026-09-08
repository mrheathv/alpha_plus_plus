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

    /// Placing a new zone directly over an existing multi-tile building is
    /// blocked, not auto-replaced — a deliberate reversal of an earlier
    /// design (see `place(at:)`'s own doc comment for why: convenient in
    /// isolation, risky once drag-painting could silently demolish an
    /// established building mid-stroke). Nothing about the old building or
    /// the treasury changes.
    func testPlacingOverAnExistingMultiTileBuildingIsBlocked() {
        let controller = GameController()
        let origin = GridPosition(x: 0, y: 0)
        controller.selectedTool = .residential
        controller.place(at: origin) // covers (0,0)-(1,1)
        let treasuryAfterFirstPlacement = controller.treasury

        controller.selectedTool = .commercial
        let outcome = controller.place(at: origin)

        XCTAssertEqual(outcome, .blocked)
        XCTAssertEqual(controller.map[origin].zone, .residential)
        XCTAssertEqual(controller.treasury, treasuryAfterFirstPlacement)
    }

    /// The intended replacement workflow still works: bulldoze first (free),
    /// then place — exactly what auto-replace used to do in one click, now
    /// two, with the bulldoze being an explicit, deliberate step instead of
    /// an implicit side effect of the next zone tool you happen to pick.
    func testBulldozingThenPlacingReplacesABuilding() {
        let controller = GameController()
        let origin = GridPosition(x: 0, y: 0)
        controller.selectedTool = .residential
        controller.place(at: origin) // covers (0,0)-(1,1)
        let treasuryAfterFirstPlacement = controller.treasury

        controller.bulldoze(at: origin)
        controller.selectedTool = .commercial
        let outcome = controller.place(at: origin)

        XCTAssertEqual(outcome, .placed)
        XCTAssertEqual(controller.map[origin].zone, .commercial)
        XCTAssertEqual(controller.treasury, treasuryAfterFirstPlacement - ZoneType.commercial.placementCost)
    }

    /// A new footprint that overlaps two *different* existing buildings at
    /// once is blocked by either one alone — both buildings stay exactly as
    /// they were, not half-cleared by a footprint that only clips a corner
    /// of each.
    func testPlacingOverlappingTwoDifferentBuildingsIsBlocked() {
        let controller = GameController()
        controller.selectedTool = .residential
        controller.place(at: GridPosition(x: 0, y: 0)) // covers (0,0)-(1,1)
        controller.selectedTool = .commercial
        controller.place(at: GridPosition(x: 3, y: 0)) // covers (3,0)-(4,1), a gap away from the first

        // A 3x3 stadium anchored at (1,0) covers (1,0)-(3,2) — it clips a
        // corner of each existing building without fully containing either.
        controller.selectedTool = .stadium
        let outcome = controller.place(at: GridPosition(x: 1, y: 0))

        XCTAssertEqual(outcome, .blocked)
        XCTAssertEqual(controller.map[GridPosition(x: 0, y: 0)].zone, .residential)
        XCTAssertEqual(controller.map[GridPosition(x: 0, y: 1)].zone, .residential)
        XCTAssertEqual(controller.map[GridPosition(x: 3, y: 0)].zone, .commercial)
        XCTAssertEqual(controller.map[GridPosition(x: 4, y: 1)].zone, .commercial)
        // And no part of the stadium got placed either — this is an
        // all-or-nothing refusal, not a partial one.
        for cell in [GridPosition(x: 2, y: 0), GridPosition(x: 2, y: 1), GridPosition(x: 2, y: 2)] {
            XCTAssertEqual(controller.map[cell].zone, .empty)
        }
    }

    /// The same block applies when the *incoming* zone is 1×1 (like a road)
    /// touching just one corner of an existing multi-tile building — a
    /// single occupied cell anywhere in the new footprint is enough to
    /// refuse the whole placement, not just clear that one corner.
    func testPlacingA1x1ZoneOverPartOfABuildingIsBlocked() {
        let controller = GameController()
        let origin = GridPosition(x: 0, y: 0)
        controller.selectedTool = .residential
        controller.place(at: origin) // covers (0,0)-(1,1)

        controller.selectedTool = .road
        let outcome = controller.place(at: GridPosition(x: 1, y: 1)) // a non-anchor corner

        XCTAssertEqual(outcome, .blocked)
        XCTAssertEqual(controller.map[GridPosition(x: 1, y: 1)].zone, .residential)
        XCTAssertEqual(controller.map[origin].zone, .residential)
    }

    /// Repainting a tile with the *same* tool it already has is still a
    /// free no-op, not newly blocked — `place(at:)`'s existing
    /// same-zone-and-anchor guard runs before the occupied check, so
    /// drag-painting a long road across tiles that are already road never
    /// regresses into flashing "blocked" on every tile it re-crosses.
    func testRepaintingATileWithItsOwnZoneStaysUnchangedNotBlocked() {
        let controller = GameController()
        let position = GridPosition(x: 0, y: 0)
        controller.selectedTool = .road
        controller.place(at: position)

        let outcome = controller.place(at: position)

        XCTAssertEqual(outcome, .unchanged)
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

    // MARK: - Power line (an underground-style layer, not a ZoneType — see `Tile.hasPowerLine`)

    func testLayingAPowerLineChargesItsOwnCostOnce() {
        let controller = GameController()
        let position = GridPosition(x: 0, y: 0)
        let startingTreasury = controller.treasury

        let outcome = controller.layPowerLine(at: position)

        XCTAssertEqual(outcome, .placed)
        XCTAssertTrue(controller.map[position].hasPowerLine)
        XCTAssertEqual(controller.treasury, startingTreasury - GameController.powerLinePlacementCost)
    }

    /// `GameScene` calls `layPowerLine` on every tile a drag stroke crosses —
    /// re-crossing already-lined ground shouldn't charge a second time.
    func testLayingAPowerLineOnATileThatAlreadyHasOneIsFreeAndUnchanged() {
        let controller = GameController()
        let position = GridPosition(x: 0, y: 0)
        controller.layPowerLine(at: position)
        let treasuryAfterFirstLine = controller.treasury

        let outcome = controller.layPowerLine(at: position)

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(controller.treasury, treasuryAfterFirstLine)
    }

    func testRemovingAPowerLineIsFreeAndClearsIt() {
        let controller = GameController()
        let position = GridPosition(x: 0, y: 0)
        controller.layPowerLine(at: position)
        let treasuryAfterPlacing = controller.treasury

        controller.removePowerLine(at: position)

        XCTAssertFalse(controller.map[position].hasPowerLine)
        XCTAssertEqual(controller.treasury, treasuryAfterPlacing)
    }

    /// The regression test pipes already have, mirrored for power lines:
    /// placing a normal zone on top of a lined tile must never silently
    /// erase the line underneath it (`CityMap.placeBuilding` carries
    /// `hasPowerLine` forward instead of defaulting it away).
    func testPlacingAZoneOverAPowerLinedTilePreservesTheLine() {
        let controller = GameController()
        let position = GridPosition(x: 0, y: 0)
        controller.layPowerLine(at: position)
        controller.selectedTool = .road

        controller.place(at: position)

        XCTAssertEqual(controller.map[position].zone, .road)
        XCTAssertTrue(controller.map[position].hasPowerLine)
    }

    /// Same regression, the bulldoze path (`GameController.clearBuilding`
    /// carries `hasPowerLine` forward the same way).
    func testBulldozingAPowerLinedTilePreservesTheLine() {
        let controller = GameController()
        let position = GridPosition(x: 0, y: 0)
        controller.selectedTool = .road
        controller.place(at: position)
        controller.layPowerLine(at: position)

        controller.bulldoze(at: position)

        XCTAssertEqual(controller.map[position].zone, .empty)
        XCTAssertTrue(controller.map[position].hasPowerLine)
    }

    /// `.powerPlant` *is* a service (like Police/Fire) — placing one should
    /// show up in upkeep, funded at the default 100% until told otherwise.
    func testPowerPlantContributesItsUpkeepCostAtDefaultFunding() {
        let controller = GameController()
        controller.selectedTool = .powerPlant
        controller.place(at: GridPosition(x: 0, y: 0))

        XCTAssertEqual(controller.upkeepCost, ZoneType.powerPlant.upkeepCost)
    }

    /// A freshly created controller hasn't run a tick yet, so there's no
    /// outage roll to have happened — this pins the quiet default rather
    /// than leaving it unspecified.
    func testNoPowerOutageBeforeAnyTickHasRun() {
        let controller = GameController()
        XCTAssertFalse(controller.isPowerOutageActive)
    }

    /// Zero-funding a power plant should read the same way zero-funding a
    /// water tower does: guaranteed no supply, `PowerGrid`'s own zero-funding
    /// behavior. This exercises it through the full `advanceSimulation` path
    /// rather than calling `PowerGrid` directly, since that's the path that
    /// actually updates `controller.map.powerSupply` in play.
    func testZeroFundedPowerPlantSuppliesNothingAfterATick() {
        let controller = GameController()
        controller.selectedTool = .powerPlant
        controller.place(at: GridPosition(x: 0, y: 0)) // covers (0,0)-(2,2)
        controller.setFundingLevel(0, for: .powerPlant)
        let linePosition = GridPosition(x: 3, y: 0) // touches the plant's own footprint cell (2,0)
        controller.layPowerLine(at: linePosition)

        controller.advanceSimulation()

        XCTAssertFalse(controller.map.powerSupply.isSupplied(at: linePosition))
    }

    // MARK: - Bonds

    func testIssuingABondAddsToTreasuryAndBalance() {
        let controller = GameController()
        let startingTreasury = controller.treasury

        let outcome = controller.issueBond()

        XCTAssertTrue(outcome)
        XCTAssertEqual(controller.bondBalance, GameController.bondIssueAmount)
        XCTAssertEqual(controller.treasury, startingTreasury + GameController.bondIssueAmount)
    }

    /// `maxBondBalance` is the cap the roadmap's own "there's no debt in
    /// this model" gap called out as missing — borrowing has to actually
    /// run out somewhere, or it's not a real constraint.
    func testIssuingBondsBeyondTheCapIsANoOp() {
        let controller = GameController()
        while controller.issueBond() {} // borrow until the cap refuses
        let balanceAtCap = controller.bondBalance
        let treasuryAtCap = controller.treasury
        XCTAssertEqual(balanceAtCap, GameController.maxBondBalance)

        let outcome = controller.issueBond()

        XCTAssertFalse(outcome)
        XCTAssertEqual(controller.bondBalance, balanceAtCap)
        XCTAssertEqual(controller.treasury, treasuryAtCap)
    }

    func testRepayingABondReducesBalanceAndTreasury() {
        let controller = GameController()
        controller.issueBond()
        let treasuryAfterIssuing = controller.treasury

        controller.repayBond(GameController.bondIssueAmount)

        XCTAssertEqual(controller.bondBalance, 0)
        XCTAssertEqual(controller.treasury, treasuryAfterIssuing - GameController.bondIssueAmount)
    }

    /// Repaying more than is actually owed clamps to the outstanding
    /// balance rather than taking `bondBalance` negative.
    func testRepayingMoreThanOwedClampsToTheOutstandingBalance() {
        let controller = GameController()
        controller.issueBond() // owes exactly one bond's worth
        let treasuryAfterIssuing = controller.treasury

        controller.repayBond(GameController.bondIssueAmount * 10)

        XCTAssertEqual(controller.bondBalance, 0)
        XCTAssertEqual(controller.treasury, treasuryAfterIssuing - GameController.bondIssueAmount)
    }

    /// Repaying more than the treasury can actually cover clamps to what's
    /// there instead of driving treasury deeper negative than the payment
    /// itself would already explain.
    func testRepayingMoreThanTreasuryCanAffordClampsToTreasury() {
        let controller = GameController()
        controller.issueBond()
        controller.issueBond()
        controller.issueBond() // owes 3 bonds' worth ($15,000), at the cap

        // Spend the treasury down below the outstanding bond balance —
        // roads at $50 apiece, one per distinct tile so the "same zone
        // twice is free" guard never masks a real charge.
        controller.selectedTool = .road
        var remainingTiles = controller.map.tiles.map(\.position).makeIterator()
        while controller.treasury >= controller.bondBalance, let position = remainingTiles.next() {
            controller.place(at: position)
        }
        let treasuryBeforeRepay = controller.treasury
        XCTAssertLessThan(treasuryBeforeRepay, controller.bondBalance)

        controller.repayBond(controller.bondBalance)

        XCTAssertEqual(controller.treasury, 0)
        XCTAssertEqual(controller.bondBalance, GameController.bondIssueAmount * 3 - treasuryBeforeRepay)
    }

    /// `netRevenue` folds bond interest in alongside tax and upkeep — a
    /// bond isn't a one-time fee, it's an ongoing drain every tick after.
    func testBondInterestReducesNetRevenue() {
        let controller = GameController()
        let netRevenueBeforeBond = controller.netRevenue

        controller.issueBond()

        XCTAssertEqual(controller.bondInterest, Int(Double(GameController.bondIssueAmount) * GameController.bondInterestRate))
        XCTAssertEqual(controller.netRevenue, netRevenueBeforeBond - controller.bondInterest)
    }

    func testResetMapClearsBondBalance() {
        let controller = GameController()
        controller.issueBond()

        controller.resetMap()

        XCTAssertEqual(controller.bondBalance, 0)
    }

    // MARK: - Ordinances

    /// Every ordinance defaults off — a fresh city has no policies active
    /// and pays nothing for them, same "untouched behaves exactly as
    /// before this existed" default every other lever in this project
    /// starts at.
    func testEveryOrdinanceStartsInactive() {
        let controller = GameController()

        XCTAssertFalse(controller.isOrdinanceActive(\.neighborhoodWatch))
        XCTAssertFalse(controller.isOrdinanceActive(\.fireInspections))
        XCTAssertFalse(controller.isOrdinanceActive(\.businessTaxBreak))
    }

    func testSetOrdinanceTogglesItOnAndOff() {
        let controller = GameController()

        controller.setOrdinance(\.neighborhoodWatch, active: true)
        XCTAssertTrue(controller.isOrdinanceActive(\.neighborhoodWatch))

        controller.setOrdinance(\.neighborhoodWatch, active: false)
        XCTAssertFalse(controller.isOrdinanceActive(\.neighborhoodWatch))
    }

    /// Setting one ordinance doesn't touch the other two — each toggle
    /// reaches exactly the field its key path names.
    func testSettingOneOrdinanceDoesNotAffectTheOthers() {
        let controller = GameController()

        controller.setOrdinance(\.fireInspections, active: true)

        XCTAssertTrue(controller.isOrdinanceActive(\.fireInspections))
        XCTAssertFalse(controller.isOrdinanceActive(\.neighborhoodWatch))
        XCTAssertFalse(controller.isOrdinanceActive(\.businessTaxBreak))
    }

    /// Each active ordinance costs `Ordinances.costPerOrdinance` per tick,
    /// folded into `netRevenue` alongside upkeep and bond interest —
    /// proven with two active at once so this can't pass by coincidence
    /// with a cost of exactly one ordinance's worth.
    func testActiveOrdinancesReduceNetRevenue() {
        let controller = GameController()
        let netRevenueBeforeOrdinances = controller.netRevenue

        controller.setOrdinance(\.neighborhoodWatch, active: true)
        controller.setOrdinance(\.fireInspections, active: true)

        XCTAssertEqual(controller.netRevenue, netRevenueBeforeOrdinances - 2 * Ordinances.costPerOrdinance)
    }

    func testResetMapClearsAllOrdinances() {
        let controller = GameController()
        controller.setOrdinance(\.neighborhoodWatch, active: true)
        controller.setOrdinance(\.businessTaxBreak, active: true)

        controller.resetMap()

        XCTAssertFalse(controller.isOrdinanceActive(\.neighborhoodWatch))
        XCTAssertFalse(controller.isOrdinanceActive(\.businessTaxBreak))
    }

    // MARK: - RCI demand meter

    /// `cityDemand` is a passthrough to `map.cityDemand` — this pins that
    /// down so `GameView`'s demand meter and `CitySimulator`'s own growth
    /// gate are guaranteed to be reading the exact same number, not two
    /// copies that could drift.
    func testCityDemandReadsThroughToTheMapsCachedValue() {
        let controller = GameController()

        XCTAssertEqual(controller.cityDemand, controller.map.cityDemand)
    }
}
