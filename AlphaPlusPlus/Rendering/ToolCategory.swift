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

    /// The tools in this group, in the order the city earns them.
    ///
    /// Unlock order rather than pairing each cheap tool with its upgrade
    /// (road beside highway, pump beside tower). Both readings are defensible,
    /// but this one puts everything currently available at the left of the
    /// group and everything still locked trailing off to the right, so a
    /// player's usable tools are always where they last were rather than
    /// interleaved with greyed-out ones.
    var tools: [ZoneType] {
        switch self {
        case .zones:
            return [.residential, .commercial, .industrial]
        case .transport:
            return [.road, .publicTransit, .highway, .subway]
        case .utilities:
            return [.waterPump, .generator, .waterTower, .powerPlant]
        case .services:
            return [.policeStation, .fireStation, .school, .hospital, .stadium]
        }
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
}
