import Foundation

/// How well-funded each service is, as a fraction of full funding — 1.0 is
/// "fully staffed," 0.5 is "running at half strength," 1.5 is "funded above
/// the norm." One field per fundable `ZoneType`, not a `[ZoneType: Double]`
/// dictionary: the set of fundable services is small and fixed (unlike
/// zones themselves, which `CaseIterable` already enumerates), so named
/// fields are both simpler to read and impossible to have a missing key
/// for — `level(for:)` always has an answer, never an optional to unwrap.
///
/// Lives on `CityMap` (see `CityMap.serviceFunding`) rather than on
/// `GameController`, even though only the player-facing side ever changes
/// it: funding level is city *state* that the simulation itself reads
/// (`LandValue.falloffValue` is the one place that does), the same
/// category as "what's zoned where" — not a UI concern layered on top.
///
/// Residential/Commercial/Industrial, roads, and `.empty` aren't fundable —
/// they're the tax base, not a city expense (see `ZoneType.upkeepCost`,
/// which is 0 for exactly these same zones) — so `level(for:)` always
/// reports 1.0 for them: "funding" isn't a concept that applies, and 1.0
/// is the value that leaves every formula using it unaffected.
struct ServiceFunding: Equatable, Codable, Sendable {
    var policeStation: Double = 1.0
    var fireStation: Double = 1.0
    var publicTransit: Double = 1.0
    var powerPlant: Double = 1.0
    var stadium: Double = 1.0
    // `.subway` is a staffed service like `.publicTransit` (see
    // `ZoneType.upkeepCost`), so it gets its own dial the same way; a
    // plain `.highway` doesn't — it's still just a road, not a service.
    var subway: Double = 1.0
    // `.waterTower` is a service too, but `Water.computeSupply(for:)`
    // only ever checks `level(for: .waterTower) > 0` — the network is
    // either live or offline, no continuous strength dial the way a
    // falloff-distance service gets (see that function's own doc comment
    // for why). `.pipe` doesn't get one, same reasoning as `.highway`.
    var waterTower: Double = 1.0

    /// How well-funded `zone` currently is. Never optional — every
    /// `ZoneType` has an answer, even the ones that can't be funded at all.
    func level(for zone: ZoneType) -> Double {
        switch zone {
        case .policeStation: return policeStation
        case .fireStation: return fireStation
        case .publicTransit: return publicTransit
        case .powerPlant: return powerPlant
        case .stadium: return stadium
        case .subway: return subway
        case .waterTower: return waterTower
        case .empty, .residential, .commercial, .industrial, .road, .highway, .pipe: return 1.0
        }
    }

    /// Sets the funding level for `zone`. A no-op for a zone that isn't
    /// fundable, rather than a precondition failure — same "let it be a
    /// harmless no-op" contract `CityMap.placeBuilding` uses for an invalid
    /// footprint, so a caller iterating `ZoneType.allCases` doesn't need to
    /// filter down to the fundable ones first.
    mutating func setLevel(_ level: Double, for zone: ZoneType) {
        switch zone {
        case .policeStation: policeStation = level
        case .fireStation: fireStation = level
        case .publicTransit: publicTransit = level
        case .powerPlant: powerPlant = level
        case .stadium: stadium = level
        case .subway: subway = level
        case .waterTower: waterTower = level
        case .empty, .residential, .commercial, .industrial, .road, .highway, .pipe: break
        }
    }
}
