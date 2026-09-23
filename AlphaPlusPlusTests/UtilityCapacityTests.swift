import XCTest
@testable import AlphaPlusPlus

/// Tests for utility capacity — the mechanic that makes a *growing* city keep
/// asking for something, rather than being finished with its infrastructure
/// the moment it is first connected.
@MainActor
final class UtilityCapacityTests: XCTestCase {

    /// Laying a power line changes what is supplied *immediately*, not on the
    /// next tick.
    ///
    /// **The bug this pins.** Supply was recomputed only inside
    /// `advanceSimulation()`, and the game starts paused — so a player could
    /// lay an entire network, watch the Power overlay stay stubbornly dark, and
    /// reasonably conclude the mechanic was broken. The markers appeared,
    /// because those read `Tile.hasPowerLine` directly; the supply colouring
    /// did not, because it reads a cached field nobody had recomputed.
    ///
    /// Nothing ticks in this test on purpose. That is the whole point.
    @MainActor
    func testLayingAPowerLineSuppliesImmediatelyWithoutATick() {
        let controller = GameController(peakPopulation: Unlocks.everythingUnlocked)
        let plant = GridPosition(x: 2, y: 2)
        controller.selectTool(.generator)
        _ = controller.place(at: plant)

        // Far enough away to be outside the direct-supply radius.
        let far = GridPosition(x: 12, y: 2)
        XCTAssertFalse(PowerGrid.hasSupply(at: far, in: controller.map),
                       "precondition: the far tile should start unpowered")

        for x in 3 ... 12 {
            _ = controller.layPowerLine(at: GridPosition(x: x, y: 2))
        }
        XCTAssertTrue(
            PowerGrid.hasSupply(at: far, in: controller.map),
            "a completed power line did not supply anything until a tick ran — this is what made the overlay look broken"
        )

        controller.removePowerLine(at: GridPosition(x: 8, y: 2))
        XCTAssertFalse(
            PowerGrid.hasSupply(at: far, in: controller.map),
            "cutting the line did not disconnect anything until a tick ran"
        )
    }

    /// The same for water, which is a separate network with the same shape.
    @MainActor
    func testLayingPipeSuppliesImmediatelyWithoutATick() {
        let controller = GameController(peakPopulation: Unlocks.everythingUnlocked)
        controller.selectTool(.waterPump)
        _ = controller.place(at: GridPosition(x: 2, y: 6))

        let far = GridPosition(x: 12, y: 6)
        XCTAssertFalse(Water.hasSupply(at: far, in: controller.map))
        for x in 3 ... 12 {
            _ = controller.layPipe(at: GridPosition(x: x, y: 6))
        }
        XCTAssertTrue(Water.hasSupply(at: far, in: controller.map),
                      "a completed pipe run did not supply anything until a tick ran")
    }


    /// A map with `towers` water towers, `plants` power plants and `lots`
    /// residential buildings at `density`.
    ///
    /// Every tile carries a pipe and a power line, which is not how a player
    /// would build but is exactly what these tests want: it removes network
    /// topology from the question entirely, so a failure here means capacity,
    /// not a lot that happened to sit one tile off the main.
    private func makeCity(
        towers: Int,
        plants: Int,
        lots: Int,
        density: Int = 5,
        size: Int = 40
    ) -> CityMap {
        var map = CityMap(width: size, height: size)
        for tile in map.tiles {
            map[tile.position].hasPipe = true
            map[tile.position].hasPowerLine = true
        }
        for x in 0 ..< size {
            map.placeBuilding(zone: .road, origin: GridPosition(x: x, y: 0))
        }

        var x = 0
        for _ in 0 ..< towers {
            map.placeBuilding(zone: .waterTower, origin: GridPosition(x: x, y: 2))
            x += 2
        }
        x = 0
        for _ in 0 ..< plants {
            map.placeBuilding(zone: .powerPlant, origin: GridPosition(x: x, y: 5))
            x += 3
        }

        // Lot rows every 3, with a road row immediately under each so the
        // lots actually have access. Without that they simply never grow, and
        // a test about capacity quietly becomes a test about nothing.
        x = 0
        var y = 10
        for x2 in 0 ..< size {
            map.placeBuilding(zone: .road, origin: GridPosition(x: x2, y: y + 2))
        }
        for _ in 0 ..< lots {
            if x + 1 >= size {
                x = 0
                y += 3
                guard y + 2 < size else { break }
                for x2 in 0 ..< size {
                    map.placeBuilding(zone: .road, origin: GridPosition(x: x2, y: y + 2))
                }
            }
            guard y + 1 < size else { break }
            map.placeBuilding(zone: .residential, origin: GridPosition(x: x, y: y))
            for cell in map.footprintCells(origin: GridPosition(x: x, y: y), size: 2) {
                map[cell].density = density
            }
            x += 2
        }
        return map
    }

