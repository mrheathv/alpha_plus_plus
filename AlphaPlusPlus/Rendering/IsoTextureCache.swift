import SpriteKit

/// Rasterises each distinct *repeated* thing once and hands out sprites of it.
///
/// **Why this exists.** An isometric building is about fifty `SKShapeNode`s —
/// three faces per volume plus lit panels — against an elevation's twenty-six.
/// `SKShapeNode` does not batch, so a built-out 64×64 map would be asking
/// SpriteKit for tens of thousands of draw calls a frame. Buildings never
/// change once placed, so drawing them from shapes every frame is paying
/// repeatedly for a result that is always identical. Rendered once to a
/// texture, a building is one sprite.
///
/// **The trade this makes, stated plainly.** A cache is only a cache if it
/// hits, and every lot has a different seed, so caching per lot would store one
/// texture per building and hit never — hundreds of megabytes to save nothing.
/// So the seed is quantised: a lot picks one of `variantCount` looks for its
/// zone and tier, rather than one of unboundedly many.
///
/// That is a real reduction in variety and worth being honest about. It is also
/// the target CLAUDE.md actually asks for — "ten or more distinct looks per
/// zone per tier" — and `variantCount` clears it twice over. What is lost is
/// the difference between that and thousands, which no player can perceive on
/// a map where a hundred lots are visible at once; what is gained is that the
/// map draws at all. The quantisation lives here rather than in the
/// generators, so `IndustrialMassing` and friends stay pure functions of a
/// seed and the contact sheet keeps showing genuinely unbounded variety.
final class IsoTextureCache {

    /// How many distinct looks a zone and tier gets.
    ///
    /// **This is the ceiling on variety, not the generators.** Counting
    /// distinct massings over exactly these seeds found the three growable
    /// zones pinned at 14–16 of a possible 16 — so every extra branch written
    /// into a generator was being quantised straight back out again, and the
    /// way to buy more buildings was to raise this number rather than to
    /// write more art.
    ///
    /// Raising it costs textures and nothing else: a texture is shared by
    /// every lot that draws it, and a lot is one sprite either way. 16 → 32
    /// took a built-out 40×40 city from 48 textures to 93 with the node count
    /// unchanged at 2,177. The generators still do not saturate here (they
    /// read 21–32 distinct), so there is headroom above this if it is ever
    /// wanted.
    /// How many texture pixels are rasterised per world point.
    ///
    /// **One was never enough, and not only when zoomed in.** Every building
    /// is rasterised once at its size in world *points*, and two
    /// magnifications then stack on top: a Retina display draws two physical
    /// pixels per point, and zooming to `minimumZoomScale` doubles it again.
    /// So at rest the textures were already being shown at 2× — which is why
    /// the city reads as *drawings* rather than objects the closer you get,
    /// reported from play exactly that way.
    ///
    /// **Four, because it turned out to be nearly free.** The estimate that
    /// set this work going was that a built-out city held ~19 MB of texture
    /// and that four would therefore cost 300 — the supposed ceiling that made
    /// oversampling a mitigation rather than a fix. Measured, a 40×40 city
    /// holds **1.6 MB** at one pixel per point: ninety-three textures of about
    /// 65 points square, not the 200×250 that guess assumed. So four costs
    /// **25 MB**, which is nothing, and the ceiling was imaginary.
    ///
    /// Four is also exactly what the range needs: a Retina display is 2×, and
    /// `GameScene.minimumZoomScale` is 0.5, so the closest view asks for four
    /// texture pixels per point. At rest it asks for two.
    ///
    /// What it does cost is cold-cache time — filling every building variant
    /// goes from about 190 ms to 650. That is paid once, lazily, as buildings
    /// first appear, so it lands as a hitch when a large saved city is opened.
    /// Warming the cache off the main thread, or behind the title screen,
    /// would remove it and has not been done.
    ///
    /// **The render harness cannot show the difference between two and four.**
    /// It captures at one pixel per point, so its only magnification is the
    /// camera's, and two already covers that. Four is justified by the
    /// arithmetic above and by a real display — not by any picture in this
    /// repository, which is worth knowing before someone "simplifies" it back.
    static let oversample: CGFloat = 4

