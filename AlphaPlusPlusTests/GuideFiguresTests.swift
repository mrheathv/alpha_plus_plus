import SpriteKit
import SwiftUI
import XCTest
@testable import AlphaPlusPlus

/// The pictures the player-facing manual is illustrated with.
///
/// **These are not the art contact sheets, and the difference is the point.**
/// Every render in this project so far exists to *review* the art:
/// `IsometricContactSheetTests` draws ten seeds a tier to ask whether the
/// variety is real, `LandmarkTests` stands a landmark next to an ordinary tower
/// to ask whether it reads as one. A manual asks a different question — can a
/// player who has never seen this building recognise it on their own map — and
/// that changes what the cell has to do. So a figure here shows *one* of each
/// rather than many, and every caption is the name the **toolbar** uses
/// (`RenderPalette.displayName`), never the `ZoneType` case, because a guide
/// that teaches vocabulary the game does not use has taught the wrong thing.
///
/// Generated rather than screenshotted, for the reason `AppIconTests` gives:
/// the drawing is deterministic, so re-running this after an art change
/// produces the manual's new illustrations instead of leaving it quietly
/// describing a game that has moved on.
///
/// ```sh
/// xcodebuild -project AlphaPlusPlus.xcodeproj -scheme AlphaPlusPlus \
///            -configuration Debug -derivedDataPath ./build test \
///            -only-testing:AlphaPlusPlusTests/GuideFiguresTests
/// ```
@MainActor
final class GuideFiguresTests: XCTestCase {

    private static let projection = Isometric()
    private static let cell = CGSize(width: 220, height: 220)

    // MARK: - Buildings

    /// **What growth looks like.** One lot, the same seed, at each look it
    /// takes — so the thing the whole gate chain is about is a picture rather
    /// than a number.
    ///
    /// The same seed in every cell deliberately: this is one lot growing up,
    /// not three different lots, and a different building in each would say
    /// the opposite.
    ///
    /// **Three cells for five levels**, because `ZoneMassing` draws from
    /// `RenderPalette.growthTier`, which pairs 1 with 2 and 3 with 4 — so a
    /// five-cell figure renders two pairs of identical buildings, which reads
    /// as a broken render rather than as the truth it is. Captioning the pairs
    /// says the true and more useful thing: the building you can see changes
    /// at levels 3 and 5.
    func testRenderTheGrowthLadder() throws {
        let seed = GridPosition(x: 6, y: 11)
        let looks = [(1, "Levels 1–2"), (3, "Levels 3–4"), (5, "Level 5")]
        let cells = try looks.map { density, caption in
            (caption: caption, image: try buildingCell(.residential, density: density, seed: seed))
        }
        // Pinned, because the caption above is a claim about the renderer: if
        // the tiers are ever split per level this figure silently starts
        // under-reporting the ladder.
        XCTAssertEqual(RenderPalette.growthTier(for: 1), RenderPalette.growthTier(for: 2))
        XCTAssertEqual(RenderPalette.growthTier(for: 3), RenderPalette.growthTier(for: 4))
        XCTAssertNotEqual(RenderPalette.growthTier(for: 4), RenderPalette.growthTier(for: 5))

        try write(Self.sheet(cells: cells, columns: 3, cellSize: Self.cell,
                             title: "One residential lot, as it grows"),
                  named: "guide-growth")
    }

    /// **The three zones, told apart by shape.** Low density on the top row,
    /// full height underneath.
    ///
    /// Both rows are needed and the top one is the one that earns its place: a
    /// player spends most of the early game looking at level-1 lots, and the
    /// three zones' vocabularies — a row of houses, a strip of shops, a wide
    /// shed — are furthest apart exactly there.
    func testRenderTheThreeZones() throws {
        let zones: [ZoneType] = [.residential, .commercial, .industrial]
        let seed = GridPosition(x: 3, y: 4)
        var cells: [(caption: String, image: NSImage)] = []
        for density in [1, 5] {
            for zone in zones {
                cells.append((
                    caption: "\(RenderPalette.displayName(for: zone)) · level \(density)",
                    image: try buildingCell(zone, density: density, seed: seed)
                ))
            }
        }
        try write(Self.sheet(cells: cells, columns: 3, cellSize: Self.cell,
                             title: "The three zones, low density and full height"),
                  named: "guide-zones")
    }

