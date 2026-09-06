import SwiftUI
import SpriteKit

/// Hosts a `GameScene` in SwiftUI via `GameSKView`, instead of SwiftUI's
/// built-in `SpriteView`. The one thing this buys over `SpriteView` is that
/// `GameSKView` is a real, subclassable `NSView` — see its doc comment for
/// why that's required (trackpad scroll/pinch never reach an `SKScene`
/// directly, no matter how it's hosted).
struct GameSpriteView: NSViewRepresentable {
    let scene: GameScene

    func makeNSView(context: Context) -> GameSKView {
        let view = GameSKView()
        view.presentScene(scene)
        view.preferredFramesPerSecond = 60
        return view
    }

    /// Nothing to sync: `scene` is created once by `GameView` and never
    /// swapped out, so there's no "new scene" case to detect here — only
    /// `makeNSView` ever needs to touch it.
    func updateNSView(_ nsView: GameSKView, context: Context) {}
}
