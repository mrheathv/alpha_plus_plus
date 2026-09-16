import SpriteKit

/// What building stands on a lot, as massing — the isometric counterpart of
/// `NeonStyle.makeNode(for:density:seed:)`, and eventually its replacement.
///
/// **Returns `nil` for zones not yet ported.** The migration runs zone by zone,
/// and the running game kept using the elevation renderer throughout; this
/// grows one generator at a time until it covers everything, at which point the
/// projection flips in a single change and the elevation files are deleted.
/// Until then, `nil` means "no isometric version yet", which is what lets the
/// contact sheet render exactly what has been ported and nothing else.
enum ZoneMassing {

    static func make(for zone: ZoneType, density: Int, seed: GridPosition) -> BuildingMassing? {
        let footprint = CGFloat(zone.footprintSize)
        switch zone {
        case .industrial:
            let tier = RenderPalette.growthTier(for: density)
            guard tier > 0 else { return nil }
            return IndustrialMassing.make(tier: tier, seed: seed, footprint: footprint)
        case .commercial:
            let tier = RenderPalette.growthTier(for: density)
            guard tier > 0 else { return nil }
            return CommercialMassing.make(tier: tier, seed: seed, footprint: footprint)
        case .residential:
            let tier = RenderPalette.growthTier(for: density)
            guard tier > 0 else { return nil }
            return ResidentialMassing.make(tier: tier, seed: seed, footprint: footprint)
        case .empty, .road, .highway:
            return nil
        default:
            return ServiceMassing.make(for: zone, seed: seed, footprint: footprint)
        }
    }

    /// The neon a zone's massing is stroked in — the same tier colours the
    /// elevation generators use, so the two look like the same game while both
    /// exist.
    static func accent(for zone: ZoneType, density: Int) -> SKColor {
        zone.maxDensity > 0
            ? RenderPalette.tierColor(for: zone, tier: max(1, RenderPalette.growthTier(for: density)))
            : RenderPalette.fullColor(for: zone)
    }
}
