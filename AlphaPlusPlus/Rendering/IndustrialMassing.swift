import SpriteKit

/// Industry, described as volumes rather than drawn as a facade.
///
/// The vocabulary is `IndustrialBuilding`'s, unchanged — a wide low hall, a
/// sawtooth or monitor or flat roofline, one to three chimneys, storage tanks
/// beside the hall rather than on it, lit bays and a loading dock. Those were
/// always massing decisions; only the drawing was ever a projection decision,
/// which is the whole point of the split.
///
/// **Coordinates are lot-local**, from `(0, 0)` to `(footprint, footprint)`
/// tile units, with `z` up from the ground. The caller places the result at the
/// lot's own origin.
///
/// **One class of bug does not survive the move, and it is worth naming.** In
/// elevation, the renderer scaled a building by its *measured*
/// frame, so bolting a tank onto the side of a hall silently shrank the entire
/// works to fit — which is why `IndustrialBuilding` has to decide whether there
/// are tanks *before* it sizes the hall. Here a building occupies real space in
/// a real lot: things either fit inside the footprint or they do not, and
/// nothing rescales behind your back. The hall still narrows to make room for
/// tanks, but now for the honest reason.
enum IndustrialMassing {

    static func make(tier: Int, seed: GridPosition, footprint: CGFloat = 2) -> BuildingMassing {
        var random = BuildingRandom(seed: seed, salt: tier)
        var massing = BuildingMassing()

        if ZoneMassing.isLandmark(tier: tier, seed: seed) {
            works(tier: tier, seed: seed, footprint: footprint, into: &massing, random: &random)
            return massing
        }

        // **Forms, dealt.** Tier 1 was one sawtooth shed on every lot, the
        // most repeated building in the game after the old tier-1 house.
        // Industry keeps its vocabulary — wide and low, stacks, tanks, lit
        // bays — and now says it several ways: a warehouse with trucks at its
        // doors, gabled sheds, a yard of containers, grain silos, a tank farm,
        // a container port with its gantry, a refinery. Picked on their own
        // stream, so the halls it already drew are unchanged.
        var planRandom = BuildingRandom(seed: seed, salt: 30 + tier)
        let plan = LotPlan(alongX: planRandom.chance(0.5))
        switch tier {
        case 1:
            enum Low: CaseIterable { case hall, warehouse, gabledSheds, containerYard, silos }
            switch ZoneMassing.dealt(Low.allCases, seed: seed, salt: 5) {
            case .hall: break
            case .warehouse: warehouse(plan, tier: tier, seed: seed, into: &massing, random: &random); return massing
            case .gabledSheds: gabledSheds(plan, into: &massing, random: &random); return massing
            case .containerYard: containerYard(plan, crane: false, seed: seed, into: &massing, random: &random); return massing
            case .silos: silos(plan, into: &massing, random: &random); return massing
            }
        case 2:
            enum Mid: CaseIterable { case hall, tankFarm, containerPort, refinery, warehouse }
            switch ZoneMassing.dealt(Mid.allCases, seed: seed, salt: 6) {
            case .hall: break
            case .tankFarm: tankFarm(plan, seed: seed, into: &massing, random: &random); return massing
            case .containerPort: containerYard(plan, crane: true, seed: seed, into: &massing, random: &random); return massing
            case .refinery: refinery(plan, tier: tier, seed: seed, into: &massing, random: &random); return massing
            case .warehouse: warehouse(plan, tier: tier, seed: seed, into: &massing, random: &random); return massing
            }
        default:
            enum High: CaseIterable { case hall, hall2, refinery, tankFarm }
            switch ZoneMassing.dealt(High.allCases, seed: seed, salt: 7) {
            case .hall, .hall2: break
            case .refinery: refinery(plan, tier: tier, seed: seed, into: &massing, random: &random); return massing
            case .tankFarm: tankFarm(plan, seed: seed, into: &massing, random: &random); return massing
            }
        }

        let margin: CGFloat = 0.09
        let hasTanks = tier >= 2 && random.chance(tier >= 3 ? 0.85 : 0.45)
        let tankRadius = CGFloat(random.value(in: 0.24 ... 0.32))

        // Wide and low, and more so at higher tiers — the opposite of how the
        // residential and commercial ladders grow. A tier-3 works sprawls
        // across its lot rather than standing taller on it.
        let hallDepth = footprint - margin * 2
        let hallWidth = hasTanks
            ? footprint - margin * 2 - (tankRadius * 2 + 0.16)
            : footprint - margin * 2
        // **Calibrated against the lot, not guessed.** A tile reads as roughly
        // eight metres, so a 2×2 lot is a sixteen-metre frontage and a single
        // tall factory storey is about one tile unit. The first pass used 0.4,
        // which is a two-metre-high shed: on screen the halls came out as
        // plates with their walls too short to hold a window, and the panels
        // that should have sat on those walls read as stripes painted on the
        // ground. Height is the one dimension isometric adds, and
        // under-using it throws away the entire reason for the projection.
        let hallHeight = CGFloat(random.value(in: 0.62 ... 0.78)) + CGFloat(tier) * 0.1

        let hall = Box(x: margin, y: margin, z: 0,
                       width: hallWidth, depth: hallDepth, height: hallHeight)
        massing.add(.box(hall))
        facade(on: hall, tier: tier, seed: seed, into: &massing, random: &random)
        roof(on: hall, tier: tier, into: &massing, random: &random)

        // Chimneys: the single most recognisable industrial mark, and the one
        // thing here that is genuinely tall. Always at least one, so even a
        // tier-1 shed says "factory" from across the map.
        let stacks = random.int(in: tier >= 3 ? 2 ... 3 : (tier == 2 ? 1 ... 2 : 1 ... 1))
        for index in 0 ..< stacks {
            let spread = hall.width * 0.3
            let x = stacks == 1
                ? hall.x + hall.width / 2 + CGFloat(random.value(in: -Double(spread) ... Double(spread)))
                : hall.x + hall.width / 2 - spread + 2 * spread * CGFloat(index) / CGFloat(stacks - 1)
            chimney(
                at: CGPoint(x: x, y: hall.y + hall.depth * CGFloat(random.value(in: 0.3 ... 0.7))),
                base: hallHeight, tier: tier, into: &massing, random: &random
            )
        }

        // Tanks stand beside the hall, not on it — what gives a works its
        // sprawling, non-rectangular outline.
        if hasTanks {
            let x = hall.x + hall.width + 0.08 + tankRadius
            for index in 0 ..< random.int(in: 1 ... 2) {
                let y = footprint / 2 + (index == 0 ? -1 : 1) * tankRadius * 1.15
                tank(at: CGPoint(x: x, y: min(max(y, margin + tankRadius), footprint - margin - tankRadius)),
                     radius: tankRadius, into: &massing, random: &random)
            }
        }

        // The hazard triangle the tier's own name ("Pollution Warning") has
        // promised since the palette pass.
        if tier >= 3 {
            massing.badges.append(Badge(
                at: Point3(x: hall.x + hall.width * 0.78, y: footprint - margin, z: hallHeight * 0.55),
                size: 15
            ))
        }
        return massing
    }

