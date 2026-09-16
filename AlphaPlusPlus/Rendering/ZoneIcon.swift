import SpriteKit
import CoreImage

/// Procedural silhouettes drawn on top of a building's base color — still
/// graybox (no image assets), now in a retrowave treatment: a dark
/// silhouette fill with a neon outline in the zone's own hue, and a soft
/// glow bleeding out from that outline (the same blurred-duplicate trick
/// that used to draw a drop shadow, just a bright color with no offset
/// instead of a dark one with one). No shader, no gradient — a build cut
/// from the night with its own color leaking out of the seams.
///
/// Every icon takes the zone's own `accent` color (`RenderPalette.fullColor(for:)`,
/// read once in `makeNode` and threaded through) rather than a fixed
/// palette — the same shape silhouette works for any zone; the glow color
/// is what actually identifies it, matching how the tile underneath it is
/// already colored.
///
/// Distinct geometry per *growth tier* for the three zones that grow: a
/// residential lot looks different at density 2 than at density 5, not
/// just brighter/more glowing. Every tier of every zone — growable or
/// not — has two silhouettes to choose between, picked the same way:
/// `variant(for:optionCount:)`, keyed off the building's own anchor
/// position, so two lots at the same tier don't look identical but the
/// same lot never flickers between looks tick to tick.
///
/// Every shape is still built only from straight lines, rectangles, and
/// circles/ellipses — no hand-tuned bezier curves — simple enough to get
/// right from coordinates alone, with nothing to preview.
///
/// Each icon is authored in a fixed design space, `designSize` points on a
/// side, centered on `(0, 0)`. `TileRenderer` scales the returned node to
/// whatever the actual sprite needs.
/// The shared drawing vocabulary — `neonShape`, `detail`, `withGlow` and
/// friends — is `internal` rather than `private` so that parametric building
/// generators can live in their own files while drawing in exactly the same
/// idiom. `IndustrialBuilding` is the first of those; residential and
/// commercial follow. Keeping one vocabulary is what stops the zones drifting
/// into looking like three different games.
enum ZoneIcon {

    /// The width/height of the square each icon is designed to fit inside.
    static let designSize: CGFloat = 100

    /// `nil` for zones that don't get an icon: `.empty` (nothing to draw)
    /// and `.road`/`.highway` (a flat, glowing fill already reads as an
    /// uninterrupted stretch of network — see `RenderPalette.fullColor(for:)`
    /// and `GameScene`'s network glow) — and for a growable zone at
    /// density 0 (just zoned, nothing built yet; the icon appearing at
    /// all is itself part of the signal that something now stands here).
    /// A pipe isn't a `ZoneType` at all any more (see `Tile.hasPipe`), so
    /// this function never even sees one.
    ///
    /// `seed` — a building's anchor position — picks which *variant* a tier
    /// with more than one draws (currently tier 1 of the three growable
    /// zones, via `variant(for:optionCount:)`). Every other tier still
    /// draws exactly one look; adding a second variant there is the same
    /// pattern, just another `variant(for:)` call and another function.
    static func makeNode(for zone: ZoneType, density: Int, seed: GridPosition) -> SKNode? {
        switch zone {
        case .empty, .road, .highway:
            return nil
        case .residential:
            // Generated — see `ResidentialBuilding` for the vocabulary
            // (stepped massing, punched window grids, balcony bands, rooftop
            // tanks) and why it is deliberately nothing like the other two.
            let tier = RenderPalette.growthTier(for: density)
            guard tier > 0 else { return nil }
            return ResidentialBuilding.make(
                tier: tier,
                accent: RenderPalette.tierColor(for: zone, tier: tier),
                seed: seed
            )
        case .commercial:
            // Generated — see `CommercialBuilding`. Continuous glazing bands
            // and a lit shopfront, against residential's grid of separate
            // little windows: the difference that survives greyscale.
            let tier = RenderPalette.growthTier(for: density)
            guard tier > 0 else { return nil }
            return CommercialBuilding.make(
                tier: tier,
                accent: RenderPalette.tierColor(for: zone, tier: tier),
                seed: seed
            )
        case .industrial:
            // Generated rather than chosen from a fixed pair — see
            // `IndustrialBuilding` for why, and for why industry was the zone
            // to start with. Every seed produces a different works.
            let tier = RenderPalette.growthTier(for: density)
            guard tier > 0 else { return nil }
            return IndustrialBuilding.make(
                tier: tier,
                accent: RenderPalette.tierColor(for: zone, tier: tier),
                seed: seed
            )
        case .policeStation:
            let accent = RenderPalette.fullColor(for: zone)
            return variant(for: seed, optionCount: 2) == 0 ? precinctTowerIcon(accent: accent, seed: seed) : patrolCarIcon(accent: accent)
        case .fireStation:
            let accent = RenderPalette.fullColor(for: zone)
            return variant(for: seed, optionCount: 2) == 0 ? fireHouseTowerIcon(accent: accent, seed: seed) : twinBayFirehouseIcon(accent: accent, seed: seed)
        case .publicTransit:
            let accent = RenderPalette.fullColor(for: zone)
            return variant(for: seed, optionCount: 2) == 0 ? transitIcon(accent: accent, seed: seed) : tramIcon(accent: accent, seed: seed)
        case .powerPlant:
            let accent = RenderPalette.fullColor(for: zone)
            return variant(for: seed, optionCount: 2) == 0 ? powerPlantIcon(accent: accent, seed: seed) : singleTowerPlantIcon(accent: accent, seed: seed)
        case .stadium:
            let accent = RenderPalette.fullColor(for: zone)
            return variant(for: seed, optionCount: 2) == 0 ? stadiumIcon(accent: accent, seed: seed) : arenaIcon(accent: accent, seed: seed)
        case .subway:
            let accent = RenderPalette.fullColor(for: zone)
            return variant(for: seed, optionCount: 2) == 0 ? subwayIcon(accent: accent, seed: seed) : subwayStairsIcon(accent: accent, seed: seed)
        case .waterTower:
            let accent = RenderPalette.fullColor(for: zone)
            return variant(for: seed, optionCount: 2) == 0 ? waterTowerIcon(accent: accent, seed: seed) : standpipeTowerIcon(accent: accent, seed: seed)
        case .school:
            return schoolIcon(accent: RenderPalette.fullColor(for: zone), seed: seed)
        case .hospital:
            return hospitalIcon(accent: RenderPalette.fullColor(for: zone), seed: seed)
        case .waterPump:
            return waterPumpIcon(accent: RenderPalette.fullColor(for: zone), seed: seed)
        case .generator:
            return generatorIcon(accent: RenderPalette.fullColor(for: zone), seed: seed)
        }
    }

