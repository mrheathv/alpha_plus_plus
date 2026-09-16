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
        syncGroundGlow(on: node, zone: tile.zone, density: tile.density, footprintSize: footprintSize)
        syncZoneMarker(on: node, zone: tile.zone, density: tile.density, footprintSize: footprintSize)
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
        syncGroundGlow(on: node, zone: tile.zone, density: tile.density, footprintSize: tile.zone.footprintSize)
        syncZoneMarker(on: node, zone: tile.zone, density: tile.density, footprintSize: tile.zone.footprintSize)
        syncIcon(on: node, zone: tile.zone, density: tile.density, footprintSize: tile.zone.footprintSize, seed: tile.position)
        syncNetworkGlow(on: node, zone: tile.zone)
    }

    static func nodeName(for position: GridPosition) -> String {
        "tile-\(position.x)-\(position.y)"
    }

    // MARK: - Ground glow

    private static let groundGlowNodeName = "groundGlow"
    private static let groundGlowCacheKey = "groundGlowCacheKey"

    /// The pool of light a building throws onto the ground it stands on.
    ///
    /// **Why this earns its draw call.** `RenderPalette` moved zone identity
    /// out of a flat tile fill and into light, which only works if there is
    /// actually light. A neon-stroked silhouette on near-black ground reads
    /// as a sticker; the same silhouette sitting in a pool of its own colour
    /// reads as a lit object standing on wet asphalt at night, which is the
    /// entire retrowave reference. It is also what carries zone identity when
    /// the camera is far enough out that the building is twenty points across
    /// and its silhouette has stopped being legible — the colour survives long
    /// after the shape does.
    ///
    /// Reuses `glowTexture` and the additive-blend trick `syncNetworkGlow`
    /// documents rather than an `SKEffectNode`, for exactly the same reason:
    /// one cheap tinted sprite per developed lot, batched by SpriteKit, with
    /// no per-frame Core Image filter anywhere near it. Brightness climbs with
    /// tier, so a district lights up as it densifies.
    func syncGroundGlow(on node: SKSpriteNode, zone: ZoneType, density: Int, footprintSize: Int) {
        let tier = RenderPalette.growthTier(for: density)
        let key = "\(zone.rawValue)-\(tier)"
        guard !isUpToDate(node, name: Self.groundGlowNodeName, key: Self.groundGlowCacheKey + key) else { return }
        node.childNode(withName: Self.groundGlowNodeName)?.removeFromParent()
        markUpToDate(node, name: Self.groundGlowNodeName, key: Self.groundGlowCacheKey + key)

        // Roads have `syncNetworkGlow`, and bare or merely-zoned land has no
        // building on it to be lit by.
        guard zone != .empty, zone != .road, zone != .highway else { return }
        guard zone.maxDensity == 0 || tier > 0 else { return }

        let color = zone.maxDensity > 0
            ? RenderPalette.tierColor(for: zone, tier: tier)
            : RenderPalette.fullColor(for: zone)

        let glow = SKSpriteNode(texture: Self.glowTexture)
        glow.name = Self.groundGlowNodeName
        glow.color = color
        glow.colorBlendFactor = 1
        glow.blendMode = .add
        // Wide and faint rather than tight and bright. A pool sized close to
        // the lot reads as a glowing square — the flat colour field again, in
        // gradient form. Spilling well past the footprint at low alpha lets
        // neighbouring lots' light *add* together instead, so a dense block
        // haloes as a district while a lone building stays a single point of
        // light, and no individual tile edge ever shows.
        glow.alpha = zone.maxDensity > 0 ? 0.13 + 0.05 * CGFloat(tier) : 0.28
        let base = layout.spriteSize(forFootprint: footprintSize)
        glow.size = CGSize(width: base.width * 1.8, height: base.height * 1.8)
        // Under the building, over the flat ground fill.
        glow.zPosition = 0.4
        node.addChild(glow)
    }

    func clearGroundGlow(on node: SKSpriteNode) {
        node.childNode(withName: Self.groundGlowNodeName)?.removeFromParent()
        invalidate(node, name: Self.groundGlowNodeName)
    }

    // MARK: - Surveyed-lot marker

    private static let zoneMarkerNodeName = "zoneMarker"

    /// The outline on a lot you have zoned but which has not grown anything
    /// yet.
    ///
    /// The flat-fill palette said "claimed but empty" with a washed-out
    /// version of the zone colour, which the ground rewrite deliberately gave
    /// up. This says it the way a surveyor's marks would instead — four
    /// corner ticks in the zone's own neon — which is both more legible
    /// against a dark ground and doesn't cost a flat colour field to say.
    func syncZoneMarker(on node: SKSpriteNode, zone: ZoneType, density: Int, footprintSize: Int) {
        let show = zone.maxDensity > 0 && RenderPalette.growthTier(for: density) == 0
        let key = show ? zone.rawValue : "none"
        guard !isUpToDate(node, name: Self.zoneMarkerNodeName, key: key) else { return }
        node.childNode(withName: Self.zoneMarkerNodeName)?.removeFromParent()
        markUpToDate(node, name: Self.zoneMarkerNodeName, key: key)
        guard show else { return }

        let size = layout.spriteSize(forFootprint: footprintSize)
        let inset = min(size.width, size.height) * 0.16
        let arm = min(size.width, size.height) * 0.2
        let half = CGSize(width: size.width / 2 - inset, height: size.height / 2 - inset)

        let path = CGMutablePath()
        for sx in [CGFloat(-1), 1] {
            for sy in [CGFloat(-1), 1] {
                let corner = CGPoint(x: sx * half.width, y: sy * half.height)
                path.move(to: CGPoint(x: corner.x - sx * arm, y: corner.y))
                path.addLine(to: corner)
                path.addLine(to: CGPoint(x: corner.x, y: corner.y - sy * arm))
            }
        }

        let marker = SKShapeNode(path: path)
        marker.name = Self.zoneMarkerNodeName
        marker.strokeColor = RenderPalette.tierColor(for: zone, tier: 1)
        marker.lineWidth = max(1.5, min(size.width, size.height) * 0.035)
        marker.glowWidth = 1
        marker.alpha = 0.85
        marker.zPosition = 0.6
        node.addChild(marker)
    }

    func clearZoneMarker(on node: SKSpriteNode) {
        node.childNode(withName: Self.zoneMarkerNodeName)?.removeFromParent()
        invalidate(node, name: Self.zoneMarkerNodeName)
    }

    // MARK: - Zone icons

    private static let iconNodeName = "zoneIcon"

    /// Has the decoration named `name` already been built for `key`?
    ///
    /// **Every `sync…` in this file used to tear its nodes down and rebuild
    /// them on every call**, and `GameScene.refreshAll()` calls them for every
    /// tile on every simulation tick. On a built-out 64×64 map that meant
    /// thousands of `SKShapeNode`s — several of them with `glowWidth`, which
    /// forces its own render pass — being destroyed and recreated once a
    /// second. It read to a player as the map blinking.
    ///
    /// `syncIcon` was given a cache key when exactly this was diagnosed for
    /// building icons; the mistake was fixing the one symptom rather than the
    /// pattern. Every decoration now caches on whatever actually determines
    /// its appearance, so a tick that changes nothing touches nothing.
    ///
    /// Stashed in `SKNode.userData` rather than a dictionary on this renderer,
    /// so the cache cannot outlive the node it describes.
    private func isUpToDate(_ node: SKSpriteNode, name: String, key: String) -> Bool {
        node.userData?[name] as? String == key
    }

    private func markUpToDate(_ node: SKSpriteNode, name: String, key: String) {
        if node.userData == nil { node.userData = NSMutableDictionary() }
        node.userData?[name] = key
    }

    /// Forgets the cached key, so the next `sync…` rebuilds from scratch.
    /// Every `clear…` has to call this or a cleared decoration would never
    /// come back — the cache would still claim it was up to date.
    private func invalidate(_ node: SKSpriteNode, name: String) {
        node.userData?.removeObject(forKey: name)
    }

    /// The (zone, density) a node's current icon was last built for — the
    /// first of these caches, and the one the rest were modelled on. See
    /// `syncIcon` for why that distinction matters enough to track.
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
    /// `center` is where the icon's *silhouette* should end up in its
    /// parent's coordinates — the tile sprite's own centre by default.
    ///
    /// **Why the position is set here and not left to the caller.** Icons are
    /// authored from a ground line at `y = -40` upward, so a tall tower's
    /// drawn frame happens to sit roughly on its origin while a short one — a
    /// strip of shops, a row of houses, an industrial shed — does not: its
    /// frame's midpoint can be twenty-odd points below the origin. Placing
    /// such an icon at the tile centre put the *origin* there and left the
    /// building hanging a quarter of a lot below, overlapping its neighbour.
    /// Since this function already measures the frame in order to scale by
    /// it, it is also the only place that knows the offset needed to undo
    /// that, so it applies it rather than expecting every caller to.
    static func fitIconToTile(
        _ icon: SKNode,
        footprintSize: Int,
        layout: GridLayout,
        centeredAt center: CGPoint = .zero
    ) {
        let spriteSize = layout.spriteSize(forFootprint: footprintSize)
        let occupied = icon.calculateAccumulatedFrame()
        let fitScale = min(
            spriteSize.width / max(occupied.width, 1),
            spriteSize.height / max(occupied.height, 1)
        ) * iconFillFactor
        icon.setScale(fitScale)
        icon.position = CGPoint(
            x: center.x - occupied.midX * fitScale,
            y: center.y - occupied.midY * fitScale
        )
    }

    /// Removes a tile's icon — used alongside `clearIcon` when `GameScene`
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
        let key = zone.rawValue
        guard !isUpToDate(node, name: Self.glowNodeName, key: key) else { return }
        node.childNode(withName: Self.glowNodeName)?.removeFromParent()
        markUpToDate(node, name: Self.glowNodeName, key: key)
        guard zone == .road || zone == .highway else { return }

        let glow = SKSpriteNode(texture: Self.glowTexture)
        glow.name = Self.glowNodeName
        glow.color = RenderPalette.networkAccentColor(for: zone)
        glow.colorBlendFactor = 1
        glow.blendMode = .add
        // Turned well down from where it started. These values were set when
        // every tile was a bright saturated fill and the glow had to fight to
        // be seen; against the dark ground that replaced them, roads are the
        // most numerous thing on the map — a third of the tiles in a normal
        // grid — and at the old alpha their additive bleed lit the entire
        // board a flat lilac. The brightest thing in the frame should be a
        // building, not the pavement.
        glow.alpha = zone == .highway ? 0.42 : 0.24
        let base = layout.spriteSize(forFootprint: zone.footprintSize)
        glow.size = CGSize(width: base.width * 1.2, height: base.height * 1.2)
        glow.zPosition = 0.5
        node.addChild(glow)
    }

    /// Removes a tile's network glow — used alongside `clearIcon`
    /// when `GameScene` draws an overlay instead of normal zone colors.
    func clearNetworkGlow(on node: SKSpriteNode) {
        node.childNode(withName: Self.glowNodeName)?.removeFromParent()
        invalidate(node, name: Self.glowNodeName)
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
        let key = "\(zone.rawValue)|\(connections.north)\(connections.south)\(connections.east)\(connections.west)"
        guard !isUpToDate(node, name: Self.laneLineNodeName, key: key) else { return }
        node.childNode(withName: Self.laneLineNodeName)?.removeFromParent()
        markUpToDate(node, name: Self.laneLineNodeName, key: key)
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
        invalidate(node, name: Self.laneLineNodeName)
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
        let key = "\(hasPipe)"
        guard !isUpToDate(node, name: Self.pipeMarkerNodeName, key: key) else { return }
        node.childNode(withName: Self.pipeMarkerNodeName)?.removeFromParent()
        markUpToDate(node, name: Self.pipeMarkerNodeName, key: key)
        guard hasPipe else { return }

        let marker = SKShapeNode(rectOf: CGSize(width: layout.spriteSize.width * 0.3, height: layout.spriteSize.height * 0.3))
        marker.name = Self.pipeMarkerNodeName
        marker.fillColor = RenderPalette.pipeMarkerColor
        marker.strokeColor = .clear
        marker.zPosition = 3
        node.addChild(marker)
    }

    /// Removes a tile's pipe marker — used alongside `clearIcon`/
    /// `clearNetworkGlow` for every overlay except Water.
    func clearPipeMarker(on node: SKSpriteNode) {
        node.childNode(withName: Self.pipeMarkerNodeName)?.removeFromParent()
        invalidate(node, name: Self.pipeMarkerNodeName)
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
        let key = "\(hasPowerLine)"
        guard !isUpToDate(node, name: Self.powerLineMarkerNodeName, key: key) else { return }
        node.childNode(withName: Self.powerLineMarkerNodeName)?.removeFromParent()
        markUpToDate(node, name: Self.powerLineMarkerNodeName, key: key)
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

    /// Removes a tile's power line marker — used alongside
    /// `clearIcon`/`clearNetworkGlow`/`clearPipeMarker` for every overlay
    /// except Power.
    func clearPowerLineMarker(on node: SKSpriteNode) {
        node.childNode(withName: Self.powerLineMarkerNodeName)?.removeFromParent()
        invalidate(node, name: Self.powerLineMarkerNodeName)
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
        let key = "\(density)|\(hasWaterSupply)|\(hasPowerSupply)"
        guard !isUpToDate(node, name: Self.utilityWarningNodeName, key: key) else { return }
        node.children.filter { $0.name == Self.utilityWarningNodeName }.forEach { $0.removeFromParent() }
        markUpToDate(node, name: Self.utilityWarningNodeName, key: key)

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
    /// `clearIcon` when `GameScene` draws an overlay instead of
    /// Normal view; the Water/Power overlays already have their own,
    /// bigger signal for this (the tile's own supply-state color), so a
    /// small corner badge on top would just be redundant there.
    func clearUtilityWarning(on node: SKSpriteNode) {
        node.children.filter { $0.name == Self.utilityWarningNodeName }.forEach { $0.removeFromParent() }
        invalidate(node, name: Self.utilityWarningNodeName)
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

    private static let damageNodeName = "hazardDamage"

    /// Marks a building that a hazard knocked down and that is waiting on a
    /// service to rebuild it (`Tile.damagedBy`).
    ///
    /// Deliberately louder than `syncUtilityWarning`'s corner badge: a missing
    /// water pipe is a *ceiling* on growth the player can take their time
    /// about, while damage is a block that has actually stopped working and
    /// will stay stopped until they act. So this darkens the whole lot as well
    /// as adding a badge — a visible hole in the city rather than a detail to
    /// notice.
    ///
    /// The badge is tinted with the colour of the service the block is waiting
    /// on, so the marker also says *what to build*: a fire-red badge means put
    /// a fire station in reach, a police-blue one means a police station.
    func syncDamageMarker(on node: SKSpriteNode, damagedBy: ZoneType?) {
        let key = damagedBy?.rawValue ?? "none"
        guard !isUpToDate(node, name: Self.damageNodeName, key: key) else { return }
        node.children.filter { $0.name == Self.damageNodeName }.forEach { $0.removeFromParent() }
        markUpToDate(node, name: Self.damageNodeName, key: key)
        guard let service = damagedBy else { return }

        let container = SKNode()
        container.name = Self.damageNodeName
        container.zPosition = 6

        let scrim = SKSpriteNode(color: .black, size: layout.spriteSize)
        scrim.alpha = 0.55
        container.addChild(scrim)

        let badgeSize = layout.spriteSize.width * 0.26
        let badge = SKShapeNode(rectOf: CGSize(width: badgeSize, height: badgeSize), cornerRadius: badgeSize * 0.18)
        badge.fillColor = .black
        badge.strokeColor = RenderPalette.fullColor(for: service)
        badge.lineWidth = 2
        badge.glowWidth = 1.5
        badge.position = CGPoint(x: 0, y: 0)
        container.addChild(badge)

        // A broken-window "X" in the service's colour — the same
        // straight-lines-only shape vocabulary the rest of this file uses.
        let arm = badgeSize * 0.3
        let cross = CGMutablePath()
        cross.move(to: CGPoint(x: -arm, y: -arm))
        cross.addLine(to: CGPoint(x: arm, y: arm))
        cross.move(to: CGPoint(x: -arm, y: arm))
        cross.addLine(to: CGPoint(x: arm, y: -arm))
        let mark = SKShapeNode(path: cross)
        mark.strokeColor = RenderPalette.fullColor(for: service)
        mark.lineWidth = 2
        mark.glowWidth = 1
        container.addChild(mark)

        node.addChild(container)
    }

    /// Removes a damage marker — used alongside `clearIcon` when
    /// `GameScene` draws an overlay instead of Normal view.
    func clearDamageMarker(on node: SKSpriteNode) {
        node.children.filter { $0.name == Self.damageNodeName }.forEach { $0.removeFromParent() }
        invalidate(node, name: Self.damageNodeName)
    }

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

        let key = "\(zone.rawValue)|\(density)|\(footprintSize)|\(seed.x),\(seed.y)"
        guard !isUpToDate(node, name: Self.buildingShadowNodeName, key: key) else { return }
        node.children.filter { $0.name == Self.buildingShadowNodeName }.forEach { $0.removeFromParent() }
        markUpToDate(node, name: Self.buildingShadowNodeName, key: key)
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
        invalidate(node, name: Self.buildingShadowNodeName)
    }
}