    /// **The works: industry's landmark, and the one that must not grow a
    /// tower.**
    ///
    /// The other two zones answer this by standing up — a spire, a point
    /// block. Industry cannot, and that is not a gap: this file's vocabulary
    /// is deliberately *wide and low*, the opposite ladder, and a tall
    /// industrial building would stop reading as industry and start reading as
    /// a badly-coloured office. A factory that dominates a view in real life
    /// does it with **one enormous stack**, which is infrastructure rather
    /// than floor space.
    ///
    /// So this is an ordinary hall with a chimney three times the usual — four
    /// to five tile units, against the 1.0 to 1.6 a tier-3 works gets — set on
    /// the ground beside the hall rather than on its roof, so its whole length
    /// is in the silhouette. Flanked by a pair of tanks, because a stack on
    /// its own reads as a mast and a stack beside drums reads as a plant.
    private static func works(
        tier: Int,
        seed: GridPosition,
        footprint: CGFloat,
        into massing: inout BuildingMassing,
        random: inout BuildingRandom
    ) {
        let margin: CGFloat = 0.09
        // **Slender, and the first version was not.** It went to nearly double
        // an ordinary chimney's radius on the reasoning that a landmark should
        // be bigger, and the render was unambiguous: a fat post stops reading
        // as a chimney at all and starts reading as a badly-lit tower. What
        // makes a stack a stack is the *ratio* — this one is barely wider than
        // the two slim ones on an ordinary works and three times as tall.
        let stackRadius = CGFloat(random.value(in: 0.13 ... 0.16))
        // The hall gives up the width the stack and its drums stand in.
        let reserved = stackRadius * 2 + 0.34
        let hall = Box(x: margin, y: margin, z: 0,
                       width: footprint - margin * 2 - reserved, depth: footprint - margin * 2,
                       height: CGFloat(random.value(in: 0.7 ... 0.9)) + CGFloat(tier) * 0.1)
        massing.add(.box(hall))
        facade(on: hall, tier: tier, seed: seed, into: &massing, random: &random)
        roof(on: hall, tier: tier, into: &massing, random: &random)

        let stackX = hall.x + hall.width + 0.2 + stackRadius
        // A squat plinth, wide enough to read as one, so the stack meets the
        // ground as a structure does rather than as a pole pushed into it.
        let plinth = Box(x: stackX - stackRadius * 1.9, y: footprint / 2 - stackRadius * 1.9,
                         z: 0, width: stackRadius * 3.8, depth: stackRadius * 3.8,
                         height: CGFloat(random.value(in: 0.24 ... 0.34)))
        massing.add(.box(plinth))
        massing.add(.cylinder(Cylinder(
            x: stackX, y: footprint / 2, z: plinth.height,
            radius: stackRadius, height: CGFloat(random.value(in: 4.2 ... 5.2))
        )))

        // Drums beside the hall, where an ordinary works puts them, rather
        // than flanking the stack — the render showed them disappearing
        // behind it, and a landmark whose supporting marks are hidden is one
        // mark on an otherwise emptied lot.
        let drumRadius = CGFloat(random.value(in: 0.2 ... 0.26))
        for index in 0 ..< 2 {
            let y = footprint / 2 + (index == 0 ? -1 : 1) * drumRadius * 1.2
            guard y > margin + drumRadius, y < footprint - margin - drumRadius else { continue }
            tank(at: CGPoint(x: stackX - stackRadius - 0.1 - drumRadius, y: y),
                 radius: drumRadius, into: &massing, random: &random)
        }
    }

