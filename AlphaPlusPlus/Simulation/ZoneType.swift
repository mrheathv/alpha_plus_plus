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
/// land that *is* a road.
enum ZoneType: String, Codable, CaseIterable, Sendable {
    case empty
    case residential
    case commercial
    case industrial
    case road
}
