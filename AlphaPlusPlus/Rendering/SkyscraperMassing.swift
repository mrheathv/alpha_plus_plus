import SpriteKit

/// **The skyline: level 6, drawn as a different kind of building.**
///
/// Level 5 is a tall tower. Level 6 has to read as something else from across
/// the map, or it is a sixth rung that nobody can see. So this is not the
/// podium-and-tower generator with bigger numbers — "varying numbers is not
/// variety; varying the building is" — it is sixteen retro-futurist *forms*,
/// each a silhouette nothing below it has and none of the others share:
///
/// | form | the mark |
/// |---|---|
/// | deco | a wedding cake of setbacks, a lit ledge at every step, a needle on top |
/// | pyramid | a shaft capped with a stepped pyramid and a lit capstone |
/// | slab | a thin glass blade edged in neon down its three visible corners |
/// | twin | two shafts joined by a lit sky bridge |
/// | round | a glass drum ringed in light, crowned with a lit disc |
/// | ziggurat | stepped from the ground up in equal tiers, a lit fin on every wall |
/// | antenna farm | three steps retreating to the back corner, a roof of masts |
/// | telescope | an octagonal shaft closing in three lit-collared stages |
/// | cantilever | a slim shaft carrying a full-width block that overhangs it |
/// | split top | one shaft that forks into two blades of unequal height, lit between |
/// | stacked | four blocks piled off-centre, each shifted to another corner |
/// | wedge | a shaft cut off by a steep slanted roof with a lit ridge |
/// | cluster | three towers of three heights sharing one podium |
/// | halo | a slim core carrying one or two saucers, the Space Age reading |
/// | obelisk | eight shallow steps tapering smoothly into a needle |
/// | ribbed | lit vertical fins running the height and breaking the roofline |
///
/// **Shared by housing and shops, dressed in each zone's own facade.** A
/// skyscraper that stopped looking like its zone would be a fourth zone, so
/// the forms are shared and the walls are not: commerce's continuous glazing
/// bands and shopfront, housing's punched grid, balconies and lit doorway. The
/// facade helpers are the zones' own, called rather than copied.
///
/// Every form tops out above 5.2 tile units against about 5 for the tallest
/// ordinary level-5 tower, and the rare landmark roll becomes a supertall
/// reaching past 9 — still the tallest thing in the game, as the spire was at
/// level 5.
enum SkyscraperMassing {

    enum Facade { case bands, punched }

    enum Form: CaseIterable {
        case deco, pyramid, slab, twin, round
        case ziggurat, antennaFarm, telescope, cantilever, splitTop
        case stacked, wedge, cluster, halo, obelisk, ribbed
    }

    static func make(zone: ZoneType, seed: GridPosition, footprint: CGFloat = 2) -> BuildingMassing {
        var random = BuildingRandom(seed: seed, salt: 400)
        var massing = BuildingMassing()
        let facade: Facade = zone == .residential ? .punched : .bands
        if ZoneMassing.isLandmark(tier: 4, seed: seed) {
            deco(facade: facade, seed: seed, footprint: footprint, scale: 1.35,
                 into: &massing, random: &random)
            return massing
        }
        switch form(for: seed) {
        case .deco:
            deco(facade: facade, seed: seed, footprint: footprint, scale: 1,
                 into: &massing, random: &random)
        case .pyramid:
            pyramid(facade: facade, seed: seed, footprint: footprint, into: &massing, random: &random)
        case .slab:
            slab(facade: facade, seed: seed, footprint: footprint, into: &massing, random: &random)
        case .twin:
            twin(facade: facade, seed: seed, footprint: footprint, into: &massing, random: &random)
        case .round:
            round(facade: facade, seed: seed, footprint: footprint, into: &massing, random: &random)
        case .ziggurat:
            ziggurat(facade: facade, seed: seed, footprint: footprint, into: &massing, random: &random)
        case .antennaFarm:
            antennaFarm(facade: facade, seed: seed, footprint: footprint, into: &massing, random: &random)
        case .telescope:
            telescope(facade: facade, seed: seed, footprint: footprint, into: &massing, random: &random)
        case .cantilever:
            cantilever(facade: facade, seed: seed, footprint: footprint, into: &massing, random: &random)
        case .splitTop:
            splitTop(facade: facade, seed: seed, footprint: footprint, into: &massing, random: &random)
        case .stacked:
            stacked(facade: facade, seed: seed, footprint: footprint, into: &massing, random: &random)
        case .wedge:
            wedge(facade: facade, seed: seed, footprint: footprint, into: &massing, random: &random)
        case .cluster:
            cluster(facade: facade, seed: seed, footprint: footprint, into: &massing, random: &random)
        case .halo:
            halo(facade: facade, seed: seed, footprint: footprint, into: &massing, random: &random)
        case .obelisk:
            obelisk(facade: facade, seed: seed, footprint: footprint, into: &massing, random: &random)
        case .ribbed:
            ribbed(facade: facade, seed: seed, footprint: footprint, into: &massing, random: &random)
        }
        return massing
    }

    /// **Dealt, not rolled.** With sixteen forms and about twenty-nine
    /// ordinary variants in the cache, a fair roll per variant leaves one or
    /// two forms that the game never draws at all — a generator that owns a
    /// shape nobody can see. So for the seeds the game actually uses (the
    /// cache's canonical ones) the forms are dealt out in turn over the
    /// variants that are not landmarks, which guarantees every form turns up
    /// at least once and none more than twice. Any other seed — the contact
    /// sheets use arbitrary ones — still rolls on its own stream, so a test
    /// can ask which form a lot has without building it.
    static func form(for seed: GridPosition) -> Form {
        let forms = Form.allCases
        if let variant = canonicalVariant(of: seed) {
            let slot = (0 ..< variant).filter {
                !ZoneMassing.isLandmark(tier: 4, seed: IsoTextureCache.canonicalSeed(for: $0))
            }.count
            return forms[slot % forms.count]
        }
        var random = BuildingRandom(seed: seed, salt: 401)
        return random.pick(forms)
    }

