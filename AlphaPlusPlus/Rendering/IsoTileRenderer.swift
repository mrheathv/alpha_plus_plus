import SpriteKit

/// Turns `Tile` data into isometric nodes.
///
/// One node per building anchor, carrying its ground, its light and its
/// building, with a `zPosition` that puts it in the painter's-algorithm order
/// an isometric scene needs. `GameScene` keeps its existing structure: a
/// dictionary of tile nodes, a region rebuild, and a refresh — only what each
/// node contains changes.
struct IsoTileRenderer {

    let projection: Isometric
    let textures: IsoTextureCache

    var textureCountForTesting: Int { textures.count }

    /// How much detail buildings are drawn with — set by `GameScene` off the
    /// camera, since how close the player is standing is a fact about the
    /// view rather than about any tile.
    ///
    /// `IsometricBuilding.Detail` explains what the near tier puts back and
    /// why it is a texture rather than a second renderer.
    var detail: IsometricBuilding.Detail = .standard

    private static let groundNodeName = "isoGround"

    /// Shared by every water tile — see `WaterShader`.
    static let water: SKShader = {
        let shader = WaterShader.make()
        WaterShader.applyStyle(shader)
        return shader
    }()
    private static let glowNodeName = "isoGroundGlow"
    private static let markerNodeName = "isoZoneMarker"
    /// Not private: tests need to ask whether *the building* is showing, and
    /// now that ground and lane lines are rasterised too, "is there a textured
    /// sprite here" no longer answers that question.
    static let buildingNodeName = "isoBuilding"
    static let reflectionNodeName = "isoReflection"
    static let aircraftNodeName = "isoAircraft"
    private static let laneNodeName = "isoLane"
    static let contactNodeName = "isoContact"
    static let smokeNodeName = "isoSmoke"

    /// Node names the style tests need — which check that a street actually
    /// comes back dimmer and that a building actually lights the ground it
    /// stands on, rather than trusting that a constant nobody reads changed.
    static var laneNodeNameForTesting: String { laneNodeName }
    static var groundNodeNameForTesting: String { groundNodeName }
    static var glowNodeNameForTesting: String { glowNodeName }

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

    init(projection: Isometric, textures: IsoTextureCache? = nil) {
        self.projection = projection
        self.textures = textures ?? IsoTextureCache(projection: projection)
    }

    /// The node for one building anchor, covering its whole footprint.
    ///
    /// `zPosition` is the painter's-algorithm key rather than a sort of the
    /// parent's children: `GameScene.rebuildRegion` adds and removes nodes in a
    /// small window without touching the rest, and re-sorting a whole tile
    /// layer per placement would undo the saving that exists for.
    func makeNode(for tile: Tile, roadNeighbours: Int = 0b1111) -> SKNode {
        let footprint = tile.zone.footprintSize
        let node = SKNode()
        node.name = Self.nodeName(for: tile.position)
        node.position = projection.project(CGFloat(tile.position.x), CGFloat(tile.position.y), 0)
        node.zPosition = Isometric.depth(of: tile.position, footprint: footprint)
        update(node, for: tile, roadNeighbours: roadNeighbours)
        return node
    }

    /// Re-sync an existing node to current tile data, mutating rather than
    /// rebuilding: no allocation, no scene-graph churn, and it scales to a
    /// full-map refresh every simulation tick.
    /// - Parameter reflecting: the building the wet ground here throws back,
    ///   which the *caller* works out because it needs the map and this does
    ///   not. See `GameScene.reflection(at:)` for why a reflection belongs to
    ///   the ground it lands on rather than the building that casts it.
    /// - Parameter roadNeighbours: which sides of this tile carry on into more
    ///   street, as the four bits `syncLaneLine` already builds. A kerb is a
    ///   statement about neighbours, like a lane line, so the ground needs the
    ///   same answer the lane does. Defaults to "surrounded", which draws no
    ///   pavement — the right answer for everything that is not a street and
    ///   for a caller that has not been taught about them.
    /// - Parameter occludedBy: how much of this lot's sky its neighbours take,
    ///   0 for a building standing on its own and 1 for one walled in on every
    ///   side by towers. Worked out by the caller for the same reason the
    ///   reflection is — it needs the map, and this does not.
    func update(_ node: SKNode, for tile: Tile, reflecting: Reflected? = nil,
                roadNeighbours: Int = 0b1111, occludedBy occlusion: Double = 0) {
        let shade = Self.occlusionStep(occlusion)
        syncGround(on: node, tile: tile, roadNeighbours: roadNeighbours)
        syncGroundGlow(on: node, tile: tile, shade: shade)
        syncContactLight(on: node, tile: tile, shade: shade)
        syncSmoke(on: node, tile: tile)
        syncZoneMarker(on: node, tile: tile)
        syncReflection(on: node, tile: tile, reflecting: reflecting)
        syncBuilding(on: node, tile: tile, shade: shade)
        syncAircraft(on: node, tile: tile)
    }

    /// **Occlusion, quantised before it is ever used.**
    ///
    /// Every mark it touches is cached on a key, and enclosure is a continuous
    /// number that a neighbour three lots away growing a storey can nudge by a
    /// thousandth. A raw key would miss on every tile every tick and rebuild
    /// the whole city once a second — precisely the churn this file records as
    /// "why the map blinked", and the same reason road wear is quantised into
    /// five steps before it reaches a lane line's key.
    ///
    /// Six steps, which is more gradation than the eye finds in how dark a
    /// pool of light is.
    ///
    /// **Cut at `fullyEnclosed` rather than at 1**, and that number came from
    /// measuring rather than from reasoning. `GameScene.occlusion` returns an
    /// honest physical fraction — what share of a lot's perimeter is blocked —
    /// and on Apex, the largest and densest city this project ships, **it
    /// never once exceeds 0.5**. It cannot: every lot in a city with streets
    /// fronts onto one, and a street is open sky. Scaled against 1 the top
    /// three sixths of this range were dead weight and a whole built-out
    /// downtown resolved into three shades.
    ///
    /// So the fraction stays true and the *scale* is calibrated to the range
    /// the game can actually produce. Anything past it — a lot walled in on
    /// every side, which only a hand-built fixture manages — simply sits at
    /// the bottom.
    static func occlusionStep(_ occlusion: Double) -> Int {
        Swift.max(0, Swift.min(5, Int(occlusion / fullyEnclosed * 5.999)))
    }

    /// The enclosure a real city tops out at. See `occlusionStep`.
    static let fullyEnclosed = 0.5

    /// How much of a lot's own light its neighbours take at full enclosure.
    ///
    /// **It subtracts light rather than adding dark**, which is the rule this
    /// renderer already had to find once: on a ground that is near-black by
    /// design there is nothing left to take away, so contact at the foot of a
    /// building is drawn as a *bright* mark. Occlusion is that argument run
    /// backwards — a lot hemmed in on every side has less light reaching the
    /// ground, and the way to say so is to turn down the light that is there.
    ///
    /// Which is also why it lands hardest on the pools and barely at all on
    /// the building: darkening a whole silhouette uniformly would flatten a
    /// tower rather than seat it, and the crevices between buildings are where
    /// real density actually reads as dark.
    static let occlusionDimsGroundLight = 0.72

    /// And how much of the building's own silhouette goes with it. Small on
    /// purpose — see above.
    static let occlusionDimsBuilding = 0.22

    static func nodeName(for position: GridPosition) -> String { "iso-\(position.x)-\(position.y)" }

    // MARK: - Ground

    /// The lot itself: one diamond covering the whole footprint, not one per
    /// cell. A 2×2 building stands on a single 2×2 diamond, so its ground has
    /// no seams running through it.
    private func syncGround(on node: SKNode, tile: Tile, roadNeighbours: Int = 0b1111) {
        // **The mask is in the key only for the tiles that draw it.**
        //
        // A street whose neighbour is bulldozed grows a kerb where the
        // junction was, so a key blind to the mask would leave the old
        // surface in place. But bare land and lots ignore the mask entirely —
        // and keying them on it anyway meant every tile beside a new road
        // rebuilt its ground to produce a byte-identical texture, and
        // reported itself stale while doing it. `ScenePlaytest` caught that
        // as a row of empty tiles disagreeing after a cross street went in.
        //
        // A cache key has to describe *what was drawn*. Putting more in it
        // than the picture depends on is not a harmless safety margin: it is
        // churn, and it makes the key lie about what it represents.
        let mask = Traffic.isRoadLike(tile.zone) ? roadNeighbours : 0
        // Unbuilt land picks one of several looks from its own position, so a
        // field of it is not one texture repeated. Nothing else does — see
        // `IsoTextureCache.ground` — so nothing else needs its position here,
        // and putting it in every tile's key anyway is exactly the churn the
        // comment above is about.
        let scatter = tile.zone == .empty && !tile.isWater
            ? "|\(IsoTextureCache.variant(for: tile.position) % IsoTextureCache.bareLandVariants)"
            : ""
        let key = "\(tile.zone.rawValue)|\(tile.density)|\(tile.isWater)|\(mask)\(scatter)"
        guard !isUpToDate(node, Self.groundNodeName, key) else { return }
        markUpToDate(node, Self.groundNodeName, key)
        node.childNode(withName: Self.groundNodeName)?.removeFromParent()

        guard let rendered = textures.ground(
            for: tile.zone, density: tile.density, footprint: tile.zone.footprintSize,
            isWater: tile.isWater, kerbMask: mask, seed: tile.position
        ) else { return }
        let ground = SKSpriteNode(texture: rendered.texture, size: rendered.size)
        ground.name = Self.groundNodeName
        ground.position = rendered.offset
        ground.zPosition = 0
        if tile.isWater {
            // One shared shader instance, because an `SKShader` is the
            // batching unit — a per-tile instance would be a draw call per
            // tile, the exact cost the texture cache exists to avoid. What is
            // per-tile is the attribute.
            ground.shader = Self.water
            ground.setValue(
                SKAttributeValue(vectorFloat2: vector_float2(Float(tile.position.x),
                                                             Float(tile.position.y))),
                forAttribute: WaterShader.tileAttribute
            )
        }
        node.addChild(ground)
    }

