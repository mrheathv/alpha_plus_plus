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
        enum Kind: Hashable { case building, ground, lane, car, conduit }
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
        let scene = SKScene(size: frame.size)
        scene.backgroundColor = .clear
        node.position = CGPoint(x: -frame.minX, y: -frame.minY)
        scene.addChild(node)
        renderView.frame = NSRect(origin: .zero, size: frame.size)
        renderView.allowsTransparency = true
        renderView.presentScene(scene)
        guard let texture = renderView.texture(from: scene, crop: CGRect(origin: .zero, size: frame.size)) else {
            return nil
        }

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

    // MARK: - Ground, lane lines and cars

    /// Renders `node` once and remembers it, keyed however the caller says.
    private func rendered(_ key: Key, _ build: () -> SKNode) -> Rendered? {
        if let hit = cache[key] { return hit }
        let node = build()
        let frame = node.calculateAccumulatedFrame()
        guard frame.width > 1, frame.height > 1 else { return nil }

        let scene = SKScene(size: frame.size)
        scene.backgroundColor = .clear
        node.position = CGPoint(x: -frame.minX, y: -frame.minY)
        scene.addChild(node)
        renderView.frame = NSRect(origin: .zero, size: frame.size)
        renderView.allowsTransparency = true
        renderView.presentScene(scene)
        guard let texture = renderView.texture(from: scene, crop: CGRect(origin: .zero, size: frame.size)) else {
            return nil
        }
        let result = Rendered(texture: texture,
                              offset: CGPoint(x: frame.midX, y: frame.midY),
                              size: frame.size)
        cache[key] = result
        return result
    }

    /// The lot a building stands on.
    func ground(for zone: ZoneType, density: Int, footprint: Int) -> Rendered? {
        let tier = RenderPalette.growthTier(for: density)
        return rendered(Key(kind: .ground, zone: zone, tier: tier, footprint: footprint)) {
            let shape = SKShapeNode(path: projection.tileDiamond(
                x: 0, y: 0, size: CGFloat(footprint), inset: 0.02
            ))
            shape.fillColor = RenderPalette.color(for: zone, density: density)
            shape.strokeColor = RenderPalette.ground.blended(withFraction: 0.28, of: .white) ?? .clear
            shape.lineWidth = 0.7
            return shape
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
    func car(alongX: Bool) -> Rendered? {
        rendered(Key(kind: .car, zone: .road, variant: alongX ? 0 : 1)) {
            let length: CGFloat = 0.34, width: CGFloat = 0.2, height: CGFloat = 0.15
            let box = alongX
                ? Box(x: -length / 2, y: -width / 2, z: 0, width: length, depth: width, height: height)
                : Box(x: -width / 2, y: -length / 2, z: 0, width: width, depth: length, height: height)

            let car = SKNode()
            for face in box.faces where Isometric.isVisible(face) {
                let shape = SKShapeNode(path: projection.path(face.points))
                shape.fillColor = RenderPalette.trafficCarBody.blended(
                    withFraction: 0.2 + 0.5 * Isometric.shade(face), of: .white
                ) ?? RenderPalette.trafficCarBody
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
            car.addChild(lamp(at: tail, color: RenderPalette.networkAccentColor(for: .road)))
            return car
        }
    }

    private func lamp(at point: CGPoint, color: SKColor) -> SKShapeNode {
        let lamp = SKShapeNode(circleOfRadius: max(1.2, projection.tileWidth * 0.022))
        lamp.position = point
        lamp.fillColor = color
        lamp.strokeColor = color
        lamp.glowWidth = 2.5
        return lamp
    }

    var count: Int { cache.count }
}
