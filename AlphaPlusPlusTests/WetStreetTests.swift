import SpriteKit
import XCTest
@testable import AlphaPlusPlus

/// **The wet street, at the zoom it is played at.**
///
/// `ScenePlaytestTests.testFilmstripOfRain` frames the whole map, where a
/// reflection is a few pixels across — which is how the first version shipped
/// looking right in its only render and read as decals lying on the floor in
/// play. A reflection is a close-range effect, so it is judged close: the same
/// block dry and in the day-6 downpour, at the resting camera.
@MainActor
final class WetStreetTests: XCTestCase {

    /// A few tall blocks facing a street, with open ground in front of them —
    /// every surface a reflection can land on, and nothing else in the way.
    private func block() -> CityMap {
        var map = CityMap(width: 14, height: 12)
        for x in 0 ..< 14 {
            map[GridPosition(x: x, y: 5)].zone = .road
            map[GridPosition(x: x, y: 8)].zone = .road
        }
        for y in 0 ..< 12 { map[GridPosition(x: 6, y: y)].zone = .road }
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 5, y: 6))
        map.placeBuilding(zone: .powerPlant, origin: GridPosition(x: 10, y: 9))
        let lots: [(ZoneType, GridPosition, Int)] = [
            (.commercial, GridPosition(x: 2, y: 3), 5), (.residential, GridPosition(x: 4, y: 3), 4),
            (.commercial, GridPosition(x: 7, y: 3), 4), (.industrial, GridPosition(x: 9, y: 3), 3),
            (.residential, GridPosition(x: 2, y: 6), 3), (.commercial, GridPosition(x: 7, y: 6), 5),
        ]
        for (zone, origin, density) in lots {
            map.placeBuilding(zone: zone, origin: origin)
            for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = density }
        }
        // Plumbed and wired, or every roof wears a badge — see the rain
        // filmstrip for how that first went.
        for tile in map.tiles where tile.zone == .road {
            map[tile.position].hasPipe = true
            map[tile.position].hasPowerLine = true
        }
        return map
    }

    private func closeUp(_ game: ScenePlaytest) {
        game.scene.centerCameraOnMap()
        game.scene.camera?.setScale(0.8)
        game.frame()
    }

    func testRenderTheWetStreetUpClose() {
        let game = ScenePlaytest(map: block())
        game.controller.setFundingLevel(4, for: .waterTower)
        game.controller.setFundingLevel(4, for: .powerPlant)
        closeUp(game)
        game.capture("dry")

        game.play()
        game.tick(6)
        closeUp(game)
        XCTAssertGreaterThan(game.scene.wetnessForTesting, 0, "day 6 should be a downpour")
        game.capture("day 6 — wet")

        if let url = game.writeFilmstrip(named: "wet-street") { print("🌧  \(url.path)") }
    }
}
