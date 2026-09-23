import SpriteKit

/// A building described as *what it is* rather than as a drawing of it.
///
/// **Why the generators change shape.** `ResidentialBuilding` and friends
/// currently return an `SKNode` of a front elevation — the drawing is the
/// output, so the projection is baked into every generator. Moving to
/// isometric under that design would mean rewriting the design decisions along
/// with the drawing.
///
/// Massing separates the two. A generator says "a hall two tiles wide and a
/// third of a tile tall, with three chimneys and a sawtooth roof"; a renderer
/// decides what that looks like from a given angle. The forms the generators
/// already choose between — a strip of shops, a corner unit, a row of houses,
/// a sawtooth roof — are massing decisions and survive the move unchanged.
/// This is the same split the project draws between simulation and rendering,
/// one level down.
///
/// Everything here is in **tile units**: a 2×2 lot is 2 wide and 2 deep, and
/// `Isometric.heightUnit` decides what a height of 1 looks like on screen.
struct BuildingMassing {
    var solids: [Solid] = []
    var panels: [Panel] = []
    var badges: [Badge] = []

    /// `tier` is the farthest camera the part is drawn at; untagged parts
    /// are drawn at every zoom.
    mutating func add(_ volume: Volume, _ style: Solid.Style = .structure, from tier: DetailTier = .far) {
        solids.append(Solid(volume: volume, style: style, tier: tier))
    }

    /// Only the parts drawn at `tier`: those tagged for it or for a farther
    /// camera.
    func drawn(at tier: DetailTier) -> BuildingMassing {
        var copy = self
        copy.solids = solids.filter { $0.tier <= tier }
        copy.panels = panels.filter { $0.tier <= tier }
        return copy
    }
}

// MARK: - Level of detail

/// **Which cameras a part is drawn at.** Detail belongs to the camera distance
/// at which it first becomes big enough to read: a mark smaller than about
/// eight pixels on screen averages into grey speckle, the failure
/// `NeonStyle.minimumDetailSize` records. A part tagged `.near` is drawn at
/// the near tier and every closer one; an untagged part (`.far`) at every zoom.
///
/// Drawn by the Metal renderer only. SpriteKit is due to retire, and draws
/// `drawn(at: .standard)` — exactly what it drew before tiers existed.
enum DetailTier: Int, Comparable, CaseIterable {
    /// Always drawn, from the widest camera in.
    case far
    /// From the resting camera in (128 Retina pixels a tile).
    case standard
    /// From the near tier in (178 pixels a tile).
    case near
    /// From the street tier in (380 pixels a tile).
    case street

    static func < (a: DetailTier, b: DetailTier) -> Bool { a.rawValue < b.rawValue }

    /// The smallest a part tagged for this tier may be, in tiles: about eight
    /// pixels at the farthest camera the tier is drawn at. Measured on a
    /// part's *largest* extent — a speck is small in every direction, and a
    /// mast or a lit fin is thin but long and reads perfectly well.
    static func floor(_ tier: DetailTier) -> CGFloat {
        switch tier {
        case .far: return 0.19
        case .standard: return 0.06
        case .near: return 0.03
        case .street: return 0.016
        }
    }
}

// MARK: - Volumes

/// A volume, reduced to the polygons that bound it.
///
/// Every shape in the game funnels through `faces` so that visibility and
/// shading have exactly one implementation. The alternative — each volume type
/// knowing which of its faces the camera can see — is what the isometric spike
/// did, and it is only correct for boxes: whether the far slope of a gable roof
/// is visible depends on whether the roof is steeper than about 45°, which no
/// fixed list of faces can express.
enum Volume {
    case box(Box)
    case ridge(Ridge)
    case cylinder(Cylinder)
    /// Anything else, with its faces already computed — see `MassingShape`.
    case shape(MassingShape)

