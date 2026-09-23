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
        // Level 5 picks its form on its own stream, so the blocks it already
        // drew stay byte-identical and only the new forms are new.
        if tier == 3 {
            var formRandom = BuildingRandom(seed: seed, salt: 150)
            switch formRandom.int(in: 0 ... 3) {
            case 0:
                lBlock(seed: seed, footprint: footprint, into: &massing, random: &random)
                return massing
            case 1:
                slabBlock(seed: seed, footprint: footprint, into: &massing, random: &random)
                return massing
            default:
                break
            }
        }
        // **The low end is a Miami suburb.** Every tier-1 and tier-2 lot used
        // to be a box filling its lot, so a suburb read as a small downtown;
        // these forms leave open ground and put palms and pools in it.
        let plan = LotPlan(alongX: random.chance(0.5))
        switch tier {
        case 1:
            enum Low: CaseIterable { case houseRow, block, detached, poolBungalow, duplex }
            switch ZoneMassing.dealt(Low.allCases, seed: seed, salt: 1) {
            case .houseRow: houseRow(tier: tier, seed: seed, footprint: footprint, into: &massing, random: &random)
            case .block: block(tier: tier, seed: seed, footprint: footprint, into: &massing, random: &random)
            case .detached: detachedHouse(plan, into: &massing, random: &random)
            case .poolBungalow: poolBungalow(plan, into: &massing, random: &random)
            case .duplex: duplex(plan, into: &massing, random: &random)
            }
        case 2:
            enum Mid: CaseIterable { case block, gardenCourt, walkUp, townhouses }
            switch ZoneMassing.dealt(Mid.allCases, seed: seed, salt: 2) {
            case .block: block(tier: tier, seed: seed, footprint: footprint, into: &massing, random: &random)
            case .gardenCourt: gardenCourt(plan, seed: seed, into: &massing, random: &random)
            case .walkUp: walkUp(plan, seed: seed, into: &massing, random: &random)
            case .townhouses: townhouses(plan, footprint: footprint, into: &massing, random: &random)
            }
        default:
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
        // Half of the taller blocks carry a fire escape, chosen by the lot's
        // own roll so the random stream above is untouched.
        if tier >= 2, let ground,
           FacadeDetail.roll(CGFloat(seed.x), CGFloat(seed.y), 0, salt: 7) < 0.5 {
            FacadeDetail.fireEscape(on: ground, footprint: footprint, into: &massing)
        }
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

    // MARK: - The suburb (tiers 1 and 2)

    /// A detached house at the back of its lot, with a garage beside it and a
    /// palm in the front yard. Most of the lot is yard, which is the point:
    /// low density is mostly ground.
    private static func detachedHouse(
        _ plan: LotPlan, into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let long = CGFloat(random.value(in: 0.9 ... 1.12))
        let short = CGFloat(random.value(in: 0.7 ... 0.86))
        let house = plan.box(0.16, 0.16, long, short, height: CGFloat(random.value(in: 0.42 ... 0.54)))
        massing.add(.box(house))
        windows(on: house, rows: 1, columns: 2, chance: 0.85, salt: 1, into: &massing, random: &random)
        entrance(on: house, into: &massing, random: &random)
        massing.add(.ridge(Ridge(x: house.x - 0.05, y: house.y - 0.05, z: house.height,
                                 width: house.width + 0.1, depth: house.depth + 0.1,
                                 height: CGFloat(random.value(in: 0.26 ... 0.36)),
                                 axis: plan.alongX ? .x : .y)))
        // The garage, with its door lit: a car-shaped hole in the house.
        let garage = plan.box(0.16 + long + 0.05, 0.16, 0.42, 0.5, height: 0.32)
        massing.add(.box(garage))
        massing.add(.box(plan.box(0.16 + long + 0.03, 0.14, 0.46, 0.54, z: 0.32, height: 0.05)))
        massing.panels.append(Panel(box: garage, face: plan.face(.left), u0: 0.14, u1: 0.86,
                                    v0: 0, v1: 0.66, color: NeonStyle.windowPalette[1]))
        SuburbMassing.palm(at: plan.point(1.46, 1.5).0, plan.point(1.46, 1.5).1,
                           height: CGFloat(random.value(in: 0.95 ... 1.3)), into: &massing)
        if random.chance(0.5) {
            SuburbMassing.palm(at: plan.point(0.5, 1.58).0, plan.point(0.5, 1.58).1,
                               height: CGFloat(random.value(in: 0.8 ... 1.1)), into: &massing)
        }
    }

    /// A long low flat-roofed bungalow with a lit pool in front of it and two
    /// palms: the Miami house.
    private static func poolBungalow(
        _ plan: LotPlan, into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let long = CGFloat(random.value(in: 1.3 ... 1.5))
        let short = CGFloat(random.value(in: 0.6 ... 0.72))
        let house = plan.box(0.14, 0.14, long, short, height: CGFloat(random.value(in: 0.36 ... 0.44)))
        massing.add(.box(house))
        windows(on: house, rows: 1, columns: 4, chance: 0.8, salt: 2, into: &massing, random: &random)
        entrance(on: house, into: &massing, random: &random)
        // A thin flat roof that overhangs, the modernist line.
        massing.add(.box(Box(x: house.x - 0.06, y: house.y - 0.06, z: house.height,
                             width: house.width + 0.12, depth: house.depth + 0.12, height: 0.05)))
        SuburbMassing.pool(plan.box(CGFloat(random.value(in: 0.3 ... 0.5)), 0.14 + short + 0.22,
                                    CGFloat(random.value(in: 0.78 ... 0.96)), CGFloat(random.value(in: 0.4 ... 0.48)),
                                    height: 0), into: &massing)
        SuburbMassing.palm(at: plan.point(1.58, 1.28).0, plan.point(1.58, 1.28).1,
                           height: CGFloat(random.value(in: 1.0 ... 1.3)), into: &massing)
        SuburbMassing.palm(at: plan.point(0.42, 1.6).0, plan.point(0.42, 1.6).1,
                           height: CGFloat(random.value(in: 0.8 ... 1.05)), into: &massing)
    }

    /// Two homes under one pitched roof, a door and a porch each, a chimney
    /// at each end.
    private static func duplex(
        _ plan: LotPlan, into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let long = CGFloat(random.value(in: 1.46 ... 1.62))
        let short = CGFloat(random.value(in: 0.7 ... 0.8))
        let height = CGFloat(random.value(in: 0.6 ... 0.7))
        let body = plan.box(0.18, 0.2, long, short, height: height)
        massing.add(.box(body))
        windows(on: body, rows: 2, columns: 4, chance: 0.75, salt: 3, into: &massing, random: &random)
        for (index, a) in [0.18 + long * 0.25, 0.18 + long * 0.75].enumerated() {
            let porch = plan.box(a - 0.18, 0.2 + short, 0.36, 0.16, height: 0.05 + CGFloat(index) * 0.005)
            massing.add(.box(porch))
            let door = plan.face(.left)
            let u = (a - 0.18) / long
            massing.panels.append(Panel(box: body, face: door, u0: u - 0.07, u1: u + 0.07,
                                        v0: 0, v1: 0.36, color: NeonStyle.litAccent))
            let (cx, cy) = plan.point(index == 0 ? 0.3 : 0.18 + long - 0.12, 0.2 + short * 0.5)
            massing.add(.cylinder(Cylinder(x: cx, y: cy, z: height, radius: 0.05,
                                           height: 0.42 + CGFloat(index) * 0.03, sides: 6)))
        }
        massing.add(.ridge(Ridge(x: body.x - 0.05, y: body.y - 0.05, z: height,
                                 width: body.width + 0.1, depth: body.depth + 0.1,
                                 height: CGFloat(random.value(in: 0.28 ... 0.38)),
                                 axis: plan.alongX ? .x : .y)))
        SuburbMassing.palm(at: plan.point(1.56, 1.52).0, plan.point(1.56, 1.52).1,
                           height: CGFloat(random.value(in: 1.0 ... 1.35)), into: &massing)
    }

    /// Garden apartments: three two-storey wings around a courtyard open to
    /// the street, a lit pool and a palm in the middle.
    private static func gardenCourt(
        _ plan: LotPlan, seed: GridPosition, into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let height = CGFloat(random.value(in: 0.8 ... 0.98))
        let wing: CGFloat = 0.5
        let wings = [
            plan.box(0.14, 0.14, 1.72, wing, height: height),
            plan.box(0.14, 0.14 + wing, wing, 1.72 - wing, height: height - 0.02),
            plan.box(1.86 - wing, 0.14 + wing, wing, 1.72 - wing, height: height - 0.04),
        ]
        for (index, box) in wings.enumerated() {
            massing.add(.box(box))
            NeonStyle.clad(box, as: cladding(for: seed), into: &massing, random: &random)
            windows(on: box, rows: 2, columns: max(1, Int((max(box.width, box.depth) / 0.4).rounded())),
                    chance: 0.72, salt: index, into: &massing, random: &random)
            massing.add(.box(Box(x: box.x - 0.03, y: box.y - 0.03, z: box.z + box.height,
                                 width: box.width + 0.06, depth: box.depth + 0.06, height: 0.06 + CGFloat(index) * 0.004)))
        }
        entrance(on: wings[0], into: &massing, random: &random)
        SuburbMassing.pool(plan.box(0.8, 0.8, 0.4, 0.48, height: 0), into: &massing)
        SuburbMassing.palm(at: plan.point(1.0, 1.52).0, plan.point(1.0, 1.52).1,
                           height: CGFloat(random.value(in: 1.2 ... 1.5)), into: &massing)
    }

    /// A three-storey walk-up with open access galleries along its front, a
    /// lit strip on each gallery edge, and a stair tower at one end.
    private static func walkUp(
        _ plan: LotPlan, seed: GridPosition, into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let long = CGFloat(random.value(in: 1.34 ... 1.48))
        let short = CGFloat(random.value(in: 0.7 ... 0.8))
        let height = CGFloat(random.value(in: 1.1 ... 1.3))
        let body = plan.box(0.14, 0.2, long, short, height: height)
        massing.add(.box(body))
        NeonStyle.clad(body, as: cladding(for: seed), into: &massing, random: &random)
        windows(on: body, rows: 3, columns: 4, chance: 0.75, salt: 4, into: &massing, random: &random)
        let strip = NeonStyle.signColor(for: seed, salt: 6)
        for storey in 1 ..< 3 {
            let z = height * CGFloat(storey) / 3 - 0.03
            massing.add(.box(plan.box(0.14, 0.2 + short, long, 0.14, z: z, height: 0.05)))
            massing.add(.box(plan.box(0.14, 0.2 + short + 0.12, long, 0.025, z: z + 0.05, height: 0.03)),
                        .lit(strip))
        }
        let stair = plan.box(0.14 + long, 0.3, 0.22, 0.46, height: height + 0.16)
        massing.add(.box(stair))
        massing.panels.append(Panel(box: stair, face: plan.face(.right), u0: 0.3, u1: 0.7,
                                    v0: 0.06, v1: 0.9, color: NeonStyle.litAccent))
        massing.add(.box(Box(x: body.x - 0.03, y: body.y - 0.03, z: height, width: body.width + 0.06,
                             depth: body.depth + 0.06, height: 0.07)))
        NeonStyle.rooftopPlant(on: body, into: &massing, random: &random)
        SuburbMassing.palm(at: plan.point(0.5, 1.6).0, plan.point(0.5, 1.6).1,
                           height: CGFloat(random.value(in: 1.1 ... 1.45)), into: &massing)
        if random.chance(0.6) {
            SuburbMassing.palm(at: plan.point(1.4, 1.62).0, plan.point(1.4, 1.62).1,
                               height: CGFloat(random.value(in: 0.9 ... 1.2)), into: &massing)
        }
    }

    /// Three or four narrow three-storey townhouses side by side, each its
    /// own height with its own door — a street front rather than a block.
    /// The tier-1 row is single-storey houses standing apart; this is the
    /// same idea grown up.
    private static func townhouses(
        _ plan: LotPlan, footprint: CGFloat, into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let count = random.int(in: 3 ... 4)
        let span = footprint - 0.28
        let slot = span / CGFloat(count)
        let depth = CGFloat(random.value(in: 0.9 ... 1.05))
        for index in 0 ..< count {
            let height = CGFloat(random.value(in: 0.95 ... 1.3)) + CGFloat(index) * 0.01
            let house = plan.box(0.14 + slot * CGFloat(index), 0.2, slot * 0.96, depth, height: height)
            massing.add(.box(house))
            windows(on: house, rows: 3, columns: 1, chance: 0.8, salt: index, into: &massing, random: &random)
            let door = plan.face(.left)
            massing.panels.append(Panel(box: house, face: door, u0: 0.35, u1: 0.65, v0: 0, v1: 0.2,
                                        color: NeonStyle.litAccent))
            massing.add(.box(Box(x: house.x - 0.02, y: house.y - 0.02, z: height, width: house.width + 0.04,
                                 depth: house.depth + 0.04, height: 0.05)))
            if random.chance(0.5) {
                // A roof terrace's stair head.
                massing.add(.box(plan.box(0.14 + slot * CGFloat(index) + slot * 0.3, 0.3, slot * 0.36, 0.3,
                                          z: height + 0.05, height: 0.18)))
            }
        }
        SuburbMassing.palm(at: plan.point(0.14 + slot * 0.5, 1.6).0, plan.point(0.14 + slot * 0.5, 1.6).1,
                           height: CGFloat(random.value(in: 1.0 ... 1.3)), into: &massing)
    }

    /// **Level 5: two wings meeting in an L**, one taller than the other,
    /// wrapped round a lit courtyard corner. The stepped block is a pyramid in
    /// every direction; this one has a hollow, which is the mark.
    private static func lBlock(
        seed: GridPosition, footprint: CGFloat,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.14
        let thickness = CGFloat(random.value(in: 0.7 ... 0.85))
        let tall = CGFloat(random.value(in: 2.0 ... 2.6))
        let short = tall - CGFloat(random.value(in: 0.5 ... 0.9))
        let full = footprint - margin * 2
        let wings = [
            Box(x: margin, y: margin, z: 0, width: full, depth: thickness, height: tall),
            Box(x: margin, y: margin + thickness, z: 0, width: thickness, depth: full - thickness, height: short),
        ]
        for (index, wing) in wings.enumerated() {
            massing.add(.box(wing))
            NeonStyle.clad(wing, as: cladding(for: seed), into: &massing, random: &random)
            windows(on: wing, rows: max(2, Int((wing.height / 0.36).rounded())),
                    columns: max(1, Int((max(wing.width, wing.depth) / 0.55).rounded())),
                    chance: 0.7, salt: index, into: &massing, random: &random)
            balcony(on: wing, at: CGFloat(random.value(in: 0.4 ... 0.7)), into: &massing)
            NeonStyle.rooftopPlant(on: wing, into: &massing, random: &random)
        }
        entrance(on: wings[1], into: &massing, random: &random)
    }

    /// **Level 5: a long slab block**, one flat deep and the length of its
    /// lot, balconies running its whole face — the post-war estate slab.
    private static func slabBlock(
        seed: GridPosition, footprint: CGFloat,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let thin = CGFloat(random.value(in: 0.62 ... 0.78))
        let long = footprint - 0.28
        let alongX = random.chance(0.5)
        let slab = Box(x: alongX ? 0.14 : (footprint - thin) / 2, y: alongX ? (footprint - thin) / 2 : 0.14, z: 0,
                       width: alongX ? long : thin, depth: alongX ? thin : long,
                       height: CGFloat(random.value(in: 2.1 ... 2.8)))
        massing.add(.box(slab))
        NeonStyle.clad(slab, as: cladding(for: seed), into: &massing, random: &random)
        windows(on: slab, rows: max(2, Int((slab.height / 0.36).rounded())),
                columns: max(1, Int((long / 0.5).rounded())), chance: 0.68, salt: 2,
                into: &massing, random: &random)
        var fraction = CGFloat(random.value(in: 0.2 ... 0.28))
        while fraction < 0.9 {
            balcony(on: slab, at: fraction, into: &massing)
            fraction += CGFloat(random.value(in: 0.22 ... 0.3))
        }
        entrance(on: slab, into: &massing, random: &random)
        // Its own parapet and plant: `crown` sizes itself for a square top.
        massing.add(.box(Box(x: slab.x - 0.03, y: slab.y - 0.03, z: slab.height,
                             width: slab.width + 0.06, depth: slab.depth + 0.06, height: 0.09)))
        NeonStyle.rooftopPlant(on: slab, into: &massing, random: &random)
    }

    // MARK: - Parts

    /// A ledge that projects past the wall on every side and wraps the corner.
    ///
    /// The elevation version was a bright line with railing posts, and the
    /// posts had to be cut for being a quarter of a screen point wide, which
    /// left a line. A projecting slab says "balcony" from its silhouette, needs
    /// no detail to do it, and survives every zoom — the shape carries the
    /// meaning instead of the decoration.
    static func balcony(on box: Box, at fraction: CGFloat, into massing: inout BuildingMassing) {
        let overhang: CGFloat = 0.08
        let slab = Box(
            x: box.x - overhang, y: box.y - overhang,
            z: box.z + box.height * fraction,
            width: box.width + overhang * 2, depth: box.depth + overhang * 2,
            height: 0.06
        )
        massing.add(.box(slab))
        FacadeDetail.balustrade(on: slab, into: &massing)
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
    static func cladding(for seed: GridPosition) -> NeonStyle.Cladding {
        NeonStyle.cladding(for: seed, options: [.curtainWall, .panel], salt: 1)
    }

    static func windows(
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
                    let window = Panel(
                        box: box, face: face,
                        u0: (CGFloat(column) + 0.26) / CGFloat(columns),
                        u1: (CGFloat(column) + 0.74) / CGFloat(columns),
                        v0: (CGFloat(row) + 0.24) / CGFloat(rows),
                        v1: (CGFloat(row) + 0.7) / CGFloat(rows),
                        color: NeonStyle.windowColor(row: row, column: column, salt: salt)
                    )
                    massing.panels.append(window)
                    FacadeDetail.airConditioner(under: window, into: &massing)
                }
            }
        }
    }

    /// A lit doorway at street level — the human-scale detail that says people
    /// live here.
    static func entrance(on box: Box, into massing: inout BuildingMassing, random: inout BuildingRandom) {
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
