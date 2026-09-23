import SpriteKit  // for SKColor, which the whole palette is written in

/// **What each view says about each tile**, owned once and shared by both
/// renderers (M8): the SpriteKit tile renderer until it is deleted, the Metal
/// overlay (`MetalOverlay`) after. Moved out of `IsoTileRenderer.swift` so
/// the decision survives that file, under the same names.
extension IsoTileRenderer {

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
        /// the reason `paint` itself exists: the Metal renderer and the tests
        /// both have to reach the same answer, and the last time that decision
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
        case .land:
            // Buildings hidden: the question is where the city can go next,
            // and the answer is a shape on the ground. A map with no land
            // budget reads as owned everywhere, which is the truth.
            let land = map.land
            let parcel = land?.parcel(containing: position)
            let owned = map.isOwned(position)
            let forSale = !owned && parcel.map { land?.touchesOwnedLand($0) ?? false } ?? false
            let alternate = parcel.map { ($0.x + $0.y) % 2 == 1 } ?? false
            let color = RenderPalette.landColor(owned: owned, forSale: forSale, alternate: alternate)
            // **Lit, not tinted**, for the reason the Problems view found: a
            // tint multiplies into near-black ground and then loses up to 40%
            // more to the vignette, and the first render of this view came out
            // maroon and navy. Additive light is what survives, so owned and
            // for-sale land glow and land out of reach simply stays dark.
            return OverlayPaint(buildings: .flagged(owned || forSale ? color : nil), color: color)
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

    /// Which utility badges a building wears: one short of water or power
    /// from the level before the one that needs it, so the warning arrives
    /// while there is still time to answer it. Shared by both renderers.
    static func missingUtilities(of tile: Tile, hasWaterSupply: Bool,
                                 hasPowerSupply: Bool) -> (water: Bool, power: Bool) {
        (tile.density >= CitySimulator.waterRequiredFromLevel - 1 && !hasWaterSupply,
         tile.density >= CitySimulator.powerRequiredFromLevel - 1 && !hasPowerSupply)
    }

    // MARK: - Enclosure

}
