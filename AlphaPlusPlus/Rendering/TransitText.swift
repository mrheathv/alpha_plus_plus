import Foundation

/// What the transit panel calls things.
///
/// In `Rendering/` for the reason `CalendarText` and
/// `RenderPalette.displayName(for:)` are: `Simulation/` may import Foundation
/// only, and what a thing is *called* is a statement about the UI.
enum TransitText {

    static func modeName(_ mode: TransitRoute.Mode) -> String {
        switch mode {
        case .bus: return "Bus"
        case .subway: return "Subway"
        }
    }

    /// "Bus 1", "Subway 2".
    ///
    /// **Numbered by position within its own mode, not by route id.** The id
    /// is never reused, so naming from it would leave gaps — "Bus 1, Bus 4" —
    /// and a gap in a numbered list reads as something missing rather than as
    /// something deleted. The cost is that deleting a line renumbers the ones
    /// after it, which is what a city builder that auto-names its lines
    /// generally does; the name is a label, and the identity is the id.
    static func name(for route: TransitRoute, numberedWithin routes: [TransitRoute]) -> String {
        let number = (routes.filter { $0.mode == route.mode }.firstIndex(of: route) ?? 0) + 1
        return "\(modeName(route.mode)) \(number)"
    }

    static func stops(_ count: Int) -> String {
        "\(count) stop\(count == 1 ? "" : "s")"
    }

    /// One tick is one day (`CityDate`), so what the router counted this tick
    /// is the day's ridership — no conversion, and the unit says so.
    static func ridership(_ riders: Int?) -> String {
        guard let riders else { return "no data yet" }
        return "\(riders.formatted()) riders/day"
    }

    /// What a line that is not running is waiting for.
    ///
    /// Only ever "too few stops", because that is the only way a route can
    /// exist and do nothing: every other failure — a station bulldozed, a stop
    /// that is the wrong kind of building — reduces to the same thing once
    /// `Transit` has finished counting what works.
    static func fault(for route: TransitRoute, workingStops: Int) -> String? {
        guard workingStops < TransitRoute.minimumStops else { return nil }
        return workingStops == route.stops.count
            ? "Needs another stop"
            : "A station on this line is gone"
    }

    /// The draft's own line of instruction. A player who has just pressed a
    /// tool with no idea what it wants needs a sentence, and this is the only
    /// place in the game where clicking a *building* means something other
    /// than inspecting or bulldozing it.
    static func draftPrompt(for draft: TransitRouteDraft) -> String {
        switch draft.stops.count {
        case 0:
            return "Click a \(modeName(draft.mode).lowercased()) station to start the line."
        case 1:
            return "Click another station. Click the last one again to take it off."
        default:
            return "Click more stations, or finish the line."
        }
    }
}
