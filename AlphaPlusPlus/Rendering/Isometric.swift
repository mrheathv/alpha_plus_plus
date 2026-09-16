import SpriteKit

/// The 2:1 isometric projection, and the box it draws.
///
/// **Status: a spike.** Nothing in the running game uses this yet. It exists so
/// the isometric question can be *looked at* before the codebase is committed
/// to it — see `IsometricSpikeTests`, which renders a block with it.
///
/// **Why isometric is being considered at all.** The game currently draws its
/// ground from directly overhead (a square grid) and its buildings as front
/// elevations, as if seen from the street. Those are two different viewpoints
/// in one picture, which is why a building reads as a lit card standing on a
/// floor plan rather than as an object with mass. No amount of colour or glow
/// tuning closes that gap: a shape reads as a volume when you can see two of
/// its faces at once, and an elevation only ever has one.
///
/// **And why it suits this art direction rather than fighting it.** Neon is an
/// *edge* treatment. In elevation a box has no visible edges, so the glow can
/// only trace a silhouette — which is exactly what the current buildings look
/// like. In isometric the same box shows a top and two sides, and the creases
/// between them are real lines with real direction. The style gets structure to
/// light instead of an outline to trace.
///
/// **The projection.** `x` runs down-and-right on screen, `y` down-and-left,
/// `z` straight up. A tile is twice as wide as it is tall — the classic 2:1
/// that keeps every edge on a clean 2-pixel-per-1 slope, so diagonals stay
/// crisp instead of shimmering.
enum Isometric {

    /// Width of one tile's diamond, in points. Its height is half this.
    static let tileWidth: CGFloat = 64
    static var tileHeight: CGFloat { tileWidth / 2 }

    /// Screen points per one tile-unit of elevation.
    ///
    /// Deliberately *not* `tileHeight`. Tying vertical scale to the tile's own
    /// squash makes every building look squat, because a storey is not as tall
    /// as a lot is wide. This is the single knob that decides whether the city
    /// reads as a model village or a skyline.
    static let heightUnit: CGFloat = 30

    /// A rectangular volume in tile units: `x`/`y` are the minimum plan
    /// corner, `z` the base elevation.
    struct Box {
        var x: CGFloat
        var y: CGFloat
        var z: CGFloat
        var width: CGFloat
        var depth: CGFloat
        var height: CGFloat

        /// How far from the camera this volume sits. Used to sort back to
        /// front — see `sorted(_:)`.
        var depthKey: CGFloat { x + y }
    }

    /// World point to screen point.
    static func project(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint {
        CGPoint(
            x: (x - y) * tileWidth / 2,
            y: -(x + y) * tileHeight / 2 + z * heightUnit
        )
    }

    /// The three faces of a box the camera can see: its top, the side facing
    /// down-right, and the side facing down-left.
    ///
    /// Only three, because a box is opaque and the other three are behind it.
    /// Returned separately rather than as one silhouette so each can take a
    /// different value — the top catches light, the two sides fall away from
    /// it — which is what actually makes the shape read as solid.
    static func faces(of box: Box) -> (top: CGPath, right: CGPath, left: CGPath) {
        let x0 = box.x, x1 = box.x + box.width
        let y0 = box.y, y1 = box.y + box.depth
        let z0 = box.z, z1 = box.z + box.height

        func quad(_ points: [CGPoint]) -> CGPath {
            let path = CGMutablePath()
            path.move(to: points[0])
            points.dropFirst().forEach { path.addLine(to: $0) }
            path.closeSubpath()
            return path
        }

        return (
            top: quad([
                project(x0, y0, z1), project(x1, y0, z1),
                project(x1, y1, z1), project(x0, y1, z1),
            ]),
            right: quad([
                project(x1, y0, z0), project(x1, y1, z0),
                project(x1, y1, z1), project(x1, y0, z1),
            ]),
            left: quad([
                project(x0, y1, z0), project(x1, y1, z0),
                project(x1, y1, z1), project(x0, y1, z1),
            ])
        )
    }

    /// One tile of ground, as a diamond.
    static func tileDiamond(x: CGFloat, y: CGFloat, inset: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        let i = inset
        path.move(to: project(x + i, y + i, 0))
        path.addLine(to: project(x + 1 - i, y + i, 0))
        path.addLine(to: project(x + 1 - i, y + 1 - i, 0))
        path.addLine(to: project(x + i, y + 1 - i, 0))
        path.closeSubpath()
        return path
    }

    /// Back-to-front order — the painter's algorithm an isometric scene needs
    /// and a top-down one does not.
    ///
    /// Top-down, nothing overlaps, so every tile sprite can sit at
    /// `zPosition = 0` (which is exactly what `GameScene` does today). In
    /// isometric a tall building in front must cover the one behind it, and
    /// the only thing that decides "in front" is `x + y`. This is the piece
    /// `GridLayout`'s doc comment misses when it claims a switch to isometric
    /// touches one file: positioning is one file, draw order is the renderer.
    static func sorted<T>(_ items: [T], by key: (T) -> CGFloat) -> [T] {
        items.enumerated()
            .sorted { lhs, rhs in
                let a = key(lhs.element), b = key(rhs.element)
                return a == b ? lhs.offset < rhs.offset : a < b
            }
            .map(\.element)
    }
}
