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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "Normal"
        case .landValue: return "Land Value"
        case .traffic: return "Traffic"
        case .water: return "Water"
        case .power: return "Power"
        case .pollution: return "Pollution"
        }
    }
}
