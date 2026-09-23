import XCTest
import AppKit
@testable import AlphaPlusPlus

/// **A photograph of a real city, at the two zooms it is actually played at.**
///
/// Not a contact sheet and not a fixture render: this opens one of the
/// `CityMinterTests` saves and photographs it wide and close through
/// `MetalCityRenderer.render`, the renderer the game draws with (M8). It
/// exists because this project is usually driven over a remote session where
/// `screencapture` and accessibility scripting both fail, so a picture of the
/// running game is otherwise not obtainable at all.
///
/// `render` settles the detail tier for the camera before drawing, which is
/// what the SpriteKit version had to remember to pump `update` for. Moving
/// things are drawn where the motion clock puts them at `time`, so a still
/// can catch a bus part-way along its route now.
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

    /// Opens a saved city.
    private func open(_ name: String) throws -> GameController {
        let url = try CitySaveFile.defaultDirectory()
            .appendingPathComponent("\(name).alphacity")
        let save = try CitySaveFile.read(from: url)
        let controller = GameController(map: save.map,
                                        rng: SeededRNG(seed: 1),
                                        peakPopulation: Unlocks.everythingUnlocked)
        try controller.restore(from: save)
        return controller
    }

    /// One frame through the Metal renderer the game draws with, at
    /// `scale` points per pixel. `render` settles the detail tier for the
    /// camera before it draws, so the close shot is the frame a player sees
    /// there rather than the far tier caught mid-swap.
    private func shoot(_ map: CityMap, with renderer: MetalCityRenderer, centre: CGPoint,
                       scale: CGFloat, to url: URL) throws {
        let camera = MetalCityRenderer.Camera(centre: centre, scale: scale, size: frame)
        let image = try XCTUnwrap(renderer.render(map, camera: camera, wetness: 0, time: 2)?.image,
                                  "the city rendered nothing")
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: url)
        print("📸 \(url.lastPathComponent)")
    }

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

        let controller = try open(name)
        let map = controller.map
        let renderer = try XCTUnwrap(MetalCityRenderer(), "no Metal device")

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

        // **Wide**, framed on the ground diamond: the whole city in shot.
        let projection = Isometric()
        let content = projection.contentBounds(of: map)
        try shoot(map, with: renderer, centre: CGPoint(x: content.midX, y: content.midY),
                  scale: max(content.width / frame.width, content.height / frame.height) * 1.04,
                  to: directory.appendingPathComponent("\(name)-wide.png"))

        // **Close**, over the downtown, at the camera where the near detail
        // tier draws (0.3 points a pixel in the renderer's units).
        let downtown = busiestBlock(in: map)
        try shoot(map, with: renderer,
                  centre: projection.project(CGFloat(downtown.x), CGFloat(downtown.y), 1.5), scale: 0.3,
                  to: directory.appendingPathComponent("\(name)-close.png"))
    }
}
