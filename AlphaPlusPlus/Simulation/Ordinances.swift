import Foundation

/// City-wide policy toggles — a second budget lever above `GameController.taxRate`
/// and `ServiceFunding`, this one binary (on/off) rather than a percentage,
/// matching how every reference game since SC2000 models an ordinance: a
/// fixed, targeted effect and a fixed ongoing cost, not a dial to fine-tune.
/// Flagged as one of the biggest genre-parity gaps this project had —
/// present in every game on the roadmap's own parity list since 1993,
/// unaddressed until now.
///
/// Lives on `CityMap`, not `GameController`, for the same reason
/// `ServiceFunding` does (see that type's own doc comment): an ordinance's
/// effect is city *state* the simulation itself reads directly —
/// `CityHazards.apply` for the two safety ordinances, `Demand.compute(for:)`
/// for the tax break — not a UI-only concern layered on top of already-computed
/// numbers.
///
/// Three to start, each hooked into a mechanic this project already has
/// (hazards, demand) rather than a new system invented just to give an
/// ordinance something to do — the same "reuse what's already real" shape
/// `PowerGrid` took from `Water`, just applied to a budget lever instead of
/// a network.
struct Ordinances: Equatable, Codable, Sendable {
    /// Halves `CityHazards.crime`'s chance per tick, city-wide — a police
    /// substation can't be on every block, but a standing neighborhood
    /// watch can blanket the whole city for one flat cost instead of
    /// another building's worth of footprint and placement cost.
    var neighborhoodWatch = false

    /// Halves `CityHazards.fire`'s chance per tick, city-wide — same shape
    /// as `neighborhoodWatch`, for the other hazard.
    var fireInspections = false

    /// Nudges commercial demand up by `Demand.businessTaxBreakBoost`
    /// (clamped to `CityDemand`'s own ±1 range) — representing the city
    /// trading tax revenue it doesn't model per-RCI-type (see `Demand`'s
    /// own doc comment on why residential/commercial/industrial don't have
    /// separate rates yet) for faster commercial growth instead. The
    /// ordinance's flat upkeep cost stands in for that foregone revenue,
    /// rather than this project growing a second tax-rate system just to
    /// make one ordinance's cost "real" in a more literal sense.
    var businessTaxBreak = false

    /// Flat cost per active ordinance, charged every tick regardless of
    /// city size — a first guess, same "needs playtesting" status as every
    /// other number in this project. Real games often scale ordinance cost
    /// with population; this is deliberately the simplest version that
    /// could work, the same starting point `Demand`'s own `scale` constant
    /// documents taking for demand itself.
    static let costPerOrdinance = 30

    /// What every currently-active ordinance costs the treasury this tick,
    /// summed — folded into `GameController.upkeepCost` alongside every
    /// service building's own upkeep, the same "one number covers
    /// everything running this tick" shape that already has.
    var totalUpkeepCost: Int {
        [neighborhoodWatch, fireInspections, businessTaxBreak].filter { $0 }.count * Self.costPerOrdinance
    }
}
