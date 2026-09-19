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
            let footprint = map.footprintCells(origin: tile.position, size: tile.zone.footprintSize)

            // **The gate chain lives in `LotStatus`, and this acts on it.**
            // It used to be written the other way round — the chain existed
            // only as the control flow of this loop, which meant nothing could
            // ask it a question, it could only be run. The player's inspector
            // needs to ask, and an inspector with its own copy of these rules
            // would drift from them the first time either changed. So the
            // answer is computed once and both consume it.
            switch status(of: tile, in: map, using: distances) {

            // Nothing happens. Each of these is a lot waiting on something the
            // player has to go and do; none of them is a roll.
            case .notGrowable, .atMaximumDensity,
                 .needsLandValue, .needsWater, .needsPower, .needsSchool:
                continue

            case .noRoadAccess:
                // A site nobody can reach loses a level, and stops building.
                guard tile.density > 0 else { continue }
                for cell in footprint {
                    next[cell].density = tile.density - 1
                    next[cell].constructionRemaining = nil
                }

            // **`.burning` behaves exactly like `.damaged` here, on purpose.**
            // The two are one state to the simulation — a block alight is
            // always also damaged — and they are separate only because they
            // are completely different problems *to the player*: one is an
            // emergency they must answer now, the other is a ruin waiting on a
            // service. Letting the distinction change what `advance` does
            // would be a balance change smuggled inside a refactor, and this
            // refactor is meant to leave the simulation bit-identical.
            case .burning, .damaged:
                // A damaged building rebuilds before it does anything else,
                // and only once the service it's waiting on actually reaches
                // it. Until then it neither grows nor decays — an uncovered
                // block that burns stays burnt until the player does
                // something.
                guard let service = tile.damagedBy else { continue }
                let covered = isRepairCovered(footprint, by: service, in: map, using: distances)
                if covered || Double.random(in: 0 ..< 1, using: &rng) < Self.unassistedRepairChancePerTick {
                    for cell in footprint { next[cell].damagedBy = nil }
                }

            case .underConstruction(let remaining, _):
                let left = remaining - 1
                for cell in footprint {
                    next[cell].constructionRemaining = left > 0 ? left : nil
                    if left == 0 { next[cell].density = tile.density + 1 }
                }

            case .beingAbandoned:
                if Double.random(in: 0 ..< 1, using: &rng) < Self.abandonmentChancePerTick {
                    for cell in footprint { next[cell].density = tile.density - 1 }
                }

            case .decliningToSustainable:
                if Double.random(in: 0 ..< 1, using: &rng) < Self.declineChancePerTick {
                    for cell in footprint { next[cell].density = tile.density - 1 }
                }

            case .readyToGrow(let demand):
                guard Double.random(in: 0 ..< 1, using: &rng) < growthChance(for: demand) else { continue }
                // Approved, not built. The level arrives when the work does.
                let duration = Self.constructionTicks(toReach: tile.density + 1)
                for cell in footprint { next[cell].constructionRemaining = duration }
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
    /// How long a lot spends building its way to `level`.
    ///
    /// **Why growth is no longer instantaneous.** A lot used to gain a level
    /// the moment its gates were satisfied, and the whole city finished in
    /// sixteen ticks — 90% of final population by tick 7. Nothing was wrong
    /// with the decisions in those sixteen ticks; there was simply no time in
    /// which to watch them land, notice a mistake, or change your mind. A
    /// simulation you cannot observe is a calculation, not a game.
    ///
    /// **Scaled by level, not flat.** A shopfront going up should feel
    /// responsive and a tower should feel like an investment, so reaching
    /// level 1 takes `baseConstructionTicks` and level 5 takes five times
    /// that. A lot climbing from nothing to its maximum spends about 120
    /// ticks doing it, against the 5 it used to.
    static func constructionTicks(toReach level: Int) -> Int {
        Swift.max(1, Self.baseConstructionTicks * level)
    }

    /// Ticks per density level of construction. See `constructionTicks`.
    static let baseConstructionTicks = 8

    /// The demand a *particular lot* feels, which is not the same as the
    /// demand the city reports.
    ///
    /// **Why oversupply had to stop being city-wide.** Abandonment read
    /// `map.cityDemand.value(for:)` — one number for the whole city — so
    /// over-zoning housing emptied every residential lot equally, the
    /// waterfront tower and the lot wedged between two factories alike. There
    /// was no such thing as a bad neighbourhood: the city was uniformly in
    /// demand or uniformly not.
    ///
    /// Shifting that number by the lot's own desirability makes oversupply
    /// bite where it should. When a city has too much housing, the marginal
    /// lots empty first and the desirable ones hold — which is what makes
    /// *where* you built something matter long after you built it, and what
    /// turns "the city is declining" into "that district is declining".
    ///
    /// It also connects a finding to a consequence. Residential demand drifts
    /// steadily toward `abandonmentDemand` over a long run and never arrives —
    /// measured at −0.55 against a −0.75 threshold. With a local offset the
    /// city's worst lots cross it while its average does not, so that drift
    /// finally does something.
    static func localDemand(cityDemand: Double, landValue: Double) -> Double {
        cityDemand + (landValue - Self.localDemandReference) * Self.localDemandSensitivity
    }

    /// The land value at which a lot feels exactly the city's own demand.
    /// Above it a lot is insulated from oversupply, below it exposed.
    static let localDemandReference = 0.5

    /// How far desirability can shift the demand a lot feels, per unit of land
    /// value. At 0.6 a truly bad lot sits about 0.3 below the city average and
    /// a prime one about 0.3 above — enough for the worst to cross the
    /// abandonment threshold while the city as a whole is merely oversupplied.
    static let localDemandSensitivity = 0.6

    /// The highest density a lot's *surroundings* can currently sustain.
    ///
    /// **The missing half of a check that already existed.** Growth is gated by
    /// `bestLandValue >= requiredLandValue(toReach: nextLevel)` — a guard on the
    /// level a lot is trying to reach. Nothing ever asked whether it could
    /// still support the level it *had*. A tier-5 tower is already at maximum
    /// density, so that guard never ran for it again, which meant pollution,
    /// traffic and lost service coverage could only ever stall growth: you
    /// could ruin a district completely and nothing moved out. Tax was the one
    /// lever that felt like management, and the only reason is that it works
    /// through city-wide demand, which *is* bidirectional.
    ///
    /// This reads the same table downward. A lot above what it returns falls
    /// back one level at a time, at `declineChancePerTick`.
    ///
    /// **Hysteresis is deliberate.** The threshold to *keep* a level is
    /// `declineMargin` below the threshold to *reach* it, so a lot sitting
    /// exactly on a boundary does not flicker between growing and decaying
    /// forever — which is what would happen with a single shared threshold,
    /// since growth and decline read the same number.
    static func sustainableDensity(landValue: Double, hasWater: Bool, hasPower: Bool) -> Int {
        var sustainable = 0
        for level in 1 ... 5 {
            guard landValue >= requiredLandValue(toReach: level) - Self.declineMargin else { break }
            if level >= Self.waterRequiredFromLevel, !hasWater { break }
            if level >= Self.powerRequiredFromLevel, !hasPower { break }
            sustainable = level
        }
        return sustainable
    }

    /// How far below a level's own threshold a lot may sink before it starts
    /// losing that level. See `sustainableDensity` for why this is not zero.
    static let declineMargin = 0.05

    /// Per-tick chance that a lot above what it can sustain loses one level.
    ///
    /// Deliberately slow, and deliberately the same order as
    /// `abandonmentChancePerTick`. At 0.02 a level takes about fifty ticks to
    /// go, so a district visibly rots rather than collapsing, and a player who
    /// notices has plenty of time to fix the cause — the decline stops the
    /// moment the ground can support the density again. A city you manage
    /// should punish neglect, not inattention.
    static let declineChancePerTick = 0.02

    /// Not private: `LotStatus` reports the shortfall to the player, and the
    /// number it is short *of* is half of that answer.
    static func requiredLandValue(toReach level: Int) -> Double {
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
    /// gate itself — and, since phase 2, in both directions: losing water
    /// *does* now cause decay, exactly like insufficient land value does.
    /// That comment used to say the opposite, and its reasoning was
    /// consistency with the land-value gate; when that gate became
    /// bidirectional the same argument required this one to follow, or the
    /// rule would have been arbitrary rather than principled. A first guess
    /// like every other number in this file.
    ///
    /// Not `private`: `IsoTileRenderer.syncUtilityWarning` (Rendering/) reads
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

    /// From this level on, a zone additionally needs a `.school` in range —
    /// the third and last rung of the utility ladder, after water at 3 and
    /// power at 4.
    ///
    /// The top density tier was previously gated on land value alone, which
    /// made it a reward for building *near good things* rather than a
    /// decision of its own. An education requirement turns the last tier into
    /// something a player has to go and build for, and gives the mid-game its
    /// own objective the way water and power give the early game theirs.
    ///
    /// Asks `ServiceCoverage` rather than making a present-or-absent check,
    /// because unlike a pipe or a power line a school serves a *radius* — the
    /// question is "is this block in a school's catchment," not "is a school
    /// connected to it."
    static let educationRequiredFromLevel = 5

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

    /// How likely a damaged building with *no* covering service is to rebuild
    /// itself anyway, on any given tick.
    ///
    /// Without this, repair-gated damage has no equilibrium and quietly
    /// guarantees total decay. A building below the coverage threshold takes a
    /// hazard at roughly 0.009 per tick, so over the hundreds of ticks a city
    /// runs, *every* uncovered building is hit eventually — and if damage only
    /// ever clears through coverage, every uncovered building therefore ends
    /// up permanently dead. A design playtest showed exactly that: with no
    /// unassisted repair, nearly every strategy went bankrupt and a
    /// service-less city fell to 32 people. That is not difficulty, it is a
    /// ratchet.
    ///
    /// At 0.01 against a ~0.009 damage rate, an uncovered district settles
    /// around half its buildings broken at any moment — visibly blighted,
    /// permanently worse off, but alive and recoverable the moment a station
    /// reaches it. Coverage still repairs on the very next tick, so it remains
    /// roughly a hundred times faster than waiting; the difference between
    /// protected and unprotected is a difference of degree rather than the
    /// difference between a city and a graveyard.
    static let unassistedRepairChancePerTick = 0.01

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
