import SpriteKit
import CoreGraphics

/// The shared drawing vocabulary every building renderer works in.
///
/// **What this used to be.** `ZoneIcon` drew every building in the game as a
/// front elevation, and carried the palette and primitives those drawings were
/// made from. The drawings are gone — buildings are described as
/// `BuildingMassing` and drawn by `IsometricBuilding` now — but the palette and
/// primitives are not, and they were always the more durable half: what makes a
/// lit window the same colour in a factory and a hospital, and what stops the
/// zones drifting into looking like three different games.
///
/// So this is `ZoneIcon` with the icons taken out, and the name says so.
enum NeonStyle {

    // MARK: - Sizing

    /// The smallest a detail may be, in design-space or tile-relative terms, if
    /// it is meant to be *seen* rather than merely present.
    ///
    /// **The rule that follows: if a mark cannot be drawn at least this big,
    /// cut it rather than shrink it.** Learned the expensive way — the art was
    /// first reviewed at the most zoomed-in view the camera has, which is the
    /// rarest one, and window grids, mullions, railing posts and frame lines
    /// that looked like detail there were a grey speckle at the size the game
    /// is actually played at. They did not add detail; they averaged every
    /// facade toward mud and muted the neon.
    ///
    /// It applies to geometry as well as to marks: a cylinder had sixteen sides
    /// for a chimney six points wide, and separate ring volumes for bands two
    /// points tall. Detail below the size it can be seen at is not detail, it
    /// is cost.
    static let minimumDetailSize: CGFloat = 9

    /// How hard a growable building's neon burns, by growth tier.
    ///
    /// Shared so a tier-2 shop and a tier-2 factory carry the same weight as
    /// each other and less than any tier-3 — the hierarchy has to be about
    /// *density*, not about which zone picked a brighter number. `liveliness`
    /// is a small per-building wobble on top, so a row of same-tier lots is not
    /// a row of identical lamps.
    ///
    /// Brightness is a channel because a night skyline is mostly dim with a few
    /// things blazing, and that contrast is most of what makes it look like
    /// night. It also survives distance better than shape: when the camera is
    /// far enough out that a silhouette has stopped resolving, how hard a
    /// building glows still reads.
    static func glowIntensity(forTier tier: Int, liveliness: CGFloat = 1) -> CGFloat {
        let base: CGFloat = [0.55, 0.78, 1.15][max(0, min(2, tier - 1))]
        return base * liveliness
    }

    // MARK: - Palette

    /// Every building's fill — near-black, so a building reads as a shape cut
    /// out of the night, lit only by its own neon. Consistent across every
    /// zone: the *glow colour*, not a different material, is what tells a house
    /// from a shop.
    static let silhouetteFill = SKColor(srgbRed: 0.05, green: 0.03, blue: 0.09, alpha: 1.0)

    /// Windows, shopfronts, lit panels — anything meant to read as lit up at
    /// night. The one element deliberately *not* coloured by the zone's accent:
    /// a lit window glows the same cool cyan-white whatever building it is
    /// punched into, so light reads as its own kind of thing rather than as a
    /// paler version of the building's neon.
    static let litAccent = SKColor(srgbRed: 0.55, green: 0.98, blue: 1.0, alpha: 0.95)

    /// Two hues, not three. A third, dimmer, desaturated "cool white" used to
    /// sit here, and across a facade of small panes it averaged the whole grid
    /// toward grey — the opposite of what a neon look wants. Cool and warm
    /// alone still say "different tenants, different bulbs" while keeping every
    /// pane fully saturated.
    static let windowPalette: [SKColor] = [
        litAccent,
        SKColor(srgbRed: 1.0, green: 0.86, blue: 0.48, alpha: 0.98),  // warm incandescent
    ]

    /// Which window colour a given pane takes — a fixed formula on its own
    /// row/column (plus `salt`, so two grids on one building don't repeat the
    /// same pattern), not real randomness, for the same "a lot must look the
    /// same on every launch" reason `BuildingRandom` documents.
    static func windowColor(row: Int, column: Int, salt: Int = 0) -> SKColor {
        windowPalette[abs(row * 11 + column * 7 + salt) % windowPalette.count]
    }

