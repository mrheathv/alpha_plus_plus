import CoreGraphics

/// **P2 of the building-detail plan: shapes beyond boxes, ridges and drums.**
///
/// Not called `Shape`, which is SwiftUI's: the clash broke type-checking in
/// every SwiftUI view in the module, as a crash rather than an error.
///
/// Every building here was made of three volumes, so anything else was faked:
/// a smooth taper as a stack of shrinking boxes, a dome as rings of cylinders,
/// a chamfered corner as a lit strip down a square one. `MassingShape` is one more
/// kind of `Volume` holding its faces already computed, and these constructors
/// make it:
///
/// | constructor | what it is | used for |
/// |---|---|---|
/// | `prism` | any convex plan raised to a height | octagons, chamfered plans, the diner's round end |
/// | `bevelledBox` | a box with its vertical edges cut | the Harbour Tower's corners, chamfered towers |
/// | `frustum` | a box whose top is smaller than its base | smooth tapers, battered podiums |
/// | `lathe` | a profile spun round a vertical axis | domes, water tanks, drum crowns |
/// | `arch` | a semicircular band of convex blocks | porticos, arcades, entrance canopies |
///
/// **One `Volume` case, not five.** Every consumer — visibility, shading, the
/// painter's sort, both renderers — already works on `faces`, so a shape
/// that arrives with its faces computed needs nothing new from any of them.
/// Five cases would have meant five branches in every `switch` over volumes.
///
/// **Every face is convex, and that is a rule, not a preference.** The Metal
/// renderer fills a face as a fan of triangles from its first corner, which
/// is only correct for a convex polygon. So an L- or U-shaped plan stays two
/// boxes, `prism` checks its plan is convex, and an arch is a ring of small
/// convex blocks rather than one concave band.
struct MassingShape {
    var faces: [Face3]
    /// For the painter's sort, with `baseZ`: how near the camera it stands.
    var centre: Point3
    var baseZ: CGFloat
    var topZ: CGFloat
}

extension MassingShape {

    // MARK: - Prism

    /// A convex plan, in either winding, raised from `z` by `height`.
    ///
    /// `precondition`s that the plan is convex: a concave one would render
    /// wrongly in Metal with no error anywhere, which is the worst way for it
    /// to fail.
    static func prism(plan: [CGPoint], z: CGFloat, height: CGFloat) -> MassingShape {
        precondition(plan.count >= 3 && isConvex(plan), "a prism's plan must be convex")
        let centre = Point3(x: plan.map(\.x).reduce(0, +) / CGFloat(plan.count),
                            y: plan.map(\.y).reduce(0, +) / CGFloat(plan.count),
                            z: z + height / 2)
        var faces: [Face3] = []
        for index in plan.indices {
            let a = plan[index], b = plan[(index + 1) % plan.count]
            faces.append(Face3([Point3(x: a.x, y: a.y, z: z), Point3(x: b.x, y: b.y, z: z),
                                Point3(x: b.x, y: b.y, z: z + height), Point3(x: a.x, y: a.y, z: z + height)],
                               outwardFrom: centre))
        }
        faces.append(Face3(plan.map { Point3(x: $0.x, y: $0.y, z: z + height) }, outwardFrom: centre))
        faces.append(Face3(plan.map { Point3(x: $0.x, y: $0.y, z: z) }, outwardFrom: centre))
        return MassingShape(faces: faces, centre: centre, baseZ: z, topZ: z + height)
    }

    /// Whether a polygon is convex: every turn goes the same way.
    static func isConvex(_ plan: [CGPoint]) -> Bool {
        var sign: CGFloat = 0
        for index in plan.indices {
            let a = plan[index], b = plan[(index + 1) % plan.count], c = plan[(index + 2) % plan.count]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            guard abs(cross) > 1e-9 else { continue }
            if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { return false }
        }
        return true
    }

    // MARK: - Bevelled box

    /// A box whose four vertical edges are cut back by `bevel`: an octagon in
    /// plan. The cut faces catch light the square corners did not have, which
    /// is what makes a tower read as machined rather than stacked.
    static func bevelledBox(_ box: Box, bevel: CGFloat) -> MassingShape {
        let b = min(bevel, min(box.width, box.depth) / 2 - 0.001)
        let x0 = box.x, x1 = box.x + box.width, y0 = box.y, y1 = box.y + box.depth
        let plan = [CGPoint(x: x0 + b, y: y0), CGPoint(x: x1 - b, y: y0), CGPoint(x: x1, y: y0 + b),
                    CGPoint(x: x1, y: y1 - b), CGPoint(x: x1 - b, y: y1), CGPoint(x: x0 + b, y: y1),
                    CGPoint(x: x0, y: y1 - b), CGPoint(x: x0, y: y0 + b)]
        return prism(plan: plan, z: box.z, height: box.height)
    }

    // MARK: - Frustum

    /// A box whose top is inset by `inset` on every side: a smooth taper, or
    /// a battered podium. The sloped sides face up a little, so they light
    /// differently from a vertical wall, which is the whole point.
    static func frustum(_ box: Box, topInset inset: CGFloat) -> MassingShape {
        let i = min(inset, min(box.width, box.depth) / 2 - 0.001)
        let z0 = box.z, z1 = box.z + box.height
        let bottom = [Point3(x: box.x, y: box.y, z: z0), Point3(x: box.x + box.width, y: box.y, z: z0),
                      Point3(x: box.x + box.width, y: box.y + box.depth, z: z0),
                      Point3(x: box.x, y: box.y + box.depth, z: z0)]
        let top = [Point3(x: box.x + i, y: box.y + i, z: z1), Point3(x: box.x + box.width - i, y: box.y + i, z: z1),
                   Point3(x: box.x + box.width - i, y: box.y + box.depth - i, z: z1),
                   Point3(x: box.x + i, y: box.y + box.depth - i, z: z1)]
        let centre = box.centre
        var faces: [Face3] = []
        for index in 0 ..< 4 {
            let next = (index + 1) % 4
            faces.append(Face3([bottom[index], bottom[next], top[next], top[index]], outwardFrom: centre))
        }
        faces.append(Face3(top, outwardFrom: centre))
        faces.append(Face3(bottom, outwardFrom: centre))
        return MassingShape(faces: faces, centre: centre, baseZ: z0, topZ: z1)
    }

