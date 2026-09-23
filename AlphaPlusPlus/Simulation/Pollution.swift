import Foundation

/// How dirty each tile is, from industry.
///
/// **Why this exists.** Until now nothing in the game made *where* you put
/// something matter. A factory next to housing was identical to a factory on
/// the far side of the map, so there was never a reason not to zone one
/// homogeneous blob — which is most of why the game read as placing boxes. The
/// classic city-builder decision is "keep the dirty thing away from the people
/// thing," and it needs the dirty thing to actually be bad to be near.
///
/// The art has been promising this for a while: `RenderPalette` names
/// industrial's top tier "Pollution Warning" and `IndustrialMassing` puts a hazard
/// triangle on both of its tier-3 looks. This is the mechanic those were
/// drawn for.
///
/// **Accumulating, not nearest-only.** `LandValue`'s power-plant penalty uses
/// `falloffValue(nearestZone:)`, which asks only about the closest one — fine
/// for a building you place once or twice. Pollution has to *stack*, because
/// the whole point is that an industrial district is much worse than a lone
/// factory, and "distance to the nearest factory" can't tell those apart. So
/// this sums every source's contribution into a per-tile field, the same
/// "compute a whole-map value once per tick and cache it on `CityMap`" shape
/// `TrafficLoad`, `WaterSupply` and `PowerSupply` already use.
///
/// **v1 simplifications**, in the same spirit `Demand` documents its own:
/// every zone suffers pollution equally (in the reference games it hits
/// residential hardest), it disperses as a simple radial falloff rather than
/// drifting on wind, and only industry emits. Power plants keep their existing
/// separate penalty rather than being folded in here, so that mechanic's own
/// tuning stays where it is.
struct PollutionMap: Equatable, Codable, Sendable {
    /// Pollution per tile, 0 (clean) to 1 (as dirty as this model goes).
    /// Sparse: tiles nothing reaches simply aren't present.
    private var levels: [GridPosition: Double]

    init() {
        self.levels = [:]
    }

    fileprivate init(levels: [GridPosition: Double]) {
        self.levels = levels
    }

    /// How polluted `position` is, 0...1. Reads 0 everywhere on a `CityMap`
    /// that never had `Pollution.compute(for:)` run against it — a fresh map,
    /// or one built directly in a test — the same "nothing until computed"
    /// default `TrafficLoad` and `WaterSupply` keep.
    func level(at position: GridPosition) -> Double {
        levels[position] ?? 0
    }

    /// Whether anything is polluted at all. Used by tests and by the overlay
    /// to tell "computed and clean" from "never computed."
    var isEmpty: Bool { levels.isEmpty }
}

enum Pollution {

    /// How far one industrial building's pollution reaches.
    ///
    /// Shorter than `LandValue.serviceFalloffDistance` (12) on purpose: a
    /// station is *meant* to serve a wide neighbourhood, while pollution
    /// needs to be escapable. If dirty air reached as far as a police station
    /// covers, there would be no arrangement of a map that separates industry
    /// from housing, and the mechanic would read as a flat tax on zoning
    /// industry at all rather than as a planning problem. At 6, a single road
    /// and a row of lots is enough of a buffer to matter.
    static let radius = 6

    /// How much pollution one density level of industry puts into its own
    /// tile, per emitting cell.
    ///
    /// Deliberately small, because every cell of a building emits and the
    /// contributions overlap: a 2×2 factory's four cells between them multiply
    /// the figure at the centre by roughly three. The first attempt used 0.12
    /// and a single fully-grown factory pinned an entire radius-3 blob at the
    /// 1.0 cap — which is not a gradient at all, so the overlay showed a flat
    /// blob, stacking past one factory meant nothing, and there was no
    /// fine-grained planning to do.
    ///
    /// At 0.04 a lone density-5 factory reads about 0.67 at its own tile,
    /// falling smoothly to nothing at `radius`. That leaves real headroom for
    /// several factories to stack toward saturation, which is the difference
    /// this type exists to represent.
    static let perDensityLevel = 0.04

    /// Computes the pollution field for `map`.
    ///
    /// Scatter rather than gather: each source adds its falloff to the tiles
    /// around it, rather than each tile searching for sources. That makes the
    /// cost `sources × radius²` instead of `tiles × sources` — the same
    /// asymmetry `ZoneDistanceField` exploits, and the reason this can afford
    /// to accumulate when `LandValue`'s nearest-only penalty could not.
    static func compute(for map: CityMap) -> PollutionMap {
        var levels: [GridPosition: Double] = [:]

        for tile in map.tiles where tile.zone == .industrial && tile.isBuildingAnchor && tile.density > 0 {
            let emission = Double(tile.density) * perDensityLevel

            // Emitted from every cell of the building, not just its anchor, so
            // a 2×2 factory pollutes from its whole footprint the way it
            // occupies its whole footprint.
            for cell in map.footprintCells(origin: tile.position, size: tile.zone.footprintSize) {
                for dy in -radius ... radius {
                    for dx in -radius ... radius {
                        let target = GridPosition(x: cell.x + dx, y: cell.y + dy)
                        guard map.contains(target) else { continue }
                        let distance = cell.manhattanDistance(to: target)
                        guard distance <= radius else { continue }
                        let falloff = 1 - Double(distance) / Double(radius)
                        levels[target, default: 0] += emission * falloff
                    }
                }
            }
        }

        // Clamped once at the end rather than per addition, so that stacking
        // genuinely accumulates up to the cap instead of each source being
        // individually capped and the sum meaning nothing.
        for (position, value) in levels {
            levels[position] = min(1, value)
        }

        return PollutionMap(levels: levels)
    }
}
