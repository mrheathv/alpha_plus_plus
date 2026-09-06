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
}
