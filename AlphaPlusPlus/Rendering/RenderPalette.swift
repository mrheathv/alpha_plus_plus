import SpriteKit

/// Graybox color palette.
///
/// This file is the *entire* answer to "what color is a residential zone?".
/// Because `ZoneType` (in Simulation/) has no idea colors exist, restyling the
/// whole game — or swapping colored squares for real sprites in Phase 3 — is a
/// change to this file and `TileRenderer`, and nothing else.
///
/// `SKColor` is SpriteKit's cross-platform alias; on macOS it is `NSColor`.
enum RenderPalette {

    /// Behind the grid. Deliberately darker than every tile color so the map
    /// reads as an object sitting on a surface. "Night sky," from the
    /// Retrowave SimCity reference palette.
    static let background = SKColor(srgbRed: 0.051, green: 0.008, blue: 0.129, alpha: 1.0)

    /// The warm glow `GameScene`'s ambient sun sprite tints — the
    /// retrowave "sun on the horizon" motif, sitting fixed in world space
    /// well below the map's own bottom edge rather than on any literal
    /// horizon line (a top-down camera has none). Every reference image
    /// this project's art pass has pulled from puts a big warm sun behind
    /// the skyline; this is that same light, adapted for a camera that
    /// looks straight down instead of across a horizon.
    static let sunGlow = SKColor(srgbRed: 1.0, green: 0.58, blue: 0.16, alpha: 1.0)

    /// Colour for the Pollution overlay: clean tiles stay near the night-sky
    /// background and dirty ones climb toward a sickly industrial yellow-green.
    ///
    /// Deliberately not the neon magenta/cyan the rest of the palette runs on
    /// — pollution is the one channel that should read as *wrong*, and the
    /// synthwave palette has no unpleasant colour in it by design. Borrowing
    /// industrial's own ember hue and souring it toward green keeps it in the
    /// family while still reading as contamination.
    static func pollutionColor(for level: Double) -> SKColor {
        let clamped = max(0, min(1, level))
        return SKColor(
            srgbRed: 0.10 + 0.62 * clamped,
            green: 0.05 + 0.72 * clamped,
            blue: 0.16 + 0.06 * clamped,
            alpha: 1.0
        )
    }

    /// Flash color for "you can't afford this" feedback, when `place(at:)`
    /// reports `.insufficientFunds`. Saturated red reads as an error against
    /// every zone color, including road's gray and residential's green.
    static let insufficientFundsFlash = SKColor(srgbRed: 0.95, green: 0.15, blue: 0.15, alpha: 1.0)

    /// Flash color for a fire hazard striking a tile (`CityHazards.Strike`
    /// with `coveringService == .fireStation`). Bright orange — close
    /// enough to "fire" to read intuitively, but distinct from both the red
    /// insufficient-funds flash and the crime flash below, since all three
    /// can plausibly appear on the same session.
    static let fireHazardFlash = SKColor(srgbRed: 1.0, green: 0.45, blue: 0.05, alpha: 1.0)

    /// Flash color for a crime hazard striking a tile (`coveringService == .policeStation`).
    /// Violet — reads as "something bad happened" without borrowing fire's
    /// orange or the funds flash's red, so a glance at *which* color flashed
    /// says which hazard it was.
    static let crimeHazardFlash = SKColor(srgbRed: 0.55, green: 0.25, blue: 0.85, alpha: 1.0)

    /// Flash color for "bulldoze it first" feedback, when `place(at:)`
    /// reports `.blocked` — placing over a tile that already has something
    /// on it. The exact hue `placementPreviewBlockedFill`/`Stroke` already
    /// warn with before the click, just opaque, so the pre-click warning
    /// and the post-click flash read as the same signal rather than two
    /// different reds with two different meanings.
    static let blockedPlacementFlash = SKColor(srgbRed: 1.0, green: 0.2, blue: 0.25, alpha: 1.0)