    /// Which of `optionCount` visual variants a building at `seed` (its
    /// anchor position) should draw — deterministic and stable across
    /// ticks and app launches, unlike `GridPosition`'s own `Hashable`
    /// conformance, which Swift deliberately randomizes per process launch
    /// (fine for dictionary buckets, wrong for "this exact lot always
    /// looks the same"). A simple mix of `x`/`y`, not a real hash function
    /// — this only ever needs to pick between 2-3 options, not distribute
    /// uniformly across a huge space.
    private static func variant(for seed: GridPosition, optionCount: Int) -> Int {
        abs(seed.x &* 31 &+ seed.y) % optionCount
    }

    // MARK: - Shared palette

    /// Every building silhouette's fill — near-black, so a building reads
    /// as a shape cut out of the night, lit only by its own neon outline.
    /// Consistent across every zone: the *glow color*, not a different
    /// material fill, is what identifies a house from a shop now.
    static let silhouetteFill = SKColor(srgbRed: 0.05, green: 0.03, blue: 0.09, alpha: 1.0)

    /// Windows, sign faces, stadium floodlights, and (for Residential
    /// specifically) the glowing walkway a reference isometric sprite
    /// showed leading up to a building's front door — anything meant to
    /// read as lit up at night. The one element deliberately *not*
    /// colored by the zone's own accent: every one of these glows the
    /// same cool cyan-white regardless of what color building it's
    /// punched into, so a lit window (or a lit path) reads as its own
    /// kind of light, not just a paler version of the building's neon.
    static let litAccent = SKColor(srgbRed: 0.55, green: 0.98, blue: 1.0, alpha: 0.95)

    /// A small mix of window-light colors — `litAccent`'s original cool
    /// cyan, plus a warm incandescent and a dimmer cool white — spread
    /// across one facade's many cells (`facadeGrid` below) instead of
    /// repeating `litAccent` identically in every one. A real skyline is
    /// never one color of window: different tenants, different bulbs,
    /// different hours. Deliberately scoped to *dense grids* only — a
    /// building's one or two *featured* windows (`mullionedWindow`, a
    /// shop's display window) stay pure `litAccent`, so a single accent
    /// window still reads as this file's one consistent "lit window"
    /// color the way `litAccent`'s own doc comment intends; the mixed
    /// palette is additional texture for "many independent units of
    /// light," not a replacement for that rule.
    static let windowPalette: [SKColor] = [
        litAccent,
        SKColor(srgbRed: 1.0, green: 0.92, blue: 0.70, alpha: 0.95),  // warm incandescent
        SKColor(srgbRed: 0.80, green: 0.92, blue: 1.0, alpha: 0.85),  // dimmer cool white
    ]

    /// Which `windowPalette` color one cell of a `facadeGrid` should be —
    /// a fixed formula on the cell's own row/column (plus `salt`, so two
    /// grids on the same building don't repeat the same pattern), not
    /// real randomness, the same "deterministic, not random" reasoning
    /// `signColor(for:salt:)` documents.
    static func windowColor(row: Int, column: Int, salt: Int = 0) -> SKColor {
        windowPalette[abs(row * 11 + column * 7 + salt) % windowPalette.count]
    }

    /// Doors, wheels, smokestacks, rail ties — anything that should read
    /// as the darkest, most recessed part of a shape, darker even than
    /// `silhouetteFill` itself.
    static let recessedAccent = SKColor.black.withAlphaComponent(0.75)

    /// Warm orange, used only for fire's inner flame, the power plant's
    /// hazard stripe, and a diner's sign face — a fixed "attention" color
    /// rather than a zone accent, the same way it worked before this pass
    /// (a neon diner sign glowing orange/red is its own classic look, not
    /// a departure from one).
    static let emberColor = SKColor(srgbRed: 1.0, green: 0.45, blue: 0.15, alpha: 0.95)

    /// The mixed-neon-signage look a dense night skyline reference photo
    /// showed — hanging plaques and marquees in a handful of different hot
    /// colors, not one fixed hue the way every window already reads.
    /// `signColor(for:salt:)` below picks one per plaque, deterministically,
    /// the same "no real randomness" reasoning `variant(for:)` documents.
    static let signPalette: [SKColor] = [
        SKColor(srgbRed: 0.0, green: 0.95, blue: 1.0, alpha: 0.95),   // electric cyan
        SKColor(srgbRed: 1.0, green: 0.15, blue: 0.55, alpha: 0.95),  // hot magenta
        SKColor(srgbRed: 1.0, green: 0.75, blue: 0.20, alpha: 0.95),  // amber
    ]

    /// Which `signPalette` color a given signboard should glow — mixed
    /// deterministically off the building's own anchor position the same
    /// way `variant(for:)` mixes `x`/`y`, plus a `salt` so a building with
    /// more than one sign doesn't just repeat the same color on each of
    /// them.
    static func signColor(for seed: GridPosition, salt: Int = 0) -> SKColor {
        signPalette[abs(seed.x &* 17 &+ seed.y &* 13 &+ salt) % signPalette.count]
    }

    /// A small glowing plaque — a projecting shop sign, a rooftop logo
    /// board, a marquee readout — filled and stroked in its own
    /// `signPalette` color rather than `litAccent`'s fixed cyan or the
    /// building's own `accent`, so it reads as an independent light
    /// source bolted onto the facade, the way real neon signage does.
    static func neonSignboard(rect: CGRect, color: SKColor) -> SKNode {
        let plaque = SKShapeNode(rect: rect)
        plaque.fillColor = color
        plaque.strokeColor = color
        plaque.lineWidth = 1
        return withGlow([plaque], color: color, blurRadius: 4)
    }

    /// A shape filled `silhouetteFill` (or `fill`, for the rare shape that
    /// isn't a primary body) with a crisp stroke in the zone's own
    /// `accent` — the "outline," as opposed to `withGlow`'s soft-edged
    /// duplicate behind it. Every primary body/roof/stack shape in this
    /// file is a `neonShape`; only small non-primary details (a door, a
    /// window) skip straight to `detail(rect:fill:)` with no stroke at all.
    static func neonShape(_ path: CGPath, accent: SKColor, fill: SKColor = silhouetteFill, lineWidth: CGFloat = 2.5) -> SKShapeNode {
        let node = SKShapeNode(path: path)
        node.fillColor = fill
        node.strokeColor = accent
        node.lineWidth = lineWidth
        return node
    }