    /// Which cached variant `seed` is the canonical seed of, if any.
    private static func canonicalVariant(of seed: GridPosition) -> Int? {
        guard seed.x >= 0, seed.x % 31 == 0 else { return nil }
        let variant = seed.x / 31
        guard variant < IsoTextureCache.variantCount,
              IsoTextureCache.canonicalSeed(for: variant) == seed else { return nil }
        return variant
    }

    // MARK: - Forms

    /// Setbacks stepping in, each ledge lit, ending in a needle. The Chrysler
    /// and Empire State silhouette, which is the most recognisable skyscraper
    /// shape there is. `scale` stretches it into the supertall landmark.
    private static func deco(
        facade: Facade, seed: GridPosition, footprint: CGFloat, scale: CGFloat,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let podium = base(facade: facade, footprint: footprint, into: &massing, random: &random)
        var inset = CGFloat(0.06) + CGFloat(random.value(in: 0.16 ... 0.26))
        var z = podium.height
        var height = CGFloat(random.value(in: 2.2 ... 2.8)) * scale
        var top = Box(x: 0, y: 0, z: 0, width: 0, depth: 0, height: 0)
        let ledge = NeonStyle.signColor(for: seed, salt: 9)
        let steps = random.int(in: 3 ... 4)
        for step in 0 ..< steps {
            guard footprint - inset * 2 > 0.3 else { break }
            top = Box(x: inset, y: inset, z: z,
                      width: footprint - inset * 2, depth: footprint - inset * 2, height: height)
            massing.add(.box(top))
            dress(top, facade: facade, seed: seed, signed: step == 0, footprint: footprint,
                  into: &massing, random: &random)
            // The lit ledge: what turns a stack of boxes into Deco.
            massing.add(.box(Box(x: top.x - 0.03, y: top.y - 0.03, z: top.z + top.height,
                                 width: top.width + 0.06, depth: top.depth + 0.06, height: 0.07)),
                        .lit(ledge))
            z = top.z + top.height + 0.07
            inset += CGFloat(random.value(in: 0.1 ... 0.15))
            height *= CGFloat(random.value(in: 0.45 ... 0.6))
        }
        let needleHeight = CGFloat(random.value(in: 0.8 ... 1.2)) * scale
        // Deco's top: the needle, or on a third of them a dome — both are
        // the period's, and they are the two tops a skyline is read by.
        var topRandom = BuildingRandom(seed: seed, salt: 404)
        if scale == 1, topRandom.chance(0.34), top.width >= 0.6 {
            dome(on: Box(x: top.x, y: top.y, z: top.z, width: top.width, depth: top.depth,
                         height: top.height + 0.07), color: ledge, into: &massing)
        } else {
            needle(on: top, z: z, height: needleHeight, into: &massing)
        }
    }

    /// A shaft with a stepped pyramid on it: six layers closing to a point,
    /// and a lit capstone. Stepped rather than smooth because the massing
    /// vocabulary is boxes — and a ziggurat is the more retro reading anyway.
    private static func pyramid(
        facade: Facade, seed: GridPosition, footprint: CGFloat,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let podium = base(facade: facade, footprint: footprint, into: &massing, random: &random)
        let inset = CGFloat(0.06) + CGFloat(random.value(in: 0.24 ... 0.34))
        let shaft = Box(x: inset, y: inset, z: podium.height,
                        width: footprint - inset * 2, depth: footprint - inset * 2,
                        height: CGFloat(random.value(in: 4.0 ... 5.0)))
        massing.add(.box(shaft))
        dress(shaft, facade: facade, seed: seed, signed: true, footprint: footprint,
              into: &massing, random: &random)

        var z = shaft.z + shaft.height
        massing.add(.box(Box(x: shaft.x - 0.03, y: shaft.y - 0.03, z: z,
                             width: shaft.width + 0.06, depth: shaft.depth + 0.06, height: 0.07)),
                    .lit(NeonStyle.signColor(for: seed, salt: 9)))
        z += 0.07
        let layers = 6
        let step = shaft.width / CGFloat(layers * 2 + 1)
        let layerHeight = CGFloat(random.value(in: 0.13 ... 0.18))
        for layer in 0 ..< layers {
            let shrink = step * CGFloat(layer)
            massing.add(.box(Box(x: shaft.x + shrink, y: shaft.y + shrink, z: z,
                                 width: shaft.width - shrink * 2, depth: shaft.depth - shrink * 2,
                                 height: layerHeight)))
            z += layerHeight
        }
        let cap = step * CGFloat(layers)
        massing.add(.box(Box(x: shaft.x + cap, y: shaft.y + cap, z: z,
                             width: shaft.width - cap * 2, depth: shaft.depth - cap * 2, height: 0.16)),
                    .lit(NeonStyle.litAccent))
    }

