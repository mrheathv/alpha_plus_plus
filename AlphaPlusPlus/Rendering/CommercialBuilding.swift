import SpriteKit

/// Draws commercial buildings parametrically, from a seed.
///
/// **The vocabulary, and why it is this one.** Commerce has to read as *glass
/// and signage* against housing's punched windows and industry's sheds. The
/// marks that do that:
///
/// - **Continuous glazing bands.** Unbroken horizontal ribbons of light across
///   the whole facade, rather than housing's grid of separate little windows.
///   One long lit strip reads as an open floor plate; a grid of small ones
///   reads as many homes. This is the single strongest difference between the
///   two zones and it survives greyscale.
/// - **A glazed podium.** A tall, fully-lit ground floor — the shopfront —
///   usually wider than the tower above it.
/// - **Projecting signage.** A vertical blade sign, a rooftop billboard, or a
///   fascia band, lit in its own colour rather than the building's accent.
/// - **An illuminated crown.** Offices light their tops; housing puts water
///   tanks up there (see `ResidentialBuilding.crown`).
///
/// **Why there is a `Form` and not just size ranges.** The first pass varied
/// only dimensions, and the contact sheet showed the cost immediately: all ten
/// tier-1 lots were the same drawing at slightly different widths — podium,
/// dark storey, billboard — because at tier 1 every random branch in the file
/// was either disabled (`tier >= 2` guards on the setback and the blade sign)
/// or forced (the crown was always `litBand`). Varying numbers inside one
/// massing does not produce variety; it produces the same building ten times.
/// Low-density commerce in a real city is genuinely several different
/// *buildings* — a strip of shops, a shop with a flat over it, a corner unit —
/// so tier 1 now picks between those, and only the tiers where commerce really
/// does converge on one form (podium plus tower) share a single massing.
///
/// See `IndustrialBuilding` for why growable zones are generated at all.
enum CommercialBuilding {

    /// The overall massing. Tier 1 picks between the three street forms;
    /// tiers 2-3 are always `podiumTower`, since that *is* what densifying
    /// commerce looks like and the variety there comes from setbacks, crowns
    /// and signage instead.
    private enum Form { case strip, shopAndFlat, cornerUnit, podiumTower }

    static func make(tier: Int, accent: SKColor, seed: GridPosition) -> SKNode {
        var random = BuildingRandom(seed: seed, salt: 200 + tier)
        let form: Form = tier >= 2
            ? .podiumTower
            : random.pick([.strip, .shopAndFlat, .cornerUnit])

        let container = SKNode()
        var outline: [SKShapeNode] = []
        var details: [SKNode] = []

        switch form {
        case .strip:
            strip(accent: accent, seed: seed, outline: &outline, details: &details, random: &random)
        case .cornerUnit:
            cornerUnit(accent: accent, seed: seed, outline: &outline, details: &details, random: &random)
        case .shopAndFlat, .podiumTower:
            podiumTower(tier: tier, accent: accent, seed: seed,
                        outline: &outline, details: &details, random: &random)
        }

        container.addChild(ZoneIcon.withGlow(outline, color: accent))
        details.forEach(container.addChild)
        return container
    }

    // MARK: - Forms

