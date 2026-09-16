import SpriteKit

/// Turns `Tile` data into isometric nodes — the counterpart of `TileRenderer`,
/// and eventually its replacement.
///
/// One node per building anchor, carrying its ground, its light and its
/// building, with a `zPosition` that puts it in the painter's-algorithm order
/// an isometric scene needs. `GameScene` keeps its existing structure: a
/// dictionary of tile nodes, a region rebuild, and a refresh — only what each
/// node contains changes.
struct IsoTileRenderer {

    let projection: Isometric
    let textures: BuildingTextureCache

    private static let groundNodeName = "isoGround"
    private static let glowNodeName = "isoGroundGlow"
    private static let markerNodeName = "isoZoneMarker"
    private static let buildingNodeName = "isoBuilding"
    private static let laneNodeName = "isoLane"

    init(projection: Isometric, textures: BuildingTextureCache? = nil) {
        self.projection = projection
        self.textures = textures ?? BuildingTextureCache(projection: projection)
    }

    /// The node for one building anchor, covering its whole footprint.
    ///
    /// `zPosition` is the painter's-algorithm key rather than a sort of the
    /// parent's children: `GameScene.rebuildRegion` adds and removes nodes in a
    /// small window without touching the rest, and re-sorting a whole tile
    /// layer per placement would undo the saving that exists for.
    func makeNode(for tile: Tile, in view: SKView?) -> SKNode {
        let footprint = tile.zone.footprintSize
        let node = SKNode()
        node.name = Self.nodeName(for: tile.position)
        node.position = projection.project(CGFloat(tile.position.x), CGFloat(tile.position.y), 0)
        node.zPosition = Isometric.depth(of: tile.position, footprint: footprint)
        update(node, for: tile, in: view)
        return node
    }

    /// Re-sync an existing node to current tile data, mutating rather than
    /// rebuilding — the same reasoning `TileRenderer.update` documents.
    func update(_ node: SKNode, for tile: Tile, in view: SKView?) {
        syncGround(on: node, tile: tile)
        syncGroundGlow(on: node, tile: tile)
        syncZoneMarker(on: node, tile: tile)
        syncBuilding(on: node, tile: tile, in: view)
    }

    static func nodeName(for position: GridPosition) -> String { "iso-\(position.x)-\(position.y)" }

    // MARK: - Ground

    /// The lot itself: one diamond covering the whole footprint, not one per
    /// cell. A 2×2 building stands on a single 2×2 diamond, so its ground has
    /// no seams running through it.
    private func syncGround(on node: SKNode, tile: Tile) {
        node.childNode(withName: Self.groundNodeName)?.removeFromParent()
        let size = CGFloat(tile.zone.footprintSize)
        let ground = SKShapeNode(path: projection.tileDiamond(x: 0, y: 0, size: size, inset: 0.02))
        ground.name = Self.groundNodeName
        ground.fillColor = RenderPalette.color(for: tile.zone, density: tile.density)
        ground.strokeColor = RenderPalette.ground.blended(withFraction: 0.28, of: .white) ?? .clear
        ground.lineWidth = 0.7
        ground.zPosition = 0
        node.addChild(ground)
    }

    /// The pool of light a building throws on the ground it stands on — the
    /// same additive trick the top-down renderer uses, and the thing that
    /// carries zone identity when the camera is far enough out that the
    /// silhouette has stopped resolving.
    private func syncGroundGlow(on node: SKNode, tile: Tile) {
        node.childNode(withName: Self.glowNodeName)?.removeFromParent()
        let tier = RenderPalette.growthTier(for: tile.density)
        guard tile.zone != .empty, tile.zone != .road, tile.zone != .highway else { return }
        guard tile.zone.maxDensity == 0 || tier > 0 else { return }

        let glow = SKSpriteNode(texture: TileRenderer.sharedGlowTexture)
        glow.name = Self.glowNodeName
        glow.color = ZoneMassing.accent(for: tile.zone, density: tile.density)
        glow.colorBlendFactor = 1
        glow.blendMode = .add
        glow.alpha = tile.zone.maxDensity > 0 ? 0.13 + 0.05 * CGFloat(tier) : 0.28
        let size = CGFloat(tile.zone.footprintSize)
        glow.size = CGSize(width: projection.tileWidth * size * 1.7,
                           height: projection.tileHeight * size * 1.7)
        glow.position = projection.project(size / 2, size / 2, 0)
        glow.zPosition = 0.1
        node.addChild(glow)
    }

