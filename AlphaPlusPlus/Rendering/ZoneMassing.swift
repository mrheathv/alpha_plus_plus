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
        // Level 6 is its own kind of building, shared by housing and shops.
        if RenderPalette.growthTier(for: density) >= 4, zone == .residential || zone == .commercial {
            return SkyscraperMassing.make(zone: zone, seed: seed, footprint: footprint)
        }
        if IconBuildings.isIcon(zone) {
            return IconMassing.make(for: zone, seed: seed, footprint: footprint)
        }
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

    // MARK: - Landmarks

    /// **Does this lot get the rare form?**
    ///
    /// Every building in this game is one idiom — dark faces, a neon edge, lit
    /// rectangles — so a density-5 tower was a taller density-3 tower and the
    /// skyline had no shape. A landmark is the exception each zone gets to
    /// make about itself: a spire downtown, a point block in housing, a stack
    /// over a works.
    ///
    /// **Rolled on its own generator, with its own salt.** The obvious place
    /// is a first roll inside each `make`, and that would shift every
    /// subsequent draw and silently redesign every ordinary building in the
    /// game — a change to nine-tenths of the city smuggled inside a feature
    /// about one-twelfth of it. A separate stream leaves everything that is
    /// not a landmark byte-identical, which is also what makes the contact
    /// sheet readable afterwards: the only cells that moved are the new ones.
    ///
    /// **It is a property of the variant, not of the lot**, and that falls out
    /// of how the cache works rather than being arranged. `IsoTextureCache`
    /// quantises a lot's seed to one of `variantCount` looks, so this is rolled
    /// against a canonical seed: about three of the thirty-two come back true,
    /// and a lot that is a landmark is one on every launch and every tick.
    static func isLandmark(tier: Int, seed: GridPosition) -> Bool {
        guard tier >= 3 else { return false }
        var random = BuildingRandom(seed: seed, salt: 900 + tier)
        return random.chance(landmarkChance)
    }

    /// Roughly one top-tier lot in twelve.
    ///
    /// Sized against what it is for rather than picked: a landmark has to be
    /// rare enough that finding one is an event and common enough that a
    /// built-out downtown has several. One in twelve puts two or three of them
    /// in a block of thirty and a couple of dozen across Apex.
    static let landmarkChance = 1.0 / 12

    /// The neon a zone's massing is stroked in — the same tier colours the
    /// elevation generators use, so the two look like the same game while both
    /// exist.
    static func accent(for zone: ZoneType, density: Int) -> SKColor {
        zone.maxDensity > 0
            ? RenderPalette.tierColor(for: zone, tier: max(1, RenderPalette.growthTier(for: density)))
            : RenderPalette.fullColor(for: zone)
    }
}
