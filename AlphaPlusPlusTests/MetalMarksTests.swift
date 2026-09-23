import XCTest
import AppKit
@testable import AlphaPlusPlus

/// **M8: what SpriteKit drew over the Metal city, drawn by Metal**: the
/// cursor, the flashes and the route diagram. Each is checked on rendered
/// pixels, because a mark that is planned and never reaches the frame is the
/// failure this project keeps shipping.
final class MetalMarksTests: XCTestCase {

    private func apex() throws -> CityMap {
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "needs Apex")
        return try CitySaveFile.read(from: url).map
    }

    private func camera(_ map: CityMap) -> MetalCityRenderer.Camera {
        let bounds = Isometric().contentBounds(of: map)
        return .init(centre: CGPoint(x: bounds.midX, y: bounds.midY), scale: 0.9,
                     size: CGSize(width: 1200, height: 750))
    }

    private func bytes(_ frame: MetalCityRenderer.Frame?) throws -> [UInt8] {
        let data = try XCTUnwrap(try XCTUnwrap(frame).image.dataProvider?.data)
        return Array(UnsafeBufferPointer(start: CFDataGetBytePtr(data), count: CFDataGetLength(data)))
    }

    private func changed(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).filter { abs(Int($0) - Int($1)) > 8 }.count
    }

    /// The cursor reaches the frame, and a blocked one is drawn differently.
    func testTheCursorIsDrawn() throws {
        let map = try apex()
        let renderer = try XCTUnwrap(MetalCityRenderer())
        let centre = GridPosition(x: map.width / 2, y: map.height / 2)
        let bare = try bytes(renderer.render(map, camera: camera(map), wetness: 0, time: 1, motionClock: 1))
        renderer.cursor = .init(origin: centre, size: 2, blocked: false, kind: .tool)
        let clear = try bytes(renderer.render(map, camera: camera(map), wetness: 0, time: 1, motionClock: 1))
        renderer.cursor = .init(origin: centre, size: 2, blocked: true, kind: .tool)
        let blocked = try bytes(renderer.render(map, camera: camera(map), wetness: 0, time: 1, motionClock: 1))
        XCTAssertGreaterThan(changed(bare, clear), 400, "the cursor does not reach the frame")
        XCTAssertGreaterThan(changed(clear, blocked), 400, "a blocked cursor looks like a clear one")
    }

    /// A flash reaches the frame, and is gone once its time is up, on the
    /// wall clock: the motion clock is held still, as it is while paused.
    func testAFlashFadesOnTheWallClock() throws {
        let map = try apex()
        let renderer = try XCTUnwrap(MetalCityRenderer())
        let centre = GridPosition(x: map.width / 2, y: map.height / 2)
        let bare = try bytes(renderer.render(map, camera: camera(map), wetness: 0, time: 1, motionClock: 1))
        renderer.flash(.init(origin: centre, size: 2, kind: .blocked))
        let lit = try bytes(renderer.render(map, camera: camera(map), wetness: 0, time: 1, motionClock: 1))
        XCTAssertGreaterThan(changed(bare, lit), 400, "the flash does not reach the frame")
        _ = try bytes(renderer.render(map, camera: camera(map), wetness: 0, time: 1.2, motionClock: 1))
        XCTAssertFalse(renderer.flashesForTesting.isEmpty, "the flash ended before its time")
        let after = try bytes(renderer.render(map, camera: camera(map), wetness: 0, time: 1.5, motionClock: 1))
        XCTAssertTrue(renderer.flashesForTesting.isEmpty, "the flash never ended")
        XCTAssertLessThan(changed(bare, after), 50, "the flash left a mark behind")
    }

    /// The route diagram is drawn in its own view and nowhere else, and it
    /// is a picture worth keeping: written to `metal-marks.png`.
    func testTheRouteDiagramIsDrawnInItsOwnView() throws {
        let map = try apex()
        XCTAssertFalse(map.transit.routes(mode: .subway).isEmpty, "the fixture has no subway to draw")
        let renderer = try XCTUnwrap(MetalCityRenderer())
        renderer.overlayMode = .subway
        let camera = camera(map)
        let withLines = try XCTUnwrap(renderer.render(map, camera: camera, wetness: 0, time: 1, motionClock: 1))
        // The same view with the lines gone: only the diagram differs.
        var bare = map
        for route in bare.transit.routes(mode: .subway) { bare.transit.remove(id: route.id) }
        let without = try XCTUnwrap(MetalCityRenderer())
        without.overlayMode = .subway
        let withoutLines = try XCTUnwrap(without.render(bare, camera: camera, wetness: 0, time: 1, motionClock: 1))
        XCTAssertGreaterThan(changed(try bytes(withLines), try bytes(withoutLines)), 2_000,
                             "the subway lines do not reach the frame")

        renderer.cursor = .init(origin: GridPosition(x: map.width / 2, y: map.height / 2), size: 2,
                                blocked: false, kind: .tool)
        renderer.flash(.init(origin: GridPosition(x: map.width / 2 + 4, y: map.height / 2), size: 2,
                             kind: .hazard(.fireStation)))
        let picture = try XCTUnwrap(renderer.render(map, camera: camera, wetness: 0, time: 1, motionClock: 1))
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ContactSheet")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try NSBitmapImageRep(cgImage: picture.image).representation(using: .png, properties: [:])?
            .write(to: url.appendingPathComponent("metal-marks.png"))
    }
}
