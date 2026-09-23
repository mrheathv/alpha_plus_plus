import XCTest
@testable import AlphaPlusPlus

/// **The closer camera, and the street tier it opens.** Metal may zoom about
/// two and a half times nearer than SpriteKit, and past `streetEngages` it
/// draws road markings, framed windows and cars on wheels.
@MainActor
final class StreetLevelTests: XCTestCase {

    /// What the Metal renderer's camera scale is at the closest zoom a player
    /// can reach, on a 2× Retina panel.
    static let closest = GameScene.metalMinimumZoomScale / 2

    func testTheStreetTierEngagesAtTheClosestCameraAndNotAtRest() throws {
        let renderer = try XCTUnwrap(MetalCityRenderer())
        let map = MetalMotionTests.tickedCity()
        let size = CGSize(width: 800, height: 500)
        let centre = Isometric().project(14, 12, 0)
        _ = renderer.render(map, camera: .init(centre: centre, scale: 0.25, size: size), wetness: 0)
        XCTAssertFalse(renderer.streetDetail, "street marks at the old closest camera")
        _ = renderer.render(map, camera: .init(centre: centre, scale: Self.closest, size: size), wetness: 0)
        XCTAssertTrue(renderer.streetDetail, "no street marks at the new closest camera")
    }

    /// Street marks are more triangles, but only where they are drawn: at rest
    /// the city is exactly what it was.
    func testTheStreetTierAddsDetailOnlyWhenClose() throws {
        let map = MetalMotionTests.tickedCity()
        let near = MetalCityMesh.build(map, near: true)
        let street = MetalCityMesh.build(map, near: true, street: true)
        XCTAssertGreaterThan(street.vertices.count, near.vertices.count, "the street tier adds nothing")
    }

    func testRenderStreetLevel() throws {
        let size = CGSize(width: 1200, height: 750)
        var frames: [(String, NSImage)] = []
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        if FileManager.default.fileExists(atPath: url.path) {
            let apex = try CitySaveFile.read(from: url).map
            let renderer = try XCTUnwrap(MetalCityRenderer())
            let street = MetalMotionTests.centre(MetalMotionTests.exposedBusiestStreet(in: apex))
            for (label, scale, wet) in [("Apex · old closest (0.25)", CGFloat(0.25), Float(0)),
                                        ("Apex · new closest, street tier", Self.closest, Float(0)),
                                        ("Apex · new closest, rain", Self.closest, Float(1))] {
                let frame = try XCTUnwrap(renderer.render(apex, camera: .init(centre: street, scale: scale, size: size),
                                                          wetness: wet, time: 2, motionClock: 1.3,
                                                          rainfall: wet * 0.7))
                frames.append((label, NSImage(cgImage: frame.image, size: size)))
            }
        }
        let river = MetalMotionTests.tickedCity()
        let renderer = try XCTUnwrap(MetalCityRenderer())
        let frame = try XCTUnwrap(renderer.render(river, camera: .init(centre: Isometric().project(11, 13, 0),
                                                                       scale: Self.closest, size: size),
                                                  wetness: 0, time: 2, motionClock: 1.3))
        frames.append(("River city · new closest, street tier", NSImage(cgImage: frame.image, size: size)))
        try MetalSpikeTests.writeGrid(frames, columns: 2, cell: size, named: "street-level")
    }
}
