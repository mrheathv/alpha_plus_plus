import AppKit
import XCTest
@testable import AlphaPlusPlus

/// Buying land.
@MainActor
final class LandOwnershipTests: XCTestCase {

    /// A city founded the way the panel founds one: on the middle, with the
    /// rest for sale.
    private func foundedCity(size: MapSize = .small) -> GameController {
        let controller = GameController(rng: AlwaysZeroRNG())
        controller.selectedMapSize = size
        controller.selectedTerrain = .flat
        controller.resetMap(buyingLand: true)
        return controller
    }

    // MARK: - The starting land

    func testEveryRegionSizeDividesIntoParcels() {
        for size in MapSize.allCases {
            XCTAssertEqual(size.dimension % LandOwnership.parcelSize, 0, "\(size) leaves a sliver")
        }
    }

    /// The middle two by two parcels, whatever the size of the region.
    func testACityStartsOnTheMiddleOfItsRegion() {
        for (size, middle) in [(MapSize.small, 16), (.medium, 24), (.large, 32)] {
            let land = foundedCity(size: size).map.land
            XCTAssertEqual(land?.owned.count, 4, "\(size)")
            XCTAssertTrue(land?.owns(GridPosition(x: middle, y: middle)) ?? false, "\(size)")
            XCTAssertTrue(land?.owns(GridPosition(x: middle - 1, y: middle - 1)) ?? false, "\(size)")
            XCTAssertFalse(land?.owns(GridPosition(x: 0, y: 0)) ?? true, "\(size)")
        }
    }

    /// Every existing caller — tests, the harness, old saves — owns the lot.
    func testAMapWithNoLandBudgetOwnsEverything() {
        let controller = GameController()
        controller.resetMap()
        XCTAssertNil(controller.map.land)
        XCTAssertTrue(controller.map.isOwned(GridPosition(x: 0, y: 0)))
    }

    // MARK: - Building

    func testNothingIsBuiltOnLandTheCityDoesNotOwn() {
        let controller = foundedCity()
        controller.selectTool(.road)
        XCTAssertEqual(controller.place(at: GridPosition(x: 2, y: 2)), .blocked)
        XCTAssertEqual(controller.place(at: GridPosition(x: 12, y: 12)), .placed)
        XCTAssertEqual(controller.layPipe(at: GridPosition(x: 2, y: 3)), .blocked)
        XCTAssertEqual(controller.layPowerLine(at: GridPosition(x: 2, y: 4)), .blocked)
    }

    /// A 2×2 lot straddling the boundary is on land the city does not own.
    func testABuildingMayNotStraddleTheBoundary() {
        let controller = foundedCity()
        controller.selectTool(.residential)
        XCTAssertEqual(controller.place(at: GridPosition(x: 7, y: 10)), .blocked)
        XCTAssertEqual(controller.place(at: GridPosition(x: 8, y: 10)), .placed)
    }

    // MARK: - Buying

    func testBuyingAParcelOpensItAndCostsItsPrice() {
        let controller = foundedCity()
        let before = controller.treasury
        let west = GridPosition(x: 3, y: 10)   // parcel (0, 1), beside the start

        XCTAssertEqual(controller.buyLand(at: west), .bought(.init(x: 0, y: 1)))
        XCTAssertEqual(controller.treasury, before - LandOwnership.basePrice)
        controller.selectTool(.road)
        XCTAssertEqual(controller.place(at: west), .placed)
    }

    func testEachParcelCostsMoreThanTheLast() {
        let controller = foundedCity()
        let first = controller.map.land!.nextPrice
        controller.buyLand(at: GridPosition(x: 3, y: 10))
        let second = controller.map.land!.nextPrice
        XCTAssertGreaterThan(second, first)
    }

    func testLandHasToTouchLandYouOwn() {
        let controller = foundedCity()
        XCTAssertEqual(controller.buyLand(at: GridPosition(x: 0, y: 0)),
                       .refused(.notTouchingOwnedLand), "a corner parcel is two away")
        XCTAssertEqual(controller.buyLand(at: GridPosition(x: 12, y: 12)), .refused(.alreadyOwned))
    }

    func testAPoorCityCannotBuy() {
        let controller = foundedCity()
        controller.selectTool(.road)
        // Spend the treasury down on road inside the land it started with.
        spending: for y in 8 ..< 24 {
            for x in 8 ..< 24 {
                guard controller.treasury >= controller.map.land!.nextPrice else { break spending }
                controller.place(at: GridPosition(x: x, y: y))
            }
        }
        XCTAssertLessThan(controller.treasury, controller.map.land!.nextPrice)
        XCTAssertEqual(controller.buyLand(at: GridPosition(x: 3, y: 10)), .insufficientFunds)
    }

    /// An unranked city may own six parcels: the four it started with and
    /// two more. The seventh waits for Hamlet, and the refusal names it.
    func testTheRankLimitsHowMuchLandYouMayOwn() {
        let controller = foundedCity(size: .large)
        for position in [GridPosition(x: 20, y: 28), GridPosition(x: 44, y: 28)] {
            if case .bought = controller.buyLand(at: position) { continue }
            XCTFail("could not buy \(position)")
        }
        XCTAssertEqual(controller.buyLand(at: GridPosition(x: 28, y: 20)), .refused(.needsRank(.hamlet)))
    }

