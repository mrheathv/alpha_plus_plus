import AppKit
import XCTest
@testable import AlphaPlusPlus

/// **M6: the look, judged across the whole zoom range.**
///
/// Every render in this project that tuned something at one zoom tuned it at
/// exactly one zoom — the bloom's reach drifted 2.3× across the range before
/// anybody measured it. So the look is reviewed as a grid: the closest camera,
/// the resting one and the widest, dry and in rain, on the densest city and on
/// the river city. A change that improves one cell and ruins another shows up
/// here as that.
///
/// Scales are per *pixel* on a 2× display: the game's 0.5 / 1.0 / 3.0 camera
/// becomes 0.25 / 0.5 / 1.5 here.
///
/// ```sh
/// xcodebuild -project AlphaPlusPlus.xcodeproj -scheme AlphaPlusPlus -testPlan Full \
///            -configuration Release -derivedDataPath ./build ENABLE_TESTABILITY=YES \
///            test -only-testing:AlphaPlusPlusTests/MetalLookTests
/// open ./build/ContactSheet/metal-look.png
/// ```
@MainActor
final class MetalLookTests: XCTestCase {

    static let zooms: [(String, CGFloat)] = [("closest", 0.25), ("resting", 0.5), ("widest", 1.5)]

    func testRenderTheLook() throws {
        let size = CGSize(width: 1200, height: 750)
        var frames: [(String, NSImage)] = []

        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        if FileManager.default.fileExists(atPath: url.path) {
            let apex = try CitySaveFile.read(from: url).map
            let renderer = try XCTUnwrap(MetalCityRenderer())
            let bounds = Isometric().contentBounds(of: apex)
            let middle = CGPoint(x: bounds.midX, y: bounds.midY)
            let street = MetalMotionTests.centre(MetalMotionTests.exposedBusiestStreet(in: apex))
            for (label, scale) in Self.zooms {
                for (weather, wet) in [("dry", Float(0)), ("rain", Float(1))] {
                    let centre = scale < 1 ? street : middle
                    let camera = MetalCityRenderer.Camera(centre: centre, scale: scale, size: size)
                    let frame = try XCTUnwrap(renderer.render(apex, camera: camera, wetness: wet, time: 2,
                                                              motionClock: 1.3, rainfall: wet * 0.7))
                    frames.append(("Apex · \(label) · \(weather)", NSImage(cgImage: frame.image, size: size)))
                }
            }
        }

        let river = MetalMotionTests.tickedCity()
        let renderer = try XCTUnwrap(MetalCityRenderer())
        for (label, scale, x, y) in [("closest", CGFloat(0.25), CGFloat(11), CGFloat(13)),
                                     ("resting", 0.5, 14, 12)] {
            for (weather, wet) in [("dry", Float(0)), ("rain", Float(1))] {
                let camera = MetalCityRenderer.Camera(centre: Isometric().project(x, y, 0), scale: scale, size: size)
                let frame = try XCTUnwrap(renderer.render(river, camera: camera, wetness: wet, time: 2,
                                                          motionClock: 1.3, rainfall: wet * 0.7))
                frames.append(("River city · \(label) · \(weather)", NSImage(cgImage: frame.image, size: size)))
            }
        }
        let name = ProcessInfo.processInfo.environment["LOOK_NAME"] ?? "metal-look"
        try MetalSpikeTests.writeGrid(frames, columns: 2, cell: size, named: name)
    }