    /// A single wide low block: the strip of shops. All shopfront along the
    /// bottom, a full-width fascia sign above it, and rooftop plant boxes for
    /// a silhouette that isn't a plain rectangle. No storey above, which is
    /// what makes it read as a different building rather than a short tower.
    private static func strip(
        accent: SKColor,
        seed: GridPosition,
        outline: inout [SKShapeNode],
        details: inout [SKNode],
        random: inout BuildingRandom
    ) {
        let width = CGFloat(random.value(in: 76 ... 88))
        let height = CGFloat(random.value(in: 32 ... 42))
        let body = CGRect(x: -width / 2, y: -40, width: width, height: height)
        outline.append(ZoneIcon.neonShape(rect: body, accent: accent))
        let ground = shopfront(in: body, glassShare: 0.36 ... 0.46, random: &random)
        details.append(contentsOf: ground.parts)

        // The upper face carries exactly one of two things. Trying to fit both
        // a sign band and a window band between the shopfront and the parapet
        // never worked — a 36-point-tall block simply has no room for two
        // stacked bands, and the guard that checked for room was false every
        // time, so the windows silently never drew. One or the other also
        // gives the strip form two readable looks instead of one.
        let signColor = ZoneIcon.signColor(for: seed)
        let bandBottom = max(ground.glassTop + 6, body.maxY - 13)
        if random.chance(0.5) {
            // The fascia: a long lit sign band, the mark that says "several
            // shops behind one frontage".
            let fasciaWidth = width * CGFloat(random.value(in: 0.62 ... 0.86))
            details.append(ZoneIcon.neonSignboard(
                rect: CGRect(x: -fasciaWidth / 2, y: bandBottom, width: fasciaWidth, height: 10),
                color: signColor
            ))
        } else {
            // A clerestory of small panes, with the sign moved up onto the
            // roof as a billboard instead.
            let panes = random.int(in: 3 ... 4)
            let bandWidth = width * 0.8
            let paneWidth = max(ZoneIcon.minimumDetailSize, bandWidth / CGFloat(panes) * 0.82)
            for index in 0 ..< panes {
                let x = -bandWidth / 2 + bandWidth * (CGFloat(index) + 0.5) / CGFloat(panes)
                guard random.chance(0.7) else { continue }
                details.append(ZoneIcon.detail(
                    rect: CGRect(x: x - paneWidth / 2, y: bandBottom, width: paneWidth, height: 9),
                    fill: ZoneIcon.windowColor(row: 0, column: index, salt: 3)
                ))
            }
            let boardWidth = width * CGFloat(random.value(in: 0.3 ... 0.46))
            details.append(ZoneIcon.neonSignboard(
                rect: CGRect(x: CGFloat(random.value(in: -0.14 ... 0.14)) * width - boardWidth / 2,
                             y: body.maxY + 5, width: boardWidth, height: 10),
                color: signColor
            ))
        }

        // Parapet plus rooftop plant — the cheap flat-roof retail silhouette.
        outline.append(ZoneIcon.neonShape(
            rect: CGRect(x: body.minX - 2, y: body.maxY, width: width + 4, height: 4),
            accent: accent, lineWidth: 1.5
        ))
        let units = random.int(in: 1 ... 3)
        for index in 0 ..< units {
            let unitWidth = CGFloat(random.value(in: 9 ... 15))
            // Spread the units across the roof and keep them *on* it: an
            // unclamped offset put a lone box past the parapet, where it read
            // as a floating rectangle rather than as rooftop plant.
            let slot = width / CGFloat(units)
            let limit = width / 2 - unitWidth / 2 - 4
            let x = min(max(-width / 2 + slot * (CGFloat(index) + 0.5)
                            + CGFloat(random.value(in: -0.1 ... 0.1)) * width, -limit), limit)
            outline.append(ZoneIcon.neonShape(
                rect: CGRect(x: x - unitWidth / 2, y: body.maxY + 4,
                             width: unitWidth, height: CGFloat(random.value(in: 5 ... 9))),
                accent: accent, lineWidth: 1.5
            ))
        }
    }

