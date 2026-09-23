import CoreGraphics

/// **The facts about buildings and vehicles both renderers share** (M8):
/// which of the fixed looks a lot draws, the seed that stands for each, the
/// kinds of vehicle on the road, and the badge glyphs. Moved out of
/// `IsoTextureCache.swift`, under the same names, so they outlive the
/// SpriteKit texture cache they used to sit in.
extension IsoTextureCache {
    static let variantCount = 32

    /// Which of the `variantCount` looks a lot gets.
    ///
    /// Mixed from the position rather than taken modulo it, so neighbouring
    /// lots do not march through the variants in step and produce visible
    /// diagonal stripes of identical buildings. Deliberately avoids
    /// `hashValue`, which Swift randomises per process — a lot must look the
    /// same on every launch, the same rule `BuildingRandom` documents.
    static func variant(for seed: GridPosition) -> Int {
        var mixed = UInt64(bitPattern: Int64(seed.x &* 73_856_093 &+ seed.y &* 19_349_663))
        mixed &+= 0x9E37_79B9_7F4A_7C15
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((mixed ^ (mixed >> 31)) % UInt64(variantCount))
    }

    /// The canonical seed that stands for a variant. Spread apart so two
    /// variants are not near-neighbours in the generators' own seed space,
    /// which would make them near-identical buildings.
    static func canonicalSeed(for variant: Int) -> GridPosition {
        GridPosition(x: variant * 31, y: variant * 17)
    }

    /// How many looks unbuilt land gets. Small, because each is a whole
    /// texture and the marks on them are deliberately too soft to identify —
    /// what breaks a field's repetition is that *neighbours differ*, not that
    /// any one of them is memorable. Eight is enough that a run of tiles in
    /// any direction does not come back to the same picture inside a screen.
    static let bareLandVariants = 8

    /// A lightning bolt: the zigzag everybody already reads as power.
    static func boltPath(_ radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let w = radius * 0.42, h = radius * 0.62
        path.move(to: CGPoint(x: w * 0.35, y: h))
        path.addLine(to: CGPoint(x: -w, y: h * 0.05))
        path.addLine(to: CGPoint(x: -w * 0.1, y: h * 0.05))
        path.addLine(to: CGPoint(x: -w * 0.35, y: -h))
        path.addLine(to: CGPoint(x: w, y: -h * 0.1))
        path.addLine(to: CGPoint(x: w * 0.1, y: -h * 0.1))
        path.closeSubpath()
        return path
    }

    /// A teardrop: a circle with its top drawn out to a point.
    static func dropPath(_ radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let r = radius * 0.42
        let tip = CGPoint(x: 0, y: r * 1.75)
        path.move(to: tip)
        // Two curves down to the shoulders, then a full arc for the belly —
        // drawn rather than approximated with a circle plus a triangle, which
        // leaves a visible seam at this size.
        path.addQuadCurve(to: CGPoint(x: r, y: -r * 0.15),
                          control: CGPoint(x: r * 0.72, y: r * 0.72))
        // **Clockwise, so the belly goes under.** With y up, `false` sweeps
        // 0 → π/2 → π, which bulges the arc over the *top* and cuts the drop
        // off into a rounded triangle — it rendered as an up-arrow, which is
        // not what anybody reads as water.
        path.addArc(center: CGPoint(x: 0, y: -r * 0.15), radius: r,
                    startAngle: 0, endAngle: .pi, clockwise: true)
        path.addQuadCurve(to: tip, control: CGPoint(x: -r * 0.72, y: r * 0.72))
        path.closeSubpath()
        return path
    }

    /// A car, pointing down one of the two road diagonals.
    /// What kind of thing is on the road.
    ///
    /// Every vehicle used to be the same vehicle — one texture per axis, so a
    /// street outside a factory carried the same hatchback as one outside a
    /// tower block. Traffic is one of the few things on this map that
    /// *moves*, which makes it one of the few places variety is actually
    /// watched rather than glanced at.
    enum Vehicle: Hashable {
        case car
        /// Longer, taller, and carrying a separate box body, so it reads as
        /// freight from the silhouette alone rather than from its colour.
        case lorry
        /// A transit vehicle, running a line. Longest of the three and lit
        /// along its flank, because the point of it is being *recognisable*
        /// from across the map: this is the only thing on screen that proves
        /// a route you drew is carrying anybody.
        case transit(TransitRoute.Mode)
        /// A ship at the dock. By a distance the largest thing that moves on
        /// this map, which is the point: a seaport was the only building in
        /// the game whose entire purpose was invisible once it was built, and
        /// a hull long enough to read from across the map is what says the
        /// quay is trading.
        case ship
        /// A patrol car. Not a different shape — a different *colour*, which
        /// is the whole point of drawing traffic as light: at eleven points
        /// across, hue is legible where silhouette is not.
        case police
        /// An engine running to a fire.
        case fire
        /// An airliner on the runway. **Drawn moving, having been cut as a
        /// static mark**: standing still at three tiles across, a fuselage, a
        /// wing and a fin merged into one lump that read as a crate. Motion
        /// is a different channel from shape — a shape sliding down a lit
        /// centreline is an aircraft because of where it is and what it is
        /// doing, not because its silhouette resolves.
        case aircraft

        var length: CGFloat {
            switch self {
            case .car, .police: return 0.34
            case .lorry, .fire: return 0.52
            case .transit: return 0.62
            case .ship: return 1.9
            case .aircraft: return 0.66
            }
        }

        var height: CGFloat {
            switch self {
            case .car, .police: return 0.15
            case .lorry, .fire: return 0.24
            case .transit: return 0.22
            case .ship: return 0.3
            case .aircraft: return 0.17
            }
        }

        /// How wide across the beam. A ship is the one vehicle here that is
        /// not roughly a lane wide — a hull as narrow as a bus would read as
        /// a very long tram that had fallen in the water.
        var beam: CGFloat {
            switch self {
            case .ship: return 0.62
            // Wings. The one proportion that separates an aircraft from a bus
            // once both are a few points across.
            case .aircraft: return 0.5
            default: return 0.2
            }
        }
    }
}