    /// Enough fully-grown lots to exceed `capacity` — derived rather than
    /// hardcoded, so retuning `capacityPerTower`/`capacityPerPlant` doesn't
    /// silently turn these into tests of nothing.
    private func lotsToExceed(_ capacity: Int, density: Int = 5) -> Int {
        capacity / density + 2
    }

    // MARK: - The load itself

    func testDemandIsTotalDensityAcrossGrowableZones() {
        let map = makeCity(towers: 1, plants: 1, lots: 3, density: 4)

        // 3 lots × density 4, counted once per building.
        XCTAssertEqual(UtilityLoad.demand(in: map), 12)
    }

    func testCapacityScalesWithHowManyPlantsYouBuilt() {
        let one = makeCity(towers: 1, plants: 1, lots: 0)
        let three = makeCity(towers: 3, plants: 3, lots: 0)

        XCTAssertEqual(Water.load(in: one).capacity, Water.capacityPerTower)
        XCTAssertEqual(Water.load(in: three).capacity, Water.capacityPerTower * 3)
        XCTAssertEqual(PowerGrid.load(in: three).capacity, PowerGrid.capacityPerPlant * 3)
    }

    /// Funding buys throughput now, not only coverage — halving the budget
    /// halves what the plants can carry.
    func testFundingScalesCapacity() {
        var map = makeCity(towers: 2, plants: 2, lots: 0)
        let fullCapacity = Water.load(in: map).capacity

        map.serviceFunding.setLevel(0.5, for: .waterTower)

        XCTAssertEqual(Water.load(in: map).capacity, fullCapacity / 2)
    }

    func testAnEmptyCityIsNotOverloaded() {
        let map = makeCity(towers: 1, plants: 1, lots: 0)

        XCTAssertFalse(Water.load(in: map).isOverloaded)
        XCTAssertFalse(PowerGrid.load(in: map).isOverloaded)
    }

    /// A city with demand but no plants at all is overloaded, not merely
    /// disconnected — and must not divide by zero working that out.
    func testDemandWithNoPlantsIsOverloaded() {
        let map = makeCity(towers: 0, plants: 0, lots: 4)

        XCTAssertTrue(Water.load(in: map).isOverloaded)
        XCTAssertEqual(Water.load(in: map).overloadFraction, 1)
    }

    // MARK: - What overload does

    func testWaterSupplyFailsWhenOverCapacity() {
        let overloaded = makeCity(towers: 1, plants: 1, lots: lotsToExceed(Water.capacityPerTower))
        XCTAssertTrue(Water.load(in: overloaded).isOverloaded, "the fixture is not actually over capacity")

        var map = overloaded
        map.waterSupply = Water.computeSupply(for: map)

        XCTAssertFalse(
            Water.hasSupply(at: GridPosition(x: 0, y: 12), in: map),
            "an overloaded network still supplied water"
        )
    }

    func testPowerSupplyFailsWhenOverCapacity() {
        let overloaded = makeCity(towers: 1, plants: 1, lots: lotsToExceed(PowerGrid.capacityPerPlant))
        XCTAssertTrue(PowerGrid.load(in: overloaded).isOverloaded, "the fixture is not actually over capacity")

        var map = overloaded
        map.powerSupply = PowerGrid.computeSupply(for: map, outageActive: false)

        XCTAssertFalse(PowerGrid.hasSupply(at: GridPosition(x: 0, y: 12), in: map))
    }

