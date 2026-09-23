import Foundation

/// **How far a civic service reaches.**
///
/// Police, fire, schooling, hospitals, fire containment and the repair gate
/// all ask the same question — *is this block served by that building?* — and
/// every one of them used to answer it the same copy-pasted way:
///
/// ```swift
/// LandValue.falloffValue(nearestZone: service,
///                        falloffDistance: LandValue.serviceFalloffDistance,
///                        at: cell, in: map, using: distances) >= 0.3
/// ```
///
/// Five call sites, five separately-named `0.3` constants, one shared
/// `serviceFalloffDistance`. They were all the same number by coincidence of
/// everyone picking 0.3, and `CityHazards.apply` carried a sixth copy inline
/// — inside the very file whose `isExposed` exists to be the single
/// definition, and whose doc comment says this project has paid three times
/// for letting a second copy drift.
///
/// **Two things were tangled, and untangling them is most of the point.**
/// `serviceFalloffDistance` is how far a station projects *land value* — an
/// amenity, felt as desirability. It was doing double duty as how far the
/// station actually *protects*, so there was no way to make a police station
/// cover more ground without also making it a bigger amenity, and no way to
/// tune desirability without silently moving every hazard in the game. That
/// is exactly the separation `Transit` already had to draw between a
/// catchment and a land-value falloff, never carried back here.
///
/// So reach is now a real distance in tiles rather than a threshold on a
/// gradient, which buys three things beyond the decoupling:
///
/// - **Funding scales smoothly.** The old form multiplied funding into the
///   value and then compared against a fixed 0.3, so the radius fell off a
///   cliff: 1.0 → 0.5 funding took it from 8 tiles to 4 (area 145 → 41), and
///   *any* funding at or below 0.3 protected nothing anywhere, including the
///   station's own lot. Reach is now simply proportional to funding.
/// - **The overlay can draw the edge.** `strength` reaches zero exactly where
///   `serves` stops being true, so the Crime and Fire Risk views no longer
///   paint a gradient a third wider than the protection it depicts.
/// - **One knob.** "How much should a station cover" is one number.
enum ServiceCoverage {

    /// How far a fully-funded service reaches, in tiles (Manhattan, like
    /// every other coverage question in this game).
    ///
    /// **Sized against how many stations a city should need.** A service
    /// covers a diamond of `2r² + 2r + 1` tiles, so at the 8 tiles this
    /// worked out to before, one station covered 145 tiles and a 64×64 map
    /// wanted **28 police stations and 28 fire stations** at perfect packing
    /// — which is not a decision, it is wallpaper you are obliged to lay.
    /// Reported from play as the radius being "a big problem".
    ///
    /// At 14 a station covers 421 tiles and the same map wants about ten of
    /// each: enough that siting them is a real choice and each one is a bill
    /// you notice, few enough that covering a city is something you finish.
    static let radius = 14

    /// `radius`, scaled by what the player is paying for that service.
    ///
    /// Funding above 1.0 reaches further, which is the same deliberate lever
    /// `LandValue.falloffValue` documents for over-funding — and unlike the
    /// old threshold form, funding *below* 1.0 now shrinks the radius in
    /// proportion instead of collapsing it.
    static func reach(of service: ZoneType, in map: CityMap) -> Double {
        Double(radius) * map.serviceFunding.level(for: service)
    }

    /// Does `service` reach any cell of `footprint`?
    ///
    /// The *best*-served cell decides, which is what every call site did
    /// before via `.max()` — a building is only unserved if every corner of
    /// it is.
    static func serves(
        _ footprint: [GridPosition],
        _ service: ZoneType,
        in map: CityMap,
        using distances: ZoneDistanceField? = nil
    ) -> Bool {
        let reach = reach(of: service, in: map)
        // An unfunded service does nothing at all, not even on its own lot.
        guard reach > 0 else { return false }
        return footprint.contains { cell in
            guard let distance = LandValue.distanceToNearest(service, from: cell, in: map, using: distances)
            else { return false }
            return Double(distance) <= reach
        }
    }

    /// How strongly `service` reaches `position`, 1 at its door and 0 at the
    /// edge of its reach.
    ///
    /// For the overlays, which want a gradient rather than a yes/no so the
    /// player can see where the *next* station should go. It hits zero
    /// exactly where `serves` turns false, which is the property the Crime
    /// and Fire Risk views were missing: their ground was painted from the
    /// land-value falloff, which runs half again as far as the protection
    /// does, so the outer third of the glow promised cover that was not
    /// there.
    static func strength(
        at position: GridPosition,
        from service: ZoneType,
        in map: CityMap,
        using distances: ZoneDistanceField? = nil
    ) -> Double {
        let reach = reach(of: service, in: map)
        guard reach > 0,
              let distance = LandValue.distanceToNearest(service, from: position, in: map, using: distances)
        else { return 0 }
        // Over `reach + 1` rather than `reach`, so that this is *positive
        // exactly where `serves` is true* — at the last covered ring it is a
        // thin sliver rather than zero. Dividing by `reach` would put the
        // outermost protected tiles at a strength of nothing, which is the
        // same class of mistake this type exists to fix: a reading that
        // disagrees with the rule it is depicting.
        return Swift.max(0, 1 - Double(distance) / (reach + 1))
    }
}
