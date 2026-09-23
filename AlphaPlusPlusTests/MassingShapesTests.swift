import Foundation
import XCTest
@testable import AlphaPlusPlus

/// The P2 toolkit: `MassingShape`'s constructors, held to the two rules both
/// renderers rely on — every face points out of its shape, and every face is
/// convex — and drawn on a sheet of their own.
@MainActor
final class MassingShapesTests: XCTestCase {

    private static let samples: [(String, MassingShape)] = [
        ("prism (hexagon)", .prism(plan: (0 ..< 6).map { i in
            let a = CGFloat(i) / 6 * 2 * .pi
            return CGPoint(x: 1 + 0.6 * cos(a), y: 1 + 0.6 * sin(a))
        }, z: 0, height: 1.2)),
        ("bevelled box", .bevelledBox(Box(x: 0.3, y: 0.3, z: 0, width: 1.4, depth: 1.4, height: 1.6), bevel: 0.25)),
        ("frustum", .frustum(Box(x: 0.2, y: 0.2, z: 0, width: 1.6, depth: 1.6, height: 1.4), topInset: 0.4)),
        ("lathe (tank)", .lathe(x: 1, y: 1, z: 0, profile: [(0.5, 0), (0.5, 0.8), (0.3, 1.05), (0, 1.15)])),
        ("dome", .dome(x: 1, y: 1, z: 0, radius: 0.7)),
        ("arch", .arch(at: CGPoint(x: 1, y: 0.8), z: 0, alongX: true, span: 1.0, band: 0.18, depth: 0.3)),
    ]

    /// Faces must point out of their shape, or they vanish or light from the
    /// wrong side with no error. The arch is a ring of separate blocks, so it
    /// is checked block by block through its own construction and left out.
    func testEveryFacePointsOutward() {
        for (name, shape) in Self.samples where name != "arch" {
            for face in shape.faces {
                let middle = face.points.reduce(Point3(x: 0, y: 0, z: 0), +)
                let mid = Point3(x: middle.x / CGFloat(face.points.count), y: middle.y / CGFloat(face.points.count),
                                 z: middle.z / CGFloat(face.points.count))
                XCTAssertGreaterThan(face.normal.dot(mid - shape.centre), -1e-6, "\(name): a face points inward")
            }
        }
    }

    /// Metal fills a face as a fan from its first corner, so a concave face
    /// would draw wrongly and silently.
    func testEveryFaceIsConvex() {
        for (name, shape) in Self.samples {
            for face in shape.faces where face.points.count > 3 {
                // Project onto the plane most square to the normal.
                let n = face.normal
                let plan = face.points.map { p -> CGPoint in
                    if abs(n.z) >= abs(n.x) && abs(n.z) >= abs(n.y) { return CGPoint(x: p.x, y: p.y) }
                    if abs(n.x) >= abs(n.y) { return CGPoint(x: p.y, y: p.z) }
                    return CGPoint(x: p.x, y: p.z)
                }
                XCTAssertTrue(MassingShape.isConvex(plan), "\(name): a face is concave")
            }
        }
    }

    func testAConcavePlanIsRecognised() {
        let ell = [CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 0), CGPoint(x: 2, y: 1),
                   CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 2), CGPoint(x: 0, y: 2)]
        XCTAssertFalse(MassingShape.isConvex(ell))
        XCTAssertTrue(MassingShape.isConvex([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1)]))
    }

    /// A bevelled box shows its two near cut corners as faces of their own,
    /// which is the point of it: the camera sees more walls than a box's two.
    func testABevelledBoxShowsItsCutCorners() {
        let visible = Self.samples[1].1.faces.filter { Isometric.isVisible($0) && abs($0.normal.z) < 0.5 }
        XCTAssertGreaterThanOrEqual(visible.count, 3)
    }

    /// Each shape alone on a lot, drawn by the Metal renderer. These are
    /// massings no lot generates, so each is handed to the renderer as a
    /// low-density housing lot's building (housing carries no signs), one variant apiece.
    func testRenderTheToolkit() throws {
        let cells = Self.samples.enumerated().map { index, sample -> MetalSheet.Cell in
            var massing = BuildingMassing()
            massing.add(.shape(sample.1))
            return .init(label: sample.0, zone: .residential, density: 1, variant: index, massing: massing)
        }
        try MetalSheet.write(cells, columns: cells.count, cell: CGSize(width: 240, height: 260),
                             named: "massing-shapes")
    }
}
