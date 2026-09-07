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

    init(position: GridPosition, zone: ZoneType = .empty, density: Int = 0, buildingOrigin: GridPosition? = nil, hasPipe: Bool = false) {
        self.position = position
        self.zone = zone
        self.density = density
        self.buildingOrigin = buildingOrigin ?? position
        self.hasPipe = hasPipe
    }
}
