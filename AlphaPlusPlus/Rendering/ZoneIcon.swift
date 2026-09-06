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
/// just brighter/more glowing.
///
/// Every shape is still built only from straight lines, rectangles, and
/// circles/ellipses — no hand-tuned bezier curves — simple enough to get
/// right from coordinates alone, with nothing to preview.
///
/// Each icon is authored in a fixed design space, `designSize` points on a
/// side, centered on `(0, 0)`. `TileRenderer` scales the returned node to
/// whatever the actual sprite needs.
enum ZoneIcon {

    /// The width/height of the square each icon is designed to fit inside.
    static let designSize: CGFloat = 100

    /// `nil` for zones that don't get an icon: `.empty` (nothing to draw)
    /// and `.road`/`.highway`/`.pipe` (a flat, glowing fill already reads
    /// as an uninterrupted stretch of network — see
    /// `RenderPalette.fullColor(for:)` and `GameScene`'s network glow) —
    /// and for a growable zone at density 0 (just zoned, nothing built
    /// yet; the icon appearing at all is itself part of the signal that
    /// something now stands here).
    ///
    /// `seed` — a building's anchor position — picks which *variant* a tier
    /// with more than one draws (currently tier 1 of the three growable
    /// zones, via `variant(for:optionCount:)`). Every other tier still
    /// draws exactly one look; adding a second variant there is the same
    /// pattern, just another `variant(for:)` call and another function.
    static func makeNode(for zone: ZoneType, density: Int, seed: GridPosition) -> SKNode? {
        switch zone {
        case .empty, .road, .highway, .pipe:
            return nil
        case .residential:
            let accent = RenderPalette.fullColor(for: zone)
            switch growthTier(for: density) {
            case 0: return nil
            case 1: return variant(for: seed, optionCount: 2) == 0 ? smallHouseIcon(accent: accent) : smallCottageIcon(accent: accent)
            case 2: return mediumHouseIcon(accent: accent)
            default: return largeHousingIcon(accent: accent)
            }
        case .commercial:
            let accent = RenderPalette.fullColor(for: zone)
            switch growthTier(for: density) {
            case 0: return nil
            case 1: return variant(for: seed, optionCount: 2) == 0 ? smallShopIcon(accent: accent) : smallDinerIcon(accent: accent)
            case 2: return midriseOfficeIcon(accent: accent)
            default: return towerIcon(accent: accent)
            }
        case .industrial:
            let accent = RenderPalette.fullColor(for: zone)
            switch growthTier(for: density) {
            case 0: return nil
            case 1: return variant(for: seed, optionCount: 2) == 0 ? smallWarehouseIcon(accent: accent) : smallDepotIcon(accent: accent)
            case 2: return factoryIcon(accent: accent)
            default: return bigFactoryIcon(accent: accent)
            }
        case .policeStation: return shieldIcon(accent: RenderPalette.fullColor(for: zone))
        case .fireStation: return torchIcon(accent: RenderPalette.fullColor(for: zone))
        case .publicTransit: return transitIcon(accent: RenderPalette.fullColor(for: zone))
        case .powerPlant: return powerPlantIcon(accent: RenderPalette.fullColor(for: zone))
        case .stadium: return stadiumIcon(accent: RenderPalette.fullColor(for: zone))
        case .subway: return subwayIcon(accent: RenderPalette.fullColor(for: zone))
        case .waterTower: return waterTowerIcon(accent: RenderPalette.fullColor(for: zone))
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

    /// Which visual tier a growable zone's density falls into: 0 (nothing
    /// built), 1 (small), 2 (medium), 3 (large/fully developed).
    /// Deliberately a direct table, not a `density / maxDensity` proportion
    /// — a proportional split would put density 2 and 3 in the *same*
    /// third for a max of 5, which is exactly the "adjacent levels should
    /// look different" case the icons exist to show. Assumes today's
    /// `maxDensity` of 5 for every growable zone; revisit this table
    /// specifically if that ever changes.
    private static func growthTier(for density: Int) -> Int {
        switch density {
        case 0: return 0
        case 1, 2: return 1
        case 3, 4: return 2
        default: return 3
        }
    }

    // MARK: - Shared palette

    /// Every building silhouette's fill — near-black, so a building reads
    /// as a shape cut out of the night, lit only by its own neon outline.
    /// Consistent across every zone: the *glow color*, not a different
    /// material fill, is what identifies a house from a shop now.
    private static let silhouetteFill = SKColor(srgbRed: 0.05, green: 0.03, blue: 0.09, alpha: 1.0)

    /// Windows, sign faces, stadium floodlights — anything meant to read
    /// as lit up at night. The one element deliberately *not* colored by
    /// the zone's own accent: a lit window is white-hot regardless of
    /// what color building it's punched into.
    private static let litAccent = SKColor(srgbRed: 0.95, green: 0.98, blue: 1.0, alpha: 0.95)

    /// Doors, wheels, smokestacks, rail ties — anything that should read
    /// as the darkest, most recessed part of a shape, darker even than
    /// `silhouetteFill` itself.
    private static let recessedAccent = SKColor.black.withAlphaComponent(0.75)

    /// Warm orange, used only for fire's inner flame, the power plant's
    /// hazard stripe, and a diner's sign face — a fixed "attention" color
    /// rather than a zone accent, the same way it worked before this pass
    /// (a neon diner sign glowing orange/red is its own classic look, not
    /// a departure from one).
    private static let emberColor = SKColor(srgbRed: 1.0, green: 0.45, blue: 0.15, alpha: 0.95)

    /// A shape filled `silhouetteFill` (or `fill`, for the rare shape that
    /// isn't a primary body) with a crisp stroke in the zone's own
    /// `accent` — the "outline," as opposed to `withGlow`'s soft-edged
    /// duplicate behind it. Every primary body/roof/stack shape in this
    /// file is a `neonShape`; only small non-primary details (a door, a
    /// window) skip straight to `detail(rect:fill:)` with no stroke at all.
    private static func neonShape(_ path: CGPath, accent: SKColor, fill: SKColor = silhouetteFill, lineWidth: CGFloat = 2.5) -> SKShapeNode {
        let node = SKShapeNode(path: path)
        node.fillColor = fill
        node.strokeColor = accent
        node.lineWidth = lineWidth
        return node
    }

    private static func neonShape(rect: CGRect, accent: SKColor, fill: SKColor = silhouetteFill, lineWidth: CGFloat = 2.5) -> SKShapeNode {
        neonShape(CGPath(rect: rect, transform: nil), accent: accent, fill: fill, lineWidth: lineWidth)
    }

    /// A rect with no outline — used for window/accent details layered on
    /// top of a body shape that already has its own neon stroke, so
    /// details don't each grow a second competing outline.
    private static func detail(rect: CGRect, fill: SKColor) -> SKShapeNode {
        let node = SKShapeNode(rect: rect)
        node.fillColor = fill
        node.strokeColor = .clear
        return node
    }

    private static func dot(radius: CGFloat, at point: CGPoint, fill: SKColor, stroke: SKColor = recessedAccent) -> SKShapeNode {
        let node = SKShapeNode(circleOfRadius: radius)
        node.position = point
        node.fillColor = fill
        node.strokeColor = stroke
        node.lineWidth = 1.5
        return node
    }

    private static func peakedRoofPath(left: CGFloat, right: CGFloat, base: CGFloat, peak: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: left, y: base))
        path.addLine(to: CGPoint(x: right, y: base))
        path.addLine(to: peak)
        path.closeSubpath()
        return path
    }

