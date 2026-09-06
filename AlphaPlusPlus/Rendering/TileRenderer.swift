import SpriteKit

/// Turns `Tile` *data* into SpriteKit *nodes*.
///
/// This is the seam described in CLAUDE.md: `Tile` knows nothing about
/// SpriteKit, and this type knows nothing about simulation rules. It only
/// answers "given this tile's data, what should appear on screen?".
///
/// In Phase 3 the body of `makeNode` becomes `SKSpriteNode(texture:)` with real
/// art. Nothing else in the codebase has to notice.
struct TileRenderer {

    let layout: GridLayout

    /// Create the sprite for a tile.
    func makeNode(for tile: Tile) -> SKSpriteNode {
        let node = SKSpriteNode(color: RenderPalette.color(for: tile.zone), size: layout.spriteSize)
        node.position = layout.point(for: tile.position)
        // Names are how we find nodes again later (and they show up in Xcode's
        // SpriteKit debugger, which is handy while grayboxing).
        node.name = Self.nodeName(for: tile.position)
        return node
    }

    /// Re-sync an existing sprite to current tile data.
    ///
    /// Mutating a node we already have beats deleting and recreating it: no
    /// allocation, no scene-graph churn, and it scales to a full-map refresh
    /// every simulation tick in Phase 2.
    func update(_ node: SKSpriteNode, for tile: Tile) {
        node.color = RenderPalette.color(for: tile.zone)
    }

    static func nodeName(for position: GridPosition) -> String {
        "tile-\(position.x)-\(position.y)"
    }
}
