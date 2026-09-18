import Foundation

/// Which data channel `GameScene` draws instead of normal zone colors, if
/// any. Replaces what used to be a single `isShowingLandValue` boolean now
/// that there are two overlays (land value, traffic) instead of one — an
/// enum makes "both at once" a state that can't be represented, rather than
/// one that has to be guarded against every time a second boolean would
/// have made it possible.
enum OverlayMode: String, CaseIterable, Identifiable, Hashable {
    case none
    case landValue
    case traffic
    case water
    case power
    case pollution
    /// Police coverage — and, read the other way, where crime can happen.
    /// The genre calls this the crime map for a reason: a player does not
    /// especially want to know where their stations are, they want to know
    /// which blocks are unprotected. See `IsoTileRenderer.paint`, which draws
    /// the coverage on the ground and the *risk* on the buildings.
    case police
    case fire
    /// Every block that wants attention, ranked — see `LotStatus.Severity`.
    /// The answer to "which of my four hundred lots has a problem", which
    /// until now could only be found by hovering over them one at a time.
    case problems

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "Normal"
        case .landValue: return "Land Value"
        case .traffic: return "Traffic"
        case .water: return "Water"
        case .power: return "Power"
        case .pollution: return "Pollution"
        // Named for what the player is looking for rather than for the
        // building that provides it. "Police" is a map of stations; "Crime" is
        // a map of the problem, and the problem is what you act on.
        case .police: return "Crime"
        case .fire: return "Fire Risk"
        case .problems: return "Problems"
        }
    }
}
