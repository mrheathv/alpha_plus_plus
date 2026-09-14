import SpriteKit
import CoreGraphics

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
        syncNetworkGlow(on: node, zone: tile.zone)
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
        syncNetworkGlow(on: node, zone: tile.zone)
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

    /// The (zone, density) a node's current icon was last built for,
    /// stashed in `SKNode.userData` so `syncIcon` can tell "nothing
    /// actually changed" apart from "this tile grew/decayed/re-zoned" —
    /// see `syncIcon`'s own doc comment for why that distinction matters
    /// enough to track.
    private static let iconCacheKey = "iconCacheKey"

    /// Rebuilds a tile's icon *only* when its (zone, density) actually
    /// changed since the last call — checked via `iconCacheKey` — rather
    /// than unconditionally tearing it down and remaking it every call the
    /// way this used to work. That used to mean every simulation tick threw
    /// away and recreated *every* building's icon on the map, including its
    /// `ZoneIcon.withGlow` layer — an `SKEffectNode` with
    /// `shouldRasterize = true`, whose entire point is to cache a Core Image
    /// blur pass across frames. Recreating that node from scratch every tick
    /// defeated the cache completely: a brand new, unrasterized effect node
    /// for every building, every tick, forcing a fresh Gaussian blur pass
    /// each time and reading as exactly the flicker a live playtest
    /// surfaced once a city had enough buildings (and enough simultaneous
    /// blur passes) for that per-tick rebuild to cost a visible frame or
    /// more. `ZoneIcon` picks a different *shape* per growth tier and
    /// nothing else ever changes an icon's look, so (zone, density) is a
    /// complete cache key — `seed` (picking a building's visual variant)
    /// is fixed for a given tile's whole lifetime, never a reason to rebuild
    /// on its own.
    func syncIcon(on node: SKSpriteNode, zone: ZoneType, density: Int, footprintSize: Int, seed: GridPosition) {
        let cacheKey = "\(zone.rawValue)-\(density)"
        if node.userData?[Self.iconCacheKey] as? String == cacheKey { return }

        node.children.filter { $0.name == Self.iconNodeName }.forEach { $0.removeFromParent() }
        if let icon = ZoneIcon.makeNode(for: zone, density: density, seed: seed) {
            icon.name = Self.iconNodeName
            Self.fitIconToTile(icon, footprintSize: footprintSize, layout: layout)
            node.addChild(icon)
        }
        if node.userData == nil { node.userData = NSMutableDictionary() }
        node.userData?[Self.iconCacheKey] = cacheKey
    }

    /// How much smaller than an exact edge-to-edge fit an icon is scaled —
    /// a hair of breathing room so neighboring buildings' glow doesn't
    /// perfectly z-fight along shared tile edges, not the kind of margin
    /// that reads as "a small building on an empty lot."
    static let iconFillFactor: CGFloat = 0.98

    /// Not `private`: `ZoneIconContactSheetTests` renders the icon
    /// catalog through this exact function, so the contact sheet shows
    /// the same fill the game does rather than a reimplementation that
    /// could quietly drift away from it.
    ///
    /// Scales `icon` so its *actual drawn silhouette* — measured directly
    /// via `calculateAccumulatedFrame()`, not assumed from `ZoneIcon.designSize` —
    /// fills the tile it sits on, edge to edge.
    ///
    /// Every `ZoneIcon` shape is authored inside a fixed `designSize`
    /// square, but few of them actually *use* the whole square — a
    /// `towerIcon` body is under half as wide as the square it's drawn in,
    /// the rest left as headroom for a roofline, a projecting sign, a
    /// glow's soft edge. Scaling by a flat `spriteWidth / designSize`
    /// (this file's old approach) treated every icon as if it filled that
    /// whole square, so most buildings rendered as a small icon floating
    /// in a lot-sized field of bare tile color — especially visible once
    /// `ZoneType.footprintSize` made ordinary buildings 2×2, not 1×1: a
    /// real city block's worth of empty color around what should read as
    /// a building filling its lot. Measuring the icon's own accumulated
    /// frame and fitting *that* to the tile (aspect-fit, so nothing
    /// overflows past the footprint in either axis) makes every icon claim
    /// as much of its actual lot as its own silhouette proportions allow,
    /// without this file needing to know or care what those proportions
    /// are for any given building.
    static func fitIconToTile(_ icon: SKNode, footprintSize: Int, layout: GridLayout) {
        let spriteSize = layout.spriteSize(forFootprint: footprintSize)
        let occupied = icon.calculateAccumulatedFrame().size
        let fitScale = min(spriteSize.width / max(occupied.width, 1), spriteSize.height / max(occupied.height, 1))
        icon.setScale(fitScale * iconFillFactor)
    }

    /// Removes a tile's icon — used alongside `clearPips` when `GameScene`
    /// draws an overlay instead of normal zone colors. Also clears the
    /// cache key `syncIcon` checks, so switching back out of an overlay
    /// always rebuilds the icon it just tore down rather than seeing an
    /// unchanged (zone, density) and leaving the tile bare.
    func clearIcon(on node: SKSpriteNode) {
        node.children.filter { $0.name == Self.iconNodeName }.forEach { $0.removeFromParent() }
        node.userData?.removeObject(forKey: Self.iconCacheKey)
    }

    // MARK: - Network glow (roads, highways, pipes)

    private static let glowNodeName = "networkGlow"

    /// A soft radial-gradient sprite, white fading to transparent, generated
    /// once via `CGContext`/`CGGradient` and cached — not per-tile, and not
    /// via `SKEffectNode`/`CIGaussianBlur` the way `ZoneIcon`'s building
    /// glow works. Roads/highways/pipes can cover a large fraction of the
    /// map (far more tiles than the handful of buildings that ever get a
    /// blur pass), so a real per-tile Core Image blur here would be a real
    /// frame-rate risk. Tinting one shared white texture and additively
    /// blending it (`syncNetworkGlow`) gets the same "glowing" read at a
    /// fraction of the cost: one extra cheap sprite draw per network tile,
    /// no per-frame filter evaluation, and SpriteKit batches plain textured
    /// sprites efficiently even by the hundreds.
    private static let glowTexture: SKTexture = {
        let diameter = 64
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: diameter, height: diameter, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return SKTexture() }

        let components: [CGFloat] = [1, 1, 1, 0.85, 1, 1, 1, 0]
        guard let gradient = CGGradient(colorSpace: colorSpace, colorComponents: components, locations: [0, 1], count: 2) else {
            return SKTexture()
        }
        let center = CGPoint(x: CGFloat(diameter) / 2, y: CGFloat(diameter) / 2)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: CGFloat(diameter) / 2, options: [])

        guard let image = context.makeImage() else { return SKTexture() }
        return SKTexture(cgImage: image)
    }()

    /// Adds (or removes) the soft glow behind a road/highway tile, tinted
    /// that zone's own `RenderPalette.networkAccentColor(for:)` — the
    /// same lane-line color `syncLaneLine` draws on top of the tile, so
    /// the glow reads as light spilling from that line, not from the dark
    /// asphalt base itself. `.add` blend mode means overlapping glow from
    /// adjacent network tiles brightens rather than just stacking flat
    /// color on top of itself — a straight run of road reads as one
    /// continuous brighter seam, exactly the "glowing grid line" look,
    /// without any of the tiles needing to know about their neighbors.
    /// Sized a bit larger than the tile itself so that brightening bleeds
    /// across tile edges instead of stopping dead at each tile's own
    /// boundary; drawn at a `zPosition` above the flat tile fills (but
    /// below density pips) so the bleed is actually visible over a
    /// neighboring tile's own color instead of being hidden behind it.
    ///
    /// Pipes don't get this — they're not a `ZoneType` any more (see
    /// `Tile.hasPipe`), so they have no surface color of their own to
    /// glow. `syncPipeMarker` is their equivalent, drawn only in the
    /// Water overlay instead of always-on.
    func syncNetworkGlow(on node: SKSpriteNode, zone: ZoneType) {
        node.childNode(withName: Self.glowNodeName)?.removeFromParent()
        guard zone == .road || zone == .highway else { return }

        let glow = SKSpriteNode(texture: Self.glowTexture)
        glow.name = Self.glowNodeName
        glow.color = RenderPalette.networkAccentColor(for: zone)
        glow.colorBlendFactor = 1
        glow.blendMode = .add
        glow.alpha = zone == .highway ? 0.8 : 0.55
        let base = layout.spriteSize(forFootprint: zone.footprintSize)
        glow.size = CGSize(width: base.width * 1.4, height: base.height * 1.4)
        glow.zPosition = 0.5
        node.addChild(glow)
    }

    /// Removes a tile's network glow — used alongside `clearPips`/`clearIcon`
    /// when `GameScene` draws an overlay instead of normal zone colors.
    func clearNetworkGlow(on node: SKSpriteNode) {
        node.childNode(withName: Self.glowNodeName)?.removeFromParent()
    }

    // MARK: - Lane line (roads/highways, Normal view only)

    private static let laneLineNodeName = "laneLine"

    /// A bright line down the center of a road/highway tile, shaped to
    /// match what's actually connected to it — a straight run, a 90°
    /// turn, a T-junction, a full 4-way crossroads, or a dead-end stub —
    /// instead of always a straight line through the tile regardless of
    /// its real neighbors. The literal "glowing lane marking" a synthwave
    /// street is drawn with, on top of the tile's own dark asphalt-purple
    /// base (`RenderPalette.fullColor(for:)`). Colored via
    /// `RenderPalette.networkAccentColor(for:)`, the same value
    /// `syncNetworkGlow` tints its bleed with, so the line and its own
    /// glow always agree.
    ///
    /// Built from up to four independent half-length segments, one per
    /// connected direction, each running from the tile's center out to
    /// that edge — a straight tile ends up with two segments (e.g. east +
    /// west) that together span the same full length the old always-one-
    /// piece line did, so an ordinary street reads exactly as it always
    /// has; a corner draws only the two connected segments, meeting at
    /// the center as an L; a T-junction draws three; a crossroads all
    /// four. `connections` is a plain `Traffic.RoadConnections`, not
    /// something this method computes itself — same reasoning `horizontal`
    /// used to document here: answering "what's actually connected to this
    /// tile" needs the whole `CityMap`, more than the single `Tile` this
    /// file otherwise works from, so `GameScene` computes it once per tile
    /// and passes it along instead of this file taking on a `Simulation/`
    /// dependency of its own.
    func syncLaneLine(on node: SKSpriteNode, zone: ZoneType, connections: Traffic.RoadConnections) {
        node.childNode(withName: Self.laneLineNodeName)?.removeFromParent()
        guard zone == .road || zone == .highway else { return }

        let thickness: CGFloat = zone == .highway ? 5 : 3
        let halfLength = layout.spriteSize.width * 0.45
        let color = RenderPalette.networkAccentColor(for: zone)

        let container = SKNode()
        container.name = Self.laneLineNodeName
        container.zPosition = 1

        func addSegment(dx: CGFloat, dy: CGFloat) {
            let size = dx == 0 ? CGSize(width: thickness, height: halfLength) : CGSize(width: halfLength, height: thickness)
            let segment = SKShapeNode(rectOf: size)
            segment.position = CGPoint(x: dx * halfLength / 2, y: dy * halfLength / 2)
            segment.fillColor = color
            segment.strokeColor = .clear
            container.addChild(segment)
        }

        if connections.north { addSegment(dx: 0, dy: 1) }
        if connections.south { addSegment(dx: 0, dy: -1) }
        if connections.east { addSegment(dx: 1, dy: 0) }
        if connections.west { addSegment(dx: -1, dy: 0) }

        node.addChild(container)
    }

    /// Removes a tile's lane line — used alongside `clearNetworkGlow` when
    /// `GameScene` draws an overlay instead of normal zone colors, or when
    /// a tile stops being a road/highway at all.
    func clearLaneLine(on node: SKSpriteNode) {
        node.childNode(withName: Self.laneLineNodeName)?.removeFromParent()
    }

    // MARK: - Pipe marker (Water overlay only)

    private static let pipeMarkerNodeName = "pipeMarker"

    /// A small square drawn on top of the Water overlay's own coloring
    /// wherever `Tile.hasPipe` is true — the one place a pipe is actually
    /// visible at all, now that it's an underground layer rather than a
    /// `ZoneType` with a tile color of its own. `GameScene` only calls
    /// this while `overlayMode == .water`; every other overlay (including
    /// Normal) calls `clearPipeMarker` instead, so pipes read as genuinely
    /// invisible infrastructure the rest of the time — the intuitively
    /// correct result for something buried underground, not just a
    /// rendering shortcut.
    func syncPipeMarker(on node: SKSpriteNode, hasPipe: Bool) {
        node.childNode(withName: Self.pipeMarkerNodeName)?.removeFromParent()
        guard hasPipe else { return }

        let marker = SKShapeNode(rectOf: CGSize(width: layout.spriteSize.width * 0.3, height: layout.spriteSize.height * 0.3))
        marker.name = Self.pipeMarkerNodeName
        marker.fillColor = RenderPalette.pipeMarkerColor
        marker.strokeColor = .clear
        marker.zPosition = 3
        node.addChild(marker)
    }

    /// Removes a tile's pipe marker — used alongside `clearPips`/`clearIcon`/
    /// `clearNetworkGlow` for every overlay except Water.
    func clearPipeMarker(on node: SKSpriteNode) {
        node.childNode(withName: Self.pipeMarkerNodeName)?.removeFromParent()
    }

    // MARK: - Power line marker (Power overlay only)

    private static let powerLineMarkerNodeName = "powerLineMarker"

    /// The exact same role `syncPipeMarker` plays for the Water overlay,
    /// one section up, for the parallel Power overlay and
    /// `Tile.hasPowerLine` — a small diamond rather than a square
    /// specifically so the two utility markers stay visually distinct
    /// from one another if either overlay ever needed to show both at
    /// once, not just via color.
    func syncPowerLineMarker(on node: SKSpriteNode, hasPowerLine: Bool) {
        node.childNode(withName: Self.powerLineMarkerNodeName)?.removeFromParent()
        guard hasPowerLine else { return }

        let side = layout.spriteSize.width * 0.22
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: side))
        path.addLine(to: CGPoint(x: side, y: 0))
        path.addLine(to: CGPoint(x: 0, y: -side))
        path.addLine(to: CGPoint(x: -side, y: 0))
        path.closeSubpath()

        let marker = SKShapeNode(path: path)
        marker.name = Self.powerLineMarkerNodeName
        marker.fillColor = RenderPalette.powerLineMarkerColor
        marker.strokeColor = .clear
        marker.zPosition = 3
        node.addChild(marker)
    }

    /// Removes a tile's power line marker — used alongside `clearPips`/
    /// `clearIcon`/`clearNetworkGlow`/`clearPipeMarker` for every overlay
    /// except Power.
    func clearPowerLineMarker(on node: SKSpriteNode) {
        node.childNode(withName: Self.powerLineMarkerNodeName)?.removeFromParent()
    }

    // MARK: - Utility warning (Normal view only)

    private static let utilityWarningNodeName = "utilityWarning"

    /// A small warning badge in a tile's corner for a building that's
    /// missing water and/or power it actually needs right now — the
    /// consequence a live playtest asked for. Without this, an
    /// unconnected building silently capped its own growth with nothing
    /// on the map to explain why short of switching to the Water or Power
    /// overlay and going looking for the gap. Two colors, not one, reusing
    /// the exact hues `RenderPalette.waterColor(for:)`/`powerColor(for:)`
    /// already use for "supplied" in their own overlays, so which utility
    /// is missing is legible at a glance to anyone who's used those
    /// overlays even once — both badges show if both are missing.
    ///
    /// `density` is only "missing" a utility once `CitySimulator` would
    /// actually check for it (`waterRequiredFromLevel`/
    /// `powerRequiredFromLevel`) — a brand-new tier-1 lot hasn't earned the
    /// right to need water yet, so warning it here would be a false alarm
    /// for a building that isn't actually stuck on anything.
    func syncUtilityWarning(on node: SKSpriteNode, density: Int, hasWaterSupply: Bool, hasPowerSupply: Bool) {
        node.children.filter { $0.name == Self.utilityWarningNodeName }.forEach { $0.removeFromParent() }

        let missingWater = density >= CitySimulator.waterRequiredFromLevel - 1 && !hasWaterSupply
        let missingPower = density >= CitySimulator.powerRequiredFromLevel - 1 && !hasPowerSupply
        guard missingWater || missingPower else { return }

        let badgeSize = layout.spriteSize.width * 0.22
        let cornerY = layout.spriteSize.height * 0.5 - badgeSize * 0.6
        if missingWater {
            let x = missingPower ? -badgeSize * 0.6 : 0
            node.addChild(utilityWarningBadge(at: CGPoint(x: x, y: cornerY), size: badgeSize, color: RenderPalette.waterColor(for: true)))
        }
        if missingPower {
            let x = missingWater ? badgeSize * 0.6 : 0
            node.addChild(utilityWarningBadge(at: CGPoint(x: x, y: cornerY), size: badgeSize, color: RenderPalette.powerColor(for: true)))
        }
    }

    /// Removes a tile's utility warning badge(s) — used alongside
    /// `clearPips`/`clearIcon` when `GameScene` draws an overlay instead of
    /// Normal view; the Water/Power overlays already have their own,
    /// bigger signal for this (the tile's own supply-state color), so a
    /// small corner badge on top would just be redundant there.
    func clearUtilityWarning(on node: SKSpriteNode) {
        node.children.filter { $0.name == Self.utilityWarningNodeName }.forEach { $0.removeFromParent() }
    }

    /// One warning badge: a dark triangle outlined in `color`, with a
    /// small exclamation mark (a rect and a dot, this file's usual
    /// straight-lines-and-circles-only shape vocabulary) in the same
    /// color — legible as "warning," not just "a colored dot," even at a
    /// badge this small.
    private func utilityWarningBadge(at center: CGPoint, size: CGFloat, color: SKColor) -> SKNode {
        let half = size / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x, y: center.y + half))
        path.addLine(to: CGPoint(x: center.x - half, y: center.y - half))
        path.addLine(to: CGPoint(x: center.x + half, y: center.y - half))
        path.closeSubpath()

        let triangle = SKShapeNode(path: path)
        triangle.fillColor = SKColor.black.withAlphaComponent(0.8)
        triangle.strokeColor = color
        triangle.lineWidth = 1.5

        let mark = SKShapeNode(rect: CGRect(x: center.x - size * 0.06, y: center.y - half * 0.45, width: size * 0.12, height: size * 0.35))
        mark.fillColor = color
        mark.strokeColor = .clear

        let dot = SKShapeNode(circleOfRadius: size * 0.07)
        dot.position = CGPoint(x: center.x, y: center.y - half * 0.6)
        dot.fillColor = color
        dot.strokeColor = .clear

        let container = SKNode()
        container.name = Self.utilityWarningNodeName
        container.zPosition = 4
        container.addChild(triangle)
        container.addChild(mark)
        container.addChild(dot)
        return container
    }

    // MARK: - Building shadow (Water/Power overlays only)

    private static let buildingShadowNodeName = "buildingShadow"

    /// A dimmed copy of a building's own icon, drawn in the Water/Power
    /// overlays in place of `syncIcon`'s full-brightness one — the fix for
    /// a real gap a live play session found: those two overlays recolor
    /// every tile by supply state and `clearIcon` away whatever building
    /// sat there, which is exactly correct for *reading the supply data*
    /// but leaves you unable to see which tiles have a building on them at
    /// all while you're the one laying pipe or power line to them. This
    /// reuses `ZoneIcon.makeNode` — same silhouette Normal view draws, not
    /// a second art asset to keep in sync — just faded low enough
    /// (`shadowAlpha`) to read as "a building sits here" without fighting
    /// the supply-color coding underneath it, which stays the overlay's
    /// main signal. `.empty`/`.road`/`.highway` all return `nil` from
    /// `ZoneIcon.makeNode` already (nothing to shadow), so this needs no
    /// zone filtering of its own beyond that.
    private static let shadowAlpha: CGFloat = 0.35
    private static let shadowCacheKey = "buildingShadowCacheKey"

    /// Same (zone, density) cache-key check `syncIcon` uses, and for the
    /// same reason — this draws through the same `ZoneIcon.makeNode`, glow
    /// pass included, so rebuilding it unconditionally every tick would
    /// reintroduce the exact per-tick re-blur cost/flicker `syncIcon`'s own
    /// doc comment describes, just while a Water/Power overlay is open
    /// instead of Normal view.
    func syncBuildingShadow(on node: SKSpriteNode, zone: ZoneType, density: Int, footprintSize: Int, seed: GridPosition) {
        let cacheKey = "\(zone.rawValue)-\(density)"
        if node.userData?[Self.shadowCacheKey] as? String == cacheKey { return }

        node.children.filter { $0.name == Self.buildingShadowNodeName }.forEach { $0.removeFromParent() }
        if let icon = ZoneIcon.makeNode(for: zone, density: density, seed: seed) {
            icon.name = Self.buildingShadowNodeName
            icon.alpha = Self.shadowAlpha
            Self.fitIconToTile(icon, footprintSize: footprintSize, layout: layout)
            node.addChild(icon)
        }
        if node.userData == nil { node.userData = NSMutableDictionary() }
        node.userData?[Self.shadowCacheKey] = cacheKey
    }

    /// Removes a tile's building shadow — used alongside `clearIcon` for
    /// every overlay except Water/Power. Also clears the cache key
    /// `syncBuildingShadow` checks, so leaving Water/Power and coming back
    /// always rebuilds rather than seeing an unchanged (zone, density) and
    /// leaving the tile bare — the same reasoning `clearIcon` documents.
    func clearBuildingShadow(on node: SKSpriteNode) {
        node.children.filter { $0.name == Self.buildingShadowNodeName }.forEach { $0.removeFromParent() }
        node.userData?.removeObject(forKey: Self.shadowCacheKey)
    }
}
