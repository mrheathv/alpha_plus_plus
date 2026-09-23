import SpriteKit

/// The service and civic buildings, described as volumes.
///
/// **One generator per service, not two hand-picked looks.** The elevation
/// renderer this replaced drew
/// exactly two variants of each service, because hand-writing a third was
/// unaffordable — the file says as much ("these don't grow, so a second variant
/// is the only way two of the same service ever look different"). Massing has
/// no such limit: the same seeded parameters that give the growable zones their
/// variety work here, so two fire stations differ the way two factories do,
/// without anyone writing a second function.
///
/// What is preserved exactly is each service's **identity mark** — the one
/// feature that makes it recognisable while scanning for coverage gaps, which
/// is what these icons are for. A hose-drying tower, a water tank on legs, a
/// gable and a clock, a cross, cooling towers, a bowl with floodlights.
enum ServiceMassing {

    static func make(for zone: ZoneType, seed: GridPosition, footprint: CGFloat) -> BuildingMassing? {
        var random = BuildingRandom(seed: seed, salt: 400 + zone.rawValue.count)
        var massing = BuildingMassing()

        switch zone {
        case .policeStation: precinct(footprint, seed, &massing, &random)
        case .fireStation: firehouse(footprint, &massing, &random)
        case .publicTransit: transitStop(footprint, &massing, &random)
        case .subway: subwayEntrance(footprint, &massing, &random)
        case .tramStop: tramPlatform(footprint, &massing, &random)
        case .railStation: trainShed(footprint, &massing, &random)
        case .waterTower: waterTower(footprint, &massing, &random)
        case .waterPump: waterPump(footprint, &massing, &random)
        case .generator: generator(footprint, &massing, &random)
        case .park: park(footprint, &massing, &random)
        case .school: school(footprint, &massing, &random)
        case .hospital: hospital(footprint, &massing, &random)
        case .powerPlant: powerPlant(footprint, &massing, &random)
        case .stadium: stadium(footprint, &massing, &random)
        case .seaport: seaport(footprint, &massing, &random)
        case .airport: airport(footprint, &massing, &random)
        case .neonArcade: neonArcade(footprint, &massing, &random)
        case .broadcastTower: broadcastTower(footprint, &massing, &random)
        case .arcology: arcology(footprint, &massing, &random)
        default: return nil
        }
        return massing
    }

    // MARK: - Shared

    /// Lit windows on the two visible walls of a civic block.
    private static func windows(
        on box: Box, rows: Int, columns: Int, chance: Double,
        _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        for face in [Panel.Face.right, .left] {
            for row in 0 ..< rows {
                for column in 0 ..< columns where random.chance(chance) {
                    massing.panels.append(Panel(
                        box: box, face: face,
                        u0: (CGFloat(column) + 0.24) / CGFloat(columns),
                        u1: (CGFloat(column) + 0.76) / CGFloat(columns),
                        v0: (CGFloat(row) + 0.24) / CGFloat(rows),
                        v1: (CGFloat(row) + 0.7) / CGFloat(rows),
                        color: NeonStyle.windowColor(row: row, column: column)
                    ))
                }
            }
        }
    }

    private static func doorway(on box: Box, width: CGFloat, _ massing: inout BuildingMassing) {
        massing.panels.append(Panel(
            box: box, face: .left, u0: 0.5 - width / 2, u1: 0.5 + width / 2,
            v0: 0, v1: min(0.4, 0.3 / max(box.height, 0.3)), color: NeonStyle.litAccent
        ))
    }

    // MARK: - Rank rewards

    /// **The Neon Arcade: a low hall under the biggest sign in the city.**
    ///
    /// The identity mark is the sign. Every other building here is lit by its
    /// windows; this one is lit by its *advertising*, a board standing on the
    /// roof taller than the hall under it — the silhouette of every arcade and
    /// cinema on every neon street. The hall stays low so the sign is the
    /// thing you see first. Two forms: the board across the roof, or a blade
    /// standing at the corner like a cinema's vertical name.
    private static func neonArcade(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let accent = RenderPalette.fullColor(for: .neonArcade)
        let margin: CGFloat = 0.12
        let hall = Box(x: margin, y: margin, z: 0,
                       width: footprint - margin * 2, depth: footprint - margin * 2,
                       height: CGFloat(random.value(in: 0.75 ... 0.95)))
        massing.add(.box(hall))
        // A marquee band round both visible walls: the lit strip over the
        // doors every arcade has, and the reason it reads as open at night.
        for face in [Panel.Face.right, .left] {
            massing.panels.append(Panel(box: hall, face: face, u0: 0.06, u1: 0.94,
                                        v0: 0.52, v1: 0.72, color: accent))
        }
        doorway(on: hall, width: 0.34, &massing)

        if random.chance(0.5) {
            // The board across the roof, set back from the front edge so it
            // stands on the hall rather than hanging off it.
            let board = Box(x: hall.x + 0.2, y: hall.y + hall.depth * 0.45, z: hall.height,
                            width: hall.width - 0.4, depth: 0.14,
                            height: CGFloat(random.value(in: 0.9 ... 1.2)))
            massing.add(.box(board), .lit(accent))
            // Legs, so it reads as a sign on a frame rather than a lit wall.
            for x in [board.x + 0.1, board.x + board.width - 0.2] {
                massing.add(.box(Box(x: x, y: board.y, z: hall.height, width: 0.1, depth: 0.1,
                                     height: 0.2)))
            }
        } else {
            // The blade at the near corner, the cinema's vertical name.
            let blade = Box(x: hall.x + hall.width - 0.24, y: hall.y + hall.depth - 0.24, z: 0.2,
                            width: 0.14, depth: 0.14,
                            height: hall.height + CGFloat(random.value(in: 1.3 ... 1.7)))
            massing.add(.box(blade), .lit(accent))
        }
    }

    /// **The Broadcast Tower: the tallest thing in the game.**
    ///
    /// A mast rather than a building. The commercial landmark spire tops out
    /// at 6.6 and this goes higher, so a City sees its reward from anywhere on
    /// the map — which is the whole job of a reward building. Tapering
    /// sections with lit rings between them, a lit tip, and a small studio
    /// block at its foot so it stands on something.
    ///
    /// **Slender, for the reason the industrial landmark's stack is**: the
    /// first thick version of that read as a post. What makes a mast a mast is
    /// the ratio, and a thin line far taller than anything round it is the
    /// one silhouette nothing else in the city can be mistaken for.
    private static func broadcastTower(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let accent = RenderPalette.fullColor(for: .broadcastTower)
        let studio = Box(x: 0.14, y: 0.14, z: 0, width: footprint * 0.5, depth: footprint - 0.28,
                         height: 0.55)
        massing.add(.box(studio))
        windows(on: studio, rows: 1, columns: 3, chance: 0.9, &massing, &random)

        let centreX = footprint * 0.68
        let centreY = footprint * 0.5
        let sections = 4
        let total = CGFloat(random.value(in: 7.2 ... 8.0))
        var z: CGFloat = 0
        for index in 0 ..< sections {
            let width = 0.32 - CGFloat(index) * 0.06
            let height = total / CGFloat(sections)
            let section = Box(x: centreX - width / 2, y: centreY - width / 2, z: z,
                              width: width, depth: width, height: height)
            massing.add(.box(section))
            z += height
            // A lit ring at each joint: the beacons a real mast carries, and
            // what makes the height legible as height rather than as a line.
            let ring = width + 0.08
            massing.add(.box(Box(x: centreX - ring / 2, y: centreY - ring / 2, z: z - 0.08,
                                 width: ring, depth: ring, height: 0.08)), .lit(accent))
        }
        // The tip: a thin lit spike above the last ring.
        massing.add(.box(Box(x: centreX - 0.03, y: centreY - 0.03, z: z,
                             width: 0.06, depth: 0.06, height: 0.7)), .lit(accent))
    }

