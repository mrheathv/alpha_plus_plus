import SpriteKit

/// **The icons, described as volumes** — see `IconBuildings` for why they
/// exist and why there is one of each.
///
/// Each one is drawn from the reference images the player brought, and each
/// is built around one mark nothing else in the game has, because a building
/// that exists only to be looked at has to be unmistakable from across the
/// map:
///
/// | icon | the mark |
/// |---|---|
/// | Sunset Spire | Deco shoulders, a stepped lit crown and a needle — the tallest thing in the game |
/// | Harbour Tower | a crown of lit spikes over a shaft that narrows at every stage |
/// | Chrome Dome | a lit dome on a drum over a slim tower |
/// | Twin Masts | two slim towers, each carrying a pair of antennas |
/// | Night Market | pagoda eaves wrapped in stacked vertical neon signs |
///
/// **One variant, not thirty-two.** A growable zone tiles the map and needs
/// variety; a city has exactly one of each icon, so what it needs is the one
/// best version. The seed still varies small things (sign colours, which
/// antenna is taller) so the rule that a lot's look comes from its seed holds.
enum IconMassing {

    static func make(for zone: ZoneType, seed: GridPosition, footprint: CGFloat) -> BuildingMassing? {
        var random = BuildingRandom(seed: seed, salt: 600 + zone.rawValue.count)
        var massing = BuildingMassing()
        let accent = RenderPalette.fullColor(for: zone)
        switch zone {
        case .sunsetSpire: sunsetSpire(footprint, accent, &massing, &random)
        case .harbourTower: harbourTower(footprint, accent, &massing, &random)
        case .chromeDome: chromeDome(footprint, accent, &massing, &random)
        case .twinMasts: twinMasts(footprint, accent, &massing, &random)
        case .nightMarket: nightMarket(footprint, seed, &massing, &random)
        default: return nil
        }
        return massing
    }

    // MARK: - The icons

    /// **The Sunset Spire**: the Empire State silhouette standing in front of
    /// the sun in the third reference image. A tall shaft ribbed with lit
    /// vertical piers, three Deco shoulders each with a lit ledge, a crown of
    /// small stepped tiers, a lit lantern and a long needle. About thirteen
    /// tile units: a quarter taller than the Harbour Tower, and nearly half
    /// again the tallest skyscraper.
    private static func sunsetSpire(
        _ footprint: CGFloat, _ accent: SKColor,
        _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let podium = Box(x: 0.08, y: 0.08, z: 0, width: footprint - 0.16, depth: footprint - 0.16, height: 0.7)
        massing.add(.box(podium))
        CommercialMassing.shopfront(on: podium, share: 0.2 ... 0.62, into: &massing)

        var inset: CGFloat = 0.24
        var z = podium.height
        var shaft = Box(x: inset, y: inset, z: z, width: footprint - inset * 2,
                        depth: footprint - inset * 2, height: 5.8)
        for (index, height) in [5.8, 1.4, 1.0].enumerated() {
            shaft = Box(x: inset, y: inset, z: z, width: footprint - inset * 2,
                        depth: footprint - inset * 2, height: CGFloat(height))
            massing.add(.box(shaft))
            // Lit piers the height of the stage: the vertical emphasis that
            // makes Deco read as Deco rather than as a stack of boxes.
            let piers = index == 0 ? 5 : 3
            for face in [Panel.Face.right, .left] {
                for pier in 0 ..< piers {
                    let u = (CGFloat(pier) + 0.5) / CGFloat(piers)
                    massing.panels.append(Panel(box: shaft, face: face, u0: u - 0.035, u1: u + 0.035,
                                                v0: 0.04, v1: 0.96, color: NeonStyle.litAccent))
                }
                for gap in 0 ..< piers - 1 {
                    let u = CGFloat(gap + 1) / CGFloat(piers)
                    massing.panels.append(Panel(box: shaft, face: face, u0: u - 0.05, u1: u + 0.05,
                                                v0: 0.1, v1: 0.9, color: NeonStyle.windowColor(row: gap, column: index, salt: 3)))
                }
            }
            z += shaft.height
            massing.add(.box(Box(x: shaft.x - 0.03, y: shaft.y - 0.03, z: z, width: shaft.width + 0.06,
                                 depth: shaft.depth + 0.06, height: 0.07)), .lit(accent))
            z += 0.07
            inset += index == 0 ? 0.2 : 0.14
        }
        // The crown: four small tiers closing in, then the lantern.
        for step in 0 ..< 4 {
            let side = max(0.18, footprint - inset * 2 - CGFloat(step) * 0.1)
            let tier = Box(x: footprint / 2 - side / 2, y: footprint / 2 - side / 2, z: z,
                           width: side, depth: side, height: 0.22)
            massing.add(.box(tier))
            z += tier.height
        }
        let lantern = Box(x: footprint / 2 - 0.1, y: footprint / 2 - 0.1, z: z, width: 0.2, depth: 0.2, height: 0.3)
        massing.add(.box(lantern), .lit(accent))
        z += lantern.height
        let needle = CGFloat(random.value(in: 2.2 ... 2.5))
        massing.add(.cylinder(Cylinder(x: footprint / 2, y: footprint / 2, z: z, radius: 0.045,
                                       height: needle, sides: 8)))
        massing.add(.cylinder(Cylinder(x: footprint / 2, y: footprint / 2, z: z + needle, radius: 0.07,
                                       height: 0.12, sides: 8)), .lit(NeonStyle.litAccent))
    }

