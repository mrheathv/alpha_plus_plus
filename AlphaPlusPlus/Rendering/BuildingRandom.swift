import Foundation

/// A tiny deterministic source of choices for drawing one building.
///
/// **Why not `SystemRandomNumberGenerator`.** A lot's look has to be stable:
/// the same building must draw the same way on every tick, every redraw and
/// every app launch, or the city visibly reshuffles itself while you watch. It
/// also has to differ from its neighbour's, or a row of lots reads as
/// wallpaper. Seeding from the lot's own position gives both — the same
/// property `NeonStyle.variant(for:optionCount:)` already relies on, and for
/// the same reason it avoids `GridPosition.hashValue` (Swift randomises that
/// per process, which is fine for dictionary buckets and wrong for "this lot
/// always looks like this").
///
/// Deliberately not `RandomNumberGenerator`: that protocol's `next()` returns
/// a full `UInt64` and invites `Double.random(in:using:)`, which is far more
/// machinery than picking between three roof styles needs. This is a counter
/// and a hash, and it is enough.
struct BuildingRandom {
    private var state: UInt64

    /// `salt` separates independent decisions about the same building, so
    /// asking for a roof style and then a stack count doesn't correlate them.
    init(seed: GridPosition, salt: Int = 0) {
        // SplitMix64's mixing constant, same one `SeededRNG` uses in the test
        // suite — good avalanche from a tiny amount of arithmetic.
        let mixed = UInt64(bitPattern: Int64(seed.x &* 73_856_093 &+ seed.y &* 19_349_663 &+ salt &* 83_492_791))
        self.state = mixed &+ 0x9E37_79B9_7F4A_7C15
    }

    private mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// An integer in `range`, inclusive.
    mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }

    /// A `CGFloat` in `range`, quantised finely enough for layout work.
    mutating func value(in range: ClosedRange<Double>) -> Double {
        let steps = 1_000
        let t = Double(int(in: 0 ... steps)) / Double(steps)
        return range.lowerBound + t * (range.upperBound - range.lowerBound)
    }

    /// True with probability `chance`.
    mutating func chance(_ chance: Double) -> Bool {
        value(in: 0 ... 1) < chance
    }

    /// One of `options`. Traps on an empty array, which would be a caller bug
    /// rather than something to paper over with an optional.
    mutating func pick<T>(_ options: [T]) -> T {
        precondition(!options.isEmpty, "BuildingRandom.pick needs something to pick from")
        return options[int(in: 0 ... (options.count - 1))]
    }
}
