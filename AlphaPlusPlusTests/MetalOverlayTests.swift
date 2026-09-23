import AppKit
import SpriteKit
import XCTest
import simd
@testable import AlphaPlusPlus

/// **M4: what the map tells you, on the Metal renderer.**
///
/// The plan's bar: every view has a render, and the colour-accessibility
/// tests pass against the Metal palette. The second half is measured on
/// *rendered pixels*, not on palette entries — a lit renderer changes what a
/// colour looks like, and the question is what the player's eye receives.
///
/// ```sh
/// xcodebuild -project AlphaPlusPlus.xcodeproj -scheme AlphaPlusPlus -testPlan Full \
///            -configuration Release -derivedDataPath ./build ENABLE_TESTABILITY=YES \
///            test -only-testing:AlphaPlusPlusTests/MetalOverlayTests
/// open ./build/ContactSheet/metal-overlays.png
/// ```
@MainActor
final class MetalOverlayTests: XCTestCase {

    /// Three blocks in the three states a utility view has to tell apart:
    /// served, wanting and not needing anything yet — for water *and* power,
    /// the same fixture `ColourAccessibilityTests` uses on SpriteKit.
    ///
    /// With `leftDry`, the left block is also out of reach of any water, so
    /// the Water view has its own "wanting" state to show.
    static func utilityBlocks(leftDry: Bool = false) -> CityMap {
        var map = CityMap(width: 18, height: 18)
        for x in 0 ..< 18 { map[GridPosition(x: x, y: 7)].zone = .road }
        for origin in [GridPosition(x: 2, y: 8), GridPosition(x: 10, y: 8)] {
            map.placeBuilding(zone: .residential, origin: origin)
            for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = 5 }
        }
        // Too small to want either utility: the "not applicable" answer.
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 6, y: 4))
        for cell in map.footprintCells(origin: GridPosition(x: 6, y: 4), size: 2) { map[cell].density = 1 }
        for y in 0 ..< 7 { map[GridPosition(x: 5, y: y)].zone = .road }
        if leftDry {
            // Two, as on the other side: one pump's capacity is less than
            // the city's demand, and an overloaded network serves nobody.
            map.placeBuilding(zone: .waterPump, origin: GridPosition(x: 12, y: 10))
            map.placeBuilding(zone: .waterPump, origin: GridPosition(x: 13, y: 10))
        } else {
            map.placeBuilding(zone: .waterPump, origin: GridPosition(x: 5, y: 9))
            map.placeBuilding(zone: .waterPump, origin: GridPosition(x: 8, y: 9))
        }
        map.placeBuilding(zone: .generator, origin: GridPosition(x: 13, y: 8))
        return map
    }

    private static func controller(_ map: CityMap) -> GameController {
        let controller = GameController(map: map, rng: SeededRNG(seed: 2))
        controller.recomputeUtilitySupply()
        return controller
    }

    /// The badge the colour cannot replace: in the Power view the unpowered
    /// block carries the bolt, and the powered one carries nothing.
    func testThePowerViewBadgesWhatTheColourCannotSay() throws {
        let map = Self.controller(Self.utilityBlocks()).map
        XCTAssertFalse(PowerGrid.hasSupply(at: GridPosition(x: 2, y: 8), in: map))
        XCTAssertTrue(PowerGrid.hasSupply(at: GridPosition(x: 10, y: 8), in: map))
        let overlay = MetalOverlay()
        overlay.update(map, mode: .power)
        let boards = stride(from: 0, to: overlay.billboards.count, by: MetalOverlay.billboardFloatCount).map {
            Array(overlay.billboards[$0 ..< $0 + MetalOverlay.billboardFloatCount])
        }
        func badged(_ origin: GridPosition) -> Bool {
            boards.contains { b in
                b[7] == MetalOverlay.Glyph.power.rawValue
                    && abs(b[0] - Float(origin.x + 1)) < 0.6 && abs(b[1] - Float(origin.y + 1)) < 0.6
            }
        }
        XCTAssertTrue(badged(GridPosition(x: 2, y: 8)), "no bolt on the block with no power")
        XCTAssertFalse(badged(GridPosition(x: 10, y: 8)), "a bolt on a powered block")
    }

    /// Every view either paints the ground or has nothing to say — none of
    /// them silently paints nothing, which is how three SpriteKit heatmaps
    /// once shipped.
    func testEveryViewPaintsSomething() {
        let map = MetalMotionTests.tickedCity()
        for mode in OverlayMode.allCases where mode != .none {
            let overlay = MetalOverlay()
            overlay.update(map, mode: mode)
            XCTAssertFalse(overlay.tiles.isEmpty, "\(mode) paints nothing")
        }
    }

    /// Normal view's marks: a scaffold on a lot under construction and a
    /// damage badge on a struck one — and neither under a view, which hides
    /// what describes a building.
    func testNormalViewCarriesTheBuildingMarks() {
        var map = MetalMotionTests.tickedCity()
        map[GridPosition(x: 2, y: 3)].constructionRemaining = 4
        map[GridPosition(x: 5, y: 3)].damagedBy = .policeStation
        let overlay = MetalOverlay()
        overlay.update(map, mode: .none)
        XCTAssertFalse(overlay.traces.isEmpty, "no scaffold")
        XCTAssertTrue(stride(from: 7, to: overlay.billboards.count, by: MetalOverlay.billboardFloatCount)
            .contains { overlay.billboards[$0] == MetalOverlay.Glyph.damage.rawValue }, "no damage mark")
        overlay.update(map, mode: .landValue)
        XCTAssertTrue(overlay.traces.isEmpty)
        XCTAssertTrue(overlay.hidesBuildings, "a heatmap left the buildings standing over its data")
    }

    // MARK: - Colour vision, on rendered pixels

    private enum Vision: CaseIterable {
        case deuteranopia, protanopia, tritanopia
        var matrix: [[Double]] {
            switch self {
            case .deuteranopia: return [[0.625, 0.375, 0], [0.700, 0.300, 0], [0, 0.300, 0.700]]
            case .protanopia:   return [[0.567, 0.433, 0], [0.558, 0.442, 0], [0, 0.242, 0.758]]
            case .tritanopia:   return [[0.950, 0.050, 0], [0, 0.433, 0.567], [0, 0.475, 0.525]]
            }
        }
    }

    /// **The rule, carried across and measured on what the player sees.**
    /// A pair of meanings may share a colour only if something else tells
    /// them apart. On SpriteKit exactly one pair collapses — Power's supplied
    /// and wanting, which is why that view badges — and the Metal renderer is
    /// held to the same: any collapse outside that pair fails.
    func testTheRenderedViewsKeepTheirMeaningsApart() throws {
        let renderer = try XCTUnwrap(MetalCityRenderer())
        let size = CGSize(width: 900, height: 600)
        let camera = MetalCityRenderer.Camera(centre: Isometric().project(8, 8, 0), scale: 0.7, size: size)
        let matrix = renderer.viewProjection(for: camera, mapExtent: 1)

        /// The average colour of a building's right-hand wall, in sRGB 0…1.
        func wall(_ origin: GridPosition, in bytes: [UInt8]) -> SIMD3<Double> {
            var sum = SIMD3<Double>(0, 0, 0), n = 0.0
            for dy in stride(from: 0.4, through: 1.6, by: 0.3) {
                for dz in stride(from: 0.3, through: 0.9, by: 0.15) {
                    let world = SIMD4<Float>(Float(origin.x) + 2.001, Float(origin.y) + Float(dy), Float(dz), 1)
                    let clip = matrix * world
                    let px = Int((Double(clip.x) + 1) / 2 * Double(size.width))
                    let py = Int((1 - Double(clip.y)) / 2 * Double(size.height))
                    guard px >= 0, py >= 0, px < Int(size.width), py < Int(size.height) else { continue }
                    let i = (py * Int(size.width) + px) * 4
                    sum += SIMD3(Double(bytes[i]), Double(bytes[i + 1]), Double(bytes[i + 2])) / 255
                    n += 1
                }
            }
            return sum / max(n, 1)
        }
        func seen(_ c: SIMD3<Double>, _ v: Vision) -> SIMD3<Double> {
            let m = v.matrix
            return SIMD3(m[0][0] * c.x + m[0][1] * c.y + m[0][2] * c.z,
                         m[1][0] * c.x + m[1][1] * c.y + m[1][2] * c.z,
                         m[2][0] * c.x + m[2][1] * c.y + m[2][2] * c.z)
        }

        var collapsed: Set<String> = []
        for mode in [OverlayMode.water, .power] {
            let map = Self.controller(Self.utilityBlocks(leftDry: mode == .water)).map
            renderer.overlayMode = mode
            let image = try XCTUnwrap(renderer.render(map, camera: camera, wetness: 0, time: 1)).image
            let bytes = MetalMotionTests.bytes(image)
            let states = [("served", wall(GridPosition(x: 10, y: 8), in: bytes)),
                          ("wanting", wall(GridPosition(x: 2, y: 8), in: bytes)),
                          ("not applicable", wall(GridPosition(x: 6, y: 4), in: bytes))]
            let name = mode == .water ? "Water" : "Power"
            // The fixture has to be in the state it claims.
            let served = mode == .water ? Water.hasSupply : PowerGrid.hasSupply
            XCTAssertTrue(served(GridPosition(x: 10, y: 8), map))
            XCTAssertFalse(served(GridPosition(x: 2, y: 8), map))
            for i in 0 ..< states.count {
                for j in i + 1 ..< states.count {
                    let worst = Vision.allCases.map { simd_length(seen(states[i].1, $0) - seen(states[j].1, $0)) }
                        .min() ?? 1
                    print(String(format: "🟪 %@ %@ / %@: %.3f", name, states[i].0, states[j].0, worst))
                    if worst < ColourAccessibilityTests.tellApart {
                        collapsed.insert("\(name): \(states[i].0) / \(states[j].0)")
                    }
                }
            }
        }
        XCTAssertTrue(collapsed.isSubset(of: ["Power: served / wanting"]),
                      "meanings a colourblind player cannot tell apart by colour, with no glyph: \(collapsed)")
    }

    /// **What a view costs to rebuild on the densest city**, because with a
    /// view up it is rebuilt on every change of the map — a placement, a day.
    /// Printed for every view and bounded at a frame: a view that takes
    /// longer than a frame to repaint makes every click in it hitch.
    func testEveryViewRebuildsInsideAFrameOnApex() throws {
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "needs Apex")
        let map = try CitySaveFile.read(from: url).map
        let overlay = MetalOverlay()
        var report: [String] = []
        for mode in OverlayMode.allCases {
            var best = Double.infinity
            for _ in 0 ..< 3 {
                let start = DispatchTime.now().uptimeNanoseconds
                overlay.update(map, mode: mode)
                best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            report.append(String(format: "%@ %.1f", "\(mode)", best))
            XCTAssertLessThan(best, 16, "\(mode) takes \(best) ms to rebuild on Apex")
        }
        print("🟪 view rebuild on Apex, ms: " + report.joined(separator: " · "))
    }

    // MARK: - The renders

    /// **Every view, one frame each** — the render the plan asks for.
    func testRenderEveryView() throws {
        var map = MetalMotionTests.tickedCity()
        // Plumbing, so the Water and Power views have a network to show with
        // both answers in it.
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 0, y: 13))
        map.placeBuilding(zone: .generator, origin: GridPosition(x: 2, y: 13))
        for x in 0 ..< 16 {
            map[GridPosition(x: x, y: 12)].hasPipe = true
            map[GridPosition(x: x, y: 12)].hasPowerLine = true
        }
        map.placeBuilding(zone: .policeStation, origin: GridPosition(x: 14, y: 13))
        let controller = Self.controller(map)
        map = controller.map
        let renderer = try XCTUnwrap(MetalCityRenderer())
        let size = CGSize(width: 720, height: 450)
        let camera = MetalCityRenderer.Camera(centre: Isometric().project(15, 11, 0), scale: 1.6, size: size)
        var frames: [(String, NSImage)] = []
        for mode in OverlayMode.allCases {
            renderer.overlayMode = mode
            let frame = try XCTUnwrap(renderer.render(map, camera: camera, wetness: 0, time: 1))
            frames.append(("\(mode)", NSImage(cgImage: frame.image, size: size)))
        }
        try MetalSpikeTests.writeGrid(frames, columns: 3, cell: size, named: "metal-overlays")
    }

    /// Normal view's marks up close: a scaffold climbing, a damaged block, and
    /// blocks short of water and power wearing the drop and the bolt.
    func testRenderTheBuildingMarks() throws {
        var map = Self.controller(Self.utilityBlocks()).map
        map[GridPosition(x: 6, y: 4)].constructionRemaining = 5
        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 12, y: 3))
        for cell in map.footprintCells(origin: GridPosition(x: 12, y: 3), size: 2) { map[cell].density = 3 }
        map[GridPosition(x: 12, y: 3)].damagedBy = .fireStation
        let renderer = try XCTUnwrap(MetalCityRenderer())
        let size = CGSize(width: 1100, height: 700)
        let camera = MetalCityRenderer.Camera(centre: Isometric().project(8, 7, 0), scale: 0.6, size: size)
        let frame = try XCTUnwrap(renderer.render(map, camera: camera, wetness: 0, time: 1))
        try MetalSpikeTests.writeGrid([("Normal view — scaffold, damage, the drop and the bolt",
                                        NSImage(cgImage: frame.image, size: size))],
                                      columns: 1, cell: size, named: "metal-marks")
    }
}
