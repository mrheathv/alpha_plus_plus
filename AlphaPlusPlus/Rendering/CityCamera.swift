import CoreGraphics
import Foundation

/// **The camera, as a value** (M8). Where the view is looking and how far in,
/// with the pan, zoom, clamp and keyboard maths that lived on `GameScene`'s
/// `SKCameraNode`, and the one thing a view needs to turn a click into a tile.
///
/// Renderer-neutral on purpose: the Metal view reads it every frame, the
/// input controller moves it, and a test can drive it with no view at all.
/// The coordinates are the ones `Isometric` projects into, which is what
/// `GameScene`'s scene space always was: `centre` is a point in that space and
/// `scale` is world points per view point, so a *smaller* scale is closer in.
struct CityCamera {
    var centre: CGPoint = .zero
    var scale: CGFloat = 1

    /// The closest the camera goes. The Metal renderer draws real geometry at
    /// any zoom, so it comes about two and a half times closer than
    /// SpriteKit's cached textures could, near street level.
    static let minimumScale: CGFloat = 0.2
    static let maximumScale: CGFloat = 3.0

    let projection: Isometric

    init(projection: Isometric = Isometric()) {
        self.projection = projection
    }

    // MARK: - Picking

    /// The world point under `viewPoint`, in a view `viewSize` points across.
    /// View points are AppKit's: origin bottom-left, y up, the same way up as
    /// the world, so there is no flip.
    func worldPoint(forViewPoint viewPoint: CGPoint, viewSize: CGSize) -> CGPoint {
        CGPoint(x: centre.x + (viewPoint.x - viewSize.width / 2) * scale,
                y: centre.y + (viewPoint.y - viewSize.height / 2) * scale)
    }

    /// The tile under `viewPoint`, picked against the ground plane as it
    /// always has been (a point over a tower's upper floors is ground behind
    /// it), or `nil` off the map.
    func tile(atViewPoint viewPoint: CGPoint, viewSize: CGSize, in map: CityMap) -> GridPosition? {
        projection.position(for: worldPoint(forViewPoint: viewPoint, viewSize: viewSize), in: map)
    }

    // MARK: - Moving

    /// Pans by a scroll gesture's delta (`NSEvent.scrollingDeltaX/Y`). The
    /// camera is the viewport, so it moves against the gesture and the map
    /// follows the fingers, as content does everywhere else on macOS.
    mutating func pan(deltaX: CGFloat, deltaY: CGFloat, in map: CityMap) {
        centre.x -= deltaX
        centre.y += deltaY
        clamp(to: map)
    }

    /// Zooms by one pinch delta (`NSEvent.magnification`, the change since
    /// the last event), keeping `anchor` (a world point, normally what is
    /// under the cursor) where it is on screen. The anchor is held against
    /// the *clamped* scale, or a pinch at the zoom limit would shove the
    /// camera sideways while nothing appeared to zoom.
    mutating func zoom(byMagnification magnification: CGFloat, anchoredAt anchor: CGPoint? = nil,
                       in map: CityMap) {
        let before = scale
        scale = min(max(before * (1 - magnification), Self.minimumScale), Self.maximumScale)
        if let anchor, before > 0 {
            let ratio = scale / before
            centre = CGPoint(x: anchor.x - (anchor.x - centre.x) * ratio,
                             y: anchor.y - (anchor.y - centre.y) * ratio)
        }
        clamp(to: map)
    }

    /// One frame of keyboard panning. `direction` is `GameScene.keyboardPan`'s
    /// velocity (dy positive is up the screen); it is normalised, so a
    /// diagonal is not 1.41 times faster, and scaled by the zoom, so a key
    /// crosses the same fraction of the screen however far out you are.
    mutating func applyKeyboardPan(_ direction: CGVector, elapsed: TimeInterval, in map: CityMap) {
        guard direction != .zero else { return }
        let distance = KeyboardControls.panPointsPerSecond * CGFloat(elapsed) * scale
        let length = (direction.dx * direction.dx + direction.dy * direction.dy).squareRoot()
        centre.x += direction.dx / length * distance
        centre.y += direction.dy / length * distance
        clamp(to: map)
    }

    /// Looks at the middle of the map. Says nothing about zoom.
    mutating func centre(on map: CityMap) {
        centre = projection.centerPoint(of: map)
    }

    /// The rectangle the centre is kept inside: the ground's bounds, not
    /// everything drawn on it, with two tiles of margin. Generous on purpose;
    /// the point is keeping the map findable, not fencing the player in.
    func clampBounds(for map: CityMap) -> CGRect {
        projection.contentBounds(of: map).insetBy(dx: -projection.tileWidth * 2,
                                                  dy: -projection.tileHeight * 2)
    }

    mutating func clamp(to map: CityMap) {
        let bounds = clampBounds(for: map)
        centre.x = min(max(centre.x, bounds.minX), bounds.maxX)
        centre.y = min(max(centre.y, bounds.minY), bounds.maxY)
    }
}