    var faces: [Face3] {
        switch self {
        case .box(let box): return box.faces
        case .ridge(let ridge): return ridge.faces
        case .cylinder(let cylinder): return cylinder.faces
        case .shape(let shape): return shape.faces
        }
    }

    /// Where the volume sits, for back-to-front sorting: how near the camera
    /// its centre is, then how high it stands. Elevation breaks the tie so a
    /// chimney standing on a hall draws after the hall rather than inside it.
    var depth: (CGFloat, CGFloat) {
        switch self {
        case .box(let box):
            return (box.x + box.width / 2 + box.y + box.depth / 2, box.z)
        case .ridge(let ridge):
            return (ridge.x + ridge.width / 2 + ridge.y + ridge.depth / 2, ridge.z)
        case .cylinder(let cylinder):
            return (cylinder.x + cylinder.y, cylinder.z)
        case .shape(let shape):
            return (shape.centre.x + shape.centre.y, shape.baseZ)
        }
    }
}

struct Solid {
    enum Style {
        /// Drawn in the building's own neon: dark faces, glowing creases.
        case structure
        /// A glowing solid in its own colour — a sign blade, a lit crown band.
        case lit(SKColor)
    }

    var volume: Volume
    var style: Style
    var tier: DetailTier = .far
}

/// A rectangular volume. `x`/`y` are the minimum plan corner, `z` the base.
struct Box {
    var x: CGFloat
    var y: CGFloat
    var z: CGFloat
    var width: CGFloat
    var depth: CGFloat
    var height: CGFloat

    var centre: Point3 {
        Point3(x: x + width / 2, y: y + depth / 2, z: z + height / 2)
    }

    var faces: [Face3] {
        let x0 = x, x1 = x + width
        let y0 = y, y1 = y + depth
        let z0 = z, z1 = z + height
        let c = centre
        func face(_ points: [Point3]) -> Face3 { Face3(points, outwardFrom: c) }
        return [
            face([.init(x: x0, y: y0, z: z1), .init(x: x1, y: y0, z: z1),
                  .init(x: x1, y: y1, z: z1), .init(x: x0, y: y1, z: z1)]),   // top
            face([.init(x: x1, y: y0, z: z0), .init(x: x1, y: y1, z: z0),
                  .init(x: x1, y: y1, z: z1), .init(x: x1, y: y0, z: z1)]),   // +x
            face([.init(x: x0, y: y1, z: z0), .init(x: x1, y: y1, z: z0),
                  .init(x: x1, y: y1, z: z1), .init(x: x0, y: y1, z: z1)]),   // +y
            face([.init(x: x0, y: y0, z: z0), .init(x: x1, y: y0, z: z0),
                  .init(x: x1, y: y0, z: z1), .init(x: x0, y: y0, z: z1)]),   // -x
            face([.init(x: x0, y: y0, z: z0), .init(x: x0, y: y1, z: z0),
                  .init(x: x0, y: y1, z: z1), .init(x: x0, y: y0, z: z1)]),   // -y
            face([.init(x: x0, y: y0, z: z0), .init(x: x1, y: y0, z: z0),
                  .init(x: x1, y: y1, z: z0), .init(x: x0, y: y1, z: z0)]),   // bottom
        ]
    }
}

/// A volume whose top collapses to a ridge line: a pitched roof, and — with
/// the ridge pushed all the way to one edge — a sawtooth.
///
/// One primitive covers both because a sawtooth *is* a gable with the ridge at
/// the wall, which is also why `ridgePosition` is a fraction rather than a
/// separate roof type.
struct Ridge {
    enum Axis { case x, y }

    var x: CGFloat
    var y: CGFloat
    var z: CGFloat
    var width: CGFloat
    var depth: CGFloat
    var height: CGFloat

    /// Which way the ridge line runs.
    var axis: Axis = .x

    /// Where the ridge sits across the perpendicular axis: 0.5 is a symmetric
    /// gable, 1 puts it at the far wall and makes a sawtooth.
    var ridgePosition: CGFloat = 0.5

