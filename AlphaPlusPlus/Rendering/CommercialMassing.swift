import SpriteKit

/// Commerce, described as volumes.
///
/// `CommercialBuilding`'s vocabulary: continuous glazing bands rather than
/// housing's punched grid, a glazed podium, projecting signage, and an
/// illuminated crown where housing puts machinery. Tier 1 still picks between
/// three street forms — a strip of shops, a corner unit, a shop with a flat
/// over it — because varying numbers is not variety, and low density is where
/// most of a city's map area sits.
///
/// **The projecting sign is the mark that gains most from the projection.** In
/// elevation a blade sign was a bright rectangle beside a silhouette, which is
/// indistinguishable from a rectangle *on* the silhouette; the only thing
/// saying it projected was that it overlapped the outline. Here it is a volume
/// standing off the wall, and it casts its own glow into the air beside the
/// building.
enum CommercialMassing {

    private enum Form { case strip, cornerUnit, podiumTower }

    static func make(tier: Int, seed: GridPosition, footprint: CGFloat = 2) -> BuildingMassing {
        var random = BuildingRandom(seed: seed, salt: 200 + tier)
        var massing = BuildingMassing()
        if ZoneMassing.isLandmark(tier: tier, seed: seed) {
            spire(seed: seed, footprint: footprint, into: &massing, random: &random)
            return massing
        }
        let form: Form = tier >= 2 ? .podiumTower : random.pick([.strip, .cornerUnit, .podiumTower])

        switch form {
        case .strip:
            strip(seed: seed, footprint: footprint, into: &massing, random: &random)
        case .cornerUnit:
            cornerUnit(seed: seed, footprint: footprint, into: &massing, random: &random)
        case .podiumTower:
            podiumTower(tier: tier, seed: seed, footprint: footprint, into: &massing, random: &random)
        }
        return massing
    }

    // MARK: - Forms

    /// A single wide low block: the strip of shops. All shopfront along the
    /// street, a fascia sign above it, rooftop plant, and no storey over it —
    /// which is what makes it read as a different building rather than a short
    /// tower.
    private static func strip(
        seed: GridPosition,
        footprint: CGFloat,
        into massing: inout BuildingMassing,
        random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.06
        let body = Box(x: margin, y: margin, z: 0,
                       width: footprint - margin * 2, depth: footprint - margin * 2,
                       height: CGFloat(random.value(in: 0.78 ... 0.98)))
        massing.add(.box(body))
        shopfront(on: body, share: 0.2 ... 0.46, into: &massing)

        // The fascia: a long lit band across the upper face, the mark that says
        // "several shops behind one frontage".
        let color = NeonStyle.signColor(for: seed)
        for face in [Panel.Face.right, .left] {
            massing.panels.append(Panel(box: body, face: face, u0: 0.12, u1: 0.88,
                                        v0: 0.62, v1: 0.86, color: color))
        }
        massing.add(.box(Box(x: body.x - 0.03, y: body.y - 0.03, z: body.height,
                             width: body.width + 0.06, depth: body.depth + 0.06, height: 0.08)))
        roofPlant(on: body, count: random.int(in: 1 ... 3), into: &massing, random: &random)
    }

    /// A low shopfront block with one narrow taller element on one end: the
    /// corner unit. The asymmetry is the point — nothing else in the commercial
    /// vocabulary is off-centre.
    private static func cornerUnit(
        seed: GridPosition,
        footprint: CGFloat,
        into massing: inout BuildingMassing,
        random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.08
        let base = Box(x: margin, y: margin, z: 0,
                       width: footprint - margin * 2, depth: footprint - margin * 2,
                       height: CGFloat(random.value(in: 0.5 ... 0.66)))
        massing.add(.box(base))
        shopfront(on: base, share: 0.18 ... 0.6, into: &massing)

        let size = CGFloat(random.value(in: 0.7 ... 0.95))
        let alongX = random.chance(0.5)
        let far = random.chance(0.5)
        let offset = far ? footprint - margin - size : margin
        let tower = alongX
            ? Box(x: offset, y: margin, z: base.height, width: size, depth: base.depth, height: CGFloat(random.value(in: 0.7 ... 1.1)))
            : Box(x: margin, y: offset, z: base.height, width: base.width, depth: size, height: CGFloat(random.value(in: 0.7 ... 1.1)))
        massing.add(.box(tower))
        glazingBands(on: tower, into: &massing, random: &random)
        bladeSign(on: tower, color: NeonStyle.signColor(for: seed), footprint: footprint,
                  into: &massing, random: &random)
        crown(on: tower, tier: 1, seed: seed, into: &massing, random: &random)
    }