    /// The fix has to actually work: build another plant and the network comes
    /// back. Without this, overload would be a dead end rather than a prompt.
    func testBuildingAnotherPlantRestoresSupply() {
        var map = makeCity(towers: 1, plants: 1, lots: lotsToExceed(Water.capacityPerTower))
        XCTAssertTrue(Water.load(in: map).isOverloaded, "the fixture is not actually over capacity")

        // Enough towers to cover the demand.
        var x = 4
        while Water.load(in: map).isOverloaded {
            map.placeBuilding(zone: .waterTower, origin: GridPosition(x: x, y: 2))
            x += 2
            if x > 36 { break }
        }
        map.waterSupply = Water.computeSupply(for: map)

        XCTAssertFalse(Water.load(in: map).isOverloaded)
        XCTAssertTrue(
            Water.hasSupply(at: GridPosition(x: 0, y: 12), in: map),
            "adding capacity did not bring the network back"
        )
    }

    /// A city comfortably within capacity behaves exactly as it did before
    /// capacity existed — this must be invisible until you outgrow it.
    func testAnUnderCapacityCityIsSuppliedNormally() {
        var map = makeCity(towers: 4, plants: 4, lots: 4)
        XCTAssertFalse(Water.load(in: map).isOverloaded)

        map.waterSupply = Water.computeSupply(for: map)
        map.powerSupply = PowerGrid.computeSupply(for: map, outageActive: false)

        XCTAssertTrue(Water.hasSupply(at: GridPosition(x: 0, y: 12), in: map))
        XCTAssertTrue(PowerGrid.hasSupply(at: GridPosition(x: 0, y: 12), in: map))
    }

    // MARK: - End to end

    /// The point of the whole mechanic: a city that keeps growing eventually
    /// outgrows its utilities and stalls there until the player builds more.
    ///
    /// Drives `CitySimulator.advance` directly, recomputing water each tick,
    /// rather than going through `advanceSimulation()` — the same isolation
    /// `PollutionTests` uses. That keeps hazards out of it (under
    /// `AlwaysZeroRNG` every hazard fires every tick, so an unprotected city
    /// is levelled and never reaches the growth this is about) and keeps
    /// demand fixed, so the only thing that can stall growth is capacity.
    func testAGrowingCityStallsOnceItOutgrowsItsWaterTower() {
        // Sized against density *4*, not 5. A lot with plain road frontage
        // tops out at land value 0.75, and `CitySimulator.requiredLandValue`
        // asks 0.8 for density 5 — so without extra amenities these lots can
        // never reach full density, and sizing the fixture for 5 leaves the
        // city permanently under capacity with nothing to measure.
        var map = makeCity(towers: 1, plants: 1, lots: lotsToExceed(Water.capacityPerTower, density: 4), density: 0)
        map.cityDemand = CityDemand(residential: 1, commercial: 0, industrial: 0)

        var rng = AlwaysZeroRNG()
        var sawOverload = false
        for _ in 0 ..< ticksToBuild(toLevel: ZoneType.residential.maxDensity) {
            // Both networks, not just water: density 4 needs power, so leaving
            // `powerSupply` uncomputed stalls growth at 3 and the city never
            // draws enough to test anything.
            map.waterSupply = Water.computeSupply(for: map)
            map.powerSupply = PowerGrid.computeSupply(for: map, outageActive: false)
            map = CitySimulator.advance(map, using: &rng)
            if Water.load(in: map).isOverloaded { sawOverload = true }
        }

        XCTAssertTrue(
            sawOverload,
            "a city grew all the way out on a single water tower — capacity is not binding"
        )

        // And the stall is real: nothing reached the densities that need water.
        let densities = map.tiles.filter { $0.isBuildingAnchor && $0.zone == .residential }.map(\.density)
        XCTAssertFalse(densities.isEmpty)
        XCTAssertLessThan(
            densities.max() ?? 0, ZoneType.residential.maxDensity,
            "buildings reached full density despite the water network being over capacity"
        )
        XCTAssertGreaterThan(densities.max() ?? 0, 0, "the fixture never grew at all")
    }

