import XCTest
@testable import AlphaPlusPlus

/// Fire that spreads — phase 7, and the first hazard in the game with a time
/// dimension and a spatial one rather than being over inside the tick it
/// happened.
@MainActor
final class FireTests: XCTestCase {

    /// A row of adjacent industrial blocks with no fire station anywhere, one
    /// of them alight. Industrial because `CityHazards.fire` covers industry
    /// and commerce, so this is a city fire could plausibly be in.
    private func burningRow(fireStation: Bool = false) -> CityMap {
        var map = CityMap(width: 24, height: 10)
        for x in 0 ..< 20 { map[GridPosition(x: x, y: 4)].zone = .road }
        for x in stride(from: 0, to: 16, by: 2) {
            map.placeBuilding(zone: .industrial, origin: GridPosition(x: x, y: 2))
            for cell in map.footprintCells(origin: GridPosition(x: x, y: 2), size: 2) {
                map[cell].density = 4
            }
        }
        if fireStation {
            map.placeBuilding(zone: .fireStation, origin: GridPosition(x: 4, y: 6))
        }
        for cell in map.footprintCells(origin: GridPosition(x: 6, y: 2), size: 2) {
            map[cell].fireTicks = 0
        }
        return map
    }

    /// "This fire is not going out this tick, and everything it reaches
    /// catches." `Fire.advance` rolls burnout once and then spread once per
    /// neighbour, so one high roll followed by zeroes isolates spreading from
    /// burning out — which no single fixed value can do, since
    /// `spreadChancePerTick` sits *below* `burnoutChancePerTick`.
    ///
    /// Good for exactly one tick; longer runs use `SeededRNG` and measure.
    private var spreadingRNG: ScriptedRNG { ScriptedRNG(first: 0.9, then: 0) }

    // MARK: - It spreads

    func testAFireReachesTheBlockNextDoor() {
        var map = burningRow()
        var rng = spreadingRNG
        let neighbour = GridPosition(x: 4, y: 2)
        XCTAssertFalse(map[neighbour].isBurning, "precondition: the neighbour is already alight")

        let (next, ignited) = Fire.advance(map, using: &rng)

        XCTAssertTrue(next[neighbour].isBurning, "the fire did not reach the block next door")
        XCTAssertTrue(ignited.contains { $0.position == neighbour },
                      "a block caught fire and nothing reported it")
        map = next
        XCTAssertEqual(map[neighbour].damagedBy, .fireStation,
                       "a block the fire reached was not recorded as needing a fire station")
        XCTAssertLessThan(map[neighbour].density, 4,
                          "the fire arrived and cost the block nothing")
    }

    /// Damage on arrival is `CityHazards`' own number, not a second one — a
    /// fire that arrives by spreading is the same fire.
    func testSpreadingCostsTheSameAsBeingStruck() {
        var map = burningRow()
        var rng = spreadingRNG
        let (next, _) = Fire.advance(map, using: &rng)
        XCTAssertEqual(next[GridPosition(x: 4, y: 2)].density,
                       4 - CityHazards.fire.densityLoss)
        map = next
    }

    /// Roads are firebreaks without anything here knowing what a firebreak is:
    /// a fire only travels to something that can burn.
    func testAFireDoesNotCrossAGapWithNothingToBurn() {
        var map = burningRow()
        // Flatten the block to the left, leaving the lot but nothing on it.
        for cell in map.footprintCells(origin: GridPosition(x: 4, y: 2), size: 2) {
            map[cell].density = 0
        }
        var rng = spreadingRNG
        let (next, _) = Fire.advance(map, using: &rng)
        XCTAssertFalse(next[GridPosition(x: 4, y: 2)].isBurning,
                       "an empty lot caught fire")
        XCTAssertFalse(next[GridPosition(x: 2, y: 2)].isBurning,
                       "the fire jumped clean over a lot with nothing on it")
        // The positive control, without which this passes just as happily on a
        // build where fire does not spread at all.
        XCTAssertTrue(next[GridPosition(x: 8, y: 2)].isBurning,
                      "precondition: nothing spread in either direction")
    }

    /// Services are not kindling. A random roll deleting the player's fire
    /// station would be a far bigger event than this models.
    func testAFireDoesNotBurnDownServiceBuildings() {
        var map = burningRow()
        map.placeBuilding(zone: .policeStation, origin: GridPosition(x: 8, y: 2))
        var rng = spreadingRNG
        let (next, _) = Fire.advance(map, using: &rng)
        XCTAssertFalse(next[GridPosition(x: 8, y: 2)].isBurning,
                       "the fire took out a service building")
        XCTAssertTrue(next[GridPosition(x: 4, y: 2)].isBurning,
                      "precondition: nothing spread in either direction")
    }

    // MARK: - It goes out

    /// `AlwaysZeroRNG` passes every roll, and burnout is checked first — so
    /// every fire in every fixture built on it goes out immediately and never
    /// spreads. That is the property that keeps phase 7 from quietly levelling
    /// the whole test suite, so it is worth pinning rather than relying on.
    func testUnderAlwaysZeroAFireGoesOutRatherThanSpreading() {
        var map = burningRow()
        var rng = AlwaysZeroRNG()
        let (next, ignited) = Fire.advance(map, using: &rng)

        XCTAssertFalse(next[GridPosition(x: 6, y: 2)].isBurning, "the fire did not go out")
        XCTAssertTrue(ignited.isEmpty, "a fire that was going out still spread")
    }

