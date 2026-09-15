import XCTest
@testable import AlphaPlusPlus

/// Every growable zone (residential/commercial/industrial) is a 2×2
/// footprint (`ZoneType.footprintSize`), so these tests place them with
/// `CityMap.placeBuilding(zone:origin:)` rather than poking a single tile's
/// `.zone` directly — a lone `map[position].zone = .residential` would
/// leave the *other* three cells of that footprint as whatever they
/// defaulted to, which `CitySimulator.advance` would still (correctly, per
/// its own contract) treat as part of the same building. Roads and transit
/// stops stay 1×1, so those are still set directly.
final class CitySimulatorTests: XCTestCase {

    func testRoadAdjacentTileGrowsOneLevelPerAdvance() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0)) // covers (0,0)-(1,1)
        map[GridPosition(x: 2, y: 0)].zone = .road // shares an edge with (1,0), just outside the footprint

        var rng = AlwaysZeroRNG()
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 1)
    }

    func testTileWithoutRoadAccessDoesNotGrow() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        // No road anywhere on the map.

        var rng = AlwaysZeroRNG()
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 0)
    }

    /// Locks in "orthogonal only": a road diagonal to the footprint's far
    /// corner touches it only at a point, not an edge, so it must not count
    /// as access.
    func testDiagonalOnlyRoadNeighborDoesNotCount() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0)) // covers (0,0)-(1,1)
        map[GridPosition(x: 2, y: 2)].zone = .road // diagonal to (1,1), the footprint's far corner

        var rng = AlwaysZeroRNG()
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 0)
    }

    func testDensityStopsGrowingAtMaxDensity() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 0, y: 0)].density = ZoneType.residential.maxDensity
        map[GridPosition(x: 2, y: 0)].zone = .road

        var rng = AlwaysZeroRNG()
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, ZoneType.residential.maxDensity)
    }

    func testEmptyAndRoadTilesAreUntouchedByAdvance() {
        var map = CityMap(width: 3, height: 3)
        map[GridPosition(x: 1, y: 0)].zone = .road
        // (0,0) stays .empty and is road-adjacent, but .empty has
        // maxDensity 0 — it should never accrue density regardless.

        var rng = AlwaysZeroRNG()
        let next = CitySimulator.advance(map, using: &rng)

        for tile in next.tiles {
            XCTAssertEqual(tile.density, 0)
        }
    }

    func testCommercialAndIndustrialGrowTheSameWayAsResidential() {
        var map = CityMap(width: 6, height: 6)
        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 0, y: 0)) // covers (0,0)-(1,1)
        map[GridPosition(x: 2, y: 0)].zone = .road // touches (1,0)
        map.placeBuilding(zone: .industrial, origin: GridPosition(x: 0, y: 3)) // covers (0,3)-(1,4), nowhere near a road

        var rng = AlwaysZeroRNG()
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 1)
        XCTAssertEqual(next[GridPosition(x: 0, y: 3)].density, 0)
    }

    // MARK: - Decay

    func testTileDecaysByOneWhenItHasNoRoadAccess() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 0, y: 0)].density = 3
        // No road adjacent — simulates a road that used to be there getting
        // bulldozed out from under an already-developed building.

        var rng = AlwaysZeroRNG()
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 2)
    }

    func testDecayStopsAtZeroRatherThanGoingNegative() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        // density defaults to 0, no road access.

        var rng = AlwaysZeroRNG()
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 0)
    }

    /// Sanity check on the growth/decay branch itself: having road access
    /// always means grow (or hold at cap), never decay, no matter what the
    /// building's current density already is.
    func testRoadAdjacentTileGrowsRatherThanDecays() {
        var map = CityMap(width: 5, height: 5)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 0, y: 0)].density = 2
        map[GridPosition(x: 2, y: 0)].zone = .road
        // Density 2 -> 3 crosses CitySimulator's water-required threshold,
        // so this fixture needs a real, connected supply -- a pipe
        // touching the building, connected to a funded tower.
        map[GridPosition(x: 2, y: 1)].hasPipe = true
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 3, y: 1))
        map.waterSupply = Water.computeSupply(for: map)

        var rng = AlwaysZeroRNG()
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 3)
    }

    // MARK: - Land value gates the final growth step

    /// A building touching exactly one road and nothing else sits at land
    /// value 0.75, which clears every growth threshold except the last
    /// (0.8) — so it should stall at density 4 despite still having road
    /// access.
    func testTileWithOnlyBareRoadAccessStallsBelowMaxDensity() {
        var map = CityMap(width: 5, height: 5)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0)) // covers (0,0)-(1,1)
        map[GridPosition(x: 0, y: 0)].density = 4
        map[GridPosition(x: 2, y: 0)].zone = .road // touches (1,0)

        var rng = AlwaysZeroRNG()
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 4)
    }

    /// The same building, but also within reach of a Police Station: land
    /// value climbs to ~0.917, clearing the 0.8 threshold for the final level.
    func testTileReachesMaxDensityWhenAlsoNearAService() {
        // Widened from the original 6x6: `LandValue` also penalizes land
        // near a power plant (`powerPlantPenaltyDistance`), so the plant
        // this test now needs to clear the power gate has to sit farther
        // than that penalty's own falloff distance from the residential
        // footprint — an ordinary 2×2-tower-sized gap isn't enough room.
        var map = CityMap(width: 14, height: 11)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0)) // covers (0,0)-(1,1)
        map[GridPosition(x: 0, y: 0)].density = 4
        map[GridPosition(x: 2, y: 0)].zone = .road // touches (1,0)
        map.placeBuilding(zone: .policeStation, origin: GridPosition(x: 0, y: 2)) // covers (0,2)-(1,3), distance 1 from (0,1)
        // Density 4 -> 5 crosses both the water- and power-required thresholds.
        map[GridPosition(x: 2, y: 1)].hasPipe = true
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 3, y: 1))
        map.waterSupply = Water.computeSupply(for: map)
        // A power-line run well clear of the water tower's footprint,
        // out to a plant placed far enough away (Manhattan distance 15
        // from (1,1), past the penalty's falloff distance of 8) that it
        // doesn't drag this same tile's land value back down.
        map[GridPosition(x: 2, y: 1)].hasPowerLine = true
        map[GridPosition(x: 2, y: 2)].hasPowerLine = true
        map[GridPosition(x: 2, y: 3)].hasPowerLine = true
        map[GridPosition(x: 2, y: 4)].hasPowerLine = true
        map[GridPosition(x: 2, y: 5)].hasPowerLine = true
        map[GridPosition(x: 3, y: 5)].hasPowerLine = true
        map[GridPosition(x: 4, y: 5)].hasPowerLine = true
        map[GridPosition(x: 5, y: 5)].hasPowerLine = true
        map[GridPosition(x: 6, y: 5)].hasPowerLine = true
        map[GridPosition(x: 7, y: 5)].hasPowerLine = true
        map[GridPosition(x: 8, y: 5)].hasPowerLine = true
        map[GridPosition(x: 9, y: 5)].hasPowerLine = true
        map[GridPosition(x: 9, y: 6)].hasPowerLine = true
        map[GridPosition(x: 9, y: 7)].hasPowerLine = true
        map[GridPosition(x: 9, y: 8)].hasPowerLine = true
        map.placeBuilding(zone: .powerPlant, origin: GridPosition(x: 10, y: 7)) // covers (10,7)-(12,9), touches (9,8)
        map.powerSupply = PowerGrid.computeSupply(for: map, outageActive: false)

        var rng = AlwaysZeroRNG()
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 5)
    }

    /// Caught by hands-on playtesting, not a unit test: the test right
    /// above places its Police Station touching the residential footprint
    /// directly, with no road between them — but that's not how two
    /// buildings actually relate in an ordinary road-grid city, where a
    /// station sits *across the street* from the block it serves. With the
    /// original `LandValue.serviceFalloffDistance` (8), that ordinary
    /// placement put the station at exactly distance 2 from the nearest
    /// residential cell, which computed to the exact same land value
    /// (0.75) bare road frontage already gives — so a station across the
    /// street never actually helped a zone clear density 5; only touching
    /// it directly (no road gap) did, a placement no normal city plan
    /// produces. This pins the fix: a station one ordinary road-width away
    /// must clear the level-5 threshold on its own.
    func testTileReachesMaxDensityWithAServiceAcrossAnOrdinaryRoad() {
        // Widened from the original 6x6: as with the test above, the power
        // plant needed to clear the new power gate has to sit past
        // `LandValue.powerPlantPenaltyDistance` (8) from the residential
        // footprint, or its own proximity penalty cancels out the land-value
        // boost this test is specifically checking for.
        var map = CityMap(width: 14, height: 11)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0)) // covers (0,0)-(1,1)
        map[GridPosition(x: 0, y: 0)].density = 4
        map[GridPosition(x: 2, y: 0)].zone = .road // the residential's own road frontage, touches (1,0)
        // The station sits across that same road, not touching the
        // residential footprint directly -- distance 2 from (1,0).
        map.placeBuilding(zone: .policeStation, origin: GridPosition(x: 3, y: 0))
        // A pipe run up the residential's other side (x=2, rows 1-3) to a
        // tower placed clear of the police station's own footprint.
        map[GridPosition(x: 2, y: 1)].hasPipe = true
        map[GridPosition(x: 2, y: 2)].hasPipe = true
        map[GridPosition(x: 2, y: 3)].hasPipe = true
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 3, y: 3)) // covers (3,3)-(4,4), touches (2,3)
        map.waterSupply = Water.computeSupply(for: map)
        // A power-line run that dog-legs around the water tower's footprint
        // (down past it at x=2, then across at row 6) out to a plant placed
        // far enough away (Manhattan distance 15 from (1,1)) to clear the
        // penalty distance above.
        map[GridPosition(x: 2, y: 1)].hasPowerLine = true
        map[GridPosition(x: 2, y: 2)].hasPowerLine = true
        map[GridPosition(x: 2, y: 3)].hasPowerLine = true
        map[GridPosition(x: 2, y: 4)].hasPowerLine = true
        map[GridPosition(x: 2, y: 5)].hasPowerLine = true
        map[GridPosition(x: 2, y: 6)].hasPowerLine = true
        map[GridPosition(x: 3, y: 6)].hasPowerLine = true
        map[GridPosition(x: 4, y: 6)].hasPowerLine = true
        map[GridPosition(x: 5, y: 6)].hasPowerLine = true
        map[GridPosition(x: 6, y: 6)].hasPowerLine = true
        map[GridPosition(x: 7, y: 6)].hasPowerLine = true
        map[GridPosition(x: 8, y: 6)].hasPowerLine = true
        map[GridPosition(x: 9, y: 6)].hasPowerLine = true
        map[GridPosition(x: 9, y: 7)].hasPowerLine = true
        map[GridPosition(x: 9, y: 8)].hasPowerLine = true
        map.placeBuilding(zone: .powerPlant, origin: GridPosition(x: 10, y: 7)) // covers (10,7)-(12,9), touches (9,8)
        map.powerSupply = PowerGrid.computeSupply(for: map, outageActive: false)

        var rng = AlwaysZeroRNG()
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 5)
    }

    // MARK: - Water gates growth from level 3 onward

    /// Below the water threshold, growth needs only road access + land
    /// value — this building reaches level 2 with no water anywhere.
    func testGrowthBelowTheWaterThresholdNeedsNoWaterSupply() {
        var map = CityMap(width: 6, height: 6)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 0, y: 0)].density = 1
        map[GridPosition(x: 2, y: 0)].zone = .road
        // No pipes, no tower anywhere.

        var rng = AlwaysZeroRNG()
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 2)
    }

    /// At the water threshold, the same building holds rather than
    /// growing — access and land value alone aren't enough anymore, and
    /// (like an insufficient land value) this holds the level rather than
    /// causing decay.
    func testGrowthAtTheWaterThresholdStallsWithoutAConnectedSupply() {
        var map = CityMap(width: 6, height: 6)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 0, y: 0)].density = 2
        map[GridPosition(x: 2, y: 0)].zone = .road
        // Still no pipes, no tower.

        var rng = AlwaysZeroRNG()
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 2)
    }

    /// The positive case: the same building, now with a real connected
    /// water supply, clears the threshold and reaches level 3.
    func testGrowthAtTheWaterThresholdSucceedsWithAConnectedSupply() {
        var map = CityMap(width: 6, height: 6)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0)) // covers (0,0)-(1,1)
        map[GridPosition(x: 0, y: 0)].density = 2
        map[GridPosition(x: 2, y: 0)].zone = .road
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 3, y: 1)) // covers (3,1)-(4,2)
        map[GridPosition(x: 2, y: 1)].hasPipe = true // one tile, touching both the residential's (1,1) and the tower's (3,1)
        map.waterSupply = Water.computeSupply(for: map)

        var rng = AlwaysZeroRNG()
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 3)
    }

    // MARK: - Transit as an alternate access

    /// A public transit stop alone, with no road anywhere, should be enough
    /// access to start growing — it's a second way to be "connected," not a
    /// lesser one.
    func testPublicTransitAloneProvidesAccessForGrowth() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0)) // covers (0,0)-(1,1)
        map[GridPosition(x: 2, y: 0)].zone = .publicTransit // touches (1,0)

        var rng = AlwaysZeroRNG()
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 1)
    }

    // MARK: - Highway and subway grant access exactly like their cheaper counterparts

    /// `.highway` is a pricier `.road`, not a different kind of connection —
    /// it must grant access exactly like a plain road does.
    func testHighwayAloneProvidesAccessForGrowth() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 2, y: 0)].zone = .highway

        var rng = AlwaysZeroRNG()
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 1)
    }

    /// `.subway` is a pricier `.publicTransit`, same relationship.
    func testSubwayAloneProvidesAccessForGrowth() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 2, y: 0)].zone = .subway

        var rng = AlwaysZeroRNG()
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 1)
    }

    // MARK: - Footprints grow/decay as one unit

    func testAllCellsOfAFootprintShareOneDensityAfterGrowth() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0)) // covers (0,0)-(1,1)
        map[GridPosition(x: 2, y: 0)].zone = .road

        var rng = AlwaysZeroRNG()
        let next = CitySimulator.advance(map, using: &rng)

        for cell in map.footprintCells(origin: GridPosition(x: 0, y: 0), size: 2) {
            XCTAssertEqual(next[cell].density, 1)
        }
    }

    func testAllCellsOfAFootprintShareOneDensityAfterDecay() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 0, y: 0)].density = 3
        // No road: every cell should decay together, not just the anchor.

        var rng = AlwaysZeroRNG()
        let next = CitySimulator.advance(map, using: &rng)

        for cell in map.footprintCells(origin: GridPosition(x: 0, y: 0), size: 2) {
            XCTAssertEqual(next[cell].density, 2)
        }
    }

    /// Access from *any one* corner of a footprint is enough for the whole
    /// building to grow — matches `LandValue`'s own max-not-sum philosophy:
    /// a building is as good as its best-served cell.
    func testAccessFromAnyFootprintCellIsEnoughForTheWholeBuilding() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0)) // covers (0,0)-(1,1)
        map[GridPosition(x: 2, y: 1)].zone = .road // touches (1,1), the *opposite* corner from the anchor

        var rng = AlwaysZeroRNG()
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 1)
    }

    // MARK: - Demand gates growth too, as a probability, not a hard wall

    /// Every other gate in this file passes deterministically, but a
    /// building whose type the city is drowning in should still be able
    /// to hold rather than grow — this pins down that a low-demand roll
    /// can actually block growth, not just theoretically exist.
    func testStronglyNegativeDemandCanBlockGrowth() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 2, y: 0)].zone = .road
        map.cityDemand = CityDemand(residential: -1, commercial: 0, industrial: 0)

        var rng = AlwaysMaxRNG() // guaranteed to fail any chance below 1.0
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 0)
    }

    /// At the bottom of the demand range, growth stops outright -- even for a
    /// generator that always rolls the lowest possible value, which clears
    /// every other probability gate in this file.
    ///
    /// This used to assert the opposite, back when `minimumGrowthChance` was
    /// 0.05 so that oversupply was a slowdown rather than a wall. A design
    /// playtest showed what that trickle actually bought: zoning every lot
    /// residential reached 5,152 population against a balanced city's 3,320,
    /// because 5% per tick over hundreds of ticks is simply a slower route to
    /// the same maximum. Oversupply now genuinely stops growth.
    func testStronglyNegativeDemandStopsGrowthEntirely() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 2, y: 0)].zone = .road
        map.cityDemand = CityDemand(residential: -1, commercial: 0, industrial: 0)

        var rng = AlwaysZeroRNG()
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 0)
    }

    /// Past `abandonmentDemand`, an oversupplied building doesn't just stall
    /// -- it loses a level. This is what makes over-zoning a decision with a
    /// cost rather than one that merely wastes time.
    func testDeepOversupplyAbandonsAnExistingBuilding() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 2, y: 0)].zone = .road
        for cell in map.footprintCells(origin: GridPosition(x: 0, y: 0), size: 2) {
            map[cell].density = 3
        }
        map.cityDemand = CityDemand(residential: -1, commercial: 0, industrial: 0)

        var rng = AlwaysZeroRNG() // always clears the abandonment roll
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 2)
    }

    /// Abandonment must not fire on ordinary, transient imbalance -- the kind
    /// a growing city passes through constantly. Demand just above the
    /// threshold stalls growth without tearing anything down.
    func testMildOversupplyStallsGrowthWithoutAbandonment() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 2, y: 0)].zone = .road
        for cell in map.footprintCells(origin: GridPosition(x: 0, y: 0), size: 2) {
            map[cell].density = 3
        }
        map.cityDemand = CityDemand(residential: -0.5, commercial: 0, industrial: 0)

        var rng = AlwaysMaxRNG() // fails the growth roll, so only decay could move this
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 3)
    }

    /// An empty lot at deep oversupply has nothing to abandon, and must not
    /// underflow past density 0.
    func testAbandonmentNeverDrivesDensityBelowZero() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 2, y: 0)].zone = .road
        map.cityDemand = CityDemand(residential: -1, commercial: 0, industrial: 0)

        var rng = AlwaysZeroRNG()
        var next = map
        for _ in 0 ..< 5 { next = CitySimulator.advance(next, using: &rng) }

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 0)
    }

    /// Strongly positive demand is a guaranteed grow, matching demand 0's
    /// (a fresh, uncomputed `CityDemand`) already-passing behavior in
    /// every test above -- demand can only ever help or leave growth
    /// alone here, never require a lucky roll on top of already-positive
    /// demand.
    func testStronglyPositiveDemandGuaranteesGrowthEvenOnAnUnluckyRoll() {
        var map = CityMap(width: 3, height: 3)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 2, y: 0)].zone = .road
        map.cityDemand = CityDemand(residential: 1, commercial: 0, industrial: 0)

        var rng = AlwaysMaxRNG()
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 1)
    }

    /// Demand is read per zone type, not one shared number -- a building
    /// the city desperately wants shouldn't be blocked by another type
    /// being oversupplied.
    func testDemandIsReadPerZoneTypeNotShared() {
        var map = CityMap(width: 6, height: 6)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0)) // covers (0,0)-(1,1)
        map[GridPosition(x: 2, y: 0)].zone = .road // touches (1,0)
        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 0, y: 3)) // covers (0,3)-(1,4)
        map[GridPosition(x: 2, y: 3)].zone = .road // touches (1,3)
        map.cityDemand = CityDemand(residential: 1, commercial: -1, industrial: -1)

        var rng = AlwaysMaxRNG() // fails anything short of a guaranteed 1.0 chance
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 1) // residential: demand 1 -> guaranteed
        XCTAssertEqual(next[GridPosition(x: 0, y: 3)].density, 0) // commercial: demand -1 -> blocked on this roll
    }
}
