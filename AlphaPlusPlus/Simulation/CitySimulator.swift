import Foundation

/// The time-driven rules that grow a city, as opposed to `GameController`'s
/// player-driven rules (click to place/bulldoze). Splitting them this way
/// keeps `CityMap`/`Tile` as pure data with two separate rule engines acting
/// on it — one triggered by the player, one triggered by advancing time —
/// rather than either kind of rule ending up bolted onto the data model
/// itself.
///
/// A stateless `enum` (never instantiated). Growth used to be a pure
/// function of the current map alone — same input map in, same output
/// map out, no randomness — until demand-gated growth (see
/// `growthChance(for:)`) added a probability roll matching how the
/// reference city-builders actually feel: demand raises or lowers the
/// *odds* a qualifying zone grows this tick, rather than a hard on/off a
/// player would watch every zone hit on the same tick with no visible
/// cause. That's the one place this file now needs a random source,
/// threaded through as a generic parameter exactly the way
/// `CityHazards.apply` already takes one — everything upstream of that
/// roll (access, land value, water) stays exactly as deterministic as
/// before, and a caller that wants fully deterministic tests can still
/// get them by supplying an `RNG` that always lands on one side of the
/// roll (see the test suite's `AlwaysZeroRNG`).
enum CitySimulator {

    /// One simulation step: every zoned *building* (processed once at its
    /// anchor — see `Tile.isBuildingAnchor` — regardless of whether it's a
    /// 1×1 road-side lot or a 2×2 block) with access (a road or transit stop
    /// at any of its cells' edges) grows by one density level, *if* every
    /// gate clears: the best land value across its cells meets
    /// `requiredLandValue(toReach:)`'s bar for that level, a real water
    /// supply and a real power supply if the level needs either, and
    /// finally a demand roll weighted by `map.cityDemand` (see
    /// `growthChance(for:)`) — a building with only bare-minimum access
    /// can stall a level or two short of full density until land value
    /// improves, and even a building that clears every other gate can
    /// still wait a tick or several if the city doesn't currently want
    /// more of its type. A building that's
    /// *lost* access decays by one level instead, down to 0. It never
    /// does both in the same step — access means grow-or-hold, no access
    /// means decay-or-hold — so `.empty`/`.road`/service tiles (incapable of
    /// density in the first place) are the only ones skipped outright.
    /// Whatever the result, it's applied to *every* cell the building
    /// covers, so all of them always agree on density.
    ///
    /// Takes a `CityMap` and returns a new one rather than mutating in
    /// place — `CityMap` is already a value type, so "advance the
    /// simulation" reads the same way "place a zone" does on
    /// `GameController`: compute the next state, hand it back, let the
    /// caller decide what to do with it (here, `GameController.advanceSimulation()`
    /// just assigns it to `map`).
    static func advance<RNG: RandomNumberGenerator>(_ map: CityMap, using rng: inout RNG) -> CityMap {
        var next = map
        // One field for the whole sweep rather than eight full map scans per
        // footprint cell — see `ZoneDistanceField`'s doc comment. Built from
        // `map` (the tick's starting state), which is the same snapshot every
        // `LandValue.value` call below would otherwise have scanned, so this
        // changes nothing about the answers.
        let distances = ZoneDistanceField.compute(for: map)
        for tile in map.tiles where tile.isBuildingAnchor {
            guard tile.zone.maxDensity > 0 else { continue }
            let footprint = map.footprintCells(origin: tile.position, size: tile.zone.footprintSize)
            let isConnected = footprint.contains { hasAccess(at: $0, in: map) }

            if isConnected {
                let demand = map.cityDemand.value(for: tile.zone)

                // Deep oversupply doesn't just stall growth, it reverses it.
                // Checked before the growth path rather than after, because a
                // building being abandoned this tick is not also a candidate
                // to grow this tick — the same "grow-or-hold, never both"
                // exclusivity the access branch below already keeps.
                if demand <= Self.abandonmentDemand, tile.density > 0 {
                    if Double.random(in: 0 ..< 1, using: &rng) < Self.abandonmentChancePerTick {
                        for cell in footprint { next[cell].density = tile.density - 1 }
                    }
                    continue
                }

                let nextLevel = tile.density + 1
                guard nextLevel <= tile.zone.maxDensity else { continue }
                let bestLandValue = footprint.map { LandValue.value(at: $0, in: map, using: distances) }.max() ?? 0
                guard bestLandValue >= requiredLandValue(toReach: nextLevel) else { continue }
                if nextLevel >= Self.waterRequiredFromLevel {
                    guard footprint.contains(where: { Water.hasSupply(at: $0, in: map) }) else { continue }
                }
                if nextLevel >= Self.powerRequiredFromLevel {
                    guard footprint.contains(where: { PowerGrid.hasSupply(at: $0, in: map) }) else { continue }
                }
                let chance = growthChance(for: demand)
                guard Double.random(in: 0 ..< 1, using: &rng) < chance else { continue }
                for cell in footprint { next[cell].density = nextLevel }
            } else if tile.density > 0 {
                let previousLevel = tile.density - 1
                for cell in footprint { next[cell].density = previousLevel }
            }
        }
        return next
    }