    static let variantCount = 32

    /// **Why this grew past buildings.** `SKShapeNode` does not batch — every
    /// one is its own draw call — and `glowWidth` on a shape is more expensive
    /// still, because SpriteKit has to render the stroke more than once to get
    /// it. A built-out map was drawing a shape node per lot for its ground and
    /// a *glowing* shape node per road tile for its lane line, every frame,
    /// forever, to produce pictures that never change.
    ///
    /// Everything here is discrete and repeats: a lot's ground is one of a
    /// handful of colours, a road's lane line is one of sixteen connection
    /// masks, a car points one of two ways. Rendered once each, they become
    /// sprites, and sprites batch. The glow comes along inside the texture, so
    /// the retrowave bloom on the road grid costs nothing per tile at all.
    private struct Key: Hashable {
        enum Kind: Hashable { case building, ground, lane, car, conduit, badge }
        var kind: Kind = .building
        let zone: ZoneType
        var tier: Int = 0
        var variant: Int = 0
        var footprint: Int = 1
    }

    /// A rasterised building, and where its centre sits relative to the lot's
    /// own origin — needed because a building's drawn bounds are not its lot's
    /// bounds: chimneys rise above and tanks lean out.
    struct Rendered {
        let texture: SKTexture
        let offset: CGPoint
        let size: CGSize
    }

    private var cache: [Key: Rendered] = [:]
    private let projection: Isometric