    /// **Everything you place that does not grow**, with the name the toolbar
    /// gives it.
    ///
    /// This is the figure the manual most needed and the one no existing sheet
    /// could supply: `isometric-zones.png` has all of these in it, six seeds
    /// apiece, scattered down fourteen thousand pixels between the growable
    /// tiers. A player wants the opposite — one of each, in one frame, next to
    /// its name.
    func testRenderTheServiceBuildings() throws {
        let zones: [ZoneType] = [
            .policeStation, .fireStation, .school, .hospital,
            .park, .stadium, .waterPump, .waterTower,
            .generator, .powerPlant, .publicTransit, .tramStop,
            .subway, .railStation, .seaport, .airport,
            // The three rank rewards. They are not services, and they are
            // here anyway: the caption claims this is everything that does
            // not grow, and a player who has just earned an arcology wants
            // to know what they are looking for.
            .neonArcade, .broadcastTower, .arcology,
        ]
        let cells = try zones.map { zone in
            (caption: RenderPalette.displayName(for: zone),
             image: try buildingCell(zone, density: 0, seed: GridPosition(x: 5, y: 7)))
        }
        try write(Self.sheet(cells: cells, columns: 4, cellSize: Self.cell,
                             title: "Everything you place that does not grow"),
                  named: "guide-services")
    }

    // MARK: - The city

    /// **Drawing a bus line, with the panel over the map.**
    ///
    /// The first picture in this project to show the chrome *on top of the
    /// city*, and it needs composing by hand because neither renderer can do
    /// it alone: `ImageRenderer` cannot draw the hosted `SKView` (the live
    /// cockpit render comes out with a blank rectangle where the map is), and
    /// `SKView.texture(from:)` knows nothing about SwiftUI. Both halves are
    /// real — a scene frame with the shader on it, and the actual
    /// `TransitPanel` the app builds — drawn into one bitmap at the offset
    /// `GameView` puts the panel at.
    ///
    /// The draft is left deliberately **mid-line**: the panel's prompt is
    /// different at every stage ("click a station to start" → "click the last
    /// one again to take it off" → "click more stations, or finish"), and the
    /// stage worth photographing is the one where both the finished line and
    /// the line being drawn are on the map at once.
    func testRenderDrawingABusLine() throws {
        var map = Self.transitFixture()
        map.trafficLoad = Traffic.computeLoad(for: map)

        let game = ScenePlaytest(map: map, size: CGSize(width: 1240, height: 700))
        game.play()
        game.look(at: .bus)
        game.frame()
        game.zoom(by: 0.82)

        // A second line, half drawn, and **along the other street** — the
        // first version drew it between two stations the finished line
        // already called at, so the figure showed one corridor wearing two
        // colours instead of a line being added to a network.
        game.controller.beginTransitRoute(mode: .bus)
        game.controller.addStopToRoute(at: GridPosition(x: 6, y: 5))
        game.controller.addStopToRoute(at: GridPosition(x: 18, y: 5))
        game.scene.refreshAll()

        let frame = try sceneFrame(game)
        let panel = try panelImage(for: game.controller)
        let composed = try XCTUnwrap(
            Self.compose(frame: frame, panel: panel, inset: RetroMetrics.gutter),
            "failed to compose the transit figure"
        )
        try write(composed, named: "guide-transit")
    }

    /// **The same city under three views**, because the whole argument for the
    /// overlays is that they answer different questions about one map, and
    /// three separate pictures of three different cities cannot make it.
    func testRenderTheViews() throws {
        var map = Self.transitFixture()
        Self.plumb(&map)
        map.trafficLoad = Traffic.computeLoad(for: map)

        let game = ScenePlaytest(map: map, size: CGSize(width: 780, height: 470))
        // Supply is a pure function of the map and nothing has ticked, so
        // without this every building reads as unsupplied and the Water view
        // illustrates one state twice.
        game.controller.recomputeUtilitySupply()
        game.play()

        var cells: [(caption: String, image: NSImage)] = []
        for view in [OverlayMode.none, .problems, .water] {
            game.look(at: view)
            game.frame()
            game.zoom(by: 0.88)
            cells.append((caption: view.displayName, image: try sceneFrame(game)))
        }
        try write(Self.sheet(cells: cells, columns: 3, cellSize: game.scene.size,
                             title: "One city, three views"),
                  named: "guide-views")
    }

