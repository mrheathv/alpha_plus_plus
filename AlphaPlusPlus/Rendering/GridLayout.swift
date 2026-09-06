import Foundation
import CoreGraphics

/// Converts between grid space (tile indices) and scene space (points).
///
/// Every "where on screen does tile (x, y) go?" question funnels through here.
/// That is on purpose: when we eventually want an isometric SimCity 2000 look
/// instead of a top-down grid, this struct is the only file that changes —
/// simulation, palette, and scene setup are untouched.
struct GridLayout {

    /// Distance from one tile's origin to the next, in points.
    let tileSize: CGFloat

    /// Visual gutter between tiles. The sprite is drawn slightly smaller than
    /// its cell, so the dark background shows through as grid lines. Cheaper
    /// and sharper than drawing 42 separate line nodes.
    let gap: CGFloat

    init(tileSize: CGFloat = 32, gap: CGFloat = 1) {
        self.tileSize = tileSize
        self.gap = gap
    }

    /// How big to actually draw a tile sprite.
    var spriteSize: CGSize {
        CGSize(width: tileSize - gap, height: tileSize - gap)
    }

    /// Center point of a tile, in scene coordinates.
    ///
    /// SpriteKit's y axis points *up* (unlike AppKit views or a screen raster),
    /// and `SKSpriteNode`'s default anchor is its center — hence the `+ 0.5`.
    func point(for position: GridPosition) -> CGPoint {
        CGPoint(
            x: (CGFloat(position.x) + 0.5) * tileSize,
            y: (CGFloat(position.y) + 0.5) * tileSize
        )
    }

    /// How big to draw the one sprite that represents an entire N×N
    /// building — `size` copies of `tileSize`, minus the same visual gutter
    /// `spriteSize` uses, so a footprint-2 building's edge lines up with the
    /// grid exactly the way a single tile's does. `spriteSize` itself is
    /// just this with `size == 1`.
    func spriteSize(forFootprint size: Int) -> CGSize {
        CGSize(width: CGFloat(size) * tileSize - gap, height: CGFloat(size) * tileSize - gap)
    }

    /// Center point of an N×N building anchored at `origin` (its minimum-x,
    /// minimum-y corner), in scene coordinates. Generalizes `point(for:)`
    /// exactly: at `size == 1` this is `(origin.x + 0.5) * tileSize`, the
    /// same expression `point(for:)` uses, since a 1×1 building's center is
    /// just its one tile's center.
    func centerPoint(ofFootprintOrigin origin: GridPosition, size: Int) -> CGPoint {
        CGPoint(
            x: (CGFloat(origin.x) + CGFloat(size) / 2) * tileSize,
            y: (CGFloat(origin.y) + CGFloat(size) / 2) * tileSize
        )
    }

    /// Inverse of `point(for:)`: which tile contains this scene point?
    /// Returns `nil` if the point falls outside the map. Unused until we add
    /// click-to-place, but it belongs here with its counterpart.
    func position(for point: CGPoint, in map: CityMap) -> GridPosition? {
        let position = GridPosition(
            x: Int((point.x / tileSize).rounded(.down)),
            y: Int((point.y / tileSize).rounded(.down))
        )
        return map.contains(position) ? position : nil
    }

    /// Total footprint of the map in points.
    func contentSize(of map: CityMap) -> CGSize {
        CGSize(width: CGFloat(map.width) * tileSize, height: CGFloat(map.height) * tileSize)
    }

    /// Middle of the map in points — where we park the camera.
    func centerPoint(of map: CityMap) -> CGPoint {
        let size = contentSize(of: map)
        return CGPoint(x: size.width / 2, y: size.height / 2)
    }
}