    static func neonShape(rect: CGRect, accent: SKColor, fill: SKColor = silhouetteFill, lineWidth: CGFloat = 2.5) -> SKShapeNode {
        neonShape(CGPath(rect: rect, transform: nil), accent: accent, fill: fill, lineWidth: lineWidth)
    }

    /// A rect with no outline — used for window/accent details layered on
    /// top of a body shape that already has its own neon stroke, so
    /// details don't each grow a second competing outline.
    static func detail(rect: CGRect, fill: SKColor) -> SKShapeNode {
        let node = SKShapeNode(rect: rect)
        node.fillColor = fill
        node.strokeColor = .clear
        return node
    }

    static func dot(radius: CGFloat, at point: CGPoint, fill: SKColor, stroke: SKColor = recessedAccent) -> SKShapeNode {
        let node = SKShapeNode(circleOfRadius: radius)
        node.position = point
        node.fillColor = fill
        node.strokeColor = stroke
        node.lineWidth = 1.5
        return node
    }

    /// A window with an actual frame — `detail(rect:fill:)`'s flat lit
    /// square, plus a thin `recessedAccent` border, so a pane reads as
    /// glass sitting in a wall rather than a sticker with no edge. The
    /// default for every *grid* of windows (an office/tower/apartment
    /// facade): several of these read cleanly at the small size a grid
    /// cell actually gets, where `mullionedWindow`'s extra cross-lines
    /// would start to look like noise instead of glazing bars.
    static func framedWindow(rect: CGRect, fill: SKColor = litAccent, frame: SKColor = recessedAccent) -> SKShapeNode {
        let node = SKShapeNode(rect: rect)
        node.fillColor = fill
        node.strokeColor = frame
        node.lineWidth = 1
        return node
    }

    /// A window with a crossed mullion — `framedWindow`'s frame, plus one
    /// vertical and one horizontal glazing bar splitting it into four
    /// panes. Reserved for a building's one or two *featured* windows (a
    /// house's front window, a shop's display window) where there's room
    /// for the extra line work to read as real carpentry rather than
    /// clutter — the specific detail this file's houses were missing that
    /// made a window read as a flat colored square instead of glass.
    private static func mullionedWindow(rect: CGRect, fill: SKColor = litAccent, frame: SKColor = recessedAccent) -> SKNode {
        let container = SKNode()
        container.addChild(framedWindow(rect: rect, fill: fill, frame: frame))
        let cross = CGMutablePath()
        cross.move(to: CGPoint(x: rect.midX, y: rect.minY))
        cross.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        cross.move(to: CGPoint(x: rect.minX, y: rect.midY))
        cross.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        let muntin = SKShapeNode(path: cross)
        muntin.strokeColor = frame
        muntin.lineWidth = 1.2
        container.addChild(muntin)
        return container
    }

    /// A thin, darker strip along a body's own bottom edge — the ground
    /// meeting the wall, grounding a silhouette that would otherwise seem
    /// to float free of its own tile.
    static func foundation(under bodyRect: CGRect, height: CGFloat = 3) -> SKShapeNode {
        detail(rect: CGRect(x: bodyRect.minX, y: bodyRect.minY, width: bodyRect.width, height: height), fill: recessedAccent)
    }

    /// A window strip divided into even panes by vertical mullion lines —
    /// a vehicle's windshield/side-window band, so it reads as individual
    /// panes of glass along the body rather than one flat lit rectangle.
    private static func panedBand(rect: CGRect, paneCount: Int, fill: SKColor = litAccent, frame: SKColor = recessedAccent) -> SKNode {
        let container = SKNode()
        container.addChild(framedWindow(rect: rect, fill: fill, frame: frame))
        let dividers = CGMutablePath()
        let step = rect.width / CGFloat(paneCount)
        for index in 1 ..< paneCount {
            let x = rect.minX + step * CGFloat(index)
            dividers.move(to: CGPoint(x: x, y: rect.minY))
            dividers.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        let lines = SKShapeNode(path: dividers)
        lines.strokeColor = frame
        lines.lineWidth = 1
        container.addChild(lines)
        return container
    }

    /// A dense grid of small windows covering most of a facade — most lit,
    /// a fixed fraction left dark for texture — the checkerboard-glow look
    /// of a real nighttime skyscraper, instead of a handful of sparse
    /// windows. `rows`/`columns` count cells; `cell` is each window's
    /// size; `spacing` is the gap between cells; `origin` is the
    /// bottom-left corner of the whole grid. Which cells are dark, and
    /// which `windowPalette` color a lit one gets, are both fixed
    /// formulas on the cell's own row/column, not real randomness — this
    /// file's other "pick 1 of 2" variety already comes from
    /// `variant(for:)`, so a second source of randomness here would just
    /// make every tower of the same variant look different for no reason.
    ///
    /// Every few rows reads as one wide lit strip — a floor of continuous
    /// glass, or a sign band — spanning the whole grid's width, instead of
    /// individual cells: the "mixed window texture" a real dense skyline
    /// (and the app icon's own skyline) actually has, rather than one
    /// uniform grid of identical squares repeated top to bottom.
    private static func facadeGrid(rows: Int, columns: Int, cell: CGSize, spacing: CGSize, origin: CGPoint) -> SKNode {
        let container = SKNode()
        let totalWidth = CGFloat(columns) * cell.width + CGFloat(max(columns - 1, 0)) * spacing.width
        for row in 0 ..< rows {
            let y = origin.y + CGFloat(row) * (cell.height + spacing.height)
            let isStripRow = columns > 1 && row % 4 == 3 && (row * 7) % 5 < 3
            if isStripRow {
                let lit = (row * 3) % 7 < 6
                let fill = lit ? windowColor(row: row, column: 0) : silhouetteFill
                container.addChild(framedWindow(rect: CGRect(x: origin.x, y: y, width: totalWidth, height: cell.height), fill: fill))
                continue
            }
            for column in 0 ..< columns {
                let lit = (row * 3 + column * 5) % 7 < 5
                let x = origin.x + CGFloat(column) * (cell.width + spacing.width)
                let fill = lit ? windowColor(row: row, column: column) : silhouetteFill
                container.addChild(framedWindow(rect: CGRect(x: x, y: y, width: cell.width, height: cell.height), fill: fill))
            }
        }
        return container
    }

    /// A four-point polygon — used for the power plant's and water
    /// tower's silhouettes (narrower at one end than the other), built
    /// from lines only.
    static func trapezoid(bottomLeft: CGPoint, bottomRight: CGPoint, topRight: CGPoint, topLeft: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: bottomLeft)
        path.addLine(to: bottomRight)
        path.addLine(to: topRight)
        path.addLine(to: topLeft)
        path.closeSubpath()
        return path
    }

