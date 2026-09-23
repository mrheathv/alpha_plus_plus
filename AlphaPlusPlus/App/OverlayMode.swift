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
    case tram
    case subway
    case rail
    /// Which of the region the city owns, and which parcels are for sale.
    /// Clicking a parcel here buys it — see `LandOwnership`.
    case land

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
    static let clickEditing: Set<OverlayMode> = [.water, .power, .bus, .tram, .subway, .rail, .land]

    /// The view that belongs to a kind of line. The inverse of `routeMode`,
    /// spelled once — it was a `mode == .bus ? .bus : .subway` ternary in
    /// four places, which is a construction that silently means "one of the
    /// two I happened to have" and has to be hunted down for every mode
    /// added after it.
    static func view(for mode: TransitRoute.Mode) -> OverlayMode {
        switch mode {
        case .bus: return .bus
        case .tram: return .tram
        case .subway: return .subway
        case .rail: return .rail
        }
    }

    /// The line a click in this view is drawing, if it is drawing one.
    var routeMode: TransitRoute.Mode? {
        switch self {
        case .bus: return .bus
        case .tram: return .tram
        case .subway: return .subway
        case .rail: return .rail
        default: return nil
        }
    }

    /// Views that are *about* the street network, and therefore have to show
    /// it.
    ///
    /// Reported from play: *"the traffic overlay should still show cars and
    /// you should be able to place roads and highways while in the overlay."*
    /// Both halves were the same bug. Every overlay stripped the lane lines
    /// and removed the cars, so the Traffic view — a heatmap *of the road
    /// network* — was the one view that hid the road network and the traffic
    /// on it. Roads placed there landed correctly and were simply invisible,
    /// which is indistinguishable from a click that did nothing.
    ///
    /// A heatmap normally hides the buildings because the data *is* the
    /// picture and the city on top is clutter. Traffic is the exception: the
    /// thing being measured is the streets, and a congestion map you cannot
    /// see the streets in measures nothing you can act on.
    /// Whether a building that wants a utility and has not got it keeps its
    /// warning badge.
    ///
    /// **Only the two utility views, and it is an accessibility rule rather
    /// than a preference.** `ColourAccessibilityTests` measures every pair of
    /// colours in this game that means two different things: supplied amber
    /// and wanting red sit 0.516 apart to an unimpaired eye and **0.060
    /// apart under deuteranopia**. They are the same colour, and in the Power
    /// view the colour was the only thing saying which was which. A search
    /// for a third hue found none — only near-white clears water's blue,
    /// power's amber and the unlit tone for every deficiency — so the answer
    /// is the second channel this file predicted, and a glyph is one.
    ///
    /// Every other view leaves the badge off: a heatmap's subject is the
    /// data, and a drop over every unwatered block on the pollution map is
    /// the clutter the overlay exists to remove.
    var showsUtilityBadges: Bool {
        self == .water || self == .power
    }

    var showsRoadNetwork: Bool {
        self == .none || self == .traffic
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
        case .tram: return "Tram"
        case .subway: return "Subway"
        // Named for what it is rather than for the building, like Crime: a
        // player looking at this view is asking about the connection to the
        // region, not about a platform.
        case .rail: return "Regional Rail"
        case .land: return "Land"
        }
    }
}