    /// A thin blade of a tower, neon down its three visible edges. The narrow
    /// axis is the mark: every other tall building here is square in plan.
    private static func slab(
        facade: Facade, seed: GridPosition, footprint: CGFloat,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let podium = base(facade: facade, footprint: footprint, into: &massing, random: &random)
        let thin = CGFloat(random.value(in: 0.55 ... 0.7))
        let long = CGFloat(random.value(in: 1.4 ... 1.62))
        let alongX = random.chance(0.5)
        let width = alongX ? long : thin
        let depth = alongX ? thin : long
        let blade = Box(x: (footprint - width) / 2, y: (footprint - depth) / 2, z: podium.height,
                        width: width, depth: depth, height: CGFloat(random.value(in: 4.8 ... 6.2)))
        massing.add(.box(blade))
        dress(blade, facade: facade, seed: seed, signed: false, footprint: footprint,
              into: &massing, random: &random)

        // The three vertical edges the camera can see: +x/-y, +x/+y, -x/+y.
        let edge = NeonStyle.signColor(for: seed, salt: 11)
        let t: CGFloat = 0.05
        for (x, y) in [(blade.x + blade.width - t / 2, blade.y - t / 2),
                       (blade.x + blade.width - t / 2, blade.y + blade.depth - t / 2),
                       (blade.x - t / 2, blade.y + blade.depth - t / 2)] {
            massing.add(.box(Box(x: x, y: y, z: blade.z, width: t, depth: t, height: blade.height)),
                        .lit(edge))
        }
        // A flat lit cap with a plant room behind it.
        let top = blade.z + blade.height
        massing.add(.box(Box(x: blade.x - 0.02, y: blade.y - 0.02, z: top,
                             width: blade.width + 0.04, depth: blade.depth + 0.04, height: 0.08)),
                    .lit(edge))
        var topRandom = BuildingRandom(seed: seed, salt: 405)
        if topRandom.chance(0.4) {
            spikeCrown(on: Box(x: blade.x, y: blade.y, z: blade.z, width: blade.width, depth: blade.depth,
                               height: blade.height + 0.08), color: edge, into: &massing)
        } else {
            NeonStyle.rooftopPlant(on: Box(x: blade.x, y: blade.y, z: blade.z,
                                           width: blade.width, depth: blade.depth, height: blade.height + 0.08),
                                   into: &massing, random: &random)
        }
    }

    /// Two shafts on a shared podium, joined high up by a lit bridge.
    private static func twin(
        facade: Facade, seed: GridPosition, footprint: CGFloat,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let podium = base(facade: facade, footprint: footprint, into: &massing, random: &random)
        let margin: CGFloat = 0.14
        let gap = CGFloat(random.value(in: 0.26 ... 0.38))
        let size = (footprint - margin * 2 - gap) / 2
        let depth = CGFloat(random.value(in: 0.9 ... 1.3))
        let alongX = random.chance(0.5)
        let height = CGFloat(random.value(in: 4.4 ... 5.6))
        let across = (footprint - depth) / 2
        var towers: [Box] = []
        for index in 0 ..< 2 {
            let along = margin + CGFloat(index) * (size + gap)
            // A hair apart in height, so the pair never ties a sort key.
            let tower = alongX
                ? Box(x: along, y: across, z: podium.height, width: size, depth: depth,
                      height: height + CGFloat(index) * 0.02)
                : Box(x: across, y: along, z: podium.height, width: depth, depth: size,
                      height: height + CGFloat(index) * 0.02)
            massing.add(.box(tower))
            dress(tower, facade: facade, seed: seed, signed: false, footprint: footprint,
                  into: &massing, random: &random)
            towers.append(tower)
        }
        let bridgeZ = podium.height + height * CGFloat(random.value(in: 0.55 ... 0.7))
        let bridge = alongX
            ? Box(x: margin + size, y: footprint / 2 - 0.12, z: bridgeZ, width: gap, depth: 0.24, height: 0.18)
            : Box(x: footprint / 2 - 0.12, y: margin + size, z: bridgeZ, width: 0.24, depth: gap, height: 0.18)
        massing.add(.box(bridge), .lit(NeonStyle.signColor(for: seed, salt: 13)))
        for tower in towers {
            let top = tower.z + tower.height
            let cap = Box(x: tower.x + 0.1, y: tower.y + 0.1, z: top,
                          width: tower.width - 0.2, depth: tower.depth - 0.2, height: 0.2)
            massing.add(.box(cap))
            needle(on: cap, z: top + 0.2, height: 0.55, into: &massing)
        }
    }

    /// A drum, ringed with light, on a square podium.
    private static func round(
        facade: Facade, seed: GridPosition, footprint: CGFloat,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let podium = base(facade: facade, footprint: footprint, into: &massing, random: &random)
        let radius = CGFloat(random.value(in: 0.56 ... 0.7))
        let height = CGFloat(random.value(in: 4.6 ... 6.0))
        let centre = footprint / 2
        massing.add(.cylinder(Cylinder(x: centre, y: centre, z: podium.height,
                                       radius: radius, height: height, sides: 12)))
        let ringColor = NeonStyle.signColor(for: seed, salt: 15)
        floorRings(centre: centre, radius: radius, from: podium.height, to: podium.height + height,
                   sides: 12, facade: facade, color: ringColor, into: &massing)
        let top = podium.height + height
        massing.add(.cylinder(Cylinder(x: centre, y: centre, z: top, radius: radius + 0.08,
                                       height: 0.12, sides: 12)), .lit(ringColor))
        massing.add(.cylinder(Cylinder(x: centre, y: centre, z: top + 0.12, radius: radius * 0.5,
                                       height: 0.35, sides: 12)))
        let cap = Box(x: centre - 0.05, y: centre - 0.05, z: top + 0.47, width: 0.1, depth: 0.1, height: 0)
        needle(on: cap, z: top + 0.47, height: 0.7, into: &massing)
    }

    /// Stepped from the ground up in tiers of equal height, each drawn in by
    /// the same amount, with a lit fin down the middle of every visible wall.
    /// The pyramid form has a straight shaft under a small stepped cap; this
    /// is stepped all the way, so its outline is a triangle rather than a post.
    private static func ziggurat(
        facade: Facade, seed: GridPosition, footprint: CGFloat,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let podium = base(facade: facade, footprint: footprint, into: &massing, random: &random)
        let tiers = random.int(in: 5 ... 6)
        let first: CGFloat = 0.14
        let last = CGFloat(random.value(in: 0.6 ... 0.7))
        let step = (last - first) / CGFloat(tiers - 1)
        let tierHeight = CGFloat(random.value(in: 0.92 ... 1.12))
        let fin = NeonStyle.signColor(for: seed, salt: 17)
        let finsUpTo = random.int(in: tiers - 2 ... tiers)
        var z = podium.height
        var top = podium
        for tier in 0 ..< tiers {
            let inset = first + step * CGFloat(tier)
            top = Box(x: inset, y: inset, z: z, width: footprint - inset * 2,
                      depth: footprint - inset * 2, height: tierHeight)
            massing.add(.box(top))
            dress(top, facade: facade, seed: seed, signed: false, footprint: footprint,
                  into: &massing, random: &random)
            if tier < finsUpTo { fins(on: top, count: 1, color: fin, rise: 0, into: &massing) }
            z += tierHeight
        }
        // A temple on the summit, the one un-stepped thing on the building.
        let size = top.width * CGFloat(random.value(in: 0.4 ... 0.55))
        let temple = Box(x: footprint / 2 - size / 2, y: footprint / 2 - size / 2, z: z,
                         width: size, depth: size, height: CGFloat(random.value(in: 0.3 ... 0.45)))
        massing.add(.box(temple))
        ledge(on: temple, color: fin, into: &massing)
    }

