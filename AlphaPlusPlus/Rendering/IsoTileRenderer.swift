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

    private static let groundNodeName = "isoGround"
    private static let glowNodeName = "isoGroundGlow"
    private static let markerNodeName = "isoZoneMarker"
    /// Not private: tests need to ask whether *the building* is showing, and
    /// now that ground and lane lines are rasterised too, "is there a textured
    /// sprite here" no longer answers that question.
    static let buildingNodeName = "isoBuilding"
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
    func makeNode(for tile: Tile) -> SKNode {
        let footprint = tile.zone.footprintSize
        let node = SKNode()
        node.name = Self.nodeName(for: tile.position)
        node.position = projection.project(CGFloat(tile.position.x), CGFloat(tile.position.y), 0)
        node.zPosition = Isometric.depth(of: tile.position, footprint: footprint)
        update(node, for: tile)
        return node
    }

    /// Re-sync an existing node to current tile data, mutating rather than
    /// rebuilding: no allocation, no scene-graph churn, and it scales to a
    /// full-map refresh every simulation tick.
    func update(_ node: SKNode, for tile: Tile) {
        syncGround(on: node, tile: tile)
        syncGroundGlow(on: node, tile: tile)
        syncZoneMarker(on: node, tile: tile)
        syncBuilding(on: node, tile: tile)
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

        guard let rendered = textures.ground(
            for: tile.zone, density: tile.density, footprint: tile.zone.footprintSize
        ) else { return }
        let ground = SKSpriteNode(texture: rendered.texture, size: rendered.size)
        ground.name = Self.groundNodeName
        ground.position = rendered.offset
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

        let glow = SKSpriteNode(texture: NeonStyle.glowTexture)
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

    private func syncBuilding(on node: SKNode, tile: Tile) {
        let key = "\(tile.zone.rawValue)|\(tile.density)"
        guard !isUpToDate(node, Self.buildingNodeName, key) else { return }
        markUpToDate(node, Self.buildingNodeName, key)
        node.childNode(withName: Self.buildingNodeName)?.removeFromParent()
        guard let sprite = textures.sprite(
            for: tile.zone, density: tile.density, seed: tile.position, at: .zero
        ) else { return }
        sprite.name = Self.buildingNodeName
        sprite.zPosition = 0.3
        node.addChild(sprite)
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
            return OverlayPaint(buildings: .hidden, color: RenderPalette.trafficColor(
                for: Traffic.congestion(at: position, in: map)))
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
            let coverage = LandValue.falloffValue(
                nearestZone: service,
                falloffDistance: LandValue.serviceFalloffDistance,
                at: position, in: map, using: distances
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
    ]

    /// Forgets what this tile is showing, so the next refresh rebuilds all of
    /// it. Called when the view changes — see `overlayDisturbedNodes`.
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
        on node: SKNode, buildings: OverlayBuildings, color: SKColor, buildingColor: SKColor? = nil
    ) {
        for name in Self.overlayDisturbedNodes where name != Self.buildingNodeName && name != Self.glowNodeName {
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
            disc.fillColor = NeonStyle.silhouetteFill
            disc.strokeColor = color
            disc.lineWidth = 2
            disc.glowWidth = 2
            container.addChild(disc)
            container.addChild(NeonStyle.detail(
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

        // A pool of ember light on the lot, which is what carries once the
        // camera is far enough out that nothing resolves.
        let pool = SKSpriteNode(texture: NeonStyle.glowTexture)
        pool.color = NeonStyle.emberColor
        pool.colorBlendFactor = 1
        pool.blendMode = .add
        pool.alpha = 0.5
        pool.size = CGSize(width: projection.tileWidth * size * 1.9,
                           height: projection.tileHeight * size * 1.9)
        pool.position = projection.project(size / 2, size / 2, 0)
        container.addChild(pool)

        // **And a plume, because colour alone was not enough.** The first
        // version was an ember-coloured glow and nothing else, and the city
        // render showed exactly what is wrong with that: an industrial
        // building is *already* orange, so a fire on one was indistinguishable
        // from the building's own neon. Same mistake as the road button that
        // came out black on black — a mark whose only channel is hue vanishes
        // on anything that shares the hue.
        //
        // So the fire gets a silhouette no zone has: a tall flame standing
        // above the roofline, white at the base where it is hottest. Height is
        // the one dimension a building cannot compete on, since the plume
        // starts where the building stops.
        let plumeHeight = Swift.max(1.2, top * 0.9)
        let base = projection.project(size / 2, size / 2, top)
        let tip = projection.project(size / 2, size / 2, top + plumeHeight)
        let halfWidth = projection.tileWidth * size * 0.2
        let flame = CGMutablePath()
        flame.move(to: CGPoint(x: base.x - halfWidth, y: base.y))
        flame.addQuadCurve(to: tip, control: CGPoint(x: base.x - halfWidth * 1.1,
                                                     y: base.y + (tip.y - base.y) * 0.65))
        flame.addQuadCurve(to: CGPoint(x: base.x + halfWidth, y: base.y),
                           control: CGPoint(x: base.x + halfWidth * 1.1,
                                            y: base.y + (tip.y - base.y) * 0.65))
        flame.closeSubpath()
        let plume = SKShapeNode(path: flame)
        plume.fillColor = NeonStyle.emberColor
        plume.strokeColor = .white
        plume.lineWidth = 2
        plume.glowWidth = 3
        plume.alpha = 0.9
        container.addChild(plume)

        // White-hot at the base of the plume. White is the one colour no zone
        // in the game uses, so this reads as fire on a factory and on a tower
        // block alike.
        let core = SKSpriteNode(texture: NeonStyle.glowTexture)
        core.color = .white
        core.colorBlendFactor = 1
        core.blendMode = .add
        core.alpha = 0.95
        core.size = CGSize(width: projection.tileWidth * size * 0.7,
                           height: projection.tileWidth * size * 0.7)
        core.position = projection.project(size / 2, size / 2, top + plumeHeight * 0.15)
        container.addChild(core)

        // Three beats of different length, so the flicker never settles into a
        // pulse the eye can predict — the same reason the regional cycle sums
        // two periods rather than running one.
        pool.run(.repeatForever(.sequence([
            .fadeAlpha(to: 0.28, duration: 0.31),
            .fadeAlpha(to: 0.55, duration: 0.23),
        ])))
        core.run(.repeatForever(.sequence([
            .scale(to: 1.25, duration: 0.17),
            .scale(to: 0.85, duration: 0.29),
        ])))
        plume.run(.repeatForever(.sequence([
            .group([.scaleY(to: 1.18, duration: 0.19), .fadeAlpha(to: 1, duration: 0.19)]),
            .group([.scaleY(to: 0.88, duration: 0.27), .fadeAlpha(to: 0.75, duration: 0.27)]),
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

    /// A car sprite, from the cache.
    ///
    /// Cars were three shape nodes and a trail each. A busy city has hundreds
    /// of them moving at once, which is the worst possible thing to be drawing
    /// with shape nodes — so they are rasterised like everything else that
    /// repeats, and there are exactly two of them: one per road diagonal.
    func carSprite(alongX: Bool) -> SKNode {
        guard let rendered = textures.car(alongX: alongX) else { return SKNode() }
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
        lane.alpha = 0.35 + 0.65 * Double(step) / 4
        lane.zPosition = 0.25
        node.addChild(lane)
    }
}
