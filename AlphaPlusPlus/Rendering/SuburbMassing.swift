import SpriteKit

/// **The furniture of an 80s Miami suburb**, shared by housing and shops.
///
/// Low density used to fill its lot edge to edge, so a suburb looked like a
/// small downtown rather than a different kind of place. What says "low
/// density" is the ground between the buildings, and what says *Miami* is
/// what stands on it: palms, a lit pool, a sign on a tall pole. These are the
/// marks the low-end generators put in the open ground they now leave.
///
/// Shared for the reason `NeonStyle`'s primitives are: a palm in a front yard
/// and a palm by a motel pool are the same palm, and two copies would drift.
enum SuburbMassing {

    /// A palm: a slim trunk, a crown, and four fronds that droop away from
    /// it. A silhouette in the building's own neon, not a green: a park is the
    /// one green in the game, and a palm at night is a shape against the sky.
    ///
    /// **The fronds slope, and the first ones did not.** Flat, they were a
    /// plus sign on a pole and read as a telegraph pole. Each is a `Ridge`
    /// with its ridge pushed to the trunk end, so it falls away along its
    /// length — the droop is the whole of what makes it a palm.
    ///
    /// Reaches `0.36` past its trunk, so callers keep the trunk that far
    /// inside the lot.
    static func palm(at x: CGFloat, _ y: CGFloat, height: CGFloat, into massing: inout BuildingMassing) {
        massing.add(.cylinder(Cylinder(x: x, y: y, z: 0, radius: 0.04, height: height, sides: 6)))
        let reach: CGFloat = 0.36
        let blade: CGFloat = 0.13
        let droop: CGFloat = 0.16
        let z = height - droop + 0.04
        // Along x: high at the trunk end. `ridgePosition` runs across the
        // ridge's own axis, so a ridge along y with its line at one x-edge is
        // a wedge falling along x.
        massing.add(.ridge(Ridge(x: x, y: y - blade / 2, z: z, width: reach, depth: blade,
                                 height: droop, axis: .y, ridgePosition: 0)))
        massing.add(.ridge(Ridge(x: x - reach, y: y - blade / 2, z: z + 0.004, width: reach, depth: blade,
                                 height: droop, axis: .y, ridgePosition: 1)))
        massing.add(.ridge(Ridge(x: x - blade / 2, y: y, z: z + 0.008, width: blade, depth: reach,
                                 height: droop, axis: .x, ridgePosition: 0)))
        massing.add(.ridge(Ridge(x: x - blade / 2, y: y - reach, z: z + 0.012, width: blade, depth: reach,
                                 height: droop, axis: .x, ridgePosition: 1)))
        massing.add(.cylinder(Cylinder(x: x, y: y, z: height, radius: 0.07, height: 0.07, sides: 6)))
    }

    /// A lit pool with a deck around it. The one lit surface lying flat on the
    /// ground in a suburb, and the mark that makes it Miami.
    static func pool(_ area: Box, into massing: inout BuildingMassing) {
        massing.add(.box(Box(x: area.x - 0.04, y: area.y - 0.04, z: 0, width: area.width + 0.08,
                             depth: area.depth + 0.08, height: 0.02)))
        massing.add(.box(Box(x: area.x, y: area.y, z: 0.02, width: area.width, depth: area.depth,
                             height: 0.025)), .lit(NeonStyle.waterAccent))
    }

    /// A sign on a tall pole: the roadside mark of a strip, a diner, a motel
    /// or a petrol station, standing well above the low roofs around it.
    /// `stacked` adds a second, smaller board offset on top, which is the
    /// motel arrow's shape without needing a diagonal.
    static func poleSign(
        at x: CGFloat, _ y: CGFloat, height: CGFloat, color: SKColor, stacked: Bool,
        footprint: CGFloat, into massing: inout BuildingMassing
    ) {
        // The board is wider than the pole, so the pole is kept far enough in
        // for the board to stay on the lot.
        let x = min(max(x, 0.24), footprint - 0.24)
        massing.add(.cylinder(Cylinder(x: x, y: y, z: 0, radius: 0.035, height: height, sides: 6)))
        massing.add(.box(Box(x: x - 0.22, y: y - 0.04, z: height, width: 0.44, depth: 0.08, height: 0.28)),
                    .lit(color))
        if stacked {
            massing.add(.box(Box(x: x - 0.08, y: y - 0.035, z: height + 0.3, width: 0.3, depth: 0.07, height: 0.16)),
                        .lit(NeonStyle.litAccent))
        }
    }
}

/// **A lot laid out in its own axes.** Most low-end forms have a long side
/// and a short one, and which way they run should be a coin toss rather than
/// every duplex facing the same way. A form is written once in `a` (along)
/// and `b` (across), and this turns it into world boxes, faces and points —
/// so the random orientation costs one flag rather than two copies of every
/// coordinate. The back of the lot is low `a` and `b`, away from the camera,
/// so "front yard" is high `b`.
struct LotPlan {
    let alongX: Bool

    func box(_ a: CGFloat, _ b: CGFloat, _ lengthA: CGFloat, _ lengthB: CGFloat,
             z: CGFloat = 0, height: CGFloat) -> Box {
        alongX
            ? Box(x: a, y: b, z: z, width: lengthA, depth: lengthB, height: height)
            : Box(x: b, y: a, z: z, width: lengthB, depth: lengthA, height: height)
    }

    /// The wall that faces the camera across `a` (`.right`) or across `b`
    /// (`.left`), in plan terms.
    func face(_ face: Panel.Face) -> Panel.Face {
        alongX ? face : (face == .right ? .left : .right)
    }

    func point(_ a: CGFloat, _ b: CGFloat) -> (CGFloat, CGFloat) {
        alongX ? (a, b) : (b, a)
    }
}

extension ZoneMassing {

    /// **Forms are dealt, not rolled** — the rule `SkyscraperMassing.form`
    /// established, for any generator with several forms.
    ///
    /// For the canonical seeds the game draws, `options` is dealt in turn over
    /// the variants, starting at `salt` so two generators do not deal their
    /// first form to the same variant. That guarantees every form turns up,
    /// which a fair roll over thirty-two variants does not once there are more
    /// than a handful. Any other seed rolls on its own stream.
    static func dealt<T>(_ options: [T], seed: GridPosition, salt: Int) -> T {
        if seed.x >= 0, seed.x % 31 == 0 {
            let variant = seed.x / 31
            if variant < IsoTextureCache.variantCount, IsoTextureCache.canonicalSeed(for: variant) == seed {
                return options[(variant + salt) % options.count]
            }
        }
        var random = BuildingRandom(seed: seed, salt: 800 + salt)
        return random.pick(options)
    }
}
