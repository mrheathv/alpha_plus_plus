import SpriteKit

/// Draws industrial buildings parametrically, from a seed.
///
/// **Why a generator instead of more hand-written functions.** `ZoneIcon` drew
/// two fixed looks per tier, picked by a hash. Reaching the ten-plus looks per
/// zone per tier that CLAUDE.md now targets would mean ninety hand-written
/// shape functions — unmaintainable, and the wrong shape of solution. This
/// composes a building from parts instead: a hall, a roof, stacks, tanks,
/// vents. The number of distinct results is the product of those choices
/// rather than the number of functions anyone typed.
///
/// **Why industrial went first.** The contact sheet made it obvious that all
/// three growable zones drew the *same silhouette* — a tall rectangle with a
/// window grid — and differed only in hue. Strip the colour and you cannot
/// tell a factory from a tower block. Industry has the most distinctive real
/// vocabulary to borrow from, so it is where the difference shows soonest:
/// sawtooth rooflines, chimneys, storage tanks, and a footprint that spreads
/// *wide and low* while housing and offices go up.
enum IndustrialBuilding {

    /// A building for `tier` (1...3), drawn deterministically from `seed`.
    static func make(tier: Int, accent: SKColor, seed: GridPosition) -> SKNode {
        var random = BuildingRandom(seed: seed, salt: tier)

        let container = SKNode()
        var outline: [SKShapeNode] = []
        var details: [SKNode] = []

        // Wide and low, and more so at higher tiers — the opposite of how the
        // residential and commercial ladders grow. A tier-3 factory should
        // read as a *works*, sprawling across its lot, not as a taller shed.
        let hallHeight = random.value(in: tier >= 3 ? 34 ... 44 : (tier == 2 ? 28 ... 38 : 24 ... 32))

        // Whether there are tanks is decided *before* the hall is sized,
        // because they sit beside it and count toward the building's overall
        // width. Sizing the hall first and bolting tanks on afterwards pushed
        // the silhouette past `ZoneIcon.designSize`, and since
        // `TileRenderer.fitIconToTile` scales by the *measured* frame, the
        // whole works shrank to fit and the tanks ended up jammed against the
        // lot edge. Narrowing the hall to make room keeps the building the
        // same size on screen whether or not it has them.
        let hasTanks = tier >= 2 && random.chance(tier >= 3 ? 0.85 : 0.45)
        let widthRange: ClosedRange<Double> = hasTanks
            ? (tier >= 2 ? 56 ... 66 : 50 ... 58)
            : (tier >= 2 ? 74 ... 86 : 64 ... 76)
        let hallWidth = random.value(in: widthRange)
        let hall = CGRect(x: -hallWidth / 2, y: -40, width: hallWidth, height: hallHeight)
        outline.append(ZoneIcon.neonShape(rect: hall, accent: accent))

        outline.append(contentsOf: roof(on: hall, tier: tier, accent: accent, random: &random))
        details.append(contentsOf: facade(on: hall, tier: tier, random: &random))

        // Stacks: the single most recognisable industrial mark. Always at
        // least one, so even a tier-1 shed says "factory" at a glance.
        let stackCount = random.int(in: tier >= 3 ? 2 ... 3 : (tier == 2 ? 1 ... 2 : 1 ... 1))
        for index in 0 ..< stackCount {
            let spread = hallWidth * 0.34
            let x = stackCount == 1
                ? random.value(in: Double(-spread) ... Double(spread))
                : -spread + (2 * spread) * Double(index) / Double(stackCount - 1)
            outline.append(contentsOf: stack(x: CGFloat(x), topOf: hall, tier: tier, accent: accent, random: &random))
        }

        // Storage tanks sit beside the hall rather than on it, which is what
        // gives a works its sprawling, non-rectangular outline.
        if hasTanks {
            let side: CGFloat = random.chance(0.5) ? -1 : 1
            outline.append(contentsOf: tank(
                at: CGPoint(x: side * (CGFloat(hallWidth) / 2 + 11), y: -40 + CGFloat(hallHeight) * 0.3),
                accent: accent,
                random: &random
            ))
        }

        container.addChild(ZoneIcon.withGlow(outline, color: accent))
        details.forEach(container.addChild)

        // The hazard triangle the tier's own name ("Pollution Warning") has
        // promised since the palette pass.
        if tier >= 3 {
            container.addChild(warningTriangle(at: CGPoint(x: hallWidth / 2 - 12, y: -28)))
        }
        container.addChild(ZoneIcon.neonSignboard(
            rect: CGRect(x: -hallWidth / 2 + 6, y: -36, width: 18, height: 6),
            color: ZoneIcon.signColor(for: seed)
        ))
        return container
    }

    // MARK: - Parts

