import SwiftUI
import SpriteKit

/// SwiftUI wrapper that hosts the SpriteKit scene.
///
/// Why SwiftUI's `SpriteView` instead of the Xcode "macOS Game" template's
/// storyboard + `GameViewController` + `.sks` file? Because all of that is
/// boilerplate we'd have to maintain and none of it is game code — the scene is
/// identical either way. This is ~10 lines with no storyboard to hand-edit.
/// If we later need AppKit-level control (custom cursors, drag-and-drop,
/// tracking areas), we swap this one file for an `NSViewRepresentable` wrapping
/// an `SKView`; `GameScene` doesn't change.
struct GameView: View {

    /// `@State` holds the scene so SwiftUI creates it **once**. A plain `let`
    /// initialized inline would rebuild the scene every time the view's `body`
    /// is re-evaluated, throwing away the city on every redraw. This is the
    /// single most common SpriteKit-in-SwiftUI mistake.
    @State private var scene = GameScene()

    var body: some View {
        SpriteView(scene: scene, preferredFramesPerSecond: 60)
            .frame(minWidth: 640, minHeight: 480)
            .ignoresSafeArea()
    }
}
