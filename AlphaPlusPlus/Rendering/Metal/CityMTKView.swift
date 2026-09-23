import AppKit
import MetalKit

/// **What the Metal view needs from the input layer** (M8). `MapInteraction`
/// conforms: the view turns AppKit events into tiles and hands them over, and
/// never decides what a click means.
@MainActor
protocol MapInput: AnyObject {
    /// Where the view is looking. Moved by scroll, pinch and the keyboard.
    var camera: CityCamera { get set }
    /// The keyboard's steering velocity (dy positive is up the screen),
    /// integrated by the frame loop; zero when nothing is held.
    var keyboardPan: CGVector { get set }
    /// The tile under the pointer, or `nil` when it left the map.
    func pointerMoved(to tile: GridPosition?)
    /// A left-button stroke: pressed, dragged across tiles, let go.
    func press(at tile: GridPosition?)
    func drag(to tile: GridPosition?)
    func release()
    /// A right-button stroke, which bulldozes.
    func rightPress(at tile: GridPosition?)
    func rightDrag(to tile: GridPosition?)
}

/// **The map view, and the one that takes the input** (M8). An `MTKView` in
/// the real AppKit responder chain, so it receives the scroll and pinch
/// gestures `SKScene` never forwarded, and the mouse, through a tracking area
/// that asks for moves and for leaving (`GameSKView` once lost the second and
/// left the cursor stuck where the pointer last was).
final class CityMTKView: MTKView {
    weak var input: MapInput?
    /// The city the input is picking tiles in.
    var map: () -> CityMap? = { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The tile under an event, picked against the ground plane.
    private func tile(of event: NSEvent) -> GridPosition? {
        guard let input, let map = map() else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        return input.camera.tile(atViewPoint: point, viewSize: bounds.size, in: map)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let input, let map = map() else { return }
        input.camera.pan(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, in: map)
    }

    override func magnify(with event: NSEvent) {
        guard let input, let map = map() else { return }
        // Anchored on the cursor, so the district you are pinching toward
        // stays under your fingers.
        let anchor = input.camera.worldPoint(forViewPoint: convert(event.locationInWindow, from: nil),
                                             viewSize: bounds.size)
        input.camera.zoom(byMagnification: event.magnification, anchoredAt: anchor, in: map)
    }

    override func mouseDown(with event: NSEvent) { input?.press(at: tile(of: event)) }
    override func mouseDragged(with event: NSEvent) { input?.drag(to: tile(of: event)) }
    override func mouseUp(with event: NSEvent) { input?.release() }
    override func rightMouseDown(with event: NSEvent) { input?.rightPress(at: tile(of: event)) }
    override func rightMouseDragged(with event: NSEvent) { input?.rightDrag(to: tile(of: event)) }
    override func mouseMoved(with event: NSEvent) { input?.pointerMoved(to: tile(of: event)) }
    override func mouseExited(with event: NSEvent) { input?.pointerMoved(to: nil) }

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }
}