    /// A low shopfront block with one narrow taller element stood on one end:
    /// the corner unit. The asymmetry is the point — nothing else in the
    /// commercial vocabulary is off-centre.
    private static func cornerUnit(
        accent: SKColor,
        seed: GridPosition,
        outline: inout [SKShapeNode],
        details: inout [SKNode],
        random: inout BuildingRandom
    ) {
        let side: CGFloat = random.chance(0.5) ? -1 : 1
        let baseWidth = CGFloat(random.value(in: 64 ... 76))
        let baseHeight = CGFloat(random.value(in: 20 ... 26))
        let base = CGRect(x: -baseWidth / 2, y: -40, width: baseWidth, height: baseHeight)
        outline.append(ZoneIcon.neonShape(rect: base, accent: accent))
        details.append(contentsOf: shopfront(in: base, glassShare: 0.5 ... 0.64, random: &random).parts)

        let towerWidth = CGFloat(random.value(in: 22 ... 30))
        let towerHeight = CGFloat(random.value(in: 30 ... 44))
        let towerX = side * (baseWidth / 2 - towerWidth / 2 - CGFloat(random.value(in: 0 ... 5)))
        let tower = CGRect(x: towerX - towerWidth / 2, y: base.maxY,
                           width: towerWidth, height: towerHeight)
        outline.append(ZoneIcon.neonShape(rect: tower, accent: accent))
        details.append(contentsOf: glazingBands(in: tower, random: &random))

        // A blade sign hung off the tower's outer edge, over the street.
        details.append(ZoneIcon.neonSignboard(
            rect: CGRect(x: towerX + side * (towerWidth / 2 + 1) - 3,
                         y: tower.minY + towerHeight * 0.25,
                         width: 9, height: towerHeight * CGFloat(random.value(in: 0.4 ... 0.62))),
            color: ZoneIcon.signColor(for: seed)
        ))

        outline.append(contentsOf: crown(
            atTop: tower.maxY, width: towerWidth, centeredAt: towerX,
            tier: 1, accent: accent, random: &random
        ))
    }

    /// The podium-and-tower form: a glazed base with a slimmer block above,
    /// optionally set back, crowned and signed. At tier 1 it is a shop with a
    /// flat over it; at tier 3 it is a tower standing on a small base.
    private static func podiumTower(
        tier: Int,
        accent: SKColor,
        seed: GridPosition,
        outline: inout [SKShapeNode],
        details: inout [SKNode],
        random: inout BuildingRandom
    ) {
        let podiumHeight = CGFloat(random.value(in: tier == 1 ? 22 ... 30 : 16 ... 22))
        let podiumWidth = CGFloat(random.value(in: tier >= 2 ? 66 ... 78 : 62 ... 74))
        let podium = CGRect(x: -podiumWidth / 2, y: -40, width: podiumWidth, height: podiumHeight)
        outline.append(ZoneIcon.neonShape(rect: podium, accent: accent))
        details.append(contentsOf: shopfront(in: podium, glassShare: 0.44 ... 0.58, random: &random).parts)

        let towerHeight = CGFloat(random.value(in: tier >= 3 ? 62 ... 76 : (tier == 2 ? 40 ... 54 : 20 ... 32)))
        let towerWidth = podiumWidth * CGFloat(random.value(in: tier >= 3 ? 0.58 ... 0.72 : 0.74 ... 0.9))
        let towerX = CGFloat(random.value(in: -0.1 ... 0.1)) * podiumWidth
        let tower = CGRect(
            x: towerX - towerWidth / 2, y: podium.maxY,
            width: towerWidth, height: towerHeight
        )
        outline.append(ZoneIcon.neonShape(rect: tower, accent: accent))
        details.append(contentsOf: glazingBands(in: tower, random: &random))

        // A setback section on taller towers, so the skyline isn't a row of
        // identical slabs. Tier 3 towers are tall enough for two.
        var crownBase = tower.maxY
        var crownWidth = towerWidth
        let setbacks = tier >= 3 ? random.int(in: 0 ... 2) : (tier == 2 && random.chance(0.55) ? 1 : 0)
        for _ in 0 ..< setbacks {
            let setbackWidth = crownWidth * CGFloat(random.value(in: 0.62 ... 0.82))
            let setbackHeight = CGFloat(random.value(in: 10 ... 20))
            let setback = CGRect(
                x: towerX - setbackWidth / 2, y: crownBase,
                width: setbackWidth, height: setbackHeight
            )
            outline.append(ZoneIcon.neonShape(rect: setback, accent: accent))
            details.append(contentsOf: glazingBands(in: setback, random: &random))
            crownBase = setback.maxY
            crownWidth = setbackWidth
        }

        outline.append(contentsOf: crown(
            atTop: crownBase, width: crownWidth, centeredAt: towerX,
            tier: tier, accent: accent, random: &random
        ))
        details.append(contentsOf: signage(
            podium: podium, tower: tower, tier: tier, seed: seed, random: &random
        ))
    }

    // MARK: - Parts