    var centre: Point3 {
        Point3(x: x + width / 2, y: y + depth / 2, z: z + height / 2)
    }

    var faces: [Face3] {
        let x0 = x, x1 = x + width
        let y0 = y, y1 = y + depth
        let z0 = z, z1 = z + height
        let c = centre
        func face(_ points: [Point3]) -> Face3 { Face3(points, outwardFrom: c) }

        switch axis {
        case .x:
            let yr = y0 + depth * ridgePosition
            return [
                face([.init(x: x0, y: y0, z: z0), .init(x: x1, y: y0, z: z0),
                      .init(x: x1, y: yr, z: z1), .init(x: x0, y: yr, z: z1)]),
                face([.init(x: x0, y: yr, z: z1), .init(x: x1, y: yr, z: z1),
                      .init(x: x1, y: y1, z: z0), .init(x: x0, y: y1, z: z0)]),
                face([.init(x: x1, y: y0, z: z0), .init(x: x1, y: y1, z: z0),
                      .init(x: x1, y: yr, z: z1)]),
                face([.init(x: x0, y: y0, z: z0), .init(x: x0, y: y1, z: z0),
                      .init(x: x0, y: yr, z: z1)]),
                face([.init(x: x0, y: y0, z: z0), .init(x: x1, y: y0, z: z0),
                      .init(x: x1, y: y1, z: z0), .init(x: x0, y: y1, z: z0)]),
            ]
        case .y:
            let xr = x0 + width * ridgePosition
            return [
                face([.init(x: x0, y: y0, z: z0), .init(x: x0, y: y1, z: z0),
                      .init(x: xr, y: y1, z: z1), .init(x: xr, y: y0, z: z1)]),
                face([.init(x: xr, y: y0, z: z1), .init(x: xr, y: y1, z: z1),
                      .init(x: x1, y: y1, z: z0), .init(x: x1, y: y0, z: z0)]),
                face([.init(x: x0, y: y1, z: z0), .init(x: x1, y: y1, z: z0),
                      .init(x: xr, y: y1, z: z1)]),
                face([.init(x: x0, y: y0, z: z0), .init(x: x1, y: y0, z: z0),
                      .init(x: xr, y: y0, z: z1)]),
                face([.init(x: x0, y: y0, z: z0), .init(x: x1, y: y0, z: z0),
                      .init(x: x1, y: y1, z: z0), .init(x: x0, y: y1, z: z0)]),
            ]
        }
    }
}

/// Storage tanks and chimneys.
///
/// Built as an N-sided prism rather than as a true ellipse, so it reduces to
/// `Face3` like everything else and gets visibility and per-face shading for
/// free — a cylinder drawn as one flat silhouette looks pasted on next to
/// shaded boxes, and shading it properly would otherwise need its own code.
struct Cylinder {
    var x: CGFloat
    var y: CGFloat
    var z: CGFloat
    var radius: CGFloat
    var height: CGFloat

    /// Ten, not sixteen. A chimney is about six points across on screen at
    /// default zoom, where the difference between ten sides and sixteen is
    /// invisible and the difference in cost is not: every side is a face, and
    /// every visible face is a node that has to be drawn. This is
    /// `NeonStyle.minimumDetailSize`'s rule applied to geometry rather than to
    /// marks — detail below the size it can be seen at is not detail.
    var sides: Int = 10

    var centre: Point3 { Point3(x: x, y: y, z: z + height / 2) }

    var faces: [Face3] {
        let c = centre
        let ring = (0 ..< sides).map { index -> (CGFloat, CGFloat) in
            let angle = 2 * CGFloat.pi * CGFloat(index) / CGFloat(sides)
            return (x + radius * cos(angle), y + radius * sin(angle))
        }
        var faces = ring.indices.map { index -> Face3 in
            let (ax, ay) = ring[index]
            let (bx, by) = ring[(index + 1) % sides]
            return Face3([
                .init(x: ax, y: ay, z: z), .init(x: bx, y: by, z: z),
                .init(x: bx, y: by, z: z + height), .init(x: ax, y: ay, z: z + height),
            ], outwardFrom: c)
        }
        faces.append(Face3(ring.map { .init(x: $0.0, y: $0.1, z: z + height) }, outwardFrom: c))
        return faces
    }
}

