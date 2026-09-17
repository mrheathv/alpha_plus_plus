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

    /// The imbalance that counts as "full" demand (±1), for a city too small
    /// for `relativeScale` to mean anything — roughly a couple of buildings'
    /// worth, since one fully-grown 2×2 zone contributes up to 20 population
    /// or 15 jobs.
    private static let minimumScale: Double = 30

    /// What fraction of the city's own size counts as full imbalance.
    ///
    /// Demand used to be measured against a flat scale of 30 regardless of
    /// city size, and that turned out to break the whole mechanic once a city
    /// got big. A 64×64 city runs about 2,500 population against 2,500 jobs;
    /// against a scale of 30, *any* imbalance past 30 people pins demand at
    /// exactly ±1. So demand was not a gradient at all in a real city, it was
    /// a boolean — the RCI meter sat railed, and anything trying to nudge
    /// demand by a fraction of a point (`businessTaxBreakBoost`, and now
    /// `taxDemandSensitivity`) was simply swamped.
    ///
    /// A design playtest made the consequence concrete: with a flat scale, a
    /// tax rate of 2.0 produced *more* population than the default and 5.6x
    /// the treasury, because suppressing demand slowed residential growth
    /// just enough to stop the city overshooting into abandonment — high tax
    /// came out strictly better, which is precisely the non-decision the tax
    /// mechanic was added to fix.
    ///
    /// Measuring imbalance as a *fraction of the city* instead makes demand
    /// proportional at every size: 15% of a city's population-plus-jobs out of
    /// balance is full demand whether that city holds 200 people or 20,000.
    /// That also gives the tax pressure something to actually move — the
    /// equilibrium now shifts by a share of the city rather than by a fixed 15
    /// people.
    private static let relativeScale: Double = 0.15

    private static func scale(population: Int, jobs: Int) -> Double {
        max(minimumScale, Double(population + jobs) * relativeScale)
    }

    /// How much `Ordinances.businessTaxBreak` adds to commercial demand
    /// specifically, on top of the shared residential/industrial pressure
    /// below — the one place Commercial and Industrial actually do get
    /// told apart (see this file's own top doc comment on why they
    /// otherwise don't yet). A first guess, same "needs playtesting"
    /// status `scale` above already has.
    static let businessTaxBreakBoost: Double = 0.3

    /// How hard the tax rate pushes on demand, per unit of rate away from the
    /// default 1.0.
    ///
    /// This is the fix for the biggest hole a design playtest found: tax rate
    /// had *no effect whatsoever* on the city. Final population was 3,320 at
    /// a rate of 0.0, 1.0 and 2.0 alike — only the treasury moved — so setting
    /// it to maximum was strictly dominant and an entire toolbar row was a
    /// number with no consequence attached.
    ///
    /// Routed through demand rather than as a separate multiplier on growth,
    /// for two reasons. It reuses the gate that already exists instead of
    /// adding a second, parallel one (`Ordinances.businessTaxBreak` already
    /// nudges demand exactly this way, so the shape is established). And
    /// demand is the one simulation value the player can actually *see*, via
    /// the RCI meter — so over-taxing shows up as the bars sagging, a visible
    /// cause for the growth stall rather than a mysterious one.
    ///
    /// Deliberately kept *below* `CitySimulator.abandonmentDemand` (0.75), and
    /// that bound is the whole reason this number is 0.5 rather than something
    /// larger. At the maximum rate of 2.0 this contributes -0.5, which stalls
    /// growth hard but cannot on its own push a city past the abandonment
    /// threshold — reaching that still takes genuine oversupply on top. The
    /// first attempt used 1.0, and a design playtest showed exactly why that
    /// was wrong: a rate of 2.0 pinned demand at -1.0 permanently, below the
    /// abandonment line no matter how the city rebalanced, and wiped a 3,300
    /// -person city to **zero**. A tax slider should be able to cost you
    /// dearly; it should never be able to reach a state you cannot recover
    /// from by moving it back.
    ///
    /// So: 1.25 costs 0.125, a mild drag. 1.5 costs 0.25, a real one. 2.0
    /// costs 0.5 and leaves a city stalled and fragile — one bad zoning
    /// decision away from decline — rather than doomed. Below 1.0 the sign
    /// flips and cheap taxes genuinely attract growth, which is what makes the
    /// low end a strategy rather than just forfeited income.
    static let taxDemandSensitivity: Double = 0.5

    static func compute(for map: CityMap) -> CityDemand {
        let population = map.totalDensity(of: .residential) * ZoneType.residential.populationPerDensityLevel
        let jobs = map.totalDensity(of: .commercial) * ZoneType.commercial.jobsPerDensityLevel
            + map.totalDensity(of: .industrial) * ZoneType.industrial.jobsPerDensityLevel
        let unfilledJobs = jobs - population
        let scale = scale(population: population, jobs: jobs)
        let commercialAndIndustrial = pressure(from: -unfilledJobs, scale: scale)
        let commercialBoost = map.ordinances.businessTaxBreak ? businessTaxBreakBoost : 0

        // Subtracted from all three types equally: a high rate makes the whole
        // city less attractive to build in, not one sector specifically.
        // `businessTaxBreak` is what buys commercial an exemption, which is
        // precisely what an ordinance of that name ought to do.
        let taxPressure = (map.taxRate - 1.0) * taxDemandSensitivity

        // And the one term that comes from outside the city entirely. Added
        // here rather than applied to the result, so it is subject to the same
        // clamp as everything else and cannot smuggle demand past ±1 — see
        // `RegionalEconomy` for why the city needed an external input at all.
        let region = map.regionalEconomy

        return CityDemand(
            residential: clamped(pressure(from: unfilledJobs, scale: scale)
                - taxPressure + region.strength(for: .residential)),
            commercial: clamped(commercialAndIndustrial + commercialBoost
                - taxPressure + region.strength(for: .commercial)),
            industrial: clamped(commercialAndIndustrial
                - taxPressure + region.strength(for: .industrial))
        )
    }

    private static func clamped(_ value: Double) -> Double {
        max(-1, min(1, value))
    }

    private static func pressure(from value: Int, scale: Double) -> Double {
        max(-1, min(1, Double(value) / scale))
    }
}
