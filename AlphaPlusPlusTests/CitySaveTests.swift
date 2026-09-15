import XCTest
@testable import AlphaPlusPlus

/// Tests for `CitySave` — the serializable envelope for a whole city — and
/// for `GameController.snapshot()` / `restore(from:)`.
///
/// The round-trip tests deliberately build a city that has had *something*
/// done to every part of its state, rather than a fresh map with a couple of
/// tiles. A save format fails by dropping the one field nobody exercised, so
/// a test city where funding is still default, no ordinance is active, and no
/// pipe has been laid would pass while persisting none of them.
@MainActor
final class CitySaveTests: XCTestCase {

    // MARK: - Building a city worth saving

    /// A controller whose state is non-default in every dimension `CitySave`
    /// claims to persist: zoned and grown land, roads, a service building,
    /// an underground pipe, a power line, moved service funding, an active
    /// ordinance, outstanding bond debt, an off-default tax rate, and a few
    /// ticks of recorded history.
    private func makeExercisedCity() -> GameController {
        // AlwaysZeroRNG so growth and hazards are deterministic: these tests
        // assert on exact populations and treasuries after ticking, which a
        // system generator would make flaky.
        let controller = GameController(
            map: CityMap(width: MapSize.small.dimension, height: MapSize.small.dimension),
            rng: AlwaysZeroRNG()
        )

        // A road spine, so zoned land has access.
        for x in 0..<12 {
            controller.selectedTool = .road
            _ = controller.place(at: GridPosition(x: x, y: 4))
        }

        // Growable zones on both sides of it. These are 2×2, so they are
        // placed on even coordinates to keep footprints from overlapping.
        controller.selectedTool = .residential
        _ = controller.place(at: GridPosition(x: 0, y: 2))
        _ = controller.place(at: GridPosition(x: 2, y: 2))
        controller.selectedTool = .commercial
        _ = controller.place(at: GridPosition(x: 4, y: 2))
        controller.selectedTool = .industrial
        _ = controller.place(at: GridPosition(x: 6, y: 2))

        // A service building, and the two independent utility layers.
        // Both stations, not just police. Under `AlwaysZeroRNG` every hazard
        // roll succeeds, and damage is now permanent without coverage — so a
        // fixture missing a fire station has its commercial and industrial
        // blocks burnt to nothing within a tick or two, and then routes no
        // commutes at all. See `AlwaysZeroRNG`'s own doc comment.
        controller.selectedTool = .policeStation
        _ = controller.place(at: GridPosition(x: 8, y: 2))
        controller.selectedTool = .fireStation
        _ = controller.place(at: GridPosition(x: 10, y: 2))
        controller.selectedTool = .waterTower
        _ = controller.place(at: GridPosition(x: 0, y: 6))
        for x in 0..<8 {
            _ = controller.layPipe(at: GridPosition(x: x, y: 6))
        }
        controller.selectedTool = .powerPlant
        _ = controller.place(at: GridPosition(x: 12, y: 8))
        for x in 0..<12 {
            _ = controller.layPowerLine(at: GridPosition(x: x, y: 8))
        }

        // Levers the player can pull that live outside the tile grid.
        // Funding is moved off default on a service the fixture's *survival*
        // doesn't depend on. Coverage is falloff × funding, so halving the
        // police budget would drop this city's residential blocks below
        // `CityHazards` crime threshold — and under `AlwaysZeroRNG` every
        // hazard roll succeeds, so they would be permanently damaged and stop
        // routing commutes. This test is about round-tripping a save, not
        // about hazard coverage; using a service that isn't load-bearing here
        // keeps it that way.
        controller.setFundingLevel(0.5, for: .stadium)
        controller.setOrdinance(\.neighborhoodWatch, active: true)
        controller.taxRate = 1.25
        _ = controller.issueBond()

        // A few ticks, so history and the cached whole-map computations
        // (trafficLoad, waterSupply, powerSupply, demand) are all populated.
        for _ in 0..<5 { controller.advanceSimulation() }

        return controller
    }

