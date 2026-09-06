import SpriteKit
import CoreImage

/// Procedural silhouettes drawn on top of a building's base color — still
/// graybox (no image assets), but with real depth: a soft blurred drop
/// shadow behind each icon's main silhouette, and a light/shadow edge
/// treatment on flat rectangular bodies faking a light source from above.
/// Neither needs a gradient (`SKShapeNode` can't fill with one) or a custom
/// shader — a blurred duplicate shape and two thin accent strips get most
/// of the visual benefit for a fraction of the risk, which matters here
/// since this project has no way to preview a render before shipping it.
///
/// Multi-tone palette (walls, roof, glass, dark accents) instead of one
/// flat color, and distinct geometry per *growth tier* for the three zones
/// that grow: a residential lot looks different at density 2 than at
/// density 5, not just brighter.
///
/// Every shape is still built only from straight lines, rectangles, and
/// circles/ellipses — no hand-tuned bezier curves — for the same reason as
/// the shading choices above: simple enough to get right from coordinates
/// alone, with nothing to preview.
///
/// Each icon is authored in a fixed design space, `designSize` points on a
/// side, centered on `(0, 0)`. `TileRenderer` scales the returned node to
/// whatever the actual sprite needs.
enum ZoneIcon {

    /// The width/height of the square each icon is designed to fit inside.
    static let designSize: CGFloat = 100

