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
    /// the top-down layout's `position(for:)` was an integer divide, because squares tile
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

    // MARK: - Map geometry and picking

    /// Every tile's own centre must pick that tile. This is the whole of
    /// click-to-place: if it is wrong, buildings land one square off and
    /// nothing else in the game notices.
    func testEveryTileCentrePicksItsOwnTile() {
        let map = CityMap(width: 24, height: 18)
        for x in 0 ..< map.width {
            for y in 0 ..< map.height {
                let position = GridPosition(x: x, y: y)
                let picked = projection.position(for: projection.point(for: position), in: map)
                XCTAssertEqual(picked, position, "tile (\(x), \(y)) picked \(String(describing: picked))")
            }
        }
    }

    /// And near the diamond's corners, which is where an off-by-one in the
    /// inverse shows up first — a centre would still pick correctly even if the
    /// transform were subtly wrong in scale.
    func testPointsNearATileEdgePickTheRightTile() {
        let map = CityMap(width: 12, height: 12)
        let position = GridPosition(x: 5, y: 7)
        // Just inside each of the four ground corners of the tile.
        let inset: CGFloat = 0.02
        for (dx, dy) in [(inset, inset), (1 - inset, inset), (inset, 1 - inset), (1 - inset, 1 - inset)] {
            let screen = projection.project(CGFloat(position.x) + dx, CGFloat(position.y) + dy, 0)
            XCTAssertEqual(projection.position(for: screen, in: map), position,
                           "corner (\(dx), \(dy)) of tile (5, 7) picked the wrong tile")
        }
    }

    func testPointsOutsideTheMapPickNothing() {
        let map = CityMap(width: 8, height: 8)
        XCTAssertNil(projection.position(for: projection.project(-1.5, 4, 0), in: map))
        XCTAssertNil(projection.position(for: projection.project(4, -1.5, 0), in: map))
        XCTAssertNil(projection.position(for: projection.project(9.5, 4, 0), in: map))
        XCTAssertNil(projection.position(for: projection.project(4, 9.5, 0), in: map))
    }

    /// Picking is against the ground, not against what is drawn on top of it.
    ///
    /// A point over a tall tower's upper floors is geometrically over ground
    /// several tiles *behind* the tower. A city builder wants the ground — every
    /// tool acts on a lot rather than a building — and this pins that choice so
    /// it cannot drift into "topmost drawn thing" by accident.
    func testPickingIgnoresElevation() {
        let map = CityMap(width: 20, height: 20)
        let ground = GridPosition(x: 4, y: 4)
        // Where the top of a three-unit tower on that lot appears on screen.
        let towerTop = projection.project(4.5, 4.5, 3)
        let picked = projection.position(for: towerTop, in: map)
        XCTAssertNotEqual(picked, ground, "a point at the top of a tower is not over the tower's own lot")
        XCTAssertNotNil(picked, "it is over some other lot, further back")
    }

    /// The map's bounding box has to contain the whole ground diamond, or the
    /// camera will clamp the player away from the corners.
    func testContentBoundsContainsEveryCorner() {
        let map = CityMap(width: 14, height: 9)
        let bounds = projection.contentBounds(of: map)
        for (x, y) in [(0, 0), (map.width, 0), (0, map.height), (map.width, map.height)] {
            let corner = projection.project(CGFloat(x), CGFloat(y), 0)
            XCTAssertTrue(bounds.insetBy(dx: -0.001, dy: -0.001).contains(corner),
                          "corner (\(x), \(y)) at \(corner) falls outside \(bounds)")
        }
        XCTAssertTrue(bounds.contains(projection.centerPoint(of: map)))
    }

    /// A near tile must sort in front of a far one, and a multi-tile building
    /// must sort by its nearest corner — otherwise a 3x3 stadium anchored far
    /// back would be painted over by the 1x1 tiles it actually covers.
    func testTileDepthIsNearestLast() {
        XCTAssertLessThan(Isometric.depth(of: GridPosition(x: 0, y: 0)),
                          Isometric.depth(of: GridPosition(x: 3, y: 3)))
        XCTAssertEqual(Isometric.depth(of: GridPosition(x: 2, y: 1)),
                       Isometric.depth(of: GridPosition(x: 1, y: 2)))
        XCTAssertEqual(Isometric.depth(of: GridPosition(x: 1, y: 1), footprint: 3),
                       Isometric.depth(of: GridPosition(x: 3, y: 3)),
                       "a 3x3 anchored at (1,1) reaches as near as a tile at (3,3)")
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

    /// A box shows its top and the two walls at maximum x and y — *which*
    /// faces, not how many.
    ///
    /// Counting was not enough. `Isometric.toCamera` was first written pointing
    /// the wrong way, which culls exactly the three faces that point at the
    /// camera and draws the three that point away. The count is three either
    /// way, so a count assertion passed happily while every building was drawn
    /// inside out — the visible symptom being lit panels floating beside walls
    /// that were never drawn.
    func testBoxShowsItsNearWallsAndTop() {
        let box = Box(x: 0, y: 0, z: 0, width: 2, depth: 2, height: 1)
        let visible = box.faces.filter(Isometric.isVisible)
        XCTAssertEqual(visible.count, 3)

        let normals = visible.map(\.normal)
        XCTAssertTrue(normals.contains { $0.z > 0.9 }, "the top face should be visible")
        XCTAssertTrue(normals.contains { $0.x > 0.9 }, "the +x wall faces the camera and should be visible")
        XCTAssertTrue(normals.contains { $0.y > 0.9 }, "the +y wall faces the camera and should be visible")
        XCTAssertFalse(normals.contains { $0.z < -0.9 }, "the underside must never be drawn")
    }

    /// The two visible walls must not come out the same value, or a box reads
    /// as a flat hexagon rather than a solid. This is what the key light is
    /// for, and it is why the light is not simply the camera direction: lighting
    /// a face by how much it faces the viewer gives every visible face the same
    /// answer.
    func testTheTwoVisibleWallsAreLitDifferently() {
        let box = Box(x: 0, y: 0, z: 0, width: 2, depth: 2, height: 1)
        let visible = box.faces.filter(Isometric.isVisible)
        let top = visible.first { $0.normal.z > 0.9 }!
        let xWall = visible.first { $0.normal.x > 0.9 }!
        let yWall = visible.first { $0.normal.y > 0.9 }!

        XCTAssertGreaterThan(Isometric.shade(top), Isometric.shade(xWall), "the roof should catch the most light")
        XCTAssertGreaterThan(Isometric.shade(xWall), Isometric.shade(yWall), "the two walls should differ")
        XCTAssertGreaterThan(Isometric.shade(yWall), 0.05, "no visible wall may be pure black — a lit panel needs a surface to sit on")
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

    /// Every corner of a panel must lie exactly on the wall it claims to be
    /// on. A panel that drifts off its face does not fail anything — it just
    /// renders as a lit rectangle floating in the air beside the building,
    /// which is easy to mistake for a lighting effect when glancing at a
    /// contact sheet.
    func testPanelCornersLieOnTheirBoxFace() {
        let box = Box(x: 0.3, y: 0.7, z: 0, width: 1.4, depth: 1.1, height: 0.9)
        for face in [Panel.Face.right, .left] {
            let panel = Panel(box: box, face: face, u0: 0.2, u1: 0.8, v0: 0.1, v1: 0.9, color: .white)
            for corner in panel.corners {
                switch face {
                case .right:
                    XCTAssertEqual(corner.x, box.x + box.width, accuracy: 0.0001, "right panel left its wall")
                    XCTAssertGreaterThanOrEqual(corner.y, box.y)
                    XCTAssertLessThanOrEqual(corner.y, box.y + box.depth)
                case .left:
                    XCTAssertEqual(corner.y, box.y + box.depth, accuracy: 0.0001, "left panel left its wall")
                    XCTAssertGreaterThanOrEqual(corner.x, box.x)
                    XCTAssertLessThanOrEqual(corner.x, box.x + box.width)
                }
                XCTAssertGreaterThanOrEqual(corner.z, box.z - 0.0001)
                XCTAssertLessThanOrEqual(corner.z, box.z + box.height + 0.0001)
            }
        }
    }

    /// The same, for every panel a real generator emits — which is where a
    /// panel attached to the wrong volume would actually show up.
    func testGeneratedPanelsSitOnAVolumeTheyBelongTo() {
        for tier in [1, 2, 3] {
            for index in 0 ..< 8 {
                let seed = GridPosition(x: index * 7, y: index * 3)
                let massing = IndustrialMassing.make(tier: tier, seed: seed)
                for panel in massing.panels {
                    let matches = massing.solids.contains { solid in
                        guard case .box(let box) = solid.volume else { return false }
                        return abs(box.x - panel.box.x) < 0.0001
                            && abs(box.y - panel.box.y) < 0.0001
                            && abs(box.z - panel.box.z) < 0.0001
                            && abs(box.height - panel.box.height) < 0.0001
                    }
                    XCTAssertTrue(
                        matches,
                        "tier \(tier) seed \(index): a panel is attached to a box that is not in the massing"
                    )
                }
            }
        }
    }

    // MARK: - Rendering

    /// One building must cost exactly one blur pass regardless of how many
    /// volumes it is made of. The elevation contact sheet twice showed that
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