    /// The pool of light a building throws on the ground it stands on — the
    /// same additive trick the top-down renderer uses, and the thing that
    /// carries zone identity when the camera is far enough out that the
    /// silhouette has stopped resolving.
    private func syncGroundGlow(on node: SKNode, tile: Tile, shade: Int = 0) {
        let tier = RenderPalette.growthTier(for: tile.density)
        let key = "\(tile.zone.rawValue)|\(tier)|\(shade)"
        guard !isUpToDate(node, Self.glowNodeName, key) else { return }
        markUpToDate(node, Self.glowNodeName, key)
        node.childNode(withName: Self.glowNodeName)?.removeFromParent()
        guard tile.zone != .empty, tile.zone != .road, tile.zone != .highway else { return }
        guard tile.zone.maxDensity == 0 || tier > 0 else { return }

        let glow = SKSpriteNode(texture: NeonStyle.glowTexture)
        glow.name = Self.glowNodeName
        glow.color = ZoneMassing.accent(for: tile.zone, density: tile.density)
        glow.colorBlendFactor = 1
        glow.blendMode = .add
        glow.alpha = (tile.zone.maxDensity > 0 ? 0.13 + 0.05 * CGFloat(tier) : 0.28)
            * Self.lightLeftAfter(shade)
        let size = CGFloat(tile.zone.footprintSize)
        glow.size = CGSize(width: projection.tileWidth * size * 1.7,
                           height: projection.tileHeight * size * 1.7)
        glow.position = projection.project(size / 2, size / 2, 0)
        glow.zPosition = 0.1
        node.addChild(glow)
    }

    /// **Where the building meets the ground.**
    ///
    /// Buildings were hovering. They had a wide, faint pool of their own
    /// colour on the lot — 1.7× the footprint at alpha 0.13 — which reads as
    /// district ambience, the light of a *neighbourhood*, and says nothing
    /// about where any one building actually stands.
    ///
    /// **The obvious fix is wrong on this map.** Contact normally means a
    /// shadow, and a shadow means darkening the ground — but this ground is
    /// already near-black, so there is nothing to take away. At night the
    /// real cue runs the other way: a lit building spills onto the pavement
    /// hardest right at its feet. So contact here is a *bright* mark, tight
    /// to the footprint, under the wide pool rather than instead of it. The
    /// two together give the falloff — hot at the base, fading out across the
    /// lot — that makes a thing look planted instead of pasted on.
    ///
    /// Same texture and blend mode as the pool, so the extra sprite per
    /// building costs a node and no new draw call. It is a sprite rather than
    /// part of the building's own texture because that texture is shared by
    /// every lot drawing this variant, and the spill belongs to the lot.
    private func syncContactLight(on node: SKNode, tile: Tile, shade: Int = 0) {
        let tier = RenderPalette.growthTier(for: tile.density)
        let key = "\(tile.zone.rawValue)|\(tier)|\(shade)"
        guard !isUpToDate(node, Self.contactNodeName, key) else { return }
        markUpToDate(node, Self.contactNodeName, key)
        node.childNode(withName: Self.contactNodeName)?.removeFromParent()
        guard tile.zone != .empty, tile.zone != .road, tile.zone != .highway else { return }
        guard tile.zone.maxDensity == 0 || tier > 0 else { return }

        let contact = SKSpriteNode(texture: NeonStyle.glowTexture)
        contact.name = Self.contactNodeName
        contact.color = ZoneMassing.accent(for: tile.zone, density: tile.density)
        contact.colorBlendFactor = 1
        contact.blendMode = .add
        contact.alpha = (tile.zone.maxDensity > 0 ? 0.20 + 0.07 * CGFloat(tier) : 0.30)
            * Self.lightLeftAfter(shade)
        let size = CGFloat(tile.zone.footprintSize)
        // Barely wider than the lot. The whole point is that it does *not*
        // spill across the block the way the pool above it does.
        contact.size = CGSize(width: projection.tileWidth * size * 1.02,
                              height: projection.tileHeight * size * 1.02)
        contact.position = projection.project(size / 2, size / 2, 0)
        contact.zPosition = 0.2
        breathe(contact, tile: tile)
        node.addChild(contact)
    }

    /// **The city breathes.**
    ///
    /// A still city at night reads as a diorama, and what sells a place as
    /// inhabited is that a few things change while everything else holds.
    ///
    /// **It is the light already there that moves, not a new mark.** The
    /// first attempt hung a blinking beacon above every tall roof and it was
    /// wrong twice over: it was indistinguishable from the building's own lit
    /// crown, and at the zoom this game is played at the dot was about three
    /// screen points — which `minimumDetailSize` says to *cut* rather than
    /// shrink. Modulating a mark that is already a whole lot across survives
    /// every zoom, and costs no node at all.
    ///
    /// A shop's sign works harder than a window does, so commerce flickers
    /// faster and further; everything else is a slow swell you notice only
    /// across a block. The beat and its phase come from the lot's own
    /// position, so a row of towers does not pulse as one — the same reason
    /// `BuildingRandom` seeds from position, and the same reason the fire's
    /// flicker sums beats of different length.
    ///
    /// Kept deliberately shallow. This is meant to be felt rather than
    /// watched: a map of lights visibly throbbing is a screensaver, not a
    /// city.
    private func breathe(_ light: SKSpriteNode, tile: Tile) {
        guard tile.zone.maxDensity > 0, !VisualStyle.reduceMotion else { return }
        var random = BuildingRandom(seed: tile.position, salt: 91)
        let isSign = tile.zone == .commercial
        let period = Double(random.value(in: isSign ? 1.1 ... 1.9 : 2.6 ... 4.2))
        let depth: CGFloat = isSign ? 0.34 : 0.16
        let base = light.alpha

        light.run(.sequence([
            .wait(forDuration: Double(random.value(in: 0 ... 1)) * period),
            .repeatForever(.sequence([
                .fadeAlpha(to: base * (1 - depth), duration: period * 0.55),
                .fadeAlpha(to: Swift.min(1, base * (1 + depth)), duration: period * 0.45),
            ])),
        ]))
    }

