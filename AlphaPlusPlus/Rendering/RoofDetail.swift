import SpriteKit

/// **P4 of the building-detail plan: roofs that are busy up close.**
///
/// From this camera a roof is the largest face a building shows, and the
/// close-up baseline showed most of them as empty planes with a box or two.
/// This dresses a building's exposed flat roofs with the clutter a real roof
/// carries, by zone:
///
/// | zone | on its roofs |
/// |---|---|
/// | housing | a water tank on legs, air-conditioning condensers, and on a big enough roof a lit pool |
/// | shops | HVAC units with fans, a satellite dish, and on the tallest roofs a lit helipad |
/// | industry | vents with caps, and a pipe run between them |
///
/// **A pass over the finished massing, not a change to every generator.**
/// There are some forty forms across the three zones; threading roof
/// clutter through each would be forty edits and forty chances to forget
/// one. Every roof is a box, so one pass finds them all: a box at least half
/// a tile across whose top is mostly uncovered (see `exposedRoofs`).
///
/// Everything is tagged `.near`, so the resting camera draws exactly what it
/// did, and nothing draws from a building's random stream — choices come from
/// `FacadeDetail.roll` on the roof's own geometry.
enum RoofDetail {

    static let tier: DetailTier = .near

    static func dress(_ massing: inout BuildingMassing, zone: ZoneType, footprint: CGFloat) {
        var roofs = exposedRoofs(in: massing)
        // The two biggest are enough: a tower's lower setbacks are small and
        // mostly hidden by the tower above them.
        roofs.sort { $0.width * $0.depth > $1.width * $1.depth }
        for (index, roof) in roofs.prefix(2).enumerated() {
            var spots = freeSpots(on: roof, in: massing)
            guard !spots.isEmpty else { continue }
            let roll = { (salt: Int) in FacadeDetail.roll(roof.x, roof.y, roof.z + roof.height, salt: salt + index * 10) }
            let top = roof.z + roof.height
            switch zone {
            case .residential:
                if let spot = spots.popLast() { waterTank(at: spot, z: top, into: &massing) }
                if let spot = spots.popLast(), roll(1) < 0.7 { condenser(at: spot, z: top, into: &massing) }
                if roof.width * roof.depth > 1.2, roof.z > 1, roll(2) < 0.35 {
                    pool(on: roof, into: &massing)
                } else if let spot = spots.popLast(), roll(3) < 0.5 {
                    condenser(at: spot, z: top, into: &massing)
                }
            case .commercial:
                if let spot = spots.popLast() { hvac(at: spot, z: top, into: &massing) }
                if let spot = spots.popLast(), roll(4) < 0.6 { dish(at: spot, z: top, into: &massing) }
                if let spot = spots.popLast(), roll(5) < 0.5 { hvac(at: spot, z: top, into: &massing) }
                if index == 0, top > 4, roll(6) < 0.5 { helipad(on: roof, into: &massing) }
            case .industrial:
                var vents: [CGPoint] = []
                for salt in 7 ..< 10 {
                    guard let spot = spots.popLast(), roll(salt) < 0.8 else { continue }
                    vent(at: spot, z: top, into: &massing)
                    vents.append(spot)
                }
                if vents.count >= 2 { pipe(from: vents[0], to: vents[1], z: top, into: &massing) }
            default:
                break
            }
        }
    }

    // MARK: - Finding roofs

    /// Boxes at least half a tile across whose top is mostly open: the roofs
    /// a camera can see and something can sit on.
    ///
    /// **Measured by how much is covered, not by what stands at the centre.**
    /// The first version asked whether anything stood on a roof's centre, and
    /// found almost no roofs at all: most carry a parapet or a lit crown band
    /// across their whole top. Those thin slabs are candidates themselves, so
    /// the parapet's top is the roof, and a roof counts as exposed while less
    /// than half of it is covered.
    static func exposedRoofs(in massing: BuildingMassing) -> [Box] {
        let boxes: [Box] = massing.solids.compactMap { solid in
            guard solid.tier == .far, case .box(let box) = solid.volume else { return nil }
            return box
        }
        return boxes.filter { box in
            guard min(box.width, box.depth) >= 0.5, box.height >= 0.03 else { return false }
            let top = box.z + box.height
            let roof = CGRect(x: box.x, y: box.y, width: box.width, height: box.depth)
            let covered = massing.solids.reduce(CGFloat(0)) { sum, solid in
                guard let (base, rect) = footprint(of: solid.volume), abs(base - top) < 0.02 else { return sum }
                let overlap = rect.intersection(roof)
                return overlap.isNull ? sum : sum + overlap.width * overlap.height
            }
            return covered < roof.width * roof.height * 0.5
        }
    }

