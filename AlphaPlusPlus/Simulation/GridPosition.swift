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