    /// **The Arcology: a stepped megastructure, a small town in one building.**
    ///
    /// Tiers that step back as they rise, each wrapped in glazing, with a lit
    /// terrace band at every setback — the garden decks an arcology is built
    /// around, and the reason it reads as somewhere people live rather than
    /// as an office block. Crowned with a lit ring. Broad and tall at once,
    /// which nothing else in the game is: towers are tall, halls are broad.
    private static func arcology(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let accent = RenderPalette.fullColor(for: .arcology)
        let tiers = random.chance(0.5) ? 4 : 5
        var inset: CGFloat = 0.12
        var z: CGFloat = 0
        let step = (footprint / 2 - 0.55) / CGFloat(tiers)
        for index in 0 ..< tiers {
            let side = footprint - inset * 2
            let height = CGFloat(random.value(in: 1.0 ... 1.25)) - CGFloat(index) * 0.08
            let tier = Box(x: inset, y: inset, z: z, width: side, depth: side, height: height)
            massing.add(.box(tier))
            // Continuous glazing, two bands a tier — floor plates, like
            // commerce, because an arcology is a building people work in too.
            for face in [Panel.Face.right, .left] {
                for band in [(0.18, 0.38), (0.58, 0.78)] as [(CGFloat, CGFloat)] {
                    massing.panels.append(Panel(box: tier, face: face, u0: 0.08, u1: 0.92,
                                                v0: band.0, v1: band.1, color: NeonStyle.litAccent))
                }
            }
            z += height
            inset += step
            // The terrace at the setback: a lit green deck on the roof of the
            // tier below the next one.
            if index < tiers - 1 {
                massing.add(.box(Box(x: tier.x + 0.04, y: tier.y + 0.04, z: z,
                                     width: side - 0.08, depth: side - 0.08, height: 0.05)),
                            .lit(accent))
            }
        }
        // The crown.
        let crown = footprint - inset * 2
        massing.add(.box(Box(x: inset, y: inset, z: z, width: crown, depth: crown, height: 0.14)),
                    .lit(accent))
    }

    // MARK: - Services

    /// A precinct: a mid-rise station house with a rooftop beacon.
    private static func precinct(
        _ footprint: CGFloat, _ seed: GridPosition,
        _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let inset = CGFloat(random.value(in: 0.14 ... 0.26))
        let body = Box(x: inset, y: inset, z: 0, width: footprint - inset * 2,
                       depth: footprint - inset * 2, height: CGFloat(random.value(in: 1.15 ... 1.6)))
        massing.add(.box(body))
        windows(on: body, rows: max(2, Int(body.height / 0.36)), columns: 3, chance: 0.7, &massing, &random)
        doorway(on: body, width: 0.22, &massing)
        massing.add(.box(Box(x: body.x - 0.04, y: body.y - 0.04, z: body.height,
                             width: body.width + 0.08, depth: body.depth + 0.08, height: 0.08)))
        // The beacon: the mark that says "police" from across the map.
        let centre = footprint / 2
        massing.add(.box(Box(x: centre - 0.1, y: centre - 0.1, z: body.height + 0.08,
                             width: 0.2, depth: 0.2, height: 0.16)))
        massing.add(.box(Box(x: centre - 0.08, y: centre - 0.08, z: body.height + 0.24,
                             width: 0.16, depth: 0.16, height: 0.1)),
                    .lit(NeonStyle.signColor(for: seed)))
    }

    /// A firehouse: a squat station body with the tall, narrow hose-drying
    /// tower that reads as "fire station" the way a flame symbol never did.
    private static func firehouse(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.12
        let towerSize = CGFloat(random.value(in: 0.42 ... 0.56))
        let onFar = random.chance(0.5)
        let body = Box(x: margin, y: margin, z: 0,
                       width: footprint - margin * 2, depth: footprint - margin * 2,
                       height: CGFloat(random.value(in: 0.66 ... 0.86)))
        massing.add(.box(body))
        windows(on: body, rows: 1, columns: 3, chance: 0.5, &massing, &random)

        // Roll-up doors: dark, and wide enough to break the wall's outline.
        for face in [Panel.Face.right, .left] {
            for bay in 0 ..< 2 {
                massing.panels.append(Panel(
                    box: body, face: face,
                    u0: 0.14 + CGFloat(bay) * 0.42, u1: 0.44 + CGFloat(bay) * 0.42,
                    v0: 0, v1: 0.62, color: NeonStyle.recessedAccent
                ))
            }
        }

        // The tower goes at a *near* corner, not a far one.
        //
        // Placed at the far edge it sorts behind the body and is occluded up to
        // roof height, so all that survives is a stub poking out of the roof —
        // which reads as a chimney, and a chimney is industry's mark, not a
        // firehouse's. At the near corner it stands clear of the body and the
        // hose-drying tower is legible from across the map, which is the whole
        // reason this service has one.
        let near = footprint - margin - towerSize
        let tower = onFar
            ? Box(x: near, y: (footprint - towerSize) / 2, z: 0,
                  width: towerSize, depth: towerSize, height: CGFloat(random.value(in: 1.5 ... 2.0)))
            : Box(x: (footprint - towerSize) / 2, y: near, z: 0,
                  width: towerSize, depth: towerSize, height: CGFloat(random.value(in: 1.5 ... 2.0)))
        massing.add(.box(tower))
        massing.add(.box(Box(x: tower.x - 0.03, y: tower.y - 0.03, z: tower.height,
                             width: towerSize + 0.06, depth: towerSize + 0.06, height: 0.07)))
        massing.add(.box(Box(x: tower.x + towerSize / 2 - 0.06, y: tower.y + towerSize / 2 - 0.06,
                             z: tower.height + 0.07, width: 0.12, depth: 0.12, height: 0.1)),
                    .lit(NeonStyle.emberColor))
    }

    /// **Three shelters, one mark.** A bus stop is 1×1 and the cheapest
    /// transit building in the game, so a corridor ends up carrying a dozen
    /// of them — which puts it in the same position as the park: a *service*
    /// numerous enough that repetition reads as wallpaper rather than as
    /// identity.
    ///
    /// What never varies is the mark itself: a flat canopy standing on posts
    /// over something lit. That is what has to stay constant for a player
    /// scanning a street for coverage gaps, and it is what keeps a bus stop
    /// apart from the tram's kerbed island and the subway's lit mouth. What
    /// varies is the shelter *around* it.
    private static func transitStop(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        switch random.int(in: 0 ... 2) {
        case 0: openShelter(footprint, &massing, &random)
        case 1: backedShelter(footprint, &massing, &random)
        default: twinShelter(footprint, &massing, &random)
        }
        // A flag at the kerb on about half of them. A companion mark rather
        // than a fourth form: it changes the silhouette — a thin vertical
        // beside a horizontal canopy — without touching what makes the
        // building a bus stop, which is the canopy itself.
        if random.chance(0.5) {
            let pole = CGFloat(random.value(in: 0.6 ... 0.78))
            massing.add(.box(Box(x: 0.08, y: footprint / 2 - 0.03, z: 0,
                                 width: 0.06, depth: 0.06, height: pole)))
            massing.add(.box(Box(x: 0.04, y: footprint / 2 - 0.05, z: pole,
                                 width: 0.15, depth: 0.1, height: 0.05)),
                        .lit(NeonStyle.litAccent))
        }
    }

