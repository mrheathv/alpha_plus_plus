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

    /// Create the sprite for a tile. `tile` should be a building's anchor —
    /// `GameScene.buildTileNodes()` only calls this for `isBuildingAnchor`
    /// tiles, since one building (however many cells it covers) gets one
    /// sprite, sized and centered across its whole `footprintSize`, not one
    /// sprite per cell.
    func makeNode(for tile: Tile) -> SKSpriteNode {
        let footprintSize = tile.zone.footprintSize
        let node = SKSpriteNode(color: RenderPalette.color(for: tile.zone, density: tile.density), size: layout.spriteSize(forFootprint: footprintSize))
        node.position = layout.centerPoint(ofFootprintOrigin: tile.position, size: footprintSize)
        // Names are how we find nodes again later (and they show up in Xcode's
        // SpriteKit debugger, which is handy while grayboxing).
        node.name = Self.nodeName(for: tile.position)
        syncPips(on: node, count: tile.density)
        syncIcon(on: node, zone: tile.zone, density: tile.density, footprintSize: footprintSize, seed: tile.position)
        return node
    }

    /// Re-sync an existing sprite to current tile data.
    ///
    /// Mutating a node we already have beats deleting and recreating it: no
    /// allocation, no scene-graph churn, and it scales to a full-map refresh
    /// every simulation tick. `syncIcon` runs here too, not just in
    /// `makeNode` — a 1×1 zone (road, transit) re-zones through the fast
    /// incremental `refresh` path rather than a full `rebuildEntireGrid()`,
    /// so this is the only place a freshly-placed transit stop's icon would
    /// ever get drawn.
    func update(_ node: SKSpriteNode, for tile: Tile) {
        node.color = RenderPalette.color(for: tile.zone, density: tile.density)
        syncPips(on: node, count: tile.density)
        syncIcon(on: node, zone: tile.zone, density: tile.density, footprintSize: tile.zone.footprintSize, seed: tile.position)
    }

    static func nodeName(for position: GridPosition) -> String {
        "tile-\(position.x)-\(position.y)"
    }

    // MARK: - Density pips

    /// The color ramp (`RenderPalette.color(for:density:)`) shows growth as
    /// brightness, which is subtle tile-to-tile — these small dots put an
    /// actual *count* on top of it, one per density level, so "how
    /// developed is this?" reads at a glance instead of by comparing shades.
    /// Still graybox: circles, not art, same spirit as everything else
    /// `TileRenderer` draws.
    private static let pipNodeName = "densityPip"

    /// Removes and rebuilds a tile's pips from scratch every call, rather
    /// than diffing old vs. new count. Simpler, and cheap enough at 20×20
    /// (or even the larger `MapSize` options) that it isn't worth the extra
    /// bookkeeping a real diff would need.
    func syncPips(on node: SKSpriteNode, count: Int) {
        node.children.filter { $0.name == Self.pipNodeName }.forEach { $0.removeFromParent() }
        guard count > 0 else { return }

        let pipRadius = layout.spriteSize.width * 0.06
        let spacing = pipRadius * 3
        let totalWidth = CGFloat(count - 1) * spacing
        let y = -layout.spriteSize.height * 0.32

        for index in 0 ..< count {
            let pip = SKShapeNode(circleOfRadius: pipRadius)
            pip.name = Self.pipNodeName
            pip.fillColor = .white
            pip.strokeColor = .clear
            pip.alpha = 0.8
            pip.zPosition = 1
            pip.position = CGPoint(x: -totalWidth / 2 + CGFloat(index) * spacing, y: y)
            node.addChild(pip)
        }
    }

    /// Removes any pips a tile has — used when `GameScene` draws an overlay
    /// (land value, traffic) instead of normal zone colors, where a density
    /// count would just be visual noise on top of a different data channel.
    func clearPips(on node: SKSpriteNode) {
        node.children.filter { $0.name == Self.pipNodeName }.forEach { $0.removeFromParent() }
    }

    // MARK: - Zone icons

    private static let iconNodeName = "zoneIcon"

    /// Removes and rebuilds a tile's icon from scratch every call, same
    /// "simpler beats diffing" reasoning as `syncPips` — and necessary here
    /// for a reason pips don't have: `ZoneIcon` picks a different *shape*
    /// per growth tier, so the icon itself needs to change, not just be
    /// left alone, whenever density crosses a tier boundary. `ZoneIcon`
    /// authors every shape in a fixed `ZoneIcon.designSize`-point square, so
    /// scaling it to fit this specific node — whatever its actual
    /// `footprintSize` — is one division, not a per-icon concern.
    /// `seed` (a building's anchor position) picks which visual *variant*
    /// `ZoneIcon` draws when a tier has more than one — deterministic per
    /// building, so the same lot always renders the same look tick to
    /// tick, but two different lots at the same growth tier don't have to
    /// look pixel-identical.
    func syncIcon(on node: SKSpriteNode, zone: ZoneType, density: Int, footprintSize: Int, seed: GridPosition) {
        node.children.filter { $0.name == Self.iconNodeName }.forEach { $0.removeFromParent() }
        guard let icon = ZoneIcon.makeNode(for: zone, density: density, seed: seed) else { return }
        icon.name = Self.iconNodeName
        // A small margin so the icon doesn't touch the tile's own edges,
        // leaving a sliver of the base color visible as a border.
        let spriteWidth = layout.spriteSize(forFootprint: footprintSize).width
        icon.setScale(spriteWidth / ZoneIcon.designSize * 0.85)
        node.addChild(icon)
    }

    /// Removes a tile's icon — used alongside `clearPips` when `GameScene`
    /// draws an overlay instead of normal zone colors.
    func clearIcon(on node: SKSpriteNode) {
        node.children.filter { $0.name == Self.iconNodeName }.forEach { $0.removeFromParent() }
    }
}
