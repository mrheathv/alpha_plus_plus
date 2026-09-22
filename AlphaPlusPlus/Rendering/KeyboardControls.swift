import SwiftUI

/// What a key does.
///
/// Split out from `GameView` so the mapping is one table rather than a chain
/// of comparisons inside a view modifier, and so it can be tested — SwiftUI's
/// `onKeyPress` cannot be driven from a unit test, but "does W pan north"
/// is exactly the sort of thing that should not need a human at a keyboard to
/// find out.
enum KeyboardControls {

    /// A key's meaning, if it has one.
    enum Command: Equatable {
        /// Move the camera. In *camera* terms — positive `dy` is up the
        /// screen — rather than in `GameScene.pan`'s content-drag terms, which
        /// are inverted because they exist to follow a trackpad.
        case pan(dx: CGFloat, dy: CGFloat)
        /// Start or stop the simulation.
        case togglePause
    }

    /// How far the camera travels per second at the default zoom, in points.
    ///
    /// Applied per *frame* against elapsed time rather than per key event, so
    /// panning is smooth rather than stuttering on the OS key-repeat delay —
    /// the first press would move once, pause for half a second, then start
    /// repeating. Held keys are tracked and the camera integrates them, which
    /// is the difference between a camera you steer and one you nudge.
    /// **What the keys do, for the settings panel to print.**
    ///
    /// Derived here beside the mapping rather than retyped in the view, for
    /// the reason the toolbar renders `ToolCategory.entries` rather than a
    /// hand-written row: a second copy of a table is a copy that goes stale,
    /// and a keyboard reference that lies is worse than none.
    ///
    /// `KeyEquivalent` has no readable name of its own, so the strings are
    /// written once here and `keyboardReferenceCoversEveryCommand` in the
    /// tests checks the list against what `command(for:)` actually answers.
    static let reference: [(keys: String, does: String)] = [
        ("W A S D", "Pan the map"),
        ("Arrow keys", "Pan the map"),
        ("Space", "Pause and resume"),
    ]

    static let panPointsPerSecond: CGFloat = 900

    /// Both layouts, because both are muscle memory for different people and
    /// there is no reason to make anyone choose.
    static func command(for key: KeyEquivalent) -> Command? {
        switch key {
        case "w", "W", .upArrow: return .pan(dx: 0, dy: 1)
        case "s", "S", .downArrow: return .pan(dx: 0, dy: -1)
        case "a", "A", .leftArrow: return .pan(dx: -1, dy: 0)
        case "d", "D", .rightArrow: return .pan(dx: 1, dy: 0)
        case .space: return .togglePause
        default: return nil
        }
    }

    /// Does this command act once, or for as long as the key is held?
    ///
    /// Pause is a toggle: repeating it while the bar is held would flip the
    /// simulation on and off many times a second, and releasing it would leave
    /// the game in whichever state the last repeat happened to land on.
    static func isHeld(_ command: Command) -> Bool {
        if case .pan = command { return true }
        return false
    }
}
