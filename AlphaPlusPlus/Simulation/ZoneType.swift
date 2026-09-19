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
    // The third rung of the transit ladder, and the one that is not simply a
    // pricier version of the rung below. A tram runs *in the street* on its
    // own rails: it is barely slowed by traffic where a bus crawls, it is far
    // cheaper than tunnelling, and it takes a lane away from the corridor it
    // runs along (`Traffic.tramLaneShare`). That last part is the whole
    // decision — every other transit building in this game is a pure
    // addition, and this one costs the road something.
    case tramStop
    // The fourth and last rung, and the only one that points *off the map*.
    // A commuter rail line reaching the city boundary is a connection to the
    // region — the first channel `RegionalEconomy` has ever had into the city
    // other than demand — and residents who can reach it can work outside.
    // Long hops, few stops, a big station and a long wait: it is built for a
    // journey no other mode is worth making.
    case railStation
    // The genre-parity "water & sewage" gap: unlike every access/coverage
    // mechanic above (a single adjacency or falloff-distance check),
    // water is a real network — a building needs an unbroken chain of
    // piped tiles (`Tile.hasPipe`, not a `ZoneType` — a pipe is an
    // underground layer independent of whatever's on the surface, laid
    // via `GameController.layPipe(at:)` while looking at the Water
    // overlay, not through this zoning toolbar) connecting it back to a
    // `.waterTower`, checked via `Water.hasSupply(at:in:)` against
    // `CityMap.waterSupply`, the same "cache a network search, don't redo
    // it per tile" shape `Traffic.computeLoad` already uses for routed
    // commutes.
    case waterTower

    // The starter utilities. Playing the game turned up a genuine dead end:
    // a building at density 2 raises a "no water" warning badge, but the
    // water tower isn't earned until 100 residents — so a new city showed
    // errors for a problem the player was forbidden from fixing. These are
    // the small, cheap, low-capacity versions available from tick one, the
    // same cheap/upgraded relationship `.road` has with `.highway` and
    // `.publicTransit` with `.subway`, and the same shape SimCity uses when
    // it starts you on a water pump and a small plant.
    case waterPump
    case generator

    // The education/health axis — the genre's classic mid-game progression,
    // and this project's first real money *sink*: a mature city was banking
    // millions with nothing left to buy. A `.school` is what lets a lot reach
    // the top density tier at all (see
    // `CitySimulator.educationRequiredFromLevel`), and a `.hospital` halves
    // what a hazard takes out of the blocks it covers.
    case school
    case hospital

    /// A park: the one thing in the game whose only job is to make a place
    /// nicer.
    ///
    /// Every other contributor to `LandValue` is a service with desirability
    /// as a side effect — a police station raises land value *and* stops
    /// crime, a school raises it *and* unlocks the top tier. So "make this
    /// neighbourhood desirable" had no direct tool, which left the land-value
    /// gate on the upper densities something you satisfied by accident rather
    /// than something you could aim at.
    ///
    /// 1×1, unlike every other civic building, and that is the whole design:
    /// a park's cost is the *ground* it sits on. Trading buildable area for
    /// desirability is a real land-use decision, and it only reads as one if
    /// parks are small enough to thread between blocks.
    case park
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
    /// What it costs *extra* to put this on water, or `nil` if it cannot go
    /// there at all.
    ///
    /// **Only roads cross.** A river is meant to be a real constraint on
    /// where a city can go, and it stops being one the moment anything can be
    /// dropped in it — so this is deliberately not a general "build on water
    /// for more money" rule. What a bridge buys is a *route*, and routes are
    /// what roads are for.
    ///
    /// Three times a road's own price, which is what makes a crossing
    /// somewhere you choose rather than something you lay by the dozen: on a
    /// wide river a single span costs more than the streets either side of
    /// it. A highway bridge costs more again, in the same ratio the two
    /// already stand in.
    var bridgeSurcharge: Int? {
        switch self {
        case .road: return 150
        case .highway: return 300
        default: return nil
        }
    }

    /// Can this cross water at all?
    var canBridge: Bool { bridgeSurcharge != nil }

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
        // Between a bus stop and a subway entrance, like everything else
        // about it: rails in the street cost more than a shelter and far
        // less than a tunnel.
        case .tramStop: return 250
        case .railStation: return 700
        // Cheap enough to afford alongside the first few zones out of the
        // $10,000 starting treasury, since a new city now has to buy both.
        case .waterPump: return 250
        case .generator: return 500
        // Priced against the stations they sit alongside ($800): a school is
        // the cheaper of the two because every neighbourhood wants one, while
        // a hospital serves a wider area and costs accordingly.
        case .school: return 900
        case .hospital: return 1_400
        // Cheap, because the price of a park is the lot it occupies rather
        // than the money. A player should be able to answer "this block is
        // grim" immediately, not save up for it.
        case .park: return 120
        // City-scale infrastructure/civic projects, priced well above even
        // a service station to match sitting on 9 tiles instead of 4.
        case .powerPlant: return 2000
        case .stadium: return 2500
        // Priced as "the upgraded version of the cheaper option right
        // above it": 4x a plain road (still just a road, no ongoing
        // upkeep — see `upkeepCost`), a bit under 3x a transit stop.
        case .highway: return 200
        case .subway: return 400
        // Same civic-building tier as Police/Fire, priced a bit under
        // them — no staff, just pumps and a tank. (A pipe's own $40 cost
        // lives on `GameController.pipePlacementCost` now — it's not a
        // zone the toolbar places.)
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
        case .empty, .road, .policeStation, .fireStation, .publicTransit, .powerPlant, .stadium, .highway, .subway, .tramStop, .railStation, .waterTower, .waterPump, .generator, .school, .hospital, .park: return 0
        case .residential, .commercial, .industrial: return 5
        }
    }

    /// How many people one density level of this zone houses. Only
    /// `.residential` contributes population — every other zone is 0,
    /// the same "not a concept that applies here" default `upkeepCost`
    /// already uses for non-service zones. Lives here rather than as a
    /// private constant on `GameController` now that `Demand.compute(for:)`
    /// (Simulation/) needs the exact same number `GameController.population`
    /// (App/) reads — one source of truth instead of two copies that
    /// could drift apart. A freshly placed tile (density 0) houses no
    /// one yet; population scales with how developed a tile actually is.
    var populationPerDensityLevel: Int {
        switch self {
        case .residential: return 4
        default: return 0
        }
    }

    /// How many jobs one density level of this zone provides — Commercial
    /// and Industrial both count, at the same rate, rather than each
    /// having its own: one number is enough to make jobs visibly respond
    /// to growth without inventing a balance distinction this early that
    /// nothing yet depends on (see `Demand.compute(for:)`'s own doc
    /// comment for the same reasoning applied to demand). Every other
    /// zone is 0 — same shared-source-of-truth reasoning as
    /// `populationPerDensityLevel`.
    var jobsPerDensityLevel: Int {
        switch self {
        case .commercial, .industrial: return 3
        default: return 0
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
        case .tramStop: return 9
        case .railStation: return 25
        case .waterPump: return 8
        case .generator: return 15
        // Heavy on purpose: a mature city was banking millions with nothing
        // left to buy, and an ongoing cost is a better sink than a one-off
        // purchase. A hospital is the single most expensive thing in the game
        // to run; a school sits below the power plant, which is right — a 3×3
        // plant serving the whole city should cost more than a neighbourhood
        // school — but well above the stations.
        case .school: return 35
        case .hospital: return 55
        // Small but not nothing: a city that paves itself in parks should feel
        // it, and the ongoing cost is what stops "park everything" being free.
        case .park: return 4
        case .powerPlant: return 50
        case .stadium: return 40
        // `.subway` *is* a service, same as `.publicTransit` (staffed
        // stations, not just track) — priced above a bus stop's upkeep to
        // match its wider land-value reach (`LandValue.subwayFalloffDistance`).
        case .subway: return 15
        // `.waterTower` *is* a service, same tier as Police/Fire.
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
        case .empty, .road, .publicTransit, .tramStop, .highway, .subway, .waterPump, .park: return 1
        // A rail station is 2×2 where every other transit stop is 1×1, and
        // the land is part of the price: a bus shelter threads between
        // blocks, a regional terminus takes a lot.
        case .residential, .commercial, .industrial, .policeStation, .fireStation, .waterTower, .generator, .school, .hospital, .railStation: return 2
        case .powerPlant, .stadium: return 3
        }
    }
}
