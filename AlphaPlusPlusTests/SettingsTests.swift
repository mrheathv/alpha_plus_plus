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

    /// The setting reaches the value the renderer reads. What it does to the
    /// frame (the smoke goes, the traffic stays) is asserted on the Metal
    /// renderer itself: `MetalMotionTests.testReducedMotionTakesTheSmokeAndKeepsTheTraffic`.
    func testReduceMotionIsMirroredOntoTheRenderer() {
        let controller = GameController()
        defer { controller.reduceMotion = false; VisualStyle.reduceMotion = false }
        XCTAssertFalse(VisualStyle.reduceMotion)
        controller.reduceMotion = true
        XCTAssertTrue(VisualStyle.reduceMotion,
                      "the controller's copy moved and the renderer's did not — two copies of "
                      + "one fact, which is the mistake this project keeps paying for")
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
