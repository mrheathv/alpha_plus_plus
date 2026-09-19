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

    // MARK: - Reported from play

    /// **"You place a power line or pipe and it doesn't place."**
    ///
    /// Picking a route tool on the toolbar *starts a line*, deliberately — a
    /// route view that left you with nothing to draw would be a mode with
    /// nothing in it. Picking a different network tool afterwards changes the
    /// view and says nothing about that half-drawn line, so the draft is
    /// still open while the player is looking at Water or Power.
    ///
    /// And `mouseDragged` refused to paint *at all* while any draft existed.
    /// So a single click still laid one tile and every drag did nothing,
    /// which is precisely "it doesn't place" — and it stayed that way until
    /// the player happened to pick a zone tool, since `selectTool` is the
    /// only thing in the game that clears a draft.
    func testAHalfDrawnTransitLineDoesNotBlockLayingPipe() {
        let game = ScenePlaytest(map: startedCity())

        // Pick Bus Route, which raises the Bus view and opens a draft.
        game.look(at: .bus)
        game.beginLine(.bus)

        // Then pick Pipe, which is only a change of view.
        game.look(at: .water)
        game.dragInView(from: GridPosition(x: 1, y: 12), to: GridPosition(x: 1, y: 4))

        let laid = (4 ... 12).filter { game.controller.map[GridPosition(x: 1, y: $0)].hasPipe }
        XCTAssertEqual(laid.count, 9,
                       "a half-drawn bus line stopped a pipe drag from laying anything")
        game.check("laying pipe with a line still half-drawn")
    }

    /// The same thing one layer up: the drag has to keep being ignored in the
    /// view that is actually taking route clicks, or dragging across a station
    /// would add it once per frame.
    func testADragStillDoesNotPaintStopsOntoALine() {
        let game = ScenePlaytest(map: startedCity())
        game.look(at: .bus)
        game.beginLine(.bus)
        game.dragInView(from: GridPosition(x: 0, y: 0), to: GridPosition(x: 21, y: 15))
        XCTAssertLessThanOrEqual(game.controller.routeDraft?.stops.count ?? 0, 1,
                                 "a drag across the map added stops to the line")
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

extension ScenePlaytestTests {

    /// **A city changing, as a strip I can look at.**
    ///
    /// Every render this project had before this one was a still of a freshly
    /// built scene — which is exactly the state none of the bugs play has
    /// found can exist in. A pipe that is laid but not drawn, a building that
    /// grows but is not redrawn, a run whose joints are stale: all of them are
    /// facts about *what happened between two frames*, and a single frame has
    /// no way to express one.
    ///
    /// The assertions above already say whether the picture agrees. This says
    /// what it looks like, which is the half no assertion can carry.
    func testFilmstripOfASession() {
        // A denser city than the scripted sessions use: those are about
        // whether the picture agrees, and this one is about whether I can read
        // it, which needs something on the map worth reading.
        var map = startedCity()
        var index = 0
        for y in stride(from: 1, to: 15, by: 3) {
            for x in stride(from: 0, to: 21, by: 3) {
                let origin = GridPosition(x: x, y: y)
                guard map.footprintCells(origin: origin, size: 2)
                    .allSatisfy({ map[$0].zone == .empty }) else { continue }
                index += 1
                let zone = [ZoneType.residential, .residential, .commercial, .industrial][index % 4]
                map.placeBuilding(zone: zone, origin: origin)
                for cell in map.footprintCells(origin: origin, size: 2) {
                    map[cell].density = 1 + index % 3
                }
            }
        }
        let game = ScenePlaytest(map: map)
        game.capture("a city, paused, as you find it")

        game.look(at: .water)
        game.capture("the water view — most of it wants a main")

        game.dragInView(from: GridPosition(x: 1, y: 13), to: GridPosition(x: 1, y: 2))
        game.capture("a trunk main up the west side")

        game.dragInView(from: GridPosition(x: 1, y: 2), to: GridPosition(x: 20, y: 2))
        game.capture("and east across the top, straight through the blocks")

        game.look(at: .none)
        game.play()
        game.tick(6)
        game.capture("six days later")

        game.look(at: .water)
        game.capture("the same view again, now that it is plumbed")

        game.look(at: .problems)
        game.capture("what is still wrong")

        game.look(at: .none)
        game.tick(10)
        game.capture("ten more days")

        game.pause()
        game.drag(.road, from: GridPosition(x: 11, y: 0), to: GridPosition(x: 11, y: 15))
        game.capture("a cross street, laid while paused")

        game.writeFilmstrip(named: "scene-session")
        game.check("the whole strip")
    }
}
