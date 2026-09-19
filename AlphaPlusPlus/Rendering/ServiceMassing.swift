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
        case .waterTower: waterTower(footprint, &massing, &random)
        case .waterPump: waterPump(footprint, &massing, &random)
        case .generator: generator(footprint, &massing, &random)
        case .park: park(footprint, &massing, &random)
        case .school: school(footprint, &massing, &random)
        case .hospital: hospital(footprint, &massing, &random)
        case .powerPlant: powerPlant(footprint, &massing, &random)
        case .stadium: stadium(footprint, &massing, &random)
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

    /// A shelter: a canopy on posts over a lit bench. One tile, so it says one
    /// thing.
    private static func transitStop(
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

    /// **A raised platform under a pole**, which is a tram stop's identity
    /// mark the world over and — more to the point here — nothing else in
    /// this game's vocabulary. A bus stop is four legs and a flat canopy; a
    /// subway is a headhouse with a lit mouth. This is a low kerbed island
    /// with a lit edge and a single mast standing off it, so the three read
    /// apart at a glance while scanning a corridor for coverage gaps, which
    /// is what these icons are for.
    private static func tramPlatform(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin = CGFloat(random.value(in: 0.16 ... 0.24))
        let length = footprint - margin * 2
        let width = CGFloat(random.value(in: 0.30 ... 0.42))
        let island = Box(x: margin, y: (footprint - width) / 2, z: 0,
                         width: length, depth: width, height: 0.1)
        massing.add(.box(island))
        // The lit edge: the one mark that survives being twenty points across,
        // and the reason the platform reads as a platform rather than a kerb.
        massing.add(.box(Box(x: margin + 0.04, y: (footprint - width) / 2 + 0.04, z: 0.1,
                             width: length - 0.08, depth: width - 0.08, height: 0.03)),
                    .lit(NeonStyle.litAccent))
        // And the mast, at the near end so it sorts in front of the platform
        // rather than through it — the same rule the firehouse tower had to
        // learn when it came out looking like an industrial chimney.
        let mast = CGFloat(random.value(in: 0.55 ... 0.72))
        massing.add(.box(Box(x: margin + 0.05, y: (footprint - width) / 2 + width / 2 - 0.035,
                             z: 0, width: 0.07, depth: 0.07, height: mast)))
        massing.add(.box(Box(x: margin - 0.02, y: (footprint - width) / 2 + width / 2 - 0.06,
                             z: mast, width: 0.2, depth: 0.12, height: 0.05)),
                    .lit(NeonStyle.litAccent))
    }

    /// A station entrance: a headhouse with a lit mouth and a canopy over it.
    private static func subwayEntrance(
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

    /// A low wide schoolhouse with a gable and a bell tower.
    ///
    /// Civic buildings get silhouettes nothing else in the game uses, because
    /// they are the two zones a player most needs to pick out while scanning
    /// for coverage gaps.
    /// A park: the only thing on this map that is not a building.
    ///
    /// **Drawn short and soft on purpose.** Every other civic block is a
    /// lit box with windows, and a park has to read as the *absence* of that
    /// from across the map — so it is a low hedge line, a few trees, and
    /// nothing above knee height. It also has to survive being 1×1, which is a
    /// quarter of the area every other service gets: at that size there is
    /// room for exactly one idea, and the idea is "trees".
    ///
    /// Trees are a trunk and a canopy, both cylinders, because a cylinder's
    /// top is a real ellipse catching light in this projection — the same
    /// thing that lets an industrial tank read as a drum rather than a box.
    private static func park(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.12
        let span = footprint - margin * 2

        // A low kerb around the lawn, which is what stops a park reading as
        // bare ground with something dropped on it.
        massing.add(.box(Box(x: margin, y: margin, z: 0,
                             width: span, depth: span, height: 0.06)))

        // Two or three trees, placed off-centre so no two parks line up.
        for _ in 0 ..< random.int(in: 2 ... 3) {
            let inset = margin + 0.14
            let free = Swift.max(0.01, span - 0.28)
            let x = inset + CGFloat(random.value(in: 0 ... 1)) * free
            let y = inset + CGFloat(random.value(in: 0 ... 1)) * free
            let height = CGFloat(random.value(in: 0.34 ... 0.52))
            let trunk = Cylinder(x: x, y: y, z: 0.06, radius: 0.028, height: height * 0.45)
            massing.add(.cylinder(trunk))
            massing.add(.cylinder(Cylinder(
                x: x, y: y, z: 0.06 + height * 0.45,
                radius: CGFloat(random.value(in: 0.1 ... 0.15)), height: height * 0.55
            )))
        }

        // **No lit mark on the ground, and none needed.** `Panel` only draws
        // on the two visible *walls* — there is no top face to paint a path
        // on — but the thing that keeps a park readable once the camera pulls
        // back is `syncGroundGlow`, which already throws a pool of the zone's
        // colour onto every service lot. A park's pool is the only green one
        // on the map, so it reads as a park from further out than the trees
        // survive, which is exactly the job.
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
            let radius = CGFloat(random.value(in: 0.42 ... 0.56))
            let x = towers == 1
                ? footprint / 2
                : footprint * (index == 0 ? 0.3 : 0.7)
            let y = footprint * 0.26
            let height = CGFloat(random.value(in: 1.3 ... 1.9))
            massing.add(.cylinder(Cylinder(x: x, y: y, z: 0, radius: radius, height: height * 0.45)))
            massing.add(.cylinder(Cylinder(x: x, y: y, z: height * 0.45,
                                           radius: radius * 0.72, height: height * 0.35)))
            massing.add(.cylinder(Cylinder(x: x, y: y, z: height * 0.8,
                                           radius: radius * 0.88, height: height * 0.2)))
        }
    }

    /// A bowl: four stands around a lit field, with floodlights at the corners.
    private static func stadium(
        _ footprint: CGFloat, _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.12
        let outer = footprint - margin * 2
        let stand = CGFloat(random.value(in: 0.5 ... 0.66))
        let height = CGFloat(random.value(in: 0.8 ... 1.1))

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

        for corner in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
            let x = margin + CGFloat(corner.0) * outer
            let y = margin + CGFloat(corner.1) * outer
            massing.add(.cylinder(Cylinder(x: x, y: y, z: height, radius: 0.06,
                                           height: CGFloat(random.value(in: 0.5 ... 0.72)))))
            massing.add(.box(Box(x: x - 0.11, y: y - 0.11, z: height + 0.5,
                                 width: 0.22, depth: 0.22, height: 0.1)),
                        .lit(NeonStyle.litAccent))
        }
    }
}
