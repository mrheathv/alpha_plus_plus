import XCTest
import SpriteKit
@testable import AlphaPlusPlus

/// The projection and the volume maths that every isometric building rests on.
///
/// These are cheap assertions about geometry, and they exist because every bug
/// this file can catch is *silent* in the render: a face with an inverted
/// normal does not crash, it just goes missing or lights from the wrong side,
/// and a broken click inverse does not crash either, it just places buildings
/// on the wrong tile.
final class IsometricTests: XCTestCase {

    private let projection = Isometric()

    // MARK: - Projection

    /// `groundPosition(for:)` has to be the exact inverse of `project` on the
    /// ground plane, or click-to-place lands on the wrong tile.
    ///
    /// This is the piece a switch to isometric cannot skip: top-down,
    /// `GridLayout.position(for:)` is an integer divide, because squares tile
    /// trivially. Diamonds do not.
    func testGroundPositionInvertsProjection() {
        for x in stride(from: -8.0, through: 8.0, by: 0.5) {
            for y in stride(from: -8.0, through: 8.0, by: 0.5) {
                let screen = projection.project(CGFloat(x), CGFloat(y), 0)
                let back = projection.groundPosition(for: screen)
                XCTAssertEqual(back.x, CGFloat(x), accuracy: 0.0001, "x round-trip at (\(x), \(y))")
                XCTAssertEqual(back.y, CGFloat(y), accuracy: 0.0001, "y round-trip at (\(x), \(y))")
            }
        }
    }

    /// Elevation must not move a point sideways, or a tall building would lean.
    func testElevationRaisesWithoutShifting() {
        let ground = projection.project(3, 5, 0)
        let raised = projection.project(3, 5, 2)
        XCTAssertEqual(raised.x, ground.x, accuracy: 0.0001)
        XCTAssertEqual(raised.y - ground.y, 2 * projection.heightUnit, accuracy: 0.0001)
    }

    /// The 2:1 ratio is what keeps ground edges on an exact two-across-one-down
    /// slope; losing it makes every diagonal shimmer.
    func testTilesAreTwiceAsWideAsTall() {
        XCTAssertEqual(projection.tileWidth, projection.tileHeight * 2, accuracy: 0.0001)
    }

    // MARK: - Faces

    func testBoxFaceNormalsAllPointOutward() {
        let box = Box(x: 1, y: 2, z: 0, width: 2, depth: 3, height: 1.5)
        let centre = box.centre
        XCTAssertEqual(box.faces.count, 6)
        for (index, face) in box.faces.enumerated() {
            let middle = face.points.reduce(Point3(x: 0, y: 0, z: 0), +)
            let count = CGFloat(face.points.count)
            let outward = Point3(x: middle.x / count, y: middle.y / count, z: middle.z / count) - centre
            XCTAssertGreaterThan(
                face.normal.dot(outward), 0,
                "face \(index)'s normal points into the volume — it would be lit from the wrong side"
            )
        }
    }

    /// A box shows exactly three faces: its top and the two walls facing the
    /// camera. Fewer means something is being culled that should not be.
    func testBoxShowsThreeFaces() {
        let box = Box(x: 0, y: 0, z: 0, width: 2, depth: 2, height: 1)
        XCTAssertEqual(box.faces.filter(Isometric.isVisible).count, 3)
    }

    /// **The case a hardcoded face list cannot express.** Whether the far slope
    /// of a gable roof is visible depends on how steep it is, and the direction
    /// is the opposite of the intuition you get from looking at a house at
    /// street level: from a bird's-eye camera a *shallow* roof shows both
    /// slopes, because it is nearly a flat plate seen from above, while a steep
    /// A-frame hides its far slope behind the ridge.
    ///
    /// The exact threshold falls out of the projection: the far slope's normal
    /// is proportional to (0, rise, run), so it faces the camera only while
    /// `run > 1.018 × rise`. No fixed list of faces can express that, which is
    /// why visibility is computed from each face's own normal — the isometric
    /// spike hardcoded "top, right, left", which is correct for a box and wrong
    /// the moment anything slopes.
    ///
    /// Worth recording that this test was first written asserting the opposite
    /// and the code was right: a measurement disagreeing with an expectation is
    /// as often the expectation's fault as the code's.
    func testGableSlopeVisibilityDependsOnPitch() {
        let shallow = Ridge(x: 0, y: 0, z: 0, width: 2, depth: 2, height: 0.4, axis: .x)
        let steep = Ridge(x: 0, y: 0, z: 0, width: 2, depth: 2, height: 2.0, axis: .x)

        XCTAssertEqual(
            shallow.faces.filter(Isometric.isVisible).count, 3,
            "a shallow gable seen from above should show both slopes and the near gable end"
        )
        XCTAssertEqual(
            steep.faces.filter(Isometric.isVisible).count, 2,
            "a steep gable should hide its far slope behind the ridge"
        )
    }

