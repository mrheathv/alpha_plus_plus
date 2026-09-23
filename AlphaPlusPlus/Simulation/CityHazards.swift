import Foundation

/// Random, service-gated risks to already-developed zones: fire (needs Fire
/// coverage) and crime (needs Police coverage). Both follow the same shape
/// — low coverage from the relevant service means a small per-tick chance
/// of losing density — so this file expresses them as one parameterized
/// `Risk` applied to each of the standard set, rather than two near-copies
/// of the same logic.
///
/// Kept entirely separate from `CitySimulator.advance(_:)`, which stays
/// deterministic: `CityHazards.apply` is where this project's only
/// randomness lives, isolated so growth/decay stay simple to test and this
/// is the one place that has to think about a random source at all.
enum CityHazards {

    /// One hazard rule: which zones it threatens, which service defends
    /// against it, how likely it is to strike an unprotected tile on a given
    /// step, and how much density it costs when it does.
    ///
    /// How much of the service counts as "protected" is no longer a field
    /// here: it was a threshold on a land-value gradient, and every system in
    /// the game had its own separately-named copy of the same `0.3`. It is
    /// one question with one answer now — see `ServiceCoverage`.
    struct Risk {
        let zones: Set<ZoneType>
        let coveringService: ZoneType
        let chancePerTick: Double
        let densityLoss: Int
    }

    /// Industrial and commercial buildings are the flammable ones here —
    /// residential is left out for now since burning down homes reads very
    /// differently to a player than burning down a warehouse, and that's a
    /// tone call worth making deliberately later, not a default to fall
    /// into.
    ///
    /// `chancePerTick` was `0.05` until a live playtest reported the actual
    /// consequence: constant visible flickering across the map, "with each
    /// tick." A standalone playtest harness confirmed why — in a mature,
    /// fully-grown city (the same one the balance-tuning pass upstream of
    /// this used), fire and crime together struck an *average of 4.5-5.6
    /// tiles every single tick*, spiking as high as 8 in one tick, forever,
    /// for as long as the city stood. Each strike triggered `GameScene`'s
    /// `flashHazard`, an 0.08s colorize-and-0.35s-fade animation — several
    /// of those overlapping on the map every tick reads exactly as
    /// "flickering," not as the occasional, noticeable "oh no, a fire"
    /// event a hazard is supposed to be. The coverage gate below
    /// (`ServiceCoverage`) means this only ever fires on *already
    /// under-covered* buildings, but real cities inevitably have some —
    /// map edges, gaps between service buildings — so the fix is the same
    /// shape as the two upstream in this pass: the rate itself, not just
    /// the gate, was miscalibrated. Lowered 10x; the same harness confirmed
    /// that brings the same mature city down to under one strike per tick
    /// on average, an occasional event again rather than ambient noise.
    static let fire = Risk(
        zones: [.industrial, .commercial],
        coveringService: .fireStation,
        chancePerTick: 0.005,
        densityLoss: 2
    )

    /// Crime threatens residential and commercial (people and storefronts),
    /// not industrial — and costs less density per incident than fire
    /// (vandalism/theft vs. a building actually burning), but is slightly
    /// more likely on any given tick. Lowered 10x alongside `fire`, same
    /// playtest finding — see its own doc comment.
    static let crime = Risk(
        zones: [.residential, .commercial],
        coveringService: .policeStation,
        chancePerTick: 0.004,
        densityLoss: 1
    )

    static let all = [fire, crime]

    /// One hazard actually striking one tile — what `apply` reports back so
    /// a caller that cares (`MetalMapView`, for a visible flash) can react to
    /// *which* tiles were hit and by what, instead of the event being
    /// silent (a density number quietly dropping next refresh, with no cue
    /// why). `coveringService` identifies the risk that struck (`.fireStation`
    /// for fire, `.policeStation` for crime) rather than exposing `Risk`
    /// itself, since that's the one detail a flash actually needs to pick a
    /// color.
    struct Strike: Equatable {
        let position: GridPosition
        let coveringService: ZoneType
    }

    /// Apply every risk in `risks` to `map` once, returning the result and
    /// every building it struck (reported at the building's *anchor*
    /// position, the cell `MetalMapView` flashes the building from). Called with the map from *before* this step's
    /// growth (`GameController.advanceSimulation()` runs hazards, then
    /// growth, in that order) — so a tile can't grow from 0 to 1 and burn
    /// down in the same tick it was first zoned; it has to survive at least
    /// one full step at its current density before either risk considers it.
    ///
    /// Processes each building once at its anchor (`Tile.isBuildingAnchor`),
    /// using the *best*-covered cell of its footprint against
    /// `ServiceCoverage.serves` — a building is only "unprotected" if every
    /// corner is — and, if a risk triggers, applies the same `densityLoss`
    /// to every cell in the footprint, so a 2×2 building never ends up with
    /// mismatched density across its own cells.
    /// **Nothing burns or is burgled in the first season.**
    ///
    /// Reported from play: a new city catches fire while the player is still
    /// laying their first roads, and the answer to a fire — a fire station —
    /// is not something they have yet. That is precisely the rule this
    /// project already wrote down for the starter utilities: *every warning
    /// the game raises has to have an answer the player can act on right
    /// now.* A city showing errors for a problem it is forbidden to fix is
    /// the same bug wearing a different coat.
    ///
    /// Ninety days rather than a population or an unlock check, for two
    /// reasons. A police station and a fire station unlock at 40 residents,
    /// which a zoned city passes in a couple of weeks — so gating on the
    /// unlock alone would end the grace almost immediately and leave the
    /// reported problem in place. And a flat span of days is something the
    /// calendar can *say*: the city is founded in spring 1985 and the first
    /// hazard cannot land before that summer is out.
    ///
    /// Three months is also roughly three minutes at `SimulationSpeed.normal`
    /// and comfortably shorter than the ~160 days a city takes to settle, so
    /// this quietens the opening rather than removing hazards from the early
    /// game.
    static let gracePeriodDays = 90

