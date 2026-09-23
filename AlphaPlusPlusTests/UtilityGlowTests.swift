import XCTest
import AppKit
@testable import AlphaPlusPlus

/// **The Water and Power views, glowing.** Reported from play: *"I miss how
/// in the old SpriteKit version we could see the glow of the buildings for
/// power and water. Now they just light up or they don't."*
///
/// The instrument is one picture: the same half-plumbed city in both views,
/// so served and wanting are looked at side by side rather than remembered.
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

    func testRenderTheUtilityViews() throws {
        let game = try XCTUnwrap(CityPlaytest(map: Self.halfPlumbedCity()))
        let size = CGSize(width: 900, height: 600)
        var frames: [(String, NSImage)] = []
        for mode in [OverlayMode.water, .power] {
            game.look(at: mode)
            let image = try XCTUnwrap(game.picture(size: size))
            frames.append((mode.displayName, NSImage(cgImage: image, size: size)))
        }
        try MetalSpikeTests.writeGrid(frames, columns: 2, cell: size, named: "utility-glow")
    }
}
