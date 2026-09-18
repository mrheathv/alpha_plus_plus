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
    /// Bus and subway get a view each rather than sharing one.
    ///
    /// They are two networks a player plans separately — a bus line is cheap,
    /// local and drawn along streets you already have, a subway is expensive,
    /// wide-reaching and worth building before the city that justifies it —
    /// and one combined view would overlap their catchments into a single
    /// "somewhere near transit" wash that answers neither "where should the
    /// next bus stop go" nor "is the subway worth extending". Every other
    /// overlay in this list shows one network or one channel; these are no
    /// exception.
    case bus
    case subway

    var id: String { rawValue }

    /// The views where a click on the map edits something instead of placing
    /// the selected tool: Water and Power lay their buried layers, Bus and
    /// Subway add a stop to the line being drawn.
    ///
    /// A named set rather than a condition spelled out at each site. It was
    /// `overlayMode == .water || overlayMode == .power` in six places before
    /// transit arrived, and a seventh and eighth of those is how one gets
    /// forgotten — leaving a mode where clicks silently do the wrong thing,
    /// which is exactly the bug this exclusivity exists to prevent.
    static let clickEditing: Set<OverlayMode> = [.water, .power, .bus, .subway]

    /// The line a click in this view is drawing, if it is drawing one.
    var routeMode: TransitRoute.Mode? {
        switch self {
        case .bus: return .bus
        case .subway: return .subway
        default: return nil
        }
    }

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
        case .bus: return "Bus"
        case .subway: return "Subway"
        }
    }
}