    /// A sawtooth is a gable with the ridge pushed to the wall — one primitive,
    /// not two. This pins that: the far "slope" becomes a vertical wall with
    /// real area rather than degenerating to nothing.
    func testSawtoothKeepsItsVerticalFace() {
        let sawtooth = Ridge(x: 0, y: 0, z: 0, width: 2, depth: 2, height: 0.8,
                             axis: .x, ridgePosition: 1)
        let visible = sawtooth.faces.filter(Isometric.isVisible)
        XCTAssertGreaterThanOrEqual(visible.count, 2)
        for face in visible {
            let projected = projection.path(face.points).boundingBox
            XCTAssertGreaterThan(projected.width * projected.height, 0,
                                 "a sawtooth face collapsed to zero area")
        }
    }

    func testCylinderShowsAboutHalfItsSidesPlusTheCap() {
        let cylinder = Cylinder(x: 0, y: 0, z: 0, radius: 0.5, height: 1, sides: 16)
        let visible = cylinder.faces.filter(Isometric.isVisible).count
        // Half the sides face away; the top cap is always visible.
        XCTAssertGreaterThan(visible, 5)
        XCTAssertLessThan(visible, 12)
    }

    // MARK: - Draw order

    /// Nearer volumes must sort after farther ones, and a volume standing on
    /// another must sort after the one it stands on.
    func testSortIsNearestLastAndBreaksTiesByElevation() {
        let far = Box(x: 0, y: 0, z: 0, width: 1, depth: 1, height: 1)
        let near = Box(x: 4, y: 4, z: 0, width: 1, depth: 1, height: 1)
        let onTopOfFar = Box(x: 0, y: 0, z: 1, width: 1, depth: 1, height: 1)

        let ordered = Isometric.sorted(
            [Volume.box(near), .box(onTopOfFar), .box(far)],
            depth: { $0.depth }
        )
        let depths = ordered.map { $0.depth }
        XCTAssertEqual(depths[0].0, far.x + 0.5 + far.y + 0.5, accuracy: 0.0001)
        XCTAssertEqual(depths[1].1, 1, accuracy: 0.0001, "the stacked box should follow the one it stands on")
        XCTAssertEqual(depths[2].0, near.x + 0.5 + near.y + 0.5, accuracy: 0.0001)
    }

    /// A pane has to draw on top of the wall it sits on, and still be covered
    /// by anything genuinely nearer.
    func testPanelsSortOntoTheirOwnWall() {
        let box = Box(x: 0, y: 0, z: 0, width: 2, depth: 2, height: 1)
        let panel = Panel(box: box, face: .right, u0: 0.2, u1: 0.8, v0: 0.2, v1: 0.8, color: .white)
        XCTAssertGreaterThan(panel.depth.0, Volume.box(box).depth.0)

        let nearer = Box(x: 3, y: 3, z: 0, width: 1, depth: 1, height: 1)
        XCTAssertLessThan(panel.depth.0, Volume.box(nearer).depth.0)
    }

    // MARK: - Rendering

    /// One building must cost exactly one blur pass regardless of how many
    /// volumes it is made of. `ZoneIconContactSheetTests` has twice shown that
    /// a scene silently stops servicing effect nodes past a budget, so a
    /// five-box building costing five of them would not fail loudly — the map
    /// would just start dropping buildings.
    func testABuildingCostsOneEffectNode() {
        var massing = BuildingMassing()
        for index in 0 ..< 5 {
            massing.add(.box(Box(x: CGFloat(index) * 0.3, y: 0, z: CGFloat(index) * 0.4,
                                 width: 0.5, depth: 0.5, height: 0.4)))
        }
        let node = IsometricBuilding.node(for: massing, accent: .magenta, tier: 2, in: projection)
        let effectNodes = node.children.filter { $0 is SKEffectNode }
        XCTAssertEqual(effectNodes.count, 1, "expected exactly one blur pass for the whole building")
    }

    func testRenderedBuildingHasArea() {
        var massing = BuildingMassing()
        massing.add(.box(Box(x: 0, y: 0, z: 0, width: 2, depth: 2, height: 1)))
        massing.panels.append(Panel(box: Box(x: 0, y: 0, z: 0, width: 2, depth: 2, height: 1),
                                    face: .left, u0: 0.2, u1: 0.8, v0: 0.3, v1: 0.7, color: .cyan))
        let node = IsometricBuilding.node(for: massing, accent: .magenta, tier: 3, in: projection)
        let frame = node.calculateAccumulatedFrame()
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
    }
}