    // MARK: - Parts

    /// The roofline, and the part that does most of the work of saying
    /// "industrial" — a sawtooth is a shape no other zone in the game draws,
    /// and in isometric it is a row of real wedges rather than a row of
    /// triangles painted on a silhouette.
    private static func roof(
        on hall: Box,
        tier: Int,
        into massing: inout BuildingMassing,
        random: inout BuildingRandom
    ) {
        enum Style: CaseIterable { case sawtooth, monitor, flat }
        let style: Style = tier == 1 ? random.pick([.sawtooth, .flat]) : random.pick(Style.allCases)

        switch style {
        case .sawtooth:
            // The classic north-light factory roof. `ridgePosition: 1` puts the
            // ridge at the far wall, which is exactly what a sawtooth is — the
            // same primitive as a gable, not a second roof type.
            let teeth = random.int(in: 3 ... 4)
            let toothDepth = hall.depth / CGFloat(teeth)
            let height = CGFloat(random.value(in: 0.3 ... 0.42))
            for index in 0 ..< teeth {
                massing.add(.ridge(Ridge(
                    x: hall.x, y: hall.y + CGFloat(index) * toothDepth, z: hall.z + hall.height,
                    width: hall.width, depth: toothDepth, height: height,
                    axis: .x, ridgePosition: 1
                )))
            }
        case .monitor:
            // A raised clerestory running along the ridge.
            let inset = hall.depth * CGFloat(random.value(in: 0.24 ... 0.34))
            let box = Box(x: hall.x + 0.06, y: hall.y + inset, z: hall.z + hall.height,
                          width: hall.width - 0.12, depth: hall.depth - inset * 2,
                          height: CGFloat(random.value(in: 0.3 ... 0.42)))
            massing.add(.box(box))
            for face in [Panel.Face.right, .left] {
                massing.panels.append(Panel(box: box, face: face, u0: 0.1, u1: 0.9, v0: 0.25, v1: 0.75,
                                            color: NeonStyle.litAccent))
            }
        case .flat:
            // A parapet, plus rooftop plant. The quiet option should still not
            // be a blank one: in elevation a flat roof was a single line at the
            // top of a silhouette, but isometric shows the whole roof plane, so
            // an empty one is a large featureless quad pointing straight at the
            // camera — the biggest surface on the building saying nothing.
            massing.add(.box(Box(
                x: hall.x - 0.03, y: hall.y - 0.03, z: hall.z + hall.height,
                width: hall.width + 0.06, depth: hall.depth + 0.06, height: 0.1
            )))
            for _ in 0 ..< random.int(in: 1 ... 3) {
                let width = CGFloat(random.value(in: 0.2 ... 0.4))
                let depth = CGFloat(random.value(in: 0.2 ... 0.4))
                massing.add(.box(Box(
                    x: hall.x + CGFloat(random.value(in: 0.1 ... 1)) * (hall.width - width),
                    y: hall.y + CGFloat(random.value(in: 0 ... 1)) * (hall.depth - depth),
                    z: hall.z + hall.height,
                    width: width, depth: depth,
                    height: CGFloat(random.value(in: 0.14 ... 0.26))
                )))
            }
        }
    }