// MARK: - Details

/// A lit rectangle on one face of a box: a window, a glazing band, a shopfront,
/// a flush sign.
///
/// Held in *face-local* coordinates and projected onto the face plane at draw
/// time, rather than as a screen-space rectangle. That difference is what stops
/// an isometric building reading as a crate with stickers on it — a pane has to
/// sit in the wall's plane and shear with it.
struct Panel {
    enum Face {
        /// The wall at maximum x, which faces down-and-right on screen.
        case right
        /// The wall at maximum y, which faces down-and-left.
        case left
    }

    var box: Box
    var face: Face
    /// Across the face, 0 to 1.
    var u0: CGFloat
    var u1: CGFloat
    /// Up the face, 0 to 1 of the box's height.
    var v0: CGFloat
    var v1: CGFloat
    var color: SKColor
    /// The farthest camera it is drawn at; see `DetailTier`.
    var tier: DetailTier = .far

    /// This panel, tagged for `tier`: `massing.panels.append(panel.at(.near))`.
    func at(_ tier: DetailTier) -> Panel {
        var copy = self
        copy.tier = tier
        return copy
    }

    /// The panel's four corners in world space.
    var corners: [Point3] {
        let z0 = box.z + box.height * v0
        let z1 = box.z + box.height * v1
        switch face {
        case .right:
            let x = box.x + box.width
            let a = box.y + box.depth * u0
            let b = box.y + box.depth * u1
            return [.init(x: x, y: a, z: z0), .init(x: x, y: b, z: z0),
                    .init(x: x, y: b, z: z1), .init(x: x, y: a, z: z1)]
        case .left:
            let y = box.y + box.depth
            let a = box.x + box.width * u0
            let b = box.x + box.width * u1
            return [.init(x: a, y: y, z: z0), .init(x: b, y: y, z: z0),
                    .init(x: b, y: y, z: z1), .init(x: a, y: y, z: z1)]
        }
    }

    /// Sorts with the volume it sits on, so a pane on a far wall is covered by
    /// a near building rather than floating over it.
    var depth: (CGFloat, CGFloat) {
        let base = box.x + box.width / 2 + box.y + box.depth / 2
        // A hair nearer than its own box, so it lands on top of its own wall.
        return (base + 0.001, box.z)
    }
}

/// A small mark drawn at a fixed screen size at a world point — the hazard
/// triangle, and anything else that is signage rather than architecture and
/// should not shear with a wall.
struct Badge {
    enum Kind { case warning }

    var at: Point3
    var size: CGFloat
    var kind: Kind = .warning
}

// MARK: - Winding safety

extension Face3 {
    /// Builds a face and forces its normal to point away from `centre`.
    ///
    /// Winding order decides a polygon's normal, and getting it wrong on one
    /// face out of six flips that face's visibility and shading with no
    /// compile error and no crash — it simply goes missing, or lights from the
    /// wrong side. Since every volume here knows its own centre, the sign can
    /// be checked rather than hand-verified, which removes the entire class of
    /// bug from the generators that follow.
    init(_ points: [Point3], outwardFrom centre: Point3) {
        self.init(points)
        let anchor = points.reduce(Point3(x: 0, y: 0, z: 0), +)
        let middle = Point3(
            x: anchor.x / CGFloat(points.count),
            y: anchor.y / CGFloat(points.count),
            z: anchor.z / CGFloat(points.count)
        )
        if normal.dot(middle - centre) < 0 {
            normal = Point3(x: -normal.x, y: -normal.y, z: -normal.z)
        }
    }
}