    /// **The Harbour Tower**: the Hong Kong supertall in the first reference
    /// image. A square shaft that narrows at every stage, glazed in
    /// continuous bands, with its corners picked out in light — and on top a
    /// ring of lit spikes, taller at the corners, which is the whole reason
    /// the real one is recognisable from anywhere in the harbour.
    private static func harbourTower(
        _ footprint: CGFloat, _ accent: SKColor,
        _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let podium = Box(x: 0.08, y: 0.08, z: 0, width: footprint - 0.16, depth: footprint - 0.16, height: 0.5)
        massing.add(.box(podium))
        CommercialMassing.shopfront(on: podium, share: 0.18 ... 0.64, into: &massing)

        var z = podium.height
        var stage = podium
        for (index, (inset, height)) in [(0.26, 3.4), (0.34, 2.4), (0.42, 1.8), (0.5, 1.2)].enumerated() {
            stage = Box(x: CGFloat(inset), y: CGFloat(inset), z: z,
                        width: footprint - CGFloat(inset) * 2, depth: footprint - CGFloat(inset) * 2,
                        height: CGFloat(height))
            massing.add(.box(stage))
            CommercialMassing.glazingBands(on: stage, into: &massing, random: &random)
            // The corners the camera can see, lit: a chamfer drawn in light.
            let t: CGFloat = 0.05
            for (x, y) in [(stage.x + stage.width - t / 2, stage.y - t / 2 + 0.001 * CGFloat(index)),
                           (stage.x + stage.width - t / 2, stage.y + stage.depth - t / 2),
                           (stage.x - t / 2 + 0.001 * CGFloat(index), stage.y + stage.depth - t / 2)] {
                massing.add(.box(Box(x: x, y: y, z: stage.z, width: t, depth: t, height: stage.height)),
                            .lit(accent))
            }
            z += stage.height
        }
        // The crown of spikes around the top rim, taller at the corners.
        let perSide = 4
        for side in 0 ..< 4 {
            for index in 0 ..< perSide {
                let u = CGFloat(index) / CGFloat(perSide)
                let corner = index == 0
                let (x, y): (CGFloat, CGFloat)
                switch side {
                case 0: (x, y) = (stage.x + stage.width * u, stage.y)
                case 1: (x, y) = (stage.x + stage.width, stage.y + stage.depth * u)
                case 2: (x, y) = (stage.x + stage.width * (1 - u), stage.y + stage.depth)
                default: (x, y) = (stage.x, stage.y + stage.depth * (1 - u))
                }
                let height = (corner ? CGFloat(1.0) : CGFloat(0.55)) + CGFloat(side * perSide + index) * 0.004
                massing.add(.box(Box(x: min(footprint - 0.06, max(0, x - 0.03)), y: min(footprint - 0.06, max(0, y - 0.03)),
                                     z: z, width: 0.06, depth: 0.06, height: height)), .lit(accent))
            }
        }
        massing.add(.box(Box(x: stage.x + 0.12, y: stage.y + 0.12, z: z, width: stage.width - 0.24,
                             depth: stage.depth - 0.24, height: 0.3)))
    }

