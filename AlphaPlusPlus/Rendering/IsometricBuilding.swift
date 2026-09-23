import SpriteKit

/// Draws a `BuildingMassing` in isometric.
///
/// This is the half of the split that knows about pixels. A generator decides
/// what a building *is*; this decides what that looks like from the game's
/// camera — which faces are visible, how each is lit, and what order they are
/// painted in.
enum IsometricBuilding {

    /// How far a face is tinted from the silhouette's near-black toward the
    /// zone's neon, at its darkest and its brightest.
    ///
    /// The range matters more than either end. Too narrow and a box reads as a
    /// flat hexagon; too wide and the fills start competing with the neon
    /// edges, which is the same mistake the flat tile palette made one level
    /// up. Faces stay dark and the *creases* stay bright.
    /// Projected area, in square points, below which a face is not worth
    /// giving its own blurred copy in the glow pass.
    private static let glowAreaFloor: CGFloat = 40

    private static let minimumTint: CGFloat = 0.07
    private static let maximumTint: CGFloat = 0.34

    /// How much of the building is worth drawing.
    ///
    /// `NeonStyle.minimumDetailSize` cuts any mark that cannot be drawn about
    /// nine points across, and that floor was set against the size a lot is
    /// at **rest** — 63 points for a 2×2. It is the right floor there and the
    /// wrong one with the camera all the way in, where the same lot is 126
    /// points across 252 physical pixels on a Retina display: a mark dropped
    /// for being four points wide would have arrived at sixteen.
    ///
    /// So the marks the generators dropped are not gone, they are *deferred*.
    /// `.near` puts back the two this project recorded losing by name — the
    /// storey slab line and the glazing mullion — and derives both from the
    /// panels already on the building rather than inventing them, so a ledge
    /// lands under a row of windows instead of at a spacing nobody chose.
    ///
    /// **It is a second texture, not a second code path**, and that is the
    /// whole reason it is affordable. The building stays one sprite out of
    /// `IsoTextureCache`; `.near` is one more dimension of its key. Every
    /// property the cache exists for survives — no shape nodes in the scene,
    /// one node per building, and no `SKEffectNode` per lot, which a "draw it
    /// as vectors when you are close" version would have needed twenty of and
    /// which this project has twice watched a scene silently stop servicing.
    enum Detail { case standard, near }

    /// How wide a pane wants to be, in points, before a mullion is put
    /// between it and the next one. About 56 physical pixels at the closest
    /// camera on a Retina display — chunky, because a mullion finer than this
    /// is the grey speckle `minimumDetailSize` was written to delete.
    private static let paneWidth: CGFloat = 14

    /// Thickness of a mullion and of a slab line, in points.
    private static let hairline: CGFloat = 1.5

