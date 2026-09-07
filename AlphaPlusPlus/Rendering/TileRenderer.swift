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

    /// A bright line down the center of a road/highway tile, oriented
    /// along the street's own direction — the literal "glowing lane
    /// marking" a synthwave highway is drawn with, on top of the tile's
    /// own dark asphalt-purple base (`RenderPalette.fullColor(for:)`).
    /// Colored via `RenderPalette.networkAccentColor(for:)`, the same
    /// value `syncNetworkGlow` tints its bleed with, so the line and its
    /// own glow always agree.
    ///
    /// `horizontal` is a plain `Bool`, not something this method computes
    /// itself: answering "which way does this road run" needs
    /// `Traffic.isHorizontallyOriented(at:in:)`, which needs the whole
    /// `CityMap` to check neighbors — more than the single `Tile` this
    /// file otherwise works from. `GameScene` already computes that exact
    /// answer once per tile for the ambient traffic-car animation
    /// (`syncTrafficAnimation`), so it just passes it along here instead
    /// of this file taking on a `Simulation/` dependency of its own.
    func syncLaneLine(on node: SKSpriteNode, zone: ZoneType, horizontal: Bool) {
        node.childNode(withName: Self.laneLineNodeName)?.removeFromParent()
        guard zone == .road || zone == .highway else { return }

        let thickness: CGFloat = zone == .highway ? 5 : 3
        let length = layout.spriteSize.width * 0.9
        let size = horizontal ? CGSize(width: length, height: thickness) : CGSize(width: thickness, height: length)
        let line = SKShapeNode(rectOf: size)
        line.name = Self.laneLineNodeName
        line.fillColor = RenderPalette.networkAccentColor(for: zone)
        line.strokeColor = .clear
        line.zPosition = 1
        node.addChild(line)
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

    func syncBuildingShadow(on node: SKSpriteNode, zone: ZoneType, density: Int, footprintSize: Int, seed: GridPosition) {
        node.children.filter { $0.name == Self.buildingShadowNodeName }.forEach { $0.removeFromParent() }
        guard let icon = ZoneIcon.makeNode(for: zone, density: density, seed: seed) else { return }
        icon.name = Self.buildingShadowNodeName
        icon.alpha = Self.shadowAlpha
        let spriteWidth = layout.spriteSize(forFootprint: footprintSize).width
        icon.setScale(spriteWidth / ZoneIcon.designSize * 0.85)
        node.addChild(icon)
    }

    /// Removes a tile's building shadow — used alongside `clearIcon` for
    /// every overlay except Water/Power.
    func clearBuildingShadow(on node: SKSpriteNode) {
        node.children.filter { $0.name == Self.buildingShadowNodeName }.forEach { $0.removeFromParent() }
    }
}