    /// A four-point polygon — used for the power plant's and water
    /// tower's silhouettes (narrower at one end than the other), built
    /// from lines only.
    private static func trapezoid(bottomLeft: CGPoint, bottomRight: CGPoint, topRight: CGPoint, topLeft: CGPoint) -> CGPath {
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
    private static func withGlow(_ shapes: [SKShapeNode], color: SKColor, blurRadius: CGFloat = 5) -> SKNode {
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

    // MARK: - Residential (3 tiers)

    /// Tier 1 (density 1–2): a single-story cottage — body, peaked roof,
    /// one door.
    private static func smallHouseIcon(accent: SKColor) -> SKNode {
        let bodyRect = CGRect(x: -24, y: -30, width: 48, height: 28)
        let body = neonShape(rect: bodyRect, accent: accent)
        let roof = neonShape(peakedRoofPath(left: -28, right: 28, base: -2, peak: CGPoint(x: 0, y: 26)), accent: accent)

        let container = SKNode()
        container.addChild(withGlow([body, roof], color: accent))
        container.addChild(detail(rect: CGRect(x: -6, y: -30, width: 12, height: 16), fill: recessedAccent))
        return container
    }

    /// Tier 1, variant B: a cottage with a chimney and a round window
    /// instead of a plain door — same footprint and proportions as
    /// `smallHouseIcon`, different enough silhouette that two freshly-grown
    /// lots picked by `variant(for:optionCount:)` don't look identical.
    private static func smallCottageIcon(accent: SKColor) -> SKNode {
        let bodyRect = CGRect(x: -24, y: -30, width: 48, height: 28)
        let body = neonShape(rect: bodyRect, accent: accent)
        let roof = neonShape(peakedRoofPath(left: -28, right: 28, base: -2, peak: CGPoint(x: 0, y: 26)), accent: accent)
        let chimney = neonShape(rect: CGRect(x: 12, y: 12, width: 8, height: 18), accent: accent, lineWidth: 1.5)

        let container = SKNode()
        container.addChild(withGlow([body, roof, chimney], color: accent))
        container.addChild(dot(radius: 6, at: CGPoint(x: -6, y: -16), fill: litAccent, stroke: accent))
        return container
    }

    /// Tier 2 (density 3–4): a taller two-story house with upstairs windows.
    private static func mediumHouseIcon(accent: SKColor) -> SKNode {
        let bodyRect = CGRect(x: -26, y: -32, width: 52, height: 42)
        let body = neonShape(rect: bodyRect, accent: accent)
        let roof = neonShape(peakedRoofPath(left: -30, right: 30, base: 10, peak: CGPoint(x: 0, y: 32)), accent: accent)

        let container = SKNode()
        container.addChild(withGlow([body, roof], color: accent))
        container.addChild(detail(rect: CGRect(x: -7, y: -32, width: 14, height: 16), fill: recessedAccent))
        container.addChild(detail(rect: CGRect(x: -21, y: -6, width: 12, height: 12), fill: litAccent))
        container.addChild(detail(rect: CGRect(x: 9, y: -6, width: 12, height: 12), fill: litAccent))
        return container
    }

    /// Tier 3 (density 5): fully developed — two houses side by side, the
    /// clearest "this lot is built out" silhouette of the three tiers.
    private static func largeHousingIcon(accent: SKColor) -> SKNode {
        let leftBodyRect = CGRect(x: -42, y: -30, width: 32, height: 30)
        let leftBody = neonShape(rect: leftBodyRect, accent: accent)
        let leftRoof = neonShape(peakedRoofPath(left: -44, right: -8, base: 0, peak: CGPoint(x: -26, y: 20)), accent: accent)

        let rightBodyRect = CGRect(x: 6, y: -30, width: 36, height: 36)
        let rightBody = neonShape(rect: rightBodyRect, accent: accent)
        let rightRoof = neonShape(peakedRoofPath(left: 4, right: 44, base: 6, peak: CGPoint(x: 24, y: 28)), accent: accent)

        let container = SKNode()
        container.addChild(withGlow([leftBody, leftRoof, rightBody, rightRoof], color: accent))
        container.addChild(detail(rect: CGRect(x: -32, y: -18, width: 10, height: 10), fill: litAccent))
        container.addChild(detail(rect: CGRect(x: 14, y: -30, width: 12, height: 16), fill: recessedAccent))
        container.addChild(detail(rect: CGRect(x: 30, y: -10, width: 10, height: 10), fill: litAccent))
        return container
    }

    // MARK: - Commercial (3 tiers)

    /// Tier 1: a single-story storefront with an awning and a display window.
    private static func smallShopIcon(accent: SKColor) -> SKNode {
        let bodyRect = CGRect(x: -28, y: -28, width: 56, height: 32)
        let body = neonShape(rect: bodyRect, accent: accent)
        let awning = neonShape(rect: CGRect(x: -30, y: 4, width: 60, height: 8), accent: accent, lineWidth: 1.5)

        let container = SKNode()
        container.addChild(withGlow([body, awning], color: accent))
        container.addChild(detail(rect: CGRect(x: -20, y: -22, width: 40, height: 20), fill: litAccent))
        return container
    }

    /// Tier 1, variant B: a diner-style storefront with a sign on a pole
    /// instead of an awning — same body proportions as `smallShopIcon`.
    private static func smallDinerIcon(accent: SKColor) -> SKNode {
        let bodyRect = CGRect(x: -28, y: -28, width: 56, height: 30)
        let body = neonShape(rect: bodyRect, accent: accent)
        let signPole = detail(rect: CGRect(x: -2, y: 2, width: 4, height: 14), fill: recessedAccent)
        let sign = neonShape(rect: CGRect(x: -16, y: 16, width: 32, height: 10), accent: emberColor, fill: emberColor, lineWidth: 1.5)

        let container = SKNode()
        container.addChild(withGlow([body], color: accent))
        container.addChild(withGlow([sign], color: emberColor, blurRadius: 4))
        container.addChild(signPole)
        container.addChild(detail(rect: CGRect(x: -22, y: -22, width: 44, height: 18), fill: litAccent))
        return container
    }

    /// Tier 2: a mid-rise office — taller body, a grid of windows, a flat
    /// roof cap.
    private static func midriseOfficeIcon(accent: SKColor) -> SKNode {
        let bodyRect = CGRect(x: -26, y: -30, width: 52, height: 50)
        let body = neonShape(rect: bodyRect, accent: accent)
        let roofCap = neonShape(rect: CGRect(x: -28, y: 20, width: 56, height: 6), accent: accent, lineWidth: 1.5)

        let container = SKNode()
        container.addChild(withGlow([body, roofCap], color: accent))
        for row in 0 ..< 2 {
            for column in 0 ..< 3 {
                let point = CGPoint(x: -18 + CGFloat(column) * 18, y: -18 + CGFloat(row) * 20)
                container.addChild(detail(rect: CGRect(x: point.x, y: point.y, width: 10, height: 10), fill: litAccent))
            }
        }
        return container
    }

    /// Tier 3: a high-rise tower — tall and narrow, a denser window grid,
    /// a rooftop antenna.
    private static func towerIcon(accent: SKColor) -> SKNode {
        let bodyRect = CGRect(x: -20, y: -34, width: 40, height: 66)
        let body = neonShape(rect: bodyRect, accent: accent)
        let antenna = neonShape(rect: CGRect(x: -2, y: 32, width: 4, height: 16), accent: accent, lineWidth: 1.5)

        let container = SKNode()
        container.addChild(withGlow([body, antenna], color: accent, blurRadius: 6))
        for row in 0 ..< 4 {
            for column in 0 ..< 2 {
                let point = CGPoint(x: -13 + CGFloat(column) * 16, y: -26 + CGFloat(row) * 14)
                container.addChild(detail(rect: CGRect(x: point.x, y: point.y, width: 9, height: 9), fill: litAccent))
            }
        }
        return container
    }

    // MARK: - Industrial (3 tiers)

    /// Tier 1: a plain low warehouse with a garage door.
    private static func smallWarehouseIcon(accent: SKColor) -> SKNode {
        let bodyRect = CGRect(x: -32, y: -28, width: 64, height: 26)
        let body = neonShape(rect: bodyRect, accent: accent)

        let container = SKNode()
        container.addChild(withGlow([body], color: accent))
        container.addChild(detail(rect: CGRect(x: -16, y: -28, width: 32, height: 18), fill: recessedAccent))
        return container
    }

    /// Tier 1, variant B: a loading depot — a wide low dock door instead of
    /// a centered garage door, same body proportions as `smallWarehouseIcon`.
    private static func smallDepotIcon(accent: SKColor) -> SKNode {
        let bodyRect = CGRect(x: -32, y: -28, width: 64, height: 26)
        let body = neonShape(rect: bodyRect, accent: accent)

        let container = SKNode()
        container.addChild(withGlow([body], color: accent))
        container.addChild(detail(rect: CGRect(x: -32, y: -28, width: 22, height: 14), fill: recessedAccent))
        container.addChild(detail(rect: CGRect(x: 6, y: -28, width: 22, height: 14), fill: recessedAccent))
        return container
    }

    /// Tier 2: a warehouse that's started producing something — one
    /// smokestack, one puff of smoke.
    private static func factoryIcon(accent: SKColor) -> SKNode {
        let bodyRect = CGRect(x: -30, y: -28, width: 60, height: 28)
        let body = neonShape(rect: bodyRect, accent: accent)
        let stack = neonShape(rect: CGRect(x: 6, y: 0, width: 12, height: 26), accent: accent, lineWidth: 1.5)

        let container = SKNode()
        container.addChild(withGlow([body, stack], color: accent))
        container.addChild(dot(radius: 8, at: CGPoint(x: 12, y: 34), fill: litAccent, stroke: accent))
        return container
    }

    /// Tier 3: a full factory — wider body, two stacks of different
    /// heights, more smoke.
    private static func bigFactoryIcon(accent: SKColor) -> SKNode {
        let bodyRect = CGRect(x: -38, y: -30, width: 76, height: 28)
        let body = neonShape(rect: bodyRect, accent: accent)
        let shortStack = neonShape(rect: CGRect(x: -22, y: -2, width: 12, height: 22), accent: accent, lineWidth: 1.5)
        let tallStack = neonShape(rect: CGRect(x: 6, y: -2, width: 12, height: 32), accent: accent, lineWidth: 1.5)

        let container = SKNode()
        container.addChild(withGlow([body, shortStack, tallStack], color: accent, blurRadius: 6))
        container.addChild(dot(radius: 7, at: CGPoint(x: -16, y: 24), fill: litAccent, stroke: accent))
        container.addChild(dot(radius: 9, at: CGPoint(x: 12, y: 38), fill: litAccent, stroke: accent))
        return container
    }

    // MARK: - Services & civic (single icon each — these don't grow)

    /// A badge: shield outline with a gold band and a glowing center rivet.
    private static func shieldIcon(accent: SKColor) -> SKNode {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -24, y: 28))
        path.addLine(to: CGPoint(x: 24, y: 28))
        path.addLine(to: CGPoint(x: 24, y: -6))
        path.addLine(to: CGPoint(x: 0, y: -32))
        path.addLine(to: CGPoint(x: -24, y: -6))
        path.closeSubpath()
        let badge = neonShape(path, accent: accent)

        let container = SKNode()
        container.addChild(withGlow([badge], color: accent))
        let gold = SKColor(srgbRed: 0.90, green: 0.75, blue: 0.25, alpha: 0.95)
        container.addChild(detail(rect: CGRect(x: -18, y: -4, width: 36, height: 10), fill: gold))
        container.addChild(dot(radius: 5, at: .zero, fill: litAccent, stroke: accent))
        return container
    }