    /// Four posts, a flat canopy, a lit bench under it.
    private static func openShelter(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.18
        let width = footprint - margin * 2
        let height = CGFloat(random.value(in: 0.42 ... 0.54))
        for corner in [(0, 0), (1, 0), (0, 1), (1, 1)] {
            massing.add(.box(Box(
                x: margin + CGFloat(corner.0) * (width - 0.07),
                y: margin + CGFloat(corner.1) * (width - 0.07),
                z: 0, width: 0.07, depth: 0.07, height: height
            )))
        }
        massing.add(.box(Box(x: margin - 0.06, y: margin - 0.06, z: height,
                             width: width + 0.12, depth: width + 0.12, height: 0.07)))
        massing.add(.box(Box(x: margin + 0.1, y: margin + 0.1, z: 0.04,
                             width: width - 0.2, depth: width - 0.2, height: 0.09)),
                    .lit(NeonStyle.litAccent))
    }

    /// A back wall carrying a lit advertising panel, with the canopy
    /// cantilevered forward off it onto two posts. The solid wall is what
    /// separates this from the open shelter at any zoom: half the silhouette
    /// is filled in rather than open sky.
    private static func backedShelter(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.18
        let width = footprint - margin * 2
        let height = CGFloat(random.value(in: 0.48 ... 0.62))
        let wall = Box(x: margin, y: margin, z: 0,
                       width: width, depth: 0.08, height: height)
        massing.add(.box(wall))
        // The ad panel — the one lit mark, on the face that looks at the
        // camera, sized to fill most of the wall rather than to be a poster
        // on it. `minimumDetailSize`'s rule: one bold mark beats four small.
        massing.panels.append(Panel(box: wall, face: .right, u0: 0.12, u1: 0.88,
                                    v0: 0.18, v1: 0.88, color: NeonStyle.litAccent))
        for end in [CGFloat(0), 1] {
            massing.add(.box(Box(x: margin + end * (width - 0.07),
                                 y: margin + width - 0.07,
                                 z: 0, width: 0.07, depth: 0.07, height: height)))
        }
        massing.add(.box(Box(x: margin - 0.05, y: margin - 0.05, z: height,
                             width: width + 0.1, depth: width + 0.1, height: 0.06)))
    }

    /// Two canopies end to end — a busy stop, where a second bus waits behind
    /// the first. Lower than the others so the pair does not read as one tall
    /// block, and the gap between them is what makes it count as two.
    private static func twinShelter(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.14
        let span = footprint - margin * 2
        let bay = (span - 0.1) / 2
        let height = CGFloat(random.value(in: 0.36 ... 0.46))
        for half in [CGFloat(0), 1] {
            let y = margin + half * (bay + 0.1)
            for end in [CGFloat(0), 1] {
                massing.add(.box(Box(x: margin + end * (span - 0.06), y: y + bay / 2 - 0.03,
                                     z: 0, width: 0.06, depth: 0.06, height: height)))
            }
            massing.add(.box(Box(x: margin - 0.04, y: y, z: height,
                                 width: span + 0.08, depth: bay, height: 0.06)))
            massing.add(.box(Box(x: margin + 0.08, y: y + 0.05, z: 0.03,
                                 width: span - 0.16, depth: bay - 0.1, height: 0.07)),
                        .lit(NeonStyle.litAccent))
        }
    }

    /// **Three station halls, one mark.** A rail station is 2×2 and expensive,
    /// so a city holds two or three — it owes the player identity rather than
    /// variety, and that identity is *long lit platforms*, which nothing else
    /// in this game's vocabulary has. What varies is what stands over them:
    /// a pitched train shed, a head building with a flat canopy, or nothing
    /// at all because the line is up on a viaduct.
    private static func trainShed(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        switch random.int(in: 0 ... 2) {
        case 0: pitchedShed(footprint, &massing, &random)
        case 1: terminus(footprint, &massing, &random)
        default: viaduct(footprint, &massing, &random)
        }
    }

    /// Two lit platforms running the length of the lot. Every rail station
    /// starts here; the three forms differ in what they put above.
    private static func platforms(
        _ margin: CGFloat, _ span: CGFloat, _ depth: CGFloat, _ z: CGFloat,
        _ massing: inout BuildingMassing
    ) {
        for side in [CGFloat(0), 1] {
            let y = margin + side * (span - depth)
            massing.add(.box(Box(x: margin, y: y, z: z,
                                 width: span, depth: depth, height: 0.12)))
            massing.add(.box(Box(x: margin + 0.05, y: y + 0.04, z: z + 0.12,
                                 width: span - 0.1, depth: depth - 0.08, height: 0.03)),
                        .lit(NeonStyle.litAccent))
        }
    }

    /// The classic: a ridge spanning both platforms, standing clear of them so
    /// the roof reads as a roof rather than as a third storey.
    private static func pitchedShed(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.12
        let span = footprint - margin * 2
        platforms(margin, span, CGFloat(random.value(in: 0.34 ... 0.44)), 0, &massing)

        let eaves = CGFloat(random.value(in: 0.46 ... 0.62))
        for corner in [(CGFloat(0), CGFloat(0)), (1, 0), (0, 1), (1, 1)] {
            massing.add(.box(Box(
                x: margin + corner.0 * (span - 0.09),
                y: margin + corner.1 * (span - 0.09),
                z: 0, width: 0.09, depth: 0.09, height: eaves
            )))
        }
        massing.add(.ridge(Ridge(x: margin - 0.04, y: margin - 0.04, z: eaves,
                                 width: span + 0.08, depth: span + 0.08,
                                 height: CGFloat(random.value(in: 0.28 ... 0.40)))))
    }

    /// A head building at one end with the platforms running out of it under a
    /// flat canopy. The tallest of the three, and the only one with windows —
    /// which is what makes it read as a place you walk into.
    private static func terminus(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.12
        let span = footprint - margin * 2
        let head = CGFloat(random.value(in: 0.42 ... 0.58))
        let hall = Box(x: margin, y: margin, z: 0, width: span, depth: head,
                       height: CGFloat(random.value(in: 0.85 ... 1.15)))
        massing.add(.box(hall))
        windows(on: hall, rows: 2, columns: 4, chance: 0.75, &massing, &random)
        doorway(on: hall, width: 0.3, &massing)
        // A clerestory band along the top, which is what a concourse has and a
        // shed does not.
        massing.add(.box(Box(x: hall.x - 0.05, y: hall.y - 0.05, z: hall.height,
                             width: hall.width + 0.1, depth: hall.depth + 0.1, height: 0.07)))

        // The platforms occupy what is left, under a flat canopy on posts.
        let yard = span - head - 0.06
        platforms(margin, span, yard / 2 - 0.03, 0, &massing)
        let canopy = CGFloat(random.value(in: 0.5 ... 0.66))
        for corner in [(CGFloat(0), CGFloat(0)), (1, 0), (0, 1), (1, 1)] {
            massing.add(.box(Box(
                x: margin + corner.0 * (span - 0.08),
                y: margin + head + 0.06 + corner.1 * Swift.max(0.01, yard - 0.08),
                z: 0, width: 0.08, depth: 0.08, height: canopy
            )))
        }
        massing.add(.box(Box(x: margin - 0.04, y: margin + head + 0.02, z: canopy,
                             width: span + 0.08, depth: yard + 0.08, height: 0.06)))
    }

