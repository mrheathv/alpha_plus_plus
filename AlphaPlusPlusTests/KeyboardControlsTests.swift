import XCTest
import SpriteKit
import SwiftUI
@testable import AlphaPlusPlus

/// Keyboard navigation: WASD and the arrow keys steer the camera, space
/// pauses.
@MainActor
final class KeyboardControlsTests: XCTestCase {

    // MARK: - The mapping

    func testBothLayoutsSteerTheSameWay() {
        for (up, down, left, right) in [(KeyEquivalent("w"), KeyEquivalent("s"),
                                         KeyEquivalent("a"), KeyEquivalent("d")),
                                        (.upArrow, .downArrow, .leftArrow, .rightArrow)] {
            XCTAssertEqual(KeyboardControls.command(for: up), .pan(dx: 0, dy: 1))
            XCTAssertEqual(KeyboardControls.command(for: down), .pan(dx: 0, dy: -1))
            XCTAssertEqual(KeyboardControls.command(for: left), .pan(dx: -1, dy: 0))
            XCTAssertEqual(KeyboardControls.command(for: right), .pan(dx: 1, dy: 0))
        }
    }

    /// Caps lock, or a held shift, must not silently stop the camera.
    func testShiftedLettersStillSteer() {
        XCTAssertEqual(KeyboardControls.command(for: "W"), KeyboardControls.command(for: "w"))
        XCTAssertEqual(KeyboardControls.command(for: "D"), KeyboardControls.command(for: "d"))
    }

    func testSpacePauses() {
        XCTAssertEqual(KeyboardControls.command(for: .space), .togglePause)
    }

    func testUnmappedKeysAreLeftAlone() {
        for key in [KeyEquivalent("q"), "1", .tab, .escape, .return] {
            XCTAssertNil(KeyboardControls.command(for: key), "\(key.character) was claimed")
        }
    }

    /// A toggle fires once; a direction lasts as long as the key is down.
    /// Getting this backwards would flip the simulation on and off many times
    /// a second while the space bar was held.
    func testOnlyDirectionsRepeatWhileHeld() {
        XCTAssertTrue(KeyboardControls.isHeld(.pan(dx: 1, dy: 0)))
        XCTAssertFalse(KeyboardControls.isHeld(.togglePause))
    }
}