    /// The roofline, and the part that does most of the work of saying
    /// "industrial" — a sawtooth is a shape no other zone in the game draws.
    private static func roof(
        on hall: CGRect,
        tier: Int,
        accent: SKColor,
        random: inout BuildingRandom
    ) -> [SKShapeNode] {
        enum Style: CaseIterable { case sawtooth, monitor, flat }
        let style: Style = tier == 1
            ? random.pick([.sawtooth, .flat])
            : random.pick(Style.allCases)

        let top = hall.maxY
        switch style {
        case .sawtooth:
            // The classic north-light factory roof: a row of right triangles.
            let teeth = random.int(in: 3 ... 5)
            let toothWidth = hall.width / CGFloat(teeth)
            let toothHeight = CGFloat(random.value(in: 8 ... 13))
            return (0 ..< teeth).map { index in
                let x = hall.minX + CGFloat(index) * toothWidth
                let path = CGMutablePath()
                path.move(to: CGPoint(x: x, y: top))
                path.addLine(to: CGPoint(x: x + toothWidth, y: top))
                path.addLine(to: CGPoint(x: x + toothWidth, y: top + toothHeight))
                path.closeSubpath()
                return ZoneIcon.neonShape(path, accent: accent, lineWidth: 1.5)
            }
        case .monitor:
            // A raised clerestory running along the ridge.
            let inset = hall.width * CGFloat(random.value(in: 0.18 ... 0.3))
            let height = CGFloat(random.value(in: 9 ... 14))
            return [ZoneIcon.neonShape(
                rect: CGRect(x: hall.minX + inset, y: top, width: hall.width - inset * 2, height: height),
                accent: accent,
                lineWidth: 1.5
            )]
        case .flat:
            // A plain parapet — the quiet option, so not every factory shouts.
            return [ZoneIcon.neonShape(
                rect: CGRect(x: hall.minX, y: top, width: hall.width, height: 4),
                accent: accent,
                lineWidth: 1.5
            )]
        }
    }

    /// Windows and louvres along the hall face. Industrial windows are wide
    /// bands rather than the tidy grids housing and offices use.
    private static func facade(on hall: CGRect, tier: Int, random: inout BuildingRandom) -> [SKNode] {
        var parts: [SKNode] = []
        parts.append(ZoneIcon.detail(
            rect: CGRect(x: hall.minX, y: hall.minY + hall.height * 0.55, width: hall.width, height: 3),
            fill: ZoneIcon.recessedAccent
        ))

        let bays = random.int(in: 3 ... 5)
        let bayWidth = hall.width / CGFloat(bays)
        let lit = random.int(in: 1 ... max(1, bays - 1))
        for index in 0 ..< bays {
            let x = hall.minX + CGFloat(index) * bayWidth + bayWidth * 0.18
            let width = bayWidth * 0.64
            let rect = CGRect(x: x, y: hall.minY + hall.height * 0.18, width: width, height: hall.height * 0.3)
            if index < lit {
                parts.append(ZoneIcon.framedWindow(rect: rect))
            } else {
                parts.append(ZoneIcon.detail(rect: rect, fill: ZoneIcon.recessedAccent))
            }
        }
        if tier >= 2, random.chance(0.6) {
            // A loading bay cut into the base.
            let width = hall.width * CGFloat(random.value(in: 0.16 ... 0.24))
            parts.append(ZoneIcon.detail(
                rect: CGRect(x: -width / 2, y: hall.minY, width: width, height: hall.height * 0.3),
                fill: ZoneIcon.recessedAccent
            ))
        }
        return parts
    }

    private static func stack(
        x: CGFloat,
        topOf hall: CGRect,
        tier: Int,
        accent: SKColor,
        random: inout BuildingRandom
    ) -> [SKShapeNode] {
        let width = CGFloat(random.value(in: 7 ... 11))
        let height = CGFloat(random.value(in: tier >= 3 ? 30 ... 44 : (tier == 2 ? 22 ... 34 : 16 ... 26)))
        let base = hall.maxY - 2
        var shapes = [ZoneIcon.neonShape(
            rect: CGRect(x: x - width / 2, y: base, width: width, height: height),
            accent: accent,
            lineWidth: 2
        )]
        // A cap band, so a stack doesn't read as a plain bar.
        shapes.append(ZoneIcon.neonShape(
            rect: CGRect(x: x - width / 2 - 2, y: base + height - 4, width: width + 4, height: 4),
            accent: accent,
            lineWidth: 1.5
        ))
        return shapes
    }

    private static func tank(
        at centre: CGPoint,
        accent: SKColor,
        random: inout BuildingRandom
    ) -> [SKShapeNode] {
        let radius = CGFloat(random.value(in: 9 ... 13))
        let body = SKShapeNode(circleOfRadius: radius)
        body.position = centre
        body.fillColor = ZoneIcon.silhouetteFill
        body.strokeColor = accent
        body.lineWidth = 2
        // A banding line across the tank, the detail that stops it reading as
        // a bare circle.
        let band = SKShapeNode(rect: CGRect(
            x: centre.x - radius, y: centre.y - 1.5, width: radius * 2, height: 3
        ))
        band.fillColor = accent
        band.strokeColor = .clear
        band.alpha = 0.55
        return [body, band]
    }

    /// The hazard triangle, in `emberColor` — carried over from the
    /// hand-drawn tier-3 icons this generator replaces.
    private static func warningTriangle(at centre: CGPoint) -> SKNode {
        let size: CGFloat = 16
        let path = CGMutablePath()
        path.move(to: CGPoint(x: centre.x, y: centre.y + size / 2))
        path.addLine(to: CGPoint(x: centre.x - size / 2, y: centre.y - size / 2))
        path.addLine(to: CGPoint(x: centre.x + size / 2, y: centre.y - size / 2))
        path.closeSubpath()

        let triangle = SKShapeNode(path: path)
        triangle.fillColor = ZoneIcon.silhouetteFill
        triangle.strokeColor = ZoneIcon.emberColor
        triangle.lineWidth = 2
        triangle.glowWidth = 1.5

        let container = SKNode()
        container.addChild(triangle)
        container.addChild(ZoneIcon.detail(
            rect: CGRect(x: centre.x - 1, y: centre.y - 3, width: 2, height: 6),
            fill: ZoneIcon.emberColor
        ))
        return container
    }
}