    /// The line up on arches, with the platforms a storey above the street.
    /// No roof at all — the height *is* the silhouette, and it is the one
    /// station you can see over a block of flats.
    private static func viaduct(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.12
        let span = footprint - margin * 2
        let deck = CGFloat(random.value(in: 0.62 ... 0.85))
        let depth = CGFloat(random.value(in: 0.32 ... 0.42))

        // Piers: two rows of them, under where each platform lands, so the
        // structure reads as carrying the deck rather than standing beside it.
        let piers = random.int(in: 3 ... 4)
        for side in [CGFloat(0), 1] {
            let y = margin + side * (span - depth) + depth / 2
            for pier in 0 ..< piers {
                let t = CGFloat(pier) / CGFloat(piers - 1)
                massing.add(.cylinder(Cylinder(
                    x: margin + 0.1 + t * (span - 0.2), y: y,
                    z: 0, radius: 0.07, height: deck
                )))
            }
        }
        massing.add(.box(Box(x: margin - 0.03, y: margin - 0.03, z: deck - 0.1,
                             width: span + 0.06, depth: span + 0.06, height: 0.1)))
        platforms(margin, span, depth, deck, &massing)
        // A sign mast on the deck, so the station is findable when the camera
        // is far enough out that the platforms have stopped resolving.
        massing.add(.box(Box(x: margin + 0.06, y: margin + span / 2 - 0.035,
                             z: deck + 0.12, width: 0.07, depth: 0.07, height: 0.3)))
        massing.add(.box(Box(x: margin, y: margin + span / 2 - 0.06,
                             z: deck + 0.4, width: 0.22, depth: 0.12, height: 0.06)),
                    .lit(NeonStyle.litAccent))
    }

    /// **Three tram stops, one mark.** A tram stop is 1×1 and strung along a
    /// route in numbers, so it has the park's problem rather than the fire
    /// station's. What stays constant is a low kerbed island with a lit edge
    /// and a mast standing off it — nothing else in this game has that, which
    /// is what keeps it apart from the bus canopy and the subway's lit mouth.
    /// What varies is how many islands there are and what the mast carries.
    private static func tramPlatform(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        switch random.int(in: 0 ... 2) {
        case 0: islandStop(footprint, &massing, &random)
        case 1: pairedIslands(footprint, &massing, &random)
        default: screenedIsland(footprint, &massing, &random)
        }
    }

    /// One island with a lit edge and a mast — the plain version.
    private static func islandStop(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin = CGFloat(random.value(in: 0.16 ... 0.24))
        let length = footprint - margin * 2
        let width = CGFloat(random.value(in: 0.30 ... 0.42))
        island(margin, (footprint - width) / 2, length, width, &massing)
        mast(margin + 0.05, (footprint - width) / 2 + width / 2, &massing, &random)
    }

    /// Two narrow islands either side of the centre line, with a catenary
    /// boom reaching across both.
    ///
    /// The gap down the middle was the first version's only mark, and the
    /// contact sheet showed why that was not enough: two 0.2-wide islands a
    /// fifth of a tile apart merge into one island the moment the camera
    /// pulls back, so all three tram stops read as the same drawing. The boom
    /// is a **horizontal above the roofline** — a line at the top of the
    /// silhouette where the other two have only a mast head — and that
    /// survives the downsample, which is the whole of `minimumDetailSize`'s
    /// argument applied to massing rather than to marks.
    private static func pairedIslands(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin = CGFloat(random.value(in: 0.13 ... 0.19))
        let length = footprint - margin * 2
        let width = CGFloat(random.value(in: 0.17 ... 0.23))
        let gap = CGFloat(random.value(in: 0.18 ... 0.26))
        for side in [CGFloat(0), 1] {
            island(margin, footprint / 2 - gap / 2 - width + side * (gap + width),
                   length, width, &massing)
        }
        let pole = CGFloat(random.value(in: 0.66 ... 0.82))
        massing.add(.box(Box(x: margin + 0.04, y: footprint / 2 - 0.035, z: 0,
                             width: 0.07, depth: 0.07, height: pole)))
        // The boom, running the length of the stop over both islands, with the
        // lit wire slung under it.
        let reach = gap + width * 2 + 0.12
        massing.add(.box(Box(x: margin + 0.04, y: footprint / 2 - reach / 2, z: pole - 0.06,
                             width: 0.06, depth: reach, height: 0.06)))
        massing.add(.box(Box(x: margin + 0.05, y: footprint / 2 - reach / 2 + 0.03,
                             z: pole - 0.1, width: 0.04, depth: reach - 0.06, height: 0.03)),
                    .lit(NeonStyle.litAccent))
    }

    /// One island with a glass screen down its back — a shelter without a
    /// canopy, which is what keeps it a tram stop rather than a bus one.
    private static func screenedIsland(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin = CGFloat(random.value(in: 0.16 ... 0.22))
        let length = footprint - margin * 2
        let width = CGFloat(random.value(in: 0.30 ... 0.40))
        let y = (footprint - width) / 2
        island(margin, y, length, width, &massing)
        // Tall enough that the slab, not the mast, is the tallest thing in
        // the silhouette — which is what tells this one apart from the plain
        // island at the zoom the game is actually played at.
        let screen = Box(x: margin + 0.04, y: y + width - 0.06, z: 0.1,
                         width: length - 0.08, depth: 0.05,
                         height: CGFloat(random.value(in: 0.46 ... 0.58)))
        massing.add(.box(screen))
        massing.panels.append(Panel(box: screen, face: .right, u0: 0.1, u1: 0.9,
                                    v0: 0.15, v1: 0.85, color: NeonStyle.litAccent))
        mast(margin + 0.05, y + width / 2, &massing, &random)
    }

    /// A kerb with a lit edge on top. The lit edge is the one mark that
    /// survives being twenty points across, and the reason the platform reads
    /// as a platform rather than as a kerb.
    private static func island(
        _ x: CGFloat, _ y: CGFloat, _ length: CGFloat, _ width: CGFloat,
        _ massing: inout BuildingMassing
    ) {
        massing.add(.box(Box(x: x, y: y, z: 0, width: length, depth: width, height: 0.1)))
        massing.add(.box(Box(x: x + 0.04, y: y + 0.04, z: 0.1,
                             width: length - 0.08, depth: Swift.max(0.02, width - 0.08),
                             height: 0.03)),
                    .lit(NeonStyle.litAccent))
    }

    /// The mast, at the near end so it sorts in front of the platform rather
    /// than through it — the same rule the firehouse tower had to learn when
    /// it came out looking like an industrial chimney.
    private static func mast(
        _ x: CGFloat, _ y: CGFloat,
        _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let height = CGFloat(random.value(in: 0.55 ... 0.72))
        massing.add(.box(Box(x: x, y: y - 0.035, z: 0, width: 0.07, depth: 0.07, height: height)))
        massing.add(.box(Box(x: x - 0.07, y: y - 0.06, z: height,
                             width: 0.2, depth: 0.12, height: 0.05)),
                    .lit(NeonStyle.litAccent))
    }

    /// **Three entrances, one mark.** A subway entrance is 1×1 and a line is
    /// a row of them, so it earns forms for the same reason the park and the
    /// tram stop do. The constant is a **lit mouth at ground level** — the
    /// hole you walk into — which nothing else in the game draws.
    private static func subwayEntrance(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        switch random.int(in: 0 ... 2) {
        case 0: headhouse(footprint, &massing, &random)
        case 1: stairwell(footprint, &massing, &random)
        default: entranceTower(footprint, &massing, &random)
        }
    }