    /// Three broad steps that retreat toward the back corner rather than to
    /// the middle, so the building climbs away from the viewer like a stair,
    /// and a flat roof bristling with masts of different heights.
    private static func antennaFarm(
        facade: Facade, seed: GridPosition, footprint: CGFloat,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let podium = base(facade: facade, footprint: footprint, into: &massing, random: &random)
        let back: CGFloat = 0.14
        var front: CGFloat = 0.14
        var z = podium.height
        var top = podium
        for (index, height) in [random.value(in: 2.0 ... 2.4), random.value(in: 1.4 ... 1.8),
                                random.value(in: 1.0 ... 1.3)].enumerated() {
            top = Box(x: back, y: back, z: z, width: footprint - back - front,
                      depth: footprint - back - front, height: CGFloat(height))
            massing.add(.box(top))
            dress(top, facade: facade, seed: seed, signed: index == 0, footprint: footprint,
                  into: &massing, random: &random)
            z += top.height
            front += CGFloat(random.value(in: 0.24 ... 0.32))
        }
        ledge(on: top, color: NeonStyle.signColor(for: seed, salt: 19), into: &massing)
        // The farm: masts on a grid over the roof, each a different height so
        // they read as a cluster rather than a fence, and no two tie.
        let count = random.int(in: 3 ... 5)
        let spots: [(CGFloat, CGFloat)] = [(0.22, 0.22), (0.78, 0.3), (0.3, 0.78), (0.72, 0.74), (0.5, 0.5)]
        for index in 0 ..< count {
            let (u, v) = spots[index]
            let mast = Box(x: top.x + top.width * u, y: top.y + top.depth * v, z: 0, width: 0, depth: 0, height: 0)
            needle(on: mast, z: z + 0.07,
                   height: CGFloat(random.value(in: 0.5 ... 1.3)) + CGFloat(index) * 0.03,
                   into: &massing)
        }
    }

    /// An eight-sided shaft that closes in three stages, each with a lit
    /// collar, ending in a needle — a telescope pulled out. The drum is round
    /// and one stage; this is faceted and three.
    private static func telescope(
        facade: Facade, seed: GridPosition, footprint: CGFloat,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let podium = base(facade: facade, footprint: footprint, into: &massing, random: &random)
        let centre = footprint / 2
        let collar = NeonStyle.signColor(for: seed, salt: 21)
        var radius = CGFloat(random.value(in: 0.66 ... 0.8))
        var z = podium.height
        let heights = [random.value(in: 2.8 ... 3.4), random.value(in: 1.2 ... 1.6), random.value(in: 0.6 ... 0.9)]
        for (stage, value) in heights.enumerated() {
            let height = CGFloat(value)
            massing.add(.cylinder(Cylinder(x: centre, y: centre, z: z, radius: radius,
                                           height: height, sides: 8)))
            if stage < 2 {
                floorRings(centre: centre, radius: radius, from: z, to: z + height, sides: 8,
                           facade: facade, color: collar, into: &massing)
            }
            z += height
            massing.add(.cylinder(Cylinder(x: centre, y: centre, z: z, radius: radius + 0.05,
                                           height: 0.1, sides: 8)), .lit(collar))
            z += 0.1
            radius *= CGFloat(random.value(in: 0.62 ... 0.72))
        }
        let cap = Box(x: centre, y: centre, z: z, width: 0, depth: 0, height: 0)
        needle(on: cap, z: z, height: CGFloat(random.value(in: 0.6 ... 1.0)), into: &massing)
    }

    /// A slim shaft standing at the back of the lot, carrying a full-width
    /// block that hangs out over the podium in front of it. The only form
    /// wider at the top than in the middle.
    private static func cantilever(
        facade: Facade, seed: GridPosition, footprint: CGFloat,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let podium = base(facade: facade, footprint: footprint, into: &massing, random: &random)
        let margin: CGFloat = 0.14
        let alongX = random.chance(0.5)
        let span = CGFloat(random.value(in: 0.82 ... 1.02))
        let across = CGFloat(random.value(in: 1.0 ... 1.3))
        let offset = (footprint - across) / 2
        let shaftHeight = CGFloat(random.value(in: 3.8 ... 4.5))
        let shaft = alongX
            ? Box(x: margin, y: offset, z: podium.height, width: span, depth: across, height: shaftHeight)
            : Box(x: offset, y: margin, z: podium.height, width: across, depth: span, height: shaftHeight)
        massing.add(.box(shaft))
        dress(shaft, facade: facade, seed: seed, signed: true, footprint: footprint,
              into: &massing, random: &random)

        let full = footprint - margin * 2
        let blockZ = shaft.z + shaft.height + 0.07
        let blockHeight = CGFloat(random.value(in: 1.1 ... 1.5))
        let block = alongX
            ? Box(x: margin, y: offset, z: blockZ, width: full, depth: across, height: blockHeight)
            : Box(x: offset, y: margin, z: blockZ, width: across, depth: full, height: blockHeight)
        // The lit seam the block rests on: what says it is held up there
        // rather than drawn on.
        let seam = NeonStyle.signColor(for: seed, salt: 23)
        massing.add(.box(Box(x: block.x, y: block.y, z: shaft.z + shaft.height,
                             width: block.width, depth: block.depth, height: 0.07)), .lit(seam))
        massing.add(.box(block))
        dress(block, facade: facade, seed: seed, signed: false, footprint: footprint,
              into: &massing, random: &random)
        crown(on: block, seed: seed, into: &massing, random: &random)
    }