    /// A torch: the same flame silhouette as before, with a smaller
    /// ember-colored flame nested inside for a two-tone look, and its own
    /// glow like every other icon.
    private static func torchIcon(accent: SKColor) -> SKNode {
        let outerFlame = neonShape(flamePath(scale: 1.0), accent: accent)
        let container = SKNode()
        container.addChild(withGlow([outerFlame], color: accent))
        let inner = neonShape(flamePath(scale: 0.55), accent: emberColor, fill: emberColor, lineWidth: 1.5)
        inner.position = CGPoint(x: 0, y: -3)
        container.addChild(withGlow([inner], color: emberColor, blurRadius: 4))
        return container
    }

    private static func flamePath(scale: CGFloat) -> CGPath {
        let points: [CGPoint] = [
            CGPoint(x: 0, y: 32), CGPoint(x: 18, y: -6), CGPoint(x: 9, y: -6),
            CGPoint(x: 9, y: -28), CGPoint(x: -9, y: -28), CGPoint(x: -9, y: -6), CGPoint(x: -18, y: -6),
        ]
        let path = CGMutablePath()
        path.move(to: CGPoint(x: points[0].x * scale, y: points[0].y * scale))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: point.x * scale, y: point.y * scale))
        }
        path.closeSubpath()
        return path
    }

    /// A bus: rounded body, a windshield band, two wheels.
    private static func transitIcon(accent: SKColor) -> SKNode {
        let bodyRect = CGRect(x: -30, y: -14, width: 60, height: 28)
        let body = neonShape(CGPath(roundedRect: bodyRect, cornerWidth: 8, cornerHeight: 8, transform: nil), accent: accent)

        let container = SKNode()
        container.addChild(withGlow([body], color: accent))
        container.addChild(detail(rect: CGRect(x: -24, y: 1, width: 48, height: 9), fill: litAccent))
        container.addChild(dot(radius: 6, at: CGPoint(x: -17, y: -17), fill: recessedAccent, stroke: accent))
        container.addChild(dot(radius: 6, at: CGPoint(x: 17, y: -17), fill: recessedAccent, stroke: accent))
        return container
    }

    /// A subway: a station entrance kiosk over a pair of rail tracks, not
    /// another wheeled vehicle — `.publicTransit`'s bus already owns that
    /// silhouette, and a track-and-tie motif reads as "rail" at a glance
    /// the way a second bus wouldn't distinguish itself from the first.
    private static func subwayIcon(accent: SKColor) -> SKNode {
        let kioskRect = CGRect(x: -22, y: -2, width: 44, height: 32)
        let kiosk = neonShape(CGPath(roundedRect: kioskRect, cornerWidth: 10, cornerHeight: 10, transform: nil), accent: accent)

        let container = SKNode()
        container.addChild(withGlow([kiosk], color: accent))
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

    /// A water tower: an elevated tank on three splayed support legs — the
    /// classic silhouette, built the same way the power plant's cooling
    /// towers are (the shared `trapezoid` primitive), just narrow-to-narrow
    /// rather than narrow-to-wide.
    private static func waterTowerIcon(accent: SKColor) -> SKNode {
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
        return container
    }

    /// A power plant: a base building with a hazard stripe and two
    /// trapezoidal cooling towers of different heights.
    private static func powerPlantIcon(accent: SKColor) -> SKNode {
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
        container.addChild(detail(rect: CGRect(x: -38, y: -10, width: 76, height: 6), fill: emberColor))
        return container
    }

    /// A stadium: an outer bowl, a track ring, a field, and four glowing
    /// corner floodlights.
    private static func stadiumIcon(accent: SKColor) -> SKNode {
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

        let field = SKShapeNode(ellipseOf: CGSize(width: 50, height: 30))
        field.fillColor = SKColor(srgbRed: 0.15, green: 0.85, blue: 0.55, alpha: 0.85) // neon turf, lit by the same floodlights
        field.strokeColor = .clear
        container.addChild(field)

        for (dx, dy): (CGFloat, CGFloat) in [(-40, 26), (40, 26), (-40, -26), (40, -26)] {
            container.addChild(dot(radius: 4, at: CGPoint(x: dx, y: dy), fill: litAccent, stroke: accent))
        }
        return container
    }
}