    /// A headhouse with a lit mouth and a canopy over it.
    private static func headhouse(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin = CGFloat(random.value(in: 0.2 ... 0.3))
        let box = Box(x: margin, y: margin, z: 0,
                      width: footprint - margin * 2, depth: footprint - margin * 2,
                      height: CGFloat(random.value(in: 0.34 ... 0.46)))
        massing.add(.box(box))
        for face in [Panel.Face.right, .left] {
            massing.panels.append(Panel(box: box, face: face, u0: 0.18, u1: 0.82,
                                        v0: 0, v1: 0.72, color: NeonStyle.litAccent))
        }
        massing.add(.box(Box(x: box.x - 0.08, y: box.y - 0.08, z: box.height,
                             width: box.width + 0.16, depth: box.depth + 0.16, height: 0.06)))
    }

    /// An open stair going down: a balustrade around a lit well, with a sign
    /// standing beside it. The only transit building with *no* mass above the
    /// kerb, which is exactly what makes it read as a hole in the pavement.
    private static func stairwell(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin = CGFloat(random.value(in: 0.2 ... 0.28))
        let span = footprint - margin * 2
        // The lit well first, so the balustrade sorts in front of it.
        massing.add(.box(Box(x: margin + 0.06, y: margin + 0.06, z: 0,
                             width: span - 0.12, depth: span - 0.12, height: 0.05)),
                    .lit(NeonStyle.litAccent))
        let rail = CGFloat(random.value(in: 0.16 ... 0.22))
        for side in 0 ..< 4 {
            let horizontal = side % 2 == 0
            let far = side >= 2
            massing.add(.box(Box(
                x: margin + (horizontal ? 0 : far ? span - 0.05 : 0),
                y: margin + (horizontal ? (far ? span - 0.05 : 0) : 0),
                z: 0, width: horizontal ? span : 0.05, depth: horizontal ? 0.05 : span,
                height: rail
            )))
        }
        mast(margin - 0.04, margin + span / 2, &massing, &random)
    }

    /// A narrow tower with the mouth at its foot and a lit crown on top — the
    /// version that stands up over a dense block, where a headhouse would be
    /// lost between two towers.
    private static func entranceTower(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin = CGFloat(random.value(in: 0.3 ... 0.38))
        let shaft = Box(x: margin, y: margin, z: 0,
                        width: footprint - margin * 2, depth: footprint - margin * 2,
                        height: CGFloat(random.value(in: 0.8 ... 1.05)))
        massing.add(.box(shaft))
        for face in [Panel.Face.right, .left] {
            massing.panels.append(Panel(box: shaft, face: face, u0: 0.2, u1: 0.8,
                                        v0: 0, v1: 0.3, color: NeonStyle.litAccent))
        }
        massing.add(.box(Box(x: shaft.x - 0.05, y: shaft.y - 0.05, z: shaft.height,
                             width: shaft.width + 0.1, depth: shaft.depth + 0.1, height: 0.07)),
                    .lit(NeonStyle.litAccent))
    }

