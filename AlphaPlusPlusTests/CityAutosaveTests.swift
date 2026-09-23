import SwiftUI
import XCTest
@testable import AlphaPlusPlus

/// Autosave and crash recovery, always in a temporary directory — the suite
/// must never write into a player's Application Support folder.
@MainActor
final class CityAutosaveTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autosave-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func builtCity() -> GameController {
        let controller = GameController(rng: AlwaysZeroRNG())
        controller.selectTool(.road)
        for x in 0 ..< 6 { controller.place(at: GridPosition(x: x, y: 3)) }
        return controller
    }

    // MARK: - The session marker

    func testACleanQuitIsNotReportedAsACrash() {
        let first = CityAutosave(directory: directory)
        XCTAssertFalse(first.beginSession(), "a first launch is not a crash")
        first.endSession()
        XCTAssertFalse(CityAutosave(directory: directory).beginSession())
    }

    func testASessionThatNeverEndedIsReported() {
        CityAutosave(directory: directory).beginSession()
        // …and the process dies here, with no endSession.
        XCTAssertTrue(CityAutosave(directory: directory).beginSession())
    }

    // MARK: - Saving

    func testAnEmptyCityIsNotWorthAutosaving() {
        let autosave = CityAutosave(directory: directory)
        autosave.saveNow(GameController(), origin: nil)
        XCTAssertNil(autosave.available)
    }

    func testAnAutosaveRoundTripsTheCity() throws {
        let autosave = CityAutosave(directory: directory)
        let city = builtCity()
        let origin = URL(fileURLWithPath: "/tmp/My City.alphacity")
        autosave.saveNow(city, origin: origin)

        XCTAssertEqual(autosave.available?.origin, origin)
        let loaded = GameController()
        try loaded.restore(from: autosave.read())
        XCTAssertEqual(loaded.map[GridPosition(x: 2, y: 3)].zone, .road)
        XCTAssertEqual(loaded.treasury, city.treasury)
    }

    /// Every kind of edit changes the fingerprint — otherwise an edit could
    /// happen and the autosave decide nothing had.
    func testEveryKindOfEditIsNoticed() {
        let city = builtCity()
        var seen = [CityAutosave.fingerprint(of: city)]
        func expectChange(_ what: String) {
            let now = CityAutosave.fingerprint(of: city)
            XCTAssertFalse(seen.contains(now), "\(what) was not noticed")
            seen.append(now)
        }
        city.place(at: GridPosition(x: 6, y: 3)); expectChange("placing")
        city.bulldoze(at: GridPosition(x: 0, y: 3)); expectChange("a free bulldoze")
        city.advanceSimulation(); expectChange("a day passing")
    }

    /// The background save completes, and an unchanged city is not written
    /// twice.
    func testTheBackgroundSaveLandsAndIsNotRepeated() async throws {
        let autosave = CityAutosave(directory: directory)
        let city = builtCity()
        autosave.saveIfChanged(city, origin: nil)
        for _ in 0 ..< 100 where autosave.available == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        let first = try XCTUnwrap(autosave.available)

        try await Task.sleep(nanoseconds: 50_000_000)
        autosave.saveIfChanged(city, origin: nil)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(autosave.available?.savedAt, first.savedAt, "an unchanged city was written again")
    }

    // MARK: - Recovering

    /// **Recovery puts the player back in their city, with Cmd-S pointing at
    /// their own file.** Saving a recovered city into the autosave slot would
    /// have the next autosave overwrite it.
    func testRecoveringResumesTheCityAndRemembersWhereItCameFrom() {
        let origin = directory.appendingPathComponent("Mine.alphacity")
        CityAutosave(directory: directory).saveNow(builtCity(), origin: origin)

        let document = CityDocument(autosave: CityAutosave(directory: directory))
        XCTAssertNotNil(document.recoverable)
        document.resumeAutosave()

        XCTAssertFalse(document.isShowingTitle)
        XCTAssertEqual(document.controller.map[GridPosition(x: 2, y: 3)].zone, .road)
        XCTAssertEqual(document.currentURL, origin)
    }

    /// A document built without one — every test, every render — has no
    /// autosave and reports no crash.
    func testADocumentWithoutAutosaveHasNone() {
        let document = CityDocument()
        XCTAssertNil(document.autosave)
        XCTAssertNil(document.recoverable)
        XCTAssertFalse(document.previousSessionEndedBadly)
    }

    /// **The title screen after a crash.** The note and the Continue button
    /// are the whole feature from a player's side, and the title is composed
    /// against its frame — so it is rendered, like the ordinary title is.
    func testRenderTheTitleAfterACrash() throws {
        let crashed = CityAutosave(directory: directory)
        crashed.beginSession()
        crashed.saveNow(builtCity(), origin: nil)
        let document = CityDocument(autosave: CityAutosave(directory: directory))
        XCTAssertTrue(document.previousSessionEndedBadly)

        let renderer = ImageRenderer(content: TitleScreen(document: document, start: {})
            .frame(width: 900, height: 560))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let data = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation ?? Data())?
            .representation(using: .png, properties: [:]))
        let destination = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ContactSheet/retro-title-recovery.png")
        try data.write(to: destination)
    }
}
