import SwiftUI
import SpriteKit

/// Bridges `RenderPalette`'s SpriteKit-side neon colors into SwiftUI
/// `Color` for the toolbar chrome around the game view — one palette for
/// both layers, so a zone's tool button glows the exact hue its own
/// tiles and icons do, not a second hand-picked color that could drift
/// from it. `SKColor` is `NSColor` on macOS, so this is a direct bridge,
/// not a reinterpretation.
///
/// Before this, `GameView`'s toolbar was the one piece of this project
/// Phase 3's retrowave pass never reached — every button, picker, and
/// stepper still wore plain default SwiftUI/AppKit chrome around a fully
/// neon game world, a light OS panel bolted onto a dark city.
enum RetroUITheme {
    /// A tool's own accent — the same color its zone's tiles and icons
    /// already glow (`RenderPalette.fullColor(for:)`), so the toolbar
    /// button and the thing it places always agree by construction.
    static func accent(for zone: ZoneType) -> Color {
        // `.empty` is the one zone whose tile colour is wrong as a button
        // accent. On the map it is unzoned land — a near-black "night" the
        // neon sits on — which as a toolbar accent renders the Bulldoze
        // button so dim it reads as disabled, next to a row of tools that
        // genuinely can be. It is an *action*, not a patch of ground, so it
        // gets an action's colour: the same red the game already uses to mean
        // "this destroys or refuses something."
        guard zone != .empty else { return .red }
        return Color(nsColor: RenderPalette.fullColor(for: zone))
    }

    /// The toolbar's own background — the same "night" `RenderPalette.background`
    /// paints behind the map itself, so the chrome and the city read as
    /// one continuous world instead of two different apps stacked on
    /// top of each other.
    static let background = Color(nsColor: RenderPalette.background)

    /// A second, slightly lighter panel tone for rows that want to sit
    /// visually "above" the base toolbar background (the stat tiles),
    /// without introducing a whole second palette to keep in sync.
    static let panel = Color(nsColor: RenderPalette.fullColor(for: .empty))

    /// Primary interactive accent for controls that aren't tied to a
    /// specific zone (Play/Pause, Advance, Reset, segmented pickers) —
    /// the same cyan a highway's own glow uses.
    static let primaryAccent = Color(nsColor: RenderPalette.networkAccentColor(for: .highway))

    /// A secondary accent for controls that want *some* neon presence
    /// without competing with `primaryAccent` — the same magenta an
    /// ordinary road's lane line glows.
    static let secondaryAccent = Color(nsColor: RenderPalette.networkAccentColor(for: .road))

    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color(nsColor: RenderPalette.networkAccentColor(for: .highway)).opacity(0.5)
}