    /// Lit bays and a loading dock on the two walls the camera can see.
    ///
    /// Industrial glazing is wide bands rather than the tidy grids housing and
    /// offices use, and only the *lit* bays are drawn: a dark bay painted on a
    /// near-black wall is not a dark window, it is nothing.
    private static func facade(
        on hall: Box,
        tier: Int,
        seed: GridPosition,
        into massing: inout BuildingMassing,
        random: inout BuildingRandom
    ) {
        for face in [Panel.Face.right, .left] {
            let bays = random.int(in: 2 ... 3)
            for index in 0 ..< bays where random.chance(0.6) {
                massing.panels.append(Panel(
                    box: hall, face: face,
                    u0: (CGFloat(index) + 0.18) / CGFloat(bays),
                    u1: (CGFloat(index) + 0.82) / CGFloat(bays),
                    v0: 0.28, v1: 0.66,
                    color: NeonStyle.windowColor(row: index, column: 0, salt: tier)
                ))
            }
            if tier >= 2, random.chance(0.6) {
                // A loading dock cut into the base.
                let centre = CGFloat(random.value(in: 0.3 ... 0.7))
                massing.panels.append(Panel(
                    box: hall, face: face,
                    u0: centre - 0.13, u1: centre + 0.13, v0: 0, v1: 0.42,
                    color: NeonStyle.recessedAccent
                ))
            }
        }
        // One lit sign plaque, low on the near wall.
        massing.panels.append(Panel(
            box: hall, face: .left, u0: 0.08, u1: 0.34, v0: 0.7, v1: 0.92,
            color: NeonStyle.signColor(for: seed)
        ))
    }

    private static func chimney(
        at point: CGPoint,
        base: CGFloat,
        tier: Int,
        into massing: inout BuildingMassing,
        random: inout BuildingRandom
    ) {
        let radius = CGFloat(random.value(in: 0.1 ... 0.145))
        let height = CGFloat(random.value(in: tier >= 3 ? 1.0 ... 1.6 : (tier == 2 ? 0.75 ... 1.15 : 0.5 ... 0.85)))
        massing.add(.cylinder(Cylinder(x: point.x, y: point.y, z: base, radius: radius, height: height)))
        // The elevation version banded the cap so a chimney didn't read as a
        // plain post. Not carried over: a band on a stack six points wide is
        // under two points tall, which is below anything the camera resolves,
        // and in massing it costs a whole extra volume rather than one rect.
    }

    // MARK: - More forms