    static func apply<RNG: RandomNumberGenerator>(_ risks: [Risk] = all, to map: CityMap, using rng: inout RNG) -> (map: CityMap, strikes: [Strike]) {
        var next = map
        var strikes: [Strike] = []
        guard map.elapsedDays >= gracePeriodDays else { return (next, strikes) }
        // Same reasoning as `CitySimulator.advance`: one precomputed field for
        // the whole sweep instead of a full map scan per coverage query. See
        // `ZoneDistanceField`.
        let distances = ZoneDistanceField.compute(for: map)
        for tile in map.tiles where tile.isBuildingAnchor {
            guard tile.density > 0 else { continue }
            let footprint = map.footprintCells(origin: tile.position, size: tile.zone.footprintSize)
            for risk in risks where risk.zones.contains(tile.zone) {
                // `isExposed` rather than a second copy of its condition.
                // There *was* a second copy here — in the same file as the
                // doc comment explaining that a second copy always drifts.
                guard isExposed(tile, to: risk, in: map, using: distances) else { continue }
                let chance = risk.chancePerTick * ordinanceMultiplier(for: risk, in: map)
                guard Double.random(in: 0 ..< 1, using: &rng) < chance else { continue }
                // A hospital in range halves what the hazard takes out. It
                // does not stop the fire — coverage by the *relevant* service
                // is what prevents a strike, and that is `ServiceCoverage`
                // above — but it is the difference between a setback and a
                // block being flattened, which is what a health service is
                // for. It also gives the hospital a role of its own rather
                // than making it a second police station.
                let damage = damage(from: risk, to: footprint, in: map, using: distances)
                for cell in footprint {
                    next[cell].density = max(0, next[cell].density - damage)
                    // The block is now waiting on the very service whose
                    // absence let this happen — see `Tile.damagedBy`.
                    next[cell].damagedBy = risk.coveringService
                    // And a fire keeps burning after the strike that started
                    // it. Everything above is unchanged — the density loss,
                    // the `damagedBy`, the reported `Strike` — so `Fire` is
                    // propagation layered on this contract rather than a
                    // replacement for it. Crime does not spread: one mechanic
                    // at a time, and a burglary reaching for the house next
                    // door is a different model from a fire doing it.
                    if risk.coveringService == .fireStation { next[cell].fireTicks = 0 }
                }
                strikes.append(Strike(position: tile.position, coveringService: risk.coveringService))
            }
        }
        return (next, strikes)
    }

    /// How much `map.ordinances` scales this particular `risk`'s chance —
    /// 1.0 (no change) unless the ordinance covering it is active, in
    /// which case half. Reads `map.ordinances` directly rather than
    /// `apply(_:to:using:)` taking a separate parameter, the same "the
    /// simulation reads city state straight off the map" shape
    /// `LandValue.falloffValue` already uses for `ServiceFunding`.
    private static func ordinanceMultiplier(for risk: Risk, in map: CityMap) -> Double {
        switch risk.coveringService {
        case .policeStation: return map.ordinances.neighborhoodWatch ? 0.5 : 1.0
        case .fireStation: return map.ordinances.fireInspections ? 0.5 : 1.0
        default: return 1.0
        }
    }
    /// Is any cell of this building inside a hospital's catchment?
    ///
    /// Floored at 1 density level of damage where it applies, via
    /// `Swift.max(1, ...)` at the call site: a hospital should soften a
    /// hazard, never make one free. A `densityLoss` of 1 stays 1.
    /// Can `risk` actually strike this building?
    ///
    /// Exactly the condition `apply` gates on — the right kind of zone,
    /// something standing on it, and the covering service out of range. Not
    /// private, and not re-derived by its callers, because both the inspector
    /// and the crime overlay need to answer "is this block at risk" and a
    /// second copy of the condition would drift from this one. This project
    /// has paid for that mistake three times.
    static func isExposed(
        _ tile: Tile, to risk: Risk, in map: CityMap, using distances: ZoneDistanceField?
    ) -> Bool {
        guard tile.density > 0, risk.zones.contains(tile.zone) else { return false }
        let footprint = map.footprintCells(origin: tile.buildingOrigin, size: tile.zone.footprintSize)
        return !ServiceCoverage.serves(footprint, risk.coveringService, in: map, using: distances)
    }

    /// What one strike of `risk` costs a building, hospital coverage
    /// included.
    ///
    /// Not private, and not inlined in `apply`, because `Fire` needs the same
    /// answer for a block the fire *reached* rather than struck: a fire that
    /// arrives by spreading is the same fire, and "what a fire costs a
    /// building" should have exactly one definition.
    static func damage(
        from risk: Risk,
        to footprint: [GridPosition],
        in map: CityMap,
        using distances: ZoneDistanceField
    ) -> Int {
        // A hospital in range halves what the hazard takes out. It does not
        // stop the fire — coverage by the *relevant* service is what prevents
        // a strike, and that is `ServiceCoverage` — but it is the difference
        // between a setback and a block being flattened, which is what a
        // health service is for. It also gives the hospital a role of its own
        // rather than making it a second police station.
        hospitalIsInRange(of: footprint, in: map, using: distances)
            ? Swift.max(1, risk.densityLoss / 2)
            : risk.densityLoss
    }

    private static func hospitalIsInRange(
        of footprint: [GridPosition],
        in map: CityMap,
        using distances: ZoneDistanceField
    ) -> Bool {
        ServiceCoverage.serves(footprint, .hospital, in: map, using: distances)
    }

}
