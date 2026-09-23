import SpriteKit
import XCTest
@testable import AlphaPlusPlus

/// P3: the facade parts, and the marks that moved out of the renderer.
@MainActor
final class FacadeDetailTests: XCTestCase {

    private func built(_ panel: Panel?) -> MetalCityMesh.Built {
        let box = Box(x: 0.5, y: 0.5, z: 0, width: 1, depth: 1, height: 1)
        var massing = BuildingMassing()
        massing.add(.box(box))
        if var panel {
            panel.box = box
            massing.panels.append(panel)
        }
        return MetalCityMesh.building(.init(zone: .commercial, density: 3, variant: 0, tier: .street),
                                      massing: massing)
    }

    private func windowTags(in built: MetalCityMesh.Built) -> Int {
        stride(from: 19, to: built.vertices.count, by: MetalCityRenderer.GPUVertex.floatCount)
            .filter { MetalCityMesh.isWindowTag(built.vertices[$0]) }.count
    }

    private static let bright = Panel(box: Box(x: 0, y: 0, z: 0, width: 1, depth: 1, height: 1), face: .right,
                                      u0: 0.2, u1: 0.8, v0: 0.2, v1: 0.8, color: NeonStyle.litAccent)

    /// A mark bright enough to be a window is still not one: no window tag
    /// for the shader to put blinds on, and no share of the wall's light.
    /// The control is the same panel as an ordinary window, which gets both.
    func testAMarkIsNeitherAWindowNorALight() {
        var mark = Self.bright
        mark.isMark = true
        mark.standoff = 0.013
        let bare = built(nil), marked = built(mark), window = built(Self.bright)

        XCTAssertEqual(windowTags(in: marked), 0, "a mark was tagged as a window")
        XCTAssertEqual(marked.lights, bare.lights, "a mark added light")
        XCTAssertGreaterThan(windowTags(in: window), 0, "the control window lost its tag")
        XCTAssertNotEqual(window.lights, bare.lights, "the control window added no light")
    }

    /// Every lit pane gains four frame strips and a sill at the street tier,
    /// and nothing at the resting camera, which draws exactly what it did.
    func testWindowsGainFramesOnlyAtTheStreetTier() throws {
        let massing = try XCTUnwrap(ZoneMassing.make(for: .commercial, density: 3,
                                                     seed: IsoTextureCache.canonicalSeed(for: 0)))
        let lit = massing.panels.filter {
            !$0.isMark && MetalCityMesh.luminance(MetalCityMesh.linear($0.color) * Float($0.color.alphaComponent)) > 0.08
        }
        let frames = massing.panels.filter { $0.isMark && $0.tier == .street }
        XCTAssertEqual(frames.count, lit.count * 4)
        XCTAssertTrue(massing.drawn(at: .standard).panels.allSatisfy { !$0.isMark }, "a mark is drawn at rest")
        XCTAssertFalse(massing.panels.filter { $0.isMark && $0.tier == .near }.isEmpty, "no mullions or slab lines")
    }
}