    /// A long low warehouse along the back of its lot, lit loading doors on
    /// its yard side, a dock, and trucks backed up to it.
    private static func warehouse(
        _ plan: LotPlan, tier: Int, seed: GridPosition,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let depth = CGFloat(random.value(in: 0.9 ... 1.08))
        let hall = plan.box(0.1, 0.1, 1.8, depth, height: CGFloat(random.value(in: 0.56 ... 0.68)) + CGFloat(tier) * 0.08)
        massing.add(.box(hall))
        massing.add(.box(Box(x: hall.x - 0.02, y: hall.y - 0.02, z: hall.height, width: hall.width + 0.04,
                             depth: hall.depth + 0.04, height: 0.06)))
        let doors = 4
        for door in 0 ..< doors {
            let u = (CGFloat(door) + 0.5) / CGFloat(doors)
            massing.panels.append(Panel(box: hall, face: plan.face(.left), u0: u - 0.08, u1: u + 0.08,
                                        v0: 0, v1: 0.5, color: NeonStyle.windowColor(row: door, column: 0, salt: 9)))
        }
        massing.panels.append(Panel(box: hall, face: plan.face(.right), u0: 0.2, u1: 0.8, v0: 0.6, v1: 0.8,
                                    color: NeonStyle.signColor(for: seed, salt: 11)))
        massing.add(.box(plan.box(0.1, 0.1 + depth, 1.8, 0.12, height: 0.08)))
        for (index, a) in [0.3, 1.1].enumerated() where index == 0 || random.chance(0.6) {
            truck(plan, a: CGFloat(a), b: 0.1 + depth + 0.12, index: index, into: &massing)
        }
        chimney(at: CGPoint(x: plan.point(1.5, 0.3).0, y: plan.point(1.5, 0.3).1), base: hall.height,
                tier: tier, into: &massing, random: &random)
    }

    /// A trailer and cab, backed up square to a dock.
    private static func truck(_ plan: LotPlan, a: CGFloat, b: CGFloat, index: Int, into massing: inout BuildingMassing) {
        massing.add(.box(plan.box(a, b, 0.18, 0.44, height: 0.22 + CGFloat(index) * 0.004)))
        massing.add(.box(plan.box(a + 0.01, b + 0.46, 0.16, 0.16, height: 0.17)))
    }

    /// Two gabled sheds side by side, different lengths, a stack between them
    /// and crates in the yard: the small workshop, which is what a sawtooth
    /// works looks like before it grows.
    private static func gabledSheds(
        _ plan: LotPlan, into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let first = plan.box(0.12, 0.12, CGFloat(random.value(in: 1.4 ... 1.62)), 0.78, height: 0.5)
        let second = plan.box(0.12, 0.96, CGFloat(random.value(in: 1.0 ... 1.24)), 0.66, height: 0.44)
        for (index, shed) in [first, second].enumerated() {
            massing.add(.box(shed))
            massing.panels.append(Panel(box: shed, face: plan.face(.left), u0: 0.12, u1: 0.4, v0: 0, v1: 0.62,
                                        color: NeonStyle.windowColor(row: index, column: 1, salt: 9)))
            massing.panels.append(Panel(box: shed, face: plan.face(.right), u0: 0.3, u1: 0.7, v0: 0.25, v1: 0.6,
                                        color: NeonStyle.litAccent))
            massing.add(.ridge(Ridge(x: shed.x - 0.04, y: shed.y - 0.04, z: shed.height,
                                     width: shed.width + 0.08, depth: shed.depth + 0.08,
                                     height: 0.3 + CGFloat(index) * 0.02, axis: plan.alongX ? .x : .y)))
        }
        chimney(at: CGPoint(x: plan.point(0.4, 0.94).0, y: plan.point(0.4, 0.94).1), base: 0.44,
                tier: 1, into: &massing, random: &random)
        for index in 0 ..< random.int(in: 2 ... 3) {
            massing.add(.box(plan.box(1.5, 1.2 + CGFloat(index) * 0.2, 0.26, 0.16, height: 0.16 + CGFloat(index) * 0.01)))
        }
    }