    /// The podium-and-tower form: a glazed base with a slimmer block above,
    /// optionally set back, crowned and signed.
    private static func podiumTower(
        tier: Int,
        seed: GridPosition,
        footprint: CGFloat,
        into massing: inout BuildingMassing,
        random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.06
        let podium = Box(x: margin, y: margin, z: 0,
                         width: footprint - margin * 2, depth: footprint - margin * 2,
                         height: CGFloat(random.value(in: tier == 1 ? 0.55 ... 0.72 : 0.4 ... 0.56)))
        massing.add(.box(podium))
        shopfront(on: podium, share: 0.18 ... 0.62, into: &massing)

        // Roughly four metres a storey against an eight-metre tile: a tier-3
        // tower is six to eight floors over its podium.
        var inset = margin + CGFloat(random.value(in: tier >= 3 ? 0.3 ... 0.45 : 0.16 ... 0.3))
        var z = podium.height
        var height = CGFloat(random.value(in: tier >= 3 ? 2.2 ... 3.0 : (tier == 2 ? 1.2 ... 1.8 : 0.5 ... 0.85)))

        var tower = Box(x: inset, y: inset, z: z,
                        width: footprint - inset * 2, depth: footprint - inset * 2, height: height)
        massing.add(.box(tower))
        glazingBands(on: tower, into: &massing, random: &random)
        bladeSign(on: tower, color: NeonStyle.signColor(for: seed), footprint: footprint,
                  into: &massing, random: &random)

        // Setbacks, so the skyline is not a row of identical slabs.
        let setbacks = tier >= 3 ? random.int(in: 0 ... 2) : (tier == 2 && random.chance(0.55) ? 1 : 0)
        for _ in 0 ..< setbacks {
            z = tower.z + tower.height
            inset += CGFloat(random.value(in: 0.12 ... 0.24))
            height = CGFloat(random.value(in: 0.4 ... 0.75))
            guard footprint - inset * 2 > 0.3 else { break }
            tower = Box(x: inset, y: inset, z: z,
                        width: footprint - inset * 2, depth: footprint - inset * 2, height: height)
            massing.add(.box(tower))
            glazingBands(on: tower, into: &massing, random: &random)
        }
        crown(on: tower, tier: tier, seed: seed, into: &massing, random: &random)
    }