    /// **Classic and Cinematic carried across, and the switch does something.**
    /// This project has twice shipped a control that compiled and changed
    /// nothing, so the assertion is on the frame, not on the setting.
    func testTheStyleSwitchChangesTheMetalFrame() throws {
        let map = MetalMotionTests.tickedCity()
        let renderer = try XCTUnwrap(MetalCityRenderer())
        let camera = MetalCityRenderer.Camera(centre: Isometric().project(14, 10, 0), scale: 0.6,
                                              size: CGSize(width: 800, height: 500))
        let was = VisualStyle.current
        defer { VisualStyle.current = was }
        VisualStyle.current = .cinematic
        let cinematic = MetalMotionTests.bytes(try XCTUnwrap(renderer.render(map, camera: camera, wetness: 0, time: 1)).image)
        VisualStyle.current = .classic
        let classic = MetalMotionTests.bytes(try XCTUnwrap(renderer.render(map, camera: camera, wetness: 0, time: 1)).image)
        XCTAssertGreaterThan(MetalMotionTests.changed(cinematic, classic), 0.2,
                             "switching Classic and Cinematic barely changed the Metal frame")
        XCTAssertEqual(MetalCityRenderer.CompositeSettings.for(.classic).bloomStrength, 0)
    }

    func testRenderBothStyles() throws {
        let map = MetalMotionTests.tickedCity()
        let renderer = try XCTUnwrap(MetalCityRenderer())
        let size = CGSize(width: 1000, height: 640)
        let camera = MetalCityRenderer.Camera(centre: Isometric().project(14, 10, 0), scale: 0.6, size: size)
        let was = VisualStyle.current
        defer { VisualStyle.current = was }
        var frames: [(String, NSImage)] = []
        for style in VisualStyle.allCases {
            VisualStyle.current = style
            let frame = try XCTUnwrap(renderer.render(map, camera: camera, wetness: 0.5, time: 1))
            frames.append((style.displayName, NSImage(cgImage: frame.image, size: size)))
        }
        try MetalSpikeTests.writeGrid(frames, columns: 2, cell: size, named: "metal-styles")
    }

    /// **Crossing into close-up detail must not hitch.** Every visible chunk
    /// asks for building variants that may never have been built — the work
    /// SpriteKit measured as a 49 ms frame before it spread it. Measured here
    /// as the worst single frame of the swap on the densest city, with the
    /// live budget of four chunks a frame.
    func testCrossingIntoCloseDetailDoesNotHitch() throws {
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "needs Apex")
        let map = try CitySaveFile.read(from: url).map
        let renderer = try XCTUnwrap(MetalCityRenderer())
        renderer.update(map, revision: nil)
        let bounds = Isometric().contentBounds(of: map)
        let close = MetalCityRenderer.Camera(centre: CGPoint(x: bounds.midX, y: bounds.midY), scale: 0.25,
                                             size: CGSize(width: 2880, height: 1800))
        // Twenty frames at four chunks each covers all 64 of a 64×64 city.
        var worst = 0.0
        let frames = 20
        for _ in 0 ..< frames {
            let start = DispatchTime.now().uptimeNanoseconds
            renderer.settleDetail(for: close, budget: 4)
            worst = max(worst, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        XCTAssertTrue(renderer.nearDetail)
        print(String(format: "🟪 close-detail swap on Apex: worst frame %.1f ms over %d frames", worst, frames))
        XCTAssertLessThan(worst, 12, "crossing into close-up detail hitches a frame")
    }

    /// **Mood frames: the candidate looks side by side**, so a direction is
    /// picked from pictures rather than argued. One row per look: Apex at rest,
    /// Apex from the widest camera, and the river city close in light rain.
    func testRenderTheMoodFrames() throws {
        let size = CGSize(width: 1000, height: 625)
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "needs Apex")
        let apex = try CitySaveFile.read(from: url).map
        let river = MetalMotionTests.tickedCity()
        let apexRenderer = try XCTUnwrap(MetalCityRenderer())
        let riverRenderer = try XCTUnwrap(MetalCityRenderer())
        let bounds = Isometric().contentBounds(of: apex)
        let street = MetalMotionTests.centre(MetalMotionTests.exposedBusiestStreet(in: apex))
        var frames: [(String, NSImage)] = []
        for look in MetalCityRenderer.Look.candidates {
            apexRenderer.look = look
            riverRenderer.look = look
            let shots: [(String, MetalCityRenderer, CityMap, CGPoint, CGFloat, Float)] = [
                ("resting", apexRenderer, apex, street, 0.5, 0),
                ("widest", apexRenderer, apex, CGPoint(x: bounds.midX, y: bounds.midY), 1.5, 0),
                ("close, light rain", riverRenderer, river, Isometric().project(12, 12, 0), 0.3, 0.5),
            ]
            for (label, renderer, map, centre, scale, rain) in shots {
                let camera = MetalCityRenderer.Camera(centre: centre, scale: scale * 1.2, size: size)
                let frame = try XCTUnwrap(renderer.render(map, camera: camera, wetness: rain, time: 2,
                                                          motionClock: 1.3, rainfall: rain * 0.6))
                frames.append(("\(look.name) · \(label)", NSImage(cgImage: frame.image, size: size)))
            }
        }
        try MetalSpikeTests.writeGrid(frames, columns: 3, cell: size, named: "metal-mood-frames")
    }

