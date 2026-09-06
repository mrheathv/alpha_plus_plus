import Foundation

/// What the player has designated a tile for.
///
/// `String` raw values (rather than the default `Int`) make save files readable
/// and, more importantly, stable: adding a case in the middle later won't
/// silently reinterpret old saves. That is the cheap half of
/// "serialization-friendly" we can pay for now without building save/load.
///
/// Phase 2 note: `road` is modelled as a zone type for now because in Phase 1 a
/// tile is exactly one thing. Once roads gain network semantics (connectivity,
/// traffic, adjacency-driven growth) they will likely split out into their own
/// field on `Tile`, since a real city has zoned land *served by* a road, not
/// land that *is* a road. `policeStation`/`fireStation` are modelled the same
/// way for the same reason: a single tile that just *is* the service, with
/// `maxDensity` 0 so it never grows, same as `road`. `publicTransit` is the
/// same shape again: a second, cheaper way to give a zone access, alongside
/// `road` rather than replacing it — see `CitySimulator.hasAccess`.
/// `powerPlant`/`stadium` are the first zones to use `footprintSize == 3` —
/// proof the mechanism (built for the 2×2 buildings) scales to whatever size
/// a future zone needs without changes to it.
enum ZoneType: String, Codable, CaseIterable, Sendable {
    case empty
    case residential
    case commercial
    case industrial
    case road
    case policeStation
    case fireStation
    case publicTransit
    case powerPlant
    case stadium
    // The genre-parity "transit variety" gap: `.highway` is a road that
    // trades a higher price for handling more neighboring development
    // before it congests (see `Traffic.congestionCapacity(for:)`);
    // `.subway` is a `.publicTransit` stop that trades a higher price
    // (and ongoing upkeep, unlike a bus stop's flat road-tier cost) for a
    // wider land-value reach (`LandValue.subwayFalloffDistance`). Both are
    // *alongside* their cheaper counterpart, not a replacement for it —
    // same relationship `.publicTransit` already has with `.road`.
    case highway
    case subway
    // The genre-parity "water & sewage" gap: unlike every access/coverage
    // mechanic above (a single adjacency or falloff-distance check),
    // water is a real network — a building needs an unbroken chain of
    // `.pipe` tiles connecting it back to a `.waterTower`, checked via
    // `Water.hasSupply(at:in:)` against `CityMap.waterSupply`, the same
    // "cache a network search, don't redo it per tile" shape
    // `Traffic.computeLoad` already uses for routed commutes. `.pipe` is
    // deliberately *not* an access provider like `.road` — see
    // `CitySimulator.hasAccess` — it carries water, not people or cars.
    case pipe
    case waterTower
}

extension ZoneType {
    /// What it costs the treasury to paint one tile with this zone.
    ///
    /// This lives on `ZoneType` itself, in `Simulation/`, rather than beside
    /// `RenderPalette.color(for:)` in `Rendering/`: cost is game *rules*
    /// (it changes what placement does), not presentation, and it only needs
    /// `Foundation` — no import trade-off to make. `.empty` costs nothing:
    /// clearing a tile via the toolbar's "Bulldoze" tool is free, same as the
    /// right-click quick-bulldoze shortcut.
    var placementCost: Int {
        switch self {
        case .empty: return 0
        case .residential: return 100
        case .commercial: return 150
        case .industrial: return 120
        case .road: return 50
        // A landmark, city-wide investment, not a per-tile zone — priced
        // well above anything else placeable.
        case .policeStation, .fireStation: return 800
        // Cheaper than a station (it's a stop, not a building) but pricier
        // than a road tile (it projects access over an area, not just to
        // its own neighbors).
        case .publicTransit: return 150
        // City-scale infrastructure/civic projects, priced well above even
        // a service station to match sitting on 9 tiles instead of 4.
        case .powerPlant: return 2000
        case .stadium: return 2500
        // Priced as "the upgraded version of the cheaper option right
        // above it": 4x a plain road (still just a road, no ongoing
        // upkeep — see `upkeepCost`), a bit under 3x a transit stop.
        case .highway: return 200
        case .subway: return 400
        // A `.pipe` is priced below a road (simpler than paving a
        // street). `.waterTower` sits in the same civic-building tier
        // as Police/Fire, priced a bit under them — no staff, just
        // pumps and a tank.
        case .pipe: return 40
        case .waterTower: return 700
        }
    }

    /// How many growth steps this zone can develop through — `Tile.density`
    /// runs from 0 (just zoned, nothing built) up to this value (fully
    /// developed). `.empty`, `.road`, and the service buildings aren't
    /// developable land, so they're pinned at 0: `CitySimulator.advance(_:)`
    /// uses this to skip them without needing a separate "is this zone
    /// growable?" check.
    var maxDensity: Int {
        switch self {
        case .empty, .road, .policeStation, .fireStation, .publicTransit, .powerPlant, .stadium, .highway, .subway, .pipe, .waterTower: return 0
        case .residential, .commercial, .industrial: return 5
        }
    }

    /// What it costs the treasury to keep this building running, once
    /// placed, every simulation step — separate from `placementCost`, which
    /// is a one-time charge. Only public services/infrastructure carry an
    /// ongoing cost; residential/commercial/industrial zones (and roads,
    /// and `.empty`) cost nothing to maintain because they're the tax base,
    /// not city spending — see `GameController.taxRevenue`. Without this,
    /// a city's economy was a one-way accumulator once growth hit its
    /// density ceiling: nothing left to spend treasury on, so it just
    /// climbed forever. Priced at roughly 2-3% of `placementCost` per tick,
    /// same "first guess, needs playtesting" status as every other number
    /// in this file — enough that running several services is a real,
    /// felt drag on the treasury, not so much that building the services
    /// growth depends on becomes self-defeating.
    var upkeepCost: Int {
        switch self {
        // `.highway` is still just a road (no staff, no ongoing service to
        // fund) — its higher `placementCost` already reflects the bigger
        // one-time build; nothing recurring on top of that, matching
        // `.road`'s own 0.
        case .empty, .residential, .commercial, .industrial, .road, .highway: return 0
        case .policeStation, .fireStation: return 20
        case .publicTransit: return 5
        case .powerPlant: return 50
        case .stadium: return 40
        // `.subway` *is* a service, same as `.publicTransit` (staffed
        // stations, not just track) — priced above a bus stop's upkeep to
        // match its wider land-value reach (`LandValue.subwayFalloffDistance`).
        case .subway: return 15
        // `.pipe` is still just infrastructure, same reasoning as
        // `.highway`'s 0 — nothing to staff. `.waterTower` *is* a
        // service, same tier as Police/Fire.
        case .pipe: return 0
        case .waterTower: return 20
        }
    }

    /// How many cells on a side this zone occupies: a footprintSize-N zone
    /// covers an N×N block anchored at wherever it was placed (see
    /// `Tile.buildingOrigin`). Infrastructure that connects to a network
    /// (`.road`, `.publicTransit`) and unzoned land stay 1×1; ordinary
    /// buildings are 2×2 — "at scale" compared to the graybox-single-tile
    /// buildings Phase 1/2 shipped with; `powerPlant`/`stadium` are 3×3,
    /// proving the mechanism (`CityMap.footprintCells(origin:size:)` and
    /// everything built on it) doesn't care how big a zone is.
    var footprintSize: Int {
        switch self {
        case .empty, .road, .publicTransit, .highway, .subway, .pipe: return 1
        case .residential, .commercial, .industrial, .policeStation, .fireStation, .waterTower: return 2
        case .powerPlant, .stadium: return 3
        }
    }
}
