import XCTest
@testable import AlphaPlusPlus

/// **The camera as a value** (M8). The maths `GameScene`'s camera node
/// carried, pinned where no view is needed to check it.
final class CityCameraTests: XCTestCase {

    private let map = CityMap(width: 32, height: 32)

    /// The middle of the view picks the tile under the camera's centre.
    func testTheViewsCentrePicksTheTileUnderTheCamera() throws {
        var camera = CityCamera()
        camera.centre(on: map)
        let size = CGSize(width: 1200, height: 800)
        let picked = try XCTUnwrap(camera.tile(atViewPoint: CGPoint(x: 600, y: 400), viewSize: size, in: map))
        XCTAssertEqual(picked, camera.projection.position(for: camera.centre, in: map))
    }

    /// A view point one view-point right of centre is `scale` world points
    /// right of the camera, and y runs the same way up in both.
    func testViewPointsScaleIntoTheWorldWithoutAFlip() {
        var camera = CityCamera()
        camera.centre = CGPoint(x: 100, y: 50)
        camera.scale = 2
        let world = camera.worldPoint(forViewPoint: CGPoint(x: 610, y: 420),
                                      viewSize: CGSize(width: 1200, height: 800))
        XCTAssertEqual(world.x, 120, accuracy: 1e-9)
        XCTAssertEqual(world.y, 90, accuracy: 1e-9)
    }

    /// Zooming anchored at a point keeps that point where it was on screen.
    func testAnAnchoredZoomKeepsTheAnchorStill() {
        var camera = CityCamera()
        camera.centre(on: map)
        let size = CGSize(width: 1200, height: 800)
        let cursor = CGPoint(x: 700, y: 450)
        let anchor = camera.worldPoint(forViewPoint: cursor, viewSize: size)
        camera.zoom(byMagnification: 0.3, anchoredAt: anchor, in: map)
        let after = camera.worldPoint(forViewPoint: cursor, viewSize: size)
        XCTAssertEqual(after.x, anchor.x, accuracy: 1e-6)
        XCTAssertEqual(after.y, anchor.y, accuracy: 1e-6)
    }

    func testZoomStopsAtItsLimitsWithoutSlidingTheCamera() {
        var camera = CityCamera()
        camera.centre(on: map)
        camera.zoom(byMagnification: 0.99, in: map)
        XCTAssertEqual(camera.scale, CityCamera.minimumScale)
        let centre = camera.centre
        camera.zoom(byMagnification: 0.5, anchoredAt: CGPoint(x: centre.x + 300, y: centre.y), in: map)
        XCTAssertEqual(camera.scale, CityCamera.minimumScale)
        XCTAssertEqual(camera.centre, centre, "a pinch at the limit shoved the camera sideways")
        camera.zoom(byMagnification: -100, in: map)
        XCTAssertEqual(camera.scale, CityCamera.maximumScale)
    }

    func testPanningStaysOverTheMap() {
        var camera = CityCamera()
        camera.centre(on: map)
        camera.pan(deltaX: 1e6, deltaY: -1e6, in: map)
        XCTAssertTrue(camera.clampBounds(for: map).insetBy(dx: -0.001, dy: -0.001).contains(camera.centre))
    }

    func testKeyboardDiagonalsAreNotFaster() {
        var straight = CityCamera(), diagonal = CityCamera()
        straight.centre(on: map); diagonal.centre(on: map)
        let start = straight.centre
        straight.applyKeyboardPan(CGVector(dx: 1, dy: 0), elapsed: 0.1, in: map)
        diagonal.applyKeyboardPan(CGVector(dx: 1, dy: 1), elapsed: 0.1, in: map)
        func travelled(_ c: CityCamera) -> CGFloat { hypot(c.centre.x - start.x, c.centre.y - start.y) }
        XCTAssertEqual(travelled(straight), travelled(diagonal), accuracy: 1e-6)
    }
}
