import SpriteKit

/// Draws residential buildings parametrically, from a seed.
///
/// **The vocabulary, and why it is this one.** Housing has to read as
/// *dwellings* with the colour stripped away, against industry's wide low
/// works and commerce's glass. The marks that do that:
///
/// - **Stepped massing.** A block sits on a wider block sits on a wider block.
///   Real apartment towers set back as they rise, and a stepped silhouette is
///   instantly not a factory shed and not an office slab.
/// - **Punched windows in a grid.** Small, separate, regularly spaced, and
///   individually lit or dark — the opposite of commerce's continuous glazing
///   bands. A wall of separate little lights reads as many homes.
/// - **Balcony bands.** A horizontal line with a railing across a volume's
///   face. Nothing else in the game draws these.
/// - **Rooftop clutter** — water tanks, stair bulkheads — rather than
///   commerce's illuminated crowns.
///
/// **Density changes the building, not just its height.** Tier 1 is where
/// most of a city's map area sits, so it is the tier that can least afford to
/// be one drawing. Half of tier 1 is a *row of separate houses* rather than a
/// single block — narrow volumes side by side, each with its own roof. That
/// is what low density actually looks like, and it separates the bottom of the
/// ladder from the top by silhouette rather than by size alone.
///
/// See `IndustrialBuilding` for why growable zones are generated rather than
/// hand-drawn, and `BuildingRandom` for why a lot's look is stable.
enum ResidentialBuilding {

    static func make(tier: Int, accent: SKColor, seed: GridPosition) -> SKNode {
        var random = BuildingRandom(seed: seed, salt: 100 + tier)

        let container = SKNode()
        var outline: [SKShapeNode] = []
        var details: [SKNode] = []

        // Drawn before the form picks anything, so the same lot keeps the same
        // brightness whichever branch it takes. A district of identical-tier
        // lots should still have bright and quiet buildings in it.
        let liveliness = CGFloat(random.value(in: 0.72 ... 1.2))

        if tier == 1, random.chance(0.5) {
            houseRow(accent: accent, seed: seed, outline: &outline, details: &details, random: &random)
        } else {
            block(tier: tier, accent: accent, seed: seed,
                  outline: &outline, details: &details, random: &random)
        }

        container.addChild(ZoneIcon.withGlow(
            outline, color: accent,
            intensity: ZoneIcon.glowIntensity(forTier: tier, liveliness: liveliness)
        ))
        details.forEach(container.addChild)
        return container
    }

    // MARK: - Forms

    /// Two or three narrow houses side by side, each with its own roof and its
    /// own handful of windows. Low density drawn as low density.
    private static func houseRow(
        accent: SKColor,
        seed: GridPosition,
        outline: inout [SKShapeNode],
        details: inout [SKNode],
        random: inout BuildingRandom
    ) {
        let count = random.int(in: 2 ... 3)
        let span = CGFloat(random.value(in: 74 ... 86))
        let slot = span / CGFloat(count)
        let doorIndex = random.int(in: 0 ... (count - 1))

        for index in 0 ..< count {
            let width = slot * CGFloat(random.value(in: 0.74 ... 0.92))
            let height = CGFloat(random.value(in: 26 ... 40))
            let centre = -span / 2 + slot * (CGFloat(index) + 0.5)
            let rect = CGRect(x: centre - width / 2, y: -40, width: width, height: height)
            outline.append(ZoneIcon.neonShape(rect: rect, accent: accent))
            details.append(contentsOf: windowGrid(in: rect, salt: index, random: &random))

            // Each house gets its own cap, so a row never reads as one wall.
            if random.chance(0.6) {
                let pitch = CGFloat(random.value(in: 8 ... 13))
                outline.append(ZoneIcon.neonShape(
                    ZoneIcon.trapezoid(
                        bottomLeft: CGPoint(x: rect.minX - 3, y: rect.maxY),
                        bottomRight: CGPoint(x: rect.maxX + 3, y: rect.maxY),
                        topRight: CGPoint(x: centre + width / 5, y: rect.maxY + pitch),
                        topLeft: CGPoint(x: centre - width / 5, y: rect.maxY + pitch)
                    ),
                    accent: accent
                ))
            } else {
                outline.append(ZoneIcon.neonShape(
                    rect: CGRect(x: rect.minX - 2, y: rect.maxY, width: rect.width + 4, height: 4),
                    accent: accent, lineWidth: 1.5
                ))
                if random.chance(0.5) {
                    // A chimney, which is a house mark and nothing else's.
                    outline.append(ZoneIcon.neonShape(
                        rect: CGRect(x: centre + width / 4, y: rect.maxY + 4, width: 5,
                                     height: CGFloat(random.value(in: 6 ... 10))),
                        accent: accent, lineWidth: 1.5
                    ))
                }
            }

            if index == doorIndex {
                details.append(contentsOf: entrance(centredAt: centre, width: width * 0.9, random: &random))
            }
        }
    }

