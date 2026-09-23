import Foundation

/// Everything about a city worth keeping when the app closes, as one
/// serializable value.
///
/// **Why this type exists at all.** `CityMap` was already `Codable` and
/// already carries nearly the whole city — every `Tile` (zone, building
/// origin, `hasPipe`, `hasPowerLine`) plus `serviceFunding`, `trafficLoad`,
/// `waterSupply`, `powerSupply`, `demand`, and `ordinances`. But a handful of
/// things a player would be upset to lose live on `GameController` instead:
/// the treasury, the tax rate, outstanding bond debt, and the stat history
/// behind the sparklines. There was no single value that meant "this city,"
/// only a `CityMap` plus four loose `@Published` properties. This is that
/// value.
///
/// **What is deliberately not here.** `selectedTool`, `isRunning`,
/// `simulationSpeed`, and `overlayMode` are all view preferences — how you
/// are *looking* at a city, not anything about the city itself; a save that
/// restored your overlay mode would be saving the camera, not the town.
/// `lastHazardStrikes` and `isPowerOutageActive` are both recomputed from
/// scratch on the next `advanceSimulation()` tick, so persisting them would
/// only create a window where they disagree with the map they describe.
///
/// **The RNG is not saved.** `GameController.rng` is an
/// `AnyRandomNumberGenerator`, which is not `Codable` (a random generator's
/// internal state is deliberately opaque), and restoring a city installs a
/// fresh system generator. So a reloaded city is *statistically* the same
/// city but will not replay tick-for-tick identically to the run that saved
/// it — the same seed of bad luck won't repeat. For a city builder that
/// difference is invisible. It is written down here rather than left implicit
/// because it would stop being invisible the moment anything wanted
/// deterministic replay — a recorded demo, a reproducible bug report, or a
/// playtest harness diffing two runs of the same city against each other.
struct CitySave: Equatable, Codable, Sendable {

    /// Bumped whenever this struct's shape changes in a way an older or
    /// newer build would read wrongly.
    ///
    /// Checked on load so a save from a *newer* build fails loudly rather
    /// than being silently half-read: `Codable` skips unknown keys and
    /// throws on missing ones, so a future field this build has never heard
    /// of would decode into a plausible-looking city with something quietly
    /// absent. `ZoneType` already pays for the other half of this with
    /// `String` raw values, so inserting a new zone case never renumbers the
    /// existing ones (see its own doc comment) — between the two, old saves
    /// stay readable and unreadable ones say so.
    static let currentFormatVersion = 2

    /// The oldest format this build can still read.
    ///
    /// **Why there is a floor at all, and why it moved to 2.** `CityMap` uses
    /// the synthesised `Codable` conformance, and synthesised decoding throws
    /// on a *missing* key even for a property that has a default value. So
    /// every non-optional field ever added to `CityMap` has silently made
    /// older saves undecodable — `pollution`, `ordinances` and `taxRate` all
    /// did, and none of them bumped this number, so the failure showed up as a
    /// raw `DecodingError` ("the data couldn't be read") rather than as
    /// anything a player could act on. `regionalEconomy` is the fourth, and
    /// the first to admit it.
    ///
    /// The alternative is hand-writing `CityMap.init(from:)` with
    /// `decodeIfPresent` for every field, which buys real migration at the
    /// price of a decoder that must be updated in lockstep with the struct
    /// forever — the kind of duplication this project has repeatedly found
    /// goes stale without failing anything. For a game with no released
    /// version, saying so loudly is worth more than migrating. The moment
    /// there *is* a released version, this is the line to stop moving, and
    /// that is what the constant is for.
    ///
    /// An optional field still needs no bump: `decodeIfPresent` handles those
    /// for free, which is why `peakPopulation` and `Tile.damagedBy` cost
    /// nothing. Prefer that where the field is genuinely optional.
    static let minimumSupportedFormatVersion = 2

    /// The format version this particular save was written with.
    let formatVersion: Int

    let map: CityMap
    let treasury: Int
    let taxRate: Double
    let bondBalance: Int
    let history: [CityStatSnapshot]

    /// The city's high-water population mark, which is what `Unlocks` reads.
    ///
    /// `Optional` so that saves written before unlocks existed still decode —
    /// synthesised `init(from:)` uses `decodeIfPresent` for optionals — rather
    /// than needing a `formatVersion` bump and a migration for one integer.
    /// The same trick `Tile.damagedBy` uses.
    let peakPopulation: Int?

    /// The highest rank this city has earned — see `Milestone`. `Optional`
    /// for the same reason `peakPopulation` is, and a high-water mark for the
    /// same reason too: a save must not hand back a lower rank than the
    /// player earned just because the city was having a bad day when it was
    /// written.
    let milestone: Milestone?

    init(
        formatVersion: Int = CitySave.currentFormatVersion,
        map: CityMap,
        treasury: Int,
        taxRate: Double,
        bondBalance: Int,
        history: [CityStatSnapshot],
        peakPopulation: Int? = nil,
        milestone: Milestone? = nil
    ) {
        self.formatVersion = formatVersion
        self.map = map
        self.treasury = treasury
        self.taxRate = taxRate
        self.bondBalance = bondBalance
        self.history = history
        self.peakPopulation = peakPopulation
        self.milestone = milestone
    }
}

extension CitySave {

    /// Why a save couldn't be read back.
    ///
    /// A named error rather than letting `DecodingError` reach the player:
    /// "The data couldn't be read because it isn't in the correct format"
    /// is true of a corrupt file, a JSON file that was never a city, and a
    /// save from next year's build alike, and only one of those is worth
    /// telling someone to go find a newer copy of the app for.
    enum LoadError: Error, Equatable {
        /// The save was written by a build using a newer `formatVersion`
        /// than this one understands.
        case unsupportedFormatVersion(found: Int, supported: Int)

        /// The save predates a format change this build cannot read back —
        /// see `minimumSupportedFormatVersion`.
        case obsoleteFormatVersion(found: Int, oldestSupported: Int)
    }

    /// Checks a `formatVersion` against what this build can read, in both
    /// directions.
    ///
    /// Static and taking a bare `Int` so it can run *before* the full decode.
    /// That ordering is the whole point: a version mismatch usually means a
    /// field this build has never heard of or a field it now requires, and
    /// either way `JSONDecoder` throws its own opaque error first, so a check
    /// that ran on an already-decoded `CitySave` could only ever catch the
    /// cases where decoding happened to succeed anyway. See
    /// `CitySaveFile.read(from:)`, which peeks at the version key alone.
    static func validateFormatVersion(_ version: Int) throws {
        guard version <= currentFormatVersion else {
            throw LoadError.unsupportedFormatVersion(
                found: version,
                supported: currentFormatVersion
            )
        }
        guard version >= minimumSupportedFormatVersion else {
            throw LoadError.obsoleteFormatVersion(
                found: version,
                oldestSupported: minimumSupportedFormatVersion
            )
        }
    }

    /// Checks this save's own `formatVersion`.
    func validateFormatVersion() throws {
        try Self.validateFormatVersion(formatVersion)
    }
}

/// Just enough of a save to read its version number, for the peek in
/// `CitySaveFile.read(from:)`.
///
/// A separate type rather than a `JSONSerialization` dictionary lookup so the
/// key is spelled once, by the compiler, from the same property name
/// `CitySave` uses — a hand-written `"formatVersion"` string here would be
/// free to drift from the real one and would fail open when it did.
struct CitySaveVersion: Decodable, Sendable {
    let formatVersion: Int
}