    /// Unbroken horizontal ribbons — the mark that separates commerce from
    /// housing at a glance.
    /// **Fewer, thicker ribbons, and no mullions.** These were four to six
    /// points tall with 1.4-point verticals crossing them. At the size a lot
    /// is played at the verticals were a third of a screen point — they never
    /// drew as lines, only as a wash that dimmed every band they crossed — and
    /// the bands themselves were thin enough to blur into the silhouette. A
    /// band is now a real slab of light at `ZoneIcon.minimumDetailSize` or
    /// more, and the mullions are gone. Losing them costs nothing that was
    /// ever visible: what stops the facade reading as a striped box is the
    /// dark band between ribbons and the podium below, not a hairline.
    private static func glazingBands(in rect: CGRect, random: inout BuildingRandom) -> [SKNode] {
        let bandHeight = max(ZoneIcon.minimumDetailSize, CGFloat(random.value(in: 9 ... 12)))
        let gap = CGFloat(random.value(in: 6 ... 9))
        guard rect.height > bandHeight + gap else { return [] }
        // Inset hard. Thickening the bands without narrowing them turned a
        // tower into a stack of fat light bars with no building left between
        // them — the dark margin either side is what keeps it reading as
        // glazing *in* a facade rather than as the facade itself.
        let inset = rect.width * 0.17

        var parts: [SKNode] = []
        var y = rect.minY + gap
        var index = 0
        while y + bandHeight < rect.maxY - 3 {
            // Occasionally a band is dark, so the tower isn't a perfect ladder.
            if random.chance(0.84) {
                parts.append(ZoneIcon.detail(
                    rect: CGRect(x: rect.minX + inset, y: y, width: rect.width - inset * 2, height: bandHeight),
                    fill: ZoneIcon.windowColor(row: index, column: 0, salt: 7)
                ))
            }
            y += bandHeight + gap
            index += 1
        }
        return parts
    }

    /// The ground floor: one tall, bright, fully-glazed strip with an awning.
    /// `glassShare` is how much of the block's height the glazing takes — a
    /// strip of shops is nearly all glass, a tower's podium rather less.
    private static func shopfront(
        in podium: CGRect,
        glassShare: ClosedRange<Double>,
        random: inout BuildingRandom
    ) -> (parts: [SKNode], glassTop: CGFloat) {
        let glassHeight = max(ZoneIcon.minimumDetailSize,
                              podium.height * CGFloat(random.value(in: glassShare)))
        // One unbroken slab of light. The 1.6-point door mullions that used to
        // divide it were well under `ZoneIcon.minimumDetailSize` and only
        // dimmed the brightest, most zone-identifying mark commerce has.
        let glassInset = max(6, podium.width * 0.09)
        var parts: [SKNode] = [ZoneIcon.detail(
            rect: CGRect(
                x: podium.minX + glassInset, y: podium.minY + 4,
                width: podium.width - glassInset * 2, height: glassHeight
            ),
            fill: ZoneIcon.litAccent
        )]
        if random.chance(0.6) {
            // An awning over the glazing — a dark bar, so it has to be thick
            // enough to actually separate the glass from the wall above it.
            parts.append(ZoneIcon.detail(
                rect: CGRect(
                    x: podium.minX - 2, y: podium.minY + glassHeight + 6,
                    width: podium.width + 4, height: 5
                ),
                fill: ZoneIcon.recessedAccent
            ))
        }
        return (parts, podium.minY + 4 + glassHeight)
    }

