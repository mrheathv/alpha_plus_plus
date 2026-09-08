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
    /// against it, how little of that service counts as "unprotected," how
    /// likely it is to strike an unprotected tile on a given step, and how
    /// much density it costs when it does.
    struct Risk {
        let zones: Set<ZoneType>
        let coveringService: ZoneType
        let coverageThreshold: Double
        let chancePerTick: Double
        let densityLoss: Int
    }

    /// Industrial and commercial buildings are the flammable ones here —
    /// residential is left out for now since burning down homes reads very
    /// differently to a player than burning down a warehouse, and that's a
    /// tone call worth making deliberately later, not a default to fall
    /// into. All the numbers (30% coverage floor, 5% chance, -2 density)
    /// are first guesses, same as everywhere else risk/reward hasn't been
    /// played with yet.
    static let fire = Risk(
        zones: [.industrial, .commercial],
        coveringService: .fireStation,
        coverageThreshold: 0.3,
        chancePerTick: 0.05,
        densityLoss: 2
    )

    /// Crime threatens residential and commercial (people and storefronts),
    /// not industrial — and costs less density per incident than fire
    /// (vandalism/theft vs. a building actually burning), but is slightly
    /// more likely on any given tick.
    static let crime = Risk(
        zones: [.residential, .commercial],
        coveringService: .policeStation,
        coverageThreshold: 0.3,
        chancePerTick: 0.04,
        densityLoss: 1
    )

    static let all = [fire, crime]

    /// One hazard actually striking one tile — what `apply` reports back so
    /// a caller that cares (`GameScene`, for a visible flash) can react to
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
    /// position, the one cell that actually has a visible sprite for
    /// `GameScene` to flash). Called with the map from *before* this step's
    /// growth (`GameController.advanceSimulation()` runs hazards, then
    /// growth, in that order) — so a tile can't grow from 0 to 1 and burn
    /// down in the same tick it was first zoned; it has to survive at least
    /// one full step at its current density before either risk considers it.
    ///
    /// Processes each building once at its anchor (`Tile.isBuildingAnchor`),
    /// using the *best*-covered cell of its footprint against
    /// `coverageThreshold` — a building is only "unprotected" if every
    /// corner is — and, if a risk triggers, applies the same `densityLoss`
    /// to every cell in the footprint, so a 2×2 building never ends up with
    /// mismatched density across its own cells.
    static func apply<RNG: RandomNumberGenerator>(_ risks: [Risk] = all, to map: CityMap, using rng: inout RNG) -> (map: CityMap, strikes: [Strike]) {
        var next = map
        var strikes: [Strike] = []
        for tile in map.tiles where tile.isBuildingAnchor {
            guard tile.density > 0 else { continue }
            let footprint = map.footprintCells(origin: tile.position, size: tile.zone.footprintSize)
            for risk in risks where risk.zones.contains(tile.zone) {
                let bestCoverage = footprint.map {
                    LandValue.falloffValue(nearestZone: risk.coveringService, falloffDistance: LandValue.serviceFalloffDistance, at: $0, in: map)
                }.max() ?? 0
                guard bestCoverage < risk.coverageThreshold else { continue }
                let chance = risk.chancePerTick * ordinanceMultiplier(for: risk, in: map)
                guard Double.random(in: 0 ..< 1, using: &rng) < chance else { continue }
                for cell in footprint { next[cell].density = max(0, next[cell].density - risk.densityLoss) }
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
}