    // MARK: - Lathe

    /// A profile spun round a vertical axis at (`x`, `y`): `profile` lists
    /// (radius, height above `z`) from the bottom up, and each step between
    /// two of them becomes a ring of `sides` quads. The last point's radius
    /// may be zero, closing it to a point; otherwise it is capped flat.
    ///
    /// Each ring's faces are checked against a point on the axis at that
    /// ring's own height, so any profile a building would use — a dome, a
    /// tank with a domed top, a drum that flares — comes out facing outward.
    static func lathe(x: CGFloat, y: CGFloat, z: CGFloat, profile: [(radius: CGFloat, height: CGFloat)],
                      sides: Int = 12) -> MassingShape {
        precondition(profile.count >= 2, "a lathe needs at least two profile points")
        func ring(_ radius: CGFloat, _ height: CGFloat) -> [Point3] {
            (0 ..< sides).map { index in
                let angle = 2 * CGFloat.pi * CGFloat(index) / CGFloat(sides)
                return Point3(x: x + radius * cos(angle), y: y + radius * sin(angle), z: z + height)
            }
        }
        var faces: [Face3] = []
        for step in 0 ..< profile.count - 1 {
            let lower = ring(profile[step].radius, profile[step].height)
            let upper = ring(profile[step + 1].radius, profile[step + 1].height)
            let axis = Point3(x: x, y: y, z: z + (profile[step].height + profile[step + 1].height) / 2)
            for index in 0 ..< sides {
                let next = (index + 1) % sides
                if profile[step + 1].radius < 1e-6 {
                    faces.append(Face3([lower[index], lower[next], upper[index]], outwardFrom: axis))
                } else {
                    faces.append(Face3([lower[index], lower[next], upper[next], upper[index]], outwardFrom: axis))
                }
            }
        }
        let last = profile[profile.count - 1]
        let bottomZ = z + profile[0].height
        let topZ = z + last.height
        let centre = Point3(x: x, y: y, z: (bottomZ + topZ) / 2)
        if last.radius > 1e-6 {
            faces.append(Face3(ring(last.radius, last.height), outwardFrom: Point3(x: x, y: y, z: topZ - 1)))
        }
        return MassingShape(faces: faces, centre: centre, baseZ: bottomZ, topZ: topZ)
    }

    /// A dome: a quarter-circle profile of `rings` steps.
    static func dome(x: CGFloat, y: CGFloat, z: CGFloat, radius: CGFloat, rings: Int = 4, sides: Int = 12) -> MassingShape {
        let profile = (0 ... rings).map { step -> (radius: CGFloat, height: CGFloat) in
            let angle = CGFloat(step) / CGFloat(rings) * .pi / 2
            return (radius * cos(angle), radius * sin(angle))
        }
        return lathe(x: x, y: y, z: z, profile: profile, sides: sides)
    }

    // MARK: - Arch

    /// A semicircular arch standing in a vertical plane, springing from `z`.
    ///
    /// `alongX` says which way the opening runs: true for an arch in the
    /// plane of y = `at.y` spanning x, false for one spanning y. `span` is the
    /// inner width, `band` the thickness of the ring, `depth` how deep it is.
    /// Built from `segments` convex blocks, each its own set of faces, because
    /// the band as a whole is concave (see the type's doc comment).
    static func arch(at: CGPoint, z: CGFloat, alongX: Bool, span: CGFloat, band: CGFloat, depth: CGFloat,
                     segments: Int = 8) -> MassingShape {
        let inner = span / 2, outer = span / 2 + band
        func point(_ radius: CGFloat, _ angle: CGFloat, _ offset: CGFloat) -> Point3 {
            let along = radius * cos(angle)
            let up = z + radius * sin(angle)
            return alongX ? Point3(x: at.x + along, y: at.y + offset, z: up)
                          : Point3(x: at.x + offset, y: at.y + along, z: up)
        }
        var faces: [Face3] = []
        for segment in 0 ..< segments {
            let a0 = CGFloat.pi * CGFloat(segment) / CGFloat(segments)
            let a1 = CGFloat.pi * CGFloat(segment + 1) / CGFloat(segments)
            let front = [point(inner, a0, 0), point(outer, a0, 0), point(outer, a1, 0), point(inner, a1, 0)]
            let back = [point(inner, a0, depth), point(outer, a0, depth), point(outer, a1, depth), point(inner, a1, depth)]
            let all = front + back
            let centre = Point3(x: all.map(\.x).reduce(0, +) / 8, y: all.map(\.y).reduce(0, +) / 8,
                                z: all.map(\.z).reduce(0, +) / 8)
            faces.append(Face3(front, outwardFrom: centre))
            faces.append(Face3(back, outwardFrom: centre))
            for edge in 0 ..< 4 {
                let next = (edge + 1) % 4
                faces.append(Face3([front[edge], front[next], back[next], back[edge]], outwardFrom: centre))
            }
        }
        let centre = alongX ? Point3(x: at.x, y: at.y + depth / 2, z: z + outer / 2)
                            : Point3(x: at.x + depth / 2, y: at.y, z: z + outer / 2)
        return MassingShape(faces: faces, centre: centre, baseZ: z, topZ: z + outer)
    }
}