    /// A private offscreen view, used only to rasterise buildings.
    ///
    /// **This must never be the game's own view, and once was.** Rendering a
    /// node to a texture means `SKView.texture(from:)`, which needs a scene
    /// presented on a view — so the first version took the view as a parameter
    /// and `GameScene` passed its own. `presentScene` *replaces* what a view is
    /// showing, so the first building a player placed swapped the live game out
    /// for a hundred-pixel scratch scene: the map froze, clicks stopped
    /// landing, and the simulation stopped ticking, because none of those
    /// things were on screen any more.
    ///
    /// Nothing failed. Nothing logged. Every test passed, because tests hand
    /// this a scratch view of their own and never notice that the view they
    /// passed got hijacked — the bug was only reachable when the view being
    /// borrowed was one somebody was looking at.
    private let renderView = SKView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))

    init(projection: Isometric) {
        self.projection = projection
    }

    /// Throw everything away and rasterise again.
    ///
    /// The palette is *baked* into every texture in here — that is the whole
    /// point of the cache — so changing `VisualStyle` while a city is on
    /// screen leaves every sprite drawn in the style that has just been
    /// switched away from. Nothing would look wrong, which is worse: the
    /// toggle would appear to do almost nothing, since only the handful of
    /// values read live (a lane's `alpha`, a glow's blend) would move.
    func purge() {
        cache.removeAll()
    }

    /// Which of the `variantCount` looks a lot gets.
    ///
    /// Mixed from the position rather than taken modulo it, so neighbouring
    /// lots do not march through the variants in step and produce visible
    /// diagonal stripes of identical buildings. Deliberately avoids
    /// `hashValue`, which Swift randomises per process — a lot must look the
    /// same on every launch, the same rule `BuildingRandom` documents.
    static func variant(for seed: GridPosition) -> Int {
        var mixed = UInt64(bitPattern: Int64(seed.x &* 73_856_093 &+ seed.y &* 19_349_663))
        mixed &+= 0x9E37_79B9_7F4A_7C15
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((mixed ^ (mixed >> 31)) % UInt64(variantCount))
    }

    /// The canonical seed that stands for a variant. Spread apart so two
    /// variants are not near-neighbours in the generators' own seed space,
    /// which would make them near-identical buildings.
    static func canonicalSeed(for variant: Int) -> GridPosition {
        GridPosition(x: variant * 31, y: variant * 17)
    }

    func rendered(for zone: ZoneType, density: Int, seed: GridPosition) -> Rendered? {
        let tier = RenderPalette.growthTier(for: density)
        let key = Key(kind: .building, zone: zone, tier: tier, variant: Self.variant(for: seed))
        if let hit = cache[key] { return hit }

        let canonical = Self.canonicalSeed(for: key.variant)
        guard let massing = ZoneMassing.make(for: zone, density: density, seed: canonical) else { return nil }

        let node = IsometricBuilding.node(
            for: massing,
            accent: ZoneMassing.accent(for: zone, density: density),
            tier: max(1, tier),
            in: projection
        )
        let frame = node.calculateAccumulatedFrame()
        guard frame.width > 1, frame.height > 1 else { return nil }

        // Rendered through a scene positioned so the node's own bounds land at
        // the origin, because `SKView.texture(from:crop:)` crops in scene
        // coordinates and a building's bounds start well below zero.
        //
        // **Scaled up for the capture, not rebuilt at a larger projection.**
        // Building the massing against a bigger projection would make the
        // drawing bigger while leaving the blur radius and the stroke widths
        // in points — so the glow would come out relatively tighter and the
        // neon thinner. That is a change to the *look* wearing the clothes of
        // a change to resolution. Scaling the finished node keeps every
        // proportion and only adds pixels.
        let pixels = CGSize(width: frame.width * Self.oversample,
                            height: frame.height * Self.oversample)
        let scene = SKScene(size: pixels)
        scene.backgroundColor = .clear
        node.setScale(Self.oversample)
        node.position = CGPoint(x: -frame.minX * Self.oversample,
                                y: -frame.minY * Self.oversample)
        scene.addChild(node)
        renderView.frame = NSRect(origin: .zero, size: pixels)
        renderView.allowsTransparency = true
        renderView.presentScene(scene)
        guard let texture = renderView.texture(from: scene, crop: CGRect(origin: .zero, size: pixels)) else {
            return nil
        }

        // The sprite still draws at the building's world size — only the
        // texture behind it has more pixels.
        let result = Rendered(
            texture: texture,
            offset: CGPoint(x: frame.midX, y: frame.midY),
            size: frame.size
        )
        cache[key] = result
        return result
    }

    /// A sprite of the cached building, positioned so its lot lands at
    /// `origin`.
    func sprite(for zone: ZoneType, density: Int, seed: GridPosition, at origin: CGPoint) -> SKSpriteNode? {
        guard let rendered = rendered(for: zone, density: density, seed: seed) else { return nil }
        let sprite = SKSpriteNode(texture: rendered.texture, size: rendered.size)
        sprite.position = CGPoint(x: origin.x + rendered.offset.x, y: origin.y + rendered.offset.y)
        return sprite
    }

    /// The same building, thrown back off the wet street under it.
    ///
    /// **It costs no texture.** The building has already been rasterised —
    /// that is what this whole cache exists for — so a reflection is the
    /// identical texture drawn a second time, flipped and squashed. One extra
    /// sprite per lot, no new entry in the cache, and nothing to invalidate
    /// when the building changes because it *is* the building's texture.
    ///
    /// That is also why this is not the reflection G5 was holding out for. A
    /// true mirror needs the whole scene in a render target — every
    /// neighbour, the road, the sky — and this is one building reflecting
    /// only itself. What makes it work anyway is that wet asphalt does not
    /// return a picture: it returns a dim smear directly beneath whatever is
    /// standing on it, which is exactly the shape of this approximation.
    ///
    /// Mirrored about the sprite's **base** rather than its centre, since the
    /// base is where the building meets the ground and a reflection hinged
    /// anywhere else floats. Squashed because the ground is seen at a glancing
    /// angle in this projection — an unsquashed mirror reads as a second
    /// building hanging upside down.
    /// - Parameter footprint: how many tiles across the lot is, which is what
    ///   bounds how far the reflection may fall. **This is not a style
    ///   choice.** A reflection is a child of its own tile node, and the tile
    ///   in front of it is drawn later and is opaque, so anything reaching
    ///   past the lot is simply painted over — the first render showed
    ///   reflections only where they happened to hang off the edge of the map
    ///   into open ground. Squashing each one to its own lot is what makes it
    ///   visible everywhere instead of nowhere.
    func reflectionSprite(
        for zone: ZoneType, density: Int, seed: GridPosition,
        at origin: CGPoint, footprint: Int, maximumSquash: CGFloat, strength: CGFloat
    ) -> SKSpriteNode? {
        guard strength > 0, maximumSquash > 0,
              let rendered = rendered(for: zone, density: density, seed: seed)
        else { return nil }

        // The room available is the ground it is drawn on, not the building
        // it is drawn from.
        let room = projection.tileHeight * CGFloat(footprint)
        let squash = min(maximumSquash, room / rendered.size.height)

        let sprite = SKSpriteNode(texture: rendered.texture, size: rendered.size)
        // Hung from `origin`, which the caller puts at the back edge of the
        // ground doing the reflecting.
        sprite.position = CGPoint(
            x: origin.x + rendered.offset.x,
            y: origin.y - rendered.size.height * squash / 2
        )
        sprite.yScale = -squash
        sprite.alpha = strength
        // Additive, because a reflection on a near-black street is *light*
        // returning off it rather than paint laid on it — the same reasoning
        // that made the contact light a bright mark instead of a shadow.
        // Held low: this project has recorded additive saturation three times,
        // and a reflection blowing out to white would read as fog.
        sprite.blendMode = .add
        return sprite
    }

    // MARK: - Ground, lane lines and cars

    /// Renders `node` once and remembers it, keyed however the caller says.
    private func rendered(_ key: Key, _ build: () -> SKNode) -> Rendered? {
        if let hit = cache[key] { return hit }
        let node = build()
        let frame = node.calculateAccumulatedFrame()
        guard frame.width > 1, frame.height > 1 else { return nil }

        // Oversampled for the same reason buildings are — the ground diamonds
        // and lane lines are magnified by exactly as much, and a crisp tower
        // standing on a soft street would be worse than both being soft.
        let pixels = CGSize(width: frame.width * Self.oversample,
                            height: frame.height * Self.oversample)
        let scene = SKScene(size: pixels)
        scene.backgroundColor = .clear
        node.setScale(Self.oversample)
        node.position = CGPoint(x: -frame.minX * Self.oversample,
                                y: -frame.minY * Self.oversample)
        scene.addChild(node)
        renderView.frame = NSRect(origin: .zero, size: pixels)
        renderView.allowsTransparency = true
        renderView.presentScene(scene)
        guard let texture = renderView.texture(from: scene, crop: CGRect(origin: .zero, size: pixels)) else {
            return nil
        }
        let result = Rendered(texture: texture,
                              offset: CGPoint(x: frame.midX, y: frame.midY),
                              size: frame.size)
        cache[key] = result
        return result
    }

    /// The lot a building stands on.
    func ground(for zone: ZoneType, density: Int, footprint: Int, isWater: Bool = false) -> Rendered? {
        let tier = RenderPalette.growthTier(for: density)
        // A road standing on water is a bridge, which is neither of the two
        // surfaces: a narrower deck with the river showing either side of it.
        let isBridge = isWater && zone.canBridge
        // Keyed apart from every zone rather than sharing `.empty`'s texture:
        // water is a different surface, not bare ground with a tint.
        let variant = isBridge ? 8 : (isWater ? 9 : tier)
        return rendered(Key(kind: .ground, zone: zone, tier: variant, footprint: footprint)) {
            let node = SKNode()
            if isWater {
                // The river runs under the deck, so it is drawn first and at
                // full width whether or not anything crosses it.
                let river = SKShapeNode(path: projection.tileDiamond(
                    x: 0, y: 0, size: CGFloat(footprint), inset: 0.02
                ))
                river.fillColor = RenderPalette.water
                river.strokeColor = RenderPalette.waterEdge
                river.lineWidth = 0.6
                node.addChild(river)
            }
            guard !isWater || isBridge else { return node }

            // **A deck, not a tile.** Inset hard when it is a bridge so the
            // water shows either side — that gap is the only thing saying
            // this road is carried rather than laid, and it costs nothing but
            // a number. A parapet edge reads as the rail along it.
            let surface = SKShapeNode(path: projection.tileDiamond(
                x: 0, y: 0, size: CGFloat(footprint), inset: isBridge ? 0.17 : 0.02
            ))
            surface.fillColor = RenderPalette.color(for: zone, density: density)
            surface.strokeColor = isBridge
                ? RenderPalette.bridgeDeck
                : (RenderPalette.ground.blended(withFraction: 0.28, of: .white) ?? .clear)
            surface.lineWidth = isBridge ? 1.4 : 0.7
            node.addChild(surface)
            return node
        }
    }

    /// A road's glowing centre line, baked with its bloom.
    ///
    /// Keyed on the connection mask, of which there are sixteen — so a city of
    /// a thousand road tiles draws from at most thirty-two textures, and the
    /// glow that makes the street grid read as neon is paid for once each
    /// rather than per tile per frame.
    func lane(for zone: ZoneType, mask: Int) -> Rendered? {
        rendered(Key(kind: .lane, zone: zone, variant: mask)) {
            let path = CGMutablePath()
            let centre = projection.project(0.5, 0.5, 0)
            var drew = false
            func arm(_ x: CGFloat, _ y: CGFloat) {
                path.move(to: centre)
                path.addLine(to: projection.project(x, y, 0))
                drew = true
            }
            if mask & 1 != 0 { arm(1, 0.5) }
            if mask & 2 != 0 { arm(0, 0.5) }
            if mask & 4 != 0 { arm(0.5, 1) }
            if mask & 8 != 0 { arm(0.5, 0) }
            // An isolated stub still needs a mark, or a lone road tile is
            // invisible.
            if !drew { arm(1, 0.5); arm(0, 0.5) }

            let lane = SKShapeNode(path: path)
            lane.strokeColor = RenderPalette.networkAccentColor(for: zone)
            lane.lineWidth = zone == .highway ? 3 : 2
            lane.glowWidth = zone == .highway ? 5 : 4
            lane.lineCap = .round
            return lane
        }
    }

    /// **What a block is short of, as a symbol rather than a coloured dot.**
    ///
    /// Reported from play: the warning should say *which* utility is missing.
    /// It was a small outlined disc with an identical bar inside it, so hue
    /// was the only thing distinguishing "no water" from "no power" — and
    /// this project has written down twice what that costs, most recently
    /// when an ember-coloured fire turned out to be invisible on an
    /// already-orange factory. Water's blue and power's amber sit right on
    /// top of the neon half the city is drawn in.
    ///
    /// A bolt and a drop are the genre's own symbols and need no legend. They
    /// also needed the badge to grow: the old disc was ten points across, and
    /// `NeonStyle.minimumDetailSize` says a mark that cannot be drawn at
    /// least nine points should be cut rather than shrunk — so a glyph inside
    /// it had no chance of resolving.
    ///
    /// Cached rather than built per lot, like everything else here: there are
    /// exactly two of these in the whole game, against an `SKShapeNode` with
    /// `glowWidth` per warned building before.
    func utilityBadge(isWater: Bool) -> Rendered? {
        rendered(Key(kind: .badge, zone: isWater ? .waterTower : .powerPlant)) {
            let radius = Swift.max(11, projection.tileWidth * 0.34)
            let colour = isWater
                ? RenderPalette.waterColor(for: true)
                : RenderPalette.powerColor(for: true)

            let plate = SKShapeNode(circleOfRadius: radius)
            plate.fillColor = NeonStyle.silhouetteFill
            plate.strokeColor = colour
            plate.lineWidth = 2.5
            plate.glowWidth = 4

            let glyph = SKShapeNode(path: isWater ? Self.dropPath(radius) : Self.boltPath(radius))
            glyph.fillColor = colour
            glyph.strokeColor = .clear
            plate.addChild(glyph)
            return plate
        }
    }

    /// A lightning bolt: the zigzag everybody already reads as power.
    private static func boltPath(_ radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let w = radius * 0.42, h = radius * 0.62
        path.move(to: CGPoint(x: w * 0.35, y: h))
        path.addLine(to: CGPoint(x: -w, y: h * 0.05))
        path.addLine(to: CGPoint(x: -w * 0.1, y: h * 0.05))
        path.addLine(to: CGPoint(x: -w * 0.35, y: -h))
        path.addLine(to: CGPoint(x: w, y: -h * 0.1))
        path.addLine(to: CGPoint(x: w * 0.1, y: -h * 0.1))
        path.closeSubpath()
        return path
    }

    /// A teardrop: a circle with its top drawn out to a point.
    private static func dropPath(_ radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let r = radius * 0.42
        let tip = CGPoint(x: 0, y: r * 1.75)
        path.move(to: tip)
        // Two curves down to the shoulders, then a full arc for the belly —
        // drawn rather than approximated with a circle plus a triangle, which
        // leaves a visible seam at this size.
        path.addQuadCurve(to: CGPoint(x: r, y: -r * 0.15),
                          control: CGPoint(x: r * 0.72, y: r * 0.72))
        // **Clockwise, so the belly goes under.** With y up, `false` sweeps
        // 0 → π/2 → π, which bulges the arc over the *top* and cuts the drop
        // off into a rounded triangle — it rendered as an up-arrow, which is
        // not what anybody reads as water.
        path.addArc(center: CGPoint(x: 0, y: -r * 0.15), radius: r,
                    startAngle: 0, endAngle: .pi, clockwise: true)
        path.addQuadCurve(to: tip, control: CGPoint(x: -r * 0.72, y: r * 0.72))
        path.closeSubpath()
        return path
    }

    /// A buried pipe or power line, drawn as a connected run.
    ///
    /// **The same rasteriser as `lane`, deliberately.** A conduit and a road
    /// are the same drawing problem — a network whose tile should join up with
    /// its neighbours — and the buried layers had been drawing one muted disc
    /// per tile instead, which reads as a row of dots rather than as a pipe.
    /// Sixteen masks times two kinds times live-or-dead is sixty-four
    /// textures, against a cache that already holds about fifty.
    ///
    /// `live` is the part that matters most. A conduit that does not trace
    /// back to a source does nothing at all, and until now looked identical to
    /// one that does — so "did that connect?", the only question a player is
    /// actually asking while laying pipe, had no answer on screen.
    /// `WaterSupply.isSupplied(at:)` has known it all along and nothing drew it.
    func conduit(isPipe: Bool, mask: Int, live: Bool) -> Rendered? {
        let key = Key(
            kind: .conduit,
            zone: isPipe ? .waterTower : .powerPlant,
            tier: live ? 1 : 0,
            variant: mask
        )
        return rendered(key) {
            let path = CGMutablePath()
            let centre = projection.project(0.5, 0.5, 0)
            var drew = false
            func arm(_ x: CGFloat, _ y: CGFloat) {
                path.move(to: centre)
                path.addLine(to: projection.project(x, y, 0))
                drew = true
            }
            if mask & 1 != 0 { arm(1, 0.5) }
            if mask & 2 != 0 { arm(0, 0.5) }
            if mask & 4 != 0 { arm(0.5, 1) }
            if mask & 8 != 0 { arm(0.5, 0) }
            // A lone tile of pipe still has to be visible — it is the first
            // thing a player places, and the one most likely to be orphaned.
            if !drew { arm(1, 0.5); arm(0, 0.5) }

            let line = SKShapeNode(path: path)
            line.strokeColor = RenderPalette.conduitColor(isPipe: isPipe, live: live)
            line.lineWidth = live ? 2.5 : 2
            // Dead conduits get no bloom at all. The absence of glow is the
            // signal — an unlit line among burning ones reads as "this one is
            // not carrying anything" without needing a legend. And the live
            // one's bloom is kept tight: at 5 the glow swamped the tiles
            // either side and the run read as a white smear rather than a
            // wire, which is the same mistake this project already made once
            // putting `glowWidth` on individual windows.
            line.glowWidth = live ? 3 : 0
            line.lineCap = .round
            return line
        }
    }

    /// A car, pointing down one of the two road diagonals.
    /// What kind of thing is on the road.
    ///
    /// Every vehicle used to be the same vehicle — one texture per axis, so a
    /// street outside a factory carried the same hatchback as one outside a
    /// tower block. Traffic is one of the few things on this map that
    /// *moves*, which makes it one of the few places variety is actually
    /// watched rather than glanced at.
    enum Vehicle: Hashable {
        case car
        /// Longer, taller, and carrying a separate box body, so it reads as
        /// freight from the silhouette alone rather than from its colour.
        case lorry
        /// A transit vehicle, running a line. Longest of the three and lit
        /// along its flank, because the point of it is being *recognisable*
        /// from across the map: this is the only thing on screen that proves
        /// a route you drew is carrying anybody.
        case transit(TransitRoute.Mode)
        /// A ship at the dock. By a distance the largest thing that moves on
        /// this map, which is the point: a seaport was the only building in
        /// the game whose entire purpose was invisible once it was built, and
        /// a hull long enough to read from across the map is what says the
        /// quay is trading.
        case ship
        /// A patrol car. Not a different shape — a different *colour*, which
        /// is the whole point of drawing traffic as light: at eleven points
        /// across, hue is legible where silhouette is not.
        case police
        /// An engine running to a fire.
        case fire
        /// An airliner on the runway. **Drawn moving, having been cut as a
        /// static mark**: standing still at three tiles across, a fuselage, a
        /// wing and a fin merged into one lump that read as a crate. Motion
        /// is a different channel from shape — a shape sliding down a lit
        /// centreline is an aircraft because of where it is and what it is
        /// doing, not because its silhouette resolves.
        case aircraft

        var length: CGFloat {
            switch self {
            case .car, .police: return 0.34
            case .lorry, .fire: return 0.52
            case .transit: return 0.62
            case .ship: return 1.9
            case .aircraft: return 0.66
            }
        }

        var height: CGFloat {
            switch self {
            case .car, .police: return 0.15
            case .lorry, .fire: return 0.24
            case .transit: return 0.22
            case .ship: return 0.3
            case .aircraft: return 0.17
            }
        }

        /// How wide across the beam. A ship is the one vehicle here that is
        /// not roughly a lane wide — a hull as narrow as a bus would read as
        /// a very long tram that had fallen in the water.
        var beam: CGFloat {
            switch self {
            case .ship: return 0.62
            // Wings. The one proportion that separates an aircraft from a bus
            // once both are a few points across.
            case .aircraft: return 0.5
            default: return 0.2
            }
        }
    }

    func car(_ vehicle: Vehicle = .car, alongX: Bool, braking: Bool = false) -> Rendered? {
        let variant = (alongX ? 0 : 1) | (braking ? 2 : 0)
        let zone: ZoneType
        switch vehicle {
        case .car: zone = .road
        case .lorry: zone = .industrial
        case .police: zone = .policeStation
        case .fire: zone = .fireStation
        case .transit(let mode): zone = mode.stationZone
        case .ship: zone = .seaport
        case .aircraft: zone = .airport
        }
        return rendered(Key(kind: .car, zone: zone, variant: variant)) {
            let length = vehicle.length, width = vehicle.beam, height = vehicle.height
            let box = alongX
                ? Box(x: -length / 2, y: -width / 2, z: 0, width: length, depth: width, height: height)
                : Box(x: -width / 2, y: -length / 2, z: 0, width: width, depth: length, height: height)

            let body: SKColor
            switch vehicle {
            case .car, .lorry, .police, .fire: body = RenderPalette.trafficCarBody
            // A hull is dark like everything else that moves, lit by what it
            // carries rather than by being painted bright.
            case .ship, .aircraft: body = RenderPalette.trafficCarBody
            // A bus is the colour of the line it runs, which is what makes it
            // legible as *that route's* bus rather than as a long car.
            case .transit(let mode): body = RenderPalette.fullColor(for: mode.stationZone)
            }

            let car = SKNode()
            for face in box.faces where Isometric.isVisible(face) {
                let shape = SKShapeNode(path: projection.path(face.points))
                // A light touch. At `0.2 + 0.5 * shade` the top face came out
                // near-white whatever body colour it started from, which also
                // threw away the one thing a *bus*'s colour is for — saying
                // which line it runs.
                shape.fillColor = body.blended(
                    withFraction: 0.04 + 0.22 * Isometric.shade(face), of: .white
                ) ?? body
                shape.strokeColor = RenderPalette.trafficCarOutline
                shape.lineWidth = 1
                car.addChild(shape)
            }
            // Headlights and tail lights, which is most of what makes traffic
            // read as traffic at night — and the most retrowave thing on the
            // map after the road grid itself.
            let nose = alongX
                ? projection.project(length / 2, 0, height * 0.6)
                : projection.project(0, length / 2, height * 0.6)
            let tail = alongX
                ? projection.project(-length / 2, 0, height * 0.6)
                : projection.project(0, -length / 2, height * 0.6)
            car.addChild(lamp(at: nose, color: NeonStyle.litAccent))
            // **Brake lights are what makes a jam look like a jam.** Congestion
            // already changes how many cars there are and how slowly they
            // cross, and neither of those reads as *stopping*. A hot red tail
            // does, and it costs one more texture variant rather than a node
            // per car.
            car.addChild(lamp(
                at: tail,
                color: braking ? RenderPalette.brakeLight
                               : RenderPalette.networkAccentColor(for: .road),
                scale: braking ? 1.7 : 1
            ))
            return car
        }
    }

    private func lamp(at point: CGPoint, color: SKColor, scale: CGFloat = 1) -> SKShapeNode {
        let lamp = SKShapeNode(circleOfRadius: max(1.2, projection.tileWidth * 0.022) * scale)
        lamp.position = point
        lamp.fillColor = color
        lamp.strokeColor = color
        lamp.glowWidth = 2.5
        return lamp
    }

    var count: Int { cache.count }

    /// Roughly how much texture memory the cache is holding, in bytes.
    ///
    /// Worth being able to state rather than estimate, because `oversample`
    /// spends exactly this and the ceiling on raising it further *is* this
    /// number — four would be sixteen times the one-pixel-per-point baseline,
    /// which is what makes oversampling a mitigation rather than the fix.
    var approximateBytes: Int {
        cache.values.reduce(0) { total, rendered in
            let pixels = rendered.size.width * Self.oversample
                * rendered.size.height * Self.oversample
            return total + Int(pixels) * 4
        }
    }
}