    /// **The spire: commerce's landmark, and the tallest thing in the game.**
    ///
    /// An ordinary tier-3 tower stands three to four and a half tile units.
    /// This one reaches six to eight, and it gets there by being *thin* rather
    /// than by being a bigger box — a shaft a third of its lot across, which
    /// is a proportion nothing else here has. That is what makes it read as a
    /// landmark from across the map rather than as a lucky roll on the height
    /// range: at the zoom this game is played at you cannot compare two
    /// heights side by side, but you can see at a glance that one silhouette
    /// is a different *shape*.
    ///
    /// It keeps commerce's own vocabulary throughout — a glazed podium with a
    /// shopfront, continuous bands wrapping the corner, a lit crown — because
    /// a landmark that stopped looking like its zone would be a fourth zone.
    /// What it adds is the one mark reserved for it: a mast standing clear of
    /// the crown, lit at the tip.
    private static func spire(
        seed: GridPosition,
        footprint: CGFloat,
        into massing: inout BuildingMassing,
        random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.06
        let podium = Box(x: margin, y: margin, z: 0,
                         width: footprint - margin * 2, depth: footprint - margin * 2,
                         height: CGFloat(random.value(in: 0.42 ... 0.6)))
        massing.add(.box(podium))
        shopfront(on: podium, share: 0.18 ... 0.66, into: &massing)

        // The shaft. Inset hard — this is the whole mark.
        var inset = margin + CGFloat(random.value(in: 0.55 ... 0.72))
        var z = podium.height
        var shaft = Box(x: inset, y: inset, z: z,
                        width: footprint - inset * 2, depth: footprint - inset * 2,
                        height: CGFloat(random.value(in: 3.6 ... 4.8)))
        massing.add(.box(shaft))
        glazingBands(on: shaft, into: &massing, random: &random)
        bladeSign(on: shaft, color: NeonStyle.signColor(for: seed), footprint: footprint,
                  into: &massing, random: &random)

        // Two or three short steps, each narrower than the last: the crowned
        // setback, which is what turns a post into a spire.
        for step in 0 ..< random.int(in: 2 ... 3) {
            z = shaft.z + shaft.height
            inset += CGFloat(random.value(in: 0.05 ... 0.09))
            guard footprint - inset * 2 > 0.16 else { break }
            shaft = Box(x: inset, y: inset, z: z,
                        width: footprint - inset * 2, depth: footprint - inset * 2,
                        height: CGFloat(random.value(in: 0.3 ... 0.5)))
            massing.add(.box(shaft))
            if step == 0 { glazingBands(on: shaft, into: &massing, random: &random) }
        }

        let top = shaft.z + shaft.height
        // A lit collar under the mast, which is what stops the mast reading as
        // a hair sticking out of a box — the same argument the balcony won
        // over a railing: the shape has to carry the mark.
        massing.add(.box(Box(x: shaft.x - 0.05, y: shaft.y - 0.05, z: top,
                             width: shaft.width + 0.1, depth: shaft.depth + 0.1, height: 0.1)),
                    .lit(NeonStyle.signColor(for: seed, salt: 5)))
        let mastHeight = CGFloat(random.value(in: 0.9 ... 1.4))
        massing.add(.cylinder(Cylinder(
            x: shaft.x + shaft.width / 2, y: shaft.y + shaft.depth / 2, z: top + 0.1,
            radius: 0.035, height: mastHeight, sides: 8
        )))
        // The tip. One lit volume, deliberately the highest thing in the city.
        massing.add(.cylinder(Cylinder(
            x: shaft.x + shaft.width / 2, y: shaft.y + shaft.depth / 2,
            z: top + 0.1 + mastHeight, radius: 0.07, height: 0.12, sides: 8
        )), .lit(NeonStyle.litAccent))
    }

    // MARK: - Parts

    /// The ground floor: one unbroken slab of light per wall, which is the
    /// brightest and most zone-identifying mark commerce has.
    private static func shopfront(on box: Box, share: ClosedRange<CGFloat>, into massing: inout BuildingMassing) {
        for face in [Panel.Face.right, .left] {
            massing.panels.append(Panel(box: box, face: face, u0: 0.06, u1: 0.94,
                                        v0: share.lowerBound, v1: share.upperBound,
                                        color: NeonStyle.litAccent))
        }
    }

    /// Unbroken horizontal ribbons running the full width of both walls and
    /// wrapping the corner — the single strongest difference from housing's
    /// grid of separate little windows, and one that survives greyscale.
    private static func glazingBands(on box: Box, into massing: inout BuildingMassing, random: inout BuildingRandom) {
        let bands = max(1, Int((box.height / 0.34).rounded()))
        guard bands >= 1 else { return }
        for face in [Panel.Face.right, .left] {
            for band in 0 ..< bands where random.chance(0.85) {
                massing.panels.append(Panel(
                    box: box, face: face, u0: 0.1, u1: 0.9,
                    v0: (CGFloat(band) + 0.2) / CGFloat(bands),
                    v1: (CGFloat(band) + 0.68) / CGFloat(bands),
                    color: NeonStyle.windowColor(row: band, column: 0, salt: 7)
                ))
            }
        }
    }