    /// One stacked, stepped-back block: the apartment building. Housing grows
    /// *upward* as it densifies, and narrows as it does — the opposite of
    /// industry, which spreads.
    private static func block(
        tier: Int,
        accent: SKColor,
        seed: GridPosition,
        outline: inout [SKShapeNode],
        details: inout [SKNode],
        random: inout BuildingRandom
    ) {
        let volumeCount = random.int(in: tier >= 3 ? 2 ... 3 : (tier == 2 ? 2 ... 3 : 1 ... 2))
        let totalHeight = CGFloat(random.value(in: tier >= 3 ? 82 ... 94 : (tier == 2 ? 62 ... 78 : 40 ... 54)))
        let baseWidth = CGFloat(random.value(in: tier >= 3 ? 48 ... 58 : (tier == 2 ? 54 ... 64 : 58 ... 68)))

        var y: CGFloat = -40
        var width = baseWidth
        for index in 0 ..< volumeCount {
            // Later volumes are shorter and narrower: the setback that gives
            // the silhouette its steps.
            let share = index == volumeCount - 1
                ? 1.0
                : CGFloat(random.value(in: 0.38 ... 0.56))
            let remaining = totalHeight - (y + 40)
            let height = max(14, remaining * share)

            let rect = CGRect(x: -width / 2, y: y, width: width, height: height)
            outline.append(ZoneIcon.neonShape(rect: rect, accent: accent))
            details.append(contentsOf: windowGrid(in: rect, salt: index, random: &random))

            if random.chance(index == 0 ? 0.45 : 0.7) {
                details.append(contentsOf: balconyBand(on: rect, random: &random))
            }
            // No storey line between volumes: three points of near-black on
            // near-black is invisible at every zoom and only muddies the
            // silhouette. The setback itself already reads as the break.

            y = rect.maxY
            width *= CGFloat(random.value(in: 0.72 ... 0.88))
        }

        outline.append(contentsOf: crown(atTop: y, width: width, tier: tier, accent: accent, random: &random))
        details.append(contentsOf: entrance(
            centredAt: CGFloat(random.value(in: -0.22 ... 0.22)) * baseWidth,
            width: baseWidth,
            random: &random
        ))
    }

    // MARK: - Parts

