import XCTest
import SpriteKit
@testable import AlphaPlusPlus

/// The look switch, and whether it actually switches anything.
///
/// This project has twice shipped a control that compiled and did nothing —
/// `SKAction.colorize` on a plain node, and an overlay tint casting to a type
/// the ground had stopped being. A style toggle is exactly that shape of
/// risk: the palette is *baked into cached textures*, so it is entirely
/// possible for the menu item to work, the property to change, and the map to
/// carry on looking identical.
@MainActor
final class VisualStyleTests: XCTestCase {

    /// `VisualStyle.current` is global, so a test that leaves it moved would
    /// silently restyle every render test that runs after it.
    private var original: VisualStyle!

    override func setUp() {
        super.setUp()
        original = VisualStyle.current
    }

    override func tearDown() {
        VisualStyle.current = original
        super.tearDown()
    }

    private func cityWithAStreet() -> CityMap {
        var map = CityMap(width: 12, height: 12)
        for x in 2 ..< 10 { map[GridPosition(x: x, y: 5)].zone = .road }
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 4, y: 6))
        for cell in map.footprintCells(origin: GridPosition(x: 4, y: 6), size: 2) {
            map[cell].density = 5
        }
        return map
    }

    // MARK: - The switch reaches the map

    func testChangingTheStyleRedrawsTheStreetDarker() {
        let controller = GameController(map: cityWithAStreet(), rng: SeededRNG(seed: 4))
        let scene = GameScene(controller: controller)
        scene.size = CGSize(width: 600, height: 400)
        let view = SKView(frame: NSRect(origin: .zero, size: scene.size))
        view.presentScene(scene)

        func laneAlpha() -> CGFloat? {
            scene.rebuildEntireGrid()
            scene.refreshAll()
            let node = scene.tileNodesForTesting[GridPosition(x: 5, y: 5)]
            return node?.children.first { $0.name == IsoTileRenderer.laneNodeNameForTesting }?.alpha
        }

        controller.visualStyle = .classic
        scene.restyle()
        let classic = try? XCTUnwrap(laneAlpha())

        controller.visualStyle = .cinematic
        scene.restyle()
        let cinematic = try? XCTUnwrap(laneAlpha())

        XCTAssertNotNil(classic)
        XCTAssertNotNil(cinematic)
        XCTAssertLessThan(cinematic ?? 1, classic ?? 0,
                          "switching to the graded style left the pavement exactly as bright")
    }

    /// The toggle has to reach the *textures*, not just the few values read
    /// live — a building's neon is rasterised once and reused, so a style
    /// change that skipped the purge would move a lane's alpha and leave
    /// every building drawn in the style just switched away from.
    func testRestylingPurgesTheBakedTextures() {
        let cache = IsoTextureCache(projection: Isometric())
        VisualStyle.current = .classic
        let before = cache.rendered(for: .residential, density: 5, seed: GridPosition(x: 1, y: 1))
        XCTAssertNotNil(before, "precondition: nothing was rasterised, so nothing can go stale")

        cache.purge()
        VisualStyle.current = .cinematic
        let after = cache.rendered(for: .residential, density: 5, seed: GridPosition(x: 1, y: 1))
        XCTAssertNotNil(after)
        XCTAssertFalse(before?.texture === after?.texture,
                       "the cache handed back the texture it baked in the previous style")
    }

    func testTheControllerAndTheRendererNeverDisagree() {
        let controller = GameController(map: cityWithAStreet(), rng: SeededRNG(seed: 4))
        controller.visualStyle = .classic
        XCTAssertEqual(VisualStyle.current, .classic)
        controller.visualStyle = .cinematic
        XCTAssertEqual(VisualStyle.current, .cinematic,
                       "the published setting and the value the renderer reads have drifted apart")
    }

    func testSettingTheSameStyleAgainDoesNotAskForARedraw() {
        let controller = GameController(map: cityWithAStreet(), rng: SeededRNG(seed: 4))
        controller.visualStyle = .cinematic
        let requests = controller.restyleRequests
        controller.visualStyle = .cinematic
        XCTAssertEqual(controller.restyleRequests, requests,
                       "re-picking the style already showing rebuilt the whole map")
    }

    // MARK: - The land the city sits in

    /// The city used to be a diamond island on flat black. Nothing in the
    /// suite would notice that coming back: the city render builds its own
    /// plain `SKScene` and calls the tile renderer directly, so scene-level
    /// art is invisible to it.
    func testTheMapSitsOnLandThatExtendsWellPastIt() {
        let controller = GameController(map: cityWithAStreet(), rng: SeededRNG(seed: 4))
        let scene = GameScene(controller: controller)
        scene.size = CGSize(width: 600, height: 400)
        let view = SKView(frame: NSRect(origin: .zero, size: scene.size))
        view.presentScene(scene)
        scene.rebuildEntireGrid()

        let backdrop = scene.backdropNodeForTesting
        let map = Isometric().contentBounds(of: controller.map)
        XCTAssertNotNil(backdrop.texture, "there is no land outside the map at all")
        XCTAssertGreaterThan(backdrop.size.width, map.width * 1.5,
                             "the surrounding land stops about where the map does, "
                             + "so panning still finds the edge of the world")
        XCTAssertLessThan(backdrop.zPosition, 0,
                          "the backdrop is drawing over the city rather than behind it")
    }

    /// `rebuildEntireGrid` empties `tileLayer`, and the backdrop is a sibling
    /// precisely so it survives that — the same arrangement the sun and the
    /// placement preview already rely on.
    func testTheLandSurvivesARebuild() {
        let controller = GameController(map: cityWithAStreet(), rng: SeededRNG(seed: 4))
        let scene = GameScene(controller: controller)
        scene.size = CGSize(width: 600, height: 400)
        let view = SKView(frame: NSRect(origin: .zero, size: scene.size))
        view.presentScene(scene)
        scene.rebuildEntireGrid()
        let size = scene.backdropNodeForTesting.size
        scene.restyle()
        XCTAssertEqual(scene.backdropNodeForTesting.size, size,
                       "a rebuild took the land out from under the city")
        XCTAssertNotNil(scene.backdropNodeForTesting.texture)
    }

    // MARK: - Where a building meets the ground

    private func node(for tile: Tile) -> SKNode {
        IsoTileRenderer(projection: Isometric()).makeNode(for: tile)
    }

    private func sprite(_ name: String, on node: SKNode) -> SKSpriteNode? {
        node.children.first { $0.name == name } as? SKSpriteNode
    }

    /// Contact is a *bright* mark here, not a shadow: this ground is already
    /// near-black, so there is nothing to darken. At night a lit building
    /// spills onto the pavement hardest at its feet.
    func testABuiltLotLightsTheGroundAtItsFeet() {
        var map = CityMap(width: 8, height: 8)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 2, y: 2))
        for cell in map.footprintCells(origin: GridPosition(x: 2, y: 2), size: 2) {
            map[cell].density = 4
        }
        let built = node(for: map[GridPosition(x: 2, y: 2)])

        let contact = sprite(IsoTileRenderer.contactNodeName, on: built)
        let pool = sprite(IsoTileRenderer.glowNodeNameForTesting, on: built)
        XCTAssertNotNil(contact, "a building is not lighting the ground it stands on")
        XCTAssertNotNil(pool)

        // The property that makes it contact rather than more ambience: it
        // hugs the lot where the pool spills well past it.
        XCTAssertLessThan(contact?.size.width ?? .infinity, (pool?.size.width ?? 0) * 0.7,
                          "the contact light spills as wide as the district pool, "
                          + "so it says nothing about where this building stands")
        XCTAssertGreaterThan(contact?.zPosition ?? 0, pool?.zPosition ?? 0,
                             "the contact light is under the pool that is meant to fade out of it")
    }

    func testBareGroundAndRoadsLightNothing() {
        var map = CityMap(width: 8, height: 8)
        map[GridPosition(x: 1, y: 1)].zone = .road
        for position in [GridPosition(x: 0, y: 0), GridPosition(x: 1, y: 1)] {
            let tile = node(for: map[position])
            XCTAssertNil(sprite(IsoTileRenderer.contactNodeName, on: tile),
                         "\(map[position].zone) is lighting the ground as though a building stood on it")
        }
    }

    /// A zoned lot with nothing built on it yet lights nothing either — the
    /// spill belongs to a building, not to a claim.
    func testAnEmptyZonedLotLightsNothing() {
        var map = CityMap(width: 8, height: 8)
        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 2, y: 2))
        let tile = node(for: map[GridPosition(x: 2, y: 2)])
        XCTAssertNil(sprite(IsoTileRenderer.contactNodeName, on: tile),
                     "a surveyed lot with no building on it is already lighting the pavement")
    }

    /// A still city reads as a diorama. The light a lot throws swells and
    /// fades so the map looks inhabited — and it is the light *already there*
    /// that moves, because a new mark small enough to sit on a roof is about
    /// three screen points at normal zoom, which is under
    /// `NeonStyle.minimumDetailSize`.
    func testABuiltLotsLightBreathes() {
        var map = CityMap(width: 8, height: 8)
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 2, y: 2))
        for cell in map.footprintCells(origin: GridPosition(x: 2, y: 2), size: 2) {
            map[cell].density = 4
        }
        let contact = sprite(IsoTileRenderer.contactNodeName,
                             on: node(for: map[GridPosition(x: 2, y: 2)]))
        XCTAssertTrue(contact?.hasActions() ?? false,
                      "the city is holding perfectly still")
    }

    /// Neighbours must not pulse as one — a map blinking in lockstep is a
    /// screensaver. Two lots the same in every way except position should get
    /// different beats.
    func testNeighboursDoNotBreatheInStep() {
        var map = CityMap(width: 12, height: 8)
        for origin in [GridPosition(x: 2, y: 2), GridPosition(x: 6, y: 2)] {
            map.placeBuilding(zone: .residential, origin: origin)
            for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = 4 }
        }
        let renderer = IsoTileRenderer(projection: Isometric())
        func beat(_ position: GridPosition) -> TimeInterval {
            let node = renderer.makeNode(for: map[position])
            let light = node.children.first { $0.name == IsoTileRenderer.contactNodeName }
            return light?.action(forKey: "")?.duration ?? light?.children.first?.action(forKey: "")?.duration ?? 0
        }
        _ = beat(GridPosition(x: 2, y: 2))

        // Compared on the seeded parameters rather than by reaching into
        // SpriteKit's action tree, which is not introspectable enough to be
        // worth the reach.
        var left = BuildingRandom(seed: GridPosition(x: 2, y: 2), salt: 91)
        var right = BuildingRandom(seed: GridPosition(x: 6, y: 2), salt: 91)
        XCTAssertNotEqual(left.value(in: 0 ... 1), right.value(in: 0 ... 1),
                          "two lots draw the same beat, so a row of them pulses as one")
    }

    /// The city breathing is the city being *inhabited*, so it stops when the
    /// city does — the same side of the line as the traffic, and the opposite
    /// side from a placement flash, which answers a click and has to keep
    /// running while paused or it would never fade away.
    func testTheBreathingStopsWhenTheCityDoes() {
        XCTAssertTrue(
            GameScene.simulationDrivenNodeNamesForTesting.contains(IsoTileRenderer.contactNodeName),
            "a paused city is still breathing"
        )
    }

    // MARK: - What a block is short of

    /// The badge used to be an outlined disc with an identical bar in it, so
    /// **hue was the only thing** saying which utility was missing — and
    /// water's blue and power's icy white both sit on the neon half the city
    /// is drawn in. Two different glyphs is the fix, so the property to pin
    /// is that they are genuinely two different pictures.
    func testTheWaterAndPowerWarningsAreDifferentPictures() {
        let cache = IsoTextureCache(projection: Isometric())
        let drop = cache.utilityBadge(isWater: true)
        let bolt = cache.utilityBadge(isWater: false)
        XCTAssertNotNil(drop)
        XCTAssertNotNil(bolt)
        XCTAssertFalse(drop?.texture === bolt?.texture,
                       "'no water' and 'no power' are drawn with the same texture")
    }

    /// And big enough to read. The old disc was ten points across, which is
    /// right on `NeonStyle.minimumDetailSize` — a glyph inside it had no
    /// chance, which is most of why the mark said nothing.
    func testTheWarningIsBigEnoughToCarryASymbol() {
        let cache = IsoTextureCache(projection: Isometric())
        let badge = cache.utilityBadge(isWater: true)
        XCTAssertGreaterThan(badge?.size.width ?? 0, NeonStyle.minimumDetailSize * 2,
                             "the badge is too small for the symbol inside it to resolve")
    }

    // MARK: - The screenshot camera

    /// An App Store listing is mostly screenshots, and the capture has to
    /// actually produce an image — a menu item that quietly returns nil is
    /// the exact shape of dead control this file exists to catch.
    func testTheCityCanPhotographItself() {
        let controller = GameController(map: cityWithAStreet(), rng: SeededRNG(seed: 4))
        let scene = GameScene(controller: controller)
        scene.size = CGSize(width: 640, height: 400)
        let view = SKView(frame: NSRect(origin: .zero, size: scene.size))
        view.presentScene(scene)
        scene.rebuildEntireGrid()
        scene.refreshAll()

        let data = scene.captureImage()
        XCTAssertNotNil(data, "the city would not photograph itself")
        let image = NSBitmapImageRep(data: data ?? Data())
        XCTAssertGreaterThanOrEqual(image?.pixelsWide ?? 0, Int(scene.size.width),
                                    "the capture came back smaller than the window")
    }

    /// Screenshot mode is a mode, so it has to be one someone can leave.
    func testScreenshotModeIsOffByDefaultAndReversible() {
        let controller = GameController(map: cityWithAStreet(), rng: SeededRNG(seed: 4))
        XCTAssertFalse(controller.isScreenshotMode)
        controller.isScreenshotMode = true
        controller.isScreenshotMode = false
        XCTAssertFalse(controller.isScreenshotMode)
    }

    /// The menu cannot reach the scene, so it bumps a counter the view
    /// watches — the same shape `cityGeneration` and `restyleRequests` use.
    func testAskingForACaptureReachesTheView() {
        let controller = GameController(map: cityWithAStreet(), rng: SeededRNG(seed: 4))
        let before = controller.screenshotRequests
        controller.requestScreenshot()
        XCTAssertEqual(controller.screenshotRequests, before + 1,
                       "the capture command does not reach the view that owns the scene")
    }

    // MARK: - The ladder itself

    /// The point of the pass: pavement below buildings. Asserted on the
    /// numbers rather than on a picture, so it cannot drift back the way it
    /// did last time.
    func testPavementSitsBelowBuildingsInTheValueLadder() {
        let style = VisualStyle.cinematic
        XCTAssertLessThan(style.roadLaneAlpha, style.highwayLaneAlpha,
                          "a street and an arterial carry the same weight")
        XCTAssertLessThan(style.highwayLaneAlpha, 1.0,
                          "the brightest road is still drawing at full strength")
        XCTAssertGreaterThan(style.glowIntensity[2] / style.glowIntensity[0],
                             VisualStyle.classic.glowIntensity[2] / VisualStyle.classic.glowIntensity[0],
                             "the graded style did not widen the gap between a house and a tower")
    }

    /// `IsometricBuilding.glowLayer` clamps at `min(1, 0.85 * intensity)`, so
    /// anything above ~1.18 is headroom that does not exist. Pinned because
    /// the first attempt at this pass spent its whole increase there.
    func testTheTopOfTheLadderStaysUnderTheAlphaClamp() {
        for style in VisualStyle.allCases {
            let top = style.glowIntensity[style.glowIntensity.count - 1]
            XCTAssertLessThanOrEqual(0.85 * top, 1.0,
                                     "\(style.displayName)'s top tier is asking for brightness "
                                     + "the glow layer cannot give it")
        }
    }
}
