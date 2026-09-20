import SpriteKit
import AppKit

/// The AppKit-level control `GameView`'s original doc comment already
/// flagged as the fallback plan: "if we later need custom cursors,
/// drag-and-drop, tracking areas, we swap `SpriteView` for an
/// `NSViewRepresentable` wrapping an `SKView`." Trackpad scroll and pinch
/// turned out to be exactly that case — `SKScene` on macOS only forwards
/// mouse clicks/drags and keyboard events to itself; scroll and magnify
/// gestures never reach it no matter what you override there. This
/// subclass is a real `NSView` sitting in the actual AppKit responder
/// chain, so it genuinely receives those events, and forwards them
/// straight to the presented scene's `pan`/`zoom` methods.
final class GameSKView: SKView {
    override func scrollWheel(with event: NSEvent) {
        (scene as? GameScene)?.pan(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
    }

    override func magnify(with event: NSEvent) {
        guard let scene = scene as? GameScene else { return }
        // Anchored on the cursor, so the district you are pinching toward
        // stays under your fingers instead of sliding off the screen.
        scene.zoom(byMagnification: event.magnification,
                   anchoredAt: convert(convert(event.locationInWindow, from: nil), to: scene))
    }

    // MARK: - Placement preview tracking

    /// Same story as `scrollWheel`/`magnify` above: `mouseMoved` (with no
    /// button held) isn't in `SKScene`'s forwarded subset either, and even
    /// at this real-`NSView` level, AppKit only delivers it if something
    /// asked for it — hence the `NSTrackingArea` below, not just an
    /// override. Drives `GameScene`'s placement-preview outline, which
    /// needs to know where the cursor is *without* a click.
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        // `.inVisibleRect` keeps this in sync with the view's actual
        // visible bounds automatically (resizing, scrolling a container)
        // rather than needing this method to recompute `rect` by hand.
        let newTrackingArea = NSTrackingArea(
            rect: bounds,
            // **`.mouseEnteredAndExited` was missing**, which made
            // `mouseExited` below dead code: AppKit only delivers the events a
            // tracking area asks for, so the "cursor left the grid" cleanup
            // had never once run and the placement preview stayed stuck
            // wherever the cursor last was inside the grid. Harmless-looking
            // for an outline; not harmless for the inspector panel, which
            // would sit there describing a lot the player is no longer
            // pointing at.
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(newTrackingArea)
        trackingArea = newTrackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        (scene as? GameScene)?.updatePlacementPreview(at: event)
    }

    /// Cursor left the grid entirely (moved up onto the SwiftUI toolbar,
    /// or off the window) — hide the preview rather than leaving it
    /// stuck showing wherever the cursor last was inside the grid.
    override func mouseExited(with event: NSEvent) {
        (scene as? GameScene)?.clearPlacementPreview()
    }
}
