import SpriteKit

/// Housing, described as volumes.
///
/// `ResidentialBuilding`'s vocabulary, carried over: stepped massing that
/// narrows as it rises, punched window grids rather than continuous bands,
/// balcony bands, rooftop clutter rather than lit crowns, and — at low
/// density — a row of separate houses instead of one block, because that is
/// what low density actually looks like and tier 1 covers most of a city's map.
///
/// **Two marks are genuinely better in isometric than they were in elevation,
/// rather than merely equivalent.**
///
/// A balcony was a bright horizontal line across a facade with railing posts
/// that had to be deleted for being a quarter of a screen point wide. Here it
/// is a real ledge that projects past the wall on every side and wraps the
/// corner, so it reads as a balcony from its silhouette alone and needs no
/// detail at all to say so.
///
/// A pitched roof was a trapezoid stuck on top of a rectangle. Here it is a
/// volume with two slopes and a gable end, and whether you see one slope or
/// both depends on its pitch — which is the difference between a drawing of a
/// house and a house.
enum ResidentialMassing {

    static func make(tier: Int, seed: GridPosition, footprint: CGFloat = 2) -> BuildingMassing {
        var random = BuildingRandom(seed: seed, salt: 100 + tier)
        var massing = BuildingMassing()

        if ZoneMassing.isLandmark(tier: tier, seed: seed) {
            pointBlock(tier: tier, seed: seed, footprint: footprint,
                       into: &massing, random: &random)
            return massing
        }
        if tier == 1, random.chance(0.5) {
            houseRow(tier: tier, seed: seed, footprint: footprint, into: &massing, random: &random)
        } else {
            block(tier: tier, seed: seed, footprint: footprint, into: &massing, random: &random)
        }
        return massing
    }

    // MARK: - Forms

    /// Two or three narrow houses side by side, each with its own roof. Low
    /// density drawn as low density.
    private static func houseRow(
        tier: Int,
        seed: GridPosition,
        footprint: CGFloat,
        into massing: inout BuildingMassing,
        random: inout BuildingRandom
    ) {
        let count = random.int(in: 2 ... 3)
        let margin: CGFloat = 0.12
        let span = footprint - margin * 2
        let slot = span / CGFloat(count)
        let alongX = random.chance(0.5)

        for index in 0 ..< count {
            let width = slot * CGFloat(random.value(in: 0.72 ... 0.9))
            let depth = CGFloat(random.value(in: 1.0 ... 1.35))
            let height = CGFloat(random.value(in: 0.42 ... 0.62))
            let offset = margin + slot * CGFloat(index) + (slot - width) / 2
            let across = (footprint - depth) / 2 + CGFloat(random.value(in: -0.1 ... 0.1))

            let house = alongX
                ? Box(x: offset, y: across, z: 0, width: width, depth: depth, height: height)
                : Box(x: across, y: offset, z: 0, width: depth, depth: width, height: height)
            massing.add(.box(house))
            windows(on: house, rows: 1, columns: 1, chance: 0.8, salt: index, into: &massing, random: &random)

            if random.chance(0.65) {
                // A pitched roof, running along the house's long axis the way a
                // real one does.
                massing.add(.ridge(Ridge(
                    x: house.x - 0.04, y: house.y - 0.04, z: height,
                    width: house.width + 0.08, depth: house.depth + 0.08,
                    height: CGFloat(random.value(in: 0.26 ... 0.4)),
                    axis: house.width >= house.depth ? .x : .y
                )))
            } else {
                massing.add(.box(Box(
                    x: house.x - 0.03, y: house.y - 0.03, z: height,
                    width: house.width + 0.06, depth: house.depth + 0.06, height: 0.07
                )))
                if random.chance(0.6) {
                    // A chimney, which is a house mark and nothing else's.
                    massing.add(.cylinder(Cylinder(
                        x: house.x + house.width * CGFloat(random.value(in: 0.25 ... 0.75)),
                        y: house.y + house.depth * CGFloat(random.value(in: 0.25 ... 0.75)),
                        z: height, radius: 0.055,
                        height: CGFloat(random.value(in: 0.2 ... 0.32))
                    )))
                }
            }
            if index == 0 { entrance(on: house, into: &massing, random: &random) }
        }
    }