    /// `nil` for zones that don't get an icon: `.empty` (nothing to draw)
    /// and `.road` (a flat color reads as an uninterrupted line of road) —
    /// and for a growable zone at density 0 (just zoned, nothing built yet;
    /// the icon appearing at all is itself part of the signal that
    /// something now stands here).
    static func makeNode(for zone: ZoneType, density: Int) -> SKNode? {
        switch zone {
        case .empty, .road:
            return nil
        case .residential:
            switch growthTier(for: density) {
            case 0: return nil
            case 1: return smallHouseIcon()
            case 2: return mediumHouseIcon()
            default: return largeHousingIcon()
            }
        case .commercial:
            switch growthTier(for: density) {
            case 0: return nil
            case 1: return smallShopIcon()
            case 2: return midriseOfficeIcon()
            default: return towerIcon()
            }
        case .industrial:
            switch growthTier(for: density) {
            case 0: return nil
            case 1: return smallWarehouseIcon()
            case 2: return factoryIcon()
            default: return bigFactoryIcon()
            }
        case .policeStation: return shieldIcon()
        case .fireStation: return torchIcon()
        case .publicTransit: return transitIcon()
        case .powerPlant: return powerPlantIcon()
        case .stadium: return stadiumIcon()
        }
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

    /// Warm off-white — every building's "wall" color, consistent across
    /// zones so the *shape* (not a different material color) is what
    /// distinguishes a house from a shop.
    private static let wallColor = SKColor(white: 0.97, alpha: 0.92)
    private static let outlineColor = SKColor.black.withAlphaComponent(0.45)

    /// Roof/trim color for residential — warm terracotta, distinct from
    /// every zone's own base color so it doesn't disappear into whichever
    /// one it's drawn on.
    private static let roofColor = SKColor(srgbRed: 0.58, green: 0.30, blue: 0.20, alpha: 0.95)

    /// Pale blue-glass color for windows on commercial/office buildings.
    private static let glassColor = SKColor(srgbRed: 0.72, green: 0.86, blue: 0.95, alpha: 0.92)

    /// Dark accent for doors, wheels, smokestacks, badge details — anything
    /// that should read as "the darkest part of this shape."
    private static let darkAccent = SKColor.black.withAlphaComponent(0.55)

    /// Warm orange, used only for fire's inner flame and power plant's
    /// hazard stripe — the one accent color reserved for "attention."
    private static let emberColor = SKColor(srgbRed: 1.0, green: 0.55, blue: 0.15, alpha: 0.95)

    private static let highlightColor = SKColor.white.withAlphaComponent(0.4)
    private static let shadowEdgeColor = SKColor.black.withAlphaComponent(0.22)

    private static func shape(_ path: CGPath, fill: SKColor = wallColor, stroke: SKColor = outlineColor, lineWidth: CGFloat = 2) -> SKShapeNode {
        let node = SKShapeNode(path: path)
        node.fillColor = fill
        node.strokeColor = stroke
        node.lineWidth = lineWidth
        return node
    }

    private static func shape(rect: CGRect, fill: SKColor = wallColor, stroke: SKColor = outlineColor, lineWidth: CGFloat = 2) -> SKShapeNode {
        shape(CGPath(rect: rect, transform: nil), fill: fill, stroke: stroke, lineWidth: lineWidth)
    }

    /// A rect with no outline — used for window/accent details layered on
    /// top of a body shape that already has its own stroke, so details
    /// don't each grow a second competing outline.
    private static func detail(rect: CGRect, fill: SKColor) -> SKShapeNode {
        shape(rect: rect, fill: fill, stroke: .clear, lineWidth: 0)
    }

    private static func peakedRoofPath(left: CGFloat, right: CGFloat, base: CGFloat, peak: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: left, y: base))
        path.addLine(to: CGPoint(x: right, y: base))
        path.addLine(to: peak)
        path.closeSubpath()
        return path
    }

    /// A four-point polygon — used for the power plant's cooling towers
    /// (narrower at the top than the bottom), built from lines only.
    private static func trapezoid(bottomLeft: CGPoint, bottomRight: CGPoint, topRight: CGPoint, topLeft: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: bottomLeft)
        path.addLine(to: bottomRight)
        path.addLine(to: topRight)
        path.addLine(to: topLeft)
        path.closeSubpath()
        return path
    }

    // MARK: - Depth: shadows and edge shading

    /// Duplicates `shapes` in solid black, blurs the duplicates, and places
    /// them behind the originals with a small down-and-right offset — a
    /// soft drop shadow, as if lit from the upper left. Only the *primary*
    /// silhouette shapes (a body, a roof, a stack) go through this; small
    /// details (a window, a wheel) don't get their own shadow copy, since
    /// dozens of tiny blurred rects would read as noise, not depth.
    ///
    /// `shouldRasterize = true` caches the blurred result as a texture the
    /// first time it renders rather than re-running the blur every frame —
    /// standard practice for static content, and worth being deliberate
    /// about here specifically: a city map can have hundreds of these
    /// icons on screen simultaneously, and an unrasterized Core Image blur
    /// on all of them at once would be a real frame-rate risk, not a
    /// theoretical one.
    private static func withShadow(_ shapes: [SKShapeNode], offset: CGPoint = CGPoint(x: 2.5, y: -3.5), blurRadius: CGFloat = 3) -> SKNode {
        let container = SKNode()

        let shadowLayer = SKEffectNode()
        shadowLayer.shouldRasterize = true
        let blur = CIFilter(name: "CIGaussianBlur")
        blur?.setValue(blurRadius, forKey: "inputRadius")
        shadowLayer.filter = blur
        shadowLayer.position = offset
        for original in shapes {
            guard let path = original.path else { continue }
            let shadowCopy = SKShapeNode(path: path)
            shadowCopy.fillColor = .black
            shadowCopy.strokeColor = .clear
            shadowCopy.alpha = 0.32
            shadowLayer.addChild(shadowCopy)
        }
        container.addChild(shadowLayer) // added first -> renders behind everything after it

        for shape in shapes {
            container.addChild(shape)
        }
        return container
    }

    /// A thin lighter strip along a rect's top edge and a thin darker strip
    /// along its bottom edge — flat-shading stand-in for a gradient,
    /// suggesting a light source from directly above without needing one
    /// `SKShapeNode` can't fill with anyway. Applied to the primary body
    /// rects (walls, warehouse fronts, tower shafts); triangular roofs and
    /// small details are left flat rather than clipping a strip to a
    /// non-rectangular silhouette.
    private static func edgeShading(for rect: CGRect) -> SKNode {
        let container = SKNode()
        container.addChild(detail(rect: CGRect(x: rect.minX, y: rect.maxY - 3, width: rect.width, height: 3), fill: highlightColor))
        container.addChild(detail(rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 3), fill: shadowEdgeColor))
        return container
    }

    /// A small pale circle offset toward the upper-left inside a larger
    /// one — the "glossy sphere" highlight trick, used only on the bigger
    /// circular details (smoke puffs, a badge's center rivet) where it's
    /// large enough to actually read; small window dots skip it.
    private static func glintDot(radius: CGFloat, at point: CGPoint, fill: SKColor) -> SKNode {
        let container = SKNode()
        let base = SKShapeNode(circleOfRadius: radius)
        base.position = point
        base.fillColor = fill
        base.strokeColor = outlineColor
        base.lineWidth = 1.5
        container.addChild(base)
        let glint = SKShapeNode(circleOfRadius: radius * 0.35)
        glint.position = CGPoint(x: point.x - radius * 0.35, y: point.y + radius * 0.35)
        glint.fillColor = highlightColor
        glint.strokeColor = .clear
        container.addChild(glint)
        return container
    }

    private static func dot(radius: CGFloat, at point: CGPoint, fill: SKColor) -> SKShapeNode {
        let node = SKShapeNode(circleOfRadius: radius)
        node.position = point
        node.fillColor = fill
        node.strokeColor = outlineColor
        node.lineWidth = 1.5
        return node
    }

    // MARK: - Residential (3 tiers)

    /// Tier 1 (density 1–2): a single-story cottage — body, peaked roof,
    /// one door.
    private static func smallHouseIcon() -> SKNode {
        let bodyRect = CGRect(x: -24, y: -30, width: 48, height: 28)
        let body = shape(rect: bodyRect)
        let roof = shape(peakedRoofPath(left: -28, right: 28, base: -2, peak: CGPoint(x: 0, y: 26)), fill: roofColor)

        let container = SKNode()
        container.addChild(withShadow([body, roof]))
        container.addChild(edgeShading(for: bodyRect))
        container.addChild(detail(rect: CGRect(x: -6, y: -30, width: 12, height: 16), fill: darkAccent))
        return container
    }

    /// Tier 2 (density 3–4): a taller two-story house with upstairs windows.
    private static func mediumHouseIcon() -> SKNode {
        let bodyRect = CGRect(x: -26, y: -32, width: 52, height: 42)
        let body = shape(rect: bodyRect)
        let roof = shape(peakedRoofPath(left: -30, right: 30, base: 10, peak: CGPoint(x: 0, y: 32)), fill: roofColor)

        let container = SKNode()
        container.addChild(withShadow([body, roof]))
        container.addChild(edgeShading(for: bodyRect))
        container.addChild(detail(rect: CGRect(x: -7, y: -32, width: 14, height: 16), fill: darkAccent))
        container.addChild(detail(rect: CGRect(x: -21, y: -6, width: 12, height: 12), fill: glassColor))
        container.addChild(detail(rect: CGRect(x: 9, y: -6, width: 12, height: 12), fill: glassColor))
        return container
    }

    /// Tier 3 (density 5): fully developed — two houses side by side, the
    /// clearest "this lot is built out" silhouette of the three tiers.
    private static func largeHousingIcon() -> SKNode {
        let leftBodyRect = CGRect(x: -42, y: -30, width: 32, height: 30)
        let leftBody = shape(rect: leftBodyRect)
        let leftRoof = shape(peakedRoofPath(left: -44, right: -8, base: 0, peak: CGPoint(x: -26, y: 20)), fill: roofColor)

        let rightBodyRect = CGRect(x: 6, y: -30, width: 36, height: 36)
        let rightBody = shape(rect: rightBodyRect)
        let rightRoof = shape(peakedRoofPath(left: 4, right: 44, base: 6, peak: CGPoint(x: 24, y: 28)), fill: roofColor)

        let container = SKNode()
        container.addChild(withShadow([leftBody, leftRoof, rightBody, rightRoof]))
        container.addChild(edgeShading(for: leftBodyRect))
        container.addChild(edgeShading(for: rightBodyRect))
        container.addChild(detail(rect: CGRect(x: -32, y: -18, width: 10, height: 10), fill: glassColor))
        container.addChild(detail(rect: CGRect(x: 14, y: -30, width: 12, height: 16), fill: darkAccent))
        container.addChild(detail(rect: CGRect(x: 30, y: -10, width: 10, height: 10), fill: glassColor))
        return container
    }

    // MARK: - Commercial (3 tiers)

    /// Tier 1: a single-story storefront with an awning and a display window.
    private static func smallShopIcon() -> SKNode {
        let bodyRect = CGRect(x: -28, y: -28, width: 56, height: 32)
        let body = shape(rect: bodyRect)
        let awning = shape(rect: CGRect(x: -30, y: 4, width: 60, height: 8), fill: outlineColor, stroke: .clear)

        let container = SKNode()
        container.addChild(withShadow([body, awning]))
        container.addChild(edgeShading(for: bodyRect))
        container.addChild(detail(rect: CGRect(x: -20, y: -22, width: 40, height: 20), fill: glassColor))
        return container
    }

    /// Tier 2: a mid-rise office — taller body, a grid of windows, a flat
    /// roof cap.
    private static func midriseOfficeIcon() -> SKNode {
        let bodyRect = CGRect(x: -26, y: -30, width: 52, height: 50)
        let body = shape(rect: bodyRect)
        let roofCap = shape(rect: CGRect(x: -28, y: 20, width: 56, height: 6), fill: outlineColor, stroke: .clear)

        let container = SKNode()
        container.addChild(withShadow([body, roofCap]))
        container.addChild(edgeShading(for: bodyRect))
        for row in 0 ..< 2 {
            for column in 0 ..< 3 {
                let point = CGPoint(x: -18 + CGFloat(column) * 18, y: -18 + CGFloat(row) * 20)
                container.addChild(detail(rect: CGRect(x: point.x, y: point.y, width: 10, height: 10), fill: glassColor))
            }
        }
        return container
    }

    /// Tier 3: a high-rise tower — tall and narrow, a denser window grid,
    /// a rooftop antenna.
    private static func towerIcon() -> SKNode {
        let bodyRect = CGRect(x: -20, y: -34, width: 40, height: 66)
        let body = shape(rect: bodyRect)
        let antenna = shape(rect: CGRect(x: -2, y: 32, width: 4, height: 16), fill: outlineColor)

        let container = SKNode()
        container.addChild(withShadow([body, antenna]))
        container.addChild(edgeShading(for: bodyRect))
        for row in 0 ..< 4 {
            for column in 0 ..< 2 {
                let point = CGPoint(x: -13 + CGFloat(column) * 16, y: -26 + CGFloat(row) * 14)
                container.addChild(detail(rect: CGRect(x: point.x, y: point.y, width: 9, height: 9), fill: glassColor))
            }
        }
        return container
    }

    // MARK: - Industrial (3 tiers)

    /// Tier 1: a plain low warehouse with a garage door.
    private static func smallWarehouseIcon() -> SKNode {
        let bodyRect = CGRect(x: -32, y: -28, width: 64, height: 26)
        let body = shape(rect: bodyRect)

        let container = SKNode()
        container.addChild(withShadow([body]))
        container.addChild(edgeShading(for: bodyRect))
        container.addChild(detail(rect: CGRect(x: -16, y: -28, width: 32, height: 18), fill: darkAccent))
        return container
    }

    /// Tier 2: a warehouse that's started producing something — one
    /// smokestack, one puff of smoke.
    private static func factoryIcon() -> SKNode {
        let bodyRect = CGRect(x: -30, y: -28, width: 60, height: 28)
        let body = shape(rect: bodyRect)
        let stack = shape(rect: CGRect(x: 6, y: 0, width: 12, height: 26), fill: darkAccent)

        let container = SKNode()
        container.addChild(withShadow([body, stack]))
        container.addChild(edgeShading(for: bodyRect))
        container.addChild(glintDot(radius: 8, at: CGPoint(x: 12, y: 34), fill: wallColor))
        return container
    }

    /// Tier 3: a full factory — wider body, two stacks of different
    /// heights, more smoke.
    private static func bigFactoryIcon() -> SKNode {
        let bodyRect = CGRect(x: -38, y: -30, width: 76, height: 28)
        let body = shape(rect: bodyRect)
        let shortStack = shape(rect: CGRect(x: -22, y: -2, width: 12, height: 22), fill: darkAccent)
        let tallStack = shape(rect: CGRect(x: 6, y: -2, width: 12, height: 32), fill: darkAccent)

        let container = SKNode()
        container.addChild(withShadow([body, shortStack, tallStack]))
        container.addChild(edgeShading(for: bodyRect))
        container.addChild(glintDot(radius: 7, at: CGPoint(x: -16, y: 24), fill: wallColor))
        container.addChild(glintDot(radius: 9, at: CGPoint(x: 12, y: 38), fill: wallColor))
        return container
    }

    // MARK: - Services & civic (single icon each — these don't grow)

    /// A badge: shield outline with a gold band and a glinting center rivet.
    private static func shieldIcon() -> SKNode {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -24, y: 28))
        path.addLine(to: CGPoint(x: 24, y: 28))
        path.addLine(to: CGPoint(x: 24, y: -6))
        path.addLine(to: CGPoint(x: 0, y: -32))
        path.addLine(to: CGPoint(x: -24, y: -6))
        path.closeSubpath()
        let badge = shape(path)

        let container = SKNode()
        container.addChild(withShadow([badge]))
        let gold = SKColor(srgbRed: 0.80, green: 0.65, blue: 0.20, alpha: 0.95)
        container.addChild(detail(rect: CGRect(x: -18, y: -4, width: 36, height: 10), fill: gold))
        container.addChild(glintDot(radius: 5, at: .zero, fill: wallColor))
        return container
    }

    /// A torch: the same flame silhouette as before, with a smaller
    /// ember-colored flame nested inside for a two-tone look, and its own
    /// drop shadow like every other icon.
    private static func torchIcon() -> SKNode {
        let outerFlame = shape(flamePath(scale: 1.0))
        let container = SKNode()
        container.addChild(withShadow([outerFlame]))
        let inner = shape(flamePath(scale: 0.55), fill: emberColor, stroke: .clear)
        inner.position = CGPoint(x: 0, y: -3)
        container.addChild(inner)
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
    private static func transitIcon() -> SKNode {
        let bodyRect = CGRect(x: -30, y: -14, width: 60, height: 28)
        let body = shape(CGPath(roundedRect: bodyRect, cornerWidth: 8, cornerHeight: 8, transform: nil))

        let container = SKNode()
        container.addChild(withShadow([body]))
        container.addChild(detail(rect: CGRect(x: -24, y: 1, width: 48, height: 9), fill: glassColor))
        container.addChild(dot(radius: 6, at: CGPoint(x: -17, y: -17), fill: darkAccent))
        container.addChild(dot(radius: 6, at: CGPoint(x: 17, y: -17), fill: darkAccent))
        return container
    }

    /// A power plant: a base building with a hazard stripe and two
    /// trapezoidal cooling towers of different heights.
    private static func powerPlantIcon() -> SKNode {
        let baseRect = CGRect(x: -38, y: -34, width: 76, height: 24)
        let base = shape(rect: baseRect)
        let towerA = shape(trapezoid(
            bottomLeft: CGPoint(x: -24, y: -4), bottomRight: CGPoint(x: -6, y: -4),
            topRight: CGPoint(x: -9, y: 24), topLeft: CGPoint(x: -21, y: 24)
        ))
        let towerB = shape(trapezoid(
            bottomLeft: CGPoint(x: 2, y: -4), bottomRight: CGPoint(x: 24, y: -4),
            topRight: CGPoint(x: 20, y: 34), topLeft: CGPoint(x: 6, y: 34)
        ))

        let container = SKNode()
        container.addChild(withShadow([base, towerA, towerB]))
        container.addChild(edgeShading(for: baseRect))
        container.addChild(detail(rect: CGRect(x: -38, y: -10, width: 76, height: 6), fill: emberColor))
        return container
    }

    /// A stadium: an outer bowl, a track ring, a grass-colored field, and
    /// four corner light towers.
    private static func stadiumIcon() -> SKNode {
        let bowlShape = SKShapeNode(ellipseOf: CGSize(width: 88, height: 62))
        bowlShape.fillColor = wallColor
        bowlShape.strokeColor = outlineColor
        bowlShape.lineWidth = 3

        let container = SKNode()
        container.addChild(withShadow([bowlShape], offset: CGPoint(x: 3, y: -4), blurRadius: 4))

        let track = SKShapeNode(ellipseOf: CGSize(width: 66, height: 44))
        track.fillColor = .clear
        track.strokeColor = darkAccent
        track.lineWidth = 2
        container.addChild(track)

        let field = SKShapeNode(ellipseOf: CGSize(width: 50, height: 30))
        field.fillColor = SKColor(srgbRed: 0.30, green: 0.58, blue: 0.28, alpha: 0.9)
        field.strokeColor = .clear
        container.addChild(field)

        for (dx, dy): (CGFloat, CGFloat) in [(-40, 26), (40, 26), (-40, -26), (40, -26)] {
            container.addChild(shape(rect: CGRect(x: dx - 2, y: dy - 2, width: 4, height: 14), fill: darkAccent, stroke: .clear))
        }
        return container
    }
}