    // MARK: - Round-trip

    func testSnapshotThenRestoreReproducesEveryPersistedField() throws {
        let original = makeExercisedCity()
        let save = original.snapshot()

        let restored = GameController(rng: AlwaysZeroRNG())
        try restored.restore(from: save)

        XCTAssertEqual(restored.map, original.map)
        XCTAssertEqual(restored.treasury, original.treasury)
        XCTAssertEqual(restored.taxRate, original.taxRate)
        XCTAssertEqual(restored.bondBalance, original.bondBalance)
        XCTAssertEqual(restored.history, original.history)
    }

    func testSnapshotSurvivesAJSONRoundTrip() throws {
        let original = makeExercisedCity()

        let data = try JSONEncoder().encode(original.snapshot())
        let decoded = try JSONDecoder().decode(CitySave.self, from: data)

        let restored = GameController(rng: AlwaysZeroRNG())
        try restored.restore(from: decoded)

        XCTAssertEqual(restored.map, original.map)
        XCTAssertEqual(restored.treasury, original.treasury)
        XCTAssertEqual(restored.taxRate, original.taxRate)
        XCTAssertEqual(restored.bondBalance, original.bondBalance)
        XCTAssertEqual(restored.history, original.history)
    }

    /// The exercised city is only a useful fixture if it is actually
    /// non-default. If a refactor ever makes `makeExercisedCity` stop
    /// producing e.g. an active ordinance, the round-trip tests above would
    /// still pass while testing less than they claim to — this fails first
    /// and says which part went quiet.
    func testTheFixtureCityIsActuallyNonDefaultEverywhere() {
        let controller = makeExercisedCity()
        let map = controller.map

        XCTAssertNotEqual(map.serviceFunding, ServiceFunding(), "service funding is back at its default")
        XCTAssertNotEqual(map.ordinances, Ordinances(), "no ordinance is active")
        XCTAssertNotEqual(map.trafficLoad, TrafficLoad(), "no traffic was routed")
        XCTAssertNotEqual(map.waterSupply, WaterSupply(), "no water network was computed")
        XCTAssertTrue(map.tiles.contains { $0.hasPipe }, "no pipe was laid")
        XCTAssertTrue(map.tiles.contains { $0.hasPowerLine }, "no power line was laid")
        XCTAssertNotEqual(map.powerSupply, PowerSupply(), "no power grid was computed")
        XCTAssertTrue(map.tiles.contains { $0.zone == .road }, "no road was placed")
        XCTAssertTrue(map.tiles.contains { $0.zone == .policeStation }, "no service building was placed")
        XCTAssertGreaterThan(controller.bondBalance, 0, "no bond is outstanding")
        XCTAssertNotEqual(controller.taxRate, 1.0, "tax rate is back at its default")
        XCTAssertFalse(controller.history.isEmpty, "no history was recorded")
    }

    // MARK: - What restore does beyond copying fields

    func testRestoreLeavesTheSimulationPaused() throws {
        let original = makeExercisedCity()
        let restored = GameController(rng: AlwaysZeroRNG())
        restored.isRunning = true

        try restored.restore(from: original.snapshot())

        XCTAssertFalse(restored.isRunning, "loading a city should not drop the player into a running tick")
    }

    func testRestoreClearsPerTickScratchStateRatherThanCarryingItIn() throws {
        let original = makeExercisedCity()
        let restored = GameController(rng: AlwaysZeroRNG())

        try restored.restore(from: original.snapshot())

        XCTAssertTrue(restored.lastHazardStrikes.isEmpty)
        XCTAssertFalse(restored.isPowerOutageActive)
    }

    func testRestoreRealignsTheMapSizePickerToTheLoadedMap() throws {
        let large = GameController(
            map: CityMap(width: MapSize.large.dimension, height: MapSize.large.dimension),
            rng: AlwaysZeroRNG()
        )

        let restored = GameController(rng: AlwaysZeroRNG())
        restored.selectedMapSize = .small
        try restored.restore(from: large.snapshot())

        XCTAssertEqual(restored.selectedMapSize, .large)
    }

