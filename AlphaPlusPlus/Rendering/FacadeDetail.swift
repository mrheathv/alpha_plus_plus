import SpriteKit

/// **P3 of the building-detail plan: facades that have depth up close.**
///
/// The close-up baseline (`DetailBaselineTests`) showed every facade as flat
/// lit rectangles on a flat wall. These are the parts a wall grows when the
/// camera can resolve them, each tagged `.near` so the resting camera draws
/// exactly what it did and the Metal renderer adds them only from the near
/// tier in:
///
/// | part | on | what it says |
/// |---|---|---|
/// | balustrade | every housing balcony | a balcony is a place to stand, not a ledge |
/// | air conditioner | some housing windows | someone lives behind that window |
/// | awning | street-level shopfronts | a shop you could walk under |
/// | cornice | the top of each commercial volume | where a floor plate ends |
/// | fire escape | apartment blocks at tiers 2 and 3 | the walk-up's own mark |
///
/// **None of them draws from the building's random stream.** Each helper
/// they hang off (`balcony`, `windows`, `shopfront`, `glazingBands`) already
/// consumes that stream in a fixed order, and one more draw would redesign
/// every building after it — a change to the whole city smuggled inside a
/// detail pass. Where a part needs a choice it hashes its own geometry
/// (`roll`), so a lot's look is still stable and still differs from its
/// neighbour's.
enum FacadeDetail {

    /// The tier every part here is drawn from.
    static let tier: DetailTier = .near

    /// A stable roll in 0..<1 from a part's own position, for choices that
    /// must not touch a `BuildingRandom`. Same mixing constants as
    /// `BuildingRandom`, so it avoids `hashValue` for the same reason.
    static func roll(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, salt: Int) -> Double {
        let quantise = { (v: CGFloat) in Int64((v * 1000).rounded()) }
        var mixed = UInt64(bitPattern: quantise(a) &* 73_856_093 &+ quantise(b) &* 19_349_663
                            &+ quantise(c) &* 83_492_791 &+ Int64(salt) &* 2_654_435_761)
        mixed &+= 0x9E37_79B9_7F4A_7C15
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        mixed ^= mixed >> 31
        return Double(mixed % 10_000) / 10_000
    }

    /// A low solid balustrade along a balcony slab's two visible edges: a
    /// glass-and-steel wall knee-high, whose lit top edge is the railing line.
    static func balustrade(on slab: Box, into massing: inout BuildingMassing) {
        let t: CGFloat = 0.014
        let z = slab.z + slab.height
        let height: CGFloat = 0.09
        massing.add(.box(Box(x: slab.x + slab.width - t, y: slab.y, z: z, width: t, depth: slab.depth,
                             height: height)), from: tier)
        massing.add(.box(Box(x: slab.x, y: slab.y + slab.depth - t, z: z, width: slab.width - t, depth: t,
                             height: height + 0.001)), from: tier)
    }

    /// An air conditioner hung under a window on one of the two visible
    /// walls, if the window's roll says so (about one in seven).
    static func airConditioner(under window: Panel, into massing: inout BuildingMassing) {
        let box = window.box
        let u = (window.u0 + window.u1) / 2
        let bottom = box.z + box.height * window.v0
        guard bottom - box.z > 0.12,
              roll(u, window.v0, box.x + box.y, salt: window.face == .right ? 1 : 2) < 0.15 else { return }
        let size: (w: CGFloat, h: CGFloat, d: CGFloat) = (0.12, 0.07, 0.06)
        let z = bottom - size.h - 0.02
        switch window.face {
        case .right:
            massing.add(.box(Box(x: box.x + box.width, y: box.y + box.depth * u - size.w / 2, z: z,
                                 width: size.d, depth: size.w, height: size.h)), from: tier)
        case .left:
            massing.add(.box(Box(x: box.x + box.width * u - size.w / 2, y: box.y + box.depth, z: z,
                                 width: size.w, depth: size.d, height: size.h)), from: tier)
        }
    }

    /// An awning over a street-level shopfront on both visible walls: a
    /// wedge high at the wall and falling away from it, so its slope catches
    /// the light a flat canopy would not. Kept inside the lot.
    static func awnings(over box: Box, at top: CGFloat, footprint: CGFloat, into massing: inout BuildingMassing) {
        guard box.z < 0.01 else { return }
        let drop: CGFloat = 0.05
        let rightReach = min(0.12, footprint - (box.x + box.width) - 0.005)
        if rightReach > 0.04 {
            massing.add(.ridge(Ridge(x: box.x + box.width, y: box.y + box.depth * 0.06, z: top - drop,
                                     width: rightReach, depth: box.depth * 0.88, height: drop,
                                     axis: .y, ridgePosition: 0)), from: tier)
        }
        let leftReach = min(0.12, footprint - (box.y + box.depth) - 0.005)
        if leftReach > 0.04 {
            massing.add(.ridge(Ridge(x: box.x + box.width * 0.06, y: box.y + box.depth, z: top - drop + 0.001,
                                     width: box.width * 0.88, depth: leftReach, height: drop,
                                     axis: .x, ridgePosition: 0)), from: tier)
        }
    }

