import XCTest
@testable import AlphaPlusPlus

/// Tests for `CitySaveFile` — encoding a `CitySave` to disk and reading it
/// back — and for `CityDocument`, which turns that into Open/Save.
///
/// `CitySaveTests` already covers the envelope itself. These are about the
/// file: that it survives a real write-and-read through the filesystem, that
/// a bad one fails in a way the player can act on, and that a failed load
/// leaves the open city alone.
@MainActor
final class CitySaveFileTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CitySaveFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func url(_ name: String = "city") -> URL {
        directory.appendingPathComponent(name).appendingPathExtension(CitySaveFile.fileExtension)
    }

    /// A city with something done to every part of its state — same reasoning
    /// as `CitySaveTests`' own fixture: a save format fails by dropping the
    /// one field nobody exercised.
    private func makeCity() -> GameController {
        let controller = GameController(
            map: CityMap(width: MapSize.small.dimension, height: MapSize.small.dimension),
            rng: AlwaysZeroRNG()
        )
        for x in 0..<10 {
            controller.selectedTool = .road
            _ = controller.place(at: GridPosition(x: x, y: 4))
        }
        controller.selectedTool = .residential
        _ = controller.place(at: GridPosition(x: 0, y: 2))
        controller.selectedTool = .commercial
        _ = controller.place(at: GridPosition(x: 2, y: 2))
        controller.selectedTool = .waterTower
        _ = controller.place(at: GridPosition(x: 6, y: 2))
        _ = controller.layPipe(at: GridPosition(x: 5, y: 2))
        controller.setFundingLevel(0.5, for: .policeStation)
        controller.setOrdinance(\.neighborhoodWatch, active: true)
        controller.taxRate = 1.25
        _ = controller.issueBond()
        for _ in 0..<5 { controller.advanceSimulation() }
        return controller
    }

    // MARK: - Round-trip through the filesystem

    func testACityWrittenToDiskReadsBackIdentically() throws {
        let original = makeCity()
        let destination = url()

        try CitySaveFile.write(original.snapshot(), to: destination)
        let readBack = try CitySaveFile.read(from: destination)

        XCTAssertEqual(readBack, original.snapshot())
    }

    func testTheWrittenFileIsReadableJSON() throws {
        let original = makeCity()
        let destination = url()
        try CitySaveFile.write(original.snapshot(), to: destination)

        let text = try String(contentsOf: destination, encoding: .utf8)

        // Pretty-printed and sorted, so a save diffs cleanly and a human can
        // read one in a bug report.
        XCTAssertTrue(text.contains("\n"), "the save is not pretty-printed")
        // ZoneType's String raw values are the reason a save stays readable
        // and stable across inserted enum cases — check they really are text.
        XCTAssertTrue(text.contains("residential"), "zone types did not encode as readable strings")
        XCTAssertTrue(text.contains("formatVersion"))
    }

    func testOverwritingAnExistingSaveReplacesIt() throws {
        let destination = url()

        let first = makeCity()
        try CitySaveFile.write(first.snapshot(), to: destination)

        let second = makeCity()
        second.advanceSimulation()
        second.advanceSimulation()
        try CitySaveFile.write(second.snapshot(), to: destination)

        XCTAssertEqual(try CitySaveFile.read(from: destination), second.snapshot())
    }

    // MARK: - Bad files

    func testReadingAFileThatIsNotACityThrowsADecodingError() throws {
        let destination = url()
        try Data("this is not a city".utf8).write(to: destination)

        XCTAssertThrowsError(try CitySaveFile.read(from: destination)) { error in
            XCTAssertTrue(error is DecodingError, "got \(type(of: error)) instead of DecodingError")
        }
    }

    func testReadingASaveFromANewerBuildIsRejectedByVersionNotByDecoding() throws {
        let destination = url()
        let fromTheFuture = CitySave(
            formatVersion: CitySave.currentFormatVersion + 1,
            map: CityMap(width: 8, height: 8),
            treasury: 0,
            taxRate: 1.0,
            bondBalance: 0,
            history: []
        )
        // Written directly rather than through `write`, since `write` has no
        // reason to refuse producing one — it's reading that must be strict.
        try CitySaveFile.makeEncoder().encode(fromTheFuture).write(to: destination)

        XCTAssertThrowsError(try CitySaveFile.read(from: destination)) { error in
            XCTAssertEqual(
                error as? CitySave.LoadError,
                .unsupportedFormatVersion(
                    found: CitySave.currentFormatVersion + 1,
                    supported: CitySave.currentFormatVersion
                )
            )
        }
    }

    func testReadingAMissingFileThrows() {
        XCTAssertThrowsError(try CitySaveFile.read(from: url("nothing-here")))
    }

    /// Each failure has to produce a *different* sentence, or the error
    /// message is doing no work — this is the whole reason `describe` exists
    /// rather than showing `DecodingError`'s own text, which is identical for
    /// a corrupt file and a save from next year's build.
    func testEachFailureDescribesItselfDistinctly() throws {
        let versionError = CitySave.LoadError.unsupportedFormatVersion(found: 99, supported: 1)
        let versionText = CitySaveFile.describe(versionError)
        XCTAssertTrue(versionText.contains("newer version"), versionText)
        XCTAssertTrue(versionText.contains("99"), versionText)

        let corrupt = url("corrupt")
        try Data("nope".utf8).write(to: corrupt)
        var decodingText = ""
        do {
            _ = try CitySaveFile.read(from: corrupt)
        } catch {
            decodingText = CitySaveFile.describe(error)
        }
        XCTAssertTrue(decodingText.contains("isn't a valid"), decodingText)

        var missingText = ""
        do {
            _ = try CitySaveFile.read(from: url("absent"))
        } catch {
            missingText = CitySaveFile.describe(error)
        }
        XCTAssertTrue(missingText.contains("no longer exists"), missingText)

        XCTAssertNotEqual(versionText, decodingText)
        XCTAssertNotEqual(decodingText, missingText)
    }

    // MARK: - CityDocument

    func testSavingThenLoadingThroughTheDocumentPreservesTheCity() throws {
        let document = CityDocument(controller: makeCity())
        let before = document.controller.snapshot()
        let destination = url()

        document.write(to: destination)
        XCTAssertNil(document.errorMessage)
        XCTAssertEqual(document.currentURL, destination)

        let reopened = CityDocument()
        reopened.load(from: destination)

        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.controller.snapshot(), before)
        XCTAssertEqual(reopened.currentURL, destination)
    }

    /// A load that fails must leave the city the player already had exactly
    /// as it was — this is the whole reason `CitySaveFile.read` validates
    /// before `restore(from:)` is ever called.
    func testAFailedLoadLeavesTheOpenCityUntouched() throws {
        let document = CityDocument(controller: makeCity())
        let before = document.controller.snapshot()

        let corrupt = url("corrupt")
        try Data("definitely not a city".utf8).write(to: corrupt)
        document.load(from: corrupt)

        XCTAssertNotNil(document.errorMessage)
        XCTAssertEqual(document.controller.snapshot(), before, "a failed load damaged the open city")
        XCTAssertNil(document.currentURL, "a failed load claimed the file as the document's own")
    }

    func testLoadingBumpsCityGenerationSoTheSceneRebuilds() throws {
        let source = CityDocument(controller: makeCity())
        let destination = url()
        source.write(to: destination)

        let target = CityDocument()
        let before = target.controller.cityGeneration
        target.load(from: destination)

        XCTAssertEqual(
            target.controller.cityGeneration, before + 1,
            "a load must bump cityGeneration or the scene keeps drawing the old map"
        )
    }

    func testDisplayNameFollowsTheFileAndFallsBackBeforeOneExists() throws {
        let document = CityDocument(controller: makeCity())
        XCTAssertEqual(document.displayName, CitySaveFile.defaultFileName)

        document.write(to: url("Riverside"))
        XCTAssertEqual(document.displayName, "Riverside")
    }

    func testDefaultDirectoryIsCreatedUnderApplicationSupport() throws {
        let directory = try CitySaveFile.defaultDirectory()
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(directory.path.contains("Application Support"), directory.path)
        XCTAssertTrue(directory.path.contains("Alpha++"), directory.path)
    }
}
