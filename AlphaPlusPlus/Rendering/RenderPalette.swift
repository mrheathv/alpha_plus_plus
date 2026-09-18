import SpriteKit

/// The game's colour palette.
///
/// This file is the *entire* answer to "what colour is a residential zone?".
/// Because `ZoneType` (in Simulation/) has no idea colours exist, restyling the
/// whole game is a change to this file and `IsoTileRenderer`, and nothing else.
///
/// **Ground and light are different things, and that distinction is the whole
/// art direction.** This file started as a graybox palette, where a zone's
/// colour *was* its tile: every lot a big flat saturated rectangle keyed to
/// what you had zoned it. That is a data visualisation, and it is the right
/// answer while you are proving mechanics against coloured squares. It is the
/// wrong answer for a game someone buys, for two reasons — no city has ground
/// that colour, and it spends the screen's entire colour budget on a flat
/// field, leaving the neon nothing to be brighter *than*.
///
/// So the palette is split:
///
/// - `groundColor(for:density:)` is what a tile is *made of* — asphalt and
///   earth at night, near-black, carrying only a whisper of its zone's hue so
///   a district still has a cast.
/// - `tierColor(for:tier:)` / `fullColor(for:)` are what a zone *emits* —
///   the neon a building is stroked in, the halo around it, and the pool of
///   light it throws on the ground beneath it (`IsoTileRenderer.syncGroundGlow`).
///
/// Zone identity did not get weaker in the trade; it moved from a flat fill to
/// light, which is both more legible against black and the only version of it
/// that looks like night. Analytical views that genuinely want a colour-coded
/// field still have one — that is exactly what the overlays are.
///
/// `SKColor` is SpriteKit's cross-platform alias; on macOS it is `NSColor`.
enum RenderPalette {

    /// Behind the grid. Deliberately darker than every tile color so the map
    /// reads as an object sitting on a surface. "Night sky," from the
    /// Retrowave SimCity reference palette.
    static let background = SKColor(srgbRed: 0.051, green: 0.008, blue: 0.129, alpha: 1.0)

    /// Bare land: the colour of the map itself where nothing has been built.
    /// Deliberately close to `background` but a step lighter, so the map still
    /// reads as a surface sitting in the night rather than a hole in it.
    static let ground = SKColor(srgbRed: 0.078, green: 0.043, blue: 0.157, alpha: 1.0)

    /// How far a developed tile's ground is tinted toward its zone's own neon.
    ///
    /// Small on purpose, and smaller than it first looks like it should be.
    /// This is the knob that decides whether the map reads as a city at night
    /// or as a chart, and it has to be set *against* the ground glow rather
    /// than on its own: the first pass used 0.26 here, which looked reasonable
    /// alone but combined with `IsoTileRenderer.syncGroundGlow` on top rebuilt
    /// exactly the flat saturated colour field the split was meant to retire,
    /// only with a gradient in it. The fill is the faint cast; the glow is the
    /// light. Turning either one up far enough makes the other pointless.
    private static let groundTintAtFullDensity: CGFloat = 0.035
    private static let groundTintWhenZonedOnly: CGFloat = 0.025

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
    /// A building with no supply: dark and desaturated, but not black.
    ///
    /// The distinction the utility overlays live or die on, so it gets a name
    /// rather than being whichever colour was to hand. Dark enough that a
    /// wash toward it plainly reads as *off*, light enough that the building's
    /// own neon outline survives at a fifth strength and the silhouette is
    /// still a silhouette.
    static let unlitBuilding = SKColor(srgbRed: 0.16, green: 0.15, blue: 0.24, alpha: 1.0)

    /// The ground under a utility overlay, in the three states a tile can
    /// actually be in.
    ///
    /// **Three, not two**, because the two supply routes have different shapes
    /// and a player cannot see either. A source covers everything within
    /// `Water.directSupplyRadius` with no pipe at all; a pipe covers what it
    /// runs beside. Drawing both as one "served" colour hides the single most
    /// useful thing the overlay could tell you — which part of your network
    /// you did not need to build.
    ///
    /// So radius coverage is a soft halo around each source and pipe coverage
    /// is the brighter field, and the difference between them is the pipe you
    /// could have skipped.
    static func supplyGroundColor(isPipe: Bool, supplied: Bool, direct: Bool) -> SKColor {
        guard supplied else { return waterUnsupplied }
        let hue = conduitColor(isPipe: isPipe, live: true)
        return background.blended(withFraction: direct ? 0.22 : 0.48, of: hue) ?? waterUnsupplied
    }