    /// A sign blade standing off one wall.
    ///
    /// A real volume, not a bright rectangle beside a silhouette — see the
    /// type's doc comment. Kept inside the lot, since the tower it hangs off
    /// is inset and the blade is thin.
    private static func bladeSign(
        on tower: Box,
        color: SKColor,
        footprint: CGFloat,
        into massing: inout BuildingMassing,
        random: inout BuildingRandom
    ) {
        guard tower.height > 0.6, random.chance(0.65) else { return }
        let thickness: CGFloat = 0.07
        let stand: CGFloat = 0.1
        let height = tower.height * CGFloat(random.value(in: 0.35 ... 0.6))
        let z = tower.z + tower.height * CGFloat(random.value(in: 0.12 ... 0.3))

        let onX = random.chance(0.5)
        let blade = onX
            ? Box(x: tower.x + tower.width, y: tower.y + tower.depth * CGFloat(random.value(in: 0.2 ... 0.6)),
                  z: z, width: stand, depth: thickness, height: height)
            : Box(x: tower.x + tower.width * CGFloat(random.value(in: 0.2 ... 0.6)), y: tower.y + tower.depth,
                  z: z, width: thickness, depth: stand, height: height)
        guard blade.x + blade.width <= footprint, blade.y + blade.depth <= footprint else { return }
        massing.add(.box(blade), .lit(color))
    }

    /// Offices light their tops: a glowing band, a stepped cap, a mast, or a
    /// plain parapet with a lift motor room.
    private static func crown(
        on tower: Box,
        tier: Int,
        seed: GridPosition,
        into massing: inout BuildingMassing,
        random: inout BuildingRandom
    ) {
        enum Style: CaseIterable { case litBand, steppedCap, mast, parapet }
        let style: Style = tier == 1 ? random.pick([.litBand, .steppedCap, .parapet]) : random.pick(Style.allCases)
        let top = tower.z + tower.height

        switch style {
        case .litBand:
            massing.add(.box(Box(x: tower.x - 0.03, y: tower.y - 0.03, z: top,
                                 width: tower.width + 0.06, depth: tower.depth + 0.06, height: 0.09)),
                        .lit(NeonStyle.signColor(for: seed, salt: 3)))
        case .steppedCap:
            var box = tower
            var z = top
            for step in 0 ..< 2 {
                let shrink = CGFloat(0.16 + CGFloat(step) * 0.1)
                guard box.width - shrink * 2 > 0.2 else { break }
                box = Box(x: box.x + shrink, y: box.y + shrink, z: z,
                          width: box.width - shrink * 2, depth: box.depth - shrink * 2, height: 0.13)
                massing.add(.box(box))
                z += box.height
            }
        case .mast:
            massing.add(.box(Box(x: tower.x - 0.02, y: tower.y - 0.02, z: top,
                                 width: tower.width + 0.04, depth: tower.depth + 0.04, height: 0.07)))
            massing.add(.cylinder(Cylinder(
                x: tower.x + tower.width / 2, y: tower.y + tower.depth / 2, z: top + 0.07,
                radius: 0.035, height: CGFloat(random.value(in: 0.3 ... 0.55))
            )))
        case .parapet:
            massing.add(.box(Box(x: tower.x - 0.03, y: tower.y - 0.03, z: top,
                                 width: tower.width + 0.06, depth: tower.depth + 0.06, height: 0.08)))
            let size = tower.width * CGFloat(random.value(in: 0.24 ... 0.36))
            massing.add(.box(Box(
                x: tower.x + CGFloat(random.value(in: 0 ... 1)) * (tower.width - size),
                y: tower.y + CGFloat(random.value(in: 0 ... 1)) * (tower.depth - size),
                z: top + 0.08, width: size, depth: size,
                height: CGFloat(random.value(in: 0.14 ... 0.22))
            )))
        }
    }

    private static func roofPlant(
        on body: Box,
        count: Int,
        into massing: inout BuildingMassing,
        random: inout BuildingRandom
    ) {
        for _ in 0 ..< count {
            let width = CGFloat(random.value(in: 0.26 ... 0.44))
            let depth = CGFloat(random.value(in: 0.26 ... 0.44))
            massing.add(.box(Box(
                x: body.x + CGFloat(random.value(in: 0 ... 1)) * (body.width - width),
                y: body.y + CGFloat(random.value(in: 0 ... 1)) * (body.depth - depth),
                z: body.height + 0.08,
                width: width, depth: depth,
                height: CGFloat(random.value(in: 0.12 ... 0.22))
            )))
        }
    }
}
