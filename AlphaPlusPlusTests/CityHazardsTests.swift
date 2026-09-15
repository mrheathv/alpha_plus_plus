import XCTest
@testable import AlphaPlusPlus

final class CityHazardsTests: XCTestCase {

    /// The coverage gate (`coverage < threshold`) is deterministic
    /// regardless of the random draw — a well-covered tile should never be
    /// at risk, tested here without needing to force the RNG at all.
    func testWellCoveredTileIsNeverAtRisk() {
        var map = CityMap(width: 5, height: 5)
        let position = GridPosition(x: 0, y: 0)
        map[position].zone = .industrial
        map[position].density = 3
        map[GridPosition(x: 0, y: 1)].zone = .fireStation // distance 1 -> coverage ~0.917, well above the 0.3 threshold

        var rng = SystemRandomNumberGenerator()
        let result = CityHazards.apply([CityHazards.fire], to: map, using: &rng)

        XCTAssertEqual(result.map[position].density, 3)
        XCTAssertTrue(result.strikes.isEmpty)
    }

    /// `Double.random(in: 0..<1)` never actually returns 1.0, so a risk
    /// with `chancePerTick: 1` is a deterministic "always strikes" —
    /// exercising the mechanism itself without needing a seeded generator.
    func testUnprotectedTileIsAlwaysHitWhenChanceIsOne() {
        var map = CityMap(width: 5, height: 5)
        let position = GridPosition(x: 0, y: 0)
        map[position].zone = .industrial
        map[position].density = 3
        // No fire station anywhere -> coverage is 0, below any threshold.
        let guaranteedFire = CityHazards.Risk(
            zones: [.industrial], coveringService: .fireStation,
            coverageThreshold: 0.3, chancePerTick: 1.0, densityLoss: 2
        )

        var rng = SystemRandomNumberGenerator()
        let result = CityHazards.apply([guaranteedFire], to: map, using: &rng)

        XCTAssertEqual(result.map[position].density, 1) // 3 - 2
        XCTAssertEqual(result.strikes, [CityHazards.Strike(position: position, coveringService: .fireStation)])
    }

    /// Symmetric case: `chancePerTick: 0` never strikes, even with zero
    /// coverage — confirms the chance check itself, isolated from coverage.
    func testUnprotectedTileIsNeverHitWhenChanceIsZero() {
        var map = CityMap(width: 5, height: 5)
        let position = GridPosition(x: 0, y: 0)
        map[position].zone = .industrial
        map[position].density = 3
        let neverFire = CityHazards.Risk(
            zones: [.industrial], coveringService: .fireStation,
            coverageThreshold: 0.3, chancePerTick: 0.0, densityLoss: 2
        )

        var rng = SystemRandomNumberGenerator()
        let result = CityHazards.apply([neverFire], to: map, using: &rng)

        XCTAssertEqual(result.map[position].density, 3)
        XCTAssertTrue(result.strikes.isEmpty)
    }

    func testDensityLossFloorsAtZero() {
        var map = CityMap(width: 5, height: 5)
        let position = GridPosition(x: 0, y: 0)
        map[position].zone = .industrial
        map[position].density = 1
        let guaranteedFire = CityHazards.Risk(
            zones: [.industrial], coveringService: .fireStation,
            coverageThreshold: 0.3, chancePerTick: 1.0, densityLoss: 2
        )

        var rng = SystemRandomNumberGenerator()
        let result = CityHazards.apply([guaranteedFire], to: map, using: &rng)

        XCTAssertEqual(result.map[position].density, 0)
    }

    /// Fire only threatens the zones listed in `CityHazards.fire.zones` —
    /// residential isn't one of them, even at chance 1 with zero coverage.
    func testFireDoesNotAffectZonesOutsideItsList() {
        var map = CityMap(width: 5, height: 5)
        let position = GridPosition(x: 0, y: 0)
        map[position].zone = .residential
        map[position].density = 3
        let guaranteedFire = CityHazards.Risk(
            zones: [.industrial, .commercial], coveringService: .fireStation,
            coverageThreshold: 0.3, chancePerTick: 1.0, densityLoss: 2
        )

        var rng = SystemRandomNumberGenerator()
        let result = CityHazards.apply([guaranteedFire], to: map, using: &rng)

        XCTAssertEqual(result.map[position].density, 3)
        XCTAssertTrue(result.strikes.isEmpty)
    }