    /// The color a zone is drawn at its most developed. For every service
    /// building, `.empty`, and `.road`/`.highway` (their *base* fill — see
    /// `networkAccentColor(for:)` for the separate glow/lane color those
    /// two use now), this is the only color they ever have. For the three
    /// growable zones, this returns their highest tier's color
    /// (`tierColor(for:tier:)`) as a sensible single answer for any caller
    /// that just wants "the" color for a zone — `color(for:density:)` is
    /// what those three actually render through day to day, and it reads
    /// tier by tier, not through this function.
    ///
    /// Retrowave palette: every hue below is a saturated neon rather than a
    /// realistic material color (asphalt gray, brick red, grass green).
    /// `ZoneIcon` reads this same function for every *civic* building's own
    /// "accent" — the glow color for its silhouette's outline — so a
    /// service zone's tile color and the glow on the building standing on
    /// it are always the same color by construction, not two palettes that
    /// have to be kept in sync by hand. Internal rather than private for
    /// exactly that reason.
    static func fullColor(for zone: ZoneType) -> SKColor {
        switch zone {
        case .empty:
            // Unzoned land — between the near-black background and the
            // road's own dark asphalt-purple, the "night" every neon shape
            // and every glowing street sits on.
            return SKColor(srgbRed: 0.11, green: 0.035, blue: 0.23, alpha: 1.0)
        case .residential, .commercial, .industrial:
            return tierColor(for: zone, tier: 3)
        case .school:
            // Warm amber against the cool blues of water and transit — the
            // civic buildings should read as their own family on the map.
            return SKColor(srgbRed: 1.0, green: 0.78, blue: 0.25, alpha: 1.0)
        case .hospital:
            // Clinical white-pink, the one nearly-desaturated colour in the
            // palette, so a hospital stands out from every neon around it.
            return SKColor(srgbRed: 1.0, green: 0.62, blue: 0.70, alpha: 1.0)
        case .waterPump:
            // Deliberately the same hue as `.waterTower`, and `.generator`
            // as `.powerPlant` below: the pair is the same utility at two
            // sizes, so they should read as the same *system* on the map,
            // the way `.road` and `.highway` share their asphalt base.
            return fullColor(for: .waterTower)
        case .generator:
            return fullColor(for: .powerPlant)
        case .road, .highway:
            // Dark asphalt-purple base — both read as the same paved
            // surface now; what makes a highway a highway is its brighter
            // `networkAccentColor(for:)` glow, not a different base fill.
            return SKColor(srgbRed: 0.169, green: 0.063, blue: 0.333, alpha: 1.0)
        case .policeStation:
            return SKColor(srgbRed: 0.35, green: 0.35, blue: 1.0, alpha: 1.0)  // neon indigo-blue, distinct from commercial's cyan family
        case .fireStation:
            return SKColor(srgbRed: 1.0, green: 0.20, blue: 0.20, alpha: 1.0)  // neon red
        case .publicTransit:
            return SKColor(srgbRed: 0.25, green: 0.65, blue: 1.0, alpha: 1.0)  // sky blue — leans blue rather than teal, so it doesn't drift toward green
        case .powerPlant:
            // Icy electric blue-white — a "lightning bolt," not a warm
            // color at all, which is also what keeps it from reading as
            // just another shade of Industrial's oranges. Deliberately the
            // palest, most desaturated zone on the map: every other zone
            // reads as "a colored light," this one reads as "the light
            // itself."
            return SKColor(srgbRed: 0.70, green: 0.88, blue: 1.0, alpha: 1.0)
        case .stadium:
            return SKColor(srgbRed: 1.0, green: 0.25, blue: 0.75, alpha: 1.0)  // hot pink, "entertainment lights"
        case .subway:
            return SKColor(srgbRed: 0.55, green: 0.30, blue: 1.0, alpha: 1.0)  // neon violet — same transit family as publicTransit's sky blue, richer
        case .waterTower:
            return SKColor(srgbRed: 0.05, green: 0.60, blue: 0.90, alpha: 1.0)  // deep ocean-blue, distinct from Commercial's cyan family
        }
    }

