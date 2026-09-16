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

    /// Whether a decoration is already showing what the data says, keyed on
    /// whatever determines its appearance.
    ///
    /// **Not an optimisation — a correctness fix that has already been learned
    /// once.** `GameScene.refreshAll()` runs every decoration for every tile on
    /// every simulation tick. Without this, each tick tears down and rebuilds
    /// thousands of shape nodes and re-hangs every building sprite, which is
    /// precisely the churn CLAUDE.md records as "why the map blinked". The
    /// top-down renderer grew these keys after a live playtest surfaced it; the
    /// isometric one gets them before.
    private func isUpToDate(_ node: SKNode, _ name: String, _ key: String) -> Bool {
        node.userData?[name] as? String == key
    }

    private func markUpToDate(_ node: SKNode, _ name: String, _ key: String) {
        if node.userData == nil { node.userData = NSMutableDictionary() }
        node.userData?[name] = key
    }

    private func invalidate(_ node: SKNode, _ name: String) {
        node.userData?.removeObject(forKey: name)
    }

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
        let key = "\(tile.zone.rawValue)|\(tile.density)"
        guard !isUpToDate(node, Self.groundNodeName, key) else { return }
        markUpToDate(node, Self.groundNodeName, key)
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
        let tier = RenderPalette.growthTier(for: tile.density)
        let key = "\(tile.zone.rawValue)|\(tier)"
        guard !isUpToDate(node, Self.glowNodeName, key) else { return }
        markUpToDate(node, Self.glowNodeName, key)
        node.childNode(withName: Self.glowNodeName)?.removeFromParent()
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
        let show = tile.zone.maxDensity > 0 && RenderPalette.growthTier(for: tile.density) == 0
        let key = show ? tile.zone.rawValue : "none"
        guard !isUpToDate(node, Self.markerNodeName, key) else { return }
        markUpToDate(node, Self.markerNodeName, key)
        node.childNode(withName: Self.markerNodeName)?.removeFromParent()
        guard show else { return }

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
        let key = "\(tile.zone.rawValue)|\(tile.density)"
        guard !isUpToDate(node, Self.buildingNodeName, key) else { return }
        markUpToDate(node, Self.buildingNodeName, key)
        node.childNode(withName: Self.buildingNodeName)?.removeFromParent()
        guard let view else { return }
        guard let sprite = textures.sprite(
            for: tile.zone, density: tile.density, seed: tile.position, at: .zero, in: view
        ) else { return }
        sprite.name = Self.buildingNodeName
        sprite.zPosition = 0.3
        node.addChild(sprite)
    }

    // MARK: - Overlays

    /// Paint a tile as a flat data channel instead of as a building.
    ///
    /// **One call, not ten.** `GameScene`'s top-down overlay handling repeats a
    /// block of ten `clear…` calls in each of five branches, and every
    /// decoration added since has had to be remembered in all five — which is
    /// exactly the kind of repetition that goes stale silently, because a
    /// forgotten line leaves a stray building icon floating over a heatmap
    /// rather than failing anything. An overlay is one idea: hide everything
    /// that describes the *building* and tint the ground.
    func applyOverlay(on node: SKNode, color: SKColor) {
        for name in [Self.glowNodeName, Self.markerNodeName, Self.buildingNodeName,
                     Self.laneNodeName, Self.warningNodeName, Self.damageNodeName] {
            node.childNode(withName: name)?.removeFromParent()
            // Invalidated, not just removed: the cache key is what decides
            // whether a decoration gets rebuilt, so leaving a stale key behind
            // would mean switching back to Normal view restored nothing.
            invalidate(node, name)
        }
        // The ground is recoloured rather than rebuilt, so its own key has to
        // go too or the tint would survive leaving the overlay.
        invalidate(node, Self.groundNodeName)
        (node.childNode(withName: Self.groundNodeName) as? SKShapeNode)?.fillColor = color
    }

    // MARK: - Markers

    private static let warningNodeName = "isoWarning"
    private static let damageNodeName = "isoDamage"
    private static let pipeNodeName = "isoPipe"
    private static let powerNodeName = "isoPowerLine"

    /// A badge floating above a building that has outgrown its utilities.
    ///
    /// Placed above the building's own height rather than at a fixed corner
    /// offset. In elevation every icon was the same size, so a corner badge
    /// always landed clear of it; here a tier-3 tower is three times the height
    /// of a tier-1 shed, and a fixed offset would bury the warning inside the
    /// building it is about.
    func syncUtilityWarning(on node: SKNode, tile: Tile, hasWaterSupply: Bool, hasPowerSupply: Bool) {
        let key = "\(tile.zone.rawValue)|\(tile.density)|\(hasWaterSupply)|\(hasPowerSupply)"
        guard !isUpToDate(node, Self.warningNodeName, key) else { return }
        markUpToDate(node, Self.warningNodeName, key)
        node.childNode(withName: Self.warningNodeName)?.removeFromParent()
        let missingWater = tile.density >= CitySimulator.waterRequiredFromLevel - 1 && !hasWaterSupply
        let missingPower = tile.density >= CitySimulator.powerRequiredFromLevel - 1 && !hasPowerSupply
        guard missingWater || missingPower else { return }

        let size = CGFloat(tile.zone.footprintSize)
        let container = SKNode()
        container.name = Self.warningNodeName
        container.position = projection.project(size / 2, size / 2, buildingTop(of: tile) + 0.4)
        container.zPosition = 0.6

        let radius = max(5, projection.tileWidth * 0.1)
        var badges: [(CGFloat, SKColor)] = []
        if missingWater { badges.append((0, RenderPalette.waterColor(for: true))) }
        if missingPower { badges.append((0, RenderPalette.powerColor(for: true))) }
        if badges.count == 2 {
            badges[0].0 = -radius * 1.1
            badges[1].0 = radius * 1.1
        }
        for (x, color) in badges {
            let disc = SKShapeNode(circleOfRadius: radius)
            disc.position = CGPoint(x: x, y: 0)
            disc.fillColor = ZoneIcon.silhouetteFill
            disc.strokeColor = color
            disc.lineWidth = 2
            disc.glowWidth = 2
            container.addChild(disc)
            container.addChild(ZoneIcon.detail(
                rect: CGRect(x: x - radius * 0.13, y: -radius * 0.45,
                             width: radius * 0.26, height: radius * 0.9),
                fill: color
            ))
        }
        node.addChild(container)
    }

    /// A struck block, waiting for the service that would repair it.
    ///
    /// Deliberately louder than the utility badge, for the reason the top-down
    /// version documents: a missing pipe is a ceiling on growth the player can
    /// take their time over, while damage has actually stopped the block
    /// working. So the whole lot darkens as well — a visible hole in the city
    /// rather than a detail to notice — and the badge is tinted with the colour
    /// of the service being waited on, so it also says what to build.
    func syncDamageMarker(on node: SKNode, tile: Tile, damagedBy: ZoneType?) {
        let key = "\(tile.zone.rawValue)|\(damagedBy?.rawValue ?? "none")"
        guard !isUpToDate(node, Self.damageNodeName, key) else { return }
        markUpToDate(node, Self.damageNodeName, key)
        node.childNode(withName: Self.damageNodeName)?.removeFromParent()
        guard let service = damagedBy else { return }

        let size = CGFloat(tile.zone.footprintSize)
        let container = SKNode()
        container.name = Self.damageNodeName
        container.zPosition = 0.55

        let scrim = SKShapeNode(path: projection.tileDiamond(x: 0, y: 0, size: size, inset: 0.02))
        scrim.fillColor = .black
        scrim.strokeColor = .clear
        scrim.alpha = 0.55
        container.addChild(scrim)

        let color = RenderPalette.fullColor(for: service)
        let badgeSize = projection.tileWidth * 0.26
        let centre = projection.project(size / 2, size / 2, buildingTop(of: tile) * 0.6)
        let badge = SKShapeNode(rectOf: CGSize(width: badgeSize, height: badgeSize),
                                cornerRadius: badgeSize * 0.18)
        badge.fillColor = .black
        badge.strokeColor = color
        badge.lineWidth = 2
        badge.glowWidth = 1.5
        badge.position = centre
        container.addChild(badge)

        let arm = badgeSize * 0.3
        let cross = CGMutablePath()
        cross.move(to: CGPoint(x: centre.x - arm, y: centre.y - arm))
        cross.addLine(to: CGPoint(x: centre.x + arm, y: centre.y + arm))
        cross.move(to: CGPoint(x: centre.x - arm, y: centre.y + arm))
        cross.addLine(to: CGPoint(x: centre.x + arm, y: centre.y - arm))
        let mark = SKShapeNode(path: cross)
        mark.strokeColor = color
        mark.lineWidth = 2
        container.addChild(mark)
        node.addChild(container)
    }

    /// Underground networks, drawn only in their own overlay — the one place a
    /// pipe or a power line is visible at all.
    func syncBuriedMarker(on node: SKNode, tile: Tile, present: Bool, isPipe: Bool) {
        let name = isPipe ? Self.pipeNodeName : Self.powerNodeName
        let key = "\(tile.zone.rawValue)|\(present)"
        guard !isUpToDate(node, name, key) else { return }
        markUpToDate(node, name, key)
        node.childNode(withName: name)?.removeFromParent()
        guard present else { return }

        let size = CGFloat(tile.zone.footprintSize)
        let marker = SKShapeNode(path: projection.tileDiamond(x: 0, y: 0, size: size, inset: 0.32))
        marker.name = name
        marker.fillColor = (isPipe ? RenderPalette.pipeMarkerColor : RenderPalette.powerLineMarkerColor)
            .withAlphaComponent(0.9)
        marker.strokeColor = .clear
        marker.zPosition = 0.5
        node.addChild(marker)
    }

    /// How tall the building on a tile stands, in tile units — needed to put
    /// anything *above* it.
    private func buildingTop(of tile: Tile) -> CGFloat {
        guard let massing = ZoneMassing.make(
            for: tile.zone, density: tile.density,
            seed: BuildingTextureCache.canonicalSeed(for: BuildingTextureCache.variant(for: tile.position))
        ) else { return 0 }
        return massing.solids.reduce(CGFloat(0)) { result, solid in
            switch solid.volume {
            case .box(let box): return max(result, box.z + box.height)
            case .ridge(let ridge): return max(result, ridge.z + ridge.height)
            case .cylinder(let cylinder): return max(result, cylinder.z + cylinder.height)
            }
        }
    }

    /// The footprint outline shown under the cursor while a tool is armed.
    func placementPreview(at origin: GridPosition, footprint: Int, color: SKColor) -> SKNode {
        let outline = SKShapeNode(path: projection.tileDiamond(
            x: 0, y: 0, size: CGFloat(footprint), inset: 0.04
        ))
        outline.strokeColor = color
        outline.lineWidth = 2.5
        outline.glowWidth = 2
        outline.fillColor = color.withAlphaComponent(0.16)
        outline.position = projection.project(CGFloat(origin.x), CGFloat(origin.y), 0)
        return outline
    }

    /// A one-shot coloured pulse over a lot.
    ///
    /// **Why an added node rather than `SKAction.colorize`.** The top-down
    /// renderer flashed a tile by colorizing its `SKSpriteNode` and animating
    /// back to whatever colour it should be. `colorize` only affects sprites,
    /// and an isometric tile node is a plain `SKNode` holding a ground shape —
    /// so the three flashes (insufficient funds, blocked placement, hazard)
    /// kept compiling and silently stopped doing anything, which is the worst
    /// way for player feedback to break. A diamond that fades out needs no
    /// restore colour, works on any node, and cannot go quietly dead.
    func flash(on node: SKNode, tile: Tile, color: SKColor, duration: TimeInterval) {
        node.childNode(withName: Self.flashNodeName)?.removeFromParent()
        let size = CGFloat(tile.zone.footprintSize)
        let pulse = SKShapeNode(path: projection.tileDiamond(x: 0, y: 0, size: size, inset: 0.02))
        pulse.name = Self.flashNodeName
        pulse.fillColor = color
        pulse.strokeColor = color
        pulse.lineWidth = 2
        pulse.glowWidth = 3
        pulse.alpha = 0.85
        pulse.zPosition = 0.8
        node.addChild(pulse)
        pulse.run(.sequence([
            .wait(forDuration: duration * 0.25),
            .fadeOut(withDuration: duration * 0.75),
            .removeFromParent(),
        ]))
    }

    private static let flashNodeName = "isoFlash"

    // MARK: - Roads

    /// A glowing centre line along each direction a road connects in.
    ///
    /// Drawn from the tile's centre out to the midpoint of each connected
    /// edge, so a straight run joins seamlessly and a junction reads as a
    /// junction without any tile needing to know more than its own neighbours.
    func syncLaneLine(on node: SKNode, zone: ZoneType, connections: Traffic.RoadConnections) {
        let key = "\(zone.rawValue)|\(connections.north)\(connections.south)\(connections.east)\(connections.west)"
        guard !isUpToDate(node, Self.laneNodeName, key) else { return }
        markUpToDate(node, Self.laneNodeName, key)
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