    func testUndevelopedTilesAreNeverAtRisk() {
        var map = CityMap(width: 5, height: 5)
        let position = GridPosition(x: 0, y: 0)
        map[position].zone = .industrial // density 0: just zoned, nothing built
        let guaranteedFire = CityHazards.Risk(
            zones: [.industrial], coveringService: .fireStation,
            coverageThreshold: 0.3, chancePerTick: 1.0, densityLoss: 2
        )

        var rng = SystemRandomNumberGenerator()
        let result = CityHazards.apply([guaranteedFire], to: map, using: &rng)

        XCTAssertEqual(result.map[position].density, 0)
        XCTAssertTrue(result.strikes.isEmpty)
    }

    // MARK: - Ordinances

    /// `Ordinances.neighborhoodWatch` halves a police-covered risk's
    /// chance per tick — proven at the boundary rather than by asserting
    /// on randomness itself: a risk at chance exactly 1.0 always strikes
    /// under `AlwaysMaxRNG` (the roll lands just under 1.0, the highest
    /// value that generator can produce), but the same risk halved to 0.5
    /// no longer clears that same roll.
    func testNeighborhoodWatchHalvesAPoliceCoveredRisksChance() {
        var map = CityMap(width: 5, height: 5)
        let position = GridPosition(x: 0, y: 0)
        map[position].zone = .residential
        map[position].density = 3
        let guaranteedCrime = CityHazards.Risk(
            zones: [.residential], coveringService: .policeStation,
            coverageThreshold: 0.3, chancePerTick: 1.0, densityLoss: 1
        )

        var withoutOrdinanceRNG = AlwaysMaxRNG()
        let withoutOrdinance = CityHazards.apply([guaranteedCrime], to: map, using: &withoutOrdinanceRNG)
        XCTAssertFalse(withoutOrdinance.strikes.isEmpty, "chance 1.0 should always strike regardless of the roll")

        map.ordinances.neighborhoodWatch = true
        var withOrdinanceRNG = AlwaysMaxRNG()
        let withOrdinance = CityHazards.apply([guaranteedCrime], to: map, using: &withOrdinanceRNG)
        XCTAssertTrue(withOrdinance.strikes.isEmpty, "halved to 0.5, the same near-1.0 roll should no longer clear it")
    }

    /// Same proof, for `Ordinances.fireInspections` against a
    /// fire-station-covered risk.
    func testFireInspectionsHalvesAFireCoveredRisksChance() {
        var map = CityMap(width: 5, height: 5)
        let position = GridPosition(x: 0, y: 0)
        map[position].zone = .industrial
        map[position].density = 3
        let guaranteedFire = CityHazards.Risk(
            zones: [.industrial], coveringService: .fireStation,
            coverageThreshold: 0.3, chancePerTick: 1.0, densityLoss: 2
        )

        var withoutOrdinanceRNG = AlwaysMaxRNG()
        let withoutOrdinance = CityHazards.apply([guaranteedFire], to: map, using: &withoutOrdinanceRNG)
        XCTAssertFalse(withoutOrdinance.strikes.isEmpty)

        map.ordinances.fireInspections = true
        var withOrdinanceRNG = AlwaysMaxRNG()
        let withOrdinance = CityHazards.apply([guaranteedFire], to: map, using: &withOrdinanceRNG)
        XCTAssertTrue(withOrdinance.strikes.isEmpty)
    }

    /// Each ordinance only touches the risk it names — `fireInspections`
    /// alone shouldn't quiet down crime, the same "targeted, not a
    /// blanket effect" contract the roadmap's own ordinance description
    /// promises.
    func testFireInspectionsDoesNotAffectAPoliceCoveredRisk() {
        var map = CityMap(width: 5, height: 5)
        let position = GridPosition(x: 0, y: 0)
        map[position].zone = .residential
        map[position].density = 3
        map.ordinances.fireInspections = true
        let guaranteedCrime = CityHazards.Risk(
            zones: [.residential], coveringService: .policeStation,
            coverageThreshold: 0.3, chancePerTick: 1.0, densityLoss: 1
        )

        var rng = AlwaysMaxRNG()
        let result = CityHazards.apply([guaranteedCrime], to: map, using: &rng)

        XCTAssertFalse(result.strikes.isEmpty, "an unrelated ordinance shouldn't have softened this risk's chance")
    }