    /// A tank on legs — the silhouette that carries this zone, and one the
    /// projection renders far better than an elevation could.
    private static func waterTower(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let centre = footprint / 2
        let legHeight = CGFloat(random.value(in: 0.85 ... 1.2))
        let spread = CGFloat(random.value(in: 0.42 ... 0.56))
        for corner in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
            massing.add(.box(Box(
                x: centre + CGFloat(corner.0) * spread - 0.05,
                y: centre + CGFloat(corner.1) * spread - 0.05,
                z: 0, width: 0.1, depth: 0.1, height: legHeight
            )))
        }
        let radius = CGFloat(random.value(in: 0.6 ... 0.78))
        massing.add(.cylinder(Cylinder(x: centre, y: centre, z: legHeight,
                                       radius: radius, height: CGFloat(random.value(in: 0.55 ... 0.75)))))
        // A small pumphouse at the foot, so the lot is not just legs.
        massing.add(.box(Box(x: centre - 0.3, y: centre + spread - 0.1, z: 0,
                             width: 0.6, depth: 0.34, height: 0.3)))
    }

    /// The starter pump: low and wide, so a glance says "the small one"
    /// against the tower's height.
    private static func waterPump(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.14
        let shed = Box(x: margin, y: margin, z: 0,
                       width: footprint - margin * 2, depth: footprint - margin * 2,
                       height: CGFloat(random.value(in: 0.3 ... 0.4)))
        massing.add(.box(shed))
        windows(on: shed, rows: 1, columns: 2, chance: 0.6, &massing, &random)
        massing.add(.cylinder(Cylinder(x: footprint / 2, y: footprint / 2, z: shed.height,
                                       radius: 0.11, height: CGFloat(random.value(in: 0.2 ... 0.32)))))
    }

    /// The starter generator: a shed with an exhaust stack, against the power
    /// plant's cooling towers.
    private static func generator(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.16
        let shed = Box(x: margin, y: margin, z: 0,
                       width: footprint - margin * 2, depth: footprint - margin * 2,
                       height: CGFloat(random.value(in: 0.55 ... 0.72)))
        massing.add(.box(shed))
        windows(on: shed, rows: 1, columns: 3, chance: 0.55, &massing, &random)
        massing.add(.cylinder(Cylinder(
            x: shed.x + shed.width * CGFloat(random.value(in: 0.25 ... 0.75)),
            y: shed.y + shed.depth * CGFloat(random.value(in: 0.25 ... 0.75)),
            z: shed.height, radius: 0.13, height: CGFloat(random.value(in: 0.55 ... 0.85))
        )))
        for _ in 0 ..< random.int(in: 1 ... 2) {
            let size = CGFloat(random.value(in: 0.22 ... 0.34))
            massing.add(.box(Box(
                x: shed.x + CGFloat(random.value(in: 0 ... 1)) * (shed.width - size),
                y: shed.y + CGFloat(random.value(in: 0 ... 1)) * (shed.depth - size),
                z: shed.height, width: size, depth: size, height: 0.14
            )))
        }
    }

    /// **A quay with gantry cranes on it** — the mark every port in every
    /// game has, and the only silhouette in this game with an arm that
    /// reaches out over nothing. It has to read from across the map as
    /// *the docks*, because it is the one building whose whole point is
    /// where it sits.
    private static func seaport(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.1
        let span = footprint - margin * 2

        // The quay: a low deck over most of the lot, which is what a dock is
        // before anything is put on it.
        massing.add(.box(Box(x: margin, y: margin, z: 0,
                             width: span, depth: span * 0.62, height: 0.18)))

        // A shed at the back, with the lit doors a freight terminal has.
        let shed = Box(x: margin, y: margin + span * 0.68, z: 0,
                       width: span, depth: span * 0.32,
                       height: CGFloat(random.value(in: 0.55 ... 0.8)))
        massing.add(.box(shed))
        windows(on: shed, rows: 1, columns: 4, chance: 0.7, &massing, &random)

        // The cranes. Two or three, spaced along the quay — a gantry leg, a
        // tower, and a jib cantilevered out over the water. The jib is the
        // mark: nothing else in the game has a horizontal that ends in mid
        // air.
        let cranes = random.int(in: 2 ... 3)
        for index in 0 ..< cranes {
            let t = (CGFloat(index) + 0.5) / CGFloat(cranes)
            let x = margin + t * span
            let height = CGFloat(random.value(in: 0.9 ... 1.25))
            for leg in [CGFloat(-0.055), 0.055] {
                massing.add(.box(Box(x: x + leg - 0.025, y: margin + span * 0.16,
                                     z: 0.18, width: 0.05, depth: 0.05, height: height)))
            }
            // The jib, reaching out toward the water side of the lot.
            massing.add(.box(Box(x: x - 0.04, y: margin - 0.06, z: 0.18 + height,
                                 width: 0.08, depth: span * 0.46, height: 0.07)))
            massing.add(.box(Box(x: x - 0.05, y: margin - 0.08, z: 0.18 + height - 0.06,
                                 width: 0.1, depth: 0.07, height: 0.05)),
                        .lit(NeonStyle.litAccent))
        }

        // Containers on the quay, which is what says freight rather than
        // marina — and they have to be *big*. The first pass drew five of
        // them at 0.18 by 0.1, which is a fifth of a tile: on the contact
        // sheet they were specks on an empty deck, saying nothing. Three
        // boxes a player can see beats five they cannot, which is
        // `minimumDetailSize`'s rule applied to massing rather than to marks.
        for index in 0 ..< random.int(in: 2 ... 3) {
            let x = margin + span * (0.08 + CGFloat(index) * 0.3)
            let y = margin + span * CGFloat(random.value(in: 0.16 ... 0.34))
            let stack = random.int(in: 1 ... 2)
            for level in 0 ..< stack {
                massing.add(.box(Box(x: x, y: y, z: 0.18 + CGFloat(level) * 0.22,
                                     width: 0.42, depth: 0.26, height: 0.21)))
            }
        }
    }

    /// **A runway, a terminal and a control tower.**
    ///
    /// The runway is the identity mark, and it is a *lit* mark rather than a
    /// drawn one: a raised deck with a dashed centreline of glowing slabs.
    /// The first version drew the strip 0.03 tall with small lamps down the
    /// middle and the contact sheet showed nothing at all — a flat plane over
    /// flat ground has no edge in this projection to catch the light, and a
    /// lamp a twentieth of a tile across is below every floor this project
    /// has. A long dashed line of light is a shape nothing else in the game
    /// draws, and light is the one thing `RetroShader`'s vignette cannot
    /// crush.
    ///
    /// Two things were tried and cut, and both are recorded in the body:
    /// there is no full-lot apron, because a slab that spans the lot paints
    /// over everything standing on it, and there is no aircraft, because at
    /// three tiles across its parts merge into a crate.
    private static func airport(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.08
        let span = footprint - margin * 2

        // **There is no full-lot apron**, and that is not a simplification.
        // A slab covering the whole lot sits at the lot's centre, so the
        // painter's algorithm draws it *after* the runway at the back and
        // *with* the aircraft in the middle — and it painted over both. The
        // first two versions of this building were a runway and a plane that
        // were drawn correctly and then buried under their own hardstanding.
        //
        // The general shape, which has bitten this project before in the
        // draw-order ties on the hospital's cross: **a volume that spans the
        // lot has no useful depth key**, so it can only be the frontmost or
        // the backmost thing. Everything here is laid out back to front by
        // `y` instead — runway, aircraft, terminal, tower — and the lot's own
        // ground diamond is the hardstanding.
        let runway = Box(x: margin, y: margin, z: 0,
                         width: span, depth: span * 0.26, height: 0.1)
        massing.add(.box(runway))

        // The centreline, as a row of big lit slabs. This is the identity
        // mark, and it is drawn the size industry's lit bays are drawn —
        // those read at every zoom, and the first attempt at 0.055 by 0.03
        // did not read at any. A dashed line of light down a deck is a shape
        // nothing else in this game has.
        let dashes = 5
        for index in 0 ..< dashes {
            let t = (CGFloat(index) + 0.5) / CGFloat(dashes)
            massing.add(.box(Box(x: margin + t * span - 0.17,
                                 y: runway.y + runway.depth / 2 - 0.05,
                                 z: 0.1, width: 0.34, depth: 0.1, height: 0.05)),
                        .lit(NeonStyle.litAccent))
        }

        // **There is no aircraft**, and it was tried twice. A plane is a
        // fuselage, a wing and a fin, and at three tiles across the wing is
        // a tenth of a tile thick — so the three volumes merged into one
        // lump that read as a crate parked beside the runway. Scaled up
        // enough to separate, it stopped being a plane and became a hangar.
        //
        // That is `minimumDetailSize`'s rule reaching massing again: **if a
        // mark cannot be drawn big enough to read, cut it rather than shrink
        // the building around it.** The runway carries this lot on its own,
        // and an airport is mostly open ground anyway.

        // The terminal, across the near edge, where a plane would face it.
        let terminal = Box(x: margin + span * 0.06, y: margin + span * 0.74, z: 0,
                           width: span * 0.88, depth: span * 0.18,
                           height: CGFloat(random.value(in: 0.5 ... 0.72)))
        massing.add(.box(terminal))
        windows(on: terminal, rows: 2, columns: 5, chance: 0.8, &massing, &random)

        // The control tower: the one vertical on an otherwise flat lot.
        let tower = CGFloat(random.value(in: 1.1 ... 1.5))
        let towerX = margin + span * CGFloat(random.value(in: 0.1 ... 0.8))
        massing.add(.box(Box(x: towerX, y: margin + span * 0.94, z: 0,
                             width: 0.12, depth: 0.12, height: tower)))
        massing.add(.box(Box(x: towerX - 0.045, y: margin + span * 0.94 - 0.045,
                             z: tower, width: 0.21, depth: 0.21, height: 0.12)),
                    .lit(NeonStyle.litAccent))
    }

    /// **Four kinds of park, not one lawn at four sizes.**
    ///
    /// A park is 1×1 and cheap, so a city ends up with a great many of them —
    /// which puts it on the wrong side of the rule that lets a *service* get
    /// away with little variety. "A city has two fire stations" is why a
    /// firehouse only owes the player an identity; it is simply not true of
    /// the things you thread between every other block, and a row of identical
    /// lawns reads as wallpaper exactly the way a row of identical houses
    /// would.
    ///
    /// The four stay apart in **silhouette** rather than in planting — trees,
    /// water, a roof, a flat court — because that is what survives being
    /// twenty points across. Each still sits on the same low kerb, which is
    /// what stops any of them reading as bare ground with something dropped
    /// on it.
    ///
    /// **No lit mark on the ground, and none needed.** `Panel` only draws on
    /// the two visible *walls* — there is no top face to paint a path on — but
    /// what keeps a park readable once the camera pulls back is
    /// `syncGroundGlow`, which already throws a pool of the zone's colour onto
    /// every service lot. A park's pool is the only green one on the map.
    private static func park(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.12
        let span = footprint - margin * 2
        massing.add(.box(Box(x: margin, y: margin, z: 0,
                             width: span, depth: span, height: 0.06)))

        switch random.int(in: 0 ... 3) {
        case 0: grove(margin, span, &massing, &random)
        case 1: pond(margin, span, &massing, &random)
        case 2: pavilion(margin, span, &massing, &random)
        default: court(margin, span, &massing, &random)
        }
    }

    /// Trees, which is what a park looks like from a distance.
    private static func grove(
        _ margin: CGFloat, _ span: CGFloat,
        _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        for _ in 0 ..< random.int(in: 2 ... 4) {
            let inset = margin + 0.14
            let free = Swift.max(0.01, span - 0.28)
            let x = inset + CGFloat(random.value(in: 0 ... 1)) * free
            let y = inset + CGFloat(random.value(in: 0 ... 1)) * free
            let height = CGFloat(random.value(in: 0.34 ... 0.52))
            massing.add(.cylinder(Cylinder(x: x, y: y, z: 0.06, radius: 0.028, height: height * 0.45)))
            massing.add(.cylinder(Cylinder(
                x: x, y: y, z: 0.06 + height * 0.45,
                radius: CGFloat(random.value(in: 0.1 ... 0.15)), height: height * 0.55
            )))
        }
    }

    /// A lit pool with a bank around it — the one park with no vertical mass
    /// at all, which is what makes it unmistakable from across the map even
    /// though it is the quietest thing on it.
    private static func pond(
        _ margin: CGFloat, _ span: CGFloat,
        _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let inset = CGFloat(random.value(in: 0.14 ... 0.22))
        let water = Box(x: margin + inset, y: margin + inset, z: 0.06,
                        width: span - inset * 2, depth: span - inset * 2, height: 0.035)
        massing.add(.box(water), .lit(NeonStyle.waterAccent))
        for _ in 0 ..< random.int(in: 1 ... 2) {
            let x = margin + CGFloat(random.value(in: 0.03 ... 0.1))
            let y = margin + CGFloat(random.value(in: 0.1 ... 0.85)) * Swift.max(0.01, span)
            let height = CGFloat(random.value(in: 0.28 ... 0.42))
            massing.add(.cylinder(Cylinder(x: x, y: y, z: 0.06, radius: 0.025, height: height * 0.45)))
            massing.add(.cylinder(Cylinder(x: x, y: y, z: 0.06 + height * 0.45,
                                           radius: 0.1, height: height * 0.55)))
        }
    }

    /// A bandstand: a lit deck under a pitched roof on posts. The only park
    /// with a roof, and the tallest of the four.
    private static func pavilion(
        _ margin: CGFloat, _ span: CGFloat,
        _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let inset = CGFloat(random.value(in: 0.16 ... 0.26))
        let width = span - inset * 2
        let deck = Box(x: margin + inset, y: margin + inset, z: 0.06,
                       width: width, depth: width, height: 0.05)
        massing.add(.box(deck), .lit(NeonStyle.litAccent))
        let posts = CGFloat(random.value(in: 0.3 ... 0.42))
        for corner in [(CGFloat(0), CGFloat(0)), (1, 0), (0, 1), (1, 1)] {
            massing.add(.box(Box(
                x: deck.x + corner.0 * (width - 0.055),
                y: deck.y + corner.1 * (width - 0.055),
                z: 0.11, width: 0.055, depth: 0.055, height: posts
            )))
        }
        massing.add(.ridge(Ridge(x: deck.x - 0.05, y: deck.y - 0.05, z: 0.11 + posts,
                                 width: width + 0.1, depth: width + 0.1,
                                 height: CGFloat(random.value(in: 0.14 ... 0.22)))))
    }

    /// A ball court: a lit slab between two posts. Flat like the pond and
    /// man-made like the pavilion, which is what keeps it apart from both.
    private static func court(
        _ margin: CGFloat, _ span: CGFloat,
        _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let inset = CGFloat(random.value(in: 0.1 ... 0.16))
        let slab = Box(x: margin + inset, y: margin + inset, z: 0.06,
                       width: span - inset * 2, depth: span - inset * 2, height: 0.04)
        massing.add(.box(slab), .lit(NeonStyle.litAccent))
        let posts = CGFloat(random.value(in: 0.26 ... 0.4))
        for end in [CGFloat(0), 1] {
            massing.add(.box(Box(
                x: slab.x + slab.width / 2 - 0.03,
                y: slab.y + end * Swift.max(0.01, slab.depth - 0.06),
                z: 0.1, width: 0.06, depth: 0.06, height: posts
            )))
        }
    }

    private static func school(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.1
        let body = Box(x: margin, y: margin, z: 0,
                       width: footprint - margin * 2, depth: footprint - margin * 2,
                       height: CGFloat(random.value(in: 0.62 ... 0.8)))
        massing.add(.box(body))
        windows(on: body, rows: 1, columns: 4, chance: 0.85, &massing, &random)
        doorway(on: body, width: 0.18, &massing)
        massing.add(.ridge(Ridge(
            x: body.x - 0.06, y: body.y - 0.06, z: body.height,
            width: body.width + 0.12, depth: body.depth + 0.12,
            height: CGFloat(random.value(in: 0.34 ... 0.48)),
            axis: random.chance(0.5) ? .x : .y
        )))
        // The bell tower, with a lit clock face.
        //
        // It has to clear the ridge, not merely start at the eaves. Sized
        // against the body alone it ended up shorter than the roof it sits in
        // and read as a roof vent — which is nothing, where a clock tower is
        // the mark that separates a school from every other civic block.
        let centre = footprint / 2
        let tower = Box(x: centre - 0.15, y: centre - 0.15, z: body.height,
                        width: 0.3, depth: 0.3, height: CGFloat(random.value(in: 0.85 ... 1.15)))
        massing.add(.box(tower))
        for face in [Panel.Face.right, .left] {
            massing.panels.append(Panel(box: tower, face: face, u0: 0.2, u1: 0.8,
                                        v0: 0.45, v1: 0.85, color: NeonStyle.litAccent))
        }
    }

    /// A blocky ward with a lit cross on the roof.
    private static func hospital(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.12
        let body = Box(x: margin, y: margin, z: 0,
                       width: footprint - margin * 2, depth: footprint - margin * 2,
                       height: CGFloat(random.value(in: 1.0 ... 1.4)))
        massing.add(.box(body))
        windows(on: body, rows: max(2, Int(body.height / 0.34)), columns: 4, chance: 0.8, &massing, &random)
        // An entrance canopy — the drop-off every hospital has.
        massing.add(.box(Box(x: body.x + body.width * 0.25, y: body.y + body.depth, z: 0,
                             width: body.width * 0.5, depth: margin * 0.8, height: 0.34)))
        doorway(on: body, width: 0.3, &massing)

        massing.add(.box(Box(x: body.x - 0.03, y: body.y - 0.03, z: body.height,
                             width: body.width + 0.06, depth: body.depth + 0.06, height: 0.07)))
        // The cross: two crossed bars, lit. Nothing else in the game draws one.
        let centre = footprint / 2
        let arm = CGFloat(random.value(in: 0.44 ... 0.58))
        let bar: CGFloat = 0.16
        let z = body.height + 0.07
        // The two arms are given slightly different heights on purpose. Sharing
        // a centre and an elevation makes them a tie in every sort key, so which
        // one lands on top is down to insertion order, and at some seeds the
        // cross collapsed into a single bar. A hair of separation makes the
        // ordering deterministic and the plus always read as a plus.
        massing.add(.box(Box(x: centre - arm / 2, y: centre - bar / 2, z: z,
                             width: arm, depth: bar, height: 0.1)), .lit(NeonStyle.litAccent))
        massing.add(.box(Box(x: centre - bar / 2, y: centre - arm / 2, z: z,
                             width: bar, depth: arm, height: 0.115)), .lit(NeonStyle.litAccent))
    }

    /// Cooling towers over a base building.
    ///
    /// A real cooling tower has a hyperboloid waist, which no primitive here
    /// draws. Three stacked cylinders — wide base, narrow waist, flared crown —
    /// give the same read at this size for a third of the geometry, which is
    /// the same trade `Cylinder`'s ten sides make.
    ///
    /// **And it has to dominate, which it did not.** Measured before touching
    /// it: the towers topped out at 1.9 tile units, against an ordinary
    /// tier-3 block of flats at 2.9 and a tier-3 office at 4.8. So the
    /// single most industrial thing a player can build — nine lots of ground,
    /// the most expensive building in the game — stood shorter than the
    /// housing around it, and read as a *bigger service building* rather than
    /// as something a view is about. Covering more ground is not dominating.
    ///
    /// The towers are roughly twice as tall now, and a stack stands beside
    /// them, which is the other half of what a power station's silhouette
    /// actually is. It deliberately borrows `IndustrialMassing`'s landmark
    /// language — slender, very tall, on a plinth — because a player reading a
    /// skyline should not have to learn two vocabularies for the same idea.
    private static func powerPlant(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.14
        let hall = Box(x: margin, y: footprint * 0.52, z: 0,
                       width: footprint - margin * 2, depth: footprint * 0.48 - margin,
                       height: CGFloat(random.value(in: 0.7 ... 0.95)))
        massing.add(.box(hall))
        windows(on: hall, rows: 1, columns: 4, chance: 0.6, &massing, &random)
        // The hazard stripe.
        massing.panels.append(Panel(box: hall, face: .left, u0: 0.1, u1: 0.9,
                                    v0: 0.68, v1: 0.88, color: NeonStyle.emberColor))

        let towers = random.int(in: 1 ... 2)
        for index in 0 ..< towers {
            let radius = CGFloat(random.value(in: 0.44 ... 0.58))
            let x = towers == 1
                ? footprint / 2
                : footprint * (index == 0 ? 0.28 : 0.72)
            let y = footprint * 0.26
            let height = CGFloat(random.value(in: 2.8 ... 3.6))
            massing.add(.cylinder(Cylinder(x: x, y: y, z: 0, radius: radius, height: height * 0.45)))
            massing.add(.cylinder(Cylinder(x: x, y: y, z: height * 0.45,
                                           radius: radius * 0.72, height: height * 0.35)))
            massing.add(.cylinder(Cylinder(x: x, y: y, z: height * 0.8,
                                           radius: radius * 0.88, height: height * 0.2)))
        }

        // The stack. Set behind the hall, up-screen, so it does not paint over
        // the towers it stands among — a volume that spans a lot has no useful
        // depth key, which this file already records against the airport's
        // apron.
        let stackRadius = CGFloat(random.value(in: 0.13 ... 0.16))
        let stackX = footprint * (towers == 1 ? 0.78 : 0.5)
        let plinth = Box(x: stackX - stackRadius * 1.9, y: footprint * 0.86 - stackRadius * 1.9,
                         z: 0, width: stackRadius * 3.8, depth: stackRadius * 3.8,
                         height: CGFloat(random.value(in: 0.26 ... 0.36)))
        massing.add(.box(plinth))
        massing.add(.cylinder(Cylinder(
            x: stackX, y: footprint * 0.86, z: plinth.height,
            radius: stackRadius, height: CGFloat(random.value(in: 4.2 ... 5.2))
        )))
    }

    /// A bowl: four stands around a lit field, with floodlights at the corners.
    ///
    /// **A stadium dominates by mass and light rather than by height**, which
    /// is what makes it a different answer from the power plant beside it in
    /// this file — and the first version did neither. It topped out at 1.8
    /// tile units, shorter than the flats across the road, so nine lots of
    /// ground bought a low ring nobody could pick out.
    ///
    /// Three changes, and the roof is the one that matters: a cantilevered
    /// canopy projecting *inward* over the stands is the silhouette every
    /// stadium in the world has and nothing else in this game does. Taller
    /// stands under it, and floodlight masts that clear the roof by half
    /// again, so the four lit heads sit above everything around them — which
    /// is what a floodlit ground looks like from across a city at night.
    private static func stadium(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.12
        let outer = footprint - margin * 2
        let stand = CGFloat(random.value(in: 0.5 ... 0.66))
        let height = CGFloat(random.value(in: 1.1 ... 1.4))

        // Four stands forming a ring, rather than one block with a hole: a
        // hole is not something a box can have.
        massing.add(.box(Box(x: margin, y: margin, z: 0, width: outer, depth: stand, height: height)))
        massing.add(.box(Box(x: margin, y: footprint - margin - stand, z: 0,
                             width: outer, depth: stand, height: height)))
        massing.add(.box(Box(x: margin, y: margin + stand, z: 0,
                             width: stand, depth: outer - stand * 2, height: height)))
        massing.add(.box(Box(x: footprint - margin - stand, y: margin + stand, z: 0,
                             width: stand, depth: outer - stand * 2, height: height)))

        // The pitch, glowing.
        massing.add(.box(Box(x: margin + stand, y: margin + stand, z: 0,
                             width: outer - stand * 2, depth: outer - stand * 2, height: 0.06)),
                    .lit(NeonStyle.litAccent))

        // The canopy: a thin ring standing on the stands and reaching a little
        // way in over them. Four slabs rather than one, for the reason the
        // stands are four — a box cannot have a hole in it.
        //
        // **A narrow eave, and the first version was a roof.** At an overhang
        // of 0.3 on stands raised to 1.9 the render came back a solid block:
        // the canopy had closed over the pitch, and the lit field is the one
        // mark that makes a stadium findable while scanning a city. That is
        // the airport's apron again — *a volume that spans the lot paints over
        // everything standing in it* — and the answer is the same as it was
        // for the runway: the identity mark wins, and the bulk goes somewhere
        // it does not cost anything. Here that is the masts.
        let overhang = CGFloat(random.value(in: 0.08 ... 0.14))
        let roof: CGFloat = 0.12
        let canopy = stand + overhang
        for (x, y, w, d) in [
            (margin, margin, outer, canopy),
            (margin, footprint - margin - canopy, outer, canopy),
            (margin, margin + canopy, canopy, outer - canopy * 2),
            (footprint - margin - canopy, margin + canopy, canopy, outer - canopy * 2),
        ] where w > 0 && d > 0 {
            massing.add(.box(Box(x: x, y: y, z: height, width: w, depth: d, height: roof)))
        }

        // **Inset by the head's own half-width**, which
        // `testMassingStaysInsideItsFootprint` caught the moment the head was
        // enlarged: a mast standing exactly on the lot's corner hangs whatever
        // sits on top of it over the neighbour. The old head was small enough
        // to get away with it by a hundredth of a tile, which is the kind of
        // margin that is not a decision.
        let headHalf: CGFloat = 0.17
        for corner in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
            let x = margin + headHalf + CGFloat(corner.0) * (outer - headHalf * 2)
            let y = margin + headHalf + CGFloat(corner.1) * (outer - headHalf * 2)
            let mast = CGFloat(random.value(in: 2.2 ... 2.8))
            massing.add(.cylinder(Cylinder(x: x, y: y, z: height + roof, radius: 0.06,
                                           height: mast)))
            // The lit head, sized to be seen from across the map rather than
            // to be in proportion: this is the mark the whole building is
            // recognised by when it is twenty points across.
            massing.add(.box(Box(x: x - headHalf, y: y - headHalf, z: height + roof + mast,
                                 width: headHalf * 2, depth: headHalf * 2, height: 0.16)),
                        .lit(NeonStyle.litAccent))
        }
    }
}
