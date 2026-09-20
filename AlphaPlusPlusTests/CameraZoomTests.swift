import XCTest
@testable import AlphaPlusPlus

/// Zooming toward the cursor rather than the middle of the screen.
///
/// The property is simple and the reason it matters is not: a map zoomed at
/// its centre slides whatever you were looking at out from under you, so
/// getting closer to a district becomes zoom, pan, zoom, pan. Every map
/// application anchors on the pointer; this one did not.
@MainActor
final class CameraZoomTests: XCTestCase {

    private func scene() -> GameScene {
        var map = CityMap(width: 40, height: 40)
        for x in 0 ..< 40 { map[GridPosition(x: x, y: 20)].zone = .road }
        let game = ScenePlaytest(map: map)
        return game.scene
    }

    /// **The point under the cursor stays under the cursor.** Stated as the
    /// screen offset of a world point from the camera's centre, which is what
    /// "stays put" actually means once the scale has changed underneath it.
    func testTheWorldPointUnderTheCursorDoesNotMove() throws {
        let scene = scene()
        let camera = try XCTUnwrap(scene.camera)
        camera.setScale(1.0)
        camera.position = .zero

        let anchor = CGPoint(x: 220, y: -140)
        func offsetOnScreen() -> CGPoint {
            CGPoint(x: (anchor.x - camera.position.x) / camera.xScale,
                    y: (anchor.y - camera.position.y) / camera.yScale)
        }
        let before = offsetOnScreen()

        scene.zoom(byMagnification: 0.25, anchoredAt: anchor)
        XCTAssertNotEqual(camera.xScale, 1.0, "the pinch did not change the zoom at all")

        let after = offsetOnScreen()
        XCTAssertEqual(after.x, before.x, accuracy: 0.001, "the anchor slid sideways")
        XCTAssertEqual(after.y, before.y, accuracy: 0.001, "the anchor slid vertically")
    }

    /// It works in both directions — pinching out has the same contract as
    /// pinching in, and an off-by-one on the ratio would only show on one.
    func testItHoldsWhenZoomingOutToo() throws {
        let scene = scene()
        let camera = try XCTUnwrap(scene.camera)
        camera.setScale(1.0)
        camera.position = .zero

        let anchor = CGPoint(x: -90, y: 60)
        let before = CGPoint(x: (anchor.x - camera.position.x) / camera.xScale,
                             y: (anchor.y - camera.position.y) / camera.yScale)
        scene.zoom(byMagnification: -0.3, anchoredAt: anchor)
        let after = CGPoint(x: (anchor.x - camera.position.x) / camera.xScale,
                            y: (anchor.y - camera.position.y) / camera.yScale)
        XCTAssertEqual(after.x, before.x, accuracy: 0.001)
        XCTAssertEqual(after.y, before.y, accuracy: 0.001)
    }

    /// **A pinch that hits the zoom limit must not shove the camera.** The
    /// correction is computed from the *clamped* scale rather than the
    /// requested one — take it off the requested scale and a player pinching
    /// at the end of the range keeps sliding the map sideways while nothing
    /// appears to zoom, which reads as the gesture being broken.
    func testAPinchPastTheLimitDoesNotDragTheMap() throws {
        let scene = scene()
        let camera = try XCTUnwrap(scene.camera)
        camera.setScale(0.5) // already at the closest the camera goes
        camera.position = .zero
        let parked = camera.position

        scene.zoom(byMagnification: 0.9, anchoredAt: CGPoint(x: 400, y: 300))

        XCTAssertEqual(camera.xScale, 0.5, accuracy: 0.0001, "the zoom limit did not hold")
        XCTAssertEqual(camera.position.x, parked.x, accuracy: 0.001, "the camera moved anyway")
        XCTAssertEqual(camera.position.y, parked.y, accuracy: 0.001, "the camera moved anyway")
    }

    /// And with no cursor to anchor on — the keyboard, or a test about
    /// clamping — it behaves exactly as it did before.
    func testWithNoAnchorTheCameraStaysPut() throws {
        let scene = scene()
        let camera = try XCTUnwrap(scene.camera)
        camera.setScale(1.0)
        camera.position = CGPoint(x: 12, y: -8)

        scene.zoom(byMagnification: 0.2)
        XCTAssertEqual(camera.position.x, 12, accuracy: 0.001)
        XCTAssertEqual(camera.position.y, -8, accuracy: 0.001)
    }
}