    /// Which of 3 visual/color tiers a growable zone's density falls into —
    /// 0 (nothing built yet), 1 (small), 2 (medium), 3 (large/fully
    /// developed). The same table `ZoneIcon` already picks a building's
    /// *shape* from, and now also which of `tierColor(for:tier:)`'s three
    /// named colors it's drawn in — a lot doesn't just get brighter as it
    /// grows any more, it changes hue at each tier the same way its
    /// silhouette already changes shape. Deliberately a direct table, not
    /// a `density / maxDensity` proportion — a proportional split would
    /// put density 2 and 3 in the *same* third for a max of 5, which is
    /// exactly the "adjacent levels should look different" case this
    /// exists to show. Assumes today's `maxDensity` of 5 for every
    /// growable zone; revisit this table specifically if that ever changes.
    static func growthTier(for density: Int) -> Int {
        switch density {
        case 0: return 0
        case 1, 2: return 1
        case 3, 4: return 2
        default: return 3
        }
    }

    /// The three named colors a growable zone's tiers cycle through, from
    /// the Retrowave SimCity reference palette — a small lot, a mid-size
    /// development, and a fully-built one are different *hues* now, not
    /// just different brightnesses of one fixed color the way every other
    /// zone still works. `tier` is clamped to `1...3`: tier 0 (nothing
    /// built) has no color of its own — `color(for:density:)` uses tier
    /// 1's for that "dim, not built yet" state, on the theory that a bare
    /// lot previews what it's zoned to *become*, not its eventual
    /// fully-built form.
    static func tierColor(for zone: ZoneType, tier: Int) -> SKColor {
        let clampedTier = min(max(tier, 1), 3)
        switch zone {
        case .residential:
            switch clampedTier {
            case 1: return SKColor(srgbRed: 0.482, green: 0.184, blue: 0.969, alpha: 1.0)  // Low density — violet
            case 2: return SKColor(srgbRed: 0.655, green: 0.259, blue: 0.910, alpha: 1.0)  // Mid density — orchid
            default: return SKColor(srgbRed: 0.902, green: 0.651, blue: 1.0, alpha: 1.0)  // High density — pale lavender
            }
        case .commercial:
            switch clampedTier {
            case 1: return SKColor(srgbRed: 1.0, green: 0.431, blue: 0.780, alpha: 1.0)  // Retail — pink
            case 2: return SKColor(srgbRed: 1.0, green: 0.239, blue: 0.506, alpha: 1.0)  // Offices — hot rose
            default: return SKColor(srgbRed: 1.0, green: 0.702, blue: 0.278, alpha: 1.0)  // Entertainment — amber
            }
        case .industrial:
            switch clampedTier {
            case 1: return SKColor(srgbRed: 1.0, green: 0.620, blue: 0.173, alpha: 1.0)  // Manufacturing — orange
            case 2: return SKColor(srgbRed: 1.0, green: 0.369, blue: 0.227, alpha: 1.0)  // Heavy industry — red-orange
            default: return SKColor(srgbRed: 0.788, green: 0.294, blue: 0.294, alpha: 1.0)  // Pollution warning — brick red
            }
        default:
            // Every other zone doesn't grow, so it has no tiers of its
            // own — fall back to its one fixed color rather than trap,
            // since `fullColor(for:)` itself calls this at tier 3.
            return fullColor(for: zone)
        }
    }

    /// The bright accent a road or highway tile's network glow
    /// (`TileRenderer.syncNetworkGlow`) and lane-line detail
    /// (`TileRenderer.syncLaneLine`) are drawn in — separate from
    /// `fullColor(for:)`'s dark asphalt base now that the two are
    /// deliberately different values: a synthwave highway reads as a dark
    /// road with a *glowing line down the middle of it*, not a solid
    /// block of color the way it used to.
    static func networkAccentColor(for zone: ZoneType) -> SKColor {
        switch zone {
        case .highway: return SKColor(srgbRed: 0.0, green: 0.898, blue: 1.0, alpha: 1.0)  // Highway glow — cyan
        default: return SKColor(srgbRed: 1.0, green: 0.184, blue: 0.690, alpha: 1.0)  // Lane lines — magenta
        }
    }

