import Foundation

/// The city grid: a fixed-size rectangle of `Tile`s.
///
/// Stored as one flat `[Tile]` array rather than `[[Tile]]`. A flat array is a
/// single contiguous block of memory, so iterating every tile each simulation
/// tick is cache-friendly — which will matter when Phase 2 sweeps the whole map
/// many times a second. `index(of:)` does the 2D -> 1D arithmetic in one place
/// so the rest of the code never sees it.
///
/// Row-major layout: index = y * width + x.
struct CityMap: Equatable, Codable, Sendable {
    let width: Int
    let height: Int
    private(set) var tiles: [Tile]

    init(width: Int, height: Int) {
        precondition(width > 0 && height > 0, "City map must have positive dimensions")
        self.width = width
        self.height = height
        self.tiles = (0 ..< (width * height)).map { index in
            Tile(position: GridPosition(x: index % width, y: index / width))
        }
    }

    /// Is this coordinate inside the map?
    func contains(_ position: GridPosition) -> Bool {
        position.x >= 0 && position.x < width && position.y >= 0 && position.y < height
    }

    private func index(of position: GridPosition) -> Int {
        position.y * width + position.x
    }

    /// Read or write a tile by grid coordinate. Traps on out-of-bounds access,
    /// same as an array — callers that might be off the map should check
    /// `contains(_:)` first (click handling will, in the next step).
    subscript(position: GridPosition) -> Tile {
        get {
            precondition(contains(position), "Position \(position) is outside the \(width)x\(height) map")
            return tiles[index(of: position)]
        }
        set {
            precondition(contains(position), "Position \(position) is outside the \(width)x\(height) map")
            tiles[index(of: position)] = newValue
        }
    }

    /// Every position in the `size`×`size` block anchored at `origin`
    /// (extending toward +x/+y), or `[]` if *any* cell of that block would
    /// fall outside the map.
    ///
    /// All-or-nothing on purpose: a building either fits entirely or it
    /// doesn't get placed at all — there's no such thing as a building
    /// clipped at the map edge. Callers (`GameController.place(at:)`,
    /// `bulldoze(at:)`, and every footprint-aware loop in `CitySimulator`/
    /// `CityHazards`) can treat an empty result as "invalid" without a
    /// separate bounds check.
    func footprintCells(origin: GridPosition, size: Int) -> [GridPosition] {
        var cells: [GridPosition] = []
        cells.reserveCapacity(size * size)
        for dx in 0 ..< size {
            for dy in 0 ..< size {
                let cell = GridPosition(x: origin.x + dx, y: origin.y + dy)
                guard contains(cell) else { return [] }
                cells.append(cell)
            }
        }
        return cells
    }

    /// Stamp `zone` across every cell of the footprint anchored at `origin`
    /// (via `footprintCells(origin:size:)`, using `zone.footprintSize`),
    /// each cell's `buildingOrigin` pointing back to `origin`. This is the
    /// one place that writes a *whole* building's worth of tiles at once —
    /// `GameController.place(at:)` uses it for real placement, and tests
    /// use it to build well-formed multi-tile fixtures instead of poking
    /// `map[position].zone = ...` one cell at a time, which for anything
    /// wider than 1×1 would leave the other cells of the footprint
    /// inconsistent with it (wrong zone, `buildingOrigin` still pointing at
    /// themselves instead of `origin`).
    ///
    /// Doesn't validate bounds or occupancy itself — callers are expected
    /// to have already decided the placement is legal (a footprint that
    /// doesn't fit yields `[]` from `footprintCells` and this becomes a
    /// silent no-op, same "let the caller check first" contract the
    /// subscript above documents).
    mutating func placeBuilding(zone: ZoneType, origin: GridPosition) {
        for cell in footprintCells(origin: origin, size: zone.footprintSize) {
            self[cell] = Tile(position: cell, zone: zone, buildingOrigin: origin)
        }
    }
}
