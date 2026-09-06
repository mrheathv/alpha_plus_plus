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
        case .empty, .road, .policeStation, .fireStation, .publicTransit, .powerPlant, .stadium: return 0
        case .residential, .commercial, .industrial: return 5
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
        case .empty, .road, .publicTransit: return 1
        case .residential, .commercial, .industrial, .policeStation, .fireStation: return 2
        case .powerPlant, .stadium: return 3
        }
    }
}
