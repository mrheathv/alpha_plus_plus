import Foundation

/// **What kind of land a new city is founded on.**
///
/// Every map this game has ever generated was the same flat, featureless
/// plane, which is most of why every city looked alike: the *shape* of the
/// land is what makes one place different from another before a single lot
/// is zoned. Water is the genre's answer, and it is a mechanic rather than
/// decoration — it takes ground away, and where it runs decides where a city
/// can go.
///
/// **A choice at founding, not a change forced on every city.** `flat` is
/// exactly what the game did before, so it stays available and stays the
/// default; and because water lives on `Tile` as an optional, a save written
/// before any of this loads as dry land for free. Nobody's city changes under
/// them.
enum Terrain: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    /// No water at all — the map every city was built on until now.
    case flat
    /// Sea along one edge, behind a ragged shoreline.
    case coastal
    /// A handful of inland lakes, well clear of the edges.
    case lakes
    /// A river across the map, which **cuts it in two**. The most
    /// characterful and the only one that makes bridges necessary rather
    /// than decorative — see `ZoneType.bridgeSurcharge`.
    case river

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flat: return "Flat"
        case .coastal: return "Coastal"
        case .lakes: return "Lakes"
        case .river: return "River"
        }
    }

    /// One line a player can read before committing to a map.
    var summary: String {
        switch self {
        case .flat: return "Open ground, nothing in the way."
        case .coastal: return "A shoreline along one edge. Waterfront land is worth more."
        case .lakes: return "Scattered lakes to build around."
        case .river: return "A river splits the map. You will need bridges."
        }
    }
}

/// Where the water goes.
///
/// Deterministic from a seed, so the same choice and the same seed always
/// produce the same coastline — a city has to be reproducible for the same
/// reason `RegionalEconomy` is a clock rather than a dice roll, and because a
/// player who likes a map should be able to get it back.
///
/// Lives in `Simulation/` and imports Foundation only: this decides which
/// *tiles* are water, and nothing about how they are drawn.
enum TerrainGenerator {

    /// Fills `isWater` across `map` for `terrain`.
    static func apply(_ terrain: Terrain, to map: inout CityMap, seed: UInt64) {
        guard terrain != .flat else { return }
        var random = TerrainRandom(seed: seed)
        switch terrain {
        case .flat: return
        case .coastal: carveCoast(&map, &random)
        case .lakes: carveLakes(&map, &random)
        case .river: carveRiver(&map, &random)
        }
    }

    // MARK: - The three shapes

    /// Sea beyond a ragged boundary along one edge.
    ///
    /// The boundary is a slow random walk rather than a straight line,
    /// because a straight coast reads as the map having been cropped.
    private static func carveCoast(_ map: inout CityMap, _ random: inout TerrainRandom) {
        let edge = random.int(in: 0 ... 3)
        let horizontal = edge < 2
        let span = horizontal ? map.width : map.height
        let across = horizontal ? map.height : map.width

        // Shallow enough to leave the great majority of the map buildable —
        // the point is a shoreline to build along, not a smaller map.
        var depth = Double(across) * 0.14
        for step in 0 ..< span {
            depth += random.value(in: -0.55 ... 0.55)
            depth = Swift.max(1, Swift.min(Double(across) * 0.26, depth))
            for inward in 0 ..< Int(depth.rounded()) {
                let deep = edge % 2 == 0 ? inward : across - 1 - inward
                let position = horizontal
                    ? GridPosition(x: step, y: deep)
                    : GridPosition(x: deep, y: step)
                if map.contains(position) { map[position].isWater = true }
            }
        }
    }

    /// A few inland lakes, kept clear of the edges so a coast and a lake
    /// never read as the same thing.
    private static func carveLakes(_ map: inout CityMap, _ random: inout TerrainRandom) {
        let margin = 4
        for _ in 0 ..< random.int(in: 2 ... 4) {
            let centre = GridPosition(
                x: random.int(in: margin ... Swift.max(margin, map.width - margin - 1)),
                y: random.int(in: margin ... Swift.max(margin, map.height - margin - 1))
            )
            let radius = Double(Swift.min(map.width, map.height)) * random.value(in: 0.06 ... 0.11)
            fillBlob(&map, around: centre, radius: radius, &random)
        }
    }

    /// A river from one edge to the opposite one, meandering as it goes.
    ///
    /// **This is the one that cuts the map in two**, which is the whole
    /// reason it is worth having and the whole reason bridges exist. It is
    /// carved as a walk rather than a line so that the two halves are
    /// different shapes and a crossing is a real decision about *where*.
    private static func carveRiver(_ map: inout CityMap, _ random: inout TerrainRandom) {
        let horizontal = random.int(in: 0 ... 1) == 0
        let along = horizontal ? map.width : map.height
        let across = horizontal ? map.height : map.width

        var centre = Double(across) * random.value(in: 0.35 ... 0.65)
        var drift = random.value(in: -0.5 ... 0.5)
        let halfWidth = random.value(in: 1.1 ... 1.9)

        for step in 0 ..< along {
            // A drifting heading rather than a fresh offset each step: a walk
            // that re-rolls every column is a jagged edge, not a river.
            drift += random.value(in: -0.22 ... 0.22)
            drift = Swift.max(-0.75, Swift.min(0.75, drift))
            centre += drift
            centre = Swift.max(halfWidth + 1, Swift.min(Double(across) - halfWidth - 2, centre))

            let low = Int((centre - halfWidth).rounded())
            let high = Int((centre + halfWidth).rounded())
            for deep in low ... high {
                let position = horizontal
                    ? GridPosition(x: step, y: deep)
                    : GridPosition(x: deep, y: step)
                if map.contains(position) { map[position].isWater = true }
            }
        }
    }

    private static func fillBlob(
        _ map: inout CityMap, around centre: GridPosition, radius: Double,
        _ random: inout TerrainRandom
    ) {
        let reach = Int(radius.rounded()) + 2
        for dx in -reach ... reach {
            for dy in -reach ... reach {
                let position = GridPosition(x: centre.x + dx, y: centre.y + dy)
                guard map.contains(position) else { continue }
                // Squared distance against a radius wobbled per cell, so the
                // shore is ragged rather than a drawn circle.
                let distance = (Double(dx) * Double(dx) + Double(dy) * Double(dy)).squareRoot()
                if distance <= radius + random.value(in: -0.7 ... 0.7) {
                    map[position].isWater = true
                }
            }
        }
    }
}

/// A small deterministic generator, so terrain does not depend on the
/// simulation's RNG or on `Double.random`.
///
/// `Simulation/` may import Foundation only and has no seeded generator of
/// its own — every other random decision in the game is handed one by its
/// caller. Terrain is generated once, before a city exists, so it carries its
/// own. SplitMix64, which is four lines and has no state to get wrong.
struct TerrainRandom {
    private var state: UInt64

    init(seed: UInt64) {
        // Never zero: SplitMix64 from a zero state is fine, but a zero *seed*
        // is what a caller passes by accident, and giving it a distinctive
        // start makes "seed 0" a real map rather than a suspicious one.
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func value(in range: ClosedRange<Double>) -> Double {
        // Over 2^53, for the reason `ScriptedRNG` documents: a Double keeps
        // only that many bits of significand, so scaling by UInt64.max throws
        // the top bits away and produces a number nothing like the one meant.
        let unit = Double(next() >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = range.upperBound - range.lowerBound + 1
        guard span > 0 else { return range.lowerBound }
        return range.lowerBound + Int(next() % UInt64(span))
    }
}