    /// One shaft that forks into two blades of unequal height, a lit slot in
    /// the cleft between them. Twin has two towers from the podium up; this
    /// is one tower that splits.
    private static func splitTop(
        facade: Facade, seed: GridPosition, footprint: CGFloat,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let podium = base(facade: facade, footprint: footprint, into: &massing, random: &random)
        let inset = CGFloat(random.value(in: 0.24 ... 0.32))
        let body = Box(x: inset, y: inset, z: podium.height, width: footprint - inset * 2,
                       depth: footprint - inset * 2, height: CGFloat(random.value(in: 3.0 ... 3.6)))
        massing.add(.box(body))
        dress(body, facade: facade, seed: seed, signed: true, footprint: footprint,
              into: &massing, random: &random)

        let alongX = random.chance(0.5)
        let gap = CGFloat(random.value(in: 0.22 ... 0.28))
        let bladeSpan = (body.width - gap) / 2
        let tall = CGFloat(random.value(in: 1.6 ... 2.2))
        let short = tall - CGFloat(random.value(in: 0.5 ... 0.8))
        let tallFirst = random.chance(0.5)
        let z = body.z + body.height
        for index in 0 ..< 2 {
            let height = (index == 0) == tallFirst ? tall : short
            let along = inset + CGFloat(index) * (bladeSpan + gap)
            let blade = alongX
                ? Box(x: along, y: inset, z: z, width: bladeSpan, depth: body.depth, height: height)
                : Box(x: inset, y: along, z: z, width: body.width, depth: bladeSpan, height: height)
            massing.add(.box(blade))
            dress(blade, facade: facade, seed: seed, signed: false, footprint: footprint,
                  into: &massing, random: &random)
            ledge(on: blade, color: NeonStyle.signColor(for: seed, salt: 25 + index), into: &massing)
        }
        let slotAlong = inset + bladeSpan + gap * 0.3
        let slotAcross = inset + body.depth * 0.2
        let slot = alongX
            ? Box(x: slotAlong, y: slotAcross, z: z, width: gap * 0.4, depth: body.depth * 0.6, height: short * 0.9)
            : Box(x: slotAcross, y: slotAlong, z: z, width: body.width * 0.6, depth: gap * 0.4, height: short * 0.9)
        massing.add(.box(slot), .lit(NeonStyle.litAccent))
    }

    /// Four blocks piled off-centre, each shifted to a different corner of the
    /// lot, so the tower zigzags as it rises. Every other form here is
    /// symmetric about its own axis; this one is deliberately not.
    private static func stacked(
        facade: Facade, seed: GridPosition, footprint: CGFloat,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let podium = base(facade: facade, footprint: footprint, into: &massing, random: &random)
        let margin: CGFloat = 0.14
        let corners: [(Bool, Bool)] = [(false, false), (true, false), (true, true), (false, true)]
        let start = random.int(in: 0 ... 3)
        let turn = random.chance(0.5) ? 1 : 3
        var z = podium.height
        var top = podium
        for index in 0 ..< 4 {
            let size = CGFloat(random.value(in: 1.06 ... 1.3))
            let (highX, highY) = corners[(start + index * turn) % 4]
            let far = footprint - margin - size
            top = Box(x: highX ? far : margin, y: highY ? far : margin, z: z,
                      width: size, depth: size, height: CGFloat(random.value(in: 1.25 ... 1.55)))
            massing.add(.box(top))
            dress(top, facade: facade, seed: seed, signed: index == 0, footprint: footprint,
                  into: &massing, random: &random)
            z += top.height
        }
        // Four window-covered blocks already sit near the geometry budget, so
        // the stacked form takes every top but the dome.
        crown(on: top, seed: seed, allowDome: false, into: &massing, random: &random)
    }

    /// A shaft cut off by a steep single-pitch roof, a lit line along its
    /// ridge. The only skyscraper with a slope for a top.
    private static func wedge(
        facade: Facade, seed: GridPosition, footprint: CGFloat,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let podium = base(facade: facade, footprint: footprint, into: &massing, random: &random)
        let inset = CGFloat(random.value(in: 0.24 ... 0.34))
        let shaft = Box(x: inset, y: inset, z: podium.height, width: footprint - inset * 2,
                        depth: footprint - inset * 2, height: CGFloat(random.value(in: 3.8 ... 4.6)))
        massing.add(.box(shaft))
        dress(shaft, facade: facade, seed: seed, signed: true, footprint: footprint,
              into: &massing, random: &random)
        let edge = NeonStyle.signColor(for: seed, salt: 27)
        ledge(on: shaft, color: edge, into: &massing)

        let z = shaft.z + shaft.height + 0.07
        let rise = CGFloat(random.value(in: 1.0 ... 1.5))
        let axis: Ridge.Axis = random.chance(0.5) ? .x : .y
        let high: CGFloat = random.chance(0.5) ? 1 : 0
        massing.add(.ridge(Ridge(x: shaft.x, y: shaft.y, z: z, width: shaft.width, depth: shaft.depth,
                                 height: rise, axis: axis, ridgePosition: high)))
        // The lit ridge, laid along the high edge.
        let t: CGFloat = 0.06
        let ridge = axis == .x
            ? Box(x: shaft.x, y: shaft.y + (shaft.depth - t) * high, z: z + rise,
                  width: shaft.width, depth: t, height: 0.05)
            : Box(x: shaft.x + (shaft.width - t) * high, y: shaft.y, z: z + rise,
                  width: t, depth: shaft.depth, height: 0.05)
        massing.add(.box(ridge), .lit(edge))
        if random.chance(0.5) {
            needle(on: ridge, z: z + rise + 0.05, height: CGFloat(random.value(in: 0.5 ... 0.9)),
                   into: &massing)
        }
    }

