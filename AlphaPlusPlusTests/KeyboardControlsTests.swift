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

    // MARK: - What the scene does with it

    private func makeScene() -> GameScene {
        let controller = GameController(
            map: PlaytestHarness.buildCity(PlaytestHarness.CitySpec(size: 40)),
            rng: SeededRNG(seed: 1),
            peakPopulation: Unlocks.everythingUnlocked
        )
        let scene = GameScene(controller: controller)
        let view = SKView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.presentScene(scene)
        scene.rebuildEntireGrid()
        return scene
    }

    /// How far the camera moves over `frames` frames of holding a direction.
    ///
    /// Counted in frames rather than in seconds on purpose. `applyKeyboardPan`
    /// clamps each frame's elapsed time to 0.1s — so that a stalled frame
    /// cannot teleport the camera across the map — which means a helper that
    /// took "60 seconds" and delivered it as twenty frames would actually pan
    /// for two. It quietly did, and the test built on it failed for reasons
    /// that had nothing to do with the code under test.
    private func travel(_ scene: GameScene, pan: CGVector, frames: Int = 20) -> CGVector {
        let step = 1.0 / 60
        scene.keyboardPan = .zero
        scene.update(clock)      // establishes the frame clock
        clock += step
        let start = scene.cameraPositionForTesting
        scene.keyboardPan = pan
        for _ in 0 ..< frames {
            scene.update(clock)
            clock += step
        }
        let end = scene.cameraPositionForTesting
        return CGVector(dx: end.x - start.x, dy: end.y - start.y)
    }

    /// Scene time, advanced across a whole test rather than restarted per
    /// call: `update` reads absolute times and a helper that reset to zero
    /// would hand it a negative elapsed interval.
    private var clock: TimeInterval = 0

    func testHoldingAKeyMovesTheCameraThatWay() {
        let scene = makeScene()
        let right = travel(scene, pan: CGVector(dx: 1, dy: 0))
        XCTAssertGreaterThan(right.dx, 0, "pressing right did not move the camera right")
        XCTAssertEqual(right.dy, 0, accuracy: 0.001, "pressing right moved the camera vertically")

        let up = travel(scene, pan: CGVector(dx: 0, dy: 1))
        XCTAssertGreaterThan(up.dy, 0, "pressing up did not move the camera up")
    }

    /// **Diagonals must not be 1.41x faster than straight lines.** Adding two
    /// axes together and not normalising is the oldest bug in this particular
    /// genre of code, and it is invisible until someone notices the map slides
    /// faster when they hold two keys.
    func testTravellingDiagonallyIsNoFasterThanTravellingStraight() {
        let scene = makeScene()
        let straight = travel(scene, pan: CGVector(dx: 1, dy: 0))
        let diagonal = travel(scene, pan: CGVector(dx: 1, dy: 1))

        let straightDistance = (straight.dx * straight.dx + straight.dy * straight.dy).squareRoot()
        let diagonalDistance = (diagonal.dx * diagonal.dx + diagonal.dy * diagonal.dy).squareRoot()
        XCTAssertEqual(diagonalDistance, straightDistance, accuracy: straightDistance * 0.02,
                       "holding two keys covers more ground than holding one")
    }

    /// The camera keeps moving when the city does not. Looking around a
    /// stopped city is most of what pausing is for, so panning cannot share
    /// the simulation's clock.
    func testPanningWorksWhilePaused() {
        let scene = makeScene()
        scene.controllerForTesting.isRunning = false
        let moved = travel(scene, pan: CGVector(dx: 1, dy: 0))
        XCTAssertGreaterThan(moved.dx, 0, "the camera is frozen while the simulation is paused")
    }

    func testReleasingEveryKeyStopsTheCamera() {
        let scene = makeScene()
        _ = travel(scene, pan: CGVector(dx: 1, dy: 0))
        scene.keyboardPan = .zero
        let before = scene.cameraPositionForTesting
        for _ in 0 ..< 10 {
            scene.update(clock)
            clock += 1.0 / 60
        }
        XCTAssertEqual(scene.cameraPositionForTesting.x, before.x, accuracy: 0.001,
                       "the camera kept sliding after every key was released")
    }

    /// Panning is clamped to the map like every other camera move — holding a
    /// direction forever must not leave the player staring at empty space.
    func testHoldingADirectionForeverStaysOverTheMap() {
        let scene = makeScene()
        _ = travel(scene, pan: CGVector(dx: 1, dy: 1), frames: 4_000)
        let position = scene.cameraPositionForTesting
        XCTAssertTrue(position.x.isFinite && position.y.isFinite)
        // The clamp is `GameScene`'s own; this checks it was consulted at all,
        // which it would not be if keyboard panning wrote the camera directly.
        //
        // Compared per axis rather than with `CGRect.contains`, which excludes
        // the `maxX`/`maxY` edges — and a clamped camera lands *exactly* on
        // them, so `contains` reports a correctly clamped camera as out of
        // bounds.
        let bounds = scene.cameraClampBoundsForTesting
        XCTAssertGreaterThanOrEqual(position.x, bounds.minX)
        XCTAssertLessThanOrEqual(position.x, bounds.maxX)
        XCTAssertGreaterThanOrEqual(position.y, bounds.minY)
        XCTAssertLessThanOrEqual(position.y, bounds.maxY)
        XCTAssertEqual(position.x, bounds.maxX, accuracy: 0.001,
                       "holding right for a minute did not reach the map's edge")
    }
}
