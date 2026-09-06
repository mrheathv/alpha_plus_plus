import SpriteKit

/// Graybox color palette.
///
/// This file is the *entire* answer to "what color is a residential zone?".
/// Because `ZoneType` (in Simulation/) has no idea colors exist, restyling the
/// whole game — or swapping colored squares for real sprites in Phase 3 — is a
/// change to this file and `TileRenderer`, and nothing else.
///
/// `SKColor` is SpriteKit's cross-platform alias; on macOS it is `NSColor`.
enum RenderPalette {

    /// Behind the grid. Deliberately darker than every tile color so the map
    /// reads as an object sitting on a surface.
    static let background = SKColor(srgbRed: 0.08, green: 0.09, blue: 0.10, alpha: 1.0)

    static func color(for zone: ZoneType) -> SKColor {
        switch zone {
        case .empty:
            // Unzoned land. Muted so that zoned tiles pop against it.
            return SKColor(srgbRed: 0.22, green: 0.26, blue: 0.23, alpha: 1.0)
        case .residential:
            return SKColor(srgbRed: 0.30, green: 0.69, blue: 0.35, alpha: 1.0)  // green
        case .commercial:
            return SKColor(srgbRed: 0.20, green: 0.52, blue: 0.90, alpha: 1.0)  // blue
        case .industrial:
            return SKColor(srgbRed: 0.88, green: 0.66, blue: 0.18, alpha: 1.0)  // amber
        case .road:
            return SKColor(srgbRed: 0.42, green: 0.43, blue: 0.45, alpha: 1.0)  // gray
        }
    }
}
