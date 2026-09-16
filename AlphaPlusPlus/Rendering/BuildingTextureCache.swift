import SpriteKit

/// Rasterises each distinct building once and hands out sprites of it.
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
/// zone per tier" — and sixteen clears it. What is lost is the difference
/// between sixteen looks and thousands, which no player can perceive on a map
/// where a hundred lots are visible at once; what is gained is that the map
/// draws at all. The quantisation lives here rather than in the generators, so
/// `IndustrialMassing` and friends stay pure functions of a seed and the
/// contact sheet keeps showing genuinely unbounded variety.
final class BuildingTextureCache {

    /// How many distinct looks a zone and tier gets.
    static let variantCount = 16

    private struct Key: Hashable {
        let zone: ZoneType
        let tier: Int
        let variant: Int
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
        let key = Key(zone: zone, tier: tier, variant: Self.variant(for: seed))
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

    var count: Int { cache.count }
}