    /// Three towers of three different heights on one podium, the tallest at
    /// the back so the others step down toward the viewer. A downtown in one lot.
    private static func cluster(
        facade: Facade, seed: GridPosition, footprint: CGFloat,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let podium = base(facade: facade, footprint: footprint, into: &massing, random: &random)
        let margin: CGFloat = 0.14
        let size = CGFloat(random.value(in: 0.66 ... 0.78))
        let far = footprint - margin - size
        let tall = CGFloat(random.value(in: 4.8 ... 5.6))
        let mid = CGFloat(random.value(in: 3.2 ... 3.8))
        let low = CGFloat(random.value(in: 2.1 ... 2.7))
        let midOnRight = random.chance(0.5)
        let towers: [(CGFloat, CGFloat, CGFloat)] = [
            (margin, margin, tall),
            (far, margin, midOnRight ? mid : low),
            (margin, far, midOnRight ? low : mid),
        ]
        for (index, (x, y, height)) in towers.enumerated() {
            let tower = Box(x: x, y: y, z: podium.height, width: size, depth: size, height: height)
            massing.add(.box(tower))
            dress(tower, facade: facade, seed: seed, signed: index == 0, footprint: footprint,
                  into: &massing, random: &random)
            ledge(on: tower, color: NeonStyle.signColor(for: seed, salt: 29 + index), into: &massing)
            if index == 0 {
                needle(on: tower, z: tower.z + tower.height + 0.07,
                       height: CGFloat(random.value(in: 0.6 ... 1.0)), into: &massing)
            }
        }
    }

    /// A slim core carrying a saucer — or two, the lower one smaller — with a
    /// lit rim and a needle. The Space Age reading of retro-futurism, and the
    /// only form whose widest point is in the sky.
    private static func halo(
        facade: Facade, seed: GridPosition, footprint: CGFloat,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let podium = base(facade: facade, footprint: footprint, into: &massing, random: &random)
        let inset = CGFloat(random.value(in: 0.6 ... 0.66))
        let core = Box(x: inset, y: inset, z: podium.height, width: footprint - inset * 2,
                       depth: footprint - inset * 2, height: CGFloat(random.value(in: 4.4 ... 5.2)))
        massing.add(.box(core))
        dress(core, facade: facade, seed: seed, signed: false, footprint: footprint,
              into: &massing, random: &random)
        let centre = footprint / 2
        let rim = NeonStyle.signColor(for: seed, salt: 31)
        let top = core.z + core.height
        var saucers = [(z: top, radius: CGFloat(random.value(in: 0.8 ... 0.9)))]
        if random.chance(0.5) {
            saucers.insert((z: top - CGFloat(random.value(in: 1.0 ... 1.4)),
                            radius: CGFloat(random.value(in: 0.6 ... 0.7))), at: 0)
        }
        for saucer in saucers {
            massing.add(.cylinder(Cylinder(x: centre, y: centre, z: saucer.z, radius: saucer.radius,
                                           height: 0.26, sides: 16)))
            massing.add(.cylinder(Cylinder(x: centre, y: centre, z: saucer.z + 0.1, radius: saucer.radius + 0.05,
                                           height: 0.07, sides: 16)), .lit(rim))
        }
        massing.add(.cylinder(Cylinder(x: centre, y: centre, z: top + 0.26, radius: 0.34,
                                       height: 0.24, sides: 12)))
        let cap = Box(x: centre, y: centre, z: 0, width: 0, depth: 0, height: 0)
        needle(on: cap, z: top + 0.5, height: CGFloat(random.value(in: 0.7 ... 1.1)), into: &massing)
    }

    /// Eight shallow steps closing smoothly from a broad base to a needle —
    /// a taper rather than a set of setbacks. Deco steps in three or four
    /// big bites; this one in many small ones.
    private static func obelisk(
        facade: Facade, seed: GridPosition, footprint: CGFloat,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let podium = base(facade: facade, footprint: footprint, into: &massing, random: &random)
        let steps = random.int(in: 7 ... 8)
        let bottom = CGFloat(random.value(in: 1.3 ... 1.5))
        let summit = CGFloat(random.value(in: 0.36 ... 0.44))
        let stepHeight = CGFloat(random.value(in: 0.68 ... 0.8))
        var z = podium.height
        var top = podium
        for step in 0 ..< steps {
            let width = bottom + (summit - bottom) * CGFloat(step) / CGFloat(steps - 1)
            top = Box(x: footprint / 2 - width / 2, y: footprint / 2 - width / 2, z: z,
                      width: width, depth: width, height: stepHeight)
            massing.add(.box(top))
            if width > 0.7 {
                dress(top, facade: facade, seed: seed, signed: step == 0, footprint: footprint,
                      into: &massing, random: &random)
            }
            z += stepHeight
        }
        massing.add(.box(Box(x: top.x + 0.06, y: top.y + 0.06, z: z, width: top.width - 0.12,
                             depth: top.depth - 0.12, height: 0.14)),
                    .lit(NeonStyle.signColor(for: seed, salt: 33)))
        needle(on: top, z: z + 0.14, height: CGFloat(random.value(in: 0.9 ... 1.4)), into: &massing)
    }

    /// A square shaft with lit fins running its whole height and breaking the
    /// roofline, so the top reads as a comb against the sky.
    private static func ribbed(
        facade: Facade, seed: GridPosition, footprint: CGFloat,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let podium = base(facade: facade, footprint: footprint, into: &massing, random: &random)
        let inset = CGFloat(random.value(in: 0.3 ... 0.4))
        let shaft = Box(x: inset, y: inset, z: podium.height, width: footprint - inset * 2,
                        depth: footprint - inset * 2, height: CGFloat(random.value(in: 4.6 ... 5.6)))
        massing.add(.box(shaft))
        dress(shaft, facade: facade, seed: seed, signed: false, footprint: footprint,
              into: &massing, random: &random)
        fins(on: shaft, count: random.int(in: 2 ... 3), color: NeonStyle.signColor(for: seed, salt: 35),
             rise: CGFloat(random.value(in: 0.35 ... 0.6)), into: &massing)
        NeonStyle.rooftopPlant(on: shaft, into: &massing, random: &random)
    }

