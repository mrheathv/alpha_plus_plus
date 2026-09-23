import XCTest
@testable import AlphaPlusPlus

/// Tests for `Pollution` — the first mechanic in the game that makes *where*
/// you put something matter.
@MainActor
final class PollutionTests: XCTestCase {

    /// Places a fully-grown industrial building and returns the computed field.
    private func pollutedMap(
        size: Int = 30,
        industrialOrigins: [GridPosition],
        density: Int = 5
    ) -> CityMap {
        var map = CityMap(width: size, height: size)
        for origin in industrialOrigins {
            map.placeBuilding(zone: .industrial, origin: origin)
            for cell in map.footprintCells(origin: origin, size: 2) {
                map[cell].density = density
            }
        }
        map.pollution = Pollution.compute(for: map)
        return map
    }

    // MARK: - The field itself

    func testAFreshMapIsClean() {
        let map = CityMap(width: 10, height: 10)

        XCTAssertTrue(map.pollution.isEmpty)
        XCTAssertEqual(map.pollution.level(at: GridPosition(x: 5, y: 5)), 0)
    }

    func testCleanCityWithNoIndustryStaysClean() {
        var map = CityMap(width: 10, height: 10)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        for cell in map.footprintCells(origin: GridPosition(x: 0, y: 0), size: 2) {
            map[cell].density = 5
        }
        map.pollution = Pollution.compute(for: map)

        XCTAssertTrue(map.pollution.isEmpty, "something other than industry is polluting")
    }

    /// Zoned-but-unbuilt industry emits nothing — an empty lot isn't a factory.
    func testUndevelopedIndustryDoesNotPollute() {
        let map = pollutedMap(industrialOrigins: [GridPosition(x: 10, y: 10)], density: 0)

        XCTAssertTrue(map.pollution.isEmpty)
    }

    func testPollutionIsStrongestAtTheSourceAndFallsOffWithDistance() {
        let origin = GridPosition(x: 12, y: 12)
        let map = pollutedMap(industrialOrigins: [origin])

        let atSource = map.pollution.level(at: origin)
        let nearby = map.pollution.level(at: GridPosition(x: 12 + 3, y: 12))
        let far = map.pollution.level(at: GridPosition(x: 12 + Pollution.radius + 2, y: 12))

        XCTAssertGreaterThan(atSource, nearby)
        XCTAssertGreaterThan(nearby, far)
        XCTAssertEqual(far, 0, "pollution reached past its own radius")
    }

    /// Denser industry is dirtier — the same reason density drives everything
    /// else in the simulation.
    func testDenserIndustryPollutesMore() {
        let origin = GridPosition(x: 12, y: 12)
        let light = pollutedMap(industrialOrigins: [origin], density: 1)
        let heavy = pollutedMap(industrialOrigins: [origin], density: 5)

        XCTAssertGreaterThan(
            heavy.pollution.level(at: origin),
            light.pollution.level(at: origin)
        )
    }

    /// The property that makes this worth a whole field rather than reusing
    /// `LandValue.falloffValue(nearestZone:)`: an industrial *district* is
    /// worse than a lone factory, and "distance to the nearest one" cannot
    /// tell those apart.
    func testPollutionFromSeveralFactoriesStacks() {
        let lone = pollutedMap(industrialOrigins: [GridPosition(x: 12, y: 12)], density: 2)
        let cluster = pollutedMap(
            industrialOrigins: [
                GridPosition(x: 12, y: 12),
                GridPosition(x: 14, y: 12),
                GridPosition(x: 12, y: 14),
            ],
            density: 2
        )

        let between = GridPosition(x: 13, y: 13)
        XCTAssertGreaterThan(
            cluster.pollution.level(at: between),
            lone.pollution.level(at: between),
            "several factories pollute no more than one — stacking is not happening"
        )
    }

    func testPollutionNeverExceedsOne() {
        // A dense wall of heavy industry, all overlapping the same tiles.
        let origins = (0 ..< 5).flatMap { x in (0 ..< 5).map { y in GridPosition(x: x * 2, y: y * 2) } }
        let map = pollutedMap(industrialOrigins: origins)

        for tile in map.tiles {
            XCTAssertLessThanOrEqual(map.pollution.level(at: tile.position), 1.0)
        }
    }

    // MARK: - What it does to land value

    /// The whole point: a lot next to heavy industry is worth less than the
    /// same lot far from it.
    func testPollutionLowersLandValue() {
        let factory = GridPosition(x: 12, y: 12)
        var map = pollutedMap(industrialOrigins: [factory])
        // Road frontage for both lots, so the comparison is about pollution
        // rather than about access.
        for x in 0 ..< map.width {
            map.placeBuilding(zone: .road, origin: GridPosition(x: x, y: 16))
        }
        map.pollution = Pollution.compute(for: map)

        let nearIndustry = LandValue.value(at: GridPosition(x: 12, y: 15), in: map)
        let awayFromIndustry = LandValue.value(at: GridPosition(x: 26, y: 15), in: map)

        XCTAssertGreaterThan(awayFromIndustry, nearIndustry, "pollution did not depress land value")
    }

