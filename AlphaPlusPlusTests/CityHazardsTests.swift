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
}
