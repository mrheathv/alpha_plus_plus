import XCTest
@testable import AlphaPlusPlus

/// Zooming toward the cursor rather than the middle of the screen.
///
/// The property is simple and the reason it matters is not: a map zoomed at
/// its centre slides whatever you were looking at out from under you, so
/// getting closer to a district becomes zoom, pan, zoom, pan. Every map
/// application anchors on the pointer; this one did not.
final class CameraZoomTests: XCTestCase {

    private let map: CityMap = {
        var map = CityMap(width: 40, height: 40)
        for x in 0 ..< 40 { map[GridPosition(x: x, y: 20)].zone = .road }
        return map
    }()

    /// A camera over the middle of the map at `scale`, and a point near it,
    /// so the clamp never moves the camera for reasons of its own.
    private func camera(scale: CGFloat) -> CityCamera {
        var camera = CityCamera()
        camera.centre(on: map)
        camera.scale = scale
        return camera
    }

    private func offsetOnScreen(of anchor: CGPoint, _ camera: CityCamera) -> CGPoint {
        CGPoint(x: (anchor.x - camera.centre.x) / camera.scale, y: (anchor.y - camera.centre.y) / camera.scale)
    }

    /// **The point under the cursor stays under the cursor.** Stated as the
    /// screen offset of a world point from the camera's centre, which is what
    /// "stays put" actually means once the scale has changed underneath it.
    func testTheWorldPointUnderTheCursorDoesNotMove() {
        var camera = camera(scale: 1)
        let anchor = CGPoint(x: camera.centre.x + 220, y: camera.centre.y - 140)
        let before = offsetOnScreen(of: anchor, camera)
        camera.zoom(byMagnification: 0.25, anchoredAt: anchor, in: map)
        XCTAssertNotEqual(camera.scale, 1.0, "the pinch did not change the zoom at all")
        let after = offsetOnScreen(of: anchor, camera)
        XCTAssertEqual(after.x, before.x, accuracy: 0.001, "the anchor slid sideways")
        XCTAssertEqual(after.y, before.y, accuracy: 0.001, "the anchor slid vertically")
    }

    /// It works in both directions — pinching out has the same contract as
    /// pinching in, and an off-by-one on the ratio would only show on one.
    func testItHoldsWhenZoomingOutToo() {
        var camera = camera(scale: 1)
        let anchor = CGPoint(x: camera.centre.x - 90, y: camera.centre.y + 60)
        let before = offsetOnScreen(of: anchor, camera)
        camera.zoom(byMagnification: -0.3, anchoredAt: anchor, in: map)
        let after = offsetOnScreen(of: anchor, camera)
        XCTAssertEqual(after.x, before.x, accuracy: 0.001)
        XCTAssertEqual(after.y, before.y, accuracy: 0.001)
    }

    /// **A pinch that hits the zoom limit must not shove the camera.** The
    /// correction is computed from the *clamped* scale rather than the
    /// requested one — take it off the requested scale and a player pinching
    /// at the end of the range keeps sliding the map sideways while nothing
    /// appears to zoom, which reads as the gesture being broken.
    func testAPinchPastTheLimitDoesNotDragTheMap() {
        var camera = camera(scale: CityCamera.minimumScale)  // already as close as it goes
        let parked = camera.centre
        camera.zoom(byMagnification: 0.9, anchoredAt: CGPoint(x: parked.x + 400, y: parked.y + 300), in: map)
        XCTAssertEqual(camera.scale, CityCamera.minimumScale, accuracy: 0.0001, "the zoom limit did not hold")
        XCTAssertEqual(camera.centre.x, parked.x, accuracy: 0.001, "the camera moved anyway")
        XCTAssertEqual(camera.centre.y, parked.y, accuracy: 0.001, "the camera moved anyway")
    }

    /// And with no cursor to anchor on — the keyboard, or a test about
    /// clamping — the camera stays where it is.
    func testWithNoAnchorTheCameraStaysPut() {
        var camera = camera(scale: 1)
        let parked = camera.centre
        camera.zoom(byMagnification: 0.2, in: map)
        XCTAssertEqual(camera.centre.x, parked.x, accuracy: 0.001)
        XCTAssertEqual(camera.centre.y, parked.y, accuracy: 0.001)
    }
}
