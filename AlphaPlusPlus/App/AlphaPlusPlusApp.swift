import SwiftUI

/// Application entry point.
///
/// `@main` on a `SwiftUI.App` replaces the old `AppDelegate` + `main.swift` +
/// `MainMenu.xib` trio. We keep this file deliberately thin: it is the *shell*
/// (window, menus, app lifecycle) and knows nothing about the game beyond
/// "show a `GameView`".
@main
struct AlphaPlusPlusApp: App {

    var body: some Scene {
        WindowGroup("Alpha++") {
            GameView()
        }
        // A city builder is one document in one window for now. Dropping the
        // "New Window" menu item avoids a user accidentally opening a second,
        // unrelated city while we have no save/load story.
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
