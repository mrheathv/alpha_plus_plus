import Foundation

/// Roads, pipes and power lines wearing out, and the budget that keeps them
/// working.
///
/// **Why this exists.** Every piece of infrastructure in the game was a
/// one-time purchase. You laid a road, paid a flat `roadUpkeepPerTile`
/// forever, and it worked identically on tick 10,000 as on tick 1 — so the
/// only question a mature city's treasury ever faced was "what else can I
/// build", never "can I still afford what I have". That is most of why
/// CLAUDE.md's standing list of open problems has money accumulating with
/// nothing to spend it on.
///
/// It is also the other half of the answer to the stillness phase 1 measured.
/// Phase 5 gave the region weather — pressure from outside that the player
/// does not control. This is entropy from inside: the city you built starts
/// coming apart on its own, and holding it together is an ongoing decision
/// rather than a completed one.
///
/// **Wear is deterministic, for the same three reasons `RegionalEconomy` is.**
/// A player steers against a trend, not against a die; the playtest harness
/// needs cities reproducible tick for tick; and `AlwaysZeroRNG` passes every
/// probability gate, so a per-tile wear roll would have rotted every fixture
/// city's roads to nothing at maximum speed. Entropy is not an event anyway —
/// it is the thing that happens when no event does.
enum Infrastructure {

    // MARK: - Rates

    /// How fast a road with no traffic on it at all decays, per tick, as a
    /// fraction of the whole.
    ///
    /// Deliberately slow. Weather and neglect are supposed to operate on the
    /// scale of a session, not a minute: at this rate an unused, completely
    /// unmaintained road takes 500 ticks to reach ruin. That is the *floor* —
    /// it is what a quiet residential side street costs you.
    static let baseWearPerTick = 0.002

    /// The additional wear a road at full capacity takes, per tick.
    ///
    /// **This is the mechanic, not the base rate above.** Five times the
    /// floor, so what actually wears a city out is its own traffic: the busy
    /// arterials rot and the back streets do not. That matters because it ties
    /// maintenance to a system the player already has levers for — a congested
    /// corridor can be answered by paying for it *or* by fixing the
    /// congestion, with a highway or a transit line, and both are real
    /// answers. A flat decay rate would have been one more bill with no
    /// decision attached to it.
    static let congestionWearPerTick = 0.010

    /// How much wear one tick of fully funded maintenance undoes.
    ///
    /// Calibrated against the two rates above rather than picked: it exceeds
    /// `baseWearPerTick` comfortably, so quiet streets stay pristine at full
    /// funding, and it sits well below the saturated rate, so a jammed
    /// arterial still degrades even when you are paying in full. Funding is
    /// meant to be the answer to *ordinary* wear; congestion is meant to
    /// outrun it.
    static let repairPerTickAtFullFunding = 0.005

    /// The extra wear a power line takes, per tick, while the grid it belongs
    /// to is drawing more than its plants can supply.
    ///
    /// **The cascade.** An overload used to be a flat state: the grid drops
    /// city-wide, growth stalls, the meter turns red, and it stays exactly
    /// that bad for as long as you leave it. Nothing about it got *worse*, so
    /// there was no urgency — an overloaded city was a city with a to-do item.
    /// Now the overload damages the network carrying it, so lines fail one by
    /// one (see `failureWear`), and a grid left overloaded does not merely
    /// stay broken, it comes apart. That is the difference between a warning
    /// and a disaster.
    ///
    /// Five times `baseWearPerTick`, so an unattended overload takes the first
    /// line out in about a hundred ticks even at full public-works funding —
    /// slow enough to notice and act on, fast enough that ignoring it costs
    /// you something you then have to rebuild.
    static let overloadWearPerTick = 0.010

    /// Worn past this, a buried pipe or power line stops conducting.
    ///
    /// Not 1.0. A conduit that fails only at total ruin would be a cliff the
    /// player falls off with no warning, and the failure is *invisible* —
    /// buried infrastructure is only drawn in its own overlay. Failing at 0.75
    /// leaves a quarter of the wear range as a visible warning band in that
    /// overlay before anything actually breaks.
    static let failureWear = 0.75

