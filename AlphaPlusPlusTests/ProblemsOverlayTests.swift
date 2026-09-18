import XCTest
import SpriteKit
@testable import AlphaPlusPlus

/// The Problems view — the answer to "which of my four hundred lots has an
/// issue", which until now could only be found by hovering over them one at a
/// time, faster than the simulation was changing them.
@MainActor
final class ProblemsOverlayTests: XCTestCase {

    // MARK: - Ranking

    func testEveryStatusIsRankedAndOnlyRealProblemsCount() {
        XCTAssertEqual(LotStatus.burning.severity, .critical)

        for status: LotStatus in [.noRoadAccess, .beingAbandoned,
                                  .decliningToSustainable(sustainable: 2),
                                  .damaged(waitingFor: .fireStation)] {
            XCTAssertEqual(status.severity, .failing, "\(status) is not ranked as failing")
        }
        for status: LotStatus in [.needsWater, .needsPower, .needsSchool,
                                  .needsLandValue(required: 0.8, current: 0.5)] {
            XCTAssertEqual(status.severity, .blocked, "\(status) is not ranked as blocked")
        }
        // Nothing to do about any of these, so none of them may light up the
        // map — a view that flags every lot flags nothing.
        for status: LotStatus in [.notGrowable, .atMaximumDensity,
                                  .underConstruction(remaining: 3, total: 8),
                                  .readyToGrow(demand: 0.5)] {
            XCTAssertEqual(status.severity, .fine, "\(status) is being reported as a problem")
        }
    }

    func testSeverityOrdersByUrgency() {
        XCTAssertLessThan(LotStatus.Severity.fine, .blocked)
        XCTAssertLessThan(LotStatus.Severity.blocked, .failing)
        XCTAssertLessThan(LotStatus.Severity.failing, .critical)
    }

    /// "Stuck" and "getting worse" are the distinction the player acts on, and
    /// they must not collapse into one another.
    func testStuckAndFailingAreDifferentRanks() {
        XCTAssertNotEqual(LotStatus.needsWater.severity, LotStatus.beingAbandoned.severity)
        XCTAssertLessThan(LotStatus.needsWater.severity, LotStatus.beingAbandoned.severity)
    }

    // MARK: - Counting

    private func troubledCity() -> GameController {
        var map = CityMap(width: 20, height: 12)
        for x in 0 ..< 18 { map[GridPosition(x: x, y: 4)].zone = .road }
        // Three blocks that need water (they are past the level that wants it
        // and there is no tower anywhere), and one that is on fire.
        for x in stride(from: 0, to: 6, by: 2) {
            map.placeBuilding(zone: .residential, origin: GridPosition(x: x, y: 2))
            for cell in map.footprintCells(origin: GridPosition(x: x, y: 2), size: 2) {
                map[cell].density = CitySimulator.waterRequiredFromLevel - 1
            }
        }
        map.placeBuilding(zone: .industrial, origin: GridPosition(x: 10, y: 2))
        for cell in map.footprintCells(origin: GridPosition(x: 10, y: 2), size: 2) {
            map[cell].density = 3
            map[cell].fireTicks = 1
            map[cell].damagedBy = .fireStation
        }
        return GameController(map: map, rng: AlwaysMaxRNG(),
                              peakPopulation: Unlocks.everythingUnlocked)
    }

    func testTheCityCanSayHowManyBlocksWantAttention() {
        let counts = troubledCity().lotsNeedingAttention()
        XCTAssertEqual(counts[.critical], 1, "the burning block was not counted")
        XCTAssertGreaterThan(counts[.blocked] ?? 0, 0, "no block was reported as stuck")
        XCTAssertNil(counts[.fine], "healthy lots are being counted as problems")
    }

    /// A city with nothing wrong reports nothing wrong — otherwise the badge
    /// is permanent furniture and stops meaning anything.
    func testAHealthyCityReportsNoProblems() {
        var map = CityMap(width: 12, height: 12)
        for x in 0 ..< 10 { map[GridPosition(x: x, y: 4)].zone = .road }
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 0, y: 2))
        map.cityDemand = CityDemand(residential: 1, commercial: 1, industrial: 1)
        let controller = GameController(map: map, rng: AlwaysMaxRNG(),
                                        peakPopulation: Unlocks.everythingUnlocked)
        XCTAssertTrue(controller.lotsNeedingAttention().isEmpty,
                      "a city with nothing wrong is reporting problems")
    }

    // MARK: - What it draws

    private func paint(_ map: CityMap, at position: GridPosition) -> IsoTileRenderer.OverlayPaint? {
        IsoTileRenderer.paint(for: .problems, at: position, in: map,
                              using: ZoneDistanceField.compute(for: map))
    }

    /// A problem lot glows; a healthy one is left completely alone.
    ///
    /// The glow matters rather than being polish: `RetroShader` costs up to
    /// 40% of brightness at the map's edges, so a lot painted in pure red
    /// still came out a muted maroon. Additive light is the one thing that
    /// survives a vignette.
    func testProblemLotsAreFlaggedAndHealthyOnesAreNot() {
        let map = troubledCity().map
        guard case let .flagged(burning) = paint(map, at: GridPosition(x: 10, y: 2))?.buildings else {
            return XCTFail("a burning block is not flagged")
        }
        XCTAssertNotNil(burning, "a burning block was flagged with no colour")

        guard case let .flagged(road) = paint(map, at: GridPosition(x: 5, y: 4))?.buildings else {
            return XCTFail("the problems view did not paint a road tile at all")
        }
        XCTAssertNil(road, "a road is being flagged as a problem")
    }

    /// The three problem ranks have to be told apart at a glance, or the view
    /// says "something is wrong somewhere" and nothing more.
    func testTheRanksAreDrawnInDifferentColours() {
        let colors = [LotStatus.Severity.blocked, .failing, .critical]
            .map { RenderPalette.problemColor(for: $0) }
        XCTAssertEqual(Set(colors.map(\.description)).count, 3,
                       "two problem ranks are drawn the same colour")
        XCTAssertEqual(RenderPalette.problemColor(for: .fine).description,
                       RenderPalette.background.description,
                       "a healthy lot is painted something other than the background")
    }

    // MARK: - Pacing

    /// Reported from play as "everything is happening so fast". The systems
    /// this game grew are long-horizon — a storey takes 8 to 40 days, the
    /// regional cycle runs over hundreds — so the clock has to be able to run
    /// slowly enough to watch one.
    func testSlowIsGenuinelySlowerThanNormalAndNotJustABit() {
        XCTAssertGreaterThanOrEqual(
            SimulationSpeed.slow.tickInterval / SimulationSpeed.normal.tickInterval, 2.0,
            "'slow' is not meaningfully slower than 'normal'"
        )
        XCTAssertGreaterThan(SimulationSpeed.normal.tickInterval, SimulationSpeed.fast.tickInterval)

        // A year of city time at the slowest speed should be a sitting an
        // evening can contain, not an afternoon.
        let yearAtSlow = Double(CityDate.daysPerYear) * SimulationSpeed.slow.tickInterval / 60
        XCTAssertLessThan(yearAtSlow, 45, "a year takes \(Int(yearAtSlow)) minutes even to watch")
        XCTAssertGreaterThan(yearAtSlow, 10, "the slowest speed still runs a year inside ten minutes")
    }
}
