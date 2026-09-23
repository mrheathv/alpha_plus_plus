import SpriteKit

/// **The skyline: level 6, drawn as a different kind of building.**
///
/// Level 5 is a tall tower. Level 6 has to read as something else from across
/// the map, or it is a sixth rung that nobody can see. So this is not the
/// podium-and-tower generator with bigger numbers — "varying numbers is not
/// variety; varying the building is" — it is five retro-futurist *forms*, each
/// a silhouette nothing below it has:
///
/// | form | the mark |
/// |---|---|
/// | deco | a wedding cake of setbacks, a lit ledge at every step, a needle on top |
/// | pyramid | a shaft capped with a stepped pyramid and a lit capstone |
/// | slab | a thin glass blade edged in neon down its three visible corners |
/// | twin | two shafts joined by a lit sky bridge |
/// | round | a glass drum ringed in light, crowned with a lit disc |
///
/// **Shared by housing and shops, dressed in each zone's own facade.** A
/// skyscraper that stopped looking like its zone would be a fourth zone, so
/// the forms are shared and the walls are not: commerce's continuous glazing
/// bands and shopfront, housing's punched grid, balconies and lit doorway. The
/// facade helpers are the zones' own, called rather than copied.
///
/// Heights run 5.2 to 7.2 tile units against 4.8 for the tallest ordinary
/// level-5 tower, and the rare landmark roll becomes a supertall reaching past
/// 9 — still the tallest thing in the game, as the spire was at level 5.
enum SkyscraperMassing {

    enum Facade { case bands, punched }

    enum Form: CaseIterable { case deco, pyramid, slab, twin, round }

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
        }
        return massing
    }

    /// Picked on its own stream, so a test can ask which form a lot has without
    /// building it.
    static func form(for seed: GridPosition) -> Form {
        var random = BuildingRandom(seed: seed, salt: 401)
        return random.pick(Form.allCases)
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
        needle(on: top, z: z, height: CGFloat(random.value(in: 0.8 ... 1.2)) * scale,
               into: &massing)
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
        NeonStyle.rooftopPlant(on: Box(x: blade.x, y: blade.y, z: blade.z,
                                       width: blade.width, depth: blade.depth, height: blade.height + 0.08),
                               into: &massing, random: &random)
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
                                       radius: radius, height: height, sides: 16)))
        // A cylinder carries no panels, so its floors are rings: lit ones read
        // as commerce's glazing bands, plain ledges as housing's balconies.
        let ringColor = NeonStyle.signColor(for: seed, salt: 15)
        let spacing: CGFloat = facade == .bands ? 0.45 : 0.36
        var z = podium.height + spacing
        var index = 0
        while z < podium.height + height - 0.2 {
            let lit = facade == .bands || index % 3 == 1
            massing.add(.cylinder(Cylinder(x: centre, y: centre, z: z, radius: radius + 0.04,
                                           height: lit ? 0.07 : 0.05, sides: 16)),
                        lit ? .lit(facade == .bands ? NeonStyle.windowColor(row: index, column: 0, salt: 7)
                                                    : ringColor)
                            : .structure)
            z += spacing
            index += 1
        }
        let top = podium.height + height
        massing.add(.cylinder(Cylinder(x: centre, y: centre, z: top, radius: radius + 0.08,
                                       height: 0.12, sides: 16)), .lit(ringColor))
        massing.add(.cylinder(Cylinder(x: centre, y: centre, z: top + 0.12, radius: radius * 0.5,
                                       height: 0.35, sides: 12)))
        let cap = Box(x: centre - 0.05, y: centre - 0.05, z: top + 0.47, width: 0.1, depth: 0.1, height: 0)
        needle(on: cap, z: top + 0.47, height: 0.7, into: &massing)
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
        switch facade {
        case .bands:
            NeonStyle.clad(box, as: CommercialMassing.cladding(for: seed), into: &massing, random: &random)
            CommercialMassing.glazingBands(on: box, into: &massing, random: &random)
            if signed {
                CommercialMassing.bladeSign(on: box, color: NeonStyle.signColor(for: seed),
                                            footprint: footprint, into: &massing, random: &random)
            }
        case .punched:
            NeonStyle.clad(box, as: ResidentialMassing.cladding(for: seed), into: &massing, random: &random)
            ResidentialMassing.windows(on: box, rows: max(2, Int((box.height / 0.36).rounded())),
                                       columns: max(1, Int((box.width / 0.5).rounded())),
                                       chance: 0.66, salt: 3, into: &massing, random: &random)
            guard box.height > 1.2 else { return }
            var fraction = CGFloat(random.value(in: 0.2 ... 0.3))
            while fraction < 0.9 {
                ResidentialMassing.balcony(on: box, at: fraction, into: &massing)
                fraction += CGFloat(random.value(in: 0.24 ... 0.34))
            }
        }
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