    // MARK: - Serving without pipes

    /// The move a new player actually makes: drop a pump next to the houses.
    ///
    /// It used to do nothing. Supply required an unbroken pipe run, and laying
    /// pipe means finding the Water overlay first — so a starter city sat
    /// there showing "no water" warnings with a pump right beside it.
    func testAPumpServesNearbyBuildingsWithNoPipesAtAll() {
        var map = CityMap(width: 20, height: 20)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map.placeBuilding(zone: .waterPump, origin: GridPosition(x: 3, y: 0))
        XCTAssertFalse(map.tiles.contains { $0.hasPipe }, "the fixture must have no pipes at all")

        map.waterSupply = Water.computeSupply(for: map)

        XCTAssertTrue(
            Water.hasSupply(at: GridPosition(x: 0, y: 0), in: map),
            "a pump three tiles away supplied nothing without pipes"
        )
    }

    func testAGeneratorPowersNearbyBuildingsWithNoLinesAtAll() {
        var map = CityMap(width: 20, height: 20)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map.placeBuilding(zone: .generator, origin: GridPosition(x: 3, y: 0))
        XCTAssertFalse(map.tiles.contains { $0.hasPowerLine })

        map.powerSupply = PowerGrid.computeSupply(for: map, outageActive: false)

        XCTAssertTrue(PowerGrid.hasSupply(at: GridPosition(x: 0, y: 0), in: map))
    }

    /// The radius is deliberately short, so a city of any size still has to lay
    /// a real network — direct service is a starting convenience, not a
    /// replacement for pipes.
    func testDirectServiceDoesNotReachAcrossTheMap() {
        var map = CityMap(width: 30, height: 30)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 20, y: 20))

        map.waterSupply = Water.computeSupply(for: map)

        XCTAssertFalse(Water.hasSupply(at: GridPosition(x: 0, y: 0), in: map))
    }

    /// Pipes still do their job: they carry supply well past the direct radius.
    func testPipesExtendSupplyBeyondTheDirectRadius() {
        var map = CityMap(width: 30, height: 30)
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 0, y: 0))
        for x in 0 ..< 25 {
            map[GridPosition(x: x, y: 2)].hasPipe = true
        }
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 22, y: 3))

        map.waterSupply = Water.computeSupply(for: map)

        XCTAssertGreaterThan(
            GridPosition(x: 22, y: 3).manhattanDistance(to: GridPosition(x: 0, y: 0)),
            Water.directSupplyRadius,
            "the fixture is inside the direct radius, so it proves nothing about pipes"
        )
        XCTAssertTrue(Water.hasSupply(at: GridPosition(x: 22, y: 3), in: map))
    }

    /// Direct service is still service: going over capacity cuts it off along
    /// with everything else, or a player could dodge capacity entirely by
    /// clustering buildings around the plant.
    func testDirectServiceStopsWhenTheNetworkIsOverloaded() {
        var map = makeCity(towers: 1, plants: 1, lots: lotsToExceed(Water.capacityPerTower))
        XCTAssertTrue(Water.load(in: map).isOverloaded)

        map.waterSupply = Water.computeSupply(for: map)

        // A lot right beside the tower at (0,2), well inside the direct radius.
        XCTAssertFalse(Water.hasSupply(at: GridPosition(x: 0, y: 4), in: map))
    }

    /// An unfunded utility serves nobody, near or far.
    func testDefundingCutsOffDirectServiceToo() {
        var map = CityMap(width: 20, height: 20)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map.placeBuilding(zone: .waterPump, origin: GridPosition(x: 3, y: 0))
        map.serviceFunding.setLevel(0, for: .waterTower)

        map.waterSupply = Water.computeSupply(for: map)

        XCTAssertFalse(Water.hasSupply(at: GridPosition(x: 0, y: 0), in: map))
    }
}
