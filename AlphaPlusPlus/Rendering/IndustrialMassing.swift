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