    /// Smoke off a working factory.
    ///
    /// **Industry is the one zone that should look like it is doing
    /// something**, and until now a factory at density 5 differed from one at
    /// density 1 only in size and how hard it glowed. This is the first mark
    /// in the game that says a building is *running* rather than standing
    /// there — and it scales with density, so a busy industrial district
    /// visibly is one.
    private func syncSmoke(on node: SKNode, tile: Tile) {
        let show = tile.zone == .industrial && tile.density > 0 && !tile.isBurning
            && !VisualStyle.reduceMotion
        let key = show ? "\(tile.density)" : "none"
        guard !isUpToDate(node, Self.smokeNodeName, key) else { return }
        markUpToDate(node, Self.smokeNodeName, key)
        node.childNode(withName: Self.smokeNodeName)?.removeFromParent()
        guard show else { return }

        let size = CGFloat(tile.zone.footprintSize)
        let smoke = Emitters.smoke(scale: projection.tileWidth * size, density: tile.density)
        smoke.name = Self.smokeNodeName
        smoke.position = projection.project(size / 2, size / 2, buildingTop(of: tile))
        // Under the fire marker, which sits at 0.75: a factory that is both
        // working and alight is alight first.
        smoke.zPosition = 0.55
        smoke.advanceSimulationTime(4)
        node.addChild(smoke)
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

    /// How wet the streets are, 0…1 — set by the scene from `Weather`.
    ///
    /// A property rather than an argument because `update(_:for:)` is called
    /// from half a dozen places and threading a number through all of them to
    /// answer a question that is the same everywhere on screen is the ceremony
    /// `VisualStyle.current` already declined.
    var wetness: CGFloat = 0

    /// A building reflected in the wet street beneath it.
    ///
    /// Keyed on the wetness *as well as* the building, so a shower arriving
    /// rebuilds these and nothing else — and `Weather.wetness` is quantised
    /// into steps before it ever reaches here, because a value drifting by a
    /// thousandth a day would rebuild every lot in the city every tick. Road
    /// wear needed exactly the same treatment for exactly the same reason.
    /// What the wet ground on a tile throws back — the building standing
    /// immediately behind it.
    struct Reflected: Equatable {
        let zone: ZoneType
        let density: Int
        let seed: GridPosition
        /// How many tiles of wet ground lie between this one and the
        /// building: 1 right in front of it, 2 on the tile beyond. Further
        /// from its source, the light is fainter and more broken up.
        var distance: Int = 1
    }

    private func syncReflection(on node: SKNode, tile: Tile, reflecting: Reflected?) {
        let strength = wetness * VisualStyle.current.wetReflection
        // Parenthesised deliberately: `+` binds tighter than `??`, so the
        // obvious spelling of this put the strength on the *fallback* only and
        // a tile that did reflect something was keyed without it.
        let what = reflecting.map {
            "\($0.zone.rawValue)|\($0.density)|\($0.seed.x),\($0.seed.y)|\($0.distance)"
        } ?? "-"
        let key = what + "|\(Int(strength * 100))"
        guard !isUpToDate(node, Self.reflectionNodeName, key) else { return }
        markUpToDate(node, Self.reflectionNodeName, key)
        node.childNode(withName: Self.reflectionNodeName)?.removeFromParent()
        guard strength > 0, let reflecting else { return }
        // The variant comes from the ground the streaks lie on rather than the
        // building casting them, so the two tiles in front of one tower do
        // not carry the same pattern side by side.
        let here = tile.position
        guard let streaks = textures.wetStreaks(variant: here.x &* 7 &+ here.y &* 13) else { return }
        let sprite = SKSpriteNode(texture: streaks.texture, size: streaks.size)
        // Hung from just below the tile's back corner — the point nearest the
        // building — and falling toward the viewer, never past the tile's own
        // front corner: the tile in front is drawn later and opaque, and a
        // streak it paints over is a streak cut off in a straight line.
        sprite.position = CGPoint(x: streaks.offset.x,
                                  y: textures.tileHeight * 0.32 + streaks.offset.y)
        // The building's own neon, which is what a wet street gives back.
        sprite.color = RenderPalette.fullColor(for: reflecting.zone)
        sprite.colorBlendFactor = 1
        // Taller buildings throw brighter light; a two-storey house barely
        // registers, which is right — it has almost nothing lit to throw.
        // Halved on the second tile out, which is what makes the two read as
        // one streak fading rather than two separate marks.
        sprite.alpha = strength * (0.5 + 0.1 * CGFloat(min(reflecting.density, 5)))
            / CGFloat(reflecting.distance)
        // Additive: light returning off a near-black street, not paint on it.
        sprite.blendMode = .add
        sprite.name = Self.reflectionNodeName
        // Under the building and over the ground it is cast on.
        sprite.zPosition = 0.25
        node.addChild(sprite)
    }

    /// An airliner running the length of the runway.
    ///
    /// A child of the airport's own node rather than a path vehicle, because
    /// it never leaves the lot: its depth key is the building's, so there is
    /// nothing to re-sort per frame and an `SKAction` is the cheaper tool. It
    /// joins `animatedBySimulation`, so it stops when the city does — an
    /// aircraft taking off over a paused map is the "cars kept driving" bug
    /// with wings.
    ///
    /// The geometry matches `ServiceMassing.airport`: the runway is a deck
    /// across the front of the lot with a dashed centreline of lit slabs, and
    /// the aircraft runs down the middle of it.
    private func syncAircraft(on node: SKNode, tile: Tile) {
        let key = tile.zone == .airport ? "on" : "off"
        guard !isUpToDate(node, Self.aircraftNodeName, key) else { return }
        markUpToDate(node, Self.aircraftNodeName, key)
        node.childNode(withName: Self.aircraftNodeName)?.removeFromParent()
        guard tile.zone == .airport else { return }

        let sprite = carSprite(.aircraft, alongX: true)
        sprite.name = Self.aircraftNodeName
        sprite.zPosition = 0.35

        let span = CGFloat(ZoneType.airport.footprintSize) - 0.16
        let lane = 0.08 + span * 0.13
        let deck: CGFloat = 0.1
        let start = projection.project(0.2, lane, deck)
        let end = projection.project(span, lane, deck)
        sprite.position = start
        // **Invisible except while moving**, which is the whole basis for
        // drawing it at all. Standing still it is a grey lump on the apron —
        // that is exactly why the static aircraft was cut from
        // `ServiceMassing.airport` — and it only becomes an aircraft once it
        // is running down a lit centreline. Parked at the threshold between
        // departures it would be a lump for half of every cycle, and half of
        // every screenshot.
        sprite.alpha = 0
        // **The runway's ends ride on the sprite, and `GameScene` flies it.**
        //
        // A take-off run is a pure function of elapsed time, so it is driven
        // per frame like everything else that moves — see
        // `GameScene.advanceAircraft`. What has to cross the gap is the
        // geometry, and it crosses *as data* rather than being recomputed at
        // the other end: this file already warns that a second implementation
        // of the projection lines up until the day it does not.
        //
        // `userData` is where this project already hangs per-node facts that
        // belong to the node rather than to a type — the decoration cache
        // keys work the same way.
        sprite.userData = ["x0": start.x, "y0": start.y, "x1": end.x, "y1": end.y]
        node.addChild(sprite)
    }

    private func syncBuilding(on node: SKNode, tile: Tile, shade: Int = 0) {
        // The detail tier is in the key because it is part of what was drawn.
        // Leave it out and crossing the zoom threshold would change what the
        // cache hands back while every tile still reported itself up to date
        // — the map would go on showing the tier it was built at, which is
        // exactly how an overlay once kept painting the view the player had
        // just left.
        let key = "\(tile.zone.rawValue)|\(tile.density)|\(detail)|\(shade)"
        guard !isUpToDate(node, Self.buildingNodeName, key) else { return }
        markUpToDate(node, Self.buildingNodeName, key)
        node.childNode(withName: Self.buildingNodeName)?.removeFromParent()
        guard let sprite = textures.sprite(
            for: tile.zone, density: tile.density, seed: tile.position, at: .zero,
            detail: detail
        ) else { return }
        sprite.name = Self.buildingNodeName
        sprite.zPosition = 0.3
        // **The tint is on the sprite, not in the texture**, which is what
        // makes this affordable at all: one cached variant still serves every
        // lot that draws it, and a lot whose neighbour grew re-tints without
        // rasterising anything. Putting enclosure in the cache key instead
        // would multiply the whole catalogue by six to draw the same building
        // six shades of itself.
        let shadow = Double(shade) / 5 * Self.occlusionDimsBuilding
        if shadow > 0 {
            sprite.color = .black
            sprite.colorBlendFactor = CGFloat(shadow)
        }
        node.addChild(sprite)
    }

    /// The fraction of a lot's own light that survives being enclosed.
    private static func lightLeftAfter(_ shade: Int) -> CGFloat {
        CGFloat(1 - Double(shade) / 5 * occlusionDimsGroundLight)
    }

    // MARK: - Overlays

    /// How an overlay treats the buildings it is drawn over.
    enum OverlayBuildings: Equatable {
        /// Heatmaps — land value, pollution, traffic. The data *is* the
        /// picture, and buildings on top of it are clutter.
        case hidden
        /// A heatmap that also needs to *shout* — the Problems view, where the
        /// point is a lot catching your eye from across the map without being
        /// hunted for. `nil` means this lot is fine and gets nothing at all.
        case flagged(SKColor?)
        /// Water and power. You are routing a network around a city, so you
        /// need to see the city, and the one question you are asking of every
        /// building in it is whether it is on the network.
        ///
        /// **It carries the answer, not a brightness.** This used to be
        /// `dimmed(Double)`, and the call site decided that a supplied
        /// building got 0.85 alpha and an unsupplied one 0.22. Two problems
        /// with that. Brightness alone is a weak channel — a dim building on a
        /// dark map reads as "far away" or "not important", not as "this one
        /// has no water" — and it left the renderer unable to say anything
        /// *else* about the two states, because by the time it got here the
        /// distinction had already been flattened into a number. Passing the
        /// fact itself lets a supplied building be drawn in the utility's own
        /// colour, which is the answer a player can actually read at a glance.
        case connected(Bool)
        /// The utilities that feed the network you are looking at — a water
        /// tower in the water overlay, a power plant in the power overlay.
        /// These are the things the player is hunting for, so they stay at full
        /// brightness and keep their light pool.
        case highlighted
    }

    /// What an overlay does to one tile: how to treat its building, and the
    /// colour to paint its ground.
    struct OverlayPaint {
        let buildings: OverlayBuildings
        /// What to paint the ground.
        let color: SKColor
        /// What to tint the building, when that is a different question from
        /// what to paint the ground under it.
        ///
        /// It is the same colour for water and power, where the ground and the
        /// building are answering the identical yes/no. It is *not* for crime
        /// and fire risk: there the ground carries how strongly the service
        /// reaches this tile — a gradient, so the player can see a catchment's
        /// edge and decide where the next station goes — while the building
        /// carries whether it is in danger, which is a different set. A
        /// factory outside every police catchment is perfectly safe, because
        /// crime does not threaten industry. Sharing one colour tinted those
        /// safe factories to near-black along with the ground they stood on,
        /// and the render showed a map claiming half the city was at risk when
        /// it was not.
        let buildingColor: SKColor

        /// Whether the street network stays drawn — see
        /// `OverlayMode.showsRoadNetwork`.
        ///
        /// On the paint rather than read from the mode at each call site, for
        /// the reason `paint` itself exists: `GameScene` and the render both
        /// have to reach the same answer, and the last time that decision
        /// lived in two places three heatmaps silently painted nothing while
        /// the render cheerfully reported they were fine.
        var showsRoads = false

        /// Whether a building that wants a utility keeps its warning badge —
        /// see `OverlayMode.showsUtilityBadges`. On the paint for the same
        /// reason `showsRoads` is.
        var showsUtilityBadges = false

        init(buildings: OverlayBuildings, color: SKColor, buildingColor: SKColor? = nil) {
            self.buildings = buildings
            self.color = color
            self.buildingColor = buildingColor ?? color
        }
    }

    /// The whole overlay decision, in one place.
    ///
    /// **It lives here because it had already drifted.** `GameScene` held this
    /// as a five-case switch and `IsometricCityTests`' render held a second
    /// copy — and the copy only ever grew the water and power cases, so every
    /// heatmap rendered as an ordinary city and the render quietly reported
    /// that three overlays looked fine while they were painting nothing at
    /// all. That is the same failure this project has recorded before, when
    /// the streetscape painted its own flat tiles while the renderer had moved
    /// on: **a yardstick that reimplements the thing it measures always
    /// reports success.** A pure function of the map is something both callers
    /// can share, which is the only version of this that cannot drift again.
    ///
    /// Returns `nil` for `.none`, which is not an overlay but the absence of
    /// one — the normal view rebuilds its decorations rather than replacing
    /// them, so it has no paint to describe.
    static func paint(
        for mode: OverlayMode, at position: GridPosition, in map: CityMap,
        using distances: ZoneDistanceField?, transit: TransitCoverage? = nil
    ) -> OverlayPaint? {
        // **The badge flag is set here, once, from the mode** — rather than in
        // whichever cases below happen to want it. `showsRoads` is set inside
        // a case and got away with it because exactly one view needs it; a
        // second such flag set the same way is the shape that goes stale, and
        // this file already records three heatmaps silently painting nothing
        // because one decision lived in two places.
        guard var paint = basePaint(for: mode, at: position, in: map,
                                    using: distances, transit: transit) else { return nil }
        paint.showsUtilityBadges = mode.showsUtilityBadges
        return paint
    }

    private static func basePaint(
        for mode: OverlayMode,
        at position: GridPosition,
        in map: CityMap,
        // Optional for the same reason `LandValue.value` takes it that way:
        // the field is precomputed once per full refresh and absent when a
        // single tile is refreshed on its own.
        using distances: ZoneDistanceField?,
        // Same contract: stamped once for a whole sweep, computed here when a
        // single tile is asked about on its own. It is not filtered by mode —
        // `TransitCoverage` knows which line is which, so the Bus overlay
        // cannot be handed the subway's answers by a caller that got it wrong.
        transit: TransitCoverage? = nil
    ) -> OverlayPaint? {
        switch mode {
        case .none:
            return nil
        case .landValue:
            return OverlayPaint(buildings: .hidden, color: RenderPalette.landValueColor(
                for: LandValue.value(at: position, in: map, using: distances)))
        case .pollution:
            return OverlayPaint(buildings: .hidden, color: RenderPalette.pollutionColor(
                for: map.pollution.level(at: position)))
        case .traffic:
            var paint = OverlayPaint(buildings: .hidden, color: RenderPalette.trafficColor(
                for: Traffic.congestion(at: position, in: map)))
            paint.showsRoads = true
            return paint
        case .water:
            // A water tower in the water overlay is the thing the player is
            // hunting for, so it keeps its own colours while everything else
            // is recoloured by whether it is on the network.
            let supplied = Water.hasSupply(at: position, in: map)
            let isSource = map[position].zone == .waterTower || map[position].zone == .waterPump
            return OverlayPaint(
                buildings: isSource ? .highlighted : utilityBuildings(
                    supplied: supplied, wanted: CitySimulator.needsWater(map[map[position].buildingOrigin]),
                    hue: RenderPalette.conduitColor(isPipe: true, live: true)
                ),
                color: RenderPalette.supplyGroundColor(
                    isPipe: true, supplied: supplied,
                    direct: map.waterSupply.isDirectlyServed(at: position)
                ),
                buildingColor: utilityBuildingColor(
                    supplied: supplied, wanted: CitySimulator.needsWater(map[map[position].buildingOrigin]),
                    hue: RenderPalette.conduitColor(isPipe: true, live: true)
                )
            )
        case .problems:
            // Buildings hidden, like every other heatmap: the data *is* the
            // picture here, and a lot's ground diamond is its footprint — so a
            // red diamond names the block as precisely as the building on it
            // would, without anything standing in front of anything else.
            let tile = map[position]
            let status = CitySimulator.status(of: map[tile.buildingOrigin], in: map, using: distances)
            return OverlayPaint(
                buildings: .flagged(
                    status.severity == .fine
                        ? nil
                        : RenderPalette.problemColor(for: status.severity)
                ),
                color: RenderPalette.problemColor(for: status.severity)
            )
        case .police, .fire:
            // **The ground says where the service reaches; the buildings say
            // who is actually in danger.** Those are different sets and a map
            // showing only one of them answers half the question: an
            // industrial block outside every police catchment is not at risk,
            // because crime does not threaten industry, and drawing it as a
            // problem would send the player to build a station it does not
            // need. `CityHazards.isExposed` is the simulation's own condition
            // for whether a strike can land here, so the two cannot disagree.
            let risk = mode == .police ? CityHazards.crime : CityHazards.fire
            let tile = map[position]
            let service = risk.coveringService
            // **The ground now fades out exactly where protection stops.**
            // This was painted from the land-value falloff, which reaches
            // half again as far as a station actually protects — so the
            // outer third of the glow a player uses to site the next station
            // was promising cover that was not there. `ServiceCoverage`
            // answers the question the view is actually asking.
            let coverage = ServiceCoverage.strength(
                at: position, from: service, in: map, using: distances
            )
            let safe = !CityHazards.isExposed(tile, to: risk, in: map, using: distances)
            return OverlayPaint(
                buildings: tile.zone == service ? .highlighted : .connected(safe),
                color: RenderPalette.coverageColor(for: coverage, service: service),
                // Lit means fine and dark means trouble, the same way round as
                // the water and power overlays — one rule to learn across all
                // four, rather than a crime map that runs hot where the others
                // run cold.
                buildingColor: safe
                    ? RenderPalette.fullColor(for: service)
                    : RenderPalette.waterColor(for: false)
            )
        case .bus, .tram, .subway, .rail:
            // Deliberately the same shape as water and power, down to the
            // highlighted source: **lit means served**, and a player who has
            // learned one of the four network overlays has learned all of
            // them. What changes per overlay is the hue and what "served"
            // means, never the reading.
            guard let routeMode = mode.routeMode else { return nil }
            let coverage = transit ?? Transit.coverage(for: map)
            let served = coverage.isServed(at: position, by: routeMode)
            // The stations are what the player is hunting for here — they are
            // the only thing a route can be built out of — so they keep their
            // own colours, the way a tower does in the water overlay.
            let isStation = map[position].zone == routeMode.stationZone
            return OverlayPaint(
                buildings: isStation ? .highlighted : .connected(served),
                color: RenderPalette.transitGroundColor(for: routeMode, served: served),
                buildingColor: served
                    ? RenderPalette.transitLineColor(for: routeMode)
                    : RenderPalette.unlitBuilding
            )
        case .power:
            let supplied = PowerGrid.hasSupply(at: position, in: map)
            let isSource = map[position].zone == .powerPlant || map[position].zone == .generator
            return OverlayPaint(
                buildings: isSource ? .highlighted : utilityBuildings(
                    supplied: supplied, wanted: CitySimulator.needsPower(map[map[position].buildingOrigin]),
                    hue: RenderPalette.conduitColor(isPipe: false, live: true)
                ),
                color: RenderPalette.supplyGroundColor(
                    isPipe: false, supplied: supplied,
                    direct: map.powerSupply.isDirectlyServed(at: position)
                ),
                buildingColor: utilityBuildingColor(
                    supplied: supplied, wanted: CitySimulator.needsPower(map[map[position].buildingOrigin]),
                    hue: RenderPalette.conduitColor(isPipe: false, live: true)
                )
            )
        }
    }

    /// **Three answers, not two.** A utility overlay used to ask "is this
    /// building on the network" of everything on the map, and paint the two
    /// answers lit and dark. But a house too small to need water yet is
    /// neither served nor in trouble, and painting it the same near-black as
    /// a tower dying for want of a main made the map claim a problem that was
    /// not there — precisely the failure the crime overlay had to be fixed
    /// for, where safe factories outside every police catchment were tinted
    /// as though they were at risk.
    ///
    /// So: served is lit in the utility's own hue, *wanting and lacking* is
    /// lit in the loudest colour on the map, and everything else is quiet.
    private static func utilityBuildings(
        supplied: Bool, wanted: Bool, hue: SKColor
    ) -> OverlayBuildings {
        // Lit for both of the states that mean something, dim only for the
        // one that does not.
        .connected(supplied || wanted)
    }

    private static func utilityBuildingColor(
        supplied: Bool, wanted: Bool, hue: SKColor
    ) -> SKColor {
        if supplied { return hue }
        return wanted ? RenderPalette.utilityWanted : RenderPalette.unlitBuilding
    }

    /// Everything an overlay removes, recolours or hides.
    ///
    /// **The list exists so the invalidation can happen once, when the view
    /// changes, rather than once per tile per tick.** It used to be the
    /// latter: `applyOverlay` cleared each cache key every time it ran, on the
    /// entirely sound reasoning that a stale key would mean returning to
    /// Normal restored nothing. But a key cleared every tick is a key that can
    /// never *hit*, and that made it impossible to keep the buildings
    /// themselves up to date — calling `update` first would have rebuilt every
    /// sprite on the map every tick only for this to remove it again, which is
    /// the churn "why the map blinked" records.
    ///
    /// Cleared on the transition instead (`invalidateOverlayNodes`), these
    /// keys behave normally for as long as a view is up: a lot that grows
    /// rebuilds, a lot that does not costs nothing.
    static let overlayDisturbedNodes = [
        markerNodeName, laneNodeName, warningNodeName, damageNodeName,
        constructionNodeName, fireNodeName, buildingNodeName, glowNodeName,
        contactNodeName, smokeNodeName, reflectionNodeName,
    ]

    /// Forgets what this tile is showing, so the next refresh rebuilds all of
    /// it. Called when the view changes — see `overlayDisturbedNodes`.
    /// Forget one decoration, so the next refresh rebuilds it.
    ///
    /// Needed from outside for the reflections: when the weather turns, every
    /// tile's reflection key changes meaning, and the tiles that carry one are
    /// *ground* whose own data has not moved — so nothing else would rebuild
    /// them.
    func invalidateDecoration(_ name: String, on node: SKNode) {
        invalidate(node, name)
    }

    func invalidateOverlayNodes(on node: SKNode) {
        for name in Self.overlayDisturbedNodes { invalidate(node, name) }
    }

    /// Paint a tile as a flat data channel instead of as a building.
    ///
    /// **One call, not ten.** `GameScene`'s top-down overlay handling repeated
    /// a block of ten `clear…` calls in each of five branches, and every
    /// decoration added since had to be remembered in all five — exactly the
    /// kind of repetition that goes stale silently, because a forgotten line
    /// leaves a stray building floating over a heatmap rather than failing
    /// anything.
    func applyOverlay(
        on node: SKNode, buildings: OverlayBuildings, color: SKColor, buildingColor: SKColor? = nil,
        keepingRoads: Bool = false, keepingUtilityBadges: Bool = false
    ) {
        for name in Self.overlayDisturbedNodes
        where name != Self.buildingNodeName && name != Self.glowNodeName
            && !(keepingRoads && name == Self.laneNodeName)
            && !(keepingUtilityBadges && name == Self.warningNodeName) {
            node.childNode(withName: name)?.removeFromParent()
        }

        switch buildings {
        case .hidden:
            node.childNode(withName: Self.buildingNodeName)?.removeFromParent()
            node.childNode(withName: Self.glowNodeName)?.removeFromParent()
        case .flagged(let flag):
            // Hidden like any heatmap, but the lot *glows* rather than merely
            // being coloured in.
            //
            // **Because a tint cannot get bright enough.** `RetroShader` puts
            // scanlines and a vignette over the whole scene, which costs up to
            // 40% of brightness at the edges of the map — so a lot painted in
            // pure red still came out a muted maroon, and the render showed a
            // correct picture nobody would notice they were being shown.
            // Additive light is the one thing that survives a vignette, which
            // is why every other urgent mark in this game (fire, supply,
            // lane lines) is made of it.
            node.childNode(withName: Self.buildingNodeName)?.removeFromParent()
            node.childNode(withName: Self.glowNodeName)?.removeFromParent()
            guard let flag else { break }
            let pool = SKSpriteNode(texture: NeonStyle.glowTexture)
            pool.name = Self.glowNodeName
            pool.color = flag
            pool.colorBlendFactor = 1
            pool.blendMode = .add
            pool.alpha = 0.7
            pool.size = CGSize(width: projection.tileWidth * 2.2,
                               height: projection.tileHeight * 2.2)
            pool.position = projection.project(0.5, 0.5, 0)
            pool.zPosition = 0.2
            node.addChild(pool)
        case .connected(let isSupplied):
            // **The network lights the buildings on it.**
            //
            // This used to repaint the building — 85% toward the utility
            // colour if supplied, 85% toward near-black if not — and both ends
            // were wrong. A supplied building lost the form that says what it
            // *is*, and an unsupplied one sank into the ground until you could
            // not tell a block of flats from bare land, which is exactly what
            // play reported: "it's tough to tell where buildings are in the
            // power/water overlay".
            //
            // So the colour comes from the light it throws rather than from
            // repainting it — the same move this project already made when the
            // map stopped being flat coloured tiles: zone identity "moved from
            // a flat fill into light, which is both more legible against black
            // and the only version of it that looks like night". A building on
            // the network keeps its shape, takes a light wash, and casts a pool
            // of the utility's colour on its lot. One off it desaturates to
            // unlit slate but keeps a readable silhouette.
            if let building = node.childNode(withName: Self.buildingNodeName) as? SKSpriteNode {
                building.color = buildingColor ?? color
                // **Hard, both ways.** At 0.45 and 0.8 the buildings kept so
                // much of their own neon that the two states read as the same
                // picture at slightly different brightness — the overlay went
                // from "everything is mush" to "everything is lit" without
                // ever passing through "these are obviously different". A
                // utility overlay asks exactly one question, and Normal view
                // is where zone identity lives, so it can afford to spend all
                // of its colour on the answer: a dark slate city with the
                // supplied half burning in the utility's own hue.
                building.colorBlendFactor = isSupplied ? 0.78 : 0.92
                // Never below 0.85. Alpha was what made an unsupplied block
                // vanish: at 0.5 over a dark ground there is nothing left to
                // recognise, and "I cannot see it" is not the same message as
                // "it has no water".
                building.alpha = isSupplied ? 1 : 0.85
            }
            // The zone's own light pool, recoloured rather than removed. It is
            // already sized and placed for this lot by `syncGroundGlow`, so
            // lighting a supplied building costs nothing new — and taking it
            // away from an unsupplied one is the other half of the signal.
            if let glow = node.childNode(withName: Self.glowNodeName) as? SKSpriteNode, isSupplied {
                glow.color = buildingColor ?? color
                glow.alpha = 0.55
            } else {
                node.childNode(withName: Self.glowNodeName)?.removeFromParent()
            }
        case .highlighted:
            // The utility feeding the network you are looking at. No tint at
            // all: these are the things the player is hunting for, and the
            // point is that they stand out from everything this overlay has
            // just recoloured.
            if let building = node.childNode(withName: Self.buildingNodeName) as? SKSpriteNode {
                building.colorBlendFactor = 0
                building.alpha = 1
            }
            // And it burns brightest of anything on screen: a source is where
            // the network comes from, and the overlay is largely a question
            // about distance from one.
            if let glow = node.childNode(withName: Self.glowNodeName) as? SKSpriteNode {
                glow.color = buildingColor ?? color
                glow.alpha = 0.7
            }
            invalidate(node, Self.glowNodeName)
        }

        // The ground is recoloured rather than rebuilt, so its own key has to
        // go too or the tint would survive leaving the overlay.
        invalidate(node, Self.groundNodeName)
        // **An `SKSpriteNode`, and it has not been a shape node since the
        // ground was rasterised.** This line read `as? SKShapeNode` from
        // before that change, so the cast quietly returned nil and *every*
        // overlay in the game had been tinting nothing at all — the heatmaps
        // hid the buildings and then painted no data, leaving a blank grid.
        // Same family as `SKAction.colorize` doing nothing on a plain
        // `SKNode`, which this project has already recorded once: changing
        // what a node *is* silently breaks every cast to what it was.
        if let ground = node.childNode(withName: Self.groundNodeName) as? SKSpriteNode {
            ground.color = color
            ground.colorBlendFactor = 1
        }
    }

    /// Undo an overlay's changes when returning to Normal view. The building
    /// node is cached, so it is recoloured in place rather than rebuilt —
    /// which means something has to put it back.
    func restoreFromOverlay(on node: SKNode) {
        guard let building = node.childNode(withName: Self.buildingNodeName) as? SKSpriteNode else { return }
        building.alpha = 1
        building.colorBlendFactor = 0
    }

    // MARK: - Markers

    private static let warningNodeName = "isoWarning"

    /// For the accessibility test, which has to check the glyph a colour
    /// comparison cannot see.
    static var warningNodeNameForTesting: String { warningNodeName }
    private static let damageNodeName = "isoDamage"
    /// Not private, for the same reason `buildingNodeName` is not: a test has
    /// to be able to ask whether a lot is showing a scaffold.
    static let constructionNodeName = "isoConstruction"
    static let constructionDeckName = "isoConstructionDeck"
    /// Not private: tests ask whether a block is drawn as burning.
    static let fireNodeName = "isoFire"
    static let pipeNodeName = "isoPipe"
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

        // **A symbol, not a coloured dot.** This used to be a small outlined
        // disc with an identical bar inside it, so hue was the only thing
        // saying *which* utility was short — and water's blue and power's
        // amber both sit on top of the neon half the city is drawn in. A bolt
        // and a drop are the genre's own symbols and need no legend.
        //
        // See `IsoTextureCache.utilityBadge` for why they are cached and why
        // the badge had to grow to fit them.
        var badges: [Bool] = []
        if missingWater { badges.append(true) }
        if missingPower { badges.append(false) }

        for (index, isWater) in badges.enumerated() {
            guard let rendered = textures.utilityBadge(isWater: isWater) else { continue }
            let badge = SKSpriteNode(texture: rendered.texture, size: rendered.size)
            // Side by side when a block is short of both, which is the state
            // that most wants reading — and the one the old pair of identical
            // discs said least about.
            let spread = badges.count == 2 ? rendered.size.width * 0.56 : 0
            badge.position = CGPoint(x: index == 0 ? -spread : spread, y: 0)
            container.addChild(badge)
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
    /// A block that is on fire *right now*, as opposed to one that burnt
    /// down earlier.
    ///
    /// **The one decoration in the game that animates, and the one that should
    /// be.** Everything else here is a static mark cached on a key, because
    /// `refreshAll()` runs every decoration for every tile every tick and
    /// motion is expensive. A fire is the exception on both counts: there are
    /// a handful of them at most, and the thing that distinguishes an active
    /// disaster from the damage badge sitting next to it is precisely that it
    /// is still happening. A still image of a fire is a picture of a ruin.
    ///
    /// The `SKAction` is attached once, when the node is built, and the cache
    /// key is just "is this burning" — so a fire that goes on burning is not
    /// restarted every tick, which would freeze the animation on its first
    /// frame forever.
    /// **A fire is a sunset standing on a roof.**
    ///
    /// The mark keeps every property the first version earned the hard way —
    /// a silhouette no zone has, standing *above* the roofline, because
    /// height is the one dimension a building cannot compete on — and changes
    /// what fills it. An ember-orange flame was invisible on industry, which
    /// is already orange; a plume running white-hot at the base through
    /// yellow and ember to hot magenta at the tip cannot be swallowed by any
    /// zone, because no zone owns more than one end of that ramp.
    ///
    /// It is also, finally, *on theme*. This game's whole art direction is a
    /// synthwave sunset over a neon grid, and the one thing it had no answer
    /// for was the emergency that most wants your attention. The gradient and
    /// its slats are the sunset motif turned upside down (see
    /// `NeonStyle.sunsetFlameTexture`), so the most urgent thing on the map is
    /// now drawn in the palette the rest of the map is dressed in rather than
    /// in a warning colour borrowed from somewhere else.
    func syncFireMarker(on node: SKNode, tile: Tile) {
        let key = tile.isBurning ? "burning" : "none"
        guard !isUpToDate(node, Self.fireNodeName, key) else { return }
        markUpToDate(node, Self.fireNodeName, key)
        node.childNode(withName: Self.fireNodeName)?.removeFromParent()
        guard tile.isBurning else { return }

        let size = CGFloat(tile.zone.footprintSize)
        let container = SKNode()
        container.name = Self.fireNodeName
        container.zPosition = 0.75

        let top = buildingTop(of: tile)
        let centre = projection.project(size / 2, size / 2, 0)

        // Two pools on the lot, which is what carries once the camera is far
        // enough out that nothing resolves: a wide magenta one with the ember
        // one burning inside it. One pool in one hue is the thing that went
        // missing against industry; a ring of one colour around a core of
        // another is legible on any ground in the game.
        //
        // Both blend additively, and they are *meant* to sum to white where
        // they overlap — a fire has a white-hot centre. That is the one place
        // in this renderer where additive saturation is the intended result
        // rather than the bug recorded three times over in the conduit, route
        // and tram-track passes.
        let halo = SKSpriteNode(texture: NeonStyle.glowTexture)
        halo.color = NeonStyle.signPalette[1]
        halo.colorBlendFactor = 1
        halo.blendMode = .add
        halo.alpha = 0.34
        halo.size = CGSize(width: projection.tileWidth * size * 2.6,
                           height: projection.tileHeight * size * 2.6)
        halo.position = centre
        container.addChild(halo)

        let pool = SKSpriteNode(texture: NeonStyle.glowTexture)
        pool.color = NeonStyle.emberColor
        pool.colorBlendFactor = 1
        pool.blendMode = .add
        pool.alpha = 0.46
        pool.size = CGSize(width: projection.tileWidth * size * 1.5,
                           height: projection.tileHeight * size * 1.5)
        pool.position = centre
        container.addChild(pool)

        // The plume. The path is the silhouette and the texture is the
        // sunset; `fillColor` has to be white because a fill colour
        // *multiplies* the fill texture, so anything else would tint the
        // gradient and undo the point of having one.
        //
        // **Tall and narrow, with a notched foot.** The first pass at this
        // was as wide as it was tall and closed across a flat bottom edge,
        // and magnified it read as a lamp sitting on the roof rather than as
        // something coming out of it. Proportion is what says "plume" — the
        // mark has to be unmistakable in silhouette alone, since at the zoom
        // this game is played at the gradient inside it is four pixels wide.
        let plumeHeight = Swift.max(1.6, top * 1.15)
        let base = projection.project(size / 2, size / 2, top)
        let tip = projection.project(size / 2, size / 2, top + plumeHeight)
        let rise = tip.y - base.y
        let halfWidth = projection.tileWidth * size * 0.15
        let flame = CGMutablePath()
        flame.move(to: CGPoint(x: base.x - halfWidth, y: base.y))
        flame.addQuadCurve(to: tip, control: CGPoint(x: base.x - halfWidth * 1.15,
                                                     y: base.y + rise * 0.55))
        flame.addQuadCurve(to: CGPoint(x: base.x + halfWidth, y: base.y),
                           control: CGPoint(x: base.x + halfWidth * 1.15,
                                            y: base.y + rise * 0.55))
        // Back up to a notch between two licks, so the foot is not a straight
        // line across the building's roof.
        flame.addLine(to: CGPoint(x: base.x, y: base.y + rise * 0.14))
        flame.closeSubpath()
        let plume = SKShapeNode(path: flame)
        plume.fillTexture = NeonStyle.sunsetFlameTexture
        plume.fillColor = .white
        // Magenta on the edge, because neon in this game is an *edge*
        // treatment and the tip is the part that has to stay visible over a
        // lit orange roof. The white stroke the first version used read as a
        // highlight on the building rather than as a thing standing on it.
        plume.strokeColor = NeonStyle.signPalette[1]
        plume.lineWidth = 2
        plume.glowWidth = 4
        plume.alpha = 0.95
        container.addChild(plume)

        // White-hot at the base of the plume. White is the one colour no zone
        // in the game uses, so this reads as fire on a factory and on a tower
        // block alike.
        let core = SKSpriteNode(texture: NeonStyle.glowTexture)
        core.color = .white
        core.colorBlendFactor = 1
        core.blendMode = .add
        // Kept small and well under full brightness: the first version was
        // 0.7 of a tile at alpha 0.95 and blew the whole base of the plume —
        // and the roof under it — to flat white, which threw away the bottom
        // third of the gradient it sits in front of.
        core.alpha = 0.6
        core.size = CGSize(width: projection.tileWidth * size * 0.42,
                           height: projection.tileWidth * size * 0.42)
        core.position = projection.project(size / 2, size / 2, top + plumeHeight * 0.1)
        container.addChild(core)

        // **Embers, as an emitter rather than four sprites.**
        //
        // These were four `SKSpriteNode`s each running its own action, and
        // the count was argued from `minimumDetailSize`: four sparks each
        // carrying real weight beat a cloud of specks averaging into haze.
        // That argument is right about *static* marks and does not hold here
        // — a rising spark is legible by its motion rather than its size.
        //
        // What actually kept it at four was cost. Particles in the scene
        // graph are nodes, evaluated on the CPU every frame, so "a few more
        // sparks" meant a few more of both. `SKEmitterNode` is one node whose
        // particles are simulated and drawn on the GPU, so the honest number
        // goes from four to fifty for less than the four cost.
        let embers = Emitters.embers(scale: projection.tileWidth * size)
        embers.position = CGPoint(x: base.x, y: base.y + (tip.y - base.y) * 0.2)
        embers.zPosition = 0.5
        // The emitter is *ahead* in its own life when it appears, so a block
        // that catches fire is already throwing sparks rather than spending a
        // second and a half filling up.
        embers.advanceSimulationTime(2)
        container.addChild(embers)

        // Three beats of different length, so the flicker never settles into a
        // pulse the eye can predict — the same reason the regional cycle sums
        // two periods rather than running one.
        pool.run(.repeatForever(.sequence([
            .fadeAlpha(to: 0.26, duration: 0.31),
            .fadeAlpha(to: 0.52, duration: 0.23),
        ])))
        halo.run(.repeatForever(.sequence([
            .fadeAlpha(to: 0.2, duration: 0.47),
            .fadeAlpha(to: 0.38, duration: 0.37),
        ])))
        core.run(.repeatForever(.sequence([
            .scale(to: 1.25, duration: 0.17),
            .scale(to: 0.85, duration: 0.29),
        ])))
        plume.run(.repeatForever(.sequence([
            .group([.scaleY(to: 1.18, duration: 0.19), .fadeAlpha(to: 1, duration: 0.19)]),
            .group([.scaleY(to: 0.88, duration: 0.27), .fadeAlpha(to: 0.78, duration: 0.27)]),
        ])))
        node.addChild(container)
    }

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

    /// A lot with work going on: a wireframe of the building that is coming,
    /// and a lit deck that climbs it as the work is done.
    ///
    /// Growth used to be instantaneous, so there was nothing to draw. Now a
    /// lot spends `CitySimulator.constructionTicks(toReach:)` at its old
    /// density before the new storey appears, and without this the player's
    /// entire feedback for zoning is "nothing happened for a while" — which is
    /// indistinguishable from "this lot cannot grow", the thing the utility
    /// badge exists to say. A site that is visibly *building* is the payoff
    /// for the delay, not a decoration on it.
    ///
    /// The wireframe is keyed on the target so it survives the whole build,
    /// and only the deck moves each tick — a construction site is the one
    /// decoration whose appearance changes every single tick, so rebuilding it
    /// the way the damage badge is rebuilt would put the per-tick node churn
    /// CLAUDE.md calls "why the map blinked" back on the busiest lots in the
    /// city.
    func syncConstructionSite(on node: SKNode, tile: Tile) {
        let target = tile.density + 1
        let total = CitySimulator.constructionTicks(toReach: target)
        let key = tile.isUnderConstruction ? "\(tile.zone.rawValue)|\(target)" : "none"
        let existing = node.childNode(withName: Self.constructionNodeName)

        if !isUpToDate(node, Self.constructionNodeName, key) {
            markUpToDate(node, Self.constructionNodeName, key)
            existing?.removeFromParent()
            guard tile.isUnderConstruction else { return }
            node.addChild(makeConstructionSite(for: tile, target: target))
        } else if !tile.isUnderConstruction {
            return
        }

        // Fraction built: `constructionRemaining` counts *down*, so a site
        // that has just been approved is at 0 and one finishing this tick is
        // near 1.
        let remaining = CGFloat(tile.constructionRemaining ?? 0)
        let progress = total > 0 ? max(0, 1 - remaining / CGFloat(total)) : 1
        let site = node.childNode(withName: Self.constructionNodeName)
        let (base, top) = constructionSpan(of: tile, target: target)
        // `project(0, 0, z)` is a pure vertical offset, so raising the deck is
        // one assignment rather than a rebuilt path.
        site?.childNode(withName: Self.constructionDeckName)?.position =
            projection.project(0, 0, (top - base) * progress)
    }

    /// The slice of air a scaffold occupies: from the roof of what stands
    /// there now up to the roof of what is coming.
    ///
    /// **Not from the ground up**, which is what the first version drew and
    /// which the city render showed was wrong. On a lot that already holds a
    /// tier-3 building, a deck starting at ground level spends most of the
    /// build inside the building, invisible, while the cap ring floats
    /// unattached in the sky above it — it read as a stray box hanging over
    /// the block rather than as work being done on it. Growth adds storeys to
    /// what is there, so the scaffold starts where the current roof is.
    private func constructionSpan(of tile: Tile, target: Int) -> (base: CGFloat, top: CGFloat) {
        let base = buildingTop(of: tile)
        let top = buildingTop(zone: tile.zone, density: target, seed: tile.position)
        return (base, max(top, base + 0.5))
    }

    private func makeConstructionSite(for tile: Tile, target: Int) -> SKNode {
        let size = CGFloat(tile.zone.footprintSize)
        let (base, top) = constructionSpan(of: tile, target: target)
        let height = top - base
        let inset: CGFloat = 0.14
        let corners: [(CGFloat, CGFloat)] = [
            (inset, inset), (size - inset, inset),
            (size - inset, size - inset), (inset, size - inset),
        ]

        let container = SKNode()
        container.name = Self.constructionNodeName
        container.zPosition = 0.45
        // Everything inside is drawn relative to the existing roofline, so the
        // deck's own `position` stays a plain 0…height offset.
        container.position = projection.project(0, 0, base)

        // Corner posts and a cap ring: the volume the building will occupy,
        // drawn faintly so it reads as an outline rather than as a building.
        let frame = CGMutablePath()
        for (cx, cy) in corners {
            frame.move(to: projection.project(cx, cy, 0))
            frame.addLine(to: projection.project(cx, cy, height))
        }
        frame.move(to: projection.project(corners[0].0, corners[0].1, height))
        for (cx, cy) in corners.dropFirst() + [corners[0]] {
            frame.addLine(to: projection.project(cx, cy, height))
        }
        let wireframe = SKShapeNode(path: frame)
        wireframe.strokeColor = NeonStyle.scaffoldColor.withAlphaComponent(0.5)
        wireframe.lineWidth = 1.5
        container.addChild(wireframe)

        // The deck: a bright closed ring at the height reached so far. This is
        // the part that carries the information, so it is the part that glows
        // — at a zoomed-out size the posts fade to nothing and this is still
        // legibly a lit line rising out of a lot.
        let deckPath = CGMutablePath()
        deckPath.move(to: projection.project(corners[0].0, corners[0].1, 0))
        for (cx, cy) in corners.dropFirst() + [corners[0]] {
            deckPath.addLine(to: projection.project(cx, cy, 0))
        }
        let deck = SKShapeNode(path: deckPath)
        deck.name = Self.constructionDeckName
        deck.strokeColor = NeonStyle.scaffoldColor
        deck.lineWidth = 2.5
        deck.glowWidth = 2
        container.addChild(deck)
        return container
    }

    /// Underground networks, drawn only in their own overlay — the one place a
    /// pipe or a power line is visible at all.
    /// One segment per cell of the building this node stands for — see
    /// `Segment`, and `syncConduits(on:for:in:isPipe:)` which builds them.
    ///
    /// **A node exists per *building*, not per tile**, which is what keeps a
    /// built-out map at 2.6 nodes a lot. A pipe, though, is an underground
    /// layer that goes under anything — including the three cells of a 2×2
    /// building that are not its anchor, and those cells have no node of
    /// their own to be drawn on. Reported from play as "you can't put a pipe
    /// under a building": the pipe was laid, it was live, it supplied water,
    /// and it was **invisible**, so a run across a block appeared on the bare
    /// ground either side and vanished in the middle. Worse, the visible
    /// neighbours' masks still read `hasPipe` correctly and drew a stub
    /// pointing into the gap, so the run looked severed rather than hidden.
    func syncConduit(on node: SKNode, present: Bool, isPipe: Bool, mask: Int, live: Bool) {
        syncConduits(on: node, isPipe: isPipe,
                     segments: present ? [Segment(offset: GridPosition(x: 0, y: 0), mask: mask, live: live)] : [])
    }

    /// One cell's worth of buried network: where it sits relative to the
    /// building's anchor, how it connects, and whether it is live.
    struct Segment: Equatable {
        /// In tile units from the anchor — `(0, 0)` for the anchor itself.
        var offset: GridPosition
        var mask: Int
        var live: Bool
    }

    func syncConduits(on node: SKNode, isPipe: Bool, segments: [Segment]) {
        let name = isPipe ? Self.pipeNodeName : Self.powerNodeName
        let key = segments.isEmpty
            ? "none"
            : segments.map { "\($0.offset.x),\($0.offset.y),\($0.mask),\($0.live)" }.joined(separator: "|")
        guard !isUpToDate(node, name, key) else { return }
        markUpToDate(node, name, key)
        for existing in node.children where existing.name == name { existing.removeFromParent() }
        for segment in segments {
            addConduit(to: node, named: name, segment: segment, isPipe: isPipe)
        }
    }

    private func addConduit(to node: SKNode, named name: String, segment: Segment, isPipe: Bool) {
        guard let rendered = textures.conduit(isPipe: isPipe, mask: segment.mask, live: segment.live) else { return }
        let live = segment.live

        let line = SKSpriteNode(texture: rendered.texture, size: rendered.size)
        line.name = name
        // The projection is linear through the origin, so a cell's offset from
        // the anchor projects to exactly the difference between the two.
        let shift = projection.project(CGFloat(segment.offset.x), CGFloat(segment.offset.y), 0)
        line.position = CGPoint(x: rendered.offset.x + shift.x, y: rendered.offset.y + shift.y)
        // Additive, like the lane lines: a straight run brightens where tiles
        // meet and reads as one continuous length of live wire rather than a
        // chain of separately-lit squares. A dead conduit is drawn dark, so
        // adding it contributes almost nothing — which is exactly right.
        line.blendMode = live ? .add : .alpha
        // **Above every building on the map, not just above this tile.**
        // Tile nodes are depth-sorted, so at any ordinary `zPosition` a
        // conduit is hidden by whatever stands in front of it — which for a
        // buried network is most of the city, and which made the water
        // overlay a picture of pipes you could not see. In its own overlay
        // the network is a *schematic*: the one thing the player came here to
        // look at, drawn over the city rather than inside it. A thousand
        // clears the largest depth any map can produce (`Isometric.depth`
        // tops out near twice the map's dimension).
        line.zPosition = 1_000
        node.addChild(line)
    }

    /// The rails a tram runs on, drawn on the street they were taken from.
    ///
    /// **The Tram view is the only transit overlay with something to say about
    /// the ground**, because a tram is the only mode that costs the road
    /// anything — see `Traffic.tramLaneShare`. Showing the catchment without
    /// showing which streets paid for it would hide half the decision.
    ///
    /// Drawn as a bright core down the tile rather than a fill, so it reads as
    /// rails *in* a street rather than as a coloured street — the same reason
    /// the conduit overlay draws a line and not a tinted tile.
    func syncTramTrack(on node: SKNode, present: Bool, mask: Int) {
        let name = Self.tramTrackName
        let key = present ? "\(mask)" : "none"
        guard !isUpToDate(node, name, key) else { return }
        markUpToDate(node, name, key)
        node.childNode(withName: name)?.removeFromParent()
        guard present, let rendered = textures.conduit(isPipe: true, mask: mask, live: true) else { return }

        let rails = SKSpriteNode(texture: rendered.texture, size: rendered.size)
        rails.name = name
        rails.position = rendered.offset
        rails.color = RenderPalette.transitLineColor(for: .tram)
        rails.colorBlendFactor = 1
        // **Not additive, and the render is why** — the third time this trap
        // has been walked into in this module. Additively, adjacent track
        // tiles sum where they meet and the run saturates to cyan-white: it
        // stopped reading as teal rails in a street and became a river of
        // light, brighter than the route line it is supposed to sit beneath.
        // The texture carries its own bloom; the blend does not need to add
        // one.
        rails.blendMode = .alpha
        rails.alpha = 0.85
        // Above the city like the buried networks, and below the route
        // diagram, which is the thing the player came to this view to read.
        rails.zPosition = 1_000
        node.addChild(rails)
    }

    static let tramTrackName = "tramTrack"

    /// Every working line of one mode, drawn as a diagram over the city.
    ///
    /// **Schematic, not geographic.** The line runs straight from station to
    /// station rather than tracing the streets a bus would actually use, and
    /// that is the honest drawing of what a route *is* here: this module has
    /// no track layer, and what the player authored is the claim that these
    /// stations are on one line. A bus route drawn along roads would be a
    /// picture of a path nothing in the simulation stores. Every transit map
    /// worth reading is a diagram for the same reason, and a straight neon run
    /// between lit nodes is about as retrowave as this project gets.
    ///
    /// **One node for the whole thing, not one per tile.** A route spans
    /// arbitrary distance, so it cannot be a tile-local mask the way a conduit
    /// is; and since there are a handful of routes rather than thousands of
    /// tiles, `SKShapeNode`'s refusal to batch costs nothing here.
    ///
    /// Returns `nil` when the mode has nothing in service, so a caller can
    /// skip adding an empty node.
    /// The crisp core of a route's line — named so a test can tell it from the
    /// halo around it and the marks along it.
    static let transitLineName = "transitLine"
    static let transitStopName = "transitStop"
    static let transitDraftName = "transitDraft"

    func transitDiagram(
        for mode: TransitRoute.Mode, in map: CityMap, drawing draft: TransitRouteDraft? = nil
    ) -> SKNode? {
        let color = RenderPalette.transitLineColor(for: mode)
        let container = SKNode()
        // A draft for the *other* kind of line is not this view's business.
        let draft = draft?.mode == mode ? draft : nil

        // **The line being drawn is drawn.** Without it the editor is a list
        // of stops in a panel and a map that looks no different after a click
        // than before it — and the whole reason to build a route by clicking
        // stations rather than picking them from a menu is to see the shape
        // the line makes across the city.
        if let stops = draft?.stops, !stops.isEmpty {
            let marks = SKNode()
            marks.name = Self.transitDraftName
            // Above the finished lines, which are added after it. The render
            // showed why: where a draft calls at a station an existing route
            // already uses — which is most of them, since both are built out
            // of the same handful of buildings — the running line's own stop
            // mark painted over the draft's, and the line you were drawing
            // lost its stops to the ones you drew last week.
            marks.zPosition = 10
            let points = stops.map {
                projection.centerPoint(ofFootprintOrigin: $0, size: mode.stationZone.footprintSize)
            }
            if points.count >= 2 {
                let path = CGMutablePath()
                path.move(to: points[0])
                for point in points.dropFirst() { path.addLine(to: point) }
                let line = SKShapeNode(path: path)
                line.strokeColor = NeonStyle.scaffoldColor
                line.lineWidth = 2
                line.lineCap = .round
                line.lineJoin = .round
                // Dashed, and in the amber a construction scaffold already
                // uses: this is the one line on the diagram that is not a
                // route yet, and "not finished" is a state this game has
                // already picked a colour and a texture for.
                if let dashed = line.path?.copy(dashingWithPhase: 0, lengths: [7, 5]) {
                    line.path = dashed
                }
                marks.addChild(line)
            }
            for (index, point) in points.enumerated() {
                let pip = SKShapeNode(circleOfRadius: max(projection.tileWidth * 0.14, 4))
                pip.position = point
                pip.fillColor = NeonStyle.scaffoldColor
                pip.strokeColor = RenderPalette.background
                pip.lineWidth = 1.5
                // The stop you would take off by clicking again sits on top,
                // so an accidental double-click is visibly undoable.
                pip.zPosition = index == points.count - 1 ? 1 : 0
                marks.addChild(pip)
            }
            container.addChild(marks)
        }

        for route in map.transit.routes(mode: mode) {
            // A line being edited is drawn as the draft above, not twice —
            // otherwise its old shape sits under the new one and the two
            // disagree about where the route goes.
            if let draft, draft.editing == route.id { continue }
            // The same "what works, not what was drawn" filter
            // `Transit.coverage` applies — a stop whose station has been
            // bulldozed is not on the map, so it must not be on the diagram
            // either, or the line would be drawn to a place with nothing
            // there.
            let working = Transit.workingStops(of: route, in: map)
            guard working.count >= TransitRoute.minimumStops else { continue }

            let path = CGMutablePath()
            for (index, stop) in working.enumerated() {
                let point = projection.centerPoint(ofFootprintOrigin: stop, size: mode.stationZone.footprintSize)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }

            // Two passes rather than `glowWidth`, the same trick the buildings
            // and the sparkline use: a wide faint copy under a crisp core.
            // `glowWidth` on a line this long was what made the first conduits
            // "a smear that swamped the tiles either side".
            let halo = SKShapeNode(path: path)
            halo.strokeColor = color.withAlphaComponent(0.26)
            halo.lineWidth = 10
            halo.lineCap = .round
            halo.lineJoin = .round
            halo.blendMode = .add
            container.addChild(halo)

            // **The core is not additive, and the render is why.** Drawn
            // additively over its own halo it saturated to a white-pink
            // filament and the line stopped carrying the one thing its colour
            // is for — which is exactly the mistake recorded for the first
            // conduits, whose "additive overlap plus bloom saturated the run
            // to white". The bloom around it is the additive half; the line
            // itself stays the hue it was given.
            let line = SKShapeNode(path: path)
            line.name = Self.transitLineName
            line.strokeColor = color
            line.lineWidth = 2.5
            line.lineCap = .round
            line.lineJoin = .round
            container.addChild(line)

            // A node at every stop, because a line with no marks on it says
            // how the route runs but not where you can get on it — and where
            // you can get on it is the thing the player is placing.
            //
            // A dark ring with a lit centre, the way a transit map draws an
            // interchange: the dark band separates the stop from the line
            // running through it, and the lit dot is what survives being
            // eleven points across. A hollow ring read as a *hole* in the
            // line at this size, which is the opposite of a station.
            for stop in working {
                let center = projection.centerPoint(ofFootprintOrigin: stop, size: mode.stationZone.footprintSize)
                let radius = max(projection.tileWidth * 0.20, 5)
                let ring = SKShapeNode(circleOfRadius: radius)
                ring.name = Self.transitStopName
                ring.position = center
                ring.strokeColor = color
                ring.lineWidth = 2
                ring.fillColor = RenderPalette.background
                container.addChild(ring)

                let dot = SKShapeNode(circleOfRadius: radius * 0.45)
                dot.position = center
                dot.strokeColor = .clear
                dot.fillColor = color
                container.addChild(dot)
            }
        }
        return container.children.isEmpty ? nil : container
    }

    /// How tall the building on a tile stands, in tile units — needed to put
    /// anything *above* it.
    private func buildingTop(of tile: Tile) -> CGFloat {
        buildingTop(zone: tile.zone, density: tile.density, seed: tile.position)
    }

    /// The same measurement for a building that does not exist yet, which is
    /// what a construction site needs: the scaffold has to be the size of the
    /// building that is *coming*, not the one standing there now.
    ///
    /// It asks `ZoneMassing` for the massing rather than measuring the
    /// rasterised sprite, so the answer is available for a density the cache
    /// has never been asked to draw.
    private func buildingTop(zone: ZoneType, density: Int, seed: GridPosition) -> CGFloat {
        guard let massing = ZoneMassing.make(
            for: zone, density: density,
            seed: IsoTextureCache.canonicalSeed(for: IsoTextureCache.variant(for: seed))
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

    static var flashNodeNameForTesting: String { flashNodeName }

    /// A car sprite, from the cache.
    ///
    /// Cars were three shape nodes and a trail each. A busy city has hundreds
    /// of them moving at once, which is the worst possible thing to be drawing
    /// with shape nodes — so they are rasterised like everything else that
    /// repeats, and there are exactly two of them: one per road diagonal.
    func carSprite(_ vehicle: IsoTextureCache.Vehicle = .car,
                   alongX: Bool, braking: Bool = false) -> SKNode {
        guard let rendered = textures.car(vehicle, alongX: alongX, braking: braking)
        else { return SKNode() }
        let sprite = SKSpriteNode(texture: rendered.texture, size: rendered.size)
        sprite.position = rendered.offset
        return sprite
    }

    // MARK: - Roads

    /// A glowing centre line along each direction a road connects in.
    ///
    /// Drawn from the tile's centre out to the midpoint of each connected
    /// edge, so a straight run joins seamlessly and a junction reads as a
    /// junction without any tile needing to know more than its own neighbours.
    func syncLaneLine(
        on node: SKNode,
        zone: ZoneType,
        connections: Traffic.RoadConnections,
        condition: Double = 1
    ) {
        let mask = (connections.east ? 1 : 0) | (connections.west ? 2 : 0)
            | (connections.north ? 4 : 0) | (connections.south ? 8 : 0)
        // Condition is quantised into five steps rather than keyed raw.
        // `Infrastructure.advance` moves wear by a thousandth of a tick, so a
        // raw key would miss on every tile every tick and rebuild the entire
        // street grid once a second — precisely the churn CLAUDE.md records as
        // "why the map blinked". Five steps is more than the eye resolves in a
        // glow's brightness anyway.
        let step = Swift.max(0, Swift.min(4, Int(condition * 4.999)))
        let key = "\(zone.rawValue)|\(mask)|\(step)"
        guard !isUpToDate(node, Self.laneNodeName, key) else { return }
        markUpToDate(node, Self.laneNodeName, key)
        node.childNode(withName: Self.laneNodeName)?.removeFromParent()
        guard zone == .road || zone == .highway else { return }

        guard let rendered = textures.lane(for: zone, mask: mask) else { return }
        let lane = SKSpriteNode(texture: rendered.texture, size: rendered.size)
        lane.name = Self.laneNodeName
        lane.position = rendered.offset
        // Additive, so a straight run of road brightens where tiles meet and
        // reads as one continuous glowing seam rather than a chain of
        // separately-lit squares — the thing that makes the street grid look
        // like neon tube and not like painted markings.
        lane.blendMode = .add
        // A worn road's neon goes out. Brightness rather than colour, because
        // the lane line is already the one thing on the map whose *hue* says
        // which kind of road it is — recolouring it would trade a fact the
        // player needs for one they can get from the Roads meter. A dark
        // street in a lit grid reads as neglect at any zoom, which is the only
        // property that matters here.
        //
        // **Pavement is not the subject.** A well-kept lane used to draw at
        // alpha 1.0 — full-saturation magenta, additively, with a glow, on
        // about a third of the tiles on the map. That made the street grid
        // the brightest thing in frame everywhere at once, and the buildings,
        // which are what a player is actually looking at, had to compete with
        // the road they stand on. This file has recorded that exact mistake
        // before ("the brightest thing in frame should be a building, not the
        // pavement") and it drifted back.
        //
        // A highway keeps more of its brightness than a street does, which is
        // also the first time the two have differed by anything but hue and
        // width: an arterial should read as the bigger road from across the
        // map.
        let lit = zone == .highway ? VisualStyle.current.highwayLaneAlpha
                                   : VisualStyle.current.roadLaneAlpha
        lane.alpha = lit * (0.35 + 0.65 * Double(step) / 4)
        lane.zPosition = 0.25
        node.addChild(lane)
    }
}
