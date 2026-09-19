import Foundation

/// What a lot is doing, and — when it is doing nothing — what is stopping it.
///
/// **Why this exists.** `CitySimulator.advance` decides a lot's fate by
/// falling through a ranked chain of gates: can anyone reach it, is it burnt,
/// is it mid-build, has the city stopped wanting this kind of thing, has it
/// outgrown its surroundings, and then the requirements for the *next* level —
/// land value, water, power, a school. That chain is the complete answer to
/// "why is this block stuck", and until now it existed only as control flow.
/// Nothing could ask it a question; it could only be run.
///
/// The player needs to ask it. A city with ten interacting systems and no way
/// to find out which one is holding a block back is a city you manage by
/// guessing, and several of these gates have no overlay at all — school
/// coverage, hospital coverage, whether a lot has outgrown what its
/// surroundings can support.
///
/// **And it must be the same chain, not a second copy of it.** An inspector
/// that reimplemented "is it missing water?" would drift from the simulator
/// the first time either changed, and this project has been bitten by exactly
/// that three times: a streetscape render painting its own flat tiles while
/// the renderer had moved on, an overlay render with its own stale switch, and
/// hazard damage computed in two places. So `advance` is written in terms of
/// this, rather than this being written to describe `advance`.
///
/// Deliberately says nothing about presentation — no player-facing wording
/// lives here. `Simulation/` may import Foundation only, and what a thing is
/// *called* is a statement about the UI (see `RenderPalette.displayName(for:)`,
/// which is not on `ZoneType` for the same reason).
enum LotStatus: Equatable {

    /// Not a lot that grows at all: a road, a service building, bare ground.
    case notGrowable

    /// Nothing sharing an edge with it is a road, a highway, or transit. A
    /// lot that already has something on it *shrinks* in this state; an empty
    /// one simply never starts.
    case noRoadAccess

    /// Struck by a hazard and waiting on the service whose absence let it
    /// happen. Neither grows nor decays until then.
    case damaged(waitingFor: ZoneType)

    /// On fire right now. Distinct from `damaged` — which is the aftermath —
    /// because it is the one state that gets worse while the player watches,
    /// and the one with an answer they have to take immediately.
    case burning

    /// Part-way through building its next level.
    case underConstruction(remaining: Int, total: Int)

    /// The city has far more of this kind of lot than it wants, and this one
    /// is marginal enough to be giving way. See `CitySimulator.localDemand`.
    case beingAbandoned

    /// Standing taller than its surroundings can support, and coming down one
    /// level at a time. `sustainable` is what it will settle at.
    case decliningToSustainable(sustainable: Int)

    /// Built out. Nothing is wrong; there is simply no higher level.
    case atMaximumDensity

    /// The next level needs better surroundings than this lot has.
    case needsLandValue(required: Double, current: Double)

    /// The next level needs a utility this lot is not connected to.
    case needsWater
    case needsPower

    /// The next level needs a school in range.
    case needsSchool

    /// Every requirement is met and the lot is waiting on the city wanting
    /// more of it — the growth roll, which is a probability rather than a
    /// gate. `demand` is what the city currently feels, −1 to 1.
    case readyToGrow(demand: Double)

    /// How much a lot wants the player's attention.
    ///
    /// **Because the inspector answers the wrong half of the question.** It
    /// tells you what is wrong with the lot under the pointer, which is only
    /// useful once you already know which lot to point at — and the only way
    /// to find that out was to hover over every block in the city, faster than
    /// the simulation was changing them. Ranking the states is what lets a
    /// whole city be scanned at once.
    enum Severity: Int, Comparable {
        /// Nothing to do. Growing, built out, or mid-construction.
        case fine
        /// Stuck: it wants something the player has to go and build.
        case blocked
        /// Getting worse on its own.
        case failing
        /// On fire. The only state that spreads while you read about it.
        case critical

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var severity: Severity {
        switch self {
        case .burning:
            return .critical
        case .noRoadAccess, .beingAbandoned, .decliningToSustainable, .damaged:
            return .failing
        case .needsLandValue, .needsWater, .needsPower, .needsSchool:
            return .blocked
        case .notGrowable, .atMaximumDensity, .underConstruction, .readyToGrow:
            return .fine
        }
    }

    /// Is this lot actively losing ground, as opposed to merely stuck?
    ///
    /// The distinction the player cares about most: "this will not improve"
    /// and "this is getting worse" call for different urgency, and three
    /// separate cases here mean the second thing.
    var isDeteriorating: Bool {
        switch self {
        case .noRoadAccess, .beingAbandoned, .decliningToSustainable, .burning: return true
        default: return false
        }
    }
}

extension CitySimulator {