    // MARK: - The neon glow

    /// Duplicates `shapes` in solid `color`, blurs the duplicates, and
    /// places them directly behind the originals (no offset — a glow
    /// emanates evenly, unlike a shadow cast to one side). The sharp dark
    /// original drawn on top hides the blur's solid center, leaving only
    /// its soft-edged overflow visible as a halo bleeding outward from the
    /// silhouette's outline — the whole "neon sign" effect from one blur
    /// pass, the exact technique this file used for drop shadows before
    /// this pass, just a bright color and zero offset instead of a dark
    /// one offset down-and-right.
    ///
    /// `shouldRasterize = true` caches the blurred result as a texture the
    /// first time it renders rather than re-running the blur every frame —
    /// a city map can have hundreds of these icons on screen at once, and
    /// an unrasterized Core Image blur on all of them simultaneously would
    /// be a real frame-rate risk. Only *primary* silhouette shapes (a
    /// body, a roof, a stack) go through this, same restraint the old drop
    /// shadow had — small details (a window, a door) don't get their own
    /// glow pass, since dozens of tiny blurred rects would read as noise,
    /// not light.
    static func withGlow(_ shapes: [SKShapeNode], color: SKColor, blurRadius: CGFloat = 5) -> SKNode {
        let container = SKNode()

        let glowLayer = SKEffectNode()
        glowLayer.shouldRasterize = true
        let blur = CIFilter(name: "CIGaussianBlur")
        blur?.setValue(blurRadius, forKey: "inputRadius")
        glowLayer.filter = blur
        for original in shapes {
            guard let path = original.path else { continue }
            let glowCopy = SKShapeNode(path: path)
            glowCopy.fillColor = color
            glowCopy.strokeColor = color
            glowCopy.lineWidth = 4
            glowCopy.alpha = 0.85
            glowLayer.addChild(glowCopy)
        }
        container.addChild(glowLayer) // added first -> renders behind everything after it

        for shape in shapes {
            container.addChild(shape)
        }
        return container
    }


    // MARK: - Shared building details

    /// A roll-up garage/dock door — `recessedAccent`'s flat rect, plus a
    /// few horizontal tick lines suggesting the door's own segmented
    /// panels, so it reads as an actual roll-up door rather than a dark
    /// hole cut in the wall.
    private static func rollUpDoor(rect: CGRect) -> SKNode {
        let container = SKNode()
        container.addChild(detail(rect: rect, fill: recessedAccent))
        let ridges = CGMutablePath()
        var y = rect.minY + 4
        while y < rect.maxY - 2 {
            ridges.move(to: CGPoint(x: rect.minX + 2, y: y))
            ridges.addLine(to: CGPoint(x: rect.maxX - 2, y: y))
            y += 4
        }
        let lines = SKShapeNode(path: ridges)
        lines.strokeColor = silhouetteFill
        lines.lineWidth = 1
        container.addChild(lines)
        return container
    }

    // MARK: - Services & civic (two looks each — these don't grow, so a
    // second variant is the only way two of the same service ever look
    // different from one another)

    /// A precinct tower: a mid-rise station house with a dense window
    /// grid, a rooftop beacon light, and its own projecting sign — a real
    /// building now, matching the mid-rise/high-rise language every
    /// growable zone's own tier-1 building already uses, instead of a
    /// free-floating badge symbol with no architecture to it.
    private static func precinctTowerIcon(accent: SKColor, seed: GridPosition) -> SKNode {
        let bodyRect = CGRect(x: -22, y: -34, width: 44, height: 64)
        let body = neonShape(rect: bodyRect, accent: accent)
        let roofCap = neonShape(rect: CGRect(x: -24, y: 30, width: 48, height: 5), accent: accent, lineWidth: 1.5)
        let beacon = neonShape(rect: CGRect(x: -3, y: 35, width: 6, height: 10), accent: accent, lineWidth: 1.5)

        let container = SKNode()
        container.addChild(withGlow([body, roofCap, beacon], color: accent, blurRadius: 6))
        container.addChild(dot(radius: 3, at: CGPoint(x: 0, y: 47), fill: litAccent, stroke: accent)) // rooftop beacon light
        container.addChild(foundation(under: bodyRect, height: 4))
        container.addChild(facadeGrid(rows: 5, columns: 3, cell: CGSize(width: 8, height: 8), spacing: CGSize(width: 2.5, height: 2.5), origin: CGPoint(x: -13, y: -28)))
        container.addChild(detail(rect: CGRect(x: -6, y: -34, width: 12, height: 10), fill: recessedAccent)) // entrance
        container.addChild(neonSignboard(rect: CGRect(x: -28, y: -14, width: 6, height: 16), color: signColor(for: seed))) // precinct sign
        return container
    }

    /// A patrol car: a rounded body, a raised cabin, and a light bar on
    /// the roof — a vehicle instead of a building, the same "building vs.
    /// vehicle" variety `transitIcon`/`tramIcon` use for Transit.
    private static func patrolCarIcon(accent: SKColor) -> SKNode {
        let bodyRect = CGRect(x: -30, y: -12, width: 60, height: 22)
        let body = neonShape(CGPath(roundedRect: bodyRect, cornerWidth: 8, cornerHeight: 8, transform: nil), accent: accent)
        let cabin = neonShape(CGPath(roundedRect: CGRect(x: -14, y: 8, width: 28, height: 14), cornerWidth: 6, cornerHeight: 6, transform: nil), accent: accent, lineWidth: 1.5)

        let container = SKNode()
        container.addChild(withGlow([body, cabin], color: accent))
        container.addChild(panedBand(rect: CGRect(x: -10, y: 12, width: 20, height: 8), paneCount: 2))
        container.addChild(detail(rect: CGRect(x: -8, y: 22, width: 7, height: 5), fill: emberColor)) // light bar, red side
        container.addChild(detail(rect: CGRect(x: 1, y: 22, width: 7, height: 5), fill: litAccent)) // light bar, blue side
        container.addChild(dot(radius: 6, at: CGPoint(x: -18, y: -16), fill: recessedAccent, stroke: accent))
        container.addChild(dot(radius: 6, at: CGPoint(x: 18, y: -16), fill: recessedAccent, stroke: accent))
        return container
    }

