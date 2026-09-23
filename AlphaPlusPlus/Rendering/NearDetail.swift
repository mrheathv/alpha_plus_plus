import SpriteKit  // for SKColor, which the whole palette is written in

/// **The marks a facade gains up close** (M8), shared by `FacadeDetail` and
/// moved out of `IsometricBuilding.swift` under the same name so they outlive
/// the SpriteKit drawing path.
extension IsometricBuilding {
    /// How wide a pane wants to be, in points, before a mullion is put
    /// between it and the next one. About 56 physical pixels at the closest
    /// camera on a Retina display — chunky, because a mullion finer than this
    /// is the grey speckle `minimumDetailSize` was written to delete.
    fileprivate static let paneWidth: CGFloat = 14

    /// Thickness of a mullion and of a slab line, in points.
    fileprivate static let hairline: CGFloat = 1.5

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
}
