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
        (scene as? GameScene)?.zoom(byMagnification: event.magnification)
    }
}