    // MARK: - Footprints

    /// A strike on a 2×2 building applies the same density loss to every
    /// cell of its footprint, not just the anchor — otherwise a building's
    /// own cells could end up disagreeing about their density.
    func testStrikeAppliesUniformlyAcrossAFootprint() {
        var map = CityMap(width: 5, height: 5)
        let origin = GridPosition(x: 0, y: 0)
        map.placeBuilding(zone: .industrial, origin: origin) // covers (0,0)-(1,1)
        for cell in map.footprintCells(origin: origin, size: 2) {
            map[cell].density = 3
        }
        let guaranteedFire = CityHazards.Risk(
            zones: [.industrial], coveringService: .fireStation,
            coverageThreshold: 0.3, chancePerTick: 1.0, densityLoss: 2
        )

        var rng = SystemRandomNumberGenerator()
        let result = CityHazards.apply([guaranteedFire], to: map, using: &rng)

        for cell in map.footprintCells(origin: origin, size: 2) {
            XCTAssertEqual(result.map[cell].density, 1) // 3 - 2, same on every cell
        }
        // Reported once, at the anchor — the one cell with a visible sprite.
        XCTAssertEqual(result.strikes, [CityHazards.Strike(position: origin, coveringService: .fireStation)])
    }

    // MARK: - Damage persists until a service repairs it