    /// A map whose dimensions match no `MapSize` case must not force the
    /// picker to some arbitrary nearby value — the map is authoritative, and
    /// `selectedMapSize` only ever describes what the *next* Reset builds.
    func testRestoreLeavesTheMapSizePickerAloneForAnUnrecognizedSize() throws {
        let odd = GameController(map: CityMap(width: 37, height: 37), rng: AlwaysZeroRNG())

        let restored = GameController(rng: AlwaysZeroRNG())
        restored.selectedMapSize = .medium
        try restored.restore(from: odd.snapshot())

        XCTAssertEqual(restored.selectedMapSize, .medium)
        XCTAssertEqual(restored.map.width, 37)
    }

    // MARK: - Format versioning

    func testASaveFromANewerFormatIsRejected() {
        let save = CitySave(
            formatVersion: CitySave.currentFormatVersion + 1,
            map: CityMap(width: 8, height: 8),
            treasury: 0,
            taxRate: 1.0,
            bondBalance: 0,
            history: []
        )

        let controller = GameController(rng: AlwaysZeroRNG())
        XCTAssertThrowsError(try controller.restore(from: save)) { error in
            XCTAssertEqual(
                error as? CitySave.LoadError,
                .unsupportedFormatVersion(
                    found: CitySave.currentFormatVersion + 1,
                    supported: CitySave.currentFormatVersion
                )
            )
        }
    }

    /// A rejected load must not leave a half-replaced city behind.
    func testARejectedLoadLeavesTheExistingCityUntouched() {
        let controller = makeExercisedCity()
        let before = controller.snapshot()

        let fromTheFuture = CitySave(
            formatVersion: CitySave.currentFormatVersion + 1,
            map: CityMap(width: 8, height: 8),
            treasury: 999,
            taxRate: 0.1,
            bondBalance: 42,
            history: []
        )

        XCTAssertThrowsError(try controller.restore(from: fromTheFuture))
        XCTAssertEqual(controller.snapshot(), before)
    }

    func testAnOlderFormatVersionIsStillAccepted() throws {
        let original = makeExercisedCity()
        let current = original.snapshot()
        let older = CitySave(
            formatVersion: 0,
            map: current.map,
            treasury: current.treasury,
            taxRate: current.taxRate,
            bondBalance: current.bondBalance,
            history: current.history
        )

        let restored = GameController(rng: AlwaysZeroRNG())
        XCTAssertNoThrow(try restored.restore(from: older))
        XCTAssertEqual(restored.map, original.map)
    }

    // MARK: - The one that actually matters

    /// A restored city must go on to *simulate* like the original, not merely
    /// compare equal to it the instant it loads.
    ///
    /// This is the test that would catch a field which round-trips correctly
    /// but that the simulation reads from somewhere else — a cached whole-map
    /// computation left stale, a funding level that restored into the map but
    /// not into what `LandValue` actually consults. Both controllers run on
    /// `AlwaysZeroRNG`, so the only way their stats can diverge over 20 ticks
    /// is a genuine difference in restored state.
    func testARestoredCitySimulatesIdenticallyToTheOriginal() throws {
        let original = makeExercisedCity()

        let restored = GameController(rng: AlwaysZeroRNG())
        try restored.restore(from: original.snapshot())

        for tick in 0..<20 {
            original.advanceSimulation()
            restored.advanceSimulation()
            XCTAssertEqual(restored.population, original.population, "population diverged at tick \(tick)")
            XCTAssertEqual(restored.jobs, original.jobs, "jobs diverged at tick \(tick)")
            XCTAssertEqual(restored.treasury, original.treasury, "treasury diverged at tick \(tick)")
            XCTAssertEqual(restored.map, original.map, "the map diverged at tick \(tick)")
        }
    }
}
