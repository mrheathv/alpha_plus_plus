import XCTest
@testable import AlphaPlusPlus

/// **The safety net, carried across.** The scene playtest and the random
/// player caught more rendering bugs in this project than anything else, and
/// every one of them was a picture falling behind the city — exactly the
/// kind of bug the Metal renderer's own caching (chunks rebuilt by signature,
/// a motion plan rebuilt by key, a view rebuilt by revision) can have. So the
/// sessions run the game the way it runs now (`CityPlaytest`): clicks go
/// through `MapInteraction`, days through `CityClock`, and every check asks
/// `MetalAgreement` about a Metal renderer built fresh.
@MainActor
final class MetalPlaytestTests: XCTestCase {

    /// A small plumbed and wired town with a few blocks already standing.
    static func startedCity() -> CityMap {
        var map = CityMap(width: 22, height: 16)
        for y in stride(from: 0, to: 16, by: 3) {
            for x in 0 ..< 22 { map[GridPosition(x: x, y: y)].zone = .road }
        }
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 1, y: 13))
        map.placeBuilding(zone: .generator, origin: GridPosition(x: 18, y: 13))
        for origin in [GridPosition(x: 2, y: 1), GridPosition(x: 6, y: 1),
                       GridPosition(x: 10, y: 4), GridPosition(x: 14, y: 7)] {
            map.placeBuilding(zone: .residential, origin: origin)
            for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = 2 }
        }
        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 6, y: 7))
        for cell in map.footprintCells(origin: GridPosition(x: 6, y: 7), size: 2) { map[cell].density = 2 }
        return map
    }

    private func game(seed: UInt64 = 0xA1F4) throws -> CityPlaytest {
        try XCTUnwrap(CityPlaytest(map: Self.startedCity(), seed: seed), "no Metal device")
    }

    func testAnOrdinarySession() throws {
        let game = try game()
        game.play()
        game.drag(.road, from: GridPosition(x: 11, y: 0), to: GridPosition(x: 11, y: 15))
        game.check("a cross street")
        game.look(at: .water)
        game.dragInView(from: GridPosition(x: 1, y: 13), to: GridPosition(x: 1, y: 2))
        game.dragInView(from: GridPosition(x: 1, y: 2), to: GridPosition(x: 20, y: 2))
        game.check("plumbing it")
        game.look(at: .power)
        game.dragInView(from: GridPosition(x: 18, y: 13), to: GridPosition(x: 18, y: 5))
        game.check("wiring it")
        game.look(at: .none)
        // A month, not a week: a storey takes eight days a level to build,
        // and a session in which nothing finishes growing cannot show a
        // chunk failing to redraw a building that grew — the planted-bug run
        // proved this one could not.
        game.tick(30)
        game.check("a month of growth")
        game.click(.policeStation, at: GridPosition(x: 14, y: 10))
        game.click(.park, at: GridPosition(x: 9, y: 7))
        game.check("a station and a park")
        game.pause()
        game.look(at: .problems)
        game.check("checking on the problems, paused")
        game.play()
        game.look(at: .none)
        game.tick(30)
        game.check("another month")
    }

    /// Building and bulldozing while paused, when no day passes to wake the
    /// motion plan — the case its key has to cover on its own.
    func testBuildingWhilePausedUnderEveryView() throws {
        let game = try game()
        game.play()
        game.tick(4)
        game.pause()
        for overlay in OverlayMode.allCases {
            game.look(at: overlay)
            game.click(.industrial, at: GridPosition(x: 2, y: 10))
            game.check("zoning under \(overlay.displayName), paused")
            game.bulldoze(at: GridPosition(x: 2, y: 10))
            game.check("bulldozing under \(overlay.displayName), paused")
        }
    }

    /// **A session nobody wrote**, on Metal. Short in the normal suite and a
    /// real one under `PLAYTEST_FULL` — the plan's bar for M5 is that the
    /// long run is clean.
    func testARandomSessionKeepsThePictureHonest() throws {
        let long = PlaytestHarness.Profile.current == .full
        for seed in (long ? [1, 2, 3, 4, 5, 6] : [1, 2]) as [UInt64] {
            var player = RandomScenePlayer(game: try game(seed: seed), seed: seed)
            player.play(steps: long ? 300 : 40, checkingEvery: long ? 3 : 1)
        }
    }
}