    func testAFireThatDoesNotGoOutGetsOlder() {
        var map = burningRow()
        // `AlwaysMaxRNG` fails every roll, which for a fire means both "does
        // not go out" and "does not spread" — so the only thing left to
        // observe across several ticks is the fire getting older, which is
        // exactly what this is about.
        var rng = AlwaysMaxRNG()
        let origin = GridPosition(x: 6, y: 2)
        XCTAssertEqual(map[origin].fireTicks, 0)
        for expected in 1 ... 3 {
            map = Fire.advance(map, using: &rng).map
            XCTAssertEqual(map[origin].fireTicks, expected)
        }
    }

    // MARK: - Containment is what a fire station buys

    /// The mechanic's headline: coverage does not stop a block burning, it
    /// stops the block *next to it* burning. Measured over many runs rather
    /// than asserted on one, since both sides are probabilistic.
    func testAFireStationContainsAFireThatWouldOtherwiseSpread() {
        func blocksBurnt(fireStation: Bool, seed: UInt64) -> Int {
            var map = burningRow(fireStation: fireStation)
            var rng = SeededRNG(seed: seed)
            for _ in 0 ..< 40 { map = Fire.advance(map, using: &rng).map }
            return map.tiles.filter { $0.isBuildingAnchor && $0.isDamaged }.count
        }

        var uncovered = 0
        var covered = 0
        for seed in UInt64(1) ... 25 {
            uncovered += blocksBurnt(fireStation: false, seed: seed)
            covered += blocksBurnt(fireStation: true, seed: seed)
        }
        print("\nfire containment over 25 runs: \(uncovered) blocks lost uncovered, \(covered) covered")

        XCTAssertGreaterThan(uncovered, covered,
                             "a fire station made no difference to how far fires travelled")
        XCTAssertGreaterThan(uncovered, 25,
                             "precondition: fires are not spreading at all, so there is nothing to contain")
    }

    /// Every fire ends. A city permanently alight would be a ratchet, which
    /// this project has already once had to unpick for hazard damage.
    func testEveryFireEventuallyBurnsOut() {
        var map = burningRow()
        var rng = SeededRNG(seed: 99)
        for _ in 0 ..< 400 { map = Fire.advance(map, using: &rng).map }
        XCTAssertEqual(Fire.count(in: map), 0, "the city is still on fire after 400 ticks")
    }

    // MARK: - The player's answer

    func testBulldozingPutsTheFireOut() {
        let controller = GameController(
            map: burningRow(), rng: AlwaysMaxRNG(), peakPopulation: Unlocks.everythingUnlocked
        )
        XCTAssertEqual(controller.burningBlocks, 1, "precondition: nothing is alight")

        controller.bulldoze(at: GridPosition(x: 6, y: 2))

        XCTAssertEqual(controller.burningBlocks, 0, "bulldozing a burning block left it alight")
    }

    // MARK: - Wiring

    /// A strike leaves the block burning, and everything the strike did before
    /// still happens — this is propagation layered on that contract, not a
    /// replacement for it.
    func testAFireStrikeLeavesTheBlockAlight() {
        var map = CityMap(width: 12, height: 8)
        map[GridPosition(x: 2, y: 4)].zone = .road
        map.placeBuilding(zone: .industrial, origin: GridPosition(x: 2, y: 2))
        for cell in map.footprintCells(origin: GridPosition(x: 2, y: 2), size: 2) {
            map[cell].density = 4
        }

        var rng = AlwaysZeroRNG()
        let (struck, strikes) = CityHazards.apply([CityHazards.fire], to: map, using: &rng)

        XCTAssertEqual(strikes.count, 1, "precondition: nothing was struck")
        XCTAssertTrue(struck[GridPosition(x: 2, y: 2)].isBurning,
                      "a fire strike left the block undamaged by fire")
        XCTAssertEqual(struck[GridPosition(x: 2, y: 2)].damagedBy, .fireStation)
        XCTAssertLessThan(struck[GridPosition(x: 2, y: 2)].density, 4)
    }

    /// Crime does not spread — one mechanic at a time, and a burglary reaching
    /// for the house next door is a different model.
    func testACrimeStrikeDoesNotLeaveAnythingBurning() {
        var map = CityMap(width: 12, height: 8)
        map[GridPosition(x: 2, y: 4)].zone = .road
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 2, y: 2))
        for cell in map.footprintCells(origin: GridPosition(x: 2, y: 2), size: 2) {
            map[cell].density = 4
        }

        var rng = AlwaysZeroRNG()
        let (struck, strikes) = CityHazards.apply([CityHazards.crime], to: map, using: &rng)

        XCTAssertEqual(strikes.count, 1, "precondition: nothing was struck")
        XCTAssertFalse(struck[GridPosition(x: 2, y: 2)].isBurning, "a burglary set the block on fire")
    }

    func testFireSurvivesASaveRoundTrip() throws {
        let controller = GameController(
            map: burningRow(), rng: AlwaysMaxRNG(), peakPopulation: Unlocks.everythingUnlocked
        )
        let data = try JSONEncoder().encode(controller.snapshot())
        let decoded = try JSONDecoder().decode(CitySave.self, from: data)
        let restored = GameController(map: CityMap(width: 24, height: 10), rng: AlwaysMaxRNG(),
                                      peakPopulation: Unlocks.everythingUnlocked)
        try restored.restore(from: decoded)

        XCTAssertEqual(restored.burningBlocks, 1, "a reloaded city forgot it was on fire")
    }
}