    /// One stacked, stepped-back block: the apartment building. Housing grows
    /// *upward* as it densifies and narrows as it does — the opposite of
    /// industry, which spreads.
    private static func block(
        tier: Int,
        seed: GridPosition,
        footprint: CGFloat,
        into massing: inout BuildingMassing,
        random: inout BuildingRandom
    ) {
        let volumeCount = random.int(in: tier >= 3 ? 2 ... 3 : (tier == 2 ? 2 ... 3 : 1 ... 2))
        // Roughly three metres a storey against an eight-metre tile: tier 1 is
        // two storeys, tier 3 is six or seven.
        let totalHeight = CGFloat(random.value(in: tier >= 3 ? 1.9 ... 2.6 : (tier == 2 ? 1.2 ... 1.6 : 0.7 ... 0.95)))

        var inset = CGFloat(random.value(in: 0.1 ... 0.2))
        var z: CGFloat = 0
        var ground: Box?
        var top: Box?

        for index in 0 ..< volumeCount {
            let remaining = totalHeight - z
            let share = index == volumeCount - 1 ? 1.0 : CGFloat(random.value(in: 0.4 ... 0.6))
            let height = max(0.3, remaining * share)
            let box = Box(x: inset, y: inset, z: z,
                          width: footprint - inset * 2, depth: footprint - inset * 2, height: height)
            massing.add(.box(box))
            NeonStyle.clad(box, as: cladding(for: seed), into: &massing, random: &random)
            if ground == nil { ground = box }
            top = box

            let rows = max(1, Int((height / 0.36).rounded()))
            let columns = max(1, Int((box.width / 0.55).rounded()))
            windows(on: box, rows: rows, columns: columns, chance: 0.7, salt: index,
                    into: &massing, random: &random)

            if random.chance(index == 0 ? 0.45 : 0.7), inset >= 0.09 {
                balcony(on: box, at: CGFloat(random.value(in: 0.3 ... 0.7)), into: &massing)
            }

            z += height
            inset += CGFloat(random.value(in: 0.1 ... 0.2))
        }

        if let top { NeonStyle.rooftopPlant(on: top, into: &massing, random: &random) }
        crown(atTop: z, inset: inset, footprint: footprint, tier: tier, into: &massing, random: &random)
        if let ground { entrance(on: ground, into: &massing, random: &random) }
    }

    /// **The point block: housing's landmark.**
    ///
    /// An ordinary tier-3 block stands about two and a half tile units and
    /// steps *inward* as it rises, which is a pyramid — a shape that reads as
    /// mass rather than as height. This one puts a wide two-storey podium on
    /// the ground and stands one slim shaft on it, four to five units tall.
    ///
    /// **The silhouette is the point, not the height.** A tower block is a
    /// real and specific thing — the slab on a plinth that every post-war city
    /// has a few of — and it is unmistakable at any zoom because the base and
    /// the shaft are such different widths. Commerce's landmark is a *spire*,
    /// tapering to a mast; this one is deliberately blunt, and the two do not
    /// get confused across a map.
    ///
    /// It carries housing's own marks the whole way up: punched window grids
    /// rather than continuous bands, balconies wrapping the corner every few
    /// storeys, and rooftop machinery where commerce puts a lit crown.
    private static func pointBlock(
        tier: Int,
        seed: GridPosition,
        footprint: CGFloat,
        into massing: inout BuildingMassing,
        random: inout BuildingRandom
    ) {
        // The podium: wide, low, and the thing the shaft gets its scale from.
        let margin = CGFloat(random.value(in: 0.06 ... 0.12))
        let podium = Box(x: margin, y: margin, z: 0,
                         width: footprint - margin * 2, depth: footprint - margin * 2,
                         height: CGFloat(random.value(in: 0.5 ... 0.7)))
        massing.add(.box(podium))
        windows(on: podium, rows: 2, columns: max(1, Int((podium.width / 0.55).rounded())),
                chance: 0.7, salt: 0, into: &massing, random: &random)
        entrance(on: podium, into: &massing, random: &random)

        // The shaft. Half the lot across, which against the podium's full
        // width is what carries the reading.
        let inset = margin + CGFloat(random.value(in: 0.42 ... 0.58))
        let height = CGFloat(random.value(in: 3.4 ... 4.4))
        let shaft = Box(x: inset, y: inset, z: podium.height,
                        width: footprint - inset * 2, depth: footprint - inset * 2,
                        height: height)
        massing.add(.box(shaft))
        NeonStyle.clad(shaft, as: cladding(for: seed), into: &massing, random: &random)
        let rows = max(4, Int((height / 0.36).rounded()))
        windows(on: shaft, rows: rows, columns: max(1, Int((shaft.width / 0.5).rounded())),
                chance: 0.66, salt: 3, into: &massing, random: &random)

        // Balconies every few storeys. The one residential mark that reads
        // from its silhouette alone, and on a shaft this tall there is room
        // for several without them becoming a stripe pattern.
        var fraction = CGFloat(random.value(in: 0.18 ... 0.3))
        while fraction < 0.9 {
            balcony(on: shaft, at: fraction, into: &massing)
            fraction += CGFloat(random.value(in: 0.2 ... 0.3))
        }

        NeonStyle.rooftopPlant(on: shaft, into: &massing, random: &random)
        crown(atTop: shaft.z + shaft.height, inset: inset, footprint: footprint,
              tier: tier, into: &massing, random: &random)
    }

    // MARK: - Parts

    /// A ledge that projects past the wall on every side and wraps the corner.
    ///
    /// The elevation version was a bright line with railing posts, and the
    /// posts had to be cut for being a quarter of a screen point wide, which
    /// left a line. A projecting slab says "balcony" from its silhouette, needs
    /// no detail to do it, and survives every zoom — the shape carries the
    /// meaning instead of the decoration.
    private static func balcony(on box: Box, at fraction: CGFloat, into massing: inout BuildingMassing) {
        let overhang: CGFloat = 0.08
        massing.add(.box(Box(
            x: box.x - overhang, y: box.y - overhang,
            z: box.z + box.height * fraction,
            width: box.width + overhang * 2, depth: box.depth + overhang * 2,
            height: 0.06
        )))
    }