    /// Doors, loading bays, recesses — anything that should read as the
    /// darkest, most recessed part of a shape, darker even than
    /// `silhouetteFill`.
    static let recessedAccent = SKColor.black.withAlphaComponent(0.75)

    /// Warm orange, for hazard marks and nothing else — a fixed "attention"
    /// colour rather than a zone accent.
    static let emberColor = SKColor(srgbRed: 1.0, green: 0.45, blue: 0.15, alpha: 0.95)

    /// Sodium-lamp amber, for construction scaffolding and nothing else.
    /// Warmer and dimmer than `emberColor` on purpose: a building site is a
    /// "this is happening" mark, not a "something is wrong" one, and the two
    /// have to be distinguishable at a glance from across the map.
    static let scaffoldColor = SKColor(srgbRed: 1.0, green: 0.78, blue: 0.32, alpha: 0.95)

    /// The mixed-neon-signage look a dense night skyline has: plaques and
    /// marquees in a handful of hot colours, not one fixed hue the way every
    /// window already reads.
    static let signPalette: [SKColor] = [
        SKColor(srgbRed: 0.0, green: 0.95, blue: 1.0, alpha: 0.95),   // electric cyan
        SKColor(srgbRed: 1.0, green: 0.15, blue: 0.55, alpha: 0.95),  // hot magenta
        SKColor(srgbRed: 1.0, green: 0.75, blue: 0.20, alpha: 0.95),  // amber
    ]

    /// Which sign colour a plaque glows, mixed deterministically off the
    /// building's own anchor position, plus a `salt` so a building with more
    /// than one sign doesn't repeat itself.
    static func signColor(for seed: GridPosition, salt: Int = 0) -> SKColor {
        signPalette[abs(seed.x &* 17 &+ seed.y &* 13 &+ salt) % signPalette.count]
    }

    // MARK: - Primitives

    /// A rect with no outline — for lit panels and recesses layered onto a
    /// surface that already has its own neon edge, so details don't each grow a
    /// second competing outline.
    static func detail(rect: CGRect, fill: SKColor) -> SKShapeNode {
        let node = SKShapeNode(rect: rect)
        node.fillColor = fill
        node.strokeColor = .clear
        return node
    }

    /// A soft-edged bright copy of `shapes` behind them, which is what makes
    /// neon read as neon rather than as a coloured outline.
    ///
    /// `shouldRasterize` caches the blurred result as a texture rather than
    /// re-running the filter every frame. `intensity` scales the halo's weight
    /// and opacity — see `glowIntensity(forTier:liveliness:)` for why
    /// brightness is a channel.
    static func withGlow(
        _ shapes: [SKShapeNode],
        color: SKColor,
        blurRadius: CGFloat = 7,
        intensity: CGFloat = 1
    ) -> SKNode {
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
            glowCopy.lineWidth = 7 * max(0.4, intensity)
            glowCopy.alpha = min(1, 0.9 * intensity)
            glowLayer.addChild(glowCopy)
        }
        container.addChild(glowLayer)  // added first -> renders behind everything after it
        shapes.forEach(container.addChild)
        return container
    }

    /// A soft radial-gradient sprite, white fading to transparent, generated
    /// once and tinted per use.
    ///
    /// Not an `SKEffectNode` blur: the ground glow and road network glow can
    /// cover a large fraction of the map, far more tiles than the handful of
    /// buildings that ever get a real blur pass, so a per-tile Core Image
    /// filter there would be a genuine frame-rate risk. Tinting one shared
    /// texture and blending it additively gets the same "glowing" read at a
    /// fraction of the cost.
    static let glowTexture: SKTexture = {
        let diameter = 64
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: diameter, height: diameter, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return SKTexture() }

        let components: [CGFloat] = [1, 1, 1, 0.85, 1, 1, 1, 0]
        guard let gradient = CGGradient(colorSpace: colorSpace, colorComponents: components,
                                        locations: [0, 1], count: 2) else {
            return SKTexture()
        }
        let centre = CGPoint(x: CGFloat(diameter) / 2, y: CGFloat(diameter) / 2)
        context.drawRadialGradient(gradient, startCenter: centre, startRadius: 0,
                                   endCenter: centre, endRadius: CGFloat(diameter) / 2, options: [])
        guard let image = context.makeImage() else { return SKTexture() }
        return SKTexture(cgImage: image)
    }()
}