    /// How much of a road's capacity survives total ruin.
    ///
    /// A worn road carries less traffic, which makes it more congested, which
    /// wears it faster — a genuine feedback loop, and the reason this floor is
    /// not zero. Phase 2 settled the house rule for exactly this shape of
    /// mechanic: recoverable rather than harsh. At 0.4 a ruined arterial is
    /// badly congested and visibly failing, but funding it still digs it out;
    /// at 0 it would spiral to a state no budget could recover.
    static let ruinedCapacityFraction = 0.4

    // MARK: - Queries

    /// Does anything on this tile wear out?
    ///
    /// One wear value covers the road *and* whatever is buried under it, which
    /// is a simplification with a defensible shape: a city's public-works
    /// budget resurfaces the street and replaces the main under it in the same
    /// job, and it means the busiest corridors — which carry the road and the
    /// utility runs both — are the ones that need the money.
    static func wears(_ tile: Tile) -> Bool {
        tile.zone == .road || tile.zone == .highway || tile.hasPipe || tile.hasPowerLine
    }

    /// 1 for as-new, 0 for ruined.
    static func condition(of tile: Tile) -> Double {
        1 - (tile.wear ?? 0)
    }

    /// Has this tile's buried pipe or power line failed?
    static func hasFailed(_ tile: Tile) -> Bool {
        (tile.wear ?? 0) >= failureWear
    }

    /// What fraction of its designed capacity a road tile still carries.
    static func capacityFraction(of tile: Tile) -> Double {
        ruinedCapacityFraction + (1 - ruinedCapacityFraction) * condition(of: tile)
    }

    /// How much wear one tick puts on a tile carrying this much congestion.
    ///
    /// Pulled out as a function of one number rather than left inline in
    /// `advance`, because the balance claim this phase rests on is a statement
    /// about these three rates and nothing else — that funding covers ordinary
    /// wear and does not cover congestion — and a claim like that should be
    /// checkable without building a city first.
    static func wearPerTick(congestion: Double) -> Double {
        baseWearPerTick + congestionWearPerTick * Swift.max(0, Swift.min(1, congestion))
    }

    /// How much wear one tick of maintenance at this funding level undoes.
    static func repairPerTick(funding: Double) -> Double {
        repairPerTickAtFullFunding * Swift.max(0, funding)
    }

    // MARK: - The tick

    /// One tick of decay and repair over the whole map.
    ///
    /// Reads congestion from `map.trafficLoad`, which
    /// `GameController.advanceSimulation()` has already refreshed for this
    /// tick — the same cached whole-map value `LandValue` and `CityHazards`
    /// read, rather than a second routing pass.
    static func advance(_ map: CityMap) -> CityMap {
        var next = map
        let repair = repairPerTick(funding: map.serviceFunding.level(for: .road))
        // `PowerGrid.load` is a pure function of the map, not a read of the
        // cached `powerSupply`, so this sees the overload as it stands right
        // now rather than as it stood at the end of last tick.
        let overloaded = PowerGrid.load(in: map).isOverloaded
        for tile in map.tiles where wears(tile) {
            // A buried pipe under open ground carries no traffic, so it wears
            // at the floor rate — the congestion term is about the surface.
            let congestion = tile.zone == .road || tile.zone == .highway
                ? Traffic.congestion(at: tile.position, in: map)
                : 0
            let overload = overloaded && tile.hasPowerLine ? overloadWearPerTick : 0
            let updated = (tile.wear ?? 0) + wearPerTick(congestion: congestion) + overload - repair
            // `nil` rather than 0 for a tile in perfect condition, and never
            // both: `Tile` is `Equatable`, and two tiles that are equally
            // pristine have to compare equal whether one of them has ever been
            // repaired. The same invariant `constructionRemaining` keeps.
            next[tile.position].wear = updated <= 0 ? nil : Swift.min(1, updated)
        }
        return next
    }

    /// The share of the city's infrastructure that is meaningfully worn — what
    /// the cockpit's maintenance meter reports.
    ///
    /// Measured against `failureWear` rather than against total ruin, because
    /// the number a player needs is "how much of this is about to stop
    /// working", not "how much of it is scuffed".
    static func degradedFraction(in map: CityMap) -> Double {
        var total = 0
        var degraded = 0
        for tile in map.tiles where wears(tile) {
            total += 1
            if (tile.wear ?? 0) >= failureWear * 0.5 { degraded += 1 }
        }
        guard total > 0 else { return 0 }
        return Double(degraded) / Double(total)
    }
}
