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
/// Intentionally minimal for Phase 1. Population, land value, density and
/// service coverage are Phase 2 fields.
struct Tile: Equatable, Codable, Sendable {
    var position: GridPosition
    var zone: ZoneType

    init(position: GridPosition, zone: ZoneType = .empty) {
        self.position = position
        self.zone = zone
    }
}