    /// **The Chrome Dome**: the domed tower in the second reference image. A
    /// slim shaft of vertical window strips, a drum ringed in light, and a
    /// dome built from stacked rings closing to a lit oculus and a mast.
    private static func chromeDome(
        _ footprint: CGFloat, _ accent: SKColor,
        _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let podium = Box(x: 0.1, y: 0.1, z: 0, width: footprint - 0.2, depth: footprint - 0.2, height: 0.5)
        massing.add(.box(podium))
        CommercialMassing.shopfront(on: podium, share: 0.18 ... 0.62, into: &massing)

        let inset: CGFloat = 0.44
        let shaft = Box(x: inset, y: inset, z: podium.height, width: footprint - inset * 2,
                        depth: footprint - inset * 2, height: 5.4)
        massing.add(.box(shaft))
        for face in [Panel.Face.right, .left] {
            for strip in 0 ..< 4 {
                let u = (CGFloat(strip) + 0.5) / 4
                massing.panels.append(Panel(box: shaft, face: face, u0: u - 0.06, u1: u + 0.06,
                                            v0: 0.04, v1: 0.94,
                                            color: NeonStyle.windowColor(row: strip, column: 1, salt: 5)))
            }
        }
        let centre = footprint / 2
        var z = shaft.z + shaft.height
        // The drum, and its lit ring.
        massing.add(.cylinder(Cylinder(x: centre, y: centre, z: z, radius: 0.62, height: 0.34, sides: 16)))
        massing.add(.cylinder(Cylinder(x: centre, y: centre, z: z + 0.12, radius: 0.66, height: 0.08, sides: 16)),
                    .lit(accent))
        z += 0.34
        // The dome, as rings closing in: a quarter-circle profile sampled in
        // five steps.
        let radius: CGFloat = 0.6
        let rings = 5
        for ring in 0 ..< rings {
            let a = CGFloat(ring) / CGFloat(rings) * .pi / 2
            let b = CGFloat(ring + 1) / CGFloat(rings) * .pi / 2
            let height = radius * (sin(b) - sin(a))
            massing.add(.cylinder(Cylinder(x: centre, y: centre, z: z, radius: max(0.08, radius * cos(a)),
                                           height: height, sides: 16)))
            z += height
        }
        massing.add(.cylinder(Cylinder(x: centre, y: centre, z: z, radius: 0.12, height: 0.1, sides: 10)),
                    .lit(accent))
        let mast = CGFloat(random.value(in: 0.8 ... 1.0))
        massing.add(.cylinder(Cylinder(x: centre, y: centre, z: z + 0.1, radius: 0.035, height: mast, sides: 8)))
        massing.add(.cylinder(Cylinder(x: centre, y: centre, z: z + 0.1 + mast, radius: 0.065, height: 0.1, sides: 8)),
                    .lit(NeonStyle.litAccent))
    }

    /// **Twin Masts**: the pair of slim towers in the second reference image,
    /// each carrying two antennas of different heights. The skyscraper `twin`
    /// form joins its towers with a bridge; these stand apart, and it is the
    /// four masts against the sky that carry them.
    private static func twinMasts(
        _ footprint: CGFloat, _ accent: SKColor,
        _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let podium = Box(x: 0.08, y: 0.08, z: 0, width: footprint - 0.16, depth: footprint - 0.16, height: 0.45)
        massing.add(.box(podium))
        CommercialMassing.shopfront(on: podium, share: 0.18 ... 0.62, into: &massing)

        let size: CGFloat = 0.62
        let leftFirst = random.chance(0.5)
        // On the anti-diagonal, so they stand side by side on screen. On the
        // other diagonal the near one hides the far one and the pair reads as
        // a single tower — which is what the first render showed.
        for (index, (x, y)) in [(0.16, footprint - 0.16 - size), (footprint - 0.16 - size, 0.16)].enumerated() {
            let taller = (index == 0) == leftFirst
            let tower = Box(x: x, y: y, z: podium.height, width: size, depth: size,
                            height: taller ? 6.2 : 5.5)
            massing.add(.box(tower))
            CommercialMassing.glazingBands(on: tower, into: &massing, random: &random)
            let top = tower.z + tower.height
            massing.add(.box(Box(x: tower.x - 0.03, y: tower.y - 0.03, z: top, width: tower.width + 0.06,
                                 depth: tower.depth + 0.06, height: 0.08)), .lit(accent))
            let cap = Box(x: tower.x + 0.1, y: tower.y + 0.1, z: top + 0.08, width: tower.width - 0.2,
                          depth: tower.depth - 0.2, height: 0.2)
            massing.add(.box(cap))
            for (mast, (u, v)) in [(0.3, 0.3), (0.7, 0.7)].enumerated() {
                let height = (mast == 0 ? CGFloat(2.0) : CGFloat(1.3)) + CGFloat(index) * 0.02
                let mx = cap.x + cap.width * CGFloat(u)
                let my = cap.y + cap.depth * CGFloat(v)
                massing.add(.cylinder(Cylinder(x: mx, y: my, z: cap.z + cap.height, radius: 0.04,
                                               height: height, sides: 6)))
                massing.add(.cylinder(Cylinder(x: mx, y: my, z: cap.z + cap.height + height, radius: 0.075,
                                               height: 0.12, sides: 6)), .lit(accent))
            }
        }
    }

