import SpriteKit
import XCTest
@testable import AlphaPlusPlus

/// The rank rewards: earned by rank, and each doing its one job.
@MainActor
final class RewardBuildingsTests: XCTestCase {

    /// A controller holding `rank`, loaded the way a save would give it one —
    /// the only route by which a city acquires a rank without playing to it.
    private func city(ranked rank: Milestone?, map: CityMap = CityMap(width: 24, height: 24)) throws -> GameController {
        let controller = GameController(map: map, peakPopulation: Unlocks.everythingUnlocked)
        let save = CitySave(map: map, treasury: 100_000, taxRate: 1, bondBalance: 0, history: [],
                            peakPopulation: Unlocks.everythingUnlocked, milestone: rank)
        try controller.restore(from: save)
        return controller
    }

    // MARK: - Earned by rank

    func testEachRewardWaitsForItsRank() throws {
        let rewards: [(ZoneType, Milestone)] = [(.neonArcade, .town), (.broadcastTower, .city), (.arcology, .metropolis)]
        for (zone, rank) in rewards {
            let below = try city(ranked: Milestone(rawValue: rank.rawValue - 1))
            XCTAssertFalse(below.isUnlocked(zone), "\(zone) is open before \(rank)")
            below.selectTool(zone)
            XCTAssertEqual(below.place(at: GridPosition(x: 4, y: 4)), .locked)

            let at = try city(ranked: rank)
            XCTAssertTrue(at.isUnlocked(zone), "\(zone) is still locked at \(rank)")
        }
    }

    /// No headcount opens a reward — a city of any size without the rank has
    /// not earned it, which is the whole difference from `Unlocks`.
    func testNoPopulationOpensARewardOnItsOwn() {
        for zone in [ZoneType.neonArcade, .broadcastTower, .arcology] {
            XCTAssertFalse(Unlocks.isUnlocked(zone, peakPopulation: 1_000_000))
        }
    }

    func testEarningARankNamesItsReward() {
        XCTAssertTrue(MilestoneText.earned(.town).contains("Neon Arcade"))
        XCTAssertTrue(MilestoneText.earned(.metropolis).contains("Arcology"))
        // Village's only building is an icon, the Night Market.
        XCTAssertTrue(MilestoneText.earned(.village).contains("Night Market"))
        XCTAssertFalse(MilestoneText.earned(.hamlet).contains("unlocked"), "Hamlet carries no reward")
    }

    func testEveryRewardIsOnTheToolbar() {
        for zone in [ZoneType.neonArcade, .broadcastTower, .arcology] {
            XCTAssertEqual(ToolCategory.containing(zone), .landmarks)
        }
    }

    // MARK: - What each one does

    /// An arcade lifts land value further than a park reaches, and by more.
    func testTheArcadeMakesADistrictDesirable() {
        var withArcade = CityMap(width: 24, height: 24)
        withArcade.placeBuilding(zone: .neonArcade, origin: GridPosition(x: 10, y: 10))
        var withPark = CityMap(width: 24, height: 24)
        withPark.placeBuilding(zone: .park, origin: GridPosition(x: 10, y: 10))
        let bare = CityMap(width: 24, height: 24)

        let near = GridPosition(x: 13, y: 10)
        let far = GridPosition(x: 16, y: 10)   // past a park's reach of 4
        XCTAssertGreaterThan(LandValue.value(at: near, in: withArcade),
                             LandValue.value(at: near, in: withPark))
        XCTAssertGreaterThan(LandValue.value(at: far, in: withArcade), LandValue.value(at: far, in: bare))
        XCTAssertEqual(LandValue.value(at: far, in: withPark), LandValue.value(at: far, in: bare),
                       accuracy: 1e-9)
    }

    /// A tower raises commercial demand; a second adds nothing.
    func testTheTowerSteersCommerceAndOneIsEnough() {
        var one = CityMap(width: 24, height: 24)
        one.regionalEconomy = .calm
        let none = one
        one.placeBuilding(zone: .broadcastTower, origin: GridPosition(x: 2, y: 2))
        var two = one
        two.placeBuilding(zone: .broadcastTower, origin: GridPosition(x: 8, y: 8))

        let base = Demand.compute(for: none).commercial
        XCTAssertEqual(Demand.compute(for: one).commercial - base, RewardBuildings.broadcastBoost, accuracy: 1e-9)
        XCTAssertEqual(Demand.compute(for: two).commercial, Demand.compute(for: one).commercial, accuracy: 1e-9)
        XCTAssertEqual(Demand.compute(for: one).residential, Demand.compute(for: none).residential, accuracy: 1e-9)
    }

    /// Five hundred residents who pay tax and count toward the ladder, but
    /// stay out of the housing market — self-contained, as the type says.
    func testAnArcologyHousesPeopleWhoStayInside() throws {
        var map = CityMap(width: 24, height: 24)
        map.regionalEconomy = .calm
        let before = Demand.compute(for: map)
        map.placeBuilding(zone: .arcology, origin: GridPosition(x: 5, y: 5))
        let controller = try city(ranked: .metropolis, map: map)

        XCTAssertEqual(controller.population, RewardBuildings.arcologyResidents)
        XCTAssertGreaterThan(controller.taxRevenue, 0)
        XCTAssertEqual(Demand.compute(for: map), before, "arcology residents entered the housing market")
    }

    // MARK: - How they look

    /// **The three rewards beside the city they are rewards for.** A reward
    /// is only worth having if it stands out, so it is judged next to a
    /// top-tier block rather than on its own.
    func testRenderTheRewards() {
        var map = CityMap(width: 22, height: 14)
        for x in 0 ..< 22 { map[GridPosition(x: x, y: 5)].zone = .road }
        for x in 0 ..< 22 { map[GridPosition(x: x, y: 10)].zone = .road }
        let lots: [(ZoneType, GridPosition)] = [
            (.commercial, GridPosition(x: 1, y: 3)), (.neonArcade, GridPosition(x: 4, y: 3)),
            (.residential, GridPosition(x: 7, y: 3)), (.broadcastTower, GridPosition(x: 10, y: 3)),
            (.commercial, GridPosition(x: 13, y: 3)), (.arcology, GridPosition(x: 16, y: 2)),
            (.residential, GridPosition(x: 3, y: 6)), (.commercial, GridPosition(x: 9, y: 6)),
            (.industrial, GridPosition(x: 14, y: 6)),
        ]
        for (zone, origin) in lots {
            map.placeBuilding(zone: zone, origin: origin)
            if zone.maxDensity > 0 {
                for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = 5 }
            }
        }
        for tile in map.tiles where tile.zone == .road {
            map[tile.position].hasPipe = true
            map[tile.position].hasPowerLine = true
        }
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 19, y: 6))
        map.placeBuilding(zone: .powerPlant, origin: GridPosition(x: 18, y: 11))
        let game = ScenePlaytest(map: map)
        game.controller.setFundingLevel(4, for: .waterTower)
        game.controller.setFundingLevel(4, for: .powerPlant)
        game.tick(1)
        game.frameTheWholeMap()
        game.frame()
        game.capture("arcade · tower · arcology, among top-tier blocks")
        game.writeFilmstrip(named: "rewards")
    }
}
