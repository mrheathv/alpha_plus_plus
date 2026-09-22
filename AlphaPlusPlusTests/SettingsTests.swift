import SpriteKit
import SwiftUI
import XCTest
@testable import AlphaPlusPlus

/// **A setting that changes nothing is the failure this project has shipped
/// twice.**
///
/// `SKAction.colorize` went dead on a plain node and three feedback flashes
/// kept compiling and stopped doing anything; an overlay tint cast to a type
/// the ground had stopped being, and every heatmap in the game painted no data
/// for months. Neither failed a test, because what was asserted was that the
/// call had been made. So a new control gets a test that asserts the *result*.
@MainActor
final class SettingsTests: XCTestCase {

    private func industrialCity() -> CityMap {
        var map = CityMap(width: 14, height: 14)
        for x in 0 ..< 14 { map[GridPosition(x: x, y: 6)].zone = .road }
        map.placeBuilding(zone: .industrial, origin: GridPosition(x: 4, y: 7))
        for cell in map.footprintCells(origin: GridPosition(x: 4, y: 7), size: 2) {
            map[cell].density = 5
        }
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 8, y: 7))
        for cell in map.footprintCells(origin: GridPosition(x: 8, y: 7), size: 2) {
            map[cell].density = 5
        }
        return map
    }

    private func scene(_ controller: GameController) -> GameScene {
        let scene = GameScene(controller: controller)
        scene.size = CGSize(width: 800, height: 600)
        let view = SKView(frame: NSRect(origin: .zero, size: scene.size))
        view.presentScene(scene)
        scene.rebuildEntireGrid()
        scene.refreshAll()
        return scene
    }

    private func marks(_ scene: GameScene) -> (smoke: Int, pulsing: Int) {
        var smoke = 0, pulsing = 0
        for node in scene.tileNodesForTesting.values {
            for child in node.children {
                if child.name == IsoTileRenderer.smokeNodeName { smoke += 1 }
                if child.name == IsoTileRenderer.contactNodeName, child.hasActions() {
                    pulsing += 1
                }
            }
        }
        return (smoke, pulsing)
    }

    /// **Ambient motion goes; the city's own reporting stays.**
    ///
    /// Both halves are asserted, and the second is the one that matters: a
    /// setting that quietly stopped showing where the traffic is, or where the
    /// fire is, would be a worse accessibility failure than the one it set out
    /// to fix.
    func testReduceMotionStopsTheAtmosphereAndNotTheInformation() {
        let controller = GameController(map: industrialCity(), rng: SeededRNG(seed: 5))
        defer { controller.reduceMotion = false }

        let before = marks(scene(controller))
        XCTAssertGreaterThan(before.smoke, 0, "the fixture has no smoking factory in it, so it "
                             + "cannot show whether the setting turns one off")
        XCTAssertGreaterThan(before.pulsing, 0, "nothing in the fixture is pulsing")

        controller.reduceMotion = true
        let after = marks(scene(controller))
        XCTAssertEqual(after.smoke, 0, "a chimney is still smoking with motion reduced")
        XCTAssertEqual(after.pulsing, 0, "a building's light is still breathing")
    }

    /// The other side of the same line, checked where it is actually decided.
    func testReduceMotionIsMirroredOntoTheRendererExactlyOnce() {
        let controller = GameController()
        defer { controller.reduceMotion = false; VisualStyle.reduceMotion = false }
        XCTAssertFalse(VisualStyle.reduceMotion)
        let restyles = controller.restyleRequests
        controller.reduceMotion = true
        XCTAssertTrue(VisualStyle.reduceMotion,
                      "the controller's copy moved and the renderer's did not — two copies of "
                      + "one fact, which is the mistake this project keeps paying for")
        XCTAssertEqual(controller.restyleRequests, restyles + 1,
                       "nothing asked the scene to redraw, so the change lands on nothing "
                       + "already on screen")
        controller.reduceMotion = true
        XCTAssertEqual(controller.restyleRequests, restyles + 1,
                       "setting it to the value it already had redrew the whole city")
    }

    /// The printed keyboard reference has to be the mapping, not a second copy
    /// of it that drifts. `KeyboardControls.reference` is written by hand
    /// because `KeyEquivalent` has no readable name; this checks every command
    /// the mapping can produce is named in it.
    func testTheKeyboardReferenceCoversEveryCommand() {
        let named = KeyboardControls.reference.map(\.does).joined(separator: " ").lowercased()
        var seen: Set<String> = []
        for key in ["w", "a", "s", "d", " "] as [KeyEquivalent] {
            guard let command = KeyboardControls.command(for: key) else { continue }
            switch command {
            case .pan: seen.insert("pan")
            case .togglePause: seen.insert("pause")
            }
        }
        XCTAssertEqual(seen, ["pan", "pause"], "the mapping grew a command this test does not "
                       + "know about")
        XCTAssertTrue(named.contains("pan"), "the reference never mentions panning")
        XCTAssertTrue(named.contains("pause"), "the reference never mentions pausing")
    }
}
