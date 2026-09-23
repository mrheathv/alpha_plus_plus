import Foundation

/// For every tile and every zone type, the Manhattan distance to the nearest
/// tile of that zone.
///
/// **Why this exists.** `LandValue.value(at:in:)` asks "how far to the nearest
/// road / transit stop / police station / …" eight times per call, and
/// `LandValue.distanceToNearest` answered each one by scanning *every tile on
/// the map*. `CitySimulator.advance` calls `value(at:)` once per footprint
/// cell of every building, every tick, so the cost was
/// `buildings × cells × 8 × tiles` — about 73 million tile visits per tick on
/// a built-out 64×64 map, each one running a filter closure and allocating an
/// intermediate array. Measured, that was 72% of a tick (83 ms of 114 ms), and
/// being `O(buildings × tiles)` it is also the reason tick cost grew
/// superlinearly with map area rather than linearly.
///
/// Computing every answer up front instead turns that into one pass per zone
/// type: `13 × tiles × 2`, about 106,000 operations for the same map, after
/// which each query is an array subscript.
///
/// **How.** A two-pass chamfer distance transform, which is the standard way
/// to get exact *Manhattan* distances in linear time. Seed every tile of the
/// zone with 0 and everything else with infinity; sweep forward (left-to-right,
/// bottom-to-top) taking `min(self, left + 1, below + 1)`; then sweep backward
/// taking `min(self, right + 1, above + 1)`. Every shortest 4-connected path
/// is monotone in each axis, so one sweep in each diagonal direction is enough
/// to have considered all of them — which is why this gives exact answers
/// rather than an approximation.
///
/// This works *because* the metric is Manhattan rather than path distance:
/// these are straight-line grid distances that ignore walls and roads
/// entirely, exactly as the scan it replaces did. `Traffic` needs real routing
/// over the road network and so still does real breadth-first searches; this
/// is not a substitute for that.
struct ZoneDistanceField: Equatable {

    /// Distance per zone, each a flat `width * height` array in the same
    /// row-major layout `CityMap` uses (`index = y * width + x`).
    ///
    /// Keyed by `ZoneType` and populated for *every* case rather than only
    /// the eight `LandValue` happens to ask about today. Computing a field
    /// nobody queries costs one linear sweep, while leaving one out would
    /// mean a future caller silently falling back to the slow path — or, if
    /// there were no fallback, getting a wrong answer.
    private let distances: [ZoneType: [Int32]]

    /// Distance to the nearest water, in the same layout.
    ///
    /// A channel of its own because water is not a `ZoneType` — it is a
    /// property of the ground, and a bridge is a road tile that is *also*
    /// wet. It goes through the identical two-sweep transform, so a
    /// waterfront query costs exactly what a nearest-park query costs, which
    /// is what keeps `LandValue` off the `O(tiles²)` path this type exists to
    /// delete.
    private let water: [Int32]
    private let width: Int
    private let height: Int

    /// Stands in for "no tile of this zone exists anywhere." Kept well below
    /// `Int32.max` so the `+ 1` inside the sweeps can never overflow.
    private static let unreachable: Int32 = .max / 4

    // MARK: - Building one

    static func compute(for map: CityMap) -> ZoneDistanceField {
        var fields: [ZoneType: [Int32]] = [:]
        fields.reserveCapacity(ZoneType.allCases.count)
        for zone in ZoneType.allCases {
            fields[zone] = transform(for: zone, in: map)
        }
        return ZoneDistanceField(
            distances: fields,
            water: transform(in: map) { $0.isWater },
            width: map.width, height: map.height
        )
    }

    private static func transform(for zone: ZoneType, in map: CityMap) -> [Int32] {
        transform(in: map) { $0.zone == zone }
    }

    /// The two-sweep chamfer transform, over whatever counts as a source.
    ///
    /// Taken as a predicate rather than a zone so water shares it exactly
    /// rather than getting a second copy — this is the one piece of code that
    /// makes every distance question in the game linear rather than
    /// quadratic, and a near-copy of it would be the kind of duplication this
    /// project has paid for repeatedly.
    private static func transform(in map: CityMap, isSource: (Tile) -> Bool) -> [Int32] {
        let width = map.width
        let height = map.height
        var distance = [Int32](repeating: unreachable, count: width * height)

        for (index, tile) in map.tiles.enumerated() where isSource(tile) {
            distance[index] = 0
        }

        // Forward sweep: each tile considers the two neighbours already
        // finalised in this pass (west and south, given row-major order from
        // index 0).
        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = y * width + x
                var best = distance[index]
                if x > 0 { best = min(best, distance[index - 1] &+ 1) }
                if y > 0 { best = min(best, distance[index - width] &+ 1) }
                distance[index] = best
            }
        }

        // Backward sweep: the other two neighbours (east and north).
        for y in stride(from: height - 1, through: 0, by: -1) {
            for x in stride(from: width - 1, through: 0, by: -1) {
                let index = y * width + x
                var best = distance[index]
                if x < width - 1 { best = min(best, distance[index + 1] &+ 1) }
                if y < height - 1 { best = min(best, distance[index + width] &+ 1) }
                distance[index] = best
            }
        }

        return distance
    }

    // MARK: - Querying

    /// Manhattan distance from `position` to the nearest tile of `zone`, or
    /// `nil` when the map contains no such tile — the same contract
    /// `LandValue.distanceToNearest` has, so the two are interchangeable.
    func distance(to zone: ZoneType, at position: GridPosition) -> Int? {
        guard position.x >= 0, position.y >= 0, position.x < width, position.y < height else { return nil }
        guard let field = distances[zone] else { return nil }
        let value = field[position.y * width + position.x]
        return value >= Self.unreachable ? nil : Int(value)
    }

    /// Manhattan distance to the nearest water, or `nil` on a dry map.
    func distanceToWater(at position: GridPosition) -> Int? {
        guard position.x >= 0, position.y >= 0, position.x < width, position.y < height else { return nil }
        let value = water[position.y * width + position.x]
        return value >= Self.unreachable ? nil : Int(value)
    }
}