    /// A yard of shipping containers stacked beside a low workshop; with
    /// `crane`, a gantry spans the stacks and it is a container port.
    private static func containerYard(
        _ plan: LotPlan, crane: Bool, seed: GridPosition,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let shop = plan.box(0.1, 0.1, 0.62, 1.8, height: CGFloat(random.value(in: 0.6 ... 0.75)) + (crane ? 0.2 : 0))
        massing.add(.box(shop))
        massing.panels.append(Panel(box: shop, face: plan.face(.right), u0: 0.1, u1: 0.9, v0: 0, v1: 0.5,
                                    color: NeonStyle.windowColor(row: 1, column: 2, salt: 9)))
        chimney(at: CGPoint(x: plan.point(0.4, 0.5).0, y: plan.point(0.4, 0.5).1), base: shop.height,
                tier: crane ? 2 : 1, into: &massing, random: &random)
        // Containers: the proportion is the mark — long, low, stacked.
        for row in 0 ..< 3 {
            let stack = random.int(in: 1 ... (crane ? 3 : 2))
            for level in 0 ..< stack {
                let b = 0.2 + CGFloat(row) * 0.56
                massing.add(.box(plan.box(0.92 + CGFloat(level % 2) * 0.03, b, 0.66, 0.24,
                                          z: CGFloat(level) * 0.2, height: 0.19)))
                massing.add(.box(plan.box(0.92, b + 0.27, 0.66, 0.2, z: 0, height: 0.18 + CGFloat(row) * 0.004)))
            }
        }
        guard crane else { return }
        let top: CGFloat = 1.2
        for (a, b) in [(0.84, 0.14), (1.72, 0.14), (0.84, 1.8), (1.72, 1.8)] as [(CGFloat, CGFloat)] {
            massing.add(.box(plan.box(a, b, 0.06, 0.06, height: top)))
        }
        massing.add(.box(plan.box(0.84, 0.14, 0.94, 0.06, z: top, height: 0.08)))
        massing.add(.box(plan.box(0.84, 1.8, 0.94, 0.06, z: top + 0.002, height: 0.08)))
        let trolley = CGFloat(random.value(in: 0.4 ... 1.2))
        massing.add(.box(plan.box(1.1, 0.14, 0.1, 1.72, z: top + 0.08, height: 0.08)))
        massing.add(.box(plan.box(1.08, trolley, 0.14, 0.2, z: top - 0.04, height: 0.1)),
                    .lit(NeonStyle.signColor(for: seed, salt: 12)))
    }

    /// Grain silos in a row, a headhouse bridging their tops, and a low hall
    /// in front: the tallest thing a tier-1 lot of industry draws, and its
    /// own silhouette.
    private static func silos(
        _ plan: LotPlan, into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let count = random.int(in: 3 ... 4)
        let radius: CGFloat = 0.2
        let height = CGFloat(random.value(in: 1.2 ... 1.5))
        let spacing = 1.6 / CGFloat(count)
        for index in 0 ..< count {
            let (x, y) = plan.point(0.2 + spacing * (CGFloat(index) + 0.5), 0.36)
            massing.add(.cylinder(Cylinder(x: x, y: y, z: 0, radius: radius, height: height + CGFloat(index) * 0.01, sides: 10)))
        }
        let head = plan.box(0.24, 0.26, 1.52, 0.2, z: height + 0.04, height: 0.2)
        massing.add(.box(head))
        massing.panels.append(Panel(box: head, face: plan.face(.left), u0: 0.1, u1: 0.9, v0: 0.3, v1: 0.7,
                                    color: NeonStyle.litAccent))
        let hall = plan.box(0.16, 0.9, 1.3, 0.8, height: 0.46)
        massing.add(.box(hall))
        massing.add(.ridge(Ridge(x: hall.x - 0.03, y: hall.y - 0.03, z: hall.height, width: hall.width + 0.06,
                                 depth: hall.depth + 0.06, height: 0.22, axis: plan.alongX ? .x : .y)))
        massing.panels.append(Panel(box: hall, face: plan.face(.left), u0: 0.1, u1: 0.4, v0: 0, v1: 0.6,
                                    color: NeonStyle.windowColor(row: 0, column: 0, salt: 9)))
    }

