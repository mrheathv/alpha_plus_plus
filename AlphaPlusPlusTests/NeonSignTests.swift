import XCTest
@testable import AlphaPlusPlus

/// **Neon signs.** The atlas holds every word, signs land on the lots that
/// should carry them and not the rest, and a render shows how they read.
@MainActor
final class NeonSignTests: XCTestCase {

    func testEveryWordFitsItsCell() {
        let image = MetalSigns.atlas()
        XCTAssertEqual(image?.width, MetalSigns.atlasWidth)
        XCTAssertEqual(image?.height, MetalSigns.atlasHeight)
    }

    /// A sign is an event: some shops carry one, bare ground and industry
    /// never do.
    func testSignsLandOnShopsAndNotOnIndustry() {
        var shops = 0, signed = 0
        for x in 0 ..< 40 {
            let position = GridPosition(x: x * 3, y: x * 5)
            let shape = MetalSigns.Shape(top: 2.5, roofZ: 2.3, roof: (x0: 0.4, y0: 0.4, x1: 1.6, y1: 1.6),
                                         frontX: 1.9, frontY: 1.9, midX: 1.7)
            let shop = Tile(position: position, zone: .commercial, density: 4)
            let factory = Tile(position: position, zone: .industrial, density: 4)
            shops += 1
            if !MetalSigns.plan(for: shop, shape: shape).letters.isEmpty { signed += 1 }
            XCTAssertTrue(MetalSigns.plan(for: factory, shape: shape).letters.isEmpty)
        }
        XCTAssertGreaterThan(signed, shops / 4, "almost no shop carries a sign")
        XCTAssertLessThan(signed, shops, "every shop carries a sign — then none of them is an event")
    }

    /// Signs have to reach the picture: the same frame with and without them
    /// must differ. The first render drew 67 planned signs as nothing at all.
    func testSignsChangeTheFrame() throws {
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "needs Apex")
        let map = try CitySaveFile.read(from: url).map
        let bounds = Isometric().contentBounds(of: map)
        let camera = MetalCityRenderer.Camera(centre: CGPoint(x: bounds.midX, y: bounds.midY), scale: 1.2,
                                              size: CGSize(width: 1200, height: 750))
        func pixels(signs: Bool) throws -> [UInt8] {
            MetalSigns.enabled = signs
            defer { MetalSigns.enabled = true }
            let renderer = try XCTUnwrap(MetalCityRenderer())
            let image = try XCTUnwrap(renderer.render(map, camera: camera, wetness: 0, time: 2, motionClock: 1.3)).image
            let data = try XCTUnwrap(image.dataProvider?.data)
            return Array(UnsafeBufferPointer(start: CFDataGetBytePtr(data), count: CFDataGetLength(data)))
        }
        let with = try pixels(signs: true), without = try pixels(signs: false)
        let changed = zip(with, without).filter { abs(Int($0) - Int($1)) > 8 }.count
        print("signs changed \(changed) of \(with.count) bytes")
        // Where they are: the frame with signs, and changed pixels lit green.
        var marked = with
        for i in stride(from: 0, to: marked.count - 3, by: 4) where
            (0 ..< 3).contains(where: { abs(Int(with[i + $0]) - Int(without[i + $0])) > 8 }) {
            marked[i] = 0; marked[i + 1] = 255; marked[i + 2] = 0
        }
        let provider = CGDataProvider(data: Data(marked) as CFData)!
        if let image = CGImage(width: 1200, height: 750, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4800,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("build/ContactSheet/neon-signs-where.png")
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        }
        XCTAssertGreaterThan(changed, with.count / 1000, "signs are planned but do not reach the frame")
    }

    func testRenderTheSigns() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ContactSheet")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let atlas = MetalSigns.atlas() {
            let rep = NSBitmapImageRep(cgImage: atlas)
            try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("sign-atlas.png"))
        }
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "needs Apex")
        let map = try CitySaveFile.read(from: url).map
        let renderer = try XCTUnwrap(MetalCityRenderer())
        XCTAssertTrue(renderer.hasSignAtlas, "the sign lettering did not load, so no sign can draw")
        renderer.update(map, revision: nil)
        let signCount = renderer.chunksForTesting().reduce(0) { $0 + $1.signs.count } / MetalSigns.floatCount
        print("Apex carries \(signCount) signs")
        XCTAssertGreaterThan(signCount, 20, "Apex has almost no signs")
        let size = CGSize(width: 1200, height: 750)
        // Aimed at a sign that exists, rather than at a district that might
        // not carry any: the first render looked at the factories.
        let all = renderer.chunksForTesting().flatMap(\.signs)
        // A rooftop billboard: high up, and wider than it is tall.
        let starts = Array(stride(from: 0, to: all.count, by: MetalSigns.floatCount))
        let pick: Int = starts.first(where: { all[$0 + 2] > 1.5 && abs(all[$0 + 4]) + abs(all[$0 + 5]) > 0.9 })
            ?? 0
        let target = GridPosition(x: Int(all[pick]), y: Int(all[pick + 1]))
        print("aimed at the sign at \(target), z \(all[pick + 2])")
        var frames: [(String, NSImage)] = []
        for (label, scale, wet) in [("resting", 0.5, Float(0)), ("closer", 0.3, Float(0)),
                                    ("closer, wet", 0.3, Float(1)), ("whole city", 2.4, Float(0))]
            as [(String, CGFloat, Float)] {
            let centre = label == "whole city"
                ? CGPoint(x: Isometric().contentBounds(of: map).midX, y: Isometric().contentBounds(of: map).midY)
                : Isometric().project(CGFloat(target.x), CGFloat(target.y), CGFloat(all[pick + 2]))
            let camera = MetalCityRenderer.Camera(centre: centre, scale: scale, size: size)
            let frame = try XCTUnwrap(renderer.render(map, camera: camera, wetness: wet, time: 2, motionClock: 1.3))
            frames.append((label, NSImage(cgImage: frame.image, size: size)))
        }
        try MetalSpikeTests.writeGrid(frames, columns: 2, cell: size, named: "neon-signs")
    }
}
