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
    /// reads as an object sitting on a surface.
    static let background = SKColor(srgbRed: 0.08, green: 0.09, blue: 0.10, alpha: 1.0)

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

    /// The tile's color at full development — what `color(for:density:)`
    /// blends *toward* as density rises. For `.empty`/`.road`, which never
    /// develop, this is just the only color they ever have.
    private static func fullColor(for zone: ZoneType) -> SKColor {
        switch zone {
        case .empty:
            // Unzoned land. Muted so that zoned tiles pop against it.
            return SKColor(srgbRed: 0.22, green: 0.26, blue: 0.23, alpha: 1.0)
        case .residential:
            return SKColor(srgbRed: 0.30, green: 0.69, blue: 0.35, alpha: 1.0)  // green
        case .commercial:
            return SKColor(srgbRed: 0.20, green: 0.52, blue: 0.90, alpha: 1.0)  // blue
        case .industrial:
            return SKColor(srgbRed: 0.88, green: 0.66, blue: 0.18, alpha: 1.0)  // amber
        case .road:
            return SKColor(srgbRed: 0.42, green: 0.43, blue: 0.45, alpha: 1.0)  // gray
        case .policeStation:
            return SKColor(srgbRed: 0.16, green: 0.22, blue: 0.58, alpha: 1.0)  // deep indigo, distinct from commercial's lighter blue
        case .fireStation:
            return SKColor(srgbRed: 0.70, green: 0.12, blue: 0.10, alpha: 1.0)  // brick red
        case .publicTransit:
            return SKColor(srgbRed: 0.15, green: 0.75, blue: 0.72, alpha: 1.0)  // teal, distinct from every other zone hue
        case .powerPlant:
            return SKColor(srgbRed: 0.75, green: 0.90, blue: 0.15, alpha: 1.0)  // electric chartreuse
        case .stadium:
            return SKColor(srgbRed: 0.85, green: 0.20, blue: 0.55, alpha: 1.0)  // magenta, "entertainment lights"
        case .highway:
            return SKColor(srgbRed: 0.26, green: 0.28, blue: 0.32, alpha: 1.0)  // darker, heavier-duty gray than plain road
        case .subway:
            return SKColor(srgbRed: 0.10, green: 0.42, blue: 0.58, alpha: 1.0)  // deep transit blue — same family as publicTransit's teal, richer
        case .waterTower:
            return SKColor(srgbRed: 0.20, green: 0.68, blue: 0.80, alpha: 1.0)  // aqua — distinct from every existing blue/teal
        case .pipe:
            return SKColor(srgbRed: 0.38, green: 0.55, blue: 0.58, alpha: 1.0)  // a muted, desaturated version of waterTower's aqua — same "plainer infrastructure, richer service building" family relationship highway/road and subway/publicTransit already have
        }
    }

    /// What color a tile should be drawn, given both its zone *and* how
    /// developed it is.
    ///
    /// A freshly zoned tile (density 0) is a dim, washed-out version of its
    /// zone color — "claimed but nothing built yet" — that brightens toward
    /// `fullColor(for:)` as `density` climbs to `zone.maxDensity`. This is
    /// the graybox stand-in for "a building appears and grows": no new art,
    /// just a color ramp, same spirit as everything else in this file.
    /// `.empty`/`.road` have `maxDensity == 0` and skip the blend entirely,
    /// since there's no development state for them to show.
    static func color(for zone: ZoneType, density: Int) -> SKColor {
        let full = fullColor(for: zone)
        guard zone.maxDensity > 0 else { return full }

        let dim = full.blended(withFraction: 0.7, of: background) ?? full
        let fraction = CGFloat(density) / CGFloat(zone.maxDensity)
        return dim.blended(withFraction: fraction, of: full) ?? full
    }

    /// Low end of the land-value heatmap (worthless land, value 0).
    private static let landValueLow = SKColor(srgbRed: 0.20, green: 0.16, blue: 0.30, alpha: 1.0)  // dim violet

    /// High end of the land-value heatmap (maximum value, 1).
    private static let landValueHigh = SKColor(srgbRed: 1.0, green: 0.85, blue: 0.20, alpha: 1.0)  // gold

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
    private static let trafficLow = SKColor(srgbRed: 0.16, green: 0.42, blue: 0.20, alpha: 1.0)  // muted green

    /// High end of the traffic heatmap (gridlocked, congestion 1).
    private static let trafficHigh = SKColor(srgbRed: 0.85, green: 0.15, blue: 0.15, alpha: 1.0)  // hot red

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
    /// a dim, desaturated version for "not supplied," the same "muted
    /// version of the real color" relationship `.pipe` has to `.waterTower`.
    private static let waterSupplied = SKColor(srgbRed: 0.20, green: 0.68, blue: 0.80, alpha: 1.0)
    private static let waterUnsupplied = SKColor(srgbRed: 0.16, green: 0.20, blue: 0.21, alpha: 1.0)

    static func waterColor(for hasSupply: Bool) -> SKColor {
        hasSupply ? waterSupplied : waterUnsupplied
    }

    /// Body and outline for the small ambient "cars" `GameScene` animates
    /// driving along road tiles (see `Traffic.carCount(forCongestion:)`).
    /// Pale, headlight-like body so they stand out against road's own gray.
    static let trafficCarBody = SKColor(white: 0.95, alpha: 0.95)
    static let trafficCarOutline = SKColor.black.withAlphaComponent(0.4)

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
        case .stadium: return "Stadium"
        case .highway: return "Highway"
        case .subway: return "Subway"
        case .waterTower: return "Water Tower"
        case .pipe: return "Pipe"
        }
    }
}
