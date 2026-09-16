import Foundation

/// How the zoning tools are grouped in the toolbar.
///
/// The toolbar listed every `ZoneType` in one row. That was fine at nine
/// tools, tolerable at thirteen, and stopped fitting at seventeen once the
/// starter utilities and the civic buildings arrived — the row was the last
/// thing left after the settings moved to menus, and it had outgrown the
/// window on its own.
///
/// Grouping also says something the flat row could not. A player looking for
/// "how do I get water" had to scan seventeen buttons hoping to recognise one;
/// now there is a Water & Power group with four things in it, and the answer is
/// wherever they look first.
///
/// Lives in `Rendering/` rather than on `ZoneType` for the same reason
/// `RenderPalette.displayName(for:)` does: this is a statement about how tools
/// are *presented*, and the simulation has no opinion about it.
enum ToolCategory: String, CaseIterable, Identifiable, Hashable {
    case zones
    case transport
    case utilities
    case services

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zones: return "Zones"
        case .transport: return "Transport"
        case .utilities: return "Water & Power"
        case .services: return "Services"
        }
    }

    /// Everything this group offers, in the order the city earns it.
    ///
    /// Unlock order rather than pairing each cheap tool with its upgrade
    /// (road beside highway, pump beside tower). Both readings are defensible,
    /// but this one puts everything currently available at the left of the
    /// group and everything still locked trailing off to the right, so a
    /// player's usable tools are always where they last were rather than
    /// interleaved with greyed-out ones.
    ///
    /// **Entries, not `ZoneType`s.** Pipes and power lines are not zones —
    /// they are separate layers edited by clicking while their overlay is up
    /// (see `Tile.hasPipe`) — so the toolbar had to special-case them with an
    /// `if category == .utilities` in the middle of its layout code. Anything
    /// that is not a `ZoneType` needed another such branch, which is a poor
    /// way to grow a toolbar. An entry says what a button *does*, so the
    /// layout renders a list and stops knowing what is on it.
    var entries: [ToolbarEntry] {
        switch self {
        case .zones:
            return [.zone(.residential), .zone(.commercial), .zone(.industrial)]
        case .transport:
            return [.zone(.road), .zone(.publicTransit), .zone(.highway), .zone(.subway)]
        case .utilities:
            return [
                .zone(.waterPump), .zone(.generator),
                .zone(.waterTower), .zone(.powerPlant),
                .network(.water, title: "Pipe", cost: GameController.pipePlacementCost, accentZone: .waterTower),
                .network(.power, title: "Power Line", cost: GameController.powerLinePlacementCost, accentZone: .powerPlant),
            ]
        case .services:
            return [.zone(.policeStation), .zone(.fireStation), .zone(.school),
                    .zone(.hospital), .zone(.stadium)]
        }
    }

    /// Just the zones in this group — what unlock ordering and the category
    /// picker's "is the selected tool in here" check care about.
    var tools: [ZoneType] {
        entries.compactMap(\.zone)
    }

    /// The group `zone` belongs to, for keeping the picker in step when the
    /// selected tool changes from somewhere other than the toolbar.
    ///
    /// `nil` for `.empty`, which is the bulldozer: it sits outside the groups
    /// entirely and stays on screen at all times, because needing to change
    /// category before you can undo a mistake would be a poor joke.
    static func containing(_ zone: ZoneType) -> ToolCategory? {
        allCases.first { $0.tools.contains(zone) }
    }

    /// Every zone that appears in some group — used to check the grouping
    /// stays exhaustive as zones are added.
    static var allTools: [ZoneType] {
        allCases.flatMap(\.tools)
    }

    static var allEntries: [ToolbarEntry] {
        allCases.flatMap(\.entries)
    }
}

/// One thing the toolbar offers.
///
/// A button is described rather than drawn: what it does, what it is called,
/// what it costs, and whose neon it borrows. `GameView` renders a list of
/// these, so adding a control is adding an entry — the thing four hundred
/// lines of hand-rolled rows made expensive enough that ordinances and bonds
/// still have no button at all.
struct ToolbarEntry: Identifiable, Hashable {
    enum Action: Hashable {
        /// Paint a zone onto the map.
        case zone(ZoneType)
        /// Edit an underground or overhead layer. Selecting it switches to the
        /// overlay that makes clicks lay that layer, which is how pipes and
        /// power lines have always worked — this just says so out loud.
        case network(OverlayMode)
    }

    let action: Action
    let title: String
    let cost: Int?
    /// Whose colour this borrows. A network tool has no `ZoneType` of its own,
    /// so it takes the one belonging to the utility it feeds — a pipe glows
    /// like a water tower, which is the thing it connects.
    let accentZone: ZoneType

    var id: Action { action }

    var zone: ZoneType? {
        if case .zone(let zone) = action { return zone }
        return nil
    }

    var overlay: OverlayMode? {
        if case .network(let overlay) = action { return overlay }
        return nil
    }

    static func zone(_ zone: ZoneType) -> ToolbarEntry {
        ToolbarEntry(
            action: .zone(zone),
            title: RenderPalette.displayName(for: zone),
            cost: zone.placementCost > 0 ? zone.placementCost : nil,
            accentZone: zone
        )
    }

    static func network(_ overlay: OverlayMode, title: String, cost: Int, accentZone: ZoneType) -> ToolbarEntry {
        ToolbarEntry(action: .network(overlay), title: title, cost: cost, accentZone: accentZone)
    }

    /// The bulldozer, which belongs to no group: it stays on screen at all
    /// times, because needing to change category before you can undo a mistake
    /// would be a poor joke.
    static let bulldozer = ToolbarEntry.zone(.empty)
}