    static func node(
        for massing: BuildingMassing,
        accent: SKColor,
        tier: Int,
        in projection: Isometric,
        detail: Detail = .standard
    ) -> SKNode {
        let container = SKNode()

        /// Solids and panels are sorted *together* rather than drawn in two
        /// passes. Drawing every panel after every solid is the obvious
        /// implementation and it is wrong: a window on a far building's wall
        /// would paint over a near building standing in front of it.
        enum Item {
            case solid(Solid)
            case panel(Panel)

            var depth: (CGFloat, CGFloat) {
                switch self {
                case .solid(let solid): return solid.volume.depth
                case .panel(let panel): return panel.depth
                }
            }
        }

        // SpriteKit draws what it drew before detail tiers existed: the near
        // and street tiers are the Metal renderer's (`DetailTier`).
        let shown = massing.drawn(at: .standard)
        let items = Isometric.sorted(
            shown.solids.map(Item.solid) + shown.panels.map(Item.panel),
            depth: { $0.depth }
        )

        // One glow pass for the whole building, not one per volume. Every
        // `withGlow` is an `SKEffectNode` running a Gaussian blur, and the
        // contact sheet has already shown twice that a scene quietly stops
        // servicing them past a budget — a building made of five boxes must
        // not cost five of them.
        var glowShapes: [SKShapeNode] = []
        var content: [SKNode] = []
        /// Which (box, face, height) rows have already had their slab line.
        var ledged: Set<String> = []

        for item in items {
            switch item {
            case .solid(let solid):
                let color: SKColor
                let fillTint: (CGFloat) -> SKColor
                switch solid.style {
                case .structure:
                    color = accent
                    fillTint = { shade in
                        let amount = minimumTint + (maximumTint - minimumTint) * shade
                        return NeonStyle.silhouetteFill.blended(withFraction: amount, of: accent)
                            ?? NeonStyle.silhouetteFill
                    }
                case .lit(let litColor):
                    color = litColor
                    // Dimmer than it wants to be. A lit solid's *top* face is a
                    // full-footprint quad pointing straight at the camera, so
                    // at anything near full opacity a crown band stops reading
                    // as a glowing edge and becomes a bright plate sitting on
                    // the tower. The glow pass is what should sell it.
                    fillTint = { shade in litColor.withAlphaComponent(0.34 + 0.3 * shade) }
                }

                for face in solid.volume.faces where Isometric.isVisible(face) {
                    let shape = SKShapeNode(path: projection.path(face.points))
                    shape.fillColor = fillTint(Isometric.shade(face))
                    shape.strokeColor = color
                    shape.lineWidth = 2
                    content.append(shape)

                    // Only faces big enough to matter contribute to the halo.
                    // A cylinder is a ten-sided prism, so a chimney alone would
                    // otherwise add six blurred slivers a couple of points wide
                    // — invisible after a 7-point blur, and each one a node.
                    let bounds = shape.path!.boundingBox
                    if bounds.width * bounds.height > glowAreaFloor {
                        let glowCopy = SKShapeNode(path: shape.path!)
                        glowCopy.fillColor = color
                        glowCopy.strokeColor = color
                        glowShapes.append(glowCopy)
                    }
                }

            case .panel(let panel):
                let shape = SKShapeNode(path: projection.path(panel.corners))
                shape.fillColor = panel.color
                shape.strokeColor = .clear
                content.append(shape)

                guard detail == .near else { continue }

                // Appended immediately after the panel they mark rather than
                // gathered into a pass of their own. A mullion sits on its own
                // pane and a slab line under its own row, so both tie every
                // sort key the parent has — and this project has already lost
                // a hospital's cross to exactly that tie. Riding with the
                // parent makes the order a fact rather than a coincidence.
                for mark in nearDetail(on: panel, accent: accent, in: projection, ledged: &ledged) {
                    let bar = SKShapeNode(path: projection.path(mark.corners))
                    bar.fillColor = mark.color
                    bar.strokeColor = .clear
                    content.append(bar)
                }
            }
        }

        container.addChild(glowLayer(
            glowShapes,
            intensity: NeonStyle.glowIntensity(forTier: tier)
        ))
        content.forEach(container.addChild)
        massing.badges.forEach { container.addChild(node(for: $0, in: projection)) }
        return container
    }

    // MARK: - Near detail

    /// The marks a panel gains up close: mullions across it, and — once per
    /// row, tracked in `ledged` — the slab line under it. **Shared by both
    /// renderers**: the Metal renderer draws these same panels as geometry,
    /// so a facade comes apart into the same panes whichever one is drawing.
    static func nearDetail(on panel: Panel, accent: SKColor, in projection: Isometric,
                           ledged: inout Set<String>) -> [Panel] {
        var marks = mullions(on: panel, in: projection)
        let row = ledgeKey(for: panel)
        if !ledged.contains(row) {
            ledged.insert(row)
            marks.append(slabLine(under: panel, accent: accent, in: projection))
        }
        return marks
    }

    /// How long a panel is across its own face, in points.
    private static func widthInPoints(of panel: Panel, in projection: Isometric) -> CGFloat {
        let corners = panel.corners
        let a = projection.project(corners[0])
        let b = projection.project(corners[1])
        return hypot(b.x - a.x, b.y - a.y)
    }

    /// Vertical divisions across a wide lit panel.
    ///
    /// A glazing band is one unbroken slab of light because that is what
    /// survives being 63 points across; at four times that it reads as a
    /// painted stripe, because a real facade has panes in it. The count comes
    /// from the panel's **projected** width rather than its width in tile
    /// units, so a band on a narrow tower and one on a wide hall both end up
    /// with panes the same size on screen.
    private static func mullions(on panel: Panel, in projection: Isometric) -> [Panel] {
        let across = widthInPoints(of: panel, in: projection)
        let panes = Int((across / paneWidth).rounded())
        guard panes >= 2 else { return [] }

        // `u` is a fraction of the whole box, not of the panel, so a width in
        // points converts through the panel's own span.
        let span = panel.u1 - panel.u0
        let bar = hairline * span / across
        return (1 ..< panes).map { index in
            let centre = panel.u0 + span * CGFloat(index) / CGFloat(panes)
            var mullion = panel
            mullion.u0 = centre - bar / 2
            mullion.u1 = centre + bar / 2
            mullion.color = NeonStyle.silhouetteFill.withAlphaComponent(0.85)
            return mullion
        }
    }