    /// Is any tile sharing an edge with `position` a road, a highway, a
    /// transit stop, or a subway? All four count equally as "connected" for
    /// growth purposes — `.highway`/`.subway` are pricier, higher-capacity
    /// versions of `.road`/`.publicTransit` (see `ZoneType`'s own doc
    /// comment), not a *different kind* of access.
    static func hasAccess(at position: GridPosition, in map: CityMap) -> Bool {
        position.orthogonalNeighbors().contains { neighbor in
            guard map.contains(neighbor) else { return false }
            let zone = map[neighbor].zone
            return zone == .road || zone == .publicTransit || zone == .highway || zone == .subway
        }
    }

    /// The land value a tile needs to advance *to* density level `level`.
    /// A tile touching exactly one road and nothing else sits at land value
    /// 0.75 (see `LandValue.roadFalloffDistance`) — comfortably past every
    /// threshold except the last, so bare road access alone carries a zone
    /// to density 4 but not the full 5; reaching 5 needs something more to
    /// push land value past 0.8. A second nearby road doesn't do it —
    /// `LandValue.value(at:in:)` takes the *nearest* road's own falloff,
    /// not a sum across every road in reach, so more roads alone can't
    /// climb past the same 0.75 ceiling one road already gives. A real
    /// station, subway stop, or stadium within about a road's width can:
    /// see `LandValue.serviceFalloffDistance`'s doc comment for the
    /// playtesting that pinned down exactly how close "within reach" needs
    /// to be. Level 2–4's thresholds are still a first guess, not a tuned
    /// balance — easy to revisit once growth-with-a-ceiling has been played
    /// with more.
    private static func requiredLandValue(toReach level: Int) -> Double {
        switch level {
        case ...1: return 0.0
        case 2: return 0.3
        case 3: return 0.5
        case 4: return 0.65
        default: return 0.8
        }
    }

    /// Below this level, a zone only needs today's road access + land
    /// value — a starter lot doesn't need city utilities yet. At this
    /// level and above, it *additionally* needs a real, connected water
    /// supply (`Water.hasSupply(at:in:)`), not just land value clearing
    /// the bar `requiredLandValue(toReach:)` already sets. Same "one more
    /// threshold, not a bolted-on second system" shape as the land-value
    /// gate itself: losing water later doesn't cause decay, exactly like
    /// insufficient land value doesn't — it just holds growth where it
    /// is until the supply comes back. A first guess like every other
    /// number in this file.
    ///
    /// Not `private`: `TileRenderer.syncUtilityWarning` (Rendering/) reads
    /// this too, so the on-map "you're missing water" badge lights up at
    /// the exact same density this file actually starts caring about
    /// water, instead of a second, hand-copied threshold silently drifting
    /// out of sync with this one.
    static let waterRequiredFromLevel = 3