    /// A firehouse: a squat station body with a tall, narrow hose-drying
    /// tower attached beside it — the real architectural feature that
    /// reads as "fire station" at a glance the way a plain flame symbol
    /// couldn't, and gives it real height matching the mid-rise language
    /// everywhere else. A rooftop warning light on the tower stands in for
    /// the flame this variant used to be.
    private static func fireHouseTowerIcon(accent: SKColor, seed: GridPosition) -> SKNode {
        let bodyRect = CGRect(x: -24, y: -34, width: 40, height: 46)
        let body = neonShape(rect: bodyRect, accent: accent)
        let hoseTowerRect = CGRect(x: 18, y: -34, width: 14, height: 70)
        let hoseTower = neonShape(rect: hoseTowerRect, accent: accent, lineWidth: 1.8)
        let towerCap = neonShape(rect: CGRect(x: 16, y: 34, width: 18, height: 5), accent: accent, lineWidth: 1.5)

        let container = SKNode()
        container.addChild(withGlow([body, hoseTower, towerCap], color: accent, blurRadius: 6))
        container.addChild(dot(radius: 3, at: CGPoint(x: 25, y: 42), fill: emberColor, stroke: .clear)) // rooftop warning light
        container.addChild(foundation(under: bodyRect))
        container.addChild(rollUpDoor(rect: CGRect(x: -20, y: -34, width: 32, height: 20)))
        container.addChild(facadeGrid(rows: 2, columns: 3, cell: CGSize(width: 8, height: 8), spacing: CGSize(width: 2, height: 2), origin: CGPoint(x: -12, y: -4)))
        container.addChild(neonSignboard(rect: CGRect(x: -30, y: -8, width: 6, height: 14), color: signColor(for: seed))) // firehouse sign
        return container
    }

    /// A twin-bay firehouse: two roll-up apparatus doors side by side under
    /// a wide, flat-roofed body, with a rooftop siren instead of
    /// `fireHouseTowerIcon`'s tall hose-drying tower — a second *building*
    /// variant, not a vehicle. Police, Transit, and every growable zone
    /// keep a genuine two-different-buildings (or two-different-vehicles)
    /// pair; Fire used to be the odd one out with a truck standing in for
    /// its second look, which read as inconsistent once every other
    /// service in the skyline was a real building — a live request asked
    /// for exactly this fix.
    private static func twinBayFirehouseIcon(accent: SKColor, seed: GridPosition) -> SKNode {
        let bodyRect = CGRect(x: -30, y: -34, width: 60, height: 48)
        let body = neonShape(rect: bodyRect, accent: accent)
        let roofCap = neonShape(rect: CGRect(x: -32, y: 14, width: 64, height: 5), accent: accent, lineWidth: 1.5)
        let siren = neonShape(rect: CGRect(x: -4, y: 19, width: 8, height: 10), accent: accent, lineWidth: 1.5)

        let container = SKNode()
        container.addChild(withGlow([body, roofCap, siren], color: accent, blurRadius: 6))
        container.addChild(dot(radius: 3, at: CGPoint(x: 0, y: 32), fill: emberColor, stroke: .clear)) // rooftop siren light
        container.addChild(foundation(under: bodyRect))
        container.addChild(rollUpDoor(rect: CGRect(x: -26, y: -34, width: 22, height: 22)))
        container.addChild(rollUpDoor(rect: CGRect(x: 4, y: -34, width: 22, height: 22)))
        container.addChild(facadeGrid(rows: 2, columns: 4, cell: CGSize(width: 8, height: 8), spacing: CGSize(width: 2, height: 2), origin: CGPoint(x: -22, y: -8)))
        container.addChild(neonSignboard(rect: CGRect(x: 32, y: -14, width: 6, height: 16), color: signColor(for: seed)))
        return container
    }

    /// A bus: rounded body, a windshield band split into individual panes,
    /// two wheels.
    private static func transitIcon(accent: SKColor, seed: GridPosition) -> SKNode {
        let bodyRect = CGRect(x: -30, y: -14, width: 60, height: 28)
        let body = neonShape(CGPath(roundedRect: bodyRect, cornerWidth: 8, cornerHeight: 8, transform: nil), accent: accent)

        let container = SKNode()
        container.addChild(withGlow([body], color: accent))
        container.addChild(panedBand(rect: CGRect(x: -24, y: 1, width: 48, height: 9), paneCount: 4))
        container.addChild(dot(radius: 6, at: CGPoint(x: -17, y: -17), fill: recessedAccent, stroke: accent))
        container.addChild(dot(radius: 6, at: CGPoint(x: 17, y: -17), fill: recessedAccent, stroke: accent))
        container.addChild(neonSignboard(rect: CGRect(x: 24, y: -6, width: 5, height: 12), color: signColor(for: seed))) // route sign
        return container
    }

    /// A tram: the same rounded-body silhouette as `transitIcon`'s bus,
    /// distinguished by a pantograph arm reaching up to an overhead wire
    /// instead of round wheel-wells — the detail that reads "rail-guided
    /// street vehicle" rather than "bus" at this size.
    private static func tramIcon(accent: SKColor, seed: GridPosition) -> SKNode {
        let bodyRect = CGRect(x: -32, y: -14, width: 64, height: 26)
        let body = neonShape(CGPath(roundedRect: bodyRect, cornerWidth: 6, cornerHeight: 6, transform: nil), accent: accent)

        let container = SKNode()
        container.addChild(withGlow([body], color: accent))
        container.addChild(panedBand(rect: CGRect(x: -26, y: -2, width: 52, height: 9), paneCount: 4))
        container.addChild(dot(radius: 6, at: CGPoint(x: -20, y: -18), fill: recessedAccent, stroke: accent))
        container.addChild(dot(radius: 6, at: CGPoint(x: 20, y: -18), fill: recessedAccent, stroke: accent))
        container.addChild(detail(rect: CGRect(x: -2, y: 12, width: 4, height: 14), fill: recessedAccent)) // pantograph arm
        container.addChild(detail(rect: CGRect(x: -20, y: 26, width: 40, height: 3), fill: accent)) // overhead wire
        container.addChild(neonSignboard(rect: CGRect(x: 26, y: -6, width: 5, height: 12), color: signColor(for: seed))) // route sign
        return container
    }

