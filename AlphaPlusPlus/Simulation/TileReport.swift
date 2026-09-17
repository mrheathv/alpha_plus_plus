import Foundation

/// Everything worth knowing about one tile, gathered in one pass.
///
/// **What this is for.** The city now runs about ten systems that interact,
/// and a player's only window into any of them is a whole-map overlay showing
/// one channel at a time. Diagnosing a single block means visiting five
/// overlays and remembering what each looked like there — and several things
/// have no overlay at all: school and hospital coverage, crime and fire risk,
/// how worn the roads are, what density a lot could actually sustain. So the
/// honest answer to "why is this block stuck at 3?" was that you could not
/// find out.
///
/// **It reports facts, not words.** `Simulation/` may import Foundation only,
/// and what a thing is *called* is a statement about presentation — the same
/// reason `RenderPalette.displayName(for:)` does not live on `ZoneType`. Every
/// number here is in the units the simulation already uses; turning 0.62 into
/// "desirable" is the inspector's job, not this one's.
///
/// **And it is a snapshot, not a live view.** Built on demand from a `CityMap`
/// and immediately stale, which is the right shape for something a UI rebuilds
/// whenever the pointer moves or the city ticks. Nothing caches it.
struct TileReport: Equatable {

    let position: GridPosition
    let zone: ZoneType

    /// What the lot is doing and what is stopping it — see `LotStatus`. The
    /// headline, and the only field that is a *diagnosis* rather than a
    /// measurement.
    let status: LotStatus

    /// Current level and the highest this zone can ever reach. 0 and 0 for
    /// anything that does not grow.
    let density: Int
    let maxDensity: Int

    /// Residents and jobs this lot contributes to the city's totals.
    let population: Int
    let jobs: Int

    // MARK: - Utilities

    let hasWater: Bool
    let hasPower: Bool

    // MARK: - Service coverage, 0 (none) to 1 (right next door)

    /// One field per service rather than a `[ZoneType: Double]`, the same
    /// choice `ServiceFunding` makes and for the same reason: the set is small
    /// and fixed, and a dictionary would make every read optional at the point
    /// of use for no benefit.
    let policeCoverage: Double
    let fireCoverage: Double
    let schoolCoverage: Double
    let hospitalCoverage: Double

    // MARK: - Surroundings

    /// How desirable this lot is, which is what gates every level above the
    /// first. 0 to 1.
    let landValue: Double

    /// How dirty the air is here, 0 to 1 — what industry emits and what
    /// residents mind most.
    let pollution: Double

    /// How close the roads fronting this lot are to their capacity, 0 to 1.
    /// 0 for a lot with no road frontage at all.
    let congestion: Double

    /// The condition of the worst piece of infrastructure on or beside this
    /// lot, 1 for as-new and 0 for ruined. A lot with nothing built on or
    /// beside it reports 1 — there is nothing there to be worn.
    let infrastructureCondition: Double

    /// Whether a hazard could strike here at all: `CityHazards` only rolls
    /// against blocks its covering service does not reach, so these are
    /// exactly "the police/fire brigade are too far away".
    let isExposedToCrime: Bool
    let isExposedToFire: Bool

    /// Builds a report for one tile.
    ///
    /// Takes an optional precomputed `ZoneDistanceField` for the same reason
    /// `LandValue.value` does — a caller inspecting one tile has no reason to
    /// build one, and a caller sweeping the map has every reason not to build
    /// it twice.
    static func make(
        at position: GridPosition,
        in map: CityMap,
        using distances: ZoneDistanceField? = nil
    ) -> TileReport {
        let field = distances ?? ZoneDistanceField.compute(for: map)
        let tile = map[position]
        // Reported for the *building*, not the cell under the pointer: every
        // question here is about the lot as a whole, and the simulation itself
        // decides growth, coverage and hazards on a footprint rather than a
        // tile. Hovering the bottom-right quarter of a 2×2 tower should not
        // give a different answer from hovering the top-left.
        let anchor = map[tile.buildingOrigin]
        let footprint = map.footprintCells(origin: tile.buildingOrigin, size: anchor.zone.footprintSize)

        func coverage(_ service: ZoneType) -> Double {
            footprint.map {
                LandValue.falloffValue(
                    nearestZone: service,
                    falloffDistance: LandValue.serviceFalloffDistance,
                    at: $0, in: map, using: field
                )
            }.max() ?? 0
        }

        let police = coverage(.policeStation)
        let fire = coverage(.fireStation)

        // The worst condition anywhere on the lot or on the roads fronting it.
        // The worst rather than the average, because one burst main in the run
        // is what cuts the block off, and a average would hide it behind four
        // healthy neighbours.
        var condition = 1.0
        for cell in footprint {
            let neighbourhood = [cell] + cell.orthogonalNeighbors().filter { map.contains($0) }
            for candidate in neighbourhood where Infrastructure.wears(map[candidate]) {
                condition = Swift.min(condition, Infrastructure.condition(of: map[candidate]))
            }
        }

        return TileReport(
            position: position,
            zone: anchor.zone,
            status: CitySimulator.status(of: anchor, in: map, using: field),
            density: anchor.density,
            maxDensity: anchor.zone.maxDensity,
            population: anchor.density * anchor.zone.populationPerDensityLevel,
            jobs: anchor.density * anchor.zone.jobsPerDensityLevel,
            hasWater: footprint.contains { Water.hasSupply(at: $0, in: map) },
            hasPower: footprint.contains { PowerGrid.hasSupply(at: $0, in: map) },
            policeCoverage: police,
            fireCoverage: fire,
            schoolCoverage: coverage(.school),
            hospitalCoverage: coverage(.hospital),
            landValue: footprint.map { LandValue.value(at: $0, in: map, using: field) }.max() ?? 0,
            pollution: footprint.map { map.pollution.level(at: $0) }.max() ?? 0,
            congestion: roadCongestion(around: footprint, in: map),
            infrastructureCondition: condition,
            // Exactly `CityHazards`' own condition for whether a risk can fire
            // at all, so "exposed" here and "a hazard can strike" there cannot
            // come apart.
            isExposedToCrime: anchor.density > 0
                && CityHazards.crime.zones.contains(anchor.zone)
                && police < CityHazards.crime.coverageThreshold,
            isExposedToFire: anchor.density > 0
                && CityHazards.fire.zones.contains(anchor.zone)
                && fire < CityHazards.fire.coverageThreshold
        )
    }

    /// The worst congestion on any road fronting this lot.
    ///
    /// The lot's own tiles are not roads, so this has to look outward — and it
    /// takes the worst rather than the average for the same reason a commuter
    /// would: one jammed approach is a jammed approach.
    private static func roadCongestion(around footprint: [GridPosition], in map: CityMap) -> Double {
        var worst = 0.0
        for cell in footprint {
            for neighbour in cell.orthogonalNeighbors() where map.contains(neighbour) {
                worst = Swift.max(worst, Traffic.congestion(at: neighbour, in: map))
            }
        }
        return worst
    }
}
