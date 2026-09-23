import XCTest
import SpriteKit
@testable import AlphaPlusPlus

/// **The Water and Power views, glowing.** Reported from play: *"I miss how
/// in the old SpriteKit version we could see the glow of the buildings for
/// power and water. Now they just light up or they don't."*
///
/// The instrument is one picture: the same half-plumbed city in both views,
/// SpriteKit beside Metal, so the difference is looked at rather than
/// remembered.
@MainActor
final class UtilityGlowTests: XCTestCase {

    /// A grown 32×32 city whose right half has lost its mains and lines, so
    /// both answers — served, and wanting — are on screen at once. A picture
    /// in which only one state occurs cannot show whether they read apart.
    static func halfPlumbedCity() -> CityMap {
        let controller = GameController(map: PlaytestHarness.buildCity(.init(size: 32)),
                                         rng: SeededRNG(seed: 3),
                                         peakPopulation: Unlocks.everythingUnlocked)
        for _ in 0 ..< 160 { controller.advanceSimulation() }
        var map = controller.map
        for position in map.tiles.map(\.position) where position.x >= 17 {
            map[position].hasPipe = false
            map[position].hasPowerLine = false
        }
        let settled = GameController(map: map, rng: SeededRNG(seed: 3),
                                     peakPopulation: Unlocks.everythingUnlocked)
        settled.recomputeUtilitySupply()
        return settled.map
    }

    func testRenderTheUtilityViewsBothWays() throws {
        let map = Self.halfPlumbedCity()
        let size = CGSize(width: 900, height: 600)
        let game = ScenePlaytest(map: map, size: size)
        let renderer = try XCTUnwrap(MetalCityRenderer())
        var frames: [(String, NSImage)] = []
        for mode in [OverlayMode.water, .power] {
            game.look(at: mode)
            game.frame()
            game.frame()
            let texture = try XCTUnwrap(game.scene.view?.texture(from: game.scene,
                                                                crop: CGRect(origin: .zero, size: size)))
            frames.append(("SpriteKit · \(mode.displayName)", NSImage(cgImage: texture.cgImage(), size: size)))
            renderer.overlayMode = mode
            let camera = MetalCityRenderer.Camera(centre: game.scene.cameraCentre,
                                                  scale: game.scene.cameraScale, size: size)
            let frame = try XCTUnwrap(renderer.render(game.controller.map, camera: camera, wetness: 0, time: 1))
            frames.append(("Metal · \(mode.displayName)", NSImage(cgImage: frame.image, size: size)))
        }
        try MetalSpikeTests.writeGrid(frames, columns: 2, cell: size, named: "utility-glow")
    }
}