    /// What color a tile should be drawn, given both its zone *and* how
    /// developed it is.
    ///
    /// For the three growable zones, this is the graybox stand-in for "a
    /// building appears and grows": a freshly zoned tile (density 0) is a
    /// dim, washed-out version of its tier-1 color — "claimed but nothing
    /// built yet" — that brightens toward that tier's own color as density
    /// climbs, then jumps to the *next* tier's color the moment density
    /// actually crosses into it (`growthTier(for:)`), rather than
    /// continuously blending across all 5 density levels toward one fixed
    /// color the way this used to work. Every other zone (`.empty`/
    /// `.road`/every service) has `maxDensity == 0` and skips straight to
    /// its one fixed color, since there's no development state for them to
    /// show.
    static func color(for zone: ZoneType, density: Int) -> SKColor {
        guard zone.maxDensity > 0 else { return fullColor(for: zone) }

        let tier = growthTier(for: density)
        guard tier > 0 else {
            let notYetBuilt = tierColor(for: zone, tier: 1)
            return notYetBuilt.blended(withFraction: 0.7, of: background) ?? notYetBuilt
        }
        return tierColor(for: zone, tier: tier)
    }

    /// Low end of the land-value heatmap (worthless land, value 0).
    private static let landValueLow = SKColor(srgbRed: 0.22, green: 0.10, blue: 0.35, alpha: 1.0)  // deep neon violet

    /// High end of the land-value heatmap (maximum value, 1).
    private static let landValueHigh = SKColor(srgbRed: 1.0, green: 0.90, blue: 0.25, alpha: 1.0)  // neon gold

    /// Color for the "Show Land Value" overlay: a violet-to-gold heatmap,
    /// chosen specifically so it can't be confused with any normal zone
    /// color (green/blue/amber/gray) — glancing at the map should
    /// immediately tell you which mode you're looking at.
    ///
    /// `value` is clamped defensively even though `LandValue.value(at:in:)`
    /// already only ever returns 0...1 — this function shouldn't have to
    /// trust that every future caller does the same.
    static func landValueColor(for value: Double) -> SKColor {
        let fraction = CGFloat(min(max(value, 0), 1))
        return landValueLow.blended(withFraction: fraction, of: landValueHigh) ?? landValueLow
    }

    /// Low end of the traffic heatmap (empty road, congestion 0).
    private static let trafficLow = SKColor(srgbRed: 0.15, green: 1.0, blue: 0.45, alpha: 1.0)  // neon green

    /// High end of the traffic heatmap (gridlocked, congestion 1).
    private static let trafficHigh = SKColor(srgbRed: 1.0, green: 0.15, blue: 0.35, alpha: 1.0)  // neon red

    /// Color for the "Show Traffic" overlay: green-to-red, the universal
    /// "flowing to jammed" convention (traffic lights, live-traffic map
    /// apps) — unlike the land-value overlay's violet-to-gold, this one
    /// deliberately leans on a convention players already know rather than
    /// inventing a new one, since "red is bad" needs no legend.
    static func trafficColor(for congestion: Double) -> SKColor {
        let fraction = CGFloat(min(max(congestion, 0), 1))
        return trafficLow.blended(withFraction: fraction, of: trafficHigh) ?? trafficLow
    }

    /// Color for the "Show Water" overlay — a plain two-color read, not a
    /// gradient like land value/traffic: `Water.hasSupply(at:in:)` is
    /// binary (a tile either has a connected pipe touching it or it
    /// doesn't), so there's no in-between value to blend toward. Reuses
    /// `waterTower`'s own aqua for "supplied" — the overlay and the
    /// building that provides it should read as the same thing — against
    /// a dim, desaturated version for "not supplied."
    private static let waterSupplied = SKColor(srgbRed: 0.05, green: 0.60, blue: 0.90, alpha: 1.0)
    private static let waterUnsupplied = SKColor(srgbRed: 0.12, green: 0.10, blue: 0.18, alpha: 1.0)

    static func waterColor(for hasSupply: Bool) -> SKColor {
        hasSupply ? waterSupplied : waterUnsupplied
    }

    /// Marker drawn on top of the Water overlay wherever `Tile.hasPipe` is
    /// true (see `TileRenderer`'s pipe-marker sync) — pipes have no
    /// surface color of their own now that they're an underground layer
    /// rather than a `ZoneType`, so this is the one place a pipe is
    /// actually visible at all. A muted, desaturated version of
    /// `waterTower`'s ocean-blue, same "plainer infrastructure, richer
    /// service building" family relationship highway/road and
    /// subway/publicTransit already have — the exact value `.pipe`'s own
    /// tile color used to be, before pipes moved off the surface grid.
    static let pipeMarkerColor = SKColor(srgbRed: 0.15, green: 0.40, blue: 0.55, alpha: 1.0)

