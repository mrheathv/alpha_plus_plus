import Foundation

/// A fire that is still burning, and what it does to the block next door.
///
/// **Why this exists.** `CityHazards` strikes a building and stops: one lot
/// loses density, records `damagedBy`, and the event is over inside the tick
/// it happened. That is a *hazard*, and it is doing its job — but it is not a
/// disaster, because a disaster has a time dimension and a spatial one. It
/// unfolds over several ticks, it threatens to get worse, and it asks the
/// player to do something *now* rather than eventually.
///
/// So a fire strike now leaves the block alight, and a fire that is alight
/// reaches for its neighbours. Everything `CityHazards` did before it still
/// happens on the tick of the strike — the density loss, the `damagedBy`, the
/// reported `Strike` — so this is propagation layered on top of that contract
/// rather than a replacement for it.
///
/// **What it does to the fire station.** A fire station used to be pure
/// prevention: coverage lowered the chance of a strike and had no say once one
/// landed. Now it also decides whether one burning lot becomes one burnt lot
/// or a burnt district. That is a second, different job for a building that
/// had only one, and it is the job a fire service actually does.
///
/// **And the player has an answer right now.** Bulldozing a burning lot puts
/// the fire out — `GameController.clearBuilding` replaces the tile, which
/// takes `fireTicks` with it. It costs you the building, which is exactly the
/// trade a firebreak is. That matters because this project holds every warning
/// the game raises to having an answer the player can act on immediately, and
/// "wait and see whether your fire station is close enough" is not one.
enum Fire {

    // MARK: - Rates

    /// Per-tick chance an uncontained fire burns itself out.
    ///
    /// A fire lasts about four ticks on average with nobody fighting it, which
    /// is long enough for the spread rolls below to matter and short enough
    /// that a city is never permanently on fire. The two numbers are a pair:
    /// what decides how far a fire travels is how many spread rolls it gets
    /// before this one lands.
    static let burnoutChancePerTick = 0.25

    /// Per-tick chance a burning block sets *one particular* neighbour alight.
    ///
    /// Rolled per adjacent building rather than once per fire, so a fire in a
    /// dense block with neighbours on four sides is genuinely more dangerous
    /// than one on the edge of town — which is the whole reason to model
    /// spread spatially instead of just making the hazard bigger.
    static let spreadChancePerTick = 0.18

    /// What fire-station coverage does to those two rates.
    ///
    /// Coverage does not make a block fireproof — being inside a fire
    /// station's reach is what prevents the strike, and a covered block
    /// that burns anyway got unlucky. What coverage buys is *containment*: the
    /// fire goes out roughly three times faster and is about seven times less
    /// likely to jump. The asymmetry is deliberate. A fire service that merely
    /// shortened fires would read as a smaller number; one that stops them
    /// travelling is the difference between an incident and a disaster, and
    /// that difference is the thing the player is buying.
    static let containedBurnoutMultiplier = 3.0
    static let containedSpreadMultiplier = 0.15

    // MARK: - The tick