    /// Separate lit blocks, some on and some off. The irregular lighting is
    /// what makes a block read as many households rather than one occupant.
    ///
    /// **Few and big, not many and small.** This drew a 5×4 grid of 8-point
    /// panes with a frame around each. At the size a lot is actually played
    /// at that was a grey speckle: the panes were three screen points across,
    /// the frames ate most of what light was left, and the facade averaged out
    /// to a muddy texture that fought the neon instead of adding to it. The
    /// grid is now spaced on `ZoneIcon.minimumDetailSize`, the panes are flat
    /// unframed light, and there are perhaps a third as many. Fewer, larger,
    /// fully saturated windows survive every zoom the camera has.
    private static func windowGrid(
        in rect: CGRect,
        salt: Int,
        random: inout BuildingRandom
    ) -> [SKNode] {
        let spacing = ZoneIcon.minimumDetailSize * 2.2
        let columns = max(1, Int((rect.width / spacing).rounded(.down)))
        let rows = max(1, Int((rect.height / spacing).rounded(.down)))

        let cellWidth = rect.width / CGFloat(columns)
        let cellHeight = rect.height / CGFloat(rows)
        let windowWidth = max(ZoneIcon.minimumDetailSize, cellWidth * 0.56)
        let windowHeight = max(ZoneIcon.minimumDetailSize, min(cellHeight * 0.52, 13))
        guard windowWidth < rect.width, windowHeight < rect.height else { return [] }

        // One window is always lit. With few enough cells — a narrow house in
        // a row gets a single column — an independent per-window roll can
        // turn every one of them off, and a house with no light in it is not
        // reading as low-density, it is reading as a bug.
        let litIndex = random.int(in: 0 ... (rows * columns - 1))

        var parts: [SKNode] = []
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let x = rect.minX + cellWidth * (CGFloat(column) + 0.5) - windowWidth / 2
                let y = rect.minY + cellHeight * (CGFloat(row) + 0.5) - windowHeight / 2
                let frame = CGRect(x: x, y: y, width: windowWidth, height: windowHeight)
                // Roughly a quarter dark, so the facade still has texture.
                guard row * columns + column == litIndex || random.chance(0.74) else { continue }
                parts.append(ZoneIcon.detail(
                    rect: frame,
                    fill: ZoneIcon.windowColor(row: row, column: column, salt: salt)
                ))
            }
        }
        return parts
    }

    /// A projecting balcony line — a mark unique to housing in this game's
    /// vocabulary, and one that reads at any size because it is a single long
    /// bright horizontal rather than a row of small things.
    ///
    /// It used to carry railing uprights at 1.2 points wide. Those are a
    /// quarter of a screen point at rest and simply never rendered as
    /// anything; all they did was chew the bright band into a dashed grey
    /// line. The band is thicker now instead.
    private static func balconyBand(on rect: CGRect, random: inout BuildingRandom) -> [SKNode] {
        let y = rect.minY + rect.height * CGFloat(random.value(in: 0.3 ... 0.7))
        let overhang: CGFloat = 4
        return [ZoneIcon.detail(
            rect: CGRect(x: rect.minX - overhang, y: y, width: rect.width + overhang * 2, height: 5),
            fill: ZoneIcon.litAccent
        )]
    }

    /// Rooftop clutter rather than an illuminated crown: tanks, bulkheads,
    /// and at low tiers a pitched cap. This is the other end of the
    /// residential/commercial split — offices light their tops, housing puts
    /// machinery up there.
    private static func crown(
        atTop y: CGFloat,
        width: CGFloat,
        tier: Int,
        accent: SKColor,
        random: inout BuildingRandom
    ) -> [SKShapeNode] {
        enum Style: CaseIterable { case tank, bulkhead, pitched, parapet }
        let style: Style = tier == 1
            ? random.pick([.pitched, .parapet, .tank])
            : random.pick(Style.allCases)

        switch style {
        case .tank:
            // A rooftop water tank on short legs.
            let tankWidth = width * CGFloat(random.value(in: 0.3 ... 0.44))
            let tankHeight = CGFloat(random.value(in: 10 ... 15))
            let x = CGFloat(random.value(in: -0.2 ... 0.2)) * width
            return [
                ZoneIcon.neonShape(
                    rect: CGRect(x: x - tankWidth / 2, y: y + 5, width: tankWidth, height: tankHeight),
                    accent: accent, lineWidth: 1.5
                ),
                ZoneIcon.neonShape(
                    rect: CGRect(x: x - 1.5, y: y, width: 3, height: 6),
                    accent: accent, lineWidth: 1
                ),
            ]
        case .bulkhead:
            // A stair head — a small box offset to one side.
            let boxWidth = width * CGFloat(random.value(in: 0.24 ... 0.36))
            let side: CGFloat = random.chance(0.5) ? -1 : 1
            return [ZoneIcon.neonShape(
                rect: CGRect(x: side * (width / 2 - boxWidth) - boxWidth / 2 + side * boxWidth / 2,
                             y: y, width: boxWidth, height: CGFloat(random.value(in: 8 ... 13))),
                accent: accent, lineWidth: 1.5
            )]
        case .pitched:
            let height = CGFloat(random.value(in: 10 ... 16))
            return [ZoneIcon.neonShape(
                ZoneIcon.trapezoid(
                    bottomLeft: CGPoint(x: -width / 2 - 3, y: y),
                    bottomRight: CGPoint(x: width / 2 + 3, y: y),
                    topRight: CGPoint(x: width / 4, y: y + height),
                    topLeft: CGPoint(x: -width / 4, y: y + height)
                ),
                accent: accent
            )]
        case .parapet:
            return [ZoneIcon.neonShape(
                rect: CGRect(x: -width / 2 - 2, y: y, width: width + 4, height: 4),
                accent: accent, lineWidth: 1.5
            )]
        }
    }

    /// A lit doorway and a small stoop at street level — the human-scale
    /// detail that says people live here.
    private static func entrance(
        centredAt x: CGFloat,
        width: CGFloat,
        random: inout BuildingRandom
    ) -> [SKNode] {
        // One lit block, not a lit block inside a dark surround inside a
        // walkway. The surround was 1.5 points of trim and the walkway 3
        // points wide — both below `ZoneIcon.minimumDetailSize`, so all three
        // marks resolved to a single smudge anyway. This is that smudge,
        // drawn deliberately and at a size that reads.
        let doorWidth = max(ZoneIcon.minimumDetailSize, min(CGFloat(random.value(in: 11 ... 15)), width * 0.5))
        return [ZoneIcon.detail(
            rect: CGRect(x: x - doorWidth / 2, y: -40, width: doorWidth, height: 14),
            fill: ZoneIcon.litAccent
        )]
    }
}