    // MARK: - Parts

    /// The street floors: commerce's glazed shopfront or housing's windows and
    /// lit door. What says whose skyscraper this is at the ground.
    private static func base(
        facade: Facade, footprint: CGFloat,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) -> Box {
        let margin: CGFloat = 0.06
        let podium = Box(x: margin, y: margin, z: 0,
                         width: footprint - margin * 2, depth: footprint - margin * 2,
                         height: CGFloat(random.value(in: 0.4 ... 0.55)))
        massing.add(.box(podium))
        switch facade {
        case .bands:
            CommercialMassing.shopfront(on: podium, share: 0.18 ... 0.64, into: &massing)
        case .punched:
            ResidentialMassing.windows(on: podium, rows: 1,
                                       columns: max(1, Int((podium.width / 0.55).rounded())),
                                       chance: 0.7, salt: 0, into: &massing, random: &random)
            ResidentialMassing.entrance(on: podium, into: &massing, random: &random)
        }
        return podium
    }

    /// One shaft's walls, in its zone's vocabulary.
    private static func dress(
        _ box: Box, facade: Facade, seed: GridPosition, signed: Bool, footprint: CGFloat,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        // **Sparse windows**, on about a third of towers: the silhouette
        // reference, where a tower is a dark shape with a scatter of lit
        // dashes rather than a lit grid. The outline then carries the form,
        // which is what reads from across the map; and it gives the skyline
        // darker towers to set the bright ones against.
        var sparseRandom = BuildingRandom(seed: seed, salt: 402)
        let sparse = sparseRandom.chance(0.33)
        switch facade {
        case .bands where sparse:
            NeonStyle.clad(box, as: CommercialMassing.cladding(for: seed), into: &massing, random: &random)
            let rows = max(1, Int((box.height / 0.34).rounded()))
            for face in [Panel.Face.right, .left] {
                for row in 0 ..< rows where random.chance(0.55) {
                    let start = CGFloat(random.value(in: 0.1 ... 0.62))
                    let length = CGFloat(random.value(in: 0.12 ... 0.28))
                    massing.panels.append(Panel(
                        box: box, face: face, u0: start, u1: min(0.9, start + length),
                        v0: (CGFloat(row) + 0.3) / CGFloat(rows), v1: (CGFloat(row) + 0.62) / CGFloat(rows),
                        color: NeonStyle.windowColor(row: row, column: 0, salt: 7)))
                }
            }
            if signed {
                CommercialMassing.bladeSign(on: box, color: NeonStyle.signColor(for: seed),
                                            footprint: footprint, into: &massing, random: &random)
            }
        case .bands:
            NeonStyle.clad(box, as: CommercialMassing.cladding(for: seed), into: &massing, random: &random)
            CommercialMassing.glazingBands(on: box, into: &massing, random: &random)
            if signed {
                CommercialMassing.bladeSign(on: box, color: NeonStyle.signColor(for: seed),
                                            footprint: footprint, into: &massing, random: &random)
            }
        case .punched:
            NeonStyle.clad(box, as: ResidentialMassing.cladding(for: seed), into: &massing, random: &random)
            // Capped, because a skyscraper's shaft is tall enough that a row
            // per storey is several hundred nodes of windows on a twin.
            ResidentialMassing.windows(on: box, rows: min(10, max(2, Int((box.height / 0.36).rounded()))),
                                       columns: max(1, Int((box.width / 0.5).rounded())),
                                       chance: sparse ? 0.22 : 0.66, salt: 3, into: &massing, random: &random)
            guard box.height > 1.2 else { return }
            var fraction = CGFloat(random.value(in: 0.2 ... 0.3))
            while fraction < 0.9 {
                ResidentialMassing.balcony(on: box, at: fraction, into: &massing)
                fraction += CGFloat(random.value(in: 0.24 ... 0.34))
            }
        }
    }

    /// A cylinder carries no panels, so its floors are rings: lit ones read
    /// as commerce's glazing bands, plain ledges as housing's balconies.
    private static func floorRings(
        centre: CGFloat, radius: CGFloat, from bottom: CGFloat, to top: CGFloat, sides: Int,
        facade: Facade, color: SKColor, into massing: inout BuildingMassing
    ) {
        let spacing: CGFloat = facade == .bands ? 0.45 : 0.44
        var z = bottom + spacing
        var index = 0
        while z < top - 0.2 {
            let lit = facade == .bands || index % 3 == 1
            massing.add(.cylinder(Cylinder(x: centre, y: centre, z: z, radius: radius + 0.04,
                                           height: lit ? 0.07 : 0.05, sides: sides)),
                        lit ? .lit(facade == .bands ? NeonStyle.windowColor(row: index, column: 0, salt: 7)
                                                    : color)
                            : .structure)
            z += spacing
            index += 1
        }
    }

    /// A lit ledge wrapping the top of `box`, the way deco lights its steps.
    private static func ledge(on box: Box, color: SKColor, into massing: inout BuildingMassing) {
        massing.add(.box(Box(x: box.x - 0.03, y: box.y - 0.03, z: box.z + box.height,
                             width: box.width + 0.06, depth: box.depth + 0.06, height: 0.07)),
                    .lit(color))
    }

