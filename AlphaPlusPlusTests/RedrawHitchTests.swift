import XCTest
@testable import AlphaPlusPlus

/// **Why the screen stops when a building upgrades** — reported from play.
///
/// Opt-in, a readout for diagnosis rather than a check. For each day it times
/// the three things that land on the frame a building changes level, one at a
/// time, so the report names the culprit instead of a total:
///
/// - the simulation tick (`GameController.advanceSimulation`),
/// - the Metal renderer catching up (`update`: chunk rebuilds, and massing
///   generated for any variant not seen before),
/// - drawing the frame after it.
///
/// Three cities, because an upgrade means different things in each: the
/// player's own growing city, a large city in its first months (when most of
/// its lots are climbing), and Apex, which is settled.
@MainActor
final class RedrawHitchTests: XCTestCase {

    private struct Day {
        var tick = 0.0, update = 0.0, render = 0.0
        var chunks = 0, newShapes = 0, levelChanges = 0
    }

    private func measure(_ name: String, map: CityMap, days: Int) throws -> String {
        let controller = GameController(map: map, rng: SeededRNG(seed: 1),
                                        peakPopulation: Unlocks.everythingUnlocked)
        let renderer = try XCTUnwrap(MetalCityRenderer())
        let bounds = Isometric().contentBounds(of: map)
        let camera = MetalCityRenderer.Camera(centre: CGPoint(x: bounds.midX, y: bounds.midY),
                                              scale: 0.5, size: CGSize(width: 2880, height: 1800))
        func ms(_ work: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            work()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }
        // Warm: the first build of every chunk is a load, not an upgrade.
        for _ in 0 ..< 10 { _ = renderer.render(controller.map, camera: camera, wetness: 0) }

        var record: [Day] = []
        for _ in 0 ..< days {
            var day = Day()
            let before = controller.map.tiles.map(\.density)
            day.tick = ms { controller.advanceSimulation() }
            day.levelChanges = zip(before, controller.map.tiles.map(\.density)).filter { $0 != $1 }.count
            let shapes = renderer.cachedBuildingCount
            day.update = ms { renderer.update(controller.map, revision: nil) }
            day.chunks = renderer.chunksRebuiltLastUpdate
            day.newShapes = renderer.cachedBuildingCount - shapes
            day.render = renderer.render(controller.map, camera: camera, wetness: 0)?.gpuMilliseconds ?? 0
            record.append(day)
        }
        func stats(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return String(format: "median %6.2f  max %7.2f", sorted[sorted.count / 2], sorted.last ?? 0)
        }
        let worst = record.max { $0.tick + $0.update < $1.tick + $1.update }!
        var report = "\(name) (\(map.width)×\(map.height), \(days) days)\n"
        report += "  tick     \(stats(record.map(\.tick)))\n"
        report += "  update   \(stats(record.map(\.update)))\n"
        report += "  gpu      \(stats(record.map(\.render)))\n"
        report += String(format: "  worst day: tick %.1f + update %.1f ms · %d chunks · %d new shapes · %d tiles changed level\n",
                         worst.tick, worst.update, worst.chunks, worst.newShapes, worst.levelChanges)
        let withNew = record.filter { $0.newShapes > 0 }, without = record.filter { $0.newShapes == 0 && $0.chunks > 0 }
        if !withNew.isEmpty {
            report += String(format: "  update on days with new shapes: mean %.2f ms (%d days, %.1f shapes each)\n",
                             withNew.map(\.update).reduce(0, +) / Double(withNew.count), withNew.count,
                             Double(withNew.map(\.newShapes).reduce(0, +)) / Double(withNew.count))
        }
        if !without.isEmpty {
            report += String(format: "  update on days rebuilding cached shapes only: mean %.2f ms (%d days, %.1f chunks each)\n",
                             without.map(\.update).reduce(0, +) / Double(without.count), without.count,
                             Double(without.map(\.chunks).reduce(0, +)) / Double(without.count))
        }
        return report
    }

    func testWhatAnUpgradeCostsAFrame() throws {
        try XCTSkipUnless(TestReports.enabled, TestReports.skipReason)
        #if DEBUG
        var report = "configuration: Debug\n\n"
        #else
        var report = "configuration: Release\n\n"
        #endif
        if let autosave = CityAutosave.standard(), autosave.available != nil {
            report += try measure("your autosave", map: autosave.read().map, days: 60) + "\n"
        }
        var growing = PlaytestHarness.CitySpec(size: MapSize.large.dimension)
        growing.segregateIndustry = true
        growing.transitStations = .subway
        growing.drawTransitRoutes = true
        report += try measure("a large city in its first months", map: PlaytestHarness.buildCity(growing), days: 60) + "\n"
        let apex = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        if FileManager.default.fileExists(atPath: apex.path) {
            report += try measure("Apex, settled", map: CitySaveFile.read(from: apex).map, days: 30)
        }
        print(report)
        try report.write(to: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/ContactSheet/redraw-hitch.txt"),
                         atomically: true, encoding: .utf8)
    }
}
