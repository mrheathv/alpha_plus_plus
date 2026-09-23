import Foundation

/// Reading and writing `CitySave` to disk.
///
/// Lives in `App/`, not `Simulation/`: the simulation's job ends at producing
/// a serializable value, and knowing where a file goes on a Mac is squarely
/// application business. Keeping the two apart is also what lets the playtest
/// harness snapshot and replay cities without a file ever existing.
enum CitySaveFile {

    /// The file extension for a saved city.
    static let fileExtension = "alphacity"

    // MARK: - Coding
    //
    // JSON rather than a binary format, which is what the data model was
    // already designed for: `ZoneType`'s doc comment chose `String` raw
    // values specifically so "save files are readable and, more importantly,
    // stable: adding a case in the middle later won't silently reinterpret
    // old saves." A binary encoder would throw that property away.

    /// Pretty-printed with sorted keys so a save diffs cleanly — useful when
    /// a bug report comes with a file attached, and cheap given these are
    /// hand-sized documents rather than a hot path.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    // MARK: - Writing

    /// Writes `save` to `url`.
    ///
    /// Atomically, so an interruption mid-write — a crash, a full disk, the
    /// app being force-quit — can't leave a half-written file where a working
    /// save used to be. `Data.write(to:options:.atomic)` writes to a
    /// temporary file beside the destination and renames it into place, so
    /// the old save survives intact until the new one is complete.
    static func write(_ save: CitySave, to url: URL) throws {
        let data = try makeEncoder().encode(save)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Reading

    /// Reads a `CitySave` back from `url`, rejecting one this build cannot
    /// read before returning it.
    ///
    /// The version check happens here rather than being left to the caller so
    /// there is no way to obtain an unvalidated `CitySave` from disk and use
    /// it by accident.
    ///
    /// **It reads the version first, on its own.** Decoding the whole save and
    /// then checking was the obvious order and it was wrong: a save from
    /// either side of a format change is exactly the save whose *fields* do
    /// not line up, so `JSONDecoder` threw "the data couldn't be read because
    /// it isn't in the correct format" before the version check — which exists
    /// to say something better than that — ever ran. Two decodes of a file
    /// measured in tens of kilobytes is not a cost worth optimising against a
    /// legible error message.
    static func read(from url: URL) throws -> CitySave {
        let data = try Data(contentsOf: url)
        let decoder = makeDecoder()
        let version = try decoder.decode(CitySaveVersion.self, from: data)
        try CitySave.validateFormatVersion(version.formatVersion)
        return try decoder.decode(CitySave.self, from: data)
    }

    // MARK: - Where saves live

    /// `~/Library/Application Support/Alpha++/Cities`, created on demand.
    ///
    /// Application Support rather than Documents: these are the app's own
    /// data files in the app's own format, which is exactly what Apple's
    /// File System Programming Guide reserves this directory for. The save
    /// panel still opens wherever the player last chose — this is only the
    /// default suggestion, not a restriction.
    static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("Alpha++", isDirectory: true)
            .appendingPathComponent("Cities", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A default filename for a city that hasn't been saved before.
    static let defaultFileName = "Untitled City"
}

extension CitySaveFile {

    /// Why a save couldn't be written or read, in terms a player can act on.
    ///
    /// `CitySave.LoadError` covers the one case the format itself can
    /// diagnose; this adds the cases that are about the file rather than its
    /// contents, and turns all of them into a sentence worth showing in an
    /// alert. `DecodingError`'s own description — "The data couldn't be read
    /// because it isn't in the correct format" — is equally true of a corrupt
    /// file, a JSON file that was never a city, and a save from a newer
    /// build, and only one of those is worth telling someone to go update the
    /// app for.
    static func describe(_ error: Error) -> String {
        if let loadError = error as? CitySave.LoadError {
            switch loadError {
            case let .unsupportedFormatVersion(found, supported):
                return "This city was saved by a newer version of Alpha++ "
                    + "(format \(found); this build understands format \(supported)). "
                    + "Update Alpha++ to open it."
            case let .obsoleteFormatVersion(found, oldestSupported):
                return "This city was saved in an older format (\(found)) that this "
                    + "build can no longer read; the oldest it understands is format "
                    + "\(oldestSupported)."
            }
        }
        if error is DecodingError {
            return "This file isn't a valid Alpha++ city, or it has been damaged."
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
            return "That city file no longer exists."
        }
        return nsError.localizedDescription
    }
}
