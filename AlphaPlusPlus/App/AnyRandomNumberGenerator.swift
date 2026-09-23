import Foundation

/// A concrete, non-existential wrapper around any `RandomNumberGenerator`,
/// letting `GameController` store one generator type regardless of which
/// concrete generator it was actually constructed with (a real
/// `SystemRandomNumberGenerator` in normal play, a deterministic
/// stand-in like `AlwaysZeroRNG` in tests) without making
/// `GameController` itself generic over it — a class generic over its
/// RNG type would force every view holding a `GameController` to name
/// that type too, just to satisfy a property nothing outside this file
/// cares about.
///
/// Not `any RandomNumberGenerator` (a plain existential): storing the
/// generator that way and passing it `inout` into a *different* generic
/// function call — `advanceSimulation()` does this twice, once for
/// `CityHazards.apply` and once for `CitySimulator.advance` — reliably
/// crashed the Swift 6.3.3 compiler during IR generation. Manual type
/// erasure via a closure sidesteps that: `AnyRandomNumberGenerator` is a
/// perfectly ordinary concrete type conforming to `RandomNumberGenerator`,
/// so passing it `inout` to a generic function is just normal generic
/// specialization, exactly like passing a `SystemRandomNumberGenerator`
/// directly always was.
struct AnyRandomNumberGenerator: RandomNumberGenerator {
    private var _next: () -> UInt64

    init<RNG: RandomNumberGenerator>(_ rng: RNG) {
        var rng = rng
        _next = { rng.next() }
    }

    mutating func next() -> UInt64 { _next() }
}