    /// A hazard doesn't just knock a level off — it leaves the block waiting
    /// on the service whose absence let it happen.
    func testAHazardMarksTheBuildingAsDamagedByItsCoveringService() {
        var map = CityMap(width: 12, height: 12)
        map.placeBuilding(zone: .industrial, origin: GridPosition(x: 0, y: 0))
        for cell in map.footprintCells(origin: GridPosition(x: 0, y: 0), size: 2) {
            map[cell].density = 4
        }

        var rng = AlwaysZeroRNG() // clears every hazard roll
        let (next, strikes) = CityHazards.apply([CityHazards.fire], to: map, using: &rng)

        XCTAssertFalse(strikes.isEmpty, "the fixture never caught fire, so this proved nothing")
        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].damagedBy, .fireStation)
        XCTAssertTrue(next[GridPosition(x: 1, y: 1)].isDamaged, "damage must cover the whole footprint")
    }

    /// The point of the whole mechanic: an uncovered damaged block stays
    /// broken. It neither grows back nor decays further — it just sits there.
    ///
    /// `AlwaysMaxRNG` so the `unassistedRepairChancePerTick` roll *fails*:
    /// this is about what coverage does, and an uncovered block does
    /// eventually rebuild itself on its own (see
    /// `testUncoveredDamageEventuallyRepairsItself`). Under `AlwaysZeroRNG`
    /// that self-repair would fire on the first tick and mask the thing being
    /// tested.
    func testDamageWithoutCoverageBlocksGrowthIndefinitely() {
        var map = CityMap(width: 12, height: 12)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 2, y: 0)].zone = .road
        for cell in map.footprintCells(origin: GridPosition(x: 0, y: 0), size: 2) {
            map[cell].density = 2
            map[cell].damagedBy = .fireStation
        }

        var rng = AlwaysMaxRNG() // fails the self-repair roll, so only coverage could help
        var next = map
        for _ in 0 ..< 10 { next = CitySimulator.advance(next, using: &rng) }

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 2, "damaged block grew or decayed without repair")
        XCTAssertTrue(next[GridPosition(x: 0, y: 0)].isDamaged)
    }

    /// Put the right service in range and the block rebuilds — which is the
    /// answer to "why am I paying for this station."
    func testCoverageRepairsDamageAndGrowthResumes() {
        var map = CityMap(width: 12, height: 12)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 2, y: 0)].zone = .road
        // Density 1, so the level this grows *to* stays below
        // `CitySimulator.waterRequiredFromLevel` — otherwise the water gate,
        // not the repair, would be what decides whether it grows.
        for cell in map.footprintCells(origin: GridPosition(x: 0, y: 0), size: 2) {
            map[cell].density = 1
            map[cell].damagedBy = .fireStation
        }
        map.placeBuilding(zone: .fireStation, origin: GridPosition(x: 0, y: 3))

        var rng = AlwaysZeroRNG()
        let repaired = CitySimulator.advance(map, using: &rng)
        XCTAssertFalse(repaired[GridPosition(x: 0, y: 0)].isDamaged, "coverage did not repair the block")
        XCTAssertEqual(repaired[GridPosition(x: 0, y: 0)].density, 1, "repair should not also grow in the same tick")

        // Repair takes the tick; ordinary growth resumes on the next one.
        let afterRepair = CitySimulator.advance(repaired, using: &rng)
        XCTAssertEqual(afterRepair[GridPosition(x: 0, y: 0)].density, 2)
    }

    /// The wrong service doesn't help: a block burnt down needs a fire
    /// station, not a police station.
    func testTheWrongServiceDoesNotRepairDamage() {
        var map = CityMap(width: 12, height: 12)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 2, y: 0)].zone = .road
        for cell in map.footprintCells(origin: GridPosition(x: 0, y: 0), size: 2) {
            map[cell].density = 2
            map[cell].damagedBy = .fireStation
        }
        map.placeBuilding(zone: .policeStation, origin: GridPosition(x: 0, y: 3))

        var rng = AlwaysMaxRNG() // fails self-repair, isolating the coverage check
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertTrue(next[GridPosition(x: 0, y: 0)].isDamaged)
    }

    /// Damage is a setback, not a ratchet: an uncovered block rebuilds itself
    /// eventually, just far more slowly than a covered one.
    ///
    /// Without this, repair-gated damage guarantees total decay — every
    /// building below the coverage threshold is hit eventually, so every
    /// uncovered building ends up permanently dead. See
    /// `CitySimulator.unassistedRepairChancePerTick`.
    func testUncoveredDamageEventuallyRepairsItself() {
        var map = CityMap(width: 12, height: 12)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 2, y: 0)].zone = .road
        for cell in map.footprintCells(origin: GridPosition(x: 0, y: 0), size: 2) {
            map[cell].density = 1
            map[cell].damagedBy = .fireStation
        }

        var rng = AlwaysZeroRNG() // clears the self-repair roll
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertFalse(
            next[GridPosition(x: 0, y: 0)].isDamaged,
            "an uncovered block never rebuilds on its own, which makes damage a one-way ratchet"
        )
    }

    /// Coverage must be dramatically better than waiting, or building the
    /// station isn't worth it.
    func testCoverageRepairsFarFasterThanWaiting() {
        XCTAssertLessThan(
            CitySimulator.unassistedRepairChancePerTick, 0.1,
            "self-repair is fast enough that service coverage barely matters"
        )
        XCTAssertGreaterThan(
            CitySimulator.unassistedRepairChancePerTick, 0,
            "self-repair is off, which makes hazard damage a one-way ratchet"
        )
    }

    /// Bulldozing and rebuilding is the expensive escape hatch — it clears
    /// damage, because `CityMap.placeBuilding` rebuilds the tile from scratch.
    func testRezoningClearsDamage() {
        var map = CityMap(width: 12, height: 12)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        for cell in map.footprintCells(origin: GridPosition(x: 0, y: 0), size: 2) {
            map[cell].damagedBy = .fireStation
        }

        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 0, y: 0))

        XCTAssertFalse(map[GridPosition(x: 0, y: 0)].isDamaged)
    }

    /// An undamaged city must behave exactly as it did before this existed —
    /// the repair check has to be invisible when nothing is damaged.
    func testUndamagedBuildingsGrowExactlyAsBefore() {
        var map = CityMap(width: 12, height: 12)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 0))
        map[GridPosition(x: 2, y: 0)].zone = .road

        var rng = AlwaysZeroRNG()
        let next = CitySimulator.advance(map, using: &rng)

        XCTAssertEqual(next[GridPosition(x: 0, y: 0)].density, 1)
    }
}
