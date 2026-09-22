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
    /// **Two. Four was measured and it was not affordable.**
    ///
    /// The arithmetic for four is still right — a Retina display is 2× and
    /// `GameScene.minimumZoomScale` is 0.5, so the closest view asks for four
    /// texture pixels per point — and it is still not worth what it costs.
    /// Measured back to back in one process on a built-out 64×64 city at
    /// 1280×800:
    ///
    /// | oversample | ms/frame | texture |
    /// |---|---|---|
    /// | 4× | 49.4 | 215 MB |
    /// | 2× | **19.3** | **54 MB** |
    /// | 1× | 16.4 | 14 MB |
    ///
    /// **Four triples the cost of drawing a frame**, and it was reported from
    /// play as the game running really slow within a day of landing.
    ///
    /// ### Two wrong numbers, both mine
    ///
    /// This started at 2, went to 4 on the strength of a memory estimate, and
    /// has come back. The estimate that sent it up said a built-out city held
    /// ~19 MB at 1× so four would cost 300 — call that the ceiling. Then a
    /// measurement "corrected" it to 1.6 MB at 1×, making four look like 25 MB
    /// and the ceiling imaginary.
    ///
    /// **That correction was the wrong number.** It was taken on a *40×40*
    /// city and counted only the building entries, while the ground diamonds,
    /// lane lines, conduits, badges and vehicle sprites in this same cache
    /// oversample too — and the near-detail tier doubles what a close camera
    /// keeps resident. On the city the game actually ships fixtures for, four
    /// is **215 MB**: the original instinct was closer to right than the
    /// correction that overruled it.
    ///
    /// The lesson is not about textures. A measurement taken on a smaller
    /// fixture, over a subset of the thing being measured, is not a
    /// correction — it is a second guess wearing a number's clothes, and it
    /// is more dangerous than the guess it replaced because it arrives with
    /// authority.
    ///
    /// ### What two gives up, and what covers it
    ///
    /// Two is exactly Retina at the *resting* camera, which is where the game
    /// is played; the closest camera is magnified beyond it again. What makes
    /// that survivable is the thing built since — `IsometricBuilding.Detail`
    /// puts real marks back at close zoom, and marks beat pixels. Sharpening
    /// a picture cannot add what was never in it, and that was always the
    /// larger half of the complaint.
    static var oversample: CGFloat = 2

    /// Whether cached textures carry mipmaps.
    ///
    /// **They have to, now that `oversample` is 4.** Every building sprite is
    /// drawn at its world size from a texture with four times that resolution
    /// in each axis, so one screen pixel covers sixteen texels. Without
    /// mipmaps the GPU samples that full-resolution texture anyway — which is
    /// both cache-hostile, because consecutive pixels land four texels apart
    /// rather than adjacent, and aliased, because sixteen texels get
    /// represented by one or four of them rather than averaged.
    ///
    /// It is a `var` for the same reason as `oversample`.
    static var usesMipmaps = true

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
        /// Buildings only. A near-detail building is a *different texture* of
        /// the same building, so it is one more dimension of the key rather
        /// than a second cache — which is what keeps "one sprite per lot"
        /// true at every zoom.
        var detail: IsometricBuilding.Detail = .standard
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

    func rendered(for zone: ZoneType, density: Int, seed: GridPosition,
                  detail: IsometricBuilding.Detail = .standard) -> Rendered? {
        let tier = RenderPalette.growthTier(for: density)
        let key = Key(kind: .building, zone: zone, tier: tier,
                      variant: Self.variant(for: seed), detail: detail)
        if let hit = cache[key] { return hit }

        let canonical = Self.canonicalSeed(for: key.variant)
        guard let massing = ZoneMassing.make(for: zone, density: density, seed: canonical) else { return nil }

        let node = IsometricBuilding.node(
            for: massing,
            accent: ZoneMassing.accent(for: zone, density: density),
            tier: max(1, tier),
            in: projection,
            detail: detail
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
        texture.usesMipmaps = Self.usesMipmaps

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
    func sprite(for zone: ZoneType, density: Int, seed: GridPosition, at origin: CGPoint,
                detail: IsometricBuilding.Detail = .standard) -> SKSpriteNode? {
        guard let rendered = rendered(for: zone, density: density, seed: seed,
                                      detail: detail) else { return nil }
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
        texture.usesMipmaps = Self.usesMipmaps
        let result = Rendered(texture: texture,
                              offset: CGPoint(x: frame.midX, y: frame.midY),
                              size: frame.size)
        cache[key] = result
        return result
    }

    /// The lot a building stands on.
    /// - Parameter kerbMask: which sides of this tile carry on into more
    ///   road, in the same four bits `lane` uses (east 1, west 2, north 4,
    ///   south 8). Ignored by everything that is not a street.
    func ground(for zone: ZoneType, density: Int, footprint: Int, isWater: Bool = false,
                kerbMask: Int = 0, seed: GridPosition = GridPosition(x: 0, y: 0)) -> Rendered? {
        let tier = RenderPalette.growthTier(for: density)
        // A road standing on water is a bridge, which is neither of the two
        // surfaces: a narrower deck with the river showing either side of it.
        let isBridge = isWater && zone.canBridge
        // Keyed apart from every zone rather than sharing `.empty`'s texture:
        // water is a different surface, not bare ground with a tint.
        let variant = isBridge ? 8 : (isWater ? 9 : tier)
        // **A street's ground is keyed on its neighbours too.** Where the road
        // stops, the tile grows a pavement — so a kerb is a statement about
        // what is *beside* this tile, exactly as a lane line is, and it is
        // drawn from the same sixteen-value mask.
        //
        // In the texture rather than as a layer over it, which is the whole
        // point: sixteen masks against two street zones is thirty-two more
        // entries in a cache that already holds a hundred, against **one more
        // node on every road tile in the city** if it were a sprite. That is
        // the trick that made the neon street grid free per tile, pointed at
        // the surface under it.
        let streetMask = isStreet(zone) && !isBridge ? kerbMask : 0
        // **Unbuilt land is the one surface that needs more than one
        // picture.** Everything else the ground draws is covered by what
        // stands on it or bounded by a street; bare land is the *field*, and
        // a field made of one texture is a repeating pattern by construction.
        // So it takes a look mixed from its own position, the same way a lot
        // picks its building — and nothing else does, because handing a lot
        // eight identical grounds is the churn `syncGround` already records.
        let scatter = zone == .empty && !isWater
            ? Self.variant(for: seed) % Self.bareLandVariants : 0
        return rendered(Key(kind: .ground, zone: zone, tier: variant,
                            variant: streetMask &+ scatter &* 16, footprint: footprint)) {
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
                x: 0, y: 0, size: CGFloat(footprint), inset: isBridge ? 0.17 : Self.groundInset
            ))
            surface.fillColor = RenderPalette.color(for: zone, density: density)
            // **Bare land gets no edge at all**, and the render is what
            // asked for it. A tile outline is a small mark on a lot, where a
            // building and its light pool sit on top of it — and on 353
            // contiguous unbuilt tiles it is the *only* mark, so a field of
            // them came back as graph paper. Unbuilt ground is not parcelled:
            // the grid a player needs is the placement cursor's, and a zoned
            // lot already draws a surveyed outline of its own.
            //
            // Merely dimming it was tried first and is the wrong instrument.
            // The line is drawn from `ground` and the fill from the zone, so
            // a dimmer line is still a *different colour* from what it
            // encloses, and a field of forty of them is still a grid — just
            // a quieter one. Stroking in the fill removes the mark rather
            // than turning it down, and widens the tile into its own inset,
            // which narrows the dark seam between neighbours to well under a
            // point.
            surface.strokeColor = isBridge
                ? RenderPalette.bridgeDeck
                : (zone == .empty
                   ? surface.fillColor
                   : (RenderPalette.ground.blended(withFraction: 0.28, of: .white) ?? .clear))
            surface.lineWidth = isBridge ? 1.4 : 0.7
            node.addChild(surface)

            if isStreet(zone), !isBridge {
                addPavement(to: node, mask: kerbMask, footprint: footprint)
                addStreetLamps(to: node, mask: kerbMask, footprint: footprint)
            } else if zone == .empty, !isWater {
                addScrub(to: node, scatter: scatter, footprint: footprint)
            }
            return node
        }
    }

    private func isStreet(_ zone: ZoneType) -> Bool { zone == .road || zone == .highway }

    /// **A junction has no room to be marked, and the arithmetic is why.**
    ///
    /// The mark a crossroads wants is a stop line across the mouth of each
    /// arm, and it was built: four bars in a paler grey than the kerb, drawn
    /// straight into this texture at no node cost. `street-surface.png` shows
    /// what arrived — a grey rectangle sitting around the neon, with a small
    /// cross at each of its four corners. Not four marks. One frame.
    ///
    /// The cause is that a tile is only so wide. A bar spanning the
    /// carriageway reaches 0.32 of a tile either side of the centre, so its
    /// ends sit 0.18 from the tile's edge — *inside* where the perpendicular
    /// bars sit, at 0.26. Every corner is a crossing, and the four bars close
    /// into a ring. Backing them off does not help, because the bar and the
    /// gap between bars are the same 64 points fighting over each other:
    ///
    /// | bar spans | bar | corner gap |
    /// |---|---|---|
    /// | 0.64 tile | 22.9 pt | −2.9 pt (they cross) |
    /// | 0.48 tile | 17.2 pt | 0.0 pt (they touch) |
    /// | 0.32 tile | 11.4 pt | 2.9 pt |
    /// | 0.18 tile | 6.4 pt | 5.4 pt |
    ///
    /// There is no row where both columns clear `NeonStyle.minimumDetailSize`.
    /// Which is that rule in its original form — **cut a mark that cannot be
    /// drawn big enough, do not shrink it** — reached by measuring rather than
    /// by looking, because here the two failures look alike: a ring and four
    /// specks are both "the junction has something grey on it".
    ///
    /// The one placement with room is hard against the tile's edge, and a grid
    /// kills it: every road tile in a built-out city is a junction, so two
    /// facing bars would land either side of every seam and the street would
    /// read as a ladder. Same answer the airport's static aircraft got, and
    /// the same reason — the mark is fine, the size it has to live at is not.
    ///
    /// What still distinguishes a junction is the pavement below: a crossroads
    /// is the one street tile with no footway at all, so it is visibly wider
    /// than everything around it.

    /// A lamp on every footway, which is the first thing this game has ever
    /// stood up off the ground plane without it being a building.
    ///
    /// **It rides the mask that is already in the key, so it costs nothing.**
    /// A lamp belongs on a footway, a footway exists exactly where the street
    /// does not carry on, and that is what `kerbMask` says — so a crossroads
    /// gets none, a straight run gets two, a dead end gets three, and the
    /// variety is a consequence of the street's own shape rather than a roll.
    /// No new texture dimension, no node on any tile, and a lamp cannot end up
    /// standing in a carriageway.
    ///
    /// **There is no lamp — only its light, and that is the whole finding.**
    /// The first version stood a mast up with a lit head on it, which is the
    /// obvious drawing and is two marks this scale cannot hold: a column 13
    /// points tall and one point wide is a hairline, and a head three points
    /// across is under `NeonStyle.minimumDetailSize` outright. Rendered, they
    /// read as a row of antennae floating above the road, detached from it
    /// because a lamp at the tile's up-screen edge rises further up-screen
    /// still. Cut, the same way the aviation beacon and the airport's static
    /// aircraft were cut, and for the same reason each time.
    ///
    /// What is left is the mark that survives: a warm disc on the pavement,
    /// twenty-eight points across, legible at every zoom the camera has. That
    /// is this art direction's own rule applied to street furniture — *colour
    /// comes from the light a thing throws, not from drawing the thing* — and
    /// it is exactly the trade the contact light under a building already
    /// makes, where a bright mark at the feet does the work a shadow would do
    /// on a ground that had any value left to take away.
    ///
    /// Warm, against a city lit in magenta and cyan. The street is the one
    /// surface in this game with no light of its own beyond the lane's neon,
    /// and a second hue at ground level is what separates "the road" from
    /// "the glowing line down the middle of the road".
    private func addStreetLamps(to node: SKNode, mask: Int, footprint: Int) {
        let inset = Self.groundInset
        let lo = inset, hi = CGFloat(footprint) - inset
        let mid = CGFloat(footprint) / 2
        let reach = Self.lampPoolReach, half = Self.lampPoolHalfLength
        // **Shaped along the footway, not as a disc on it**, and the render
        // is what decided that. A round pool centred on a footway 0.09 of a
        // tile wide has to be under 0.09 in radius to stay on the tile, which
        // is six points and invisible — and at any useful size it hangs over
        // the lot boundary, where it reads as a separate slab of ground
        // rather than as light on this one. Bounded in both directions
        // instead: long down the street, reaching in across the kerb, and
        // always inside the tile it belongs to.
        //
        // Which is also the truer drawing. A lamp does not put a circle on
        // the pavement; it washes the length of footway it stands over and
        // spills onto the carriageway.
        let pools: [(bit: Int, from: CGPoint, to: CGPoint)] = [
            (1, CGPoint(x: hi - reach, y: mid - half), CGPoint(x: hi, y: mid + half)),
            (2, CGPoint(x: lo, y: mid - half), CGPoint(x: lo + reach, y: mid + half)),
            (4, CGPoint(x: mid - half, y: hi - reach), CGPoint(x: mid + half, y: hi)),
            (8, CGPoint(x: mid - half, y: lo), CGPoint(x: mid + half, y: lo + reach)),
        ]
        for pool in pools where mask & pool.bit == 0 {
            let centre = CGPoint(x: (pool.from.x + pool.to.x) / 2,
                                 y: (pool.from.y + pool.to.y) / 2)
            // Nested quads rather than one, which is how a shape node gets a
            // falloff at all: each adds the same small amount of light and
            // they stack toward the middle, so the pool is brightest under
            // the lamp and fades to nothing at its edge. A single quad has a
            // hard border, and a hard border is what makes a mark read as a
            // panel instead of as light.
            //
            // Eight steps, not three. Three was tried and the render showed
            // concentric rectangles — a target painted on the road. The count
            // is what decides whether a stack of quads reads as a gradient or
            // as bands, and it is free here because all of it is rasterised
            // once per mask and arrives in the scene as part of one sprite.
            for step in Self.lampPoolFalloff {
                let light = SKShapeNode(path: projection.path([
                    Point3(x: centre.x + (pool.from.x - centre.x) * step,
                           y: centre.y + (pool.from.y - centre.y) * step, z: 0),
                    Point3(x: centre.x + (pool.to.x - centre.x) * step,
                           y: centre.y + (pool.from.y - centre.y) * step, z: 0),
                    Point3(x: centre.x + (pool.to.x - centre.x) * step,
                           y: centre.y + (pool.to.y - centre.y) * step, z: 0),
                    Point3(x: centre.x + (pool.from.x - centre.x) * step,
                           y: centre.y + (pool.to.y - centre.y) * step, z: 0),
                ]))
                light.fillColor = RenderPalette.streetLampPool
                light.strokeColor = .clear
                light.blendMode = .add
                node.addChild(light)
            }
        }
    }

    /// How far a lamp's light reaches in from the lot boundary, in tile
    /// units — the footway plus a little of the carriageway beyond the kerb,
    /// because a lamp that stopped at the kerb would read as paving rather
    /// than as light.
    private static let lampPoolReach: CGFloat = 0.34

    /// How far it runs *along* the street, either side of the tile's middle.
    /// Short of the tile's full length deliberately: the dark either end is
    /// what stops a run of lit tiles reading as one continuous glowing band
    /// and keeps each lamp a lamp.
    private static let lampPoolHalfLength: CGFloat = 0.3

    /// The nested sizes the pool is built from, as fractions of its full
    /// extent. Evenly spaced, so the number of layers covering a point falls
    /// linearly with distance from the middle and the sum is a linear ramp.
    private static let lampPoolFalloff: [CGFloat] =
        (0 ..< 8).map { 1.0 - CGFloat($0) * 0.115 }

    /// How many looks unbuilt land gets. Small, because each is a whole
    /// texture and the marks on them are deliberately too soft to identify —
    /// what breaks a field's repetition is that *neighbours differ*, not that
    /// any one of them is memorable. Eight is enough that a run of tiles in
    /// any direction does not come back to the same picture inside a screen.
    static let bareLandVariants = 8

    /// Scrub on unbuilt ground: a few soft patches of lighter and darker
    /// earth, laid out differently in each variant.
    ///
    /// **The marks have to be large and the values small**, which is the
    /// opposite of the instinct. Fine detail here is the moiré quilt the
    /// backdrop already ran into — *"at the zoom a player plans at, a margin
    /// of one-tile diamonds collapses into a quilt that fights the city"* —
    /// and a field is exactly where that bites, because the eye is being
    /// shown forty copies at once. So: patches a third of a tile across, a
    /// few per cent off the ground they sit on, and no edges anywhere.
    ///
    /// **Kept inside the tile**, which costs the field a little and is not
    /// negotiable: a patch overhanging the diamond would grow the node's
    /// accumulated frame, and a sprite's size comes from that — the same bug
    /// the pavement shipped, where a kerbed tile rendered 64 points wide
    /// against an uninterrupted one's 62.8.
    private func addScrub(to node: SKNode, scatter: Int, footprint: Int) {
        // A fixed formula on the variant, not real randomness, for the reason
        // `BuildingRandom` documents: a tile must look the same on every
        // launch, and `hashValue` is randomised per process.
        var state = UInt64(scatter &* 2_654_435_761 &+ 0x2545_F491)
        func next() -> CGFloat {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return CGFloat(state % 10_000) / 10_000
        }
        let span = CGFloat(footprint)
        for index in 0 ..< Self.scrubPatchesPerTile {
            // **Sized independently in each axis.** Square patches came back
            // as a chequer — forty little diamonds all the same shape, which
            // is a pattern wearing texture's clothes. Two rolls instead of
            // one is the whole fix.
            let width = (0.18 + next() * 0.26) * span
            let height = (0.18 + next() * 0.26) * span
            // Inset by the patch's own size so it cannot reach the diamond's
            // edge however the roll lands.
            let x = Self.groundInset + next() * (span - Self.groundInset * 2 - width)
            let y = Self.groundInset + next() * (span - Self.groundInset * 2 - height)
            let pale = index % 2 == 0

            // **Nested, for the same reason the lamp's pool is.** A shape
            // node has no falloff, so a single quad arrives with a hard
            // border — and a hard border is what turns a patch of ground into
            // a drawn mark. Four steps is enough here because the values are
            // already almost nothing.
            for step in Self.scrubFalloff {
                let w = width * step, h = height * step
                let patch = SKShapeNode(path: projection.path([
                    Point3(x: x + (width - w) / 2, y: y + (height - h) / 2, z: 0),
                    Point3(x: x + (width + w) / 2, y: y + (height - h) / 2, z: 0),
                    Point3(x: x + (width + w) / 2, y: y + (height + h) / 2, z: 0),
                    Point3(x: x + (width - w) / 2, y: y + (height + h) / 2, z: 0),
                ]))
                // Alternating lighter and darker, because one direction alone
                // reads as a stain rather than as ground that is not uniform.
                patch.fillColor = pale ? RenderPalette.scrubPale : RenderPalette.scrubDark
                patch.strokeColor = .clear
                patch.blendMode = pale ? .add : .alpha
                node.addChild(patch)
            }
        }
    }

    /// The nested sizes a patch is built from, as fractions of its extent.
    private static let scrubFalloff: [CGFloat] = [1.0, 0.76, 0.52, 0.28]

    /// How many patches one tile carries. Enough to break the flat fill, few
    /// enough that they do not merge into a second uniform surface a shade
    /// away from the first.
    private static let scrubPatchesPerTile = 5

    /// How far into the tile the pavement reaches, as a fraction of it.
    ///
    /// A carriageway is most of a street and a footway is the rest, so this
    /// is small — and it still has to survive being looked at from across the
    /// map. At a 64-point tile this is about six points, which is under
    /// `NeonStyle.minimumDetailSize`'s floor for a *mark* and fine for an
    /// *edge*: the rule is about things that have to be recognised, and a
    /// band along a boundary is recognised by where it is.
    private static let pavementWidth: CGFloat = 0.18

    /// How far a tile's drawn surface sits inside its own cell. Shared, so
    /// anything added to the ground lines up with what is already there.
    private static let groundInset: CGFloat = 0.02

    /// The footway along every side of a street that does not carry on into
    /// more street, with a kerb line where it meets the carriageway.
    ///
    /// Drawn per side rather than as one inset diamond, because a crossroads
    /// has no pavement at all and a dead end has three — an inset ring would
    /// put a kerb across the middle of every junction.
    private func addPavement(to node: SKNode, mask: Int, footprint: Int) {
        // **Inset exactly as the carriageway is**, and the test that caught
        // this is worth keeping in mind for anything else added to a cached
        // tile. A sprite's size comes from its node's accumulated frame, so a
        // pavement reaching the tile's true edge made a kerbed tile render
        // 64 points wide against an uninterrupted one's 62.8 — every street
        // with a kerb would have sat a fraction out of line with the lots
        // beside it, which is the kind of drift that reads as "the art is
        // slightly wrong" and never as a bug.
        let inset = Self.groundInset
        let lo = inset, hi = CGFloat(footprint) - inset
        let w = Self.pavementWidth
        // Each side, as the two corners it runs between in tile units.
        let sides: [(bit: Int, a: CGPoint, b: CGPoint, inward: CGPoint)] = [
            (1, CGPoint(x: hi, y: lo), CGPoint(x: hi, y: hi), CGPoint(x: -w, y: 0)),
            (2, CGPoint(x: lo, y: lo), CGPoint(x: lo, y: hi), CGPoint(x: w, y: 0)),
            (4, CGPoint(x: lo, y: hi), CGPoint(x: hi, y: hi), CGPoint(x: 0, y: -w)),
            (8, CGPoint(x: lo, y: lo), CGPoint(x: hi, y: lo), CGPoint(x: 0, y: w)),
        ]
        for side in sides where mask & side.bit == 0 {
            let path = CGMutablePath()
            let corners = [
                side.a,
                side.b,
                CGPoint(x: side.b.x + side.inward.x, y: side.b.y + side.inward.y),
                CGPoint(x: side.a.x + side.inward.x, y: side.a.y + side.inward.y),
            ].map { projection.project($0.x, $0.y, 0) }
            path.addLines(between: corners)
            path.closeSubpath()

            let footway = SKShapeNode(path: path)
            footway.fillColor = RenderPalette.pavement
            footway.strokeColor = .clear
            node.addChild(footway)

            // The kerb: the inner edge only, which is the one a street has.
            // The outer edge is where the lot begins and already reads as a
            // boundary because the surfaces differ.
            let kerb = CGMutablePath()
            kerb.move(to: corners[2])
            kerb.addLine(to: corners[3])
            let edge = SKShapeNode(path: kerb)
            edge.strokeColor = RenderPalette.kerb
            edge.lineWidth = 1
            node.addChild(edge)
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