    /// Small separate windows, some lit and some dark — the opposite of
    /// commerce's continuous glazing bands. A wall of separate lights reads as
    /// many homes.
    /// **Masonry, or precast panel.**
    ///
    /// Housing's identity is the punched grid of separate little windows, and
    /// that stays either way. What changes is whether the wall between them is
    /// blank — brick, render, anything laid in small pieces — or shows the
    /// floor slabs as horizontal bands, which is what a panel-built block
    /// looks like and what most of the towers this game is drawing would
    /// actually be.
    ///
    /// Deliberately *not* commerce's option: piers on a punched grid would
    /// read as a glazing frame, which is the one thing housing's facade is
    /// defined against.
    private static func cladding(for seed: GridPosition) -> NeonStyle.Cladding {
        NeonStyle.cladding(for: seed, options: [.curtainWall, .panel], salt: 1)
    }

    private static func windows(
        on box: Box,
        rows: Int,
        columns: Int,
        chance: Double,
        salt: Int,
        into massing: inout BuildingMassing,
        random: inout BuildingRandom
    ) {
        for face in [Panel.Face.right, .left] {
            // One window per wall is always lit: with few enough cells an
            // independent roll can turn every one off, and an unlit house reads
            // as a bug rather than as low density.
            let litIndex = random.int(in: 0 ... (rows * columns - 1))
            for row in 0 ..< rows {
                for column in 0 ..< columns {
                    guard row * columns + column == litIndex || random.chance(chance) else { continue }
                    massing.panels.append(Panel(
                        box: box, face: face,
                        u0: (CGFloat(column) + 0.26) / CGFloat(columns),
                        u1: (CGFloat(column) + 0.74) / CGFloat(columns),
                        v0: (CGFloat(row) + 0.24) / CGFloat(rows),
                        v1: (CGFloat(row) + 0.7) / CGFloat(rows),
                        color: NeonStyle.windowColor(row: row, column: column, salt: salt)
                    ))
                }
            }
        }
    }

    /// A lit doorway at street level — the human-scale detail that says people
    /// live here.
    private static func entrance(on box: Box, into massing: inout BuildingMassing, random: inout BuildingRandom) {
        let centre = CGFloat(random.value(in: 0.35 ... 0.65))
        massing.panels.append(Panel(
            box: box, face: random.chance(0.5) ? .right : .left,
            u0: centre - 0.1, u1: centre + 0.1,
            v0: 0, v1: min(0.34, 0.26 / max(box.height, 0.3)),
            color: NeonStyle.litAccent
        ))
    }

    /// Rooftop clutter rather than an illuminated crown: tanks, stair heads,
    /// and at low tiers a pitched cap. This is the other end of the
    /// residential/commercial split — offices light their tops, housing puts
    /// machinery up there.
    private static func crown(
        atTop z: CGFloat,
        inset: CGFloat,
        footprint: CGFloat,
        tier: Int,
        into massing: inout BuildingMassing,
        random: inout BuildingRandom
    ) {
        enum Style: CaseIterable { case tank, bulkhead, pitched, parapet }
        let style: Style = tier == 1 ? random.pick([.pitched, .parapet, .tank]) : random.pick(Style.allCases)
        let width = footprint - inset * 2
        let centre = footprint / 2

        switch style {
        case .tank:
            // A rooftop water tank on short legs.
            let radius = width * CGFloat(random.value(in: 0.16 ... 0.24))
            massing.add(.cylinder(Cylinder(x: centre, y: centre, z: z + 0.06,
                                           radius: radius, height: CGFloat(random.value(in: 0.24 ... 0.36)))))
            massing.add(.box(Box(x: centre - 0.04, y: centre - 0.04, z: z,
                                 width: 0.08, depth: 0.08, height: 0.07)))
        case .bulkhead:
            // A stair head — a small box offset to one side.
            let size = width * CGFloat(random.value(in: 0.3 ... 0.45))
            massing.add(.box(Box(
                x: inset + CGFloat(random.value(in: 0 ... 1)) * (width - size),
                y: inset + CGFloat(random.value(in: 0 ... 1)) * (width - size),
                z: z, width: size, depth: size,
                height: CGFloat(random.value(in: 0.22 ... 0.34))
            )))
        case .pitched:
            massing.add(.ridge(Ridge(
                x: inset - 0.05, y: inset - 0.05, z: z,
                width: width + 0.1, depth: width + 0.1,
                height: CGFloat(random.value(in: 0.28 ... 0.44)),
                axis: random.chance(0.5) ? .x : .y
            )))
        case .parapet:
            massing.add(.box(Box(x: inset - 0.04, y: inset - 0.04, z: z,
                                 width: width + 0.08, depth: width + 0.08, height: 0.09)))
        }
    }
}