    /// A subway: a station entrance kiosk over a pair of rail tracks, not
    /// another wheeled vehicle — `.publicTransit`'s bus already owns that
    /// silhouette, and a track-and-tie motif reads as "rail" at a glance
    /// the way a second bus wouldn't distinguish itself from the first.
    private static func subwayIcon(accent: SKColor, seed: GridPosition) -> SKNode {
        let kioskRect = CGRect(x: -22, y: -2, width: 44, height: 32)
        let kiosk = neonShape(CGPath(roundedRect: kioskRect, cornerWidth: 10, cornerHeight: 10, transform: nil), accent: accent)

        let container = SKNode()
        container.addChild(withGlow([kiosk], color: accent))
        container.addChild(framedWindow(rect: CGRect(x: -16, y: 20, width: 32, height: 8), fill: signColor(for: seed))) // lit sign panel above the entrance
        container.addChild(detail(rect: CGRect(x: -11, y: -2, width: 22, height: 20), fill: recessedAccent))

        // Two rails with cross-ties beneath the kiosk, built from straight
        // lines/rects only, same constraint as every other icon here.
        let railTopY: CGFloat = -22
        let railBottomY: CGFloat = -32
        container.addChild(detail(rect: CGRect(x: -32, y: railTopY, width: 64, height: 3), fill: accent))
        container.addChild(detail(rect: CGRect(x: -32, y: railBottomY, width: 64, height: 3), fill: accent))
        for tieX in stride(from: CGFloat(-28), through: 28, by: 14) {
            container.addChild(detail(rect: CGRect(x: tieX - 1.5, y: railBottomY, width: 3, height: railTopY - railBottomY + 3), fill: recessedAccent))
        }
        return container
    }

    /// A subway station entrance, viewed as a stairway going down rather
    /// than a street-level kiosk — a receding row of narrowing steps
    /// (the same "shrinking rects" perspective trick used elsewhere in
    /// this file, just applied downward) under an entrance sign band.
    private static func subwayStairsIcon(accent: SKColor, seed: GridPosition) -> SKNode {
        let frameRect = CGRect(x: -26, y: -30, width: 52, height: 40)
        let frame = neonShape(rect: frameRect, accent: accent)

        let container = SKNode()
        container.addChild(withGlow([frame], color: accent))
        let stepCount = 4
        for index in 0 ..< stepCount {
            let inset = CGFloat(index) * 4
            let stepY = -20 - CGFloat(index) * 6
            container.addChild(detail(rect: CGRect(x: -22 + inset, y: stepY, width: 44 - inset * 2, height: 4), fill: recessedAccent))
        }
        container.addChild(framedWindow(rect: CGRect(x: -22, y: 6, width: 44, height: 8), fill: signColor(for: seed))) // entrance sign band
        return container
    }

    /// A water tower: an elevated tank on three splayed support legs — the
    /// classic silhouette, built the same way the power plant's cooling
    /// towers are (the shared `trapezoid` primitive), just narrow-to-narrow
    /// rather than narrow-to-wide.
    /// A low, wide schoolhouse with a pitched roof and a clock.
    ///
    /// Civic buildings get silhouettes nothing else in the game uses — a
    /// gable and a clock face here, a cross there — because they are the two
    /// zones a player most needs to pick out at a glance while scanning for
    /// coverage gaps.
    private static func schoolIcon(accent: SKColor, seed: GridPosition) -> SKNode {
        let body = neonShape(rect: CGRect(x: -34, y: -30, width: 68, height: 44), accent: accent)
        // A gable, the one pitched roof in the whole icon set.
        let roof = neonShape(trapezoid(
            bottomLeft: CGPoint(x: -38, y: 14), bottomRight: CGPoint(x: 38, y: 14),
            topRight: CGPoint(x: 16, y: 40), topLeft: CGPoint(x: -16, y: 40)
        ), accent: accent)

        let container = SKNode()
        container.addChild(withGlow([body, roof], color: accent))
        container.addChild(detail(rect: CGRect(x: -34, y: 10, width: 68, height: 4), fill: recessedAccent))
        // Clock face in the gable.
        container.addChild(dot(radius: 6, at: CGPoint(x: 0, y: 24), fill: litAccent))
        for index in 0 ..< 3 {
            let x = -24 + CGFloat(index) * 18
            container.addChild(framedWindow(rect: CGRect(x: x, y: -8, width: 14, height: 14)))
        }
        container.addChild(detail(rect: CGRect(x: -6, y: -30, width: 12, height: 16), fill: recessedAccent)) // door
        container.addChild(neonSignboard(rect: CGRect(x: 14, y: -26, width: 16, height: 7), color: signColor(for: seed)))
        return container
    }

    /// A blocky ward with a cross above the entrance.
    private static func hospitalIcon(accent: SKColor, seed: GridPosition) -> SKNode {
        let body = neonShape(rect: CGRect(x: -32, y: -32, width: 64, height: 58), accent: accent)
        let entrance = neonShape(rect: CGRect(x: -14, y: -32, width: 28, height: 18), accent: accent, lineWidth: 1.5)

        let container = SKNode()
        container.addChild(withGlow([body, entrance], color: accent))
        // The cross — the clearest "this is a hospital" mark available inside
        // this file's straight-lines-only vocabulary.
        let arm: CGFloat = 5
        let span: CGFloat = 16
        container.addChild(detail(rect: CGRect(x: -arm, y: 26 - span / 2, width: arm * 2, height: span), fill: litAccent))
        container.addChild(detail(rect: CGRect(x: -span / 2, y: 26 - arm, width: span, height: arm * 2), fill: litAccent))
        for row in 0 ..< 2 {
            for column in 0 ..< 3 {
                let x = -24 + CGFloat(column) * 18
                let y = -6 + CGFloat(row) * 16
                container.addChild(framedWindow(rect: CGRect(x: x, y: y, width: 13, height: 11)))
            }
        }
        container.addChild(neonSignboard(rect: CGRect(x: -10, y: -28, width: 20, height: 7), color: signColor(for: seed)))
        return container
    }

