import Foundation

/// A whole-number coordinate on the city grid.
///
/// Deliberately *not* a `CGPoint`: grid coordinates are discrete tile indices,
/// not screen positions. Keeping them as `Int` makes illegal states (a tile at
/// x = 3.7) unrepresentable, and keeps the simulation free of any graphics
/// types. Converting grid space -> screen space is `Rendering/GridLayout`'s job.
struct GridPosition: Hashable, Codable, Sendable {
    var x: Int
    var y: Int

    init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

extension GridPosition: CustomStringConvertible {
    var description: String { "(\(x), \(y))" }
}

extension GridPosition {
    /// Every grid position on the straight line from `self` to `other`,
    /// inclusive of both ends, in order from `self` to `other`.
    ///
    /// This is Bresenham's line algorithm — the standard way to walk a
    /// straight line through a grid using only integer arithmetic, so it's
    /// exact (no rounding drift) and touches every cell the line passes
    /// through with no gaps. It exists for drag-to-paint: `GameScene` only
    /// gets a mouse-moved event roughly once per frame, so a fast drag can
    /// jump several tiles between two events. Filling in the line between
    /// the last tile and this one is what turns that into a continuous
    /// stroke instead of a dotted one.
    func line(to other: GridPosition) -> [GridPosition] {
        var positions: [GridPosition] = []

        var (currentX, currentY) = (x, y)
        let (targetX, targetY) = (other.x, other.y)

        let stepX = currentX < targetX ? 1 : -1
        let stepY = currentY < targetY ? 1 : -1
        let deltaX = abs(targetX - currentX)
        let deltaY = -abs(targetY - currentY)
        var error = deltaX + deltaY

        while true {
            positions.append(GridPosition(x: currentX, y: currentY))
            if currentX == targetX && currentY == targetY { break }
            let doubledError = 2 * error
            if doubledError >= deltaY {
                error += deltaY
                currentX += stepX
            }
            if doubledError <= deltaX {
                error += deltaX
                currentY += stepY
            }
        }

        return positions
    }

    /// The four positions sharing an edge with this one — north, south,
    /// east, west — not the diagonals. Doesn't check map bounds itself;
    /// callers pair this with `CityMap.contains(_:)` (see
    /// `CitySimulator.hasRoadAccess`).
    ///
    /// "Orthogonal" (not `neighbors()` including diagonals) is a deliberate
    /// choice, not an oversight: road access should mean "shares a side with
    /// a road," matching how a real driveway connects, not "touches even at
    /// a single corner."
    func orthogonalNeighbors() -> [GridPosition] {
        [
            GridPosition(x: x, y: y - 1),
            GridPosition(x: x, y: y + 1),
            GridPosition(x: x - 1, y: y),
            GridPosition(x: x + 1, y: y),
        ]
    }

    /// Grid distance to `other`, counting only orthogonal steps (no
    /// diagonal shortcuts) — the natural distance metric on a tile grid,
    /// and what `LandValue` uses to measure "how far is this tile from a
    /// road."
    func manhattanDistance(to other: GridPosition) -> Int {
        abs(x - other.x) + abs(y - other.y)
    }
}
