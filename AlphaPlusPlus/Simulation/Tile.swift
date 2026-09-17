import Foundation

/// One cell of the city grid.
///
/// A `struct` (value type), not a `class`. Two reasons that matter for a
/// simulation:
///   1. Copying is explicit — no far-away code can mutate a tile you're holding.
///   2. `Codable` + `Equatable` come nearly free, which is what we want for
///      save/load later and for tests now ("after this step, is the map equal
///      to what I expect?").
///
/// Was minimal in Phase 1 (just position + zone). Phase 2 keeps adding the
/// fields that make a zone something real: `density` first, then land value/
/// service coverage (computed, not stored — see `LandValue`), and now
/// `buildingOrigin` for zones that span more than one cell.
struct Tile: Equatable, Codable, Sendable {
    var position: GridPosition
    var zone: ZoneType

    /// How developed this tile is: 0 (just zoned, nothing built) up to
    /// `zone.maxDensity` (fully developed). Meaningless for `.empty`/`.road`
    /// tiles, which stay at 0 since their `maxDensity` is 0.
    ///
    /// Lives on `Tile` rather than being derived/stored elsewhere because
    /// it's per-tile state that persists independently of *why* it grew —
    /// same reason `zone` is stored here instead of computed.
    var density: Int

    /// The position of this tile's building's *anchor* — its minimum-x,
    /// minimum-y corner. For a plain 1×1 tile (a road, an empty cell, or
    /// any zone with `footprintSize == 1`), that's always its own
    /// `position`: a single tile is its own one-cell footprint, not a
    /// special case of "no footprint."
    ///
    /// Defaulting every tile to `buildingOrigin == position` — rather than
    /// making this `GridPosition?` and using `nil` for "not part of a
    /// bigger building" — means `isBuildingAnchor` and every piece of
    /// simulation/rendering code built on it never has to branch on
    /// "is this even a multi-tile zone?" before asking "which building does
    /// this cell belong to?" The answer is always this field, unconditionally.
    var buildingOrigin: GridPosition

    /// Is this tile the anchor of whatever building it belongs to? True for
    /// every 1×1 tile (trivially — it's its own one-cell footprint) and for
    /// the one corner of a bigger building that `GameController.place(at:)`
    /// stamped as its origin. `GameScene` uses this to decide which cells
    /// get a visible sprite: one per building, not one per cell.
    var isBuildingAnchor: Bool { buildingOrigin == position }

    /// Does this tile carry a pipe? Independent of `zone` — a tile can be
    /// a road, or zoned residential, or empty, and *also* have a pipe
    /// running underneath it. This is the one field on `Tile` that isn't
    /// part of "what the surface is doing": it's an underground layer a
    /// player edits while looking at the Water overlay
    /// (`GameController.layPipe(at:)`/`removePipe(at:)`), not through the
    /// normal zoning toolbar. Callers that reconstruct a whole `Tile` value
    /// instead of mutating this one field directly —
    /// `CityMap.placeBuilding(zone:origin:)` and
    /// `GameController.clearBuilding(at:)` — must carry the existing value
    /// forward rather than defaulting it away, or laying a pipe would get
    /// silently erased the next time anything got built or bulldozed on
    /// the surface above it.
    var hasPipe: Bool

    /// Does this tile carry a power line? The exact same shape as
    /// `hasPipe`, one paragraph up — an independent underground/overhead
    /// layer a player edits while looking at the Power overlay
    /// (`GameController.layPowerLine(at:)`/`removePowerLine(at:)`), not
    /// through the zoning toolbar. Kept as its own field rather than
    /// folded into `hasPipe` (one shared "has infrastructure" bit) since
    /// a real city plans water and power separately — a tile can have
    /// either, both, or neither — and `PowerGrid`/`Water` each need to
    /// flood-fill their *own* network, not a combined one where a pipe
    /// run would wrongly imply a power connection alongside it. Same
    /// "must be carried forward, never defaulted away" contract on
    /// re-zoning or bulldozing.
    var hasPowerLine: Bool

    /// Which service this building is waiting on to be rebuilt after a
    /// hazard, or `nil` if it isn't damaged.
    ///
    /// Set by `CityHazards.apply` to the risk's own `coveringService` — a
    /// fire leaves a block waiting on a fire station, crime on a police
    /// station. A damaged building doesn't grow at all until that service
    /// covers it (`CitySimulator.advance`), at which point the flag clears
    /// and ordinary growth resumes.
    ///
    /// This is what makes hazards matter. They used to knock a level off a
    /// building that then grew straight back, which a design playtest
    /// measured as worth about 20 population across a whole city — damage
    /// with no consequence, and therefore services with nothing to protect.
    /// Now an uncovered block that burns *stays* burnt until the player does
    /// something about it, which is the difference between a city that
    /// maintains itself and one that needs you.
    ///
    /// Optional rather than a `Bool` so the repair knows which service to
    /// look for, and so that `CityHazards` doesn't need a parallel record of
    /// what hit what. Being `Optional` also means `Codable` decodes a save
    /// written before this field existed as `nil` (synthesised `init(from:)`
    /// uses `decodeIfPresent` for optionals), so old cities load as undamaged
    /// rather than failing outright.
    var damagedBy: ZoneType?

    /// Is this building currently waiting on repair?
    var isDamaged: Bool { damagedBy != nil }

    /// Ticks left before this lot finishes the level it is building.
    ///
    /// **Why growth needed a duration at all.** A lot used to gain a density
    /// level the instant its gates were satisfied, which is why a whole city
    /// reached 90% of its final population by tick 7 and was finished by tick
    /// 16. Nothing was wrong with the decisions the player made in those
    /// sixteen ticks; there was simply no time in which to watch them happen,
    /// or to change your mind.
    ///
    /// `Optional` for the same reason `damagedBy` is: the synthesised
    /// `init(from:)` uses `decodeIfPresent` for optionals, so a city saved
    /// before this field existed loads with nothing under construction rather
    /// than failing outright.
    var constructionRemaining: Int?

    /// Is this lot part-way through building its next level?
    var isUnderConstruction: Bool { (constructionRemaining ?? 0) > 0 }

    /// How worn the road, pipe or power line on this tile is: 0 for as-new, 1
    /// for ruined. See `Infrastructure`.
    ///
    /// `Optional` for the same reason `damagedBy` and `constructionRemaining`
    /// are, and with the same invariant those two keep: `nil` is the *only*
    /// representation of "none". `Infrastructure.advance` stores `nil` rather
    /// than 0 for a tile it has repaired back to perfect, because `Tile` is
    /// `Equatable` and a tile that has been fixed has to compare equal to one
    /// that was never broken.
    var wear: Double?

    init(
        position: GridPosition,
        zone: ZoneType = .empty,
        density: Int = 0,
        buildingOrigin: GridPosition? = nil,
        hasPipe: Bool = false,
        hasPowerLine: Bool = false,
        damagedBy: ZoneType? = nil,
        constructionRemaining: Int? = nil,
        wear: Double? = nil
    ) {
        self.position = position
        self.zone = zone
        self.density = density
        self.buildingOrigin = buildingOrigin ?? position
        self.hasPipe = hasPipe
        self.hasPowerLine = hasPowerLine
        self.damagedBy = damagedBy
        self.constructionRemaining = constructionRemaining
        self.wear = wear
    }
}