    /// The starter water supply: a squat pumphouse with a stub of pipe.
    ///
    /// Deliberately low and wide against `waterTowerIcon`'s tall silhouette —
    /// the pair is the same utility at two sizes, and the whole point of a
    /// starter building is that a glance tells you it is the small one. Single
    /// variant rather than the two most services get: it occupies a 1×1 lot,
    /// so there is very little room to say anything with.
    private static func waterPumpIcon(accent: SKColor, seed: GridPosition) -> SKNode {
        let housing = neonShape(rect: CGRect(x: -30, y: -20, width: 60, height: 34), accent: accent)
        let capRect = CGRect(x: -14, y: 14, width: 28, height: 10)
        let cap = neonShape(CGPath(roundedRect: capRect, cornerWidth: 4, cornerHeight: 4, transform: nil), accent: accent)
        // A short outlet pipe, the visual promise that this feeds a network.
        let outlet = neonShape(rect: CGRect(x: 26, y: -8, width: 14, height: 8), accent: accent, lineWidth: 1.5)

        let container = SKNode()
        container.addChild(withGlow([housing, cap, outlet], color: accent))
        container.addChild(detail(rect: CGRect(x: -30, y: -6, width: 60, height: 4), fill: recessedAccent))
        container.addChild(framedWindow(rect: CGRect(x: -20, y: -16, width: 14, height: 10)))
        container.addChild(neonSignboard(rect: CGRect(x: 4, y: -16, width: 18, height: 8), color: signColor(for: seed)))
        return container
    }

    /// The starter power supply: a boxy generator shed with an exhaust stack,
    /// against `powerPlantIcon`'s cooling towers. Same "obviously the small
    /// one" reasoning as `waterPumpIcon`.
    private static func generatorIcon(accent: SKColor, seed: GridPosition) -> SKNode {
        let shed = neonShape(rect: CGRect(x: -32, y: -26, width: 64, height: 40), accent: accent)
        let stack = neonShape(rect: CGRect(x: 12, y: 14, width: 12, height: 26), accent: accent, lineWidth: 2)
        let vent = neonShape(rect: CGRect(x: -26, y: 14, width: 26, height: 8), accent: accent, lineWidth: 1.5)

        let container = SKNode()
        container.addChild(withGlow([shed, stack, vent], color: accent))
        container.addChild(detail(rect: CGRect(x: -32, y: -12, width: 64, height: 4), fill: recessedAccent))
        // Louvres along the shed face — straight lines only, same vocabulary
        // as every other building in this file.
        for index in 0 ..< 3 {
            let x = -24 + CGFloat(index) * 18
            container.addChild(detail(rect: CGRect(x: x, y: -22, width: 12, height: 6), fill: recessedAccent))
        }
        container.addChild(dot(radius: 3.5, at: CGPoint(x: 18, y: 42), fill: emberColor))
        container.addChild(neonSignboard(rect: CGRect(x: -26, y: -22, width: 14, height: 6), color: signColor(for: seed)))
        return container
    }

    private static func waterTowerIcon(accent: SKColor, seed: GridPosition) -> SKNode {
        let tankRect = CGRect(x: -26, y: 6, width: 52, height: 34)
        let tank = neonShape(CGPath(roundedRect: tankRect, cornerWidth: 12, cornerHeight: 10, transform: nil), accent: accent)
        let leftLeg = neonShape(trapezoid(
            bottomLeft: CGPoint(x: -34, y: -34), bottomRight: CGPoint(x: -28, y: -34),
            topRight: CGPoint(x: -10, y: 6), topLeft: CGPoint(x: -16, y: 6)
        ), accent: accent, lineWidth: 1.5)
        let rightLeg = neonShape(trapezoid(
            bottomLeft: CGPoint(x: 28, y: -34), bottomRight: CGPoint(x: 34, y: -34),
            topRight: CGPoint(x: 16, y: 6), topLeft: CGPoint(x: 10, y: 6)
        ), accent: accent, lineWidth: 1.5)
        let centerLeg = neonShape(rect: CGRect(x: -3, y: -34, width: 6, height: 40), accent: accent, lineWidth: 1.5)

        let container = SKNode()
        container.addChild(withGlow([tank, leftLeg, rightLeg, centerLeg], color: accent))
        container.addChild(detail(rect: CGRect(x: -26, y: 6, width: 52, height: 4), fill: recessedAccent)) // support band at the tank's base
        container.addChild(detail(rect: CGRect(x: -24, y: -14, width: 48, height: 4), fill: recessedAccent)) // cross-brace tying the legs together
        container.addChild(neonSignboard(rect: CGRect(x: -3, y: -30, width: 6, height: 14), color: signColor(for: seed))) // municipal placard on the center leg
        return container
    }

    /// A standpipe tower: one wide cylindrical tank sitting directly on a
    /// solid base, no legs — the other real-world water tower silhouette,
    /// distinct enough from `waterTowerIcon`'s elevated-tank-on-legs look
    /// to read as a different building at a glance.
    private static func standpipeTowerIcon(accent: SKColor, seed: GridPosition) -> SKNode {
        let tankRect = CGRect(x: -20, y: -10, width: 40, height: 44)
        let tank = neonShape(CGPath(roundedRect: tankRect, cornerWidth: 10, cornerHeight: 10, transform: nil), accent: accent)
        let baseRect = CGRect(x: -14, y: -34, width: 28, height: 24)
        let base = neonShape(rect: baseRect, accent: accent, lineWidth: 1.5)

        let container = SKNode()
        container.addChild(withGlow([tank, base], color: accent))
        container.addChild(detail(rect: CGRect(x: -20, y: 20, width: 40, height: 4), fill: recessedAccent))
        container.addChild(detail(rect: CGRect(x: -20, y: -2, width: 40, height: 4), fill: recessedAccent))
        container.addChild(foundation(under: baseRect))
        container.addChild(neonSignboard(rect: CGRect(x: -26, y: -20, width: 5, height: 14), color: signColor(for: seed))) // municipal placard
        return container
    }

