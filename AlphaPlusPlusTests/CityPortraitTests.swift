import XCTest
import SpriteKit
@testable import AlphaPlusPlus

/// **A photograph of a real city, at the two zooms it is actually played at.**
///
/// Not a contact sheet and not a fixture render: this opens one of the
/// `CityMinterTests` saves in a real `GameScene` on a real `SKView` — the same
/// path `GameScene.captureImage()` takes for Capture Screenshot — and
/// photographs it wide and close. It exists because this project is usually
/// driven over a remote session where `screencapture` and accessibility
/// scripting both fail, so a picture of the running game is otherwise not
/// obtainable at all.
///
/// Two things it has to do that a naive capture would not:
///
/// - **Call `update(_:)` after moving the camera.** Culling and the
///   `IsometricBuilding.Detail` tier both live there and both are driven off
///   the camera, so a capture that only sets a scale and shoots gets the far
///   textures at close range — a picture of a frame the game never draws.
/// - **Pump a few frames before shooting.** Traffic, trams and the contact
///   light are all built on the first `update`, and the emitters need a
///   moment. `SKAction`s still do not advance in a headless capture, which is
///   the standing limit recorded for the traffic render: a still cannot catch
///   a bus part-way along its route.
@MainActor
final class CityPortraitTests: XCTestCase {

    /// The window these are shot at. 16:10, and large enough that the close
    /// shot is worth looking at.
    private let frame = CGSize(width: 1600, height: 1000)

    private func portraitDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/Portraits")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Opens a saved city and hands back a scene already drawn.
    private func open(_ name: String) throws -> (GameScene, SKView, GameController) {
        let url = try CitySaveFile.defaultDirectory()
            .appendingPathComponent("\(name).alphacity")
        let save = try CitySaveFile.read(from: url)

        let controller = GameController(map: save.map,
                                        rng: SeededRNG(seed: 1),
                                        peakPopulation: Unlocks.everythingUnlocked)
        try controller.restore(from: save)

        let scene = GameScene(controller: controller)
        scene.size = frame
        let view = SKView(frame: NSRect(origin: .zero, size: frame))
        view.presentScene(scene)
        scene.rebuildEntireGrid()
        scene.refreshAll()
        return (scene, view, controller)
    }

    private func shoot(_ scene: GameScene, _ view: SKView, to url: URL) throws {
        // Frames, not one: the scene builds its traffic and its weather on
        // `update`, and the detail tier and the culling both decide there.
        for step in 0 ..< 4 { scene.update(TimeInterval(step) / 60) }
        let texture = try XCTUnwrap(
            view.texture(from: scene, crop: CGRect(origin: .zero, size: scene.size)),
            "the scene rendered nothing"
        )
        let bitmap = NSBitmapImageRep(cgImage: texture.cgImage())
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
        print("📸 \(url.lastPathComponent)")
    }

    /// Where the city is busiest, so the close shot lands on something worth
    /// looking at rather than on whatever happens to be at the middle.
    ///
    /// Density rather than population, and summed over a window rather than
    /// taken per lot, because the question is "where is the downtown" and one
    /// tall tower on its own is not one.
    private func busiestBlock(in map: CityMap) -> GridPosition {
        let radius = 4
        var best = GridPosition(x: map.width / 2, y: map.height / 2)
        var bestScore = -1
        for y in stride(from: radius, to: map.height - radius, by: 2) {
            for x in stride(from: radius, to: map.width - radius, by: 2) {
                var score = 0
                for dy in -radius ... radius {
                    for dx in -radius ... radius {
                        let tile = map[GridPosition(x: x + dx, y: y + dy)]
                        guard tile.zone == .residential || tile.zone == .commercial
                                || tile.zone == .industrial else { continue }
                        score += tile.density
                    }
                }
                if score > bestScore {
                    bestScore = score
                    best = GridPosition(x: x, y: y)
                }
            }
        }
        return best
    }

    func testPhotographTheCity() throws {
        let name = ProcessInfo.processInfo.environment["PORTRAIT_CITY"] ?? "Apex"

        // **Skipped when there is nothing to photograph**, rather than failing.
        // These read a city out of Application Support that `CityMinterTests`
        // writes, and that folder is empty on a fresh clone — so without this
        // the suite would fail for anyone who had not minted first, on a test
        // that is a camera rather than an assertion.
        let url = try CitySaveFile.defaultDirectory()
            .appendingPathComponent("\(name).alphacity")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "no \(name).alphacity — run CityMinterTests with TEST_RUNNER_MINT_CITIES=1 first"
        )

        let directory = try portraitDirectory()

        let (scene, view, controller) = try open(name)
        let map = controller.map

        let lots = map.tiles.filter { $0.isBuildingAnchor }.count
        let growable: Set<ZoneType> = [.residential, .commercial, .industrial]
        let built = map.tiles.filter {
            $0.isBuildingAnchor && growable.contains($0.zone) && $0.density > 0
        }
        let maxed = built.filter { $0.density >= 5 }.count
        let meanDensity = built.isEmpty ? 0
            : Double(built.reduce(0) { $0 + $1.density }) / Double(built.count)
        print("""

        === \(name) ===
        \(map.width)×\(map.height) · \(controller.population) residents · \(controller.jobs) jobs
        \(lots) buildings · \(built.count) growable, mean density \
        \(String(format: "%.2f", meanDensity)) · \(maxed) at maximum
        treasury $\(controller.treasury) · \(CalendarText.full(map.date))
        """)

        // **How much of the picture is ground, and what is on it.** The
        // buildings have had every pass; the surface they stand on has had
        // none, and it is not a small part of the frame.
        let all = map.tiles.count
        let roads = map.tiles.filter { $0.zone == .road || $0.zone == .highway }.count
        let bare = map.tiles.filter { $0.zone == .empty && !$0.isWater }.count
        print(String(format: "ground: %d road + %d bare of %d tiles (%.0f%% of the map)",
                     roads, bare, all, Double(roads + bare) * 100 / Double(all)))

        // **Wide.** `centerCameraOnMap` only sets the camera's *position* —
        // it says nothing about zoom, which is the trap `ScenePlaytest`'s
        // filmstrip already recorded: most of every frame came back empty
        // night. The scale has to be worked out from the ground diamond.
        scene.centerCameraOnMap()
        let content = scene.contentBoundsForTesting
        scene.setCameraScaleForTesting(
            max(content.width / frame.width, content.height / frame.height) * 1.04
        )
        try shoot(scene, view, to: directory.appendingPathComponent("\(name)-wide.png"))

        // **Close**, at the nearest camera the game allows, over the downtown.
        // This is where the near-detail tier engages, so it is also the only
        // picture in this project that shows what zooming in actually buys.
        let downtown = busiestBlock(in: map)
        scene.centerCameraForTesting(on: downtown)
        scene.setCameraScaleForTesting(0.5)
        try shoot(scene, view, to: directory.appendingPathComponent("\(name)-close.png"))

        XCTAssertEqual(scene.buildingDetailForTesting, .near,
                       "the close shot did not reach the near-detail tier")

        // The same frame with the post-process off, which is the only way to
        // tell a *drawing* problem from a *grading* one. Reported from play as
        // buildings looking translucent where they crowd together, and a
        // picture of the graded frame alone cannot say whether that is the
        // geometry or the shader on top of it.
        scene.setPostProcessEnabledForTesting(false)
        try shoot(scene, view, to: directory.appendingPathComponent("\(name)-close-raw.png"))
        scene.setPostProcessEnabledForTesting(true)
    }
}