    /// A blade sign on the tower or a billboard on the podium roof, lit in the
    /// sign palette rather than the building's own accent.
    private static func signage(
        podium: CGRect,
        tower: CGRect,
        tier: Int,
        seed: GridPosition,
        random: inout BuildingRandom
    ) -> [SKNode] {
        var parts: [SKNode] = []
        let color = ZoneIcon.signColor(for: seed)

        if tower.height > 24, random.chance(tier >= 2 ? 0.7 : 0.45) {
            // Vertical blade sign down one edge of the tower.
            let side: CGFloat = random.chance(0.5) ? -1 : 1
            let height = tower.height * CGFloat(random.value(in: 0.35 ... 0.6))
            parts.append(ZoneIcon.neonSignboard(
                rect: CGRect(
                    x: side * (tower.width / 2 + 1) + tower.midX - 4.5,
                    y: tower.minY + tower.height * 0.2,
                    width: 9, height: height
                ),
                color: color
            ))
        } else if random.chance(0.5) {
            // Billboard on the podium roof, off-centre as often as not.
            let width = podium.width * CGFloat(random.value(in: 0.3 ... 0.48))
            let x = CGFloat(random.value(in: -0.18 ... 0.18)) * podium.width
            parts.append(ZoneIcon.neonSignboard(
                rect: CGRect(x: x - width / 2, y: podium.maxY + 2, width: width, height: 10),
                color: color
            ))
        } else {
            // A fascia band across the podium itself, under the tower.
            let width = podium.width * CGFloat(random.value(in: 0.5 ... 0.78))
            parts.append(ZoneIcon.neonSignboard(
                rect: CGRect(x: -width / 2, y: podium.maxY - 10, width: width, height: 9),
                color: color
            ))
        }
        return parts
    }

    /// Offices light their tops: a glowing band, a stepped cap, a mast, or a
    /// plain parapet. Tier 1 gets the quieter three — a mast on a two-storey
    /// shop reads as a mistake rather than as a skyline.
    private static func crown(
        atTop y: CGFloat,
        width: CGFloat,
        centeredAt x: CGFloat,
        tier: Int,
        accent: SKColor,
        random: inout BuildingRandom
    ) -> [SKShapeNode] {
        enum Style: CaseIterable { case litBand, steppedCap, mast, parapet }
        let style: Style = tier == 1
            ? random.pick([.litBand, .steppedCap, .parapet])
            : random.pick(Style.allCases)

        switch style {
        case .litBand:
            // Inset rather than overhanging, and dimmer: an overhanging bright
            // bar on top of a dark tower read as a separate floating slab.
            let band = ZoneIcon.neonShape(
                rect: CGRect(x: x - width / 2 + 2, y: y - 2, width: width - 4, height: 6),
                accent: accent, lineWidth: 1.5
            )
            band.fillColor = ZoneIcon.litAccent.withAlphaComponent(0.38)
            return [band]
        case .steppedCap:
            let midWidth = width * 0.7
            let topWidth = width * 0.42
            return [
                ZoneIcon.neonShape(rect: CGRect(x: x - width / 2, y: y, width: width, height: 4),
                                   accent: accent, lineWidth: 1.5),
                ZoneIcon.neonShape(rect: CGRect(x: x - midWidth / 2, y: y + 4, width: midWidth, height: 5),
                                   accent: accent, lineWidth: 1.5),
                ZoneIcon.neonShape(rect: CGRect(x: x - topWidth / 2, y: y + 9, width: topWidth, height: 5),
                                   accent: accent, lineWidth: 1.5),
            ]
        case .mast:
            let height = CGFloat(random.value(in: 12 ... 20))
            return [
                ZoneIcon.neonShape(rect: CGRect(x: x - width / 2, y: y, width: width, height: 4),
                                   accent: accent, lineWidth: 1.5),
                ZoneIcon.neonShape(rect: CGRect(x: x - 1.5, y: y + 4, width: 3, height: height),
                                   accent: accent, lineWidth: 1.5),
            ]
        case .parapet:
            // The flat, unlit top: a rim and a lift-motor box off to one side.
            let boxWidth = width * CGFloat(random.value(in: 0.22 ... 0.34))
            let side: CGFloat = random.chance(0.5) ? -1 : 1
            return [
                ZoneIcon.neonShape(rect: CGRect(x: x - width / 2 - 2, y: y, width: width + 4, height: 4),
                                   accent: accent, lineWidth: 1.5),
                ZoneIcon.neonShape(
                    rect: CGRect(x: x + side * (width / 2 - boxWidth) - boxWidth / 2 + side * boxWidth / 2,
                                 y: y + 4, width: boxWidth, height: CGFloat(random.value(in: 6 ... 11))),
                    accent: accent, lineWidth: 1.5
                ),
            ]
        }
    }
}