    /// **The three states of drawing a line**, which no single screenshot can
    /// show: the panel's prompt is different at every stage, and the stages
    /// are the instructions.
    func testRenderTheRouteEditorSteps() throws {
        let game = ScenePlaytest(map: Self.transitFixture(),
                                 size: CGSize(width: 400, height: 300))
        let captions = ["1 · pick the tool", "2 · click a station", "3 · click more, then finish"]
        let stops = [GridPosition(x: 6, y: 12), GridPosition(x: 12, y: 12), GridPosition(x: 18, y: 12)]
        game.controller.beginTransitRoute(mode: .bus)

        var cells: [(caption: String, image: NSImage)] = []
        for (index, caption) in captions.enumerated() {
            if index > 0 { game.controller.addStopToRoute(at: stops[index - 1]) }
            if index == 2 { game.controller.addStopToRoute(at: stops[2]) }
            cells.append((caption: caption, image: try panelImage(for: game.controller)))
        }
        let widest = cells.map(\.image.size.width).max() ?? 0
        let tallest = cells.map(\.image.size.height).max() ?? 0
        try write(Self.sheet(cells: cells, columns: 3,
                             cellSize: CGSize(width: widest + 28, height: tallest + 16),
                             title: "Drawing a bus line, one click at a time"),
                  named: "guide-transit-steps")
    }

    /// **The marks a building wears**, all in one frame — which is the only
    /// arrangement that can answer whether they are distinguishable, the same
    /// reason the inspector states are rendered together.
    func testRenderTheMarksOnABuilding() throws {
        var map = CityMap(width: 18, height: 12)
        for x in 0 ..< 18 { map[GridPosition(x: x, y: 5)].zone = .road }
        for x in 0 ..< 18 { map[GridPosition(x: x, y: 9)].zone = .road }

        // Left: wants water and power. Middle: under construction.
        // Right: alight.
        let wanting = GridPosition(x: 2, y: 6)
        map.placeBuilding(zone: .residential, origin: wanting)
        for cell in map.footprintCells(origin: wanting, size: 2) { map[cell].density = 4 }

        let building = GridPosition(x: 8, y: 6)
        map.placeBuilding(zone: .commercial, origin: building)
        for cell in map.footprintCells(origin: building, size: 2) {
            map[cell].density = 2
            map[cell].constructionRemaining = 18
        }

        let alight = GridPosition(x: 14, y: 6)
        map.placeBuilding(zone: .industrial, origin: alight)
        for cell in map.footprintCells(origin: alight, size: 2) {
            map[cell].density = 3
            map[cell].fireTicks = 2
            map[cell].damagedBy = .fireStation
        }

        let game = ScenePlaytest(map: map, size: CGSize(width: 1180, height: 620))
        game.play()
        game.frame()
        try write(Self.sheet(cells: [(caption: "wants water and power · under construction · alight",
                                      image: try sceneFrame(game))],
                             columns: 1, cellSize: game.scene.size,
                             title: "What a block tells you"),
                  named: "guide-marks")
    }

    // MARK: - The cover

    /// **The picture at the top of the manual.**
    ///
    /// Deliberately *not* the wide shot `CityPortraitTests` takes. That one
    /// frames the whole ground diamond, which is the right answer for "how big
    /// is this city" and the wrong one for a cover: the map becomes an island
    /// in a field of empty night, and no individual building is large enough
    /// to read. A cover has to show what the game actually looks like to play,
    /// which means a district rather than a map.
    ///
    /// And it frames the **most varied** neighbourhood rather than the
    /// densest. `busiestBlock` finds downtown, which is where every lot has
    /// topped out and the picture is a wall of towers in one hue. What sells
    /// this game is that three zones, the services and the terrain look
    /// nothing like each other, and that is a property of a *mixed* block.
    ///
    /// Shot at several scales because which one reads best is a judgement, and
    /// this project's rule for a judgement is to render the candidates and
    /// look rather than to reason about them.
    func testRenderTheCover() throws {
        let name = ProcessInfo.processInfo.environment["COVER_CITY"] ?? "Riverrun"
        let url = try CitySaveFile.defaultDirectory()
            .appendingPathComponent("\(name).alphacity")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "no \(name).alphacity — run CityMinterTests with TEST_RUNNER_MINT_CITIES=1 first"
        )

        let save = try CitySaveFile.read(from: url)
        let controller = GameController(map: save.map, rng: SeededRNG(seed: 1),
                                        peakPopulation: Unlocks.everythingUnlocked)
        try controller.restore(from: save)

