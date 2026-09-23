import Foundation

/// **A city is never more than a couple of minutes from being saved.**
///
/// Nothing autosaved, so a crash — or a Mac that ran out of battery, or a
/// force-quit — lost everything since the player last pressed Cmd-S, which
/// for a city builder can be hours. That is a refund, not an inconvenience.
///
/// Three pieces, all small:
///
/// - **A periodic save, only when something changed**, written through
///   `CitySaveFile.write` — which is already atomic, so a crash *during* an
///   autosave leaves the previous one intact rather than half a file.
/// - **A session marker**: written at launch, removed on a clean quit. Still
///   there at the next launch means the last session did not end properly,
///   which is what lets the title screen say so rather than silently
///   offering a city the player does not know was rescued.
/// - **Where the city came from.** Recovering loads the autosave, but Cmd-S
///   afterwards must go back to the player's own file, not into the autosave
///   slot — so the origin is written beside it.
///
/// **Off unless the app turns it on.** `CityDocument` takes one as an
/// optional and only `AlphaPlusPlusApp` passes it, with the real Application
/// Support folder. Every test builds its own in a temporary directory or none
/// at all, so running the suite never writes into a player's saves — the same
/// reason the founding panel, not the controller, owns `UserDefaults`.
@MainActor
final class CityAutosave {

    let directory: URL

    /// How often a running city is saved, in real seconds. Two minutes: short
    /// enough that a crash costs very little, long enough that encoding a
    /// large city is not something the player ever notices happening.
    static let interval: TimeInterval = 120

    var cityURL: URL { directory.appendingPathComponent("Autosave.\(CitySaveFile.fileExtension)") }
    private var metadataURL: URL { directory.appendingPathComponent("Autosave.json") }
    private var sessionMarkerURL: URL { directory.appendingPathComponent("session-running") }

    /// What was true of the city the last time it was written, so an idle
    /// city is not re-encoded every two minutes for nothing.
    private var lastFingerprint: String?

    /// Whether a write is in flight, so a slow disk cannot stack them up.
    private var isWriting = false

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The real one, in `~/Library/Application Support/Alpha++/Autosave`.
    static func standard() -> CityAutosave? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return CityAutosave(directory: base.appendingPathComponent("Alpha++/Autosave", isDirectory: true))
    }

    // MARK: - The session

    /// Marks this session as running, and reports whether the *previous* one
    /// ended without saying so.
    @discardableResult
    func beginSession() -> Bool {
        let crashed = FileManager.default.fileExists(atPath: sessionMarkerURL.path)
        try? Data().write(to: sessionMarkerURL)
        return crashed
    }

    /// A clean quit.
    func endSession() {
        try? FileManager.default.removeItem(at: sessionMarkerURL)
    }

    // MARK: - Saving

    struct Metadata: Codable, Equatable {
        let savedAt: Date
        /// The file the city was opened from or last saved to, if any.
        let origin: URL?
        /// The city's date when it was saved — "spring 1987" says more to a
        /// player deciding whether to recover than a timestamp does.
        let cityDay: Int
    }

    /// Everything that changes when a player does anything worth keeping.
    ///
    /// Not a hash of the whole map, which would cost as much as encoding it.
    /// A tick moves the day; every placement, purchase and bulldoze changes
    /// the treasury or how much is built; loading or founding bumps the
    /// generation. That covers every edit the game has.
    static func fingerprint(of controller: GameController) -> String {
        let built = controller.map.tiles.reduce(0) { $0 + ($1.zone == .empty ? 0 : 1) }
        return "\(controller.cityGeneration)|\(controller.map.elapsedDays)|\(controller.treasury)"
            + "|\(built)|\(controller.map.land?.owned.count ?? -1)"
    }

    /// Saves the city if it has changed since the last save and is worth
    /// keeping. The encode and write run off the main thread: a 64×64 city is
    /// a few megabytes of JSON, and doing that on the render thread every two
    /// minutes would be a hitch the player learns to expect.
    func saveIfChanged(_ controller: GameController, origin: URL?) {
        guard controller.hasACityWorthReturningTo, !isWriting else { return }
        let fingerprint = Self.fingerprint(of: controller)
        guard fingerprint != lastFingerprint else { return }
        lastFingerprint = fingerprint

        let save = controller.snapshot()
        let metadata = Metadata(savedAt: Date(), origin: origin, cityDay: controller.map.elapsedDays)
        let cityURL = cityURL, metadataURL = metadataURL
        isWriting = true
        Task.detached(priority: .utility) {
            Self.write(save, metadata, cityURL: cityURL, metadataURL: metadataURL)
            await MainActor.run { self.isWriting = false }
        }
    }

    /// Saves now, on this thread. For quitting, when there is no "later" for
    /// a background write to finish in.
    func saveNow(_ controller: GameController, origin: URL?) {
        guard controller.hasACityWorthReturningTo else { return }
        lastFingerprint = Self.fingerprint(of: controller)
        Self.write(controller.snapshot(),
                   Metadata(savedAt: Date(), origin: origin, cityDay: controller.map.elapsedDays),
                   cityURL: cityURL, metadataURL: metadataURL)
    }

    /// City first, then the note about it: a crash between the two leaves a
    /// good city with a stale note, never a note pointing at a missing city.
    nonisolated private static func write(_ save: CitySave, _ metadata: Metadata,
                                          cityURL: URL, metadataURL: URL) {
        do {
            try CitySaveFile.write(save, to: cityURL)
            try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
        } catch {
            // Nowhere useful to report this mid-game. The next autosave tries
            // again, and a manual save still surfaces its own errors.
        }
    }

    // MARK: - Recovering

    /// The autosave, if there is one to offer.
    var available: Metadata? {
        guard FileManager.default.fileExists(atPath: cityURL.path),
              let data = try? Data(contentsOf: metadataURL)
        else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    func read() throws -> CitySave {
        try CitySaveFile.read(from: cityURL)
    }
}
