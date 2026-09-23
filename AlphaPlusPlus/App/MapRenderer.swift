import Foundation

/// Which renderer draws the map — see the Metal migration plan.
///
/// A switch that exists for the length of the migration, the way
/// `VisualStyle` exists to compare two looks: both renderers stay playable
/// until Metal can do everything SpriteKit does, so a phase that goes wrong
/// costs nothing and the two can be compared mid-session. It goes away at the
/// migration's last phase, when SpriteKit's map code is deleted.
enum MapRenderer: String, CaseIterable, Identifiable {
    case classic
    case metal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .metal: return "Metal (beta)"
        }
    }

    var summary: String {
        switch self {
        case .classic: return "The SpriteKit renderer the game has always used. Everything works."
        case .metal: return "The new renderer: real light, wet-street reflections, sharp at any zoom. "
            + "Still being built: cars, overlays and effects are missing for now."
        }
    }
}
