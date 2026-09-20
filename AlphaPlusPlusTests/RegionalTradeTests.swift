import XCTest
@testable import AlphaPlusPlus

/// The seaport and the airport: the city's two freight connections out.
///
/// Regional rail already sends *people* off the map, and it pulls a city
/// toward being a dormitory — residential demand up, the other two down.
/// These pull the other way, and the seaport is the first building in this
/// game whose legality depends on the terrain.
@MainActor
final class RegionalTradeTests: XCTestCase {

    /// A city with a road along the bottom and no water anywhere.
    private func flat(width: Int = 24, height: Int = 24) -> CityMap {
        var map = CityMap(width: width, height: height)
        for x in 0 ..< width { map[GridPosition(x: x, y: 2)].zone = .road }
        return map
    }

    /// The same city with a river across the middle.
    private func coastal(width: Int = 24, height: Int = 24) -> CityMap {
        var map = flat(width: width, height: height)
        for x in 0 ..< width { map[GridPosition(x: x, y: 12)].isWater = true }
        return map
    }

    private func controller(_ map: CityMap) -> GameController {
        GameController(map: map, rng: SystemRandomNumberGenerator(),
                       peakPopulation: Unlocks.everythingUnlocked)
    }

    // MARK: - The berth rule

    /// **The choice at founding stops being a look.** Terrain was a picture
    /// until something depended on it; a dock that has to touch water is that
    /// something, so a Flat map is a map that cannot trade by sea.
    func testASeaportCannotBeBuiltOnAMapWithNoWater() {
        let game = controller(flat())
        game.selectedTool = .seaport
        let treasury = game.treasury

        XCTAssertEqual(game.place(at: GridPosition(x: 5, y: 5)), .blocked)
        XCTAssertEqual(game.map[GridPosition(x: 5, y: 5)].zone, .empty)
        XCTAssertEqual(game.treasury, treasury, "a blocked placement still charged for the dock")
    }

    func testASeaportCanBeBuiltOnTheShore() {
        let game = controller(coastal())
        game.selectedTool = .seaport

        // A 3×3 anchored at y = 9 reaches y = 11, which is the bank.
        XCTAssertEqual(game.place(at: GridPosition(x: 5, y: 9)), .placed)
        XCTAssertEqual(game.map[GridPosition(x: 5, y: 9)].zone, .seaport)
    }

    /// The reach is the *footprint's* edge, not the anchor's. A 3×3 quay two
    /// tiles short of the bank still touches it; one three tiles short does
    /// not. Nothing else in the game asks this question, so nothing else
    /// would have caught an anchor-only check.
    func testTheBerthIsMeasuredFromTheWholeFootprint() {
        let map = coastal()
        let far = map.footprintCells(origin: GridPosition(x: 5, y: 8), size: 3)
        let near = map.footprintCells(origin: GridPosition(x: 5, y: 9), size: 3)

        XCTAssertFalse(RegionalTrade.canBerth(far, in: map))
        XCTAssertTrue(RegionalTrade.canBerth(near, in: map))
    }

    /// An airport has no such rule — it is the connection a landlocked city
    /// can still buy, which is what stops Flat being a strictly worse map.
    func testAnAirportNeedsNoWater() {
        let game = controller(flat())
        game.selectedTool = .airport

        XCTAssertEqual(game.place(at: GridPosition(x: 5, y: 5)), .placed)
    }

    // MARK: - What they do

    func testTheDocksRaiseIndustrialDemandAndTheAirportCommercial() {
        var map = coastal()
        let before = Demand.compute(for: map)

        map.placeBuilding(zone: .seaport, origin: GridPosition(x: 5, y: 9))
        let docked = Demand.compute(for: map)
        XCTAssertGreaterThan(docked.value(for: .industrial), before.value(for: .industrial))
        XCTAssertEqual(docked.value(for: .commercial), before.value(for: .commercial),
                       accuracy: 0.0001, "the docks moved commercial demand")

        map.placeBuilding(zone: .airport, origin: GridPosition(x: 15, y: 5))
        let flown = Demand.compute(for: map)
        XCTAssertGreaterThan(flown.value(for: .commercial), docked.value(for: .commercial))
    }

    /// **A second dock is worth about half the first.** The first port is what
    /// connects the city at all; every one after widens a connection that
    /// already exists. Without the diminishing return a port is a demand
    /// slider a large treasury can simply hold down.
    func testASecondPortIsWorthLessThanTheFirst() {
        var one = coastal()
        one.placeBuilding(zone: .seaport, origin: GridPosition(x: 2, y: 9))
        let first = RegionalTrade.industrialBoost(in: one)

        var two = one
        two.placeBuilding(zone: .seaport, origin: GridPosition(x: 8, y: 9))
        let second = RegionalTrade.industrialBoost(in: two) - first

        XCTAssertGreaterThan(second, 0, "a second dock did nothing at all")
        XCTAssertLessThan(second, first * 0.75, "the second dock is worth as much as the first")
    }

    /// Funding scales a port rather than gating it, the same way it scales
    /// everything else a service does. A mothballed dock connects nothing.
    func testAnUnfundedPortConnectsNothing() {
        var map = coastal()
        map.placeBuilding(zone: .seaport, origin: GridPosition(x: 5, y: 9))
        XCTAssertGreaterThan(RegionalTrade.industrialBoost(in: map), 0)

        map.serviceFunding.setLevel(0, for: .seaport)
        XCTAssertEqual(RegionalTrade.industrialBoost(in: map), 0, accuracy: 0.0001)
    }

    /// Sized against the levers it sits among: worth more than a swing of the
    /// regional cycle, less than the tax dial. A port is a substantial
    /// investment that cannot on its own overrule how the city is run.
    func testAPortIsWorthMoreThanTheWeatherAndLessThanTaxes() {
        XCTAssertGreaterThan(RegionalTrade.boostPerPort, RegionalEconomy.amplitude)
        XCTAssertLessThan(RegionalTrade.boostPerPort, Demand.taxDemandSensitivity)
    }
}
