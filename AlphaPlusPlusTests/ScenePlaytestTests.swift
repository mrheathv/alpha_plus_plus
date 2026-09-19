import XCTest
@testable import AlphaPlusPlus

/// The three bugs play has found, replayed as sessions — plus the ordinary
/// things nobody has reported yet.
///
/// Each of these was fixed with a unit test of its own, and each of those
/// tests knows what it is looking for. These do not: they play, and ask
/// whether the picture kept up. That is the difference that matters, because
/// all three were things nobody thought to look for.
@MainActor
final class ScenePlaytestTests: XCTestCase {

    /// Streets, a tower and a plant, and room to build — the shape of a city
    /// somebody is actually in the middle of making.
    func startedCity() -> CityMap {
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

    // MARK: - The three, replayed

    /// **"You can't put a pipe under a building."** Drag a run straight
    /// through a block while looking at the water view.
    func testLayingPipeAcrossABlock() {
        let game = ScenePlaytest(map: startedCity())
        game.look(at: .water)
        game.check("opening the water view")

        game.dragInView(from: GridPosition(x: 0, y: 2), to: GridPosition(x: 21, y: 2))
        game.check("dragging a main across the map")

        game.tick(3)
        game.check("three days with the main in")
    }

    /// **Buildings that grow under a view.** Sit in the water overlay and let
    /// the city build.
    func testWatchingACityGrowFromInsideAnOverlay() {
        let game = ScenePlaytest(map: startedCity())
        game.dragInView(from: GridPosition(x: 0, y: 2), to: GridPosition(x: 21, y: 2))
        game.look(at: .water)

        for day in 1 ... 12 {
            game.tick()
            game.check("day \(day) under the water view")
        }
    }

    /// **Cars on a stopped city**, and the other half of it — that placing
    /// things while paused does not start anything moving.
    func testPausingAndBuildingWhilePaused() {
        let game = ScenePlaytest(map: startedCity())
        game.play()
        game.tick(6)
        game.check("six days running")

        game.pause()
        game.check("pausing")

        game.drag(.road, from: GridPosition(x: 0, y: 8), to: GridPosition(x: 21, y: 8))
        game.check("laying a road while paused")

        game.play()
        game.check("starting again")
    }

    // MARK: - And the things nobody has reported

    /// Every view, in and out, while the city changes underneath — the
    /// combination that produced two of the three bugs.
    func testFlippingThroughEveryViewWhileTheCityChanges() {
        let game = ScenePlaytest(map: startedCity())
        game.dragInView(from: GridPosition(x: 0, y: 2), to: GridPosition(x: 21, y: 2))

        for overlay in OverlayMode.allCases {
            game.look(at: overlay)
            game.check("opening \(overlay.displayName)")
            game.tick(2)
            game.check("two days under \(overlay.displayName)")
            game.look(at: .none)
            game.check("returning to Normal from \(overlay.displayName)")
        }
    }

    /// Placing something that changes *which cells are anchors* — four bare
    /// tiles becoming one 2×2 building — which is the case
    /// `rebuildRegion(around:)` exists for, done from inside a view.
    func testBuildingAndBulldozingUnderAView() {
        let game = ScenePlaytest(map: startedCity())
        game.look(at: .landValue)

        game.click(.industrial, at: GridPosition(x: 2, y: 10))
        game.check("zoning under a heatmap")
        game.tick(4)
        game.check("four days of it growing unseen")

        game.bulldoze(at: GridPosition(x: 2, y: 10))
        game.check("bulldozing it again")

        game.look(at: .none)
        game.check("looking back at the city")
    }

    /// A session that does a bit of everything, which is the closest thing
    /// here to somebody actually playing.
    func testAnOrdinarySession() {
        let game = ScenePlaytest(map: startedCity())
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
        game.tick(8)
        game.check("a week of growth")

        game.click(.policeStation, at: GridPosition(x: 14, y: 10))
        game.click(.park, at: GridPosition(x: 9, y: 7))
        game.check("a station and a park")

        game.pause()
        game.look(at: .problems)
        game.check("checking on the problems, paused")

        game.play()
        game.look(at: .none)
        game.tick(8)
        game.check("another week")
    }
}

extension ScenePlaytestTests {

    /// **A session nobody wrote.**
    ///
    /// The scripted tests above only cover what I thought to try, and every
    /// bug reported so far has been something nobody thought to try. This
    /// plays the city and checks after every step, so what it finds is what
    /// no author would have gone looking for.
    ///
    /// A handful of seeds rather than one: a single random walk is a single
    /// sample, and the cheapest way to widen the search is to run it from
    /// several places. Short in the normal suite; `PLAYTEST_FULL` makes it a
    /// real one, which is the same arrangement `PlaytestHarness` already uses
    /// for balance.
    func testARandomSessionKeepsThePictureHonest() {
        let long = PlaytestHarness.Profile.current == .full
        for seed in (long ? [1, 2, 3, 4, 5, 6] : [1, 2, 3]) as [UInt64] {
            let game = ScenePlaytest(map: startedCity(), seed: seed)
            var player = RandomScenePlayer(game: game, seed: seed)
            // A long run can afford to look less often: the check builds a
            // whole second scene, and anything that persists is still found.
            player.play(steps: long ? 300 : 45, checkingEvery: long ? 3 : 1)
        }
    }
}
