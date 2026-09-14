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
    static let currentFormatVersion = 1

    /// The format version this particular save was written with.
    let formatVersion: Int

    let map: CityMap
    let treasury: Int
    let taxRate: Double
    let bondBalance: Int
    let history: [CityStatSnapshot]

    init(
        formatVersion: Int = CitySave.currentFormatVersion,
        map: CityMap,
        treasury: Int,
        taxRate: Double,
        bondBalance: Int,
        history: [CityStatSnapshot]
    ) {
        self.formatVersion = formatVersion
        self.map = map
        self.treasury = treasury
        self.taxRate = taxRate
        self.bondBalance = bondBalance
        self.history = history
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
    }

    /// Checks `formatVersion` before anything reads the rest of this value.
    ///
    /// Only *newer* is rejected. An older version is explicitly allowed
    /// through: there is exactly one format today, so there is nothing yet
    /// to migrate, and the first time that stops being true this is the one
    /// place a migration belongs.
    func validateFormatVersion() throws {
        guard formatVersion <= Self.currentFormatVersion else {
            throw LoadError.unsupportedFormatVersion(
                found: formatVersion,
                supported: Self.currentFormatVersion
            )
        }
    }
}