    /// Corner ticks on a lot you have zoned but which has not grown anything
    /// yet — the surveyed-lot mark, in isometric.
    private func syncZoneMarker(on node: SKNode, tile: Tile) {
        node.childNode(withName: Self.markerNodeName)?.removeFromParent()
        guard tile.zone.maxDensity > 0, RenderPalette.growthTier(for: tile.density) == 0 else { return }

        let size = CGFloat(tile.zone.footprintSize)
        let inset: CGFloat = 0.16
        let arm: CGFloat = 0.3
        let path = CGMutablePath()
        for (cx, cy) in [(inset, inset), (size - inset, inset), (inset, size - inset), (size - inset, size - inset)] {
            let towardX: CGFloat = cx < size / 2 ? 1 : -1
            let towardY: CGFloat = cy < size / 2 ? 1 : -1
            path.move(to: projection.project(cx + towardX * arm, cy, 0))
            path.addLine(to: projection.project(cx, cy, 0))
            path.addLine(to: projection.project(cx, cy + towardY * arm, 0))
        }
        let marker = SKShapeNode(path: path)
        marker.name = Self.markerNodeName
        marker.strokeColor = RenderPalette.tierColor(for: tile.zone, tier: 1)
        marker.lineWidth = 2
        marker.glowWidth = 1
        marker.alpha = 0.85
        marker.zPosition = 0.2
        node.addChild(marker)
    }

    // MARK: - Building

    private func syncBuilding(on node: SKNode, tile: Tile, in view: SKView?) {
        node.childNode(withName: Self.buildingNodeName)?.removeFromParent()
        guard let view else { return }
        guard let sprite = textures.sprite(
            for: tile.zone, density: tile.density, seed: tile.position, at: .zero, in: view
        ) else { return }
        sprite.name = Self.buildingNodeName
        sprite.zPosition = 0.3
        node.addChild(sprite)
    }

    // MARK: - Roads

    /// A glowing centre line along each direction a road connects in.
    ///
    /// Drawn from the tile's centre out to the midpoint of each connected
    /// edge, so a straight run joins seamlessly and a junction reads as a
    /// junction without any tile needing to know more than its own neighbours.
    func syncLaneLine(on node: SKNode, zone: ZoneType, connections: Traffic.RoadConnections) {
        node.childNode(withName: Self.laneNodeName)?.removeFromParent()
        guard zone == .road || zone == .highway else { return }

        let path = CGMutablePath()
        let centre = projection.project(0.5, 0.5, 0)
        var drew = false
        func arm(_ x: CGFloat, _ y: CGFloat) {
            path.move(to: centre)
            path.addLine(to: projection.project(x, y, 0))
            drew = true
        }
        if connections.east { arm(1, 0.5) }
        if connections.west { arm(0, 0.5) }
        if connections.north { arm(0.5, 1) }
        if connections.south { arm(0.5, 0) }
        // An isolated stub still needs a mark, or a lone road tile is invisible.
        if !drew { arm(1, 0.5); arm(0, 0.5) }

        let lane = SKShapeNode(path: path)
        lane.name = Self.laneNodeName
        lane.strokeColor = RenderPalette.networkAccentColor(for: zone)
        lane.lineWidth = zone == .highway ? 3 : 2
        lane.glowWidth = zone == .highway ? 3 : 2
        lane.alpha = 0.9
        lane.zPosition = 0.25
        node.addChild(lane)
    }
}