    /// One tick of every fire currently burning: it goes out, or it reaches.
    ///
    /// Returns the positions it newly set alight so `GameController` can
    /// report them the same way it reports `CityHazards.Strike`s — a fire
    /// jumping to the next block is exactly as much a thing that just happened
    /// to the player as the original strike was.
    static func advance<RNG: RandomNumberGenerator>(
        _ map: CityMap, using rng: inout RNG
    ) -> (map: CityMap, ignited: [CityHazards.Strike]) {
        var next = map
        var ignited: [CityHazards.Strike] = []
        let distances = ZoneDistanceField.compute(for: map)

        // Sorted, because which fire gets to a shared neighbour first decides
        // who ignites it, and `map.tiles` order is stable but the set of
        // burning anchors should not depend on anything else. The same
        // determinism `Traffic.computeLoad` had to be taught the hard way.
        let burning = map.tiles
            .filter { $0.isBuildingAnchor && $0.isBurning }
            .map(\.position)
            .sortedByPosition()

        for origin in burning {
            let tile = map[origin]
            let footprint = map.footprintCells(origin: origin, size: tile.zone.footprintSize)
            let contained = isContained(footprint, in: map, using: distances)

            // **Burnout is checked before spread, and that ordering is load
            // bearing.** A fire that is going out this tick is not also
            // reaching for the next block — the same "do one thing or the
            // other, never both" exclusivity `CitySimulator.advance` keeps
            // between growing and being abandoned.
            let burnout = burnoutChancePerTick * (contained ? containedBurnoutMultiplier : 1)
            if Double.random(in: 0 ..< 1, using: &rng) < burnout {
                for cell in footprint { next[cell].fireTicks = nil }
                continue
            }

            for cell in footprint { next[cell].fireTicks = (tile.fireTicks ?? 0) + 1 }

            let spread = spreadChancePerTick * (contained ? containedSpreadMultiplier : 1)
            for target in neighbouringBuildings(of: footprint, in: map) {
                // Read `next`, not `map`: a block set alight earlier in this
                // same sweep must not be ignited twice, and must not have its
                // damage applied twice either.
                guard !next[target].isBurning else { continue }
                guard Double.random(in: 0 ..< 1, using: &rng) < spread else { continue }
                ignite(target, in: &next, using: distances)
                ignited.append(CityHazards.Strike(position: target, coveringService: .fireStation))
            }
        }
        return (next, ignited)
    }

    /// Set a block alight, with the same consequences a `CityHazards` fire
    /// strike has: it loses density, it records what service would have
    /// prevented it, and a hospital in range halves the damage.
    ///
    /// Routed through `CityHazards.fire` rather than carrying its own
    /// damage number, because "what a fire costs a building" should have one
    /// definition. A fire that arrives by spreading is the same fire.
    private static func ignite(
        _ origin: GridPosition, in map: inout CityMap, using distances: ZoneDistanceField
    ) {
        let footprint = map.footprintCells(origin: origin, size: map[origin].zone.footprintSize)
        let damage = CityHazards.damage(
            from: CityHazards.fire, to: footprint, in: map, using: distances
        )
        for cell in footprint {
            map[cell].density = Swift.max(0, map[cell].density - damage)
            map[cell].damagedBy = .fireStation
            map[cell].fireTicks = 0
        }
    }

    /// Is the fire brigade on this block?
    private static func isContained(
        _ footprint: [GridPosition], in map: CityMap, using distances: ZoneDistanceField
    ) -> Bool {
        ServiceCoverage.serves(footprint, .fireStation, in: map, using: distances)
    }

    /// Every building a fire on `footprint` could jump to: the anchors of the
    /// growable lots sharing an edge with it.
    ///
    /// **Roads are firebreaks, for free.** A fire only travels to something
    /// that can burn, and a road has no density, so a grid of streets bounds
    /// how far one fire can reach without any of this knowing what a firebreak
    /// is. That rewards the layout a player is already building for traffic
    /// reasons, which is the kind of interaction that makes a city plan feel
    /// like a plan rather than a score.
    private static func neighbouringBuildings(
        of footprint: [GridPosition], in map: CityMap
    ) -> [GridPosition] {
        var anchors: Set<GridPosition> = []
        let own = Set(footprint)
        for cell in footprint {
            for neighbour in cell.orthogonalNeighbors() where map.contains(neighbour) {
                guard !own.contains(neighbour) else { continue }
                let tile = map[neighbour]
                // Growable zones only. A fire station or a power plant burning
                // down would be a far bigger event than this models, and
                // quietly deleting the player's services is not something a
                // random roll should be allowed to do.
                guard tile.zone.maxDensity > 0, tile.density > 0 else { continue }
                anchors.insert(tile.buildingOrigin)
            }
        }
        return anchors.sortedByPosition()
    }

    /// How many separate blocks are alight — what the cockpit reports.
    static func count(in map: CityMap) -> Int {
        map.tiles.filter { $0.isBuildingAnchor && $0.isBurning }.count
    }
}