    /// The Problems overlay's ground colour: how badly a lot wants looking
    /// at.
    ///
    /// A heatmap rather than the lit/dark language the utility overlays use.
    /// Those answer a yes/no about each building; this one ranks four states,
    /// and "how bad" is a gradient — which is what a heatmap is for, and why
    /// this overlay hides the buildings the way land value and pollution do.
    static func problemColor(for severity: LotStatus.Severity) -> SKColor {
        switch severity {
        // Bright, because the whole point is a lot that catches your eye from
        // across the map without being hunted for. The first values were half
        // this and the render showed the cost: a correct picture nobody would
        // notice they were being shown. Everything fine stays at the
        // background, so the only marks on screen are the ones that want
        // something.
        case .fine: return background
        case .blocked: return SKColor(srgbRed: 0.35, green: 0.55, blue: 1.0, alpha: 1.0)
        case .failing: return SKColor(srgbRed: 1.0, green: 0.26, blue: 0.42, alpha: 1.0)
        case .critical: return SKColor(srgbRed: 1.0, green: 0.68, blue: 0.15, alpha: 1.0)
        }
    }

    /// The neon a transit line is drawn in.
    ///
    /// Borrowed from the station's own zone colour rather than picked fresh,
    /// so the line running across the map is the same hue as the buildings it
    /// calls at — sky blue for buses, violet for the subway. That is what lets
    /// a player glance at a station in Normal view and know which of the two
    /// overlays it belongs to.
    static func transitLineColor(for mode: TransitRoute.Mode) -> SKColor {
        fullColor(for: mode.stationZone)
    }

    /// The Bus/Subway overlays' ground: within walking distance of the line,
    /// or not.
    ///
    /// Two states where water has three, because transit has no equivalent of
    /// the pipe-versus-radius distinction — a station either reaches you or it
    /// does not. Built the same way `supplyGroundColor` is, blending the
    /// line's own hue into the night rather than naming a third colour, so the
    /// four network overlays keep reading as one family.
    static func transitGroundColor(for mode: TransitRoute.Mode, served: Bool) -> SKColor {
        guard served else { return waterUnsupplied }
        return background.blended(withFraction: 0.42, of: transitLineColor(for: mode)) ?? waterUnsupplied
    }

    /// A buried conduit's line colour.
    ///
    /// **Hot when live, cold when not.** Power runs electric yellow and water
    /// runs a bright cyan-blue — the two hues the retrowave palette has going
    /// spare, and the two a player already associates with the things they
    /// carry. An orphaned conduit drops to a dead slate with no bloom behind
    /// it, so a run that fails to reach its source reads as unlit wire rather
    /// than as a slightly different shade of the same thing.
    static func conduitColor(isPipe: Bool, live: Bool) -> SKColor {
        // **A dead conduit has to be visible as a dead conduit.** The first
        // value here was 0.30 grey, which against this palette's near-black
        // ground was not "unlit wire", it was nothing at all — and an orphaned
        // run you cannot see is the exact failure the live/dead distinction
        // exists to fix.
        guard live else { return SKColor(srgbRed: 0.46, green: 0.47, blue: 0.56, alpha: 1.0) }
        // **Deliberately short of full brightness.** These are drawn additively
        // so a straight run brightens where tiles meet, and at 1.0 the overlap
        // plus the bloom saturated the line to white — losing the one thing
        // the colour was carrying, which is *which* utility this is. Held
        // below the ceiling, the sum lands on a bright blue or a bright
        // yellow instead of on paper.
        return isPipe
            ? SKColor(srgbRed: 0.10, green: 0.58, blue: 0.82, alpha: 1.0)
            : SKColor(srgbRed: 0.78, green: 0.62, blue: 0.10, alpha: 1.0)
    }

