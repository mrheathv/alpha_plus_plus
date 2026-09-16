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

        if tier == 1, random.chance(0.5) {
            houseRow(accent: accent, seed: seed, outline: &outline, details: &details, random: &random)
        } else {
            block(tier: tier, accent: accent, seed: seed,
                  outline: &outline, details: &details, random: &random)
        }

        container.addChild(ZoneIcon.withGlow(outline, color: accent))
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
            // A slab line marking each storey break, so the steps read as
            // structure rather than as stacked boxes.
            details.append(ZoneIcon.detail(
                rect: CGRect(x: rect.minX, y: rect.maxY - 3, width: rect.width, height: 3),
                fill: ZoneIcon.recessedAccent
            ))

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

    /// Small separate windows, some lit and some dark. The irregular lighting
    /// is what makes a block read as many households rather than one occupant.
    private static func windowGrid(
        in rect: CGRect,
        salt: Int,
        random: inout BuildingRandom
    ) -> [SKNode] {
        let columns = max(2, Int((rect.width / 13).rounded(.down)))
        let rows = max(1, Int((rect.height / 14).rounded(.down)))
        guard columns > 0, rows > 0 else { return [] }

        let cellWidth = rect.width / CGFloat(columns)
        let cellHeight = rect.height / CGFloat(rows)
        let windowWidth = cellWidth * 0.52
        let windowHeight = min(cellHeight * 0.46, 8)

        var parts: [SKNode] = []
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let x = rect.minX + cellWidth * (CGFloat(column) + 0.5) - windowWidth / 2
                let y = rect.minY + cellHeight * (CGFloat(row) + 0.5) - windowHeight / 2
                let frame = CGRect(x: x, y: y, width: windowWidth, height: windowHeight)
                // Roughly a third of windows dark, so the facade has texture.
                if random.chance(0.66) {
                    parts.append(ZoneIcon.framedWindow(
                        rect: frame,
                        fill: ZoneIcon.windowColor(row: row, column: column, salt: salt)
                    ))
                } else {
                    parts.append(ZoneIcon.detail(rect: frame, fill: ZoneIcon.recessedAccent))
                }
            }
        }
        return parts
    }

    /// A projecting balcony line with railing ticks — a mark unique to housing
    /// in this game's vocabulary.
    private static func balconyBand(on rect: CGRect, random: inout BuildingRandom) -> [SKNode] {
        let y = rect.minY + rect.height * CGFloat(random.value(in: 0.3 ... 0.7))
        let overhang: CGFloat = 3
        var parts: [SKNode] = [ZoneIcon.detail(
            rect: CGRect(x: rect.minX - overhang, y: y, width: rect.width + overhang * 2, height: 2.5),
            fill: ZoneIcon.litAccent
        )]
        // Railing uprights.
        let posts = max(3, Int(rect.width / 9))
        for index in 0 ..< posts {
            let x = rect.minX - overhang + (rect.width + overhang * 2) * CGFloat(index) / CGFloat(posts - 1)
            parts.append(ZoneIcon.detail(
                rect: CGRect(x: x - 0.6, y: y, width: 1.2, height: 4),
                fill: ZoneIcon.recessedAccent
            ))
        }
        return parts
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
        let doorWidth = min(CGFloat(random.value(in: 9 ... 13)), width * 0.5)
        return [
            ZoneIcon.detail(
                rect: CGRect(x: x - doorWidth / 2, y: -40, width: doorWidth, height: 11),
                fill: ZoneIcon.recessedAccent
            ),
            ZoneIcon.detail(
                rect: CGRect(x: x - doorWidth / 2 + 1.5, y: -40, width: doorWidth - 3, height: 8),
                fill: ZoneIcon.litAccent
            ),
            // The glowing walkway up to the door, carried over from the
            // hand-drawn residential icons this generator replaces — it was
            // pulled from a reference sprite and is worth keeping. Kept short
            // and dim: the icons it came from were cropped by the tile, and
            // once `fitIconToTile` started centring the whole silhouette this
            // became a bright bar hanging off the bottom of every house.
            ZoneIcon.detail(
                rect: CGRect(x: x - 1.5, y: -45, width: 3, height: 5),
                fill: ZoneIcon.litAccent.withAlphaComponent(0.6)
            ),
        ]
    }
}