    /// A tank farm: four drums of different sizes, a pipe rack between them,
    /// a control hut, and a flare stack burning at the top.
    private static func tankFarm(
        _ plan: LotPlan, seed: GridPosition, into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        for (a, b) in [(0.46, 0.46), (1.42, 0.5), (0.5, 1.4)] as [(CGFloat, CGFloat)] {
            let radius = CGFloat(random.value(in: 0.28 ... 0.34))
            let (x, y) = plan.point(a, b)
            massing.add(.cylinder(Cylinder(x: x, y: y, z: 0, radius: radius,
                                           height: CGFloat(random.value(in: 0.5 ... 0.85)))))
        }
        let hut = plan.box(1.18, 1.18, 0.5, 0.42, height: 0.36)
        massing.add(.box(hut))
        massing.panels.append(Panel(box: hut, face: plan.face(.left), u0: 0.15, u1: 0.85, v0: 0.3, v1: 0.7,
                                    color: NeonStyle.litAccent))
        massing.add(.box(plan.box(0.2, 0.92, 1.62, 0.06, z: 0.34, height: 0.05)))
        flare(at: plan.point(1.66, 1.66), height: CGFloat(random.value(in: 1.3 ... 1.7)), into: &massing)
    }

    /// A refinery: two process columns ringed in light, a flare stack, drums
    /// and a low process block — the densest silhouette industry has, and at
    /// tier 3 it carries the hazard mark.
    private static func refinery(
        _ plan: LotPlan, tier: Int, seed: GridPosition,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let block = plan.box(0.12, 1.02, 1.1, 0.8, height: 0.42 + CGFloat(tier) * 0.06)
        massing.add(.box(block))
        massing.panels.append(Panel(box: block, face: plan.face(.left), u0: 0.1, u1: 0.9, v0: 0.3, v1: 0.6,
                                    color: NeonStyle.windowColor(row: 0, column: 1, salt: 9)))
        let ring = NeonStyle.signColor(for: seed, salt: 13)
        for (index, (a, b)) in ([(0.4, 0.4), (0.9, 0.46)] as [(CGFloat, CGFloat)]).enumerated() {
            let (x, y) = plan.point(a, b)
            let height = CGFloat(random.value(in: 1.2 ... 1.6)) + CGFloat(tier) * 0.15 - CGFloat(index) * 0.3
            let radius = index == 0 ? CGFloat(0.16) : 0.13
            massing.add(.cylinder(Cylinder(x: x, y: y, z: 0, radius: radius, height: height)))
            var z: CGFloat = 0.4
            while z < height - 0.2 {
                massing.add(.cylinder(Cylinder(x: x, y: y, z: z, radius: radius + 0.03, height: 0.04)), .lit(ring))
                z += 0.4
            }
        }
        for (a, b) in [(1.5, 0.4), (1.52, 0.98)] as [(CGFloat, CGFloat)] {
            let (x, y) = plan.point(a, b)
            massing.add(.cylinder(Cylinder(x: x, y: y, z: 0, radius: 0.26,
                                           height: CGFloat(random.value(in: 0.5 ... 0.7)))))
        }
        massing.add(.box(plan.box(0.3, 0.74, 1.4, 0.05, z: 0.46, height: 0.05)))
        flare(at: plan.point(1.62, 1.62), height: CGFloat(random.value(in: 1.6 ... 2.0)), into: &massing)
        if tier >= 3 {
            let (x, y) = plan.point(0.7, 1.82)
            massing.badges.append(Badge(at: Point3(x: x, y: y, z: block.height * 0.55), size: 15))
        }
    }

    /// A flare stack: a thin mast burning at the top, in ember.
    private static func flare(at point: (CGFloat, CGFloat), height: CGFloat, into massing: inout BuildingMassing) {
        massing.add(.cylinder(Cylinder(x: point.0, y: point.1, z: 0, radius: 0.045, height: height, sides: 8)))
        massing.add(.cylinder(Cylinder(x: point.0, y: point.1, z: height, radius: 0.08, height: 0.14, sides: 8)),
                    .lit(NeonStyle.emberColor))
    }

    private static func tank(
        at point: CGPoint,
        radius: CGFloat,
        into massing: inout BuildingMassing,
        random: inout BuildingRandom
    ) {
        let height = CGFloat(random.value(in: 0.6 ... 0.95))
        massing.add(.cylinder(Cylinder(x: point.x, y: point.y, z: 0, radius: radius, height: height)))
        // A tank is wide enough to carry a banding line, but a separate ring
        // volume costs ten faces for it. In isometric the tank already reads as
        // a drum because its top is a real ellipse catching light, which is the
        // job the band was doing in elevation.
    }
}