        // A cover band rather than a window: wide and short, so it sits at the
        // top of a page without pushing the words off the screen.
        let frame = CGSize(width: 1800, height: 780)
        let scene = GameScene(controller: controller)
        scene.size = frame
        let view = SKView(frame: NSRect(origin: .zero, size: frame))
        view.presentScene(scene)
        scene.rebuildEntireGrid()
        scene.refreshAll()

        let spot = Self.mostVariedNeighbourhood(in: controller.map)
        print("🎞  \(name) cover centred on \(spot.position) — \(spot.report)")

        for scale in [0.7, 1.0, 1.35] as [CGFloat] {
            // Scale first: `centerCameraForTesting` clamps against the camera's
            // *current* zoom, so centring before scaling clamps to the wrong
            // rectangle and the frame drifts off the spot.
            scene.setCameraScaleForTesting(scale)
            scene.centerCameraForTesting(on: spot.position)
            // Culling and the detail tier both read the camera inside
            // `update`, so a capture without this gets the far textures at
            // close range — a frame the game never draws.
            for step in 0 ..< 4 { scene.update(TimeInterval(step) / 60) }
            _ = view.texture(from: scene, crop: CGRect(origin: .zero, size: frame))
            let texture = try XCTUnwrap(
                view.texture(from: scene, crop: CGRect(origin: .zero, size: frame)),
                "the scene rendered nothing at \(scale)"
            )
            let image = NSImage(cgImage: texture.cgImage(), size: frame)
            let data = NSBitmapImageRep(data: image.tiffRepresentation ?? Data())?
                .representation(using: .png, properties: [:])
            try write(data, named: "guide-cover-\(Int(scale * 100))")
        }
    }

    /// The block with the most *kinds* of thing in it.
    ///
    /// Scored rather than chosen by eye, so it survives the city being
    /// re-minted: a hand-picked coordinate is a number that silently stops
    /// meaning anything the moment the map changes under it.
    private static func mostVariedNeighbourhood(
        in map: CityMap, radius: Int = 7
    ) -> (position: GridPosition, report: String) {
        let growable: Set<ZoneType> = [.residential, .commercial, .industrial]
        var best = GridPosition(x: map.width / 2, y: map.height / 2)
        var bestScore = -1
        var bestReport = ""

        for y in stride(from: radius, to: map.height - radius, by: 2) {
            for x in stride(from: radius, to: map.width - radius, by: 2) {
                var zones: Set<ZoneType> = []
                var civics: Set<ZoneType> = []
                var densities: Set<Int> = []
                var water = 0, total = 0, built = 0

                for dy in -radius ... radius {
                    for dx in -radius ... radius {
                        let tile = map[GridPosition(x: x + dx, y: y + dy)]
                        total += 1
                        if tile.isWater { water += 1 }
                        guard tile.isBuildingAnchor else { continue }
                        if growable.contains(tile.zone) {
                            zones.insert(tile.zone)
                            densities.insert(tile.density)
                            built += tile.density
                        } else if tile.zone != .empty && tile.zone != .road && tile.zone != .highway {
                            civics.insert(tile.zone)
                        }
                    }
                }

                // A frame that is mostly water is a picture of a lake.
                guard Double(water) / Double(total) < 0.4 else { continue }

                let score = 40 * zones.count
                    + 14 * min(civics.count, 6)
                    + 8 * max(0, (densities.max() ?? 0) - (densities.min() ?? 0))
                    + 2 * min(water, 24)
                    + built / 4
                if score > bestScore {
                    bestScore = score
                    best = GridPosition(x: x, y: y)
                    bestReport = "\(zones.count) zones, \(civics.count) civic kinds, "
                        + "\(water) water tiles, score \(score)"
                }
            }
        }
        return (best, bestReport)
    }

    // MARK: - Fixtures

    /// Homes at one end, factories at the other, bus stops down the middle —
    /// so the router sends real traffic across it and a line drawn along that
    /// corridor is a line somebody would actually draw.
    private static func transitFixture() -> CityMap {
        var map = CityMap(width: 26, height: 18)
        for x in 0 ..< 26 { map[GridPosition(x: x, y: 13)].zone = .road }
        for x in 0 ..< 26 { map[GridPosition(x: x, y: 4)].zone = .road }
        for x in stride(from: 2, to: 26, by: 6) {
            for y in 0 ..< 18 { map[GridPosition(x: x, y: y)].zone = .road }
        }
        for origin in [GridPosition(x: 3, y: 5), GridPosition(x: 3, y: 14),
                       GridPosition(x: 9, y: 14), GridPosition(x: 9, y: 5)] {
            map.placeBuilding(zone: .residential, origin: origin)
            for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = 5 }
        }
        for origin in [GridPosition(x: 15, y: 5), GridPosition(x: 21, y: 14)] {
            map.placeBuilding(zone: .commercial, origin: origin)
            for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = 4 }
        }
        for origin in [GridPosition(x: 21, y: 5), GridPosition(x: 15, y: 14)] {
            map.placeBuilding(zone: .industrial, origin: origin)
            for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = 5 }
        }
        // Beside the streets rather than on them: a stop placed on a road
        // replaces it, and a line along a severed street is not a picture of
        // anything a player would build.
        let southern = [GridPosition(x: 6, y: 12), GridPosition(x: 12, y: 12),
                        GridPosition(x: 18, y: 12)]
        let northern = [GridPosition(x: 6, y: 5), GridPosition(x: 18, y: 5)]
        for stop in southern + northern { map.placeBuilding(zone: .publicTransit, origin: stop) }
        map.transit.add(mode: .bus, stops: southern)
        return map
    }

    /// A tower, a plant, and one main and one line down the middle of the map.
    ///
    /// Deliberately **partial**: the run covers the northern row of blocks and
    /// not the southern one, so the Water view has a supplied building *and* a
    /// building shouting for water in the same frame. A fixture where only one
    /// of the two can occur is a picture that cannot show the thing the view
    /// exists for — the trap every render note in `CLAUDE.md` keeps recording.
    private static func plumb(_ map: inout CityMap) {
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 4, y: 0))
        map.placeBuilding(zone: .powerPlant, origin: GridPosition(x: 10, y: 0))
        for y in 2 ... 8 {
            map[GridPosition(x: 4, y: y)].hasPipe = true
            map[GridPosition(x: 10, y: y)].hasPowerLine = true
        }
        for x in 0 ..< map.width {
            map[GridPosition(x: x, y: 8)].hasPipe = true
            map[GridPosition(x: x, y: 8)].hasPowerLine = true
        }
    }

    // MARK: - Rendering one building

    /// One lot on its own ground, the way `IsometricContactSheetTests` draws a
    /// cell — the lot anchored rather than the building, so a bus shelter
    /// stays visibly smaller than a power plant instead of every cell being
    /// scaled to fill.
    private func buildingCell(_ zone: ZoneType, density: Int, seed: GridPosition) throws -> NSImage {
        let size = Self.cell
        let projection = Self.projection
        let footprint = CGFloat(zone.footprintSize)
        let scene = SKScene(size: size)
        scene.backgroundColor = RenderPalette.background

        let lotCentre = projection.project(footprint / 2, footprint / 2, 0)
        let origin = CGPoint(x: size.width / 2 - lotCentre.x, y: size.height * 0.32 - lotCentre.y)

        for x in 0 ..< zone.footprintSize {
            for y in 0 ..< zone.footprintSize {
                let tile = SKShapeNode(path: projection.tileDiamond(x: CGFloat(x), y: CGFloat(y), inset: 0.015))
                tile.fillColor = RenderPalette.color(for: zone, density: density)
                tile.strokeColor = RenderPalette.ground.blended(withFraction: 0.3, of: .white) ?? .clear
                tile.lineWidth = 0.6
                tile.position = origin
                scene.addChild(tile)
            }
        }

        if let massing = ZoneMassing.make(for: zone, density: density, seed: seed) {
            let node = IsometricBuilding.node(
                for: massing,
                accent: ZoneMassing.accent(for: zone, density: density),
                tier: max(1, RenderPalette.growthTier(for: density)),
                in: projection
            )
            node.position = origin
            scene.addChild(node)
        }

        let view = SKView(frame: NSRect(origin: .zero, size: size))
        view.presentScene(scene)
        let texture = try XCTUnwrap(
            view.texture(from: scene, crop: CGRect(origin: .zero, size: size)),
            "\(zone.rawValue) at \(density): SKView produced no texture"
        )
        return NSImage(cgImage: texture.cgImage(), size: size)
    }

    /// A frame off the live session.
    ///
    /// **The first capture of any scene is thrown away**, because it comes back
    /// measurably different from the second with nothing changed in between —
    /// the same correction `CityPortraitTests` records. A figure taken from it
    /// is a picture of a frame the game never draws.
    private func sceneFrame(_ game: ScenePlaytest) throws -> NSImage {
        let scene = game.scene
        let view = try XCTUnwrap(scene.view, "the session's scene is not on a view")
        _ = view.texture(from: scene)
        let texture = try XCTUnwrap(view.texture(from: scene), "SKView produced no frame")
        return NSImage(cgImage: texture.cgImage(), size: scene.size)
    }

    /// The real `TransitPanel`, built the way `GameView` builds it.
    private func panelImage(for controller: GameController) throws -> NSImage {
        let mode = TransitRoute.Mode.bus
        let panel = TransitPanel(
            mode: mode,
            routes: controller.map.transit.routes(mode: mode),
            draft: controller.routeDraft?.mode == mode ? controller.routeDraft : nil,
            workingStops: controller.workingStopCounts(),
            capacity: controller.routeCapacities(),
            ridership: { controller.map.trafficLoad.ridership(onRoute: $0) },
            onBegin: {}, onEdit: { _ in }, onDelete: { _ in },
            onUndo: {}, onCommit: {}, onCancel: {}
        )
        let renderer = ImageRenderer(content: AnyView(panel))
        renderer.scale = 2
        return try XCTUnwrap(renderer.nsImage, "ImageRenderer produced no panel")
    }

    // MARK: - Composition

    /// Draws the panel over the frame at the inset `GameView` uses, so the
    /// figure shows the layout the app shows rather than an arrangement
    /// invented here.
    private static func compose(frame: NSImage, panel: NSImage, inset: CGFloat) -> Data? {
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(frame.size.width * scale), pixelsHigh: Int(frame.size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = frame.size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        frame.draw(in: NSRect(origin: .zero, size: frame.size))
        panel.draw(in: NSRect(x: inset,
                              y: frame.size.height - inset - panel.size.height,
                              width: panel.size.width, height: panel.size.height))

        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// A titled grid of captioned cells — the same shape every contact sheet
    /// in this project uses, so a figure in the manual and a sheet in the
    /// build directory read as the same family.
    private static func sheet(
        cells: [(caption: String, image: NSImage)], columns: Int,
        cellSize: CGSize, title: String
    ) -> Data? {
        let scale: CGFloat = 2
        let captionHeight: CGFloat = 22, margin: CGFloat = 18, titleBand: CGFloat = 34
        let rows = Int((Double(cells.count) / Double(columns)).rounded(.up))
        let sheetSize = CGSize(
            width: CGFloat(columns) * cellSize.width + margin * 2,
            height: CGFloat(rows) * (cellSize.height + captionHeight) + margin * 2 + titleBand
        )

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(sheetSize.width * scale), pixelsHigh: Int(sheetSize.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = sheetSize
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        RenderPalette.background.setFill()
        NSRect(origin: .zero, size: sheetSize).fill()

        title.draw(
            at: NSPoint(x: margin, y: sheetSize.height - margin - 20),
            withAttributes: [
                .font: NSFont(name: "Menlo-Bold", size: 15) ?? NSFont.boldSystemFont(ofSize: 15),
                .foregroundColor: NSColor.white,
            ]
        )
        let captionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Menlo", size: 11) ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(white: 0.82, alpha: 1),
        ]

        for (index, entry) in cells.enumerated() {
            let column = index % columns, row = index / columns
            let x = margin + CGFloat(column) * cellSize.width
            let y = sheetSize.height - margin - titleBand - CGFloat(row + 1) * (cellSize.height + captionHeight)
            entry.image.draw(in: NSRect(x: x, y: y + captionHeight,
                                        width: cellSize.width, height: cellSize.height))
            let captionSize = entry.caption.size(withAttributes: captionAttributes)
            entry.caption.draw(
                at: NSPoint(x: x + max(4, (cellSize.width - captionSize.width) / 2), y: y + 5),
                withAttributes: captionAttributes
            )
        }

        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private func write(_ data: Data?, named name: String) throws {
        let payload = try XCTUnwrap(data, "\(name): produced nothing")
        let destination = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ContactSheet/\(name).png")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try payload.write(to: destination)
        print("📖 \(name): \(destination.path) (\(payload.count) bytes)")
        XCTAssertGreaterThan(payload.count, 0)
    }
}
