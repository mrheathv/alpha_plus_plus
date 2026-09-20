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

    // MARK: - More, reported from play

    /// **"The traffic overlay should still show cars, and you should be able
    /// to place roads while in the overlay."** Both halves, one cause: every
    /// overlay stripped the lane lines and removed the cars, so the one view
    /// that is *about* the street network was the one view that hid it.
    ///
    /// Roads placed there were landing correctly all along — they were simply
    /// invisible, which a player cannot tell apart from a click that did
    /// nothing.
    func testTheTrafficViewShowsTheStreetsAndTheTrafficOnThem() {
        let game = ScenePlaytest(map: startedCity())
        game.play()
        game.tick(6)

        game.look(at: .traffic)
        let road = GridPosition(x: 4, y: 3)
        XCTAssertNotNil(game.laneLine(at: road),
                        "the Traffic view hid the streets it is a heatmap of")

        // And a street laid while it is up shows up straight away.
        game.drag(.road, from: GridPosition(x: 8, y: 1), to: GridPosition(x: 8, y: 8))
        XCTAssertEqual(game.controller.map[GridPosition(x: 8, y: 5)].zone, .road,
                       "a road laid in the Traffic view did not land")
        XCTAssertNotNil(game.laneLine(at: GridPosition(x: 8, y: 5)),
                        "a road laid in the Traffic view landed but was never drawn")
        game.check("laying a road in the traffic view")
    }

    /// The other heatmaps still hide the streets, because there the data is
    /// the picture and the city on top is clutter. Traffic is the exception,
    /// not a new rule.
    func testTheOtherHeatmapsStillHideTheStreets() {
        let game = ScenePlaytest(map: startedCity())
        game.play()
        game.tick(6)
        for overlay in [OverlayMode.landValue, .pollution, .problems] {
            game.look(at: overlay)
            XCTAssertNil(game.laneLine(at: GridPosition(x: 4, y: 3)),
                         "\(overlay.displayName) is drawing streets over its own data")
        }
    }

    /// **A ship, for the one building whose whole purpose was invisible.**
    ///
    /// A seaport is built, and then it sits there. Everything it does happens
    /// in `Demand`, which is a number in a panel — nothing on the map ever
    /// said the quay was trading. A hull moving in the channel does, and it is
    /// the largest moving thing in the game precisely so it reads from across
    /// the map.
    ///
    /// It also answers the aircraft this project cut from the airport: a
    /// static plane merged into a crate at three tiles across, but **motion is
    /// a different channel from shape** — a hull tracking across open water
    /// has nothing it can be confused with.
    func testAShipSailsForAWorkingDock() {
        var map = CityMap(width: 22, height: 16)
        for x in 0 ..< 22 { map[GridPosition(x: x, y: 6)].zone = .road }
        // A sea along the bottom, reaching the edge of the map so there is
        // somewhere for a ship to come from.
        for y in 10 ..< 16 {
            for x in 0 ..< 22 { map[GridPosition(x: x, y: y)].isWater = true }
        }
        map.placeBuilding(zone: .seaport, origin: GridPosition(x: 8, y: 7))

        let lane = ShippingLane.path(in: map)
        XCTAssertFalse(lane.isEmpty, "a dock on a sea that reaches the edge has no route out")
        XCTAssertTrue(lane.allSatisfy { map[$0].isWater }, "the lane runs over dry land")

        let game = ScenePlaytest(map: map)
        game.play()
        game.frame()
        XCTAssertEqual(game.scene.pathVehicleCountForTesting, 1, "the dock got no ship")

        let before = game.scene.pathVehiclePositionsForTesting
        for _ in 0 ..< 40 { game.frame() }
        XCTAssertNotEqual(game.scene.pathVehiclePositionsForTesting, before, "the ship never moved")

        game.scene.camera?.setScale(1.6)
        game.scene.camera?.position = game.scene.tileNodesForTesting[
            GridPosition(x: 9, y: 9)
        ]?.position ?? .zero
        game.frame()
        game.capture("a working dock, and something using it")

        // And the airport, which had the same problem: everything it does is
        // a number in a panel.
        var air = CityMap(width: 22, height: 16)
        for x in 0 ..< 22 { air[GridPosition(x: x, y: 12)].zone = .road }
        air.placeBuilding(zone: .airport, origin: GridPosition(x: 8, y: 8))
        let field = ScenePlaytest(map: air)
        field.play()
        field.frame()
        field.scene.camera?.setScale(0.9)
        field.scene.camera?.position = field.scene.tileNodesForTesting[
            GridPosition(x: 9, y: 9)
        ]?.position ?? .zero
        field.frame()
        field.capture("the airport — an aircraft on the centreline")
        if let url = field.writeFilmstrip(named: "airfield") { print("✈️  Airfield: \(url.path)") }

        if let url = game.writeFilmstrip(named: "ship") { print("🚢 Ship: \(url.path)") }
    }

    /// No dock, no ship. A vessel gliding past an empty coastline would be
    /// scenery, and nothing else on this map is scenery — every mark says
    /// something about the city.
    func testAnEmptyCoastGetsNoShip() {
        var map = CityMap(width: 22, height: 16)
        for y in 10 ..< 16 {
            for x in 0 ..< 22 { map[GridPosition(x: x, y: y)].isWater = true }
        }
        XCTAssertTrue(ShippingLane.path(in: map).isEmpty)
    }

    /// A dock on a pond has nowhere to sail, and gets nothing — the same
    /// honesty a severed tram line gets.
    func testADockOnAPondHasNoLane() {
        var map = CityMap(width: 22, height: 16)
        for y in 8 ..< 11 {
            for x in 8 ..< 12 { map[GridPosition(x: x, y: y)].isWater = true }
        }
        map.placeBuilding(zone: .seaport, origin: GridPosition(x: 8, y: 5))
        XCTAssertTrue(ShippingLane.path(in: map).isEmpty,
                      "a landlocked pond reported a route to open sea")
    }

    /// **A tram runs on the streets, in Normal view.**
    ///
    /// Every other transit vehicle can only be drawn over its own diagram,
    /// because every other route here is a schematic between stations and a
    /// bus cutting diagonally across blocks would be a lie. A tram lays real
    /// track down real roads, so it is the one mode that can run on the map —
    /// and `Transit.tramTracks` has computed that track since trams landed
    /// with nothing drawing a vehicle on it.
    func testATramRunsOnItsOwnTrackInNormalView() {
        var map = startedCity()
        for x in 0 ..< map.width { map[GridPosition(x: x, y: 5)].zone = .road }
        map.placeBuilding(zone: .tramStop, origin: GridPosition(x: 2, y: 4))
        map.placeBuilding(zone: .tramStop, origin: GridPosition(x: map.width - 3, y: 4))
        map.transit.add(mode: .tram, stops: [
            GridPosition(x: 2, y: 4), GridPosition(x: map.width - 3, y: 4),
        ])
        map.tramTracks = Transit.tramTracks(in: map)

        let game = ScenePlaytest(map: map)
        game.play()
        game.frame()
        XCTAssertEqual(game.scene.pathVehicleCountForTesting, 1,
                       "a drawn tram line put no vehicle on the map")

        let before = game.scene.pathVehiclePositionsForTesting
        for _ in 0 ..< 30 { game.frame() }
        XCTAssertNotEqual(game.scene.pathVehiclePositionsForTesting, before, "the tram never moved")

        // And it stops with the city. This rides on `update`'s own pause
        // guard rather than on `animatedBySimulation`, which is the whole
        // reason it is driven per frame instead of by an `SKAction` — the
        // shape that let cars keep driving around a stopped map.
        game.pause()
        let parked = game.scene.pathVehiclePositionsForTesting
        for _ in 0 ..< 30 { game.frame() }
        XCTAssertEqual(game.scene.pathVehiclePositionsForTesting, parked,
                       "the tram kept running around a paused city")
    }

    /// **The cursor and the click must agree, everywhere.**
    ///
    /// The preview tested "would this replace something", which was the whole
    /// rule when it was written. Water made it a partial one: a house hovered
    /// over a river drew in the clear colour and then refused the click, and
    /// so did a seaport on dry land — which is the worse of the two, because
    /// *where you may put it* is the dock's entire mechanic.
    ///
    /// Written as a sweep rather than as two examples on purpose. A test
    /// naming the cases I thought of would have passed on the day water
    /// landed; asking every cell of a map that has a river in it is what
    /// makes the next rule added to `placementRefusal` show up here if the
    /// cursor is not taught about it.
    func testTheCursorNeverPromisesAPlacementTheClickRefuses() {
        var map = startedCity()
        for x in 0 ..< map.width { map[GridPosition(x: x, y: 8)].isWater = true }
        let game = ScenePlaytest(map: map)

        for tool in [ZoneType.residential, .road, .seaport, .airport] {
            game.controller.selectedTool = tool
            for position in map.tiles.map(\.position) {
                game.scene.updatePlacementPreview(at: position)
                let cursor = game.scene.placementPreviewForTesting
                guard !cursor.isHidden else { continue }
                let saysClear = cursor.strokeColor == RenderPalette.placementPreviewClearStroke

                // A copy, so asking the question does not build the city.
                let trial = GameController(map: map, rng: SystemRandomNumberGenerator(),
                                           peakPopulation: Unlocks.everythingUnlocked)
                trial.selectedTool = tool
                let outcome = trial.place(at: position)

                if saysClear {
                    XCTAssertEqual(outcome, .placed,
                                   "\(tool) at \(position): the cursor said clear and the click "
                                   + "returned \(outcome)")
                } else {
                    XCTAssertNotEqual(outcome, .placed,
                                      "\(tool) at \(position): the cursor said blocked and the "
                                      + "click placed it anyway")
                }
            }
        }
    }

    /// **"It could be more apparent that you're selecting a valid stop."**
    ///
    /// It was worse than unclear — the cursor was lying. A click names a
    /// station while a line is being drawn, but the preview described
    /// whatever zoning tool was armed, and its "would this replace something"
    /// test is true of every building on the map. So the stop you were meant
    /// to click was drawn in the *blocked* colour.
    func testTheCursorSaysWhichStopsALineCanCallAt() {
        var map = startedCity()
        map.placeBuilding(zone: .publicTransit, origin: GridPosition(x: 5, y: 3))
        let game = ScenePlaytest(map: map)
        game.look(at: .bus)
        game.beginLine(.bus)

        game.scene.updatePlacementPreview(at: GridPosition(x: 5, y: 3))
        let onStation = game.scene.placementPreviewForTesting
        XCTAssertFalse(onStation.isHidden)
        let valid = onStation.strokeColor

        game.scene.updatePlacementPreview(at: GridPosition(x: 9, y: 9))
        let onNothing = game.scene.placementPreviewForTesting
        XCTAssertNotEqual(valid, onNothing.strokeColor,
                          "a stop a line can call at looks the same as bare ground")

        // And the stop a line *cannot* call at is the one marked blocked —
        // asserted this way round because the failure was the inverse.
        XCTAssertEqual(onNothing.strokeColor, RenderPalette.placementPreviewBlockedStroke)
        XCTAssertEqual(valid, RenderPalette.placementPreviewClearStroke,
                       "the station you are meant to click is drawn as forbidden")
    }

    /// **What a block is short of, side by side.**
    ///
    /// The utility badge is drawn by `GameScene` and by nothing else, so the
    /// city render has never shown it and no test has ever looked at it —
    /// the same blind spot the backdrop had. It is also the mark this game
    /// asks a player to read most often, since it is the whole feedback loop
    /// for "why has this block stopped growing".
    ///
    /// Three lots: short of water, short of power, short of both. Together,
    /// because the question is whether they are *distinguishable*, which one
    /// badge at a time cannot answer.
    func testRenderUtilityWarnings() {
        var map = CityMap(width: 16, height: 10)
        for x in 0 ..< 16 { map[GridPosition(x: x, y: 6)].zone = .road }
        // Power for the left pair only, water for nobody — so the three lots
        // land on the three states without any of them being contrived.
        map.placeBuilding(zone: .generator, origin: GridPosition(x: 1, y: 8))
        for (index, x) in [2, 7, 12].enumerated() {
            let origin = GridPosition(x: x, y: 3)
            map.placeBuilding(zone: .residential, origin: origin)
            for cell in map.footprintCells(origin: origin, size: 2) {
                // Densities chosen to cross the water gate and, for the last
                // one, the power gate too.
                map[cell].density = index == 2 ? 4 : 2
            }
        }
        let game = ScenePlaytest(map: map)
        game.look(at: .none)
        game.frame()
        game.capture("short of water, power, and both")
        let url = game.writeFilmstrip(named: "utility-warnings")
        XCTAssertNotNil(url, "the utility-warning render produced nothing")
        if let url { print("⚡️ Utility warnings: \(url.path)") }
    }

    /// **What is on the streets, and what is running the lines.**
    ///
    /// Traffic is drawn by `GameScene` and by nothing else, so — like the
    /// backdrop and the utility badge before it — the city render has never
    /// shown a single car. That is now three separate marks this project has
    /// shipped with no picture of them anywhere, all for the same reason.
    ///
    /// Two frames: Normal, where the question is whether lorries read apart
    /// from cars and whether a jam looks like stopping; and the Bus view,
    /// where the question is whether a vehicle running the line is visible at
    /// all.
    /// **What the cars actually look like, at the three zooms the game is
    /// played at.** The diagnostic for G6, and deliberately a diagnostic
    /// rather than a change: "revisit the cars" is a judgement, and the
    /// existing traffic render only ever showed them at camera 1.0, so there
    /// has never been a picture of what they become when you pull back.
    ///
    /// The camera runs 0.5 to 3.0 and a 2×2 lot is 126 screen points zoomed
    /// in, 63 at rest and about 21 zoomed out — so one vehicle goes from
    /// roughly twenty points to four. `minimumDetailSize` was written about
    /// exactly this gap, for facade details, and nothing had ever applied it
    /// to the things that move.
    func testRenderCarsAtEveryZoom() {
        var map = CityMap(width: 22, height: 14)
        for x in 0 ..< 22 { map[GridPosition(x: x, y: 7)].zone = .road }
        for x in stride(from: 2, to: 20, by: 6) {
            for y in 0 ..< 14 { map[GridPosition(x: x, y: y)].zone = .road }
        }
        for origin in [GridPosition(x: 3, y: 2), GridPosition(x: 3, y: 10)] {
            map.placeBuilding(zone: .residential, origin: origin)
            for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = 5 }
        }
        for origin in [GridPosition(x: 15, y: 2), GridPosition(x: 15, y: 10)] {
            map.placeBuilding(zone: .industrial, origin: origin)
            for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = 5 }
        }
        map.trafficLoad = Traffic.computeLoad(for: map)

        let game = ScenePlaytest(map: map)
        game.play()
        let centre = game.scene.tileNodesForTesting[GridPosition(x: 9, y: 7)]?.position ?? .zero
        for (scale, label) in [(0.5, "zoomed in — 0.5"),
                               (1.0, "at rest — 1.0"),
                               (3.0, "zoomed out — 3.0")] {
            game.scene.camera?.setScale(CGFloat(scale))
            game.scene.camera?.position = centre
            game.frame()
            game.capture(label)
        }
        if let url = game.writeFilmstrip(named: "cars") { print("🚗 Cars: \(url.path)") }
    }

    func testRenderTrafficAndTransit() {
        var map = CityMap(width: 22, height: 14)
        for x in 0 ..< 22 { map[GridPosition(x: x, y: 7)].zone = .road }
        for x in stride(from: 2, to: 20, by: 6) {
            for y in 0 ..< 14 { map[GridPosition(x: x, y: y)].zone = .road }
        }
        // Homes at one end, factories at the other, so the router actually
        // sends traffic down the middle and the congestion is real rather
        // than a number typed into the fixture.
        for origin in [GridPosition(x: 3, y: 2), GridPosition(x: 3, y: 10)] {
            map.placeBuilding(zone: .residential, origin: origin)
            for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = 5 }
        }
        for origin in [GridPosition(x: 15, y: 2), GridPosition(x: 15, y: 10)] {
            map.placeBuilding(zone: .industrial, origin: origin)
            for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = 5 }
        }
        for x in [8, 14] { map.placeBuilding(zone: .publicTransit, origin: GridPosition(x: x, y: 6)) }
        map.transit.add(mode: .bus,
                        stops: [GridPosition(x: 8, y: 6), GridPosition(x: 14, y: 6)])
        map.trafficLoad = Traffic.computeLoad(for: map)

        let game = ScenePlaytest(map: map)
        game.play()
        // **At the zoom the game is played at, not the zoom that fits the
        // map.** A car is about eleven points across at camera 1.0 and half
        // that with the whole city in frame — reviewing vehicles at the
        // second one is the mistake `minimumDetailSize` was written about,
        // where art was judged at a size the game never shows.
        game.scene.camera?.setScale(1.0)
        game.scene.camera?.position = game.scene.tileNodesForTesting[
            GridPosition(x: 9, y: 7)
        ]?.position ?? .zero
        game.frame()
        game.capture("normal — cars, lorries, and a jam")
        game.look(at: .bus)
        game.frame()
        game.capture("the bus view — something running the line")
        let url = game.writeFilmstrip(named: "traffic")
        XCTAssertNotNil(url)
        if let url { print("🚗 Traffic: \(url.path)") }
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
    /// **Rain, and the city thrown back off the wet street.**
    ///
    /// A dry frame and a wet one of the same city, so the question the render
    /// has to answer — is the reflection doing anything, and is it doing too
    /// much — can be asked by comparing rather than remembered between runs.
    ///
    /// `Weather` is a pure function of the day, so day 350 is the heaviest
    /// rain in the first year every single run. That determinism is the whole
    /// reason it is a clock rather than a dice roll.
    func testFilmstripOfRain() {
        var map = startedCity()
        var index = 0
        for y in stride(from: 1, to: 15, by: 3) {
            for x in stride(from: 0, to: 21, by: 3) {
                let origin = GridPosition(x: x, y: y)
                guard map.footprintCells(origin: origin, size: 2)
                    .allSatisfy({ map[$0].zone == .empty }) else { continue }
                index += 1
                let zone = [ZoneType.residential, .commercial, .commercial, .industrial][index % 4]
                map.placeBuilding(zone: zone, origin: origin)
                // Tall, because a reflection is a statement about height and a
                // city of two-storey blocks cannot show whether it works.
                for cell in map.footprintCells(origin: origin, size: 2) {
                    map[cell].density = 3 + index % 3
                }
            }
        }

        // The city is simply *played* to each day rather than having its clock
        // set, because `GameController.map` is `private(set)` and that is the
        // right call — the calendar is the simulation's, not a dial the view
        // reaches into. Conveniently the first storm of every city lands on
        // days 2–11 and peaks at 6, so this costs a handful of ticks.
        // Plumbed and wired, because an unserved city wears a water drop and a
        // lightning bolt over every building — and the first render of this
        // was a picture of badges with a city somewhere behind them. A fixture
        // has to let the thing it is testing be visible.
        for tile in map.tiles where tile.zone == .road {
            map[tile.position].hasPipe = true
            map[tile.position].hasPowerLine = true
        }

        let game = ScenePlaytest(map: map)
        // Funding buys *capacity*, not just coverage. Thirty lots at density
        // three to five draw several times what one tower supplies, so the
        // first attempt at this had a fully-plumbed city in a city-wide
        // outage — which looks exactly like no pipes at all.
        game.controller.setFundingLevel(4, for: .waterTower)
        game.controller.setFundingLevel(4, for: .powerPlant)
        game.capture("day 0 — dry")

        game.play()
        game.tick(6)
        game.capture("day 6 — the first storm, at its heaviest")
        XCTAssertTrue(game.scene.rainIsFallingForTesting, "day 6 is a downpour and nothing fell")
        XCTAssertGreaterThan(game.scene.wetnessForTesting, 0, "the streets never got wet")

        // And it dries up, rather than the city staying shiny forever.
        game.tick(8)
        game.capture("day 14 — dried out")
        XCTAssertFalse(game.scene.rainIsFallingForTesting, "the rain never stopped")
        XCTAssertEqual(game.scene.wetnessForTesting, 0, "the streets stayed wet after the rain passed")

        if let url = game.writeFilmstrip(named: "rain") {
            print("🌧  \(url.path)")
        }
    }

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