    /// The gate chain, evaluated. Short-circuits at the first thing that
    /// stops this lot, in exactly the order `advance` acts on them.
    ///
    /// Short-circuiting rather than gathering every gate is what keeps this
    /// free: `advance` used to make these same calls inline and stop at the
    /// first failure, so evaluating them here costs what it always cost. A
    /// version that answered "everything wrong with this lot" would evaluate
    /// land value, both utilities and school coverage on every tile of every
    /// tick, which is not a price a per-tick sweep should pay for a panel that
    /// is usually closed.
    /// `distances` is optional for the same reason `LandValue.value`'s is: a
    /// caller asking about one lot has no reason to build a whole-map field,
    /// and a caller sweeping the map has every reason not to build it twice.
    static func status(
        of tile: Tile, in map: CityMap, using distances: ZoneDistanceField? = nil
    ) -> LotStatus {
        guard tile.zone.maxDensity > 0 else { return .notGrowable }
        let footprint = map.footprintCells(origin: tile.buildingOrigin, size: tile.zone.footprintSize)

        guard footprint.contains(where: { hasAccess(at: $0, in: map) }) else { return .noRoadAccess }

        // Fire is reported ahead of the damage it caused, because it is the
        // live emergency and the damage is its aftermath — a block that is
        // still alight and a block that burnt down last week are the same
        // `damagedBy` and completely different problems. `advance` does not
        // branch on this (a burning block is always also damaged, so the
        // damage branch already stops it), which is why it sits here rather
        // than in the chain below.
        if tile.isBurning { return .burning }

        if let service = tile.damagedBy { return .damaged(waitingFor: service) }

        if let remaining = tile.constructionRemaining, remaining > 0 {
            return .underConstruction(
                remaining: remaining, total: constructionTicks(toReach: tile.density + 1)
            )
        }

        let bestLandValue = footprint.map { LandValue.value(at: $0, in: map, using: distances) }.max() ?? 0
        let demand = map.cityDemand.value(for: tile.zone)

        let feltDemand = localDemand(cityDemand: demand, landValue: bestLandValue)
        if feltDemand <= abandonmentDemand, tile.density > 0 { return .beingAbandoned }

        let hasWater = footprint.contains { Water.hasSupply(at: $0, in: map) }
        let hasPower = footprint.contains { PowerGrid.hasSupply(at: $0, in: map) }

        let sustainable = sustainableDensity(
            landValue: bestLandValue, hasWater: hasWater, hasPower: hasPower
        )
        if tile.density > sustainable { return .decliningToSustainable(sustainable: sustainable) }

        let nextLevel = tile.density + 1
        guard nextLevel <= tile.zone.maxDensity else { return .atMaximumDensity }

        let required = requiredLandValue(toReach: nextLevel)
        guard bestLandValue >= required else {
            return .needsLandValue(required: required, current: bestLandValue)
        }
        if nextLevel >= waterRequiredFromLevel, !hasWater { return .needsWater }
        if nextLevel >= powerRequiredFromLevel, !hasPower { return .needsPower }
        if nextLevel >= educationRequiredFromLevel, !hasSchooling(footprint, in: map, using: distances) {
            return .needsSchool
        }
        return .readyToGrow(demand: demand)
    }

    /// Does this lot want water — either to grow, or to keep what it has?
    ///
    /// **Not the same question as "has it got water".** A house at density 1
    /// neither needs water nor suffers without it, so painting it as a
    /// problem on the Water overlay would send the player to lay pipe that
    /// buys nothing. This is the condition the *simulation* gates on, called
    /// rather than restated — the same reason `CityHazards.isExposed` exists,
    /// after the crime overlay spent a while claiming half the city was at
    /// risk when it was not.
    static func needsWater(_ tile: Tile) -> Bool {
        needsUtility(tile, fromLevel: waterRequiredFromLevel)
    }

    static func needsPower(_ tile: Tile) -> Bool {
        needsUtility(tile, fromLevel: powerRequiredFromLevel)
    }

    private static func needsUtility(_ tile: Tile, fromLevel: Int) -> Bool {
        guard tile.zone.maxDensity > 0 else { return false }
        // `density + 1`, so a lot one level *below* the gate counts: it is
        // being held back right now, which is exactly when the player wants
        // to be told. A lot already at or above the gate is covered by the
        // same test.
        return tile.density + 1 >= fromLevel
    }

    /// Is a school close enough to unlock the top tier for this footprint?
    static func hasSchooling(
        _ footprint: [GridPosition], in map: CityMap, using distances: ZoneDistanceField? = nil
    ) -> Bool {
        footprint.contains { cell in
            LandValue.falloffValue(
                nearestZone: .school,
                falloffDistance: LandValue.serviceFalloffDistance,
                at: cell, in: map, using: distances
            ) >= educationCoverageThreshold
        }
    }

    /// Is the service a damaged block is waiting on actually reaching it?
    static func isRepairCovered(
        _ footprint: [GridPosition], by service: ZoneType,
        in map: CityMap, using distances: ZoneDistanceField? = nil
    ) -> Bool {
        footprint.contains { cell in
            LandValue.falloffValue(
                nearestZone: service,
                falloffDistance: LandValue.serviceFalloffDistance,
                at: cell, in: map, using: distances
            ) >= repairCoverageThreshold
        }
    }
}