    /// Color for the "Show Power" overlay — the exact same "plain
    /// two-color read" shape `waterColor(for:)` documents one paragraph
    /// up, for the parallel network: `PowerGrid.hasSupply(at:in:)` is
    /// just as binary as `Water.hasSupply(at:in:)`. Reuses `powerPlant`'s
    /// own icy blue-white for "supplied," against the same dim
    /// desaturated tone `waterUnsupplied` uses for "not supplied" —
    /// deliberately the same unsupplied color both overlays share, since
    /// "nothing here" should read identically regardless of which
    /// utility you're looking for.
    private static let powerSupplied = SKColor(srgbRed: 0.70, green: 0.88, blue: 1.0, alpha: 1.0)

    static func powerColor(for hasSupply: Bool) -> SKColor {
        hasSupply ? powerSupplied : waterUnsupplied
    }

    /// Marker drawn on top of the Power overlay wherever `Tile.hasPowerLine`
    /// is true — the exact same role `pipeMarkerColor` plays for pipes,
    /// one level up, just tinted toward `powerPlant`'s own icy blue-white
    /// rather than `waterTower`'s ocean-blue, so the two utility markers
    /// stay visually distinct from one another even though both share
    /// the same muted, desaturated "just a line, not a building" treatment.
    static let powerLineMarkerColor = SKColor(srgbRed: 0.45, green: 0.55, blue: 0.60, alpha: 1.0)

    /// Body and outline for the small ambient "cars" `GameScene` animates
    /// driving along road tiles (see `Traffic.carCount(forCongestion:)`).
    /// Pale, headlight-like body so they stand out against road's own gray.
    static let trafficCarBody = SKColor(white: 0.95, alpha: 0.95)
    static let trafficCarOutline = SKColor.black.withAlphaComponent(0.4)

    /// Fill/stroke for the placement-preview outline that follows the
    /// cursor before a click commits (`GameScene.updatePlacementPreview`) —
    /// green while every cell the selected tool would cover is still
    /// `.empty`, red once hovering somewhere that already has a road or
    /// building on it (placing there would replace it, via the same
    /// auto-replace path a real click already uses) — visible *before*
    /// the click, not just discoverable after.
    static let placementPreviewClearFill = SKColor(srgbRed: 0.3, green: 1.0, blue: 0.5, alpha: 0.28)
    static let placementPreviewClearStroke = SKColor(srgbRed: 0.3, green: 1.0, blue: 0.5, alpha: 0.95)
    static let placementPreviewBlockedFill = SKColor(srgbRed: 1.0, green: 0.2, blue: 0.25, alpha: 0.28)
    static let placementPreviewBlockedStroke = SKColor(srgbRed: 1.0, green: 0.2, blue: 0.25, alpha: 0.95)

    /// Label for the zone-picker toolbar. Lives here rather than on
    /// `ZoneType` itself for the same reason `color(for:)` does: `ZoneType`
    /// is simulation data and knows nothing about how it's presented.
    /// `.empty` reads as "Bulldoze" because that's what selecting it and
    /// clicking a tile *does*, even though the underlying value is the same
    /// "no zone" case used for freshly-created tiles.
    static func displayName(for zone: ZoneType) -> String {
        switch zone {
        case .empty: return "Bulldoze"
        case .residential: return "Residential"
        case .commercial: return "Commercial"
        case .industrial: return "Industrial"
        case .road: return "Road"
        case .policeStation: return "Police Station"
        case .fireStation: return "Fire Station"
        case .publicTransit: return "Transit Stop"
        case .powerPlant: return "Power Plant"
        case .school: return "School"
        case .hospital: return "Hospital"
        case .waterPump: return "Water Pump"
        case .generator: return "Generator"
        case .stadium: return "Stadium"
        case .highway: return "Highway"
        case .subway: return "Subway"
        case .waterTower: return "Water Tower"
        }
    }
}