    /// The power-grid counterpart to `waterRequiredFromLevel` — from this
    /// level on, a zone *additionally* needs a real, connected power
    /// supply (`PowerGrid.hasSupply(at:in:)`). Deliberately set higher
    /// than water's own threshold (3) rather than the same one:
    /// thematically power arguably belongs earlier than water (real
    /// infrastructure needs electricity before it needs plumbing), but
    /// matching water's exact threshold would mean *every* existing test
    /// (and every existing save-worthy city) that already builds a water
    /// network for its top density tiers would *also* need a power plant
    /// wired in for the same transition, doubling the setup burden for a
    /// mechanic that's brand new today. A first guess, explicitly chosen
    /// for "add the mechanic without churning everything that already
    /// depends on water's own threshold" over strict realism — exactly
    /// the kind of tradeoff this whole file's numbers already document
    /// making elsewhere.
    ///
    /// Not `private`, same reason as `waterRequiredFromLevel` just above.
    static let powerRequiredFromLevel = 4

    /// `growthChance(for:)`'s floor, at demand -1 (the city is drowning
    /// in this type already).
    ///
    /// Was 0.05, on the reasoning that a hard freeze reads as a wall the
    /// player never saw coming. That reasoning was sound about *feel* and
    /// wrong about consequence: a design playtest found zoning every lot
    /// residential produced 5,152 population with zero jobs, against 3,320
    /// for a balanced city — the dominant strategy was to ignore the RCI
    /// system entirely. A 5% trickle sounds negligible and is not; over the
    /// hundreds of ticks a city runs it is simply a slower road to the same
    /// maximum, so oversupply cost nothing but time.
    ///
    /// Now 0: at the very bottom of the demand range, growth genuinely stops.
    /// The "no invisible wall" concern is answered by two things that did not
    /// exist when this number was chosen — the RCI meter shows demand
    /// directly, so the cause is on screen, and `abandonmentDemand` below
    /// makes deep oversupply *visibly* start tearing buildings down rather
    /// than silently freezing them.
    private static let minimumGrowthChance = 0.0

    /// Below this demand, buildings of that type stop merely failing to grow
    /// and start being abandoned — one density level at a time, at
    /// `abandonmentChancePerTick`.
    ///
    /// This is what gives over-zoning a real cost. Without it the worst an
    /// oversupplied city suffered was stalled growth, so a player could zone
    /// wrong, wait, and lose nothing but time; the RCI gate was advice rather
    /// than a constraint. Abandonment turns it into a decision with a
    /// downside, which is the whole difference between a lever and a
    /// decoration.
    ///
    /// -0.75 rather than something closer to 0 so that ordinary, transient
    /// imbalance — the kind a growing city passes through constantly as one
    /// type outpaces another for a few ticks — never triggers it. It takes
    /// sustained, serious oversupply, or a punishing tax rate, to reach.
    static let abandonmentDemand = -0.75

    /// How likely an abandonment-eligible building is to lose a level on any
    /// given tick. Deliberately slow: a city should visibly decline over a
    /// stretch of ticks the player has time to notice and respond to, not
    /// collapse between glances. A first guess, same status as every other
    /// number here.
    static let abandonmentChancePerTick = 0.02

    /// How likely a zone that's already cleared every other gate (access,
    /// land value, water) is to actually grow *this* tick, given how
    /// badly the city currently wants more of its type
    /// (`map.cityDemand.value(for:)`, -1...1 — see `Demand.compute(for:)`).
    /// Linear between `minimumGrowthChance` at demand -1 and a guaranteed
    /// 1.0 at demand +1, so a perfectly balanced city (demand 0) lands
    /// almost exactly in the middle — a coin flip either way, not a
    /// thumb on the scale in either direction.
    private static func growthChance(for demand: Double) -> Double {
        minimumGrowthChance + (1 - minimumGrowthChance) * (demand + 1) / 2
    }
}