    /// Candidate spots in a roof's outer band, clear of anything already
    /// standing on it. Ordered so `popLast` takes the nearest the camera
    /// first, where clutter is seen rather than hidden behind a crown.
    static func freeSpots(on roof: Box, in massing: BuildingMassing) -> [CGPoint] {
        let top = roof.z + roof.height
        let margin: CGFloat = 0.14
        let occupied: [CGRect] = massing.solids.compactMap { solid in
            guard let (base, rect) = footprint(of: solid.volume), abs(base - top) < 0.02 else { return nil }
            return rect.insetBy(dx: -0.12, dy: -0.12)
        }
        var spots: [CGPoint] = []
        for u in [0.18, 0.5, 0.82] as [CGFloat] {
            for v in [0.18, 0.5, 0.82] as [CGFloat] where !(u == 0.5 && v == 0.5) {
                let point = CGPoint(x: roof.x + margin + (roof.width - margin * 2) * u,
                                    y: roof.y + margin + (roof.depth - margin * 2) * v)
                if !occupied.contains(where: { $0.contains(point) }) { spots.append(point) }
            }
        }
        return spots.sorted { $0.x + $0.y < $1.x + $1.y }
    }

    /// A volume's base height and plan rectangle, for the clearance checks.
    private static func footprint(of volume: Volume) -> (CGFloat, CGRect)? {
        switch volume {
        case .box(let b): return (b.z, CGRect(x: b.x, y: b.y, width: b.width, height: b.depth))
        case .ridge(let r): return (r.z, CGRect(x: r.x, y: r.y, width: r.width, height: r.depth))
        case .cylinder(let c): return (c.z, CGRect(x: c.x - c.radius, y: c.y - c.radius,
                                                   width: c.radius * 2, height: c.radius * 2))
        case .shape(let s):
            let xs = s.faces.flatMap { $0.points.map(\.x) }, ys = s.faces.flatMap { $0.points.map(\.y) }
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return nil }
            return (s.baseZ, CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        }
    }

    // MARK: - The clutter

    /// A water tank on four legs, the housing roof's mark since the
    /// elevation art: a lathed drum with a conical cap.
    static func waterTank(at spot: CGPoint, z: CGFloat, into massing: inout BuildingMassing) {
        let leg: CGFloat = 0.12
        for (dx, dy) in [(-0.07, -0.07), (0.05, -0.07), (-0.07, 0.05), (0.05, 0.05)] as [(CGFloat, CGFloat)] {
            massing.add(.box(Box(x: spot.x + dx, y: spot.y + dy, z: z, width: 0.02, depth: 0.02,
                                 height: leg + dx * 0.001)), from: tier)
        }
        massing.add(.shape(MassingShape.lathe(x: spot.x, y: spot.y, z: z + leg,
                                              profile: [(0.1, 0), (0.1, 0.16), (0.11, 0.17), (0, 0.24)], sides: 10)),
                    from: tier)
    }

    /// An air-conditioning condenser: a low box with a fan grille on top.
    static func condenser(at spot: CGPoint, z: CGFloat, into massing: inout BuildingMassing) {
        massing.add(.box(Box(x: spot.x - 0.08, y: spot.y - 0.06, z: z, width: 0.16, depth: 0.12, height: 0.08)),
                    from: tier)
        massing.add(.cylinder(Cylinder(x: spot.x, y: spot.y, z: z + 0.08, radius: 0.045, height: 0.012, sides: 8)),
                    from: tier)
    }

