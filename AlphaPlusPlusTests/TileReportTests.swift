import XCTest
@testable import AlphaPlusPlus

/// The inspector's data layer: the growth gate chain made askable, and
/// everything else about a tile gathered alongside it.
@MainActor
final class TileReportTests: XCTestCase {

    /// A lot with road frontage and nothing else, so each test can add back
    /// exactly the one thing it is about.
    private func lot(
        _ zone: ZoneType = .residential, density: Int = 0, width: Int = 24, height: Int = 24
    ) -> CityMap {
        var map = CityMap(width: width, height: height)
        for x in 0 ..< width { map[GridPosition(x: x, y: 2)].zone = .road }
        map.placeBuilding(zone: zone, origin: GridPosition(x: 0, y: 0))
        for cell in map.footprintCells(origin: GridPosition(x: 0, y: 0), size: zone.footprintSize) {
            map[cell].density = density
        }
        return map
    }

    private let origin = GridPosition(x: 0, y: 0)

    /// Connects the lot at `origin` to both utilities, and optionally a
    /// school. Pipes and lines rather than proximity, so the fixture does not
    /// quietly depend on `Water.directSupplyRadius`.
    private func connectUtilities(_ map: inout CityMap, school: Bool = false) {
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 8, y: 6))
        map.placeBuilding(zone: .generator, origin: GridPosition(x: 12, y: 6))
        for x in 0 ... 13 {
            map[GridPosition(x: x, y: 5)].hasPipe = true
            map[GridPosition(x: x, y: 5)].hasPowerLine = true
        }
        for y in 0 ... 6 {
            map[GridPosition(x: 1, y: y)].hasPipe = true
            map[GridPosition(x: 1, y: y)].hasPowerLine = true
        }
        for y in 5 ... 6 {
            map[GridPosition(x: 8, y: y)].hasPipe = true
            map[GridPosition(x: 12, y: y)].hasPowerLine = true
        }
        if school { map.placeBuilding(zone: .school, origin: GridPosition(x: 3, y: 0)) }
        map.waterSupply = Water.computeSupply(for: map)
        map.powerSupply = PowerGrid.computeSupply(for: map, outageActive: false)
    }

    private func status(_ map: CityMap, at position: GridPosition? = nil) -> LotStatus {
        CitySimulator.status(
            of: map[position ?? origin], in: map, using: ZoneDistanceField.compute(for: map)
        )
    }

    // MARK: - The gate chain, in order

    func testAnUnreachableLotReportsItsMissingRoad() {
        var map = lot()
        for x in 0 ..< map.width { map[GridPosition(x: x, y: 2)].zone = .empty }
        XCTAssertEqual(status(map), .noRoadAccess)
    }

    func testARoadOrAServiceIsNotAGrowableLot() {
        let map = lot()
        XCTAssertEqual(status(map, at: GridPosition(x: 5, y: 2)), .notGrowable)

        var withStation = lot()
        withStation.placeBuilding(zone: .fireStation, origin: GridPosition(x: 6, y: 0))
        XCTAssertEqual(status(withStation, at: GridPosition(x: 6, y: 0)), .notGrowable)
    }

    /// Burning and burnt are one state to the simulation and two completely
    /// different problems to a player, so the chain reports the live emergency
    /// first.
    func testBurningIsReportedAheadOfTheDamageItCaused() {
        var map = lot(density: 3)
        for cell in map.footprintCells(origin: origin, size: 2) {
            map[cell].damagedBy = .fireStation
        }
        XCTAssertEqual(status(map), .damaged(waitingFor: .fireStation))

        for cell in map.footprintCells(origin: origin, size: 2) { map[cell].fireTicks = 1 }
        XCTAssertEqual(status(map), .burning)
    }

    func testALotMidBuildReportsHowFarAlongItIs() {
        var map = lot(density: 1)
        let total = CitySimulator.constructionTicks(toReach: 2)
        for cell in map.footprintCells(origin: origin, size: 2) {
            map[cell].constructionRemaining = total - 3
        }
        XCTAssertEqual(status(map), .underConstruction(remaining: total - 3, total: total))
    }

    func testALotWithNowhereLeftToGrowSaysSoRatherThanNamingAMissingRequirement() {
        var map = lot(density: ZoneType.residential.maxDensity)
        // Everything the top tier needs — including enough amenity to sustain
        // it, or the lot would report that it is on its way back down rather
        // than that it has arrived.
        connectUtilities(&map, school: true)
        map.placeBuilding(zone: .policeStation, origin: GridPosition(x: 5, y: 0))
        map.placeBuilding(zone: .fireStation, origin: GridPosition(x: 7, y: 0))
        map.placeBuilding(zone: .hospital, origin: GridPosition(x: 9, y: 0))
        map.placeBuilding(zone: .publicTransit, origin: GridPosition(x: 2, y: 3))
        XCTAssertEqual(status(map), .atMaximumDensity)
    }

    /// The land-value gate bites at the top tier, where the bar (0.8) is above
    /// what plain road frontage buys (0.75) — which is exactly the design:
    /// every level below it is reachable anywhere, and the last one has to be
    /// earned with amenities.
    func testAShortfallInLandValueIsReportedWithBothNumbers() {
        var map = lot(density: ZoneType.residential.maxDensity - 1)
        // Utilities but deliberately *no* school: a school is itself an
        // amenity, and adding one to satisfy the gate behind this one pushed
        // land value over the very bar this test needs it to fall short of.
        connectUtilities(&map)
        guard case let .needsLandValue(required, current) = status(map) else {
            return XCTFail("expected a land-value shortfall, got \(status(map))")
        }
        XCTAssertGreaterThan(required, current, "reported a shortfall that is not one")
        XCTAssertEqual(required, CitySimulator.requiredLandValue(toReach: ZoneType.residential.maxDensity))
    }

    /// The utility gates only apply from the level that needs them, so a lot
    /// far below that must not be told it needs water.
    func testUtilitiesAreOnlyReportedOnceTheyAreActuallyRequired() {
        var map = lot(density: CitySimulator.waterRequiredFromLevel - 1)
        // Enough desirability to clear the land-value gate, so water is the
        // next thing in the chain rather than something behind it.
        map.placeBuilding(zone: .policeStation, origin: GridPosition(x: 3, y: 0))
        map.placeBuilding(zone: .fireStation, origin: GridPosition(x: 6, y: 0))
        map.placeBuilding(zone: .hospital, origin: GridPosition(x: 9, y: 0))
        XCTAssertEqual(status(map), .needsWater, "the water gate did not bite at the level that needs it")

        var supplied = map
        connectUtilities(&supplied)
        XCTAssertNotEqual(status(supplied), .needsWater, "connecting water changed nothing")
    }

    func testAnOversuppliedLotReportsThatItIsBeingAbandoned() {
        var map = lot(density: 3)
        map.cityDemand = CityDemand(residential: -1, commercial: -1, industrial: -1)
        XCTAssertEqual(status(map), .beingAbandoned)
    }

    func testALotAboveWhatItsSurroundingsSupportReportsWhereItWillSettle() {
        var map = lot(density: 5)
        map.cityDemand = CityDemand()
        guard case let .decliningToSustainable(sustainable) = status(map) else {
            return XCTFail("expected a decline, got \(status(map))")
        }
        XCTAssertLessThan(sustainable, 5)
        XCTAssertEqual(
            sustainable,
            CitySimulator.sustainableDensity(
                landValue: TileReport.make(at: origin, in: map).landValue,
                hasWater: false, hasPower: false
            )
        )
    }

    /// The good case. Nothing is wrong and the lot is simply waiting on the
    /// city wanting more — which the inspector has to be able to say, or every
    /// healthy lot would look like a problem it could not name.
    func testAHealthyLotReportsThatItIsOnlyWaitingOnDemand() {
        var map = lot(density: 0)
        map.cityDemand = CityDemand(residential: 1, commercial: 1, industrial: 1)
        guard case let .readyToGrow(demand) = status(map) else {
            return XCTFail("expected a ready lot, got \(status(map))")
        }
        XCTAssertEqual(demand, 1)
    }

    func testDeterioratingNamesTheThreeStatesThatAreGettingWorse() {
        XCTAssertTrue(LotStatus.noRoadAccess.isDeteriorating)
        XCTAssertTrue(LotStatus.beingAbandoned.isDeteriorating)
        XCTAssertTrue(LotStatus.decliningToSustainable(sustainable: 2).isDeteriorating)
        XCTAssertTrue(LotStatus.burning.isDeteriorating)

        XCTAssertFalse(LotStatus.needsWater.isDeteriorating, "stuck is not the same as shrinking")
        XCTAssertFalse(LotStatus.atMaximumDensity.isDeteriorating)
        XCTAssertFalse(LotStatus.readyToGrow(demand: 0).isDeteriorating)
        XCTAssertFalse(LotStatus.damaged(waitingFor: .fireStation).isDeteriorating,
                       "a ruin is already as bad as it gets — it is not still falling")
    }

    // MARK: - The guard that matters

    /// **The simulator and the inspector must never disagree.**
    ///
    /// This is the whole reason the gate chain was extracted rather than
    /// copied. An inspector with its own notion of "is it missing water"
    /// drifts from the rules the first time either changes, and this project
    /// has been bitten by exactly that three times — a streetscape painting
    /// its own tiles, an overlay render with its own stale switch, hazard
    /// damage computed twice.
    ///
    /// So: grow a real city, then check every lot in it. Wherever the report
    /// says a lot is blocked, one tick must not move it; wherever it says the
    /// lot is only waiting on demand, a generator that passes every roll must.
    func testTheReportedStatusPredictsWhatTheNextTickActuallyDoes() {
        let spec = PlaytestHarness.spec()
        let (controller, _) = PlaytestHarness.runScenario(spec, ticks: 0, seed: 77)
        for _ in 0 ..< 120 { controller.advanceSimulation() }

        let before = controller.map
        let field = ZoneDistanceField.compute(for: before)
        var rng = AlwaysZeroRNG() // every probability gate clears
        let after = CitySimulator.advance(before, using: &rng)

        var checkedBlocked = 0
        var checkedReady = 0
        for tile in before.tiles where tile.isBuildingAnchor && tile.zone.maxDensity > 0 {
            let status = CitySimulator.status(of: tile, in: before, using: field)
            let grew = after[tile.position].constructionRemaining != nil
                && before[tile.position].constructionRemaining == nil

            switch status {
            case .readyToGrow:
                checkedReady += 1
                XCTAssertTrue(grew, "\(tile.position) was reported ready and did not start building")
            case .needsLandValue, .needsWater, .needsPower, .needsSchool,
                 .atMaximumDensity, .noRoadAccess, .beingAbandoned, .decliningToSustainable:
                checkedBlocked += 1
                XCTAssertFalse(grew, "\(tile.position) was reported blocked (\(status)) and grew anyway")
            case .notGrowable, .damaged, .burning, .underConstruction:
                continue
            }
        }
        print("\nstatus agreement: \(checkedReady) ready lots, \(checkedBlocked) blocked lots")
        XCTAssertGreaterThan(checkedBlocked, 10, "precondition: no blocked lots, so nothing was compared")
        XCTAssertGreaterThan(checkedReady, 0, "precondition: no ready lots, so nothing was compared")
    }

    // MARK: - The rest of the report

    func testTheReportDescribesTheBuildingRatherThanTheCellUnderThePointer() {
        var map = lot(density: 4)
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 4, y: 4))
        map.waterSupply = Water.computeSupply(for: map)

        // All four cells of a 2×2 lot have to answer identically: hovering the
        // far corner of a tower is still hovering the tower.
        let reports = map.footprintCells(origin: origin, size: 2).map {
            TileReport.make(at: $0, in: map)
        }
        for report in reports.dropFirst() {
            XCTAssertEqual(report.status, reports[0].status)
            XCTAssertEqual(report.density, reports[0].density)
            XCTAssertEqual(report.hasWater, reports[0].hasWater)
            XCTAssertEqual(report.landValue, reports[0].landValue)
        }
        XCTAssertEqual(reports[0].density, 4)
    }

    func testPopulationAndJobsMatchWhatTheCityCountsForThisLot() {
        let homes = lot(.residential, density: 3)
        XCTAssertEqual(TileReport.make(at: origin, in: homes).population,
                       3 * ZoneType.residential.populationPerDensityLevel)
        XCTAssertEqual(TileReport.make(at: origin, in: homes).jobs, 0)

        let shops = lot(.commercial, density: 3)
        XCTAssertEqual(TileReport.make(at: origin, in: shops).jobs,
                       3 * ZoneType.commercial.jobsPerDensityLevel)
    }

    /// "Exposed" has to mean exactly what `CityHazards` means by it, or the
    /// inspector will promise safety the simulation does not honour.
    func testExposureMatchesWhetherAHazardCanActuallyStrike() {
        var map = lot(.industrial, density: 3)
        XCTAssertTrue(TileReport.make(at: origin, in: map).isExposedToFire,
                      "an industrial lot with no fire station is not exposed?")

        map.placeBuilding(zone: .fireStation, origin: GridPosition(x: 3, y: 0))
        XCTAssertFalse(TileReport.make(at: origin, in: map).isExposedToFire,
                       "a fire station next door did not cover the lot")

        // And the zones each risk applies to are respected: fire does not
        // threaten housing, so housing is never "exposed to fire".
        let homes = lot(.residential, density: 3)
        XCTAssertFalse(TileReport.make(at: origin, in: homes).isExposedToFire)
        XCTAssertTrue(TileReport.make(at: origin, in: homes).isExposedToCrime)
    }

    /// **`isExposed` and what `apply` actually does must not come apart.**
    ///
    /// The inspector, the crime overlay and the hazard roll all ask "can this
    /// be struck", and until they shared one definition they each had their
    /// own. Grow a city, fire every hazard that can fire, and check that
    /// nothing `isExposed` called safe was hit.
    func testNothingCalledSafeIsEverActuallyStruck() {
        let spec = PlaytestHarness.spec()
        let (controller, _) = PlaytestHarness.runScenario(spec, ticks: 0, seed: 31)
        for _ in 0 ..< 90 { controller.advanceSimulation() }

        let before = controller.map
        let field = ZoneDistanceField.compute(for: before)
        var rng = AlwaysZeroRNG() // every hazard that *can* fire, does
        let (_, strikes) = CityHazards.apply(to: before, using: &rng)

        XCTAssertGreaterThan(strikes.count, 0, "precondition: nothing was struck, so nothing was checked")
        for strike in strikes {
            let risk = strike.coveringService == .fireStation ? CityHazards.fire : CityHazards.crime
            XCTAssertTrue(
                CityHazards.isExposed(before[strike.position], to: risk, in: before, using: field),
                "\(strike.position) was struck by \(strike.coveringService.rawValue) after being "
                + "reported safe — the overlay is promising protection the simulation does not honour"
            )
        }
    }

    /// An empty lot cannot be robbed or burned, whatever the coverage is.
    func testAnUndevelopedLotIsNotExposedToAnything() {
        let map = lot(.industrial, density: 0)
        let report = TileReport.make(at: origin, in: map)
        XCTAssertFalse(report.isExposedToFire)
        XCTAssertFalse(report.isExposedToCrime)
    }

    func testWornInfrastructureNearbyShowsUpOnTheLot() {
        var map = lot(density: 2)
        XCTAssertEqual(TileReport.make(at: origin, in: map).infrastructureCondition, 1,
                       "a brand new lot is already reporting wear")

        map[GridPosition(x: 1, y: 2)].wear = 0.6
        XCTAssertEqual(TileReport.make(at: origin, in: map).infrastructureCondition,
                       0.4, accuracy: 1e-9,
                       "the worn road fronting this lot was not noticed")
    }

    func testCongestionComesFromTheRoadsFrontingTheLotNotTheLotItself() {
        var map = CityMap(width: 14, height: 8)
        for x in 0 ..< 12 { map[GridPosition(x: x, y: 2)].zone = .road }
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 10, y: 0))
        for cell in map.footprintCells(origin: GridPosition(x: 0, y: 0), size: 2) { map[cell].density = 5 }
        for cell in map.footprintCells(origin: GridPosition(x: 10, y: 0), size: 2) { map[cell].density = 5 }
        map.trafficLoad = Traffic.computeLoad(for: map)

        XCTAssertGreaterThan(TileReport.make(at: GridPosition(x: 0, y: 0), in: map).congestion, 0,
                             "a lot on a commuter route reports no congestion")
    }

    // MARK: - Can the people who live here reach work?

    /// The signal the router already computed every tick and discarded.
    func testHousingKnowsWhetherItsCommuteFoundAJob() {
        var map = CityMap(width: 16, height: 8)
        for x in 0 ..< 14 { map[GridPosition(x: x, y: 2)].zone = .road }
        map.placeBuilding(zone: .residential, origin: origin)
        for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = 3 }

        // No jobs anywhere: `computeLoad` returns before it routes a single
        // commute, which is exactly why the flag records employment rather
        // than unemployment — a set of failures would come back empty here and
        // report full employment in a city with no work in it at all.
        map.trafficLoad = Traffic.computeLoad(for: map)
        XCTAssertEqual(TileReport.make(at: origin, in: map).commuteFound, false,
                       "a city with no jobs at all reported its residents employed")

        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 10, y: 0))
        for cell in map.footprintCells(origin: GridPosition(x: 10, y: 0), size: 2) {
            map[cell].density = 5
        }
        map.trafficLoad = Traffic.computeLoad(for: map)
        XCTAssertEqual(TileReport.make(at: origin, in: map).commuteFound, true,
                       "a home with a reachable job reported nobody could get to work")
    }

    /// `nil` means "not asked", and has to stay distinguishable from `false`.
    func testTheCommuteAnswerIsAbsentWhereItWouldBeMeaningless() {
        var map = lot(.commercial, density: 3)
        map.trafficLoad = Traffic.computeLoad(for: map)
        XCTAssertNil(TileReport.make(at: origin, in: map).commuteFound,
                     "a shop was asked whether its residents can reach work")

        let unbuilt = lot(.residential, density: 0)
        XCTAssertNil(TileReport.make(at: origin, in: unbuilt).commuteFound,
                     "an empty lot reported on the commute of nobody")

        // And a map that has never routed says nothing rather than claiming
        // everyone is out of work.
        let neverTicked = lot(.residential, density: 3)
        XCTAssertNil(TileReport.make(at: origin, in: neverTicked).commuteFound,
                     "a map that has never routed a commute claimed to know the answer")
    }

    // MARK: - The controller's side

    func testTheControllerRebuildsTheReportOnlyWhenTheLotChanges() {
        var map = lot(density: 2)
        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 6, y: 0))
        let controller = GameController(map: map, rng: AlwaysZeroRNG(),
                                        peakPopulation: Unlocks.everythingUnlocked)
        XCTAssertNil(controller.inspectedReport, "something is inspected before anything was hovered")

        controller.inspect(at: origin)
        XCTAssertEqual(controller.inspectedReport?.zone, .residential)

        // The far cell of the same 2×2 lot is the same building, and has to
        // give the same answer.
        controller.inspect(at: GridPosition(x: 1, y: 1))
        XCTAssertEqual(controller.inspectedReport?.density, 2)

        controller.inspect(at: GridPosition(x: 6, y: 0))
        XCTAssertEqual(controller.inspectedReport?.zone, .commercial)

        controller.inspect(at: nil)
        XCTAssertNil(controller.inspectedReport, "the panel stayed up after the cursor left the map")
    }

    /// A stationary pointer over a city that is ticking has to keep up. A
    /// panel showing last tick's answer is worse than one showing none,
    /// because it looks live.
    func testAStationaryPointerSeesTheCityChangeUnderIt() {
        var map = lot(density: 0)
        map.cityDemand = CityDemand(residential: 1, commercial: 1, industrial: 1)
        let controller = GameController(map: map, rng: AlwaysZeroRNG(),
                                        peakPopulation: Unlocks.everythingUnlocked)
        controller.inspect(at: origin)
        let before = controller.inspectedReport

        for _ in 0 ..< CitySimulator.constructionTicks(toReach: 1) + 1 {
            controller.advanceSimulation()
        }

        XCTAssertNotEqual(controller.inspectedReport, before,
                          "the inspector is still describing the city as it was")
    }

    /// Hovering bare ground has to produce something rather than crashing or
    /// lying — a hover tool that goes blank over a third of the map is worse
    /// than none.
    func testBareGroundReportsCleanly() {
        let map = lot()
        let report = TileReport.make(at: GridPosition(x: 20, y: 20), in: map)
        XCTAssertEqual(report.zone, .empty)
        XCTAssertEqual(report.status, .notGrowable)
        XCTAssertEqual(report.density, 0)
        XCTAssertFalse(report.isExposedToCrime)
    }
}