    /// **The Night Market**: the street in the first reference image. Low
    /// two-tier pagoda halls under wide lit eaves, wrapped in tall vertical
    /// neon signs standing off the walls — the one icon that is not tall,
    /// and the only building in the game that is mostly signage.
    private static func nightMarket(
        _ footprint: CGFloat, _ seed: GridPosition,
        _ massing: inout BuildingMassing, _ random: inout BuildingRandom
    ) {
        let eave = RenderPalette.fullColor(for: .nightMarket)
        let hall = Box(x: 0.2, y: 0.2, z: 0, width: footprint - 0.4, depth: footprint - 0.4, height: 0.75)
        massing.add(.box(hall))
        CommercialMassing.shopfront(on: hall, share: 0.08 ... 0.6, into: &massing)
        // Lower eave, projecting well past the wall: the pagoda mark.
        massing.add(.box(Box(x: hall.x - 0.12, y: hall.y - 0.12, z: hall.height, width: hall.width + 0.24,
                             depth: hall.depth + 0.24, height: 0.08)), .lit(eave))
        let upper = Box(x: 0.46, y: 0.46, z: hall.height + 0.08, width: footprint - 0.92,
                        depth: footprint - 0.92, height: 0.55)
        massing.add(.box(upper))
        ResidentialMassing.windows(on: upper, rows: 1, columns: 3, chance: 0.8, salt: 4,
                                   into: &massing, random: &random)
        massing.add(.box(Box(x: upper.x - 0.12, y: upper.y - 0.12, z: upper.z + upper.height,
                             width: upper.width + 0.24, depth: upper.depth + 0.24, height: 0.07)), .lit(eave))
        massing.add(.ridge(Ridge(x: upper.x - 0.04, y: upper.y - 0.04, z: upper.z + upper.height + 0.07,
                                 width: upper.width + 0.08, depth: upper.depth + 0.08, height: 0.42,
                                 axis: random.chance(0.5) ? .x : .y)))

        // The signs: tall lit blades off both visible walls, in the sign
        // palette, at staggered heights so they read as a crowded street
        // rather than a fence.
        let blade: CGFloat = 0.07
        let stand: CGFloat = 0.1
        for (face, count) in [(0, 3), (1, 3)] {
            for index in 0 ..< count {
                let u = CGFloat(0.18) + CGFloat(index) * 0.3
                let height = CGFloat(random.value(in: 1.5 ... 2.3)) + CGFloat(index) * 0.01
                let z = CGFloat(random.value(in: 0.1 ... 0.3))
                let color = NeonStyle.signColor(for: seed, salt: face * 3 + index)
                let sign = face == 0
                    ? Box(x: hall.x + hall.width + 0.04, y: hall.y + hall.depth * u, z: z,
                          width: stand, depth: blade, height: height)
                    : Box(x: hall.x + hall.width * u, y: hall.y + hall.depth + 0.04, z: z,
                          width: blade, depth: stand, height: height)
                massing.add(.box(sign), .lit(color))
            }
        }
    }
}
