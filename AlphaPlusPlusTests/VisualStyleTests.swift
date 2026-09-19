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