    /// **The allowance never deadlocks the ladder.** Each rank has to allow
    /// enough land to hold the *next* rank's residents, or that rank can only
    /// be reached with land it unlocks. 48 residents a parcel is the default
    /// layout's measured density on the smallest map (780 on 16 parcels,
    /// `MilestoneCalibrationTests`) — the low end of what a serviced city
    /// manages, so the check holds for a city that is not especially well run.
    func testEachRankAllowsLandEnoughToReachTheNext() {
        let residentsPerParcel = 48
        var rank: Milestone? = nil
        while let next = Milestone.next(after: rank) {
            let allowed = LandOwnership.allowance(for: rank)
            let needed = next.requirements.compactMap { requirement -> Int? in
                if case .residents(let n) = requirement { return n }
                return nil
            }.first ?? 0
            if allowed != Int.max {
                XCTAssertGreaterThanOrEqual(allowed * residentsPerParcel, needed,
                                            "\(MilestoneText.title(for: rank)) cannot reach \(next)")
            }
            rank = next
        }
    }

    // MARK: - Saving

    func testOwnershipSurvivesASave() throws {
        let controller = foundedCity()
        controller.buyLand(at: GridPosition(x: 3, y: 10))
        let data = try JSONEncoder().encode(controller.snapshot())
        let loaded = GameController()
        try loaded.restore(from: JSONDecoder().decode(CitySave.self, from: data))
        XCTAssertEqual(loaded.map.land, controller.map.land)
    }

    // MARK: - On screen

    /// **The view keeps up with a purchase.** Buying repaints a parcel's worth
    /// of ground at once, in the Land view and back in Normal — the kind of
    /// change the playtest exists to catch the picture falling behind.
    func testTheMapKeepsUpWithAPurchase() throws {
        var map = CityMap(width: 32, height: 32)
        map.land = .starting(width: 32, height: 32)
        let game = try XCTUnwrap(CityPlaytest(map: map))
        game.look(at: .land)
        game.clickInView(at: GridPosition(x: 3, y: 10))
        game.check("buying a parcel in the Land view")
        XCTAssertTrue(game.controller.map.isOwned(GridPosition(x: 3, y: 10)))
        game.look(at: .none)
        game.check("back in the Normal view")
        game.click(.road, at: GridPosition(x: 3, y: 10))
        game.check("building on the land just bought")
    }

    /// Owned, for sale and out of reach are three different colours.
    func testTheLandViewTellsItsThreeStatesApart() {
        var map = CityMap(width: 32, height: 32)
        map.land = .starting(width: 32, height: 32)
        func color(_ position: GridPosition) -> NSColor? {
            IsoTileRenderer.paint(for: .land, at: position, in: map, using: nil)?.color
        }
        let owned = color(GridPosition(x: 12, y: 12))
        let forSale = color(GridPosition(x: 4, y: 12))
        let locked = color(GridPosition(x: 0, y: 0))
        XCTAssertNotEqual(owned, forSale)
        XCTAssertNotEqual(forSale, locked)
        XCTAssertNotEqual(owned, locked)
    }

    /// **The boundary, seen.** A small city on its starting land, one parcel
    /// bought, in the Normal view and the Land view — whether the edge of
    /// what you own reads at a glance without the Land view up is a question
    /// only a picture answers.
    func testRenderTheLand() throws {
        var map = CityMap(width: 32, height: 32)
        map.land = .starting(width: 32, height: 32)
        for x in 8 ..< 24 { map[GridPosition(x: x, y: 12)].zone = .road }
        for y in 8 ..< 24 { map[GridPosition(x: 15, y: y)].zone = .road }
        for (index, origin) in [GridPosition(x: 9, y: 10), GridPosition(x: 11, y: 13),
                                GridPosition(x: 16, y: 10), GridPosition(x: 18, y: 13),
                                GridPosition(x: 13, y: 16)].enumerated() {
            let zone = [ZoneType.residential, .commercial, .industrial][index % 3]
            map.placeBuilding(zone: zone, origin: origin)
            for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = 2 + index % 2 }
        }
        let game = try XCTUnwrap(CityPlaytest(map: map))
        let size = CGSize(width: 1200, height: 800)
        var frames: [(String, NSImage)] = []
        let normal = try XCTUnwrap(game.picture(size: size))
        frames.append(("normal view — the dark ground is not yet yours", NSImage(cgImage: normal, size: size)))
        game.look(at: .land)
        game.clickInView(at: GridPosition(x: 3, y: 10))
        let land = try XCTUnwrap(game.picture(size: size))
        frames.append(("land view — owned, for sale, out of reach; one parcel bought",
                       NSImage(cgImage: land, size: size)))
        try MetalSpikeTests.writeGrid(frames, columns: 2, cell: size, named: "land")
    }

    /// **Every tile says whether it is yours, however it was last drawn.**
    ///
    /// Reported from play as a starting square that "doesn't render
    /// properly": the dark edge of the land you do not own came out as a
    /// staircase, because SpriteKit drew tiles by two paths and only one had
    /// been told about ownership. Metal draws a chunk one way, and ownership
    /// is in its signature, so the question becomes whether the renderer kept
    /// up — after the three things that change what a chunk holds: a fresh
    /// map, a building placed near the boundary, and a day.
    func testOwnershipIsRedrawnWheneverItsChunkIs() throws {
        var map = CityMap(width: 32, height: 32)
        map.land = .starting(width: 32, height: 32)
        let game = try XCTUnwrap(CityPlaytest(map: map))
        game.check("on a fresh map")
        game.click(.residential, at: GridPosition(x: 9, y: 9))
        game.check("after placing near the boundary")
        game.look(at: .land)
        game.clickInView(at: GridPosition(x: 3, y: 10))
        game.check("after buying the parcel beside it")
        game.tick(1)
        game.check("after a day")
    }
}