    /// Land value floors at 0 rather than going negative, same as it already
    /// did for the power-plant penalty.
    func testLandValueNeverGoesNegativeFromPollution() {
        let origins = (0 ..< 5).flatMap { x in (0 ..< 5).map { y in GridPosition(x: x * 2, y: y * 2) } }
        let map = pollutedMap(industrialOrigins: origins)

        for tile in map.tiles {
            XCTAssertGreaterThanOrEqual(LandValue.value(at: tile.position, in: map), 0)
        }
    }

    /// An unpolluted city must value land exactly as it did before this
    /// mechanic existed — pollution has to be invisible when there's none.
    func testLandValueIsUnchangedWhereThereIsNoPollution() {
        var map = CityMap(width: 20, height: 20)
        for x in 0 ..< map.width {
            map.placeBuilding(zone: .road, origin: GridPosition(x: x, y: 10))
        }
        let position = GridPosition(x: 5, y: 11)

        let beforeComputing = LandValue.value(at: position, in: map)
        map.pollution = Pollution.compute(for: map)
        let afterComputing = LandValue.value(at: position, in: map)

        XCTAssertEqual(beforeComputing, afterComputing, accuracy: 1e-12)
    }

    /// Regression: `value(at:in:)` is legitimately asked about positions off
    /// the map — `LandValueTests` checks that a falloff reaches zero past the
    /// edge — and `CityMap`'s subscript *traps* out of bounds. Reading the
    /// tile's own zone for pollution sensitivity crashed two existing tests
    /// until it was guarded.
    func testLandValueSurvivesBeingAskedAboutOffMapPositions() {
        let map = pollutedMap(industrialOrigins: [GridPosition(x: 12, y: 12)])

        XCTAssertEqual(LandValue.value(at: GridPosition(x: -5, y: 3), in: map), 0, accuracy: 1e-12)
        XCTAssertEqual(LandValue.value(at: GridPosition(x: 3, y: map.height + 4), in: map), 0, accuracy: 1e-12)
    }

    /// Residents mind pollution most and factories barely mind it at all —
    /// the asymmetry that makes separating them worth doing. Without it,
    /// concentrating industry just moves the penalty onto the industry and
    /// planning is a wash.
    func testResidentsMindPollutionMoreThanFactoriesDo() {
        XCTAssertGreaterThan(
            LandValue.pollutionSensitivity(of: .residential),
            LandValue.pollutionSensitivity(of: .commercial)
        )
        XCTAssertGreaterThan(
            LandValue.pollutionSensitivity(of: .commercial),
            LandValue.pollutionSensitivity(of: .industrial)
        )
    }

    // MARK: - End to end

    /// Separating housing from industry has to actually pay off, or the
    /// mechanic is just a tax on zoning industry at all.
    ///
    /// Drives `CitySimulator.advance` directly rather than going through
    /// `GameController.advanceSimulation()`, and pins `cityDemand` neutral.
    /// That is not avoiding the real thing — it is *isolating* it. A fixture
    /// with three factories and one house has wildly negative industrial
    /// demand, so the industry abandons itself down to density 3 within a few
    /// ticks and takes its own pollution with it; the first version of this
    /// test measured exactly that and reported both lots growing equally.
    /// Holding demand still keeps the comparison about land value, which is
    /// the channel pollution actually works through.
    func testPollutionCapsGrowthAtALowerDensity() {
        func grownDensity(residentialAt home: GridPosition) -> Int {
            var map = CityMap(width: 40, height: 40)
            for x in 0 ..< map.width {
                map.placeBuilding(zone: .road, origin: GridPosition(x: x, y: 20))
            }
            // Heavy industry parked at one end, held at full density.
            for y in stride(from: 14, to: 20, by: 2) {
                map.placeBuilding(zone: .industrial, origin: GridPosition(x: 2, y: y))
                for cell in map.footprintCells(origin: GridPosition(x: 2, y: y), size: 2) {
                    map[cell].density = 5
                }
            }
            // Water, so density 3 is reachable at all — otherwise both lots cap
            // at 2 on `CitySimulator.waterRequiredFromLevel` and this would
            // measure the water gate instead.
            map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 0, y: 24))
            for x in 0 ..< map.width {
                map[GridPosition(x: x, y: 20)].hasPipe = true
            }
            for y in 20 ... 24 {
                map[GridPosition(x: 0, y: y)].hasPipe = true
            }

            map.placeBuilding(zone: .residential, origin: home)
            map.cityDemand = CityDemand() // neutral, so demand never gates or abandons
            map.pollution = Pollution.compute(for: map)
            // `CitySimulator.advance` reads these caches but never fills them —
            // that is `GameController.advanceSimulation()`'s job, which this
            // test deliberately bypasses. Without this the water gate, not
            // pollution, decides both outcomes.
            map.waterSupply = Water.computeSupply(for: map)

            var rng = AlwaysZeroRNG()
            var next = map
            for _ in 0 ..< ticksToBuild(toLevel: ZoneType.residential.maxDensity) {
                next = CitySimulator.advance(next, using: &rng)
            }
            return next[home].density
        }

        let beside = grownDensity(residentialAt: GridPosition(x: 4, y: 18))
        let away = grownDensity(residentialAt: GridPosition(x: 34, y: 18))

        XCTAssertGreaterThan(
            away, beside,
            "housing next to heavy industry grew just as well as housing far from it — "
            + "pollution is not creating a reason to plan a layout"
        )
    }
}