    /// Lit vertical fins standing proud of all four walls of `box`, `count`
    /// to a wall, running its height and `rise` past its roof. The back two
    /// walls are hidden below the roofline, but their fins are not above it —
    /// that is what makes the top a comb rather than a fringe.
    private static func fins(
        on box: Box, count: Int, color: SKColor, rise: CGFloat, into massing: inout BuildingMassing
    ) {
        let proud: CGFloat = 0.06
        let thick: CGFloat = 0.06
        let height = rise > 0 ? box.height + rise : box.height * 0.9
        for index in 0 ..< count {
            let u = (CGFloat(index) + 0.5) / CGFloat(count)
            let alongY = box.y + box.depth * u - thick / 2
            let alongX = box.x + box.width * u - thick / 2
            massing.add(.box(Box(x: box.x + box.width, y: alongY, z: box.z, width: proud, depth: thick,
                                 height: height)), .lit(color))
            massing.add(.box(Box(x: alongX, y: box.y + box.depth, z: box.z, width: thick, depth: proud,
                                 height: height + 0.01)), .lit(color))
            guard rise > 0 else { continue }
            massing.add(.box(Box(x: box.x - proud, y: alongY, z: box.z, width: proud, depth: thick,
                                 height: height + 0.02)), .lit(color))
            massing.add(.box(Box(x: alongX, y: box.y - proud, z: box.z, width: thick, depth: proud,
                                 height: height + 0.03)), .lit(color))
        }
    }

    /// A top for a form that has no crown of its own: a lit band, a lit
    /// band with a needle, or a stepped cap.
    private static func crown(
        on box: Box, seed: GridPosition, allowDome: Bool = true,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let color = NeonStyle.signColor(for: seed, salt: 37)
        // Picked on its own stream so the ledge-and-cap tops already drawn
        // keep their seeds; a third of tops become one of the two new ones.
        var topRandom = BuildingRandom(seed: seed, salt: 403)
        switch topRandom.int(in: 0 ... 5) {
        case 0:
            spikeCrown(on: box, color: color, into: &massing)
            return
        case 1 where allowDome && min(box.width, box.depth) >= 0.6:
            dome(on: box, color: color, into: &massing)
            return
        default:
            break
        }
        switch random.int(in: 0 ... 2) {
        case 0:
            ledge(on: box, color: color, into: &massing)
        case 1:
            ledge(on: box, color: color, into: &massing)
            needle(on: box, z: box.z + box.height + 0.07,
                   height: CGFloat(random.value(in: 0.5 ... 0.9)), into: &massing)
        default:
            let shrink = min(box.width, box.depth) * 0.2
            let cap = Box(x: box.x + shrink, y: box.y + shrink, z: box.z + box.height,
                          width: box.width - shrink * 2, depth: box.depth - shrink * 2, height: 0.22)
            massing.add(.box(cap))
            ledge(on: cap, color: color, into: &massing)
        }
    }

    /// **A crown of lit spikes** round the rim, taller at the corners: the
    /// Hong Kong supertall's top, which the Harbour Tower icon has in full
    /// and ordinary towers now carry smaller.
    private static func spikeCrown(on box: Box, color: SKColor, into massing: inout BuildingMassing) {
        let top = box.z + box.height
        massing.add(.box(Box(x: box.x - 0.03, y: box.y - 0.03, z: top, width: box.width + 0.06,
                             depth: box.depth + 0.06, height: 0.06)), .lit(color))
        let perSide = 3
        for side in 0 ..< 4 {
            for index in 0 ..< perSide {
                let u = CGFloat(index) / CGFloat(perSide)
                let (x, y): (CGFloat, CGFloat)
                switch side {
                case 0: (x, y) = (box.x + box.width * u, box.y)
                case 1: (x, y) = (box.x + box.width, box.y + box.depth * u)
                case 2: (x, y) = (box.x + box.width * (1 - u), box.y + box.depth)
                default: (x, y) = (box.x, box.y + box.depth * (1 - u))
                }
                let height = (index == 0 ? CGFloat(0.6) : 0.34) + CGFloat(side * perSide + index) * 0.004
                massing.add(.box(Box(x: x - 0.025, y: y - 0.025, z: top + 0.06, width: 0.05, depth: 0.05,
                                     height: height)), .lit(color))
            }
        }
    }

    /// **A dome**: a drum with a lit ring and a quarter-circle of stacked
    /// rings closing to a lit oculus and a mast — the domed tower in the
    /// silhouette reference, as an ordinary top rather than only the icon.
    private static func dome(on box: Box, color: SKColor, into massing: inout BuildingMassing) {
        let x = box.x + box.width / 2
        let y = box.y + box.depth / 2
        let radius = min(box.width, box.depth) * 0.42
        var z = box.z + box.height
        massing.add(.cylinder(Cylinder(x: x, y: y, z: z, radius: radius, height: 0.18, sides: 10)))
        massing.add(.cylinder(Cylinder(x: x, y: y, z: z + 0.07, radius: radius + 0.03, height: 0.05, sides: 10)),
                    .lit(color))
        z += 0.18
        // A real dome now (`MassingShape.dome`), where it was stacked drums
        // with a step at every ring.
        massing.add(.shape(MassingShape.dome(x: x, y: y, z: z, radius: radius, rings: 3, sides: 10)))
        z += radius
        massing.add(.cylinder(Cylinder(x: x, y: y, z: z, radius: 0.07, height: 0.07, sides: 8)), .lit(color))
        needle(on: Box(x: x, y: y, z: 0, width: 0, depth: 0, height: 0), z: z + 0.07, height: 0.5, into: &massing)
    }

    /// A slim mast with a lit tip, centred on `box`.
    private static func needle(on box: Box, z: CGFloat, height: CGFloat, into massing: inout BuildingMassing) {
        let x = box.x + box.width / 2
        let y = box.y + box.depth / 2
        massing.add(.cylinder(Cylinder(x: x, y: y, z: z, radius: 0.04, height: height, sides: 8)))
        massing.add(.cylinder(Cylinder(x: x, y: y, z: z + height, radius: 0.07, height: 0.12, sides: 8)),
                    .lit(NeonStyle.litAccent))
    }
}
