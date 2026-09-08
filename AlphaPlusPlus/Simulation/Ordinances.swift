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

    /// Flat portion of an active ordinance's cost, unrelated to city size —
    /// what a brand-new city pays from tick one. Found via a real 300-tick
    /// playtest harness (mixed-use city, real RNG) built for this exact
    /// question: a flat cost alone stayed exactly this small forever, while
    /// tax revenue in the same city grew into the thousands per tick — a
    /// city ten times the size paid the literal same $30 as a brand-new
    /// one, reading as "free" long before the game was actually over.
    static let baseCostPerOrdinance = 30

    /// Added on top of `baseCostPerOrdinance`, per point of population —
    /// the deliberate fix for the gap above: an ordinance covering a
    /// bigger city costs more to actually run. Service building upkeep
    /// gets this same "scales with what it covers" property for free, by
    /// summing over however many buildings exist — but there's exactly
    /// one Neighborhood Watch, not one per neighborhood, so a flat
    /// per-ordinance cost never got that scaling on its own. A first
    /// guess, same "needs playtesting" status as every other number here.
    static let costPerCapitaPerOrdinance = 0.05

    /// What one active ordinance costs the treasury this tick, given the
    /// city's current `population` — the flat base plus the per-capita
    /// term above. Not `Codable` state itself, just a computation over
    /// state `GameController` already tracks; `GameView` reads this
    /// directly for its "$X/tick each" hint so the displayed number is
    /// never stale relative to what `totalUpkeepCost(population:)` (below)
    /// actually charges.
    static func costPerOrdinance(population: Int) -> Int {
        baseCostPerOrdinance + Int(Double(population) * costPerCapitaPerOrdinance)
    }

    /// What every currently-active ordinance costs the treasury this tick,
    /// summed — folded into `GameController.netRevenue` alongside upkeep
    /// and bond interest, the same "one number covers everything running
    /// this tick" shape that already has. Takes `population` rather than
    /// reading it off a `CityMap` directly, the same "pure computation
    /// over a plain value" shape `Demand.compute(for:)` uses instead of
    /// reaching back into `GameController` for it.
    func totalUpkeepCost(population: Int) -> Int {
        let perOrdinance = Self.costPerOrdinance(population: population)
        return [neighborhoodWatch, fireInspections, businessTaxBreak].filter { $0 }.count * perOrdinance
    }
}