    /// The floor slab a row of windows sits on.
    ///
    /// Drawn in the building's accent rather than in the silhouette, which is
    /// the correction this project already wrote down once: the elevation
    /// version of this mark was "3-point storey slab lines (near-black on
    /// near-black)" and it was cut for being invisible. A slab edge catches
    /// the light the creases catch.
    private static func slabLine(under panel: Panel, accent: SKColor,
                                 in projection: Isometric) -> Panel {
        let thickness = hairline / (projection.heightUnit * max(panel.box.height, 0.01))
        var ledge = panel
        ledge.u0 = 0
        ledge.u1 = 1
        ledge.v0 = max(0, panel.v0 - thickness)
        ledge.v1 = max(0, panel.v0)
        ledge.color = accent.withAlphaComponent(0.42)
        return ledge
    }

    /// Identifies the row a panel belongs to, so a band of eight windows gets
    /// one slab line rather than eight stacked on each other.
    private static func ledgeKey(for panel: Panel) -> String {
        let box = panel.box
        func r(_ value: CGFloat) -> Int { Int((value * 1000).rounded()) }
        return "\(r(box.x))|\(r(box.y))|\(r(box.z))|\(r(box.height))"
            + "|\(panel.face == .right ? "r" : "l")|\(r(panel.v0))"
    }

    /// A blurred copy of every visible face, behind everything.
    ///
    /// Deliberately not `NeonStyle.withGlow`, which adds its glow and then its
    /// shapes as one unit. Here the glow has to sit behind the *whole*
    /// building while the faces themselves stay interleaved with the panels in
    /// depth order, so the two have to be built separately.
    private static func glowLayer(_ shapes: [SKShapeNode], intensity: CGFloat) -> SKNode {
        let layer = SKEffectNode()
        layer.shouldRasterize = true
        let blur = CIFilter(name: "CIGaussianBlur")
        // **The baked halo comes down now that the frame blooms.**
        //
        // This blur is the *whole* glow a building had: a blurred copy of
        // itself, rasterised once into its texture. With real bloom in the
        // post-process, most of what it was doing is now done in the frame —
        // and done better, because the frame's version knows about the
        // building next door and this one never could.
        //
        // Keeping both at full strength double-counts: a tier-3 tower ended
        // up with a baked halo *and* a lit one, which is how a dense block
        // went to mush. Pulling the bake back to a tight rim leaves the
        // silhouette crisp and lets the bloom carry the spill, which is the
        // right division of labour — and it is the reason bloom was the
        // first GPU job rather than the prettiest one.
        //
        // **The cost argument for this was wrong, and measuring it is the
        // only reason that is known.** The claim was that radius scales blur
        // cost superlinearly, so a smaller bake would make filling the cache
        // cheaper as well as crisper. Measured over every building variant on
        // a cold cache: radius 7 takes 191.9 ms and radius 4 takes 191.0 —
        // nine tenths of a millisecond out of a hundred and ninety, which is
        // noise. Whatever dominates that number, it is not the blur.
        //
        // The change stays, because the *visual* half is real and was checked
        // on a render. It is simply not a saving, and a comment claiming one
        // would be the kind of unmeasured assertion this project keeps
        // finding and deleting.
        blur?.setValue(VisualStyle.current.bakedGlowRadius, forKey: "inputRadius")
        let weight = VisualStyle.current.bakedGlowWeight
        for shape in shapes {
            shape.lineWidth = 6 * max(0.4, intensity) * weight
            shape.alpha = min(1, 0.85 * intensity)
            layer.addChild(shape)
        }
        return layer
    }

    private static func node(for badge: Badge, in projection: Isometric) -> SKNode {
        let centre = projection.project(badge.at)
        let size = badge.size
        let path = CGMutablePath()
        path.move(to: CGPoint(x: centre.x, y: centre.y + size / 2))
        path.addLine(to: CGPoint(x: centre.x - size / 2, y: centre.y - size / 2))
        path.addLine(to: CGPoint(x: centre.x + size / 2, y: centre.y - size / 2))
        path.closeSubpath()

        let triangle = SKShapeNode(path: path)
        triangle.fillColor = NeonStyle.silhouetteFill
        triangle.strokeColor = NeonStyle.emberColor
        triangle.lineWidth = 2
        triangle.glowWidth = 1.5

        let container = SKNode()
        container.addChild(triangle)
        container.addChild(NeonStyle.detail(
            rect: CGRect(x: centre.x - size * 0.09, y: centre.y - size * 0.2,
                         width: size * 0.18, height: size * 0.36),
            fill: NeonStyle.emberColor
        ))
        return container
    }
}