    /// A thin cornice round the top of a volume: where a floor plate ends,
    /// drawn as the shadow line a real one casts.
    static func cornice(on box: Box, into massing: inout BuildingMassing) {
        let overhang: CGFloat = 0.025
        massing.add(.box(Box(x: box.x - overhang, y: box.y - overhang, z: box.z + box.height - 0.035,
                             width: box.width + overhang * 2, depth: box.depth + overhang * 2, height: 0.035)),
                    from: tier)
    }

    /// A fire escape down the right-hand wall of an apartment block: a
    /// landing at every storey, joined by two uprights.
    static func fireEscape(on box: Box, footprint: CGFloat, into massing: inout BuildingMassing) {
        let reach = min(0.13, footprint - (box.x + box.width) - 0.005)
        guard reach > 0.07, box.height > 0.8 else { return }
        let x = box.x + box.width
        let width: CGFloat = min(0.34, box.depth * 0.3)
        let y = box.y + box.depth * 0.62
        var z: CGFloat = 0.3
        var index = 0
        while z < box.z + box.height - 0.1 {
            massing.add(.box(Box(x: x, y: y, z: box.z + z, width: reach, depth: width,
                                 height: 0.02 + CGFloat(index) * 0.0005)), from: tier)
            z += 0.36
            index += 1
        }
        for (offset, extra) in [(CGFloat(0), CGFloat(0)), (width - 0.015, 0.001)] {
            massing.add(.box(Box(x: x + reach - 0.015, y: y + offset, z: box.z + 0.3, width: 0.015, depth: 0.015,
                                 height: box.height - 0.35 + extra)), from: tier)
        }
    }

    // MARK: - Windows up close

    /// **The marks every window gains up close, moved out of the renderer.**
    /// They used to be drawn by `MetalCityMesh.building` directly: the
    /// mullions and slab lines at the near tier, and at the street tier a
    /// frame round each lit pane with a sill under it. As parts of the
    /// massing they are tagged, measured and tested like everything else, and
    /// the renderer is back to drawing what it is given.
    ///
    /// Marks sit off the wall by their own `standoff` (0.013 for mullions and
    /// slab lines, 0.015 for frames), in front of the lit pane at 0.009,
    /// which is where the renderer drew them.
    static func windowDetail(_ massing: inout BuildingMassing, accent: SKColor) {
        var ledged: Set<String> = []
        let panels = massing.panels
        for panel in panels {
            for var mark in IsometricBuilding.nearDetail(on: panel, accent: accent, in: Isometric(), ledged: &ledged) {
                mark.standoff = 0.013
                mark.isMark = true
                massing.panels.append(mark.at(.near))
            }
            let color = MetalCityMesh.linear(panel.color) * Float(panel.color.alphaComponent)
            if MetalCityMesh.luminance(color) > 0.08 { frame(panel, accent: accent, into: &massing) }
        }
    }

    /// The street-tier frame: four strips round the pane, standing proud of
    /// it, and a ledge under it that catches the street's light.
    ///
    /// **Tinted with the building's accent, faintly, so it glows.** The
    /// renderer's frames were dark with a rim of accent light on their edges,
    /// which is what gave a window its pale surround. A mark has no rim, and
    /// a plain dark frame read as a black border round every pane — the first
    /// render after the move showed it at once. At 28% of the accent a frame
    /// clears the mark's glow threshold for every zone's colour, and lands at
    /// about the brightness that rim had.
    static let frameStrength: CGFloat = 0.28

    private static func frame(_ pane: Panel, accent: SKColor, into massing: inout BuildingMassing) {
        let box = pane.box
        let t: CGFloat = 0.016
        let across = pane.face == .right ? box.depth : box.width
        let du = t / max(across, 0.01), dv = t / max(box.height, 0.01)
        let strips: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (pane.u0 - du, pane.u1 + du, pane.v1, pane.v1 + dv),   // head
            (pane.u0 - du, pane.u1 + du, pane.v0 - dv, pane.v0),   // foot
            (pane.u0 - du, pane.u0, pane.v0, pane.v1),              // left jamb
            (pane.u1, pane.u1 + du, pane.v0, pane.v1),              // right jamb
        ]
        for (u0, u1, v0, v1) in strips {
            var strip = pane
            strip.u0 = max(0, u0); strip.u1 = min(1, u1)
            strip.v0 = max(0, v0); strip.v1 = min(1, v1)
            strip.color = accent.withAlphaComponent(frameStrength)
            strip.standoff = 0.015
            strip.isMark = true
            massing.panels.append(strip.at(.street))
        }
        // The sill: a thin ledge the width of the frame, 0.04 deep.
        let z = box.z + box.height * max(0, pane.v0 - dv) - 0.012
        // A pane that starts at the ground is a door or a loading bay, and
        // has no sill; one there would sink below the street.
        guard z >= 0.02 else { return }
        let a0 = max(0, pane.u0 - du), a1 = min(1, pane.u1 + du)
        let sill: Box
        switch pane.face {
        case .right:
            sill = Box(x: box.x + box.width, y: box.y + box.depth * a0, z: z,
                       width: 0.04, depth: box.depth * (a1 - a0), height: 0.012)
        case .left:
            sill = Box(x: box.x + box.width * a0, y: box.y + box.depth, z: z,
                       width: box.width * (a1 - a0), depth: 0.04, height: 0.012)
        }
        massing.add(.box(sill), from: .street)
    }
}
