import Foundation

/// City-wide pressure to grow more of each RCI type — the second gate a
/// zone's growth needs to clear, alongside its own `LandValue`. Where
/// land value answers "is this tile a good spot," demand answers "does
/// the city want more of this type at all, right now" — orthogonal
/// questions, computed by entirely separate code, both checked before
/// density can advance (see `CitySimulator.advance`'s doc comment for
/// exactly how the two combine).
///
/// A summary of the *whole* map, not per-tile like `LandValue` — one
/// `CityDemand` value describes the entire city for one simulation tick.
/// Computed once (`Demand.compute(for:)`, called from
/// `GameController.advanceSimulation()` alongside `Traffic.computeLoad`
/// and `Water.computeSupply`) and cached here the same way `trafficLoad`/
/// `waterSupply` are, rather than rescanning the whole map for every
/// single growable building checked that tick.
struct CityDemand: Equatable, Codable, Sendable {
    /// -1 (the city has far more of this than it needs) to 1 (the city
    /// urgently wants more), for each growable zone type. 0 is "exactly
    /// balanced" — no push either way.
    var residential: Double = 0
    var commercial: Double = 0
    var industrial: Double = 0

    /// How much the city wants more of `zone` right now. 0 for every
    /// zone that isn't growable — demand isn't a concept that applies to
    /// a road or a police station, the same "always has an answer, never
    /// an optional" contract `ServiceFunding.level(for:)` already keeps.
    func value(for zone: ZoneType) -> Double {
        switch zone {
        case .residential: return residential
        case .commercial: return commercial
        case .industrial: return industrial
        default: return 0
        }
    }
}

/// Computes `CityDemand` from a `CityMap`'s current population and jobs.
/// Modeled after `Traffic.swift`/`Water.swift`'s own shape: a stateless
/// computation over the whole map, cached on it (`CityMap.cityDemand`)
/// rather than recomputed per tile.
///
/// v1, and deliberately the simplest version that could work: Residential
/// demand rises with *unfilled jobs* (more jobs than people to fill
/// them); Commercial and Industrial demand both rise with *job seekers*
/// (more people than jobs), with no distinction between the two yet —
/// matching how `GameController.jobs` already sums Commercial and
/// Industrial density together without telling them apart for any other
/// purpose either. A real split (Commercial caring more about population
/// as customers, Industrial about export/transport access) is a genuine
/// refinement to make later, not a correctness fix now — the same
/// "smallest version that's still real" starting point `Traffic`/`Water`
/// themselves shipped as v1.
enum Demand {

    /// How many unfilled jobs (or job-seekers) it takes to push demand to
    /// its extreme, ±1. Scaled to roughly "a couple of buildings' worth"
    /// of imbalance: one fully-grown 2×2 zone contributes up to 20
    /// population (`ZoneType.residential.populationPerDensityLevel` × 5)
    /// or 15 jobs (`jobsPerDensityLevel` × 5), so a much smaller scale
    /// would swing demand to its extreme from a single building's growth
    /// tick, and a much larger one would leave demand barely moving over
    /// the course of an ordinary game. A first guess, same "needs
    /// playtesting" status every other constant in this project starts at.
    private static let scale: Double = 30

    static func compute(for map: CityMap) -> CityDemand {
        let population = map.totalDensity(of: .residential) * ZoneType.residential.populationPerDensityLevel
        let jobs = map.totalDensity(of: .commercial) * ZoneType.commercial.jobsPerDensityLevel
            + map.totalDensity(of: .industrial) * ZoneType.industrial.jobsPerDensityLevel
        let unfilledJobs = jobs - population
        let commercialAndIndustrial = pressure(from: -unfilledJobs)
        return CityDemand(
            residential: pressure(from: unfilledJobs),
            commercial: commercialAndIndustrial,
            industrial: commercialAndIndustrial
        )
    }

    private static func pressure(from value: Int) -> Double {
        max(-1, min(1, Double(value) / scale))
    }
}