    /// The Crime and Fire Risk overlays' ground colour: how strongly a
    /// service reaches this tile, from unreached to right next door.
    ///
    /// Ramped from the "night" the map already sits on toward the service's
    /// own colour, rather than through a second invented hue, so the overlay
    /// and the station it is about agree by construction — the same
    /// relationship `waterColor` keeps with a water tower. Squared on the way
    /// up because `LandValue.falloffValue` is linear in distance and a linear
    /// ramp makes a station's whole catchment read as one flat disc; with the
    /// curve, the *edge* of the catchment is where the colour changes fastest,
    /// which is exactly where the player is deciding whether to build another.
    static func coverageColor(for value: Double, service: ZoneType) -> SKColor {
        let clamped = max(0, min(1, value))
        return background.blended(withFraction: CGFloat(clamped * clamped), of: fullColor(for: service))
            ?? background
    }

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
    /// `ServiceMassing` reads this same function for every civic building's own
    /// "accent" — the glow color for its silhouette's outline — so a
    /// service zone's tile color and the glow on the building standing on
    /// it are always the same color by construction, not two palettes that
    /// have to be kept in sync by hand. Internal rather than private for
    /// exactly that reason.
    static func fullColor(for zone: ZoneType) -> SKColor {
        switch zone {
        case .park:
            // **The one green in the game**, and deliberately the only one.
            // Every other zone sits somewhere on the magenta-to-cyan
            // retrowave spine; a park is the thing that is *not* built, so it
            // gets the hue nothing else uses. Pushed toward emerald rather
            // than a natural leaf green — this is a park at night under city
            // light, not a photograph of grass.
            return SKColor(srgbRed: 0.18, green: 0.92, blue: 0.55, alpha: 1.0)
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
            // Asphalt: the *darkest* surface on the map, a shade under bare
            // ground. It was twice `ground`'s brightness when every tile was
            // a saturated fill and asphalt had to hold its own against them.
            // Against a dark map that inverted the whole picture — roads are
            // about a third of a normal grid's tiles, so a pavement brighter
            // than the land read as a lilac board with dark blocks sitting on
            // it. What makes a road visible is the lane line glowing on top of
            // it, and that needs the darkest possible bed.
            return SKColor(srgbRed: 0.063, green: 0.031, blue: 0.129, alpha: 1.0)
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
    /// developed). The same table the massing generators already pick a building's
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
    /// (the road network glow) and lane-line detail
    /// (`IsoTileRenderer.syncLaneLine`) are drawn in — separate from
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

    /// What a tile is made of — the ground it is, not the zone it means.
    ///
    /// Near-black for everything, tinted a little toward the zone's own neon
    /// so a residential district has a violet cast and an industrial one an
    /// amber cast without either becoming a block of flat colour. A zoned but
    /// unbuilt lot is tinted less than a developed one, so "claimed" and
    /// "built" still differ at a glance even before a building appears (and
    /// `IsoTileRenderer.syncZoneMarker` puts a surveyed outline on it besides).
    ///
    /// Roads and highways keep their own asphalt value rather than being
    /// tinted from it: they are the one surface in the game that really is a
    /// different material, and the glowing lane line drawn on top of them
    /// needs a dark, neutral bed to read against.
    static func color(for zone: ZoneType, density: Int) -> SKColor {
        switch zone {
        case .empty:
            return ground
        case .road, .highway:
            return fullColor(for: zone)
        default:
            break
        }

        let emitted = zone.maxDensity > 0
            ? tierColor(for: zone, tier: max(1, growthTier(for: density)))
            : fullColor(for: zone)
        let tint = zone.maxDensity > 0 && growthTier(for: density) == 0
            ? groundTintWhenZonedOnly
            : groundTintAtFullDensity
        return ground.blended(withFraction: tint, of: emitted) ?? ground
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
    /// true (see `IsoTileRenderer.syncBuriedMarker`) — pipes have no
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
        case .park: return "Park"
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
