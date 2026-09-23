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
/// (`chance`), so a lot's look is still stable and still differs from its
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
}
