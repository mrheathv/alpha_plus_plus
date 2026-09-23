import XCTest
@testable import AlphaPlusPlus

/// The keyboard half of `KeyboardControlsTests`, asked of `CityCamera`
/// rather than of a scene (M8). Pausing and releasing every key are facts
/// about the frame loop, which owns `keyboardPan`, not about the camera.
final class CityCameraKeyboardTests: XCTestCase {

    private let map = CityMap(width: 40, height: 40)

    /// Twenty frames of holding `direction`.
    private func travel(_ direction: CGVector, frames: Int = 20) -> (CityCamera, CGVector) {
        var camera = CityCamera()
        camera.centre(on: map)
        let start = camera.centre
        for _ in 0 ..< frames { camera.applyKeyboardPan(direction, elapsed: 1.0 / 60, in: map) }
        return (camera, CGVector(dx: camera.centre.x - start.x, dy: camera.centre.y - start.y))
    }

    func testHoldingAKeyMovesTheCameraThatWay() {
        let right = travel(CGVector(dx: 1, dy: 0)).1
        XCTAssertGreaterThan(right.dx, 0, "pressing right did not move the camera right")
        XCTAssertEqual(right.dy, 0, accuracy: 0.001, "pressing right moved the camera vertically")
        XCTAssertGreaterThan(travel(CGVector(dx: 0, dy: 1)).1.dy, 0, "pressing up did not move the camera up")
    }

    /// A key crosses the same share of the screen however far out you are,
    /// so the distance in the world grows with the zoom.
    func testAKeyCoversMoreGroundZoomedOut() {
        var near = CityCamera(), far = CityCamera()
        near.centre(on: map); far.centre(on: map)
        near.scale = 0.5; far.scale = 2
        let start = near.centre
        near.applyKeyboardPan(CGVector(dx: 1, dy: 0), elapsed: 0.05, in: map)
        far.applyKeyboardPan(CGVector(dx: 1, dy: 0), elapsed: 0.05, in: map)
        XCTAssertEqual((far.centre.x - start.x) / (near.centre.x - start.x), 4, accuracy: 0.01)
    }

    /// Holding a direction for a minute reaches the map's edge and stops
    /// there, rather than leaving the player staring at empty space.
    /// Compared per axis: a clamped camera lands exactly on `maxX`, which
    /// `CGRect.contains` excludes.
    func testHoldingADirectionForeverStaysOverTheMap() {
        let camera = travel(CGVector(dx: 1, dy: 1), frames: 4_000).0
        let bounds = camera.clampBounds(for: map)
        XCTAssertGreaterThanOrEqual(camera.centre.x, bounds.minX)
        XCTAssertLessThanOrEqual(camera.centre.x, bounds.maxX)
        XCTAssertGreaterThanOrEqual(camera.centre.y, bounds.minY)
        XCTAssertLessThanOrEqual(camera.centre.y, bounds.maxY)
        XCTAssertEqual(camera.centre.x, bounds.maxX, accuracy: 0.001,
                       "holding right for a minute did not reach the map's edge")
    }
}