    /// An HVAC unit: a bigger box, two fans.
    static func hvac(at spot: CGPoint, z: CGFloat, into massing: inout BuildingMassing) {
        massing.add(.box(Box(x: spot.x - 0.12, y: spot.y - 0.08, z: z, width: 0.24, depth: 0.16, height: 0.1)),
                    from: tier)
        for dx in [-0.055, 0.055] as [CGFloat] {
            massing.add(.cylinder(Cylinder(x: spot.x + dx, y: spot.y, z: z + 0.1, radius: 0.045, height: 0.012 + dx * 0.01,
                                           sides: 8)), from: tier)
        }
    }

    /// A satellite dish on a post: a shallow bowl, lathed, facing up.
    static func dish(at spot: CGPoint, z: CGFloat, into massing: inout BuildingMassing) {
        massing.add(.cylinder(Cylinder(x: spot.x, y: spot.y, z: z, radius: 0.015, height: 0.1, sides: 6)), from: tier)
        massing.add(.shape(MassingShape.lathe(x: spot.x, y: spot.y, z: z + 0.1,
                                              profile: [(0.02, 0), (0.08, 0.025), (0.11, 0.05)], sides: 10)),
                    from: tier)
    }

    /// A roof vent: a stub with a wider cap.
    static func vent(at spot: CGPoint, z: CGFloat, into massing: inout BuildingMassing) {
        massing.add(.cylinder(Cylinder(x: spot.x, y: spot.y, z: z, radius: 0.04, height: 0.14, sides: 8)), from: tier)
        massing.add(.cylinder(Cylinder(x: spot.x, y: spot.y, z: z + 0.14, radius: 0.065, height: 0.03, sides: 8)),
                    from: tier)
    }

    /// A pipe run between two roof items, raised on the roof so it reads as
    /// pipework rather than a stripe.
    static func pipe(from a: CGPoint, to b: CGPoint, z: CGFloat, into massing: inout BuildingMassing) {
        let t: CGFloat = 0.03
        let lift: CGFloat = 0.06
        massing.add(.box(Box(x: min(a.x, b.x), y: a.y - t / 2, z: z + lift, width: max(abs(b.x - a.x), t),
                             depth: t, height: t)), from: tier)
        massing.add(.box(Box(x: b.x - t / 2, y: min(a.y, b.y), z: z + lift + 0.001, width: t,
                             depth: max(abs(b.y - a.y), t), height: t)), from: tier)
    }

    /// A rooftop pool on a high housing roof, lit, with a deck: Miami at
    /// altitude. It takes the middle of the roof, so it replaces clutter
    /// rather than sitting among it.
    static func pool(on roof: Box, into massing: inout BuildingMassing) {
        let top = roof.z + roof.height
        let width = roof.width * 0.4, depth = roof.depth * 0.3
        let x = roof.x + roof.width / 2 - width / 2, y = roof.y + roof.depth / 2 - depth / 2
        massing.add(.box(Box(x: x - 0.04, y: y - 0.04, z: top, width: width + 0.08, depth: depth + 0.08, height: 0.02)),
                    from: tier)
        massing.add(.box(Box(x: x, y: y, z: top + 0.02, width: width, depth: depth, height: 0.02)),
                    .lit(NeonStyle.waterAccent), from: tier)
    }

    /// A helipad on a tall commercial roof: a raised deck with a lit rim and
    /// a lit H, each stroke a thin lit bar lying on the deck.
    static func helipad(on roof: Box, into massing: inout BuildingMassing) {
        let size = min(roof.width, roof.depth) * 0.6
        guard size >= 0.5 else { return }
        let x = roof.x + roof.width / 2 - size / 2, y = roof.y + roof.depth / 2 - size / 2
        let top = roof.z + roof.height
        massing.add(.box(Box(x: x, y: y, z: top, width: size, depth: size, height: 0.04)), from: tier)
        let rim = NeonStyle.signColor(for: GridPosition(x: Int(roof.x * 100), y: Int(roof.y * 100)), salt: 21)
        let s = size * 0.36, bar = size * 0.07
        let cx = x + size / 2, cy = y + size / 2
        for (dx, dy, w, d) in [(-s / 2, -s / 2, bar, s), (s / 2 - bar, -s / 2, bar, s), (-s / 2, -bar / 2, s, bar)]
            as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            massing.add(.box(Box(x: cx + dx, y: cy + dy, z: top + 0.04, width: w, depth: d, height: 0.008)),
                        .lit(rim), from: tier)
        }
    }
}
