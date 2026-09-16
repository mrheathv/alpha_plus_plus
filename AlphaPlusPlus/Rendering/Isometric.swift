import SpriteKit

/// A point in world space, in tile units. `z` is up.
struct Point3: Equatable {
    var x: CGFloat
    var y: CGFloat
    var z: CGFloat

    static func + (lhs: Point3, rhs: Point3) -> Point3 {
        Point3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    static func - (lhs: Point3, rhs: Point3) -> Point3 {
        Point3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    func dot(_ other: Point3) -> CGFloat { x * other.x + y * other.y + z * other.z }

    var length: CGFloat { sqrt(dot(self)) }

    var normalized: Point3 {
        let l = length
        guard l > 0 else { return self }
        return Point3(x: x / l, y: y / l, z: z / l)
    }
}

/// One flat polygon of a volume, with the direction it faces.
struct Face3 {
    var points: [Point3]
    var normal: Point3

    /// Newell's method — works for any planar polygon and does not care how
    /// many vertices it has or which order they were listed in, unlike taking
    /// the cross product of the first two edges (which silently produces
    /// garbage for a vertex that happens to be collinear with its neighbours).
    init(_ points: [Point3]) {
        self.points = points
        var normal = Point3(x: 0, y: 0, z: 0)
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            normal.x += (current.y - next.y) * (current.z + next.z)
            normal.y += (current.z - next.z) * (current.x + next.x)
            normal.z += (current.x - next.x) * (current.y + next.y)
        }
        self.normal = normal.normalized
    }
}

/// The 2:1 isometric projection: world space to screen space, and the volumes
/// that get drawn in it.
///
/// **Why this exists.** The game drew its ground from directly overhead and its
/// buildings as front elevations, as if seen from the street — two viewpoints
/// in one picture, which is why a building read as a lit card standing on a
/// floor plan. A shape reads as a volume when you can see two of its faces at
/// once, and an elevation only ever has one.
///
/// It also suits this art direction rather than fighting it. Neon is an *edge*
/// treatment, and in elevation a box has no edges to light, only a silhouette
/// to trace. In isometric the same box shows three faces and the creases
/// between them.
///
/// **A struct, not an enum of constants**, for the same reason `GridLayout` is:
/// the render tools want to draw the same city at several scales, and a global
/// would make that a mutation.
///
/// **The axes.** `x` runs down-and-right on screen, `y` down-and-left, `z`
/// straight up. A tile is twice as wide as it is tall — the classic 2:1, which
/// keeps every ground edge on an exact 2-pixels-across-1-down slope so
/// diagonals stay crisp instead of shimmering.
struct Isometric {

    /// Width of one tile's diamond, in points. Its height is half this.
    var tileWidth: CGFloat = 64

    /// Screen points per one tile-unit of elevation.
    ///
    /// Deliberately independent of `tileHeight`. Tying vertical scale to the
    /// tile's own squash makes every building squat, because a storey is not
    /// as tall as a lot is wide. This is the single knob that decides whether
    /// the city reads as a model village or a skyline.
    var heightUnit: CGFloat = 30

    var tileHeight: CGFloat { tileWidth / 2 }

    /// Direction from the scene toward the camera.
    ///
    /// Plan angle is 45° by construction — that is what isometric *is* — and
    /// the elevation is about 35°, which is what a 2:1 tile implies. Used to
    /// decide which faces of a volume are visible at all.
    static let toCamera = Point3(x: -0.58, y: -0.58, z: 0.57).normalized

    /// Direction the key light comes *from*. Deliberately not the camera
    /// direction: lighting a face by how much it faces the viewer flattens
    /// everything, because the faces you can see are exactly the faces facing
    /// you. Offsetting the light gives the two visible side faces genuinely
    /// different values, which is what makes a box read as solid rather than
    /// as three panels that happen to meet.
    static let keyLight = Point3(x: -0.35, y: -0.8, z: 0.49).normalized

    // MARK: - Projection

    func project(_ point: Point3) -> CGPoint {
        CGPoint(
            x: (point.x - point.y) * tileWidth / 2,
            y: -(point.x + point.y) * tileHeight / 2 + point.z * heightUnit
        )
    }

    func project(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint {
        project(Point3(x: x, y: y, z: z))
    }

    /// Inverse of `project` for points on the ground plane (`z == 0`) — which
    /// tile does this screen point fall in?
    ///
    /// Needed because click-to-place cannot survive the projection change
    /// otherwise: top-down, `position(for:)` is an integer divide, because
    /// squares tile trivially. Diamonds do not.
    func groundPosition(for point: CGPoint) -> (x: CGFloat, y: CGFloat) {
        // Solve the two projection equations for x and y with z fixed at 0.
        let a = point.x / (tileWidth / 2)      // = x - y
        let b = -point.y / (tileHeight / 2)    // = x + y
        return (x: (b + a) / 2, y: (b - a) / 2)
    }

    func path(_ points: [Point3]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: project(first))
        points.dropFirst().forEach { path.addLine(to: project($0)) }
        path.closeSubpath()
        return path
    }

    /// One tile of ground, as a diamond.
    func tileDiamond(x: CGFloat, y: CGFloat, size: CGFloat = 1, inset: CGFloat = 0) -> CGPath {
        path([
            Point3(x: x + inset, y: y + inset, z: 0),
            Point3(x: x + size - inset, y: y + inset, z: 0),
            Point3(x: x + size - inset, y: y + size - inset, z: 0),
            Point3(x: x + inset, y: y + size - inset, z: 0),
        ])
    }

    // MARK: - Visibility and shading

    /// Whether a face points anywhere toward the camera.
    ///
    /// Computed from the face's own normal rather than hardcoded per volume
    /// type. The spike hardcoded "top, right, left", which is correct for a box
    /// and wrong the moment anything slopes: whether the far slope of a gable
    /// roof is visible depends on whether it is steeper than about 45°, and no
    /// fixed list of faces can express that.
    static func isVisible(_ face: Face3) -> Bool {
        face.normal.dot(toCamera) > 0.001
    }

    /// 0 (facing fully away from the key light) to 1 (facing straight into it).
    static func shade(_ face: Face3) -> CGFloat {
        max(0, min(1, (face.normal.dot(keyLight) + 0.25) / 1.25))
    }

    // MARK: - Ordering

    /// Back-to-front order — the painter's algorithm an isometric scene needs
    /// and a top-down one does not.
    ///
    /// Top-down, nothing overlaps, so every tile sprite can sit at
    /// `zPosition = 0`, which is exactly what `GameScene` does today. In
    /// isometric a near volume must cover a far one, and what decides "near"
    /// is `x + y`. Elevation breaks the tie, so a chimney standing on a hall
    /// draws after the hall it stands on rather than being swallowed by it.
    ///
    /// This is one of the two things `GridLayout`'s doc comment misses when it
    /// claims a switch to isometric changes one file; the other is the click
    /// inverse above.
    static func sorted<T>(_ items: [T], depth: (T) -> (CGFloat, CGFloat)) -> [T] {
        items.enumerated()
            .sorted { lhs, rhs in
                let a = depth(lhs.element), b = depth(rhs.element)
                if a.0 != b.0 { return a.0 < b.0 }
                if a.1 != b.1 { return a.1 < b.1 }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