    /// A power plant: a base building with a hazard stripe and two
    /// trapezoidal cooling towers of different heights.
    private static func powerPlantIcon(accent: SKColor, seed: GridPosition) -> SKNode {
        let baseRect = CGRect(x: -38, y: -34, width: 76, height: 24)
        let base = neonShape(rect: baseRect, accent: accent)
        let towerA = neonShape(trapezoid(
            bottomLeft: CGPoint(x: -24, y: -4), bottomRight: CGPoint(x: -6, y: -4),
            topRight: CGPoint(x: -9, y: 24), topLeft: CGPoint(x: -21, y: 24)
        ), accent: accent)
        let towerB = neonShape(trapezoid(
            bottomLeft: CGPoint(x: 2, y: -4), bottomRight: CGPoint(x: 24, y: -4),
            topRight: CGPoint(x: 20, y: 34), topLeft: CGPoint(x: 6, y: 34)
        ), accent: accent)

        let container = SKNode()
        container.addChild(withGlow([base, towerA, towerB], color: accent, blurRadius: 6))
        container.addChild(framedWindow(rect: CGRect(x: -34, y: -30, width: 14, height: 12)))
        container.addChild(framedWindow(rect: CGRect(x: -6, y: -30, width: 14, height: 12)))
        container.addChild(detail(rect: CGRect(x: -38, y: -10, width: 76, height: 6), fill: emberColor))
        container.addChild(foundation(under: baseRect))
        container.addChild(neonSignboard(rect: CGRect(x: -44, y: -28, width: 6, height: 16), color: signColor(for: seed))) // plant ID sign
        return container
    }

    /// A power plant with one large hourglass-profile cooling tower
    /// (two trapezoids, narrow waist between a wide base and a wider
    /// crown — built from the same `trapezoid` primitive as `powerPlantIcon`'s
    /// pair of towers) instead of two smaller ones side by side.
    private static func singleTowerPlantIcon(accent: SKColor, seed: GridPosition) -> SKNode {
        let baseRect = CGRect(x: -34, y: -34, width: 68, height: 20)
        let base = neonShape(rect: baseRect, accent: accent)
        let tower = neonShape(trapezoid(
            bottomLeft: CGPoint(x: -22, y: -14), bottomRight: CGPoint(x: 22, y: -14),
            topRight: CGPoint(x: 14, y: 30), topLeft: CGPoint(x: -14, y: 30)
        ), accent: accent, lineWidth: 3)
        let crown = neonShape(trapezoid(
            bottomLeft: CGPoint(x: -14, y: 30), bottomRight: CGPoint(x: 14, y: 30),
            topRight: CGPoint(x: 20, y: 40), topLeft: CGPoint(x: -20, y: 40)
        ), accent: accent, lineWidth: 1.5)

        let container = SKNode()
        container.addChild(withGlow([base, tower, crown], color: accent, blurRadius: 6))
        container.addChild(framedWindow(rect: CGRect(x: -28, y: -20, width: 12, height: 6)))
        container.addChild(framedWindow(rect: CGRect(x: 16, y: -20, width: 12, height: 6)))
        container.addChild(detail(rect: CGRect(x: -34, y: -28, width: 68, height: 6), fill: emberColor))
        container.addChild(foundation(under: baseRect))
        container.addChild(neonSignboard(rect: CGRect(x: -40, y: -28, width: 6, height: 14), color: signColor(for: seed))) // plant ID sign
        return container
    }

    /// A stadium: an outer bowl, a track ring, a field, and four glowing
    /// corner floodlights.
    private static func stadiumIcon(accent: SKColor, seed: GridPosition) -> SKNode {
        let bowlShape = SKShapeNode(ellipseOf: CGSize(width: 88, height: 62))
        bowlShape.fillColor = silhouetteFill
        bowlShape.strokeColor = accent
        bowlShape.lineWidth = 3

        let container = SKNode()
        container.addChild(withGlow([bowlShape], color: accent, blurRadius: 6))

        let track = SKShapeNode(ellipseOf: CGSize(width: 66, height: 44))
        track.fillColor = .clear
        track.strokeColor = accent
        track.lineWidth = 2
        container.addChild(track)

        // The field itself glows the stadium's own accent rather than a
        // fixed "grass green" — an energy floor lit by the same lights
        // the rest of the building glows with, not a patch of turf.
        let field = SKShapeNode(ellipseOf: CGSize(width: 50, height: 30))
        field.fillColor = accent.withAlphaComponent(0.55)
        field.strokeColor = .clear
        container.addChild(field)

        for (dx, dy): (CGFloat, CGFloat) in [(-40, 26), (40, 26), (-40, -26), (40, -26)] {
            container.addChild(dot(radius: 4, at: CGPoint(x: dx, y: dy), fill: litAccent, stroke: accent))
        }
        container.addChild(neonSignboard(rect: CGRect(x: -14, y: 34, width: 28, height: 8), color: signColor(for: seed))) // scoreboard sign above the bowl
        return container
    }

    /// An enclosed arena: a rounded rectangular hall with a marquee sign,
    /// instead of `stadiumIcon`'s open bowl-and-track — "indoor venue" as
    /// a genuinely different building shape, not just the bowl recolored.
    private static func arenaIcon(accent: SKColor, seed: GridPosition) -> SKNode {
        let bodyRect = CGRect(x: -44, y: -30, width: 88, height: 40)
        let body = neonShape(CGPath(roundedRect: bodyRect, cornerWidth: 16, cornerHeight: 16, transform: nil), accent: accent, lineWidth: 3)
        let marquee = neonShape(rect: CGRect(x: -20, y: 12, width: 40, height: 10), accent: accent, lineWidth: 1.5)
        // An attached office/hotel tower — the "arena complex," not just
        // the bowl — the detail that gives this variant real height next
        // to the mid-rise/high-rise buildings surrounding it.
        let annexRect = CGRect(x: 30, y: -30, width: 20, height: 66)
        let annex = neonShape(rect: annexRect, accent: accent, lineWidth: 1.8)

        let container = SKNode()
        container.addChild(withGlow([body, marquee, annex], color: accent, blurRadius: 6))
        container.addChild(panedBand(rect: CGRect(x: -16, y: 14, width: 32, height: 6), paneCount: 4, fill: signColor(for: seed)))
        container.addChild(foundation(under: bodyRect))
        container.addChild(foundation(under: annexRect, height: 4))
        container.addChild(facadeGrid(rows: 5, columns: 1, cell: CGSize(width: 10, height: 8), spacing: CGSize(width: 0, height: 3), origin: CGPoint(x: 35, y: -24)))
        for (dx, dy): (CGFloat, CGFloat) in [(-34, -22), (54, -22)] {
            container.addChild(dot(radius: 4, at: CGPoint(x: dx, y: dy), fill: litAccent, stroke: accent))
        }
        container.addChild(neonSignboard(rect: CGRect(x: -50, y: -14, width: 6, height: 16), color: signColor(for: seed, salt: 1))) // side-mounted sign
        return container
    }
}