    /// **The sky and the sun**, seen the way a player finds them: looking
    /// toward the back of the map, pulled out and then closer.
    func testRenderTheSky() throws {
        let size = CGSize(width: 1400, height: 875)
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "needs Apex")
        let apex = try CitySaveFile.read(from: url).map
        let renderer = try XCTUnwrap(MetalCityRenderer())
        var frames: [(String, NSImage)] = []
        // Cameras at the edge the game's clamp allows: two tiles past the far
        // corner, which is as far toward the sky as a player can look.
        for (label, x, y, scale) in [("the whole city, pulled out", CGFloat(20), CGFloat(20), CGFloat(1.5)),
                                     ("at the far edge, pulled out", -1, -1, 1.5),
                                     ("at the far edge, resting", -1, -1, 0.5)] {
            let camera = MetalCityRenderer.Camera(centre: Isometric().project(x, y, 0), scale: scale, size: size)
            let frame = try XCTUnwrap(renderer.render(apex, camera: camera, wetness: 0, time: 2))
            frames.append((label, NSImage(cgImage: frame.image, size: size)))
        }
        try MetalSpikeTests.writeGrid(frames, columns: 1, cell: size, named: "metal-sky")
    }

    /// **The readable-skyline instrument** (retrowave step 2): the player's
    /// own city — the autosave, a city a person built — beside Apex, which a
    /// generator laid out on a regular grid, each from the widest camera and
    /// at rest. Repetition is judged on both, because some of Apex's is its
    /// layout rather than its buildings. `LOOK_NAME` keeps a before.
    func testRenderTheSkyline() throws {
        let size = CGSize(width: 1400, height: 875)
        var cities: [(String, CityMap)] = []
        if let autosave = CityAutosave.standard(), autosave.available != nil {
            cities.append(("your city", try autosave.read().map))
        }
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        if FileManager.default.fileExists(atPath: url.path) {
            cities.append(("Apex", try CitySaveFile.read(from: url).map))
        }
        try XCTSkipIf(cities.isEmpty, "no city to look at")
        var frames: [(String, NSImage)] = []
        for (name, map) in cities {
            let renderer = try XCTUnwrap(MetalCityRenderer())
            let bounds = Isometric().contentBounds(of: map)
            let middle = CGPoint(x: bounds.midX, y: bounds.midY)
            let street = MetalMotionTests.centre(MetalMotionTests.exposedBusiestStreet(in: map))
            for (label, centre, scale) in [("widest", middle, CGFloat(1.5)), ("resting", street, 0.5)] {
                let camera = MetalCityRenderer.Camera(centre: centre, scale: scale, size: size)
                let frame = try XCTUnwrap(renderer.render(map, camera: camera, wetness: 0, time: 2))
                frames.append(("\(name) · \(label)", NSImage(cgImage: frame.image, size: size)))
            }
        }
        let name = ProcessInfo.processInfo.environment["LOOK_NAME"] ?? "metal-skyline"
        try MetalSpikeTests.writeGrid(frames, columns: 2, cell: size, named: name)
    }

    /// **The icons in a real downtown**, through the renderer the game draws
    /// with: Apex with all five placed over lots near its middle, at rest and
    /// from the widest camera. An icon is only special against what stands
    /// around it, so a sheet of them alone cannot answer whether they read.
    func testRenderTheIconsDowntown() throws {
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "needs Apex")
        var map = try CitySaveFile.read(from: url).map
        let middle = GridPosition(x: map.width / 2, y: map.height / 2)
        // Ordinary 2×2 lots near the middle, spread so no two icons touch.
        var spots: [GridPosition] = []
        let lots = map.tiles
            .filter { $0.isBuildingAnchor && $0.zone.maxDensity > 0 && $0.zone.footprintSize == 2 }
            .map(\.position)
            .sorted { abs($0.x - middle.x) + abs($0.y - middle.y) < abs($1.x - middle.x) + abs($1.y - middle.y) }
        for lot in lots where spots.allSatisfy({ abs($0.x - lot.x) + abs($0.y - lot.y) >= 6 }) {
            spots.append(lot)
            if spots.count == IconBuildings.all.count { break }
        }
        XCTAssertEqual(spots.count, IconBuildings.all.count)
        for (icon, spot) in zip(IconBuildings.all, spots) { map.placeBuilding(zone: icon, origin: spot) }

        let size = CGSize(width: 1400, height: 875)
        let renderer = try XCTUnwrap(MetalCityRenderer())
        let centre = spots.map(MetalMotionTests.centre).reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x / CGFloat(spots.count), y: $0.y + $1.y / CGFloat(spots.count))
        }
        var frames: [(String, NSImage)] = []
        for (label, scale) in [("resting", CGFloat(0.6)), ("widest", 1.5)] {
            let camera = MetalCityRenderer.Camera(centre: CGPoint(x: centre.x, y: centre.y + 120 * scale),
                                                  scale: scale, size: size)
            let frame = try XCTUnwrap(renderer.render(map, camera: camera, wetness: 0, time: 2))
            frames.append(("icons downtown · \(label)", NSImage(cgImage: frame.image, size: size)))
        }
        try MetalSpikeTests.writeGrid(frames, columns: 2, cell: size, named: "metal-icons")
    }

    /// **The low end in the renderer the game draws with**: a small town of
    /// tier-1 and tier-2 housing, shops and industry on a street grid, at
    /// rest and closer in. Most of a city looks like this for the first hour,
    /// so it is judged here rather than only on a contact sheet.
    func testRenderTheSuburb() throws {
        var map = CityMap(width: 20, height: 20)
        for i in 0 ..< 20 {
            for road in [0, 5, 10, 15] {
                map.placeBuilding(zone: .road, origin: GridPosition(x: road, y: i))
                map.placeBuilding(zone: .road, origin: GridPosition(x: i, y: road))
            }
        }
        var index = 0
        for bx in [1, 6, 11, 16] {
            for by in [1, 6, 11, 16] {
                for (dx, dy) in [(0, 0), (2, 0), (0, 2), (2, 2)] {
                    let origin = GridPosition(x: bx + dx, y: by + dy)
                    guard origin.x + 1 < 20, origin.y + 1 < 20 else { continue }
                    let zone: ZoneType = by >= 16 ? .industrial : (bx >= 11 ? .commercial : .residential)
                    map.placeBuilding(zone: zone, origin: origin)
                    map[origin].density = [1, 2, 3, 1, 2][index % 5]
                    index += 1
                }
            }
        }
        let size = CGSize(width: 1400, height: 875)
        let renderer = try XCTUnwrap(MetalCityRenderer())
        let bounds = Isometric().contentBounds(of: map)
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        var frames: [(String, NSImage)] = []
        for (label, scale) in [("resting", CGFloat(0.5)), ("close", 0.3)] {
            let camera = MetalCityRenderer.Camera(centre: middle, scale: scale, size: size)
            let frame = try XCTUnwrap(renderer.render(map, camera: camera, wetness: 0, time: 2))
            frames.append(("suburb · \(label)", NSImage(cgImage: frame.image, size: size)))
        }
        try MetalSpikeTests.writeGrid(frames, columns: 2, cell: size, named: "metal-suburb")
    }
}
