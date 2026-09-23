import CoreGraphics
import SpriteKit
import simd

/// **What the map tells you, on the Metal renderer** — migration phase M4.
///
/// Every view, and every mark a building wears to say something about
/// itself: the utility badges, construction scaffolds, damage, the buried
/// pipes and power lines, the tram rails the Tram view exists to show.
///
/// **The decision is not made here.** Which colour a tile is under which
/// view, and what happens to its building, is `IsoTileRenderer.paint` — the
/// same call `GameScene` and the city render make, for the recorded reason
/// that the last time that decision lived in two places, three heatmaps
/// painted nothing while the render reported they were fine. This file only
/// decides how the answer *looks* when light is real:
///
/// - **The ground is lit, not tinted.** A view's colour is added to the
///   street as light, which is the lesson SpriteKit took three tries to learn
///   ("a tint could not get bright enough") and which a lit renderer gets for
///   free: light is the one thing that survives the dark.
/// - **Buildings keep their shape.** A heatmap removes them — its data is on
///   the ground and a tower would hide it; a network view washes each one
///   toward its answer's colour in the shader, which is what SpriteKit's
///   `colorBlendFactor` did; a source the player is hunting for is left
///   exactly as it is.
/// - **Marks that must be found are drawn over everything.** A badge, a pipe
///   run in the Water view: a thing you came to a view to see cannot be hidden
///   behind a tower.
final class MetalOverlay {

    /// One tile of a view, as the shader reads it: where, and what light.
    /// `mode` 0 is a flat tile, 1 a soft pool centred on `x, y`.
    static let tileFloatCount = 8
    /// One badge: where, how many pixels across, its tint, and which glyph.
    static let billboardFloatCount = 8

    enum Glyph: Float { case water = 0, power = 1, damage = 2 }

    /// Height of a building of this zone and density on this lot, for putting
    /// a badge on its roof and a scaffold between two roofs.
    var height: (ZoneType, Int, GridPosition) -> Float = { _, _, _ in 1 }

    private(set) var mode: OverlayMode = .none
    /// Instances for the overlay-tile pass.
    private(set) var tiles: [Float] = []
    /// One RGBA per tile, row by row: the colour a building here is washed
    /// toward, and how far. Alpha 0 leaves it alone.
    private(set) var tint: [Float] = []
    /// Whether this view removes the buildings.
    private(set) var hidesBuildings = false
    /// Traces tested against the city — scaffolds.
    private(set) var traces: [Float] = []
    /// Traces drawn over everything — pipes, power lines, rails.
    private(set) var schematic: [Float] = []
    private(set) var billboards: [Float] = []

    /// Rebuilds everything the view shows. Cheap enough to do on every
    /// change of the map: one call per tile to the shared decision.
    func update(_ map: CityMap, mode: OverlayMode) {
        self.mode = mode
        tiles = []
        traces = []
        schematic = []
        billboards = []
        tint = [Float](repeating: 0, count: map.width * map.height * 4)
        hidesBuildings = false

        let distances = mode == .none ? nil : ZoneDistanceField.compute(for: map)
        let transit = mode.routeMode == nil ? nil : Transit.coverage(for: map)
        var badges = mode == .none

        if mode != .none {
            for tile in map.tiles {
                let position = tile.position
                guard let paint = IsoTileRenderer.paint(for: mode, at: position, in: map,
                                                        using: distances, transit: transit)
                else { continue }
                badges = paint.showsUtilityBadges
                let x = Float(position.x), y = Float(position.y)
                // The ground: the view's colour as light on the street — at
                // well under full strength. Added at full strength, a field of
                // it was a glaring plate with nothing to read in it; the
                // palette was picked as paint, and as light it goes further.
                tiles += [x, y, 1, 0.035] + Self.rgb(paint.color, Self.groundLight) + [0]

                // The building, once, from its anchor, over its whole footprint.
                guard tile.isBuildingAnchor else { continue }
                let size = tile.zone.footprintSize
                switch paint.buildings {
                case .hidden:
                    hidesBuildings = true
                case .flagged(let flag):
                    hidesBuildings = true
                    // A lot that wants something glows from across the map;
                    // one that is fine gets nothing at all.
                    if let flag {
                        let c = Float(size) / 2
                        tiles += [x + c, y + c, 1.7 * Float(size), 0.05] + Self.rgb(flag, 0.55) + [1]
                    }
                case .connected(let yes):
                    // SpriteKit's numbers: hard both ways, so the two answers
                    // never read as one picture at two brightnesses.
                    fillTint(map, at: position, size: size, color: paint.buildingColor,
                             amount: yes ? 0.78 : 0.92)
                case .highlighted:
                    break
                }
            }
        }

        // Scaffolds and damage are Normal view's; a view hides what
        // describes the building, as `applyOverlay` does.
        for tile in map.tiles where tile.isBuildingAnchor {
            let size = Float(tile.zone.footprintSize)
            let x = Float(tile.position.x), y = Float(tile.position.y)
            let roof = height(tile.zone, tile.density, tile.position)
            if mode == .none, tile.isUnderConstruction {
                scaffold(tile, at: SIMD2(x, y), size: size, roof: roof)
            }
            if mode == .none, let service = tile.damagedBy {
                billboards += [x + size / 2, y + size / 2, roof * 0.6 + 0.1, 30]
                    + Self.rgb(RenderPalette.fullColor(for: service), 1.6) + [Glyph.damage.rawValue]
            }
            if badges, tile.zone.maxDensity > 0 {
                let missing = IsoTileRenderer.missingUtilities(
                    of: tile, hasWaterSupply: Water.hasSupply(at: tile.position, in: map),
                    hasPowerSupply: PowerGrid.hasSupply(at: tile.position, in: map))
                // Side by side when a block is short of both, which is the
                // state that most wants reading.
                let glyphs = (missing.water ? [Glyph.water] : []) + (missing.power ? [Glyph.power] : [])
                for (index, glyph) in glyphs.enumerated() {
                    let shift = (Float(index) - Float(glyphs.count - 1) / 2) * 0.45
                    billboards += [x + size / 2 + shift, y + size / 2 - shift, roof + 0.4, 34,
                                   1.3, 1.3, 1.3, glyph.rawValue]
                }
            }
        }

        if mode == .water || mode == .power { conduits(map, isPipe: mode == .water) }
        if mode == .tram { rails(map) }
    }

    private func fillTint(_ map: CityMap, at origin: GridPosition, size: Int, color: SKColor, amount: Float) {
        let c = Self.linear(color)
        for cell in map.footprintCells(origin: origin, size: size) where map.contains(cell) {
            let i = (cell.y * map.width + cell.x) * 4
            tint[i] = c.x; tint[i + 1] = c.y; tint[i + 2] = c.z; tint[i + 3] = amount
        }
    }

    /// A wireframe of the building that is coming, from today's roof to the
    /// next storey's, and a lit deck that climbs it as the work is done —
    /// `IsoTileRenderer.syncConstructionSite`'s drawing, in light.
    private func scaffold(_ tile: Tile, at corner: SIMD2<Float>, size: Float, roof: Float) {
        let target = tile.density + 1
        let top = max(height(tile.zone, target, tile.position), roof + 0.5)
        let total = Float(CitySimulator.constructionTicks(toReach: target))
        let progress = total > 0 ? max(0, 1 - Float(tile.constructionRemaining ?? 0) / total) : 1
        let inset: Float = 0.14
        let corners = [SIMD2<Float>(inset, inset), SIMD2(size - inset, inset),
                       SIMD2(size - inset, size - inset), SIMD2(inset, size - inset)].map { $0 + corner }
        // **The deck is the mark; the frame is a hint.** The first version
        // drew a full wireframe — four posts and a lit ring at the coming
        // roofline — and a grown city at day 45 showed what that costs: nearly
        // every lot is under construction at once, and the rings, bloomed,
        // turned the first hour of play into a lattice of amber boxes over the
        // buildings. The ring at the top is gone, the posts are faint, and the
        // climbing deck carries "under construction" on its own.
        let amber = Self.linear(NeonStyle.scaffoldColor)
        let deck = roof + (top - roof) * progress
        for (index, c) in corners.enumerated() {
            let next = corners[(index + 1) % 4]
            traces += MetalMotion.trace(from: SIMD3(c.x, c.y, roof), to: SIMD3(c.x, c.y, deck),
                                        width: 0.015, mode: 1, color: amber * 0.5, alpha: 0.35)
            traces += MetalMotion.trace(from: SIMD3(c.x, c.y, deck), to: SIMD3(next.x, next.y, deck),
                                        width: 0.03, mode: 1, color: amber * 1.6, alpha: 0.85)
        }
    }

    /// The network as a network: a run from each conduit's centre to every
    /// neighbour it connects to, lit where it reaches a source and unlit wire
    /// where it does not — the only question a player laying pipe is asking.
    private func conduits(_ map: CityMap, isPipe: Bool) {
        for tile in map.tiles where isPipe ? tile.hasPipe : tile.hasPowerLine {
            let live = isPipe ? map.waterSupply.isSupplied(at: tile.position)
                              : map.powerSupply.isSupplied(at: tile.position)
            let color = Self.linear(RenderPalette.conduitColor(isPipe: isPipe, live: live)) * (live ? 2.2 : 1.2)
            run(from: tile.position, mask: Infrastructure.conduitMask(at: tile.position, in: map, isPipe: isPipe),
                color: color, width: 0.07)
        }
    }

    /// The rails, in the one view with something to say about the ground: a
    /// tram is the only mode that costs the street anything.
    private func rails(_ map: CityMap) {
        let color = Self.linear(RenderPalette.transitLineColor(for: .tram)) * 1.8
        for position in map.tramTracks {
            var mask = 0
            for (bit, dx, dy) in [(1, 1, 0), (2, -1, 0), (4, 0, 1), (8, 0, -1)]
            where map.tramTracks.contains(GridPosition(x: position.x + dx, y: position.y + dy)) { mask |= bit }
            run(from: position, mask: mask, color: color, width: 0.05)
        }
    }

    private func run(from position: GridPosition, mask: Int, color: SIMD3<Float>, width: Float) {
        let centre = SIMD3<Float>(Float(position.x) + 0.5, Float(position.y) + 0.5, 0.06)
        var drew = false
        for (bit, dx, dy) in [(1, 1, 0), (2, -1, 0), (4, 0, 1), (8, 0, -1)] as [(Int, Float, Float)]
        where mask & bit != 0 {
            schematic += MetalMotion.trace(from: centre, to: centre + SIMD3(dx * 0.5, dy * 0.5, 0),
                                           width: width, mode: 1, color: color, alpha: 1)
            drew = true
        }
        if !drew {
            // An isolated length still shows as a stub, so a single tile of
            // pipe is visible rather than nothing.
            schematic += MetalMotion.trace(from: centre - SIMD3(0.12, 0, 0), to: centre + SIMD3(0.12, 0, 0),
                                           width: width, mode: 1, color: color, alpha: 1)
        }
    }

    /// How much of a view's colour lands on the ground as light.
    static let groundLight: Float = 0.32

    static func linear(_ color: SKColor) -> SIMD3<Float> { MetalCityMesh.linear(color) }
    static func rgb(_ color: SKColor, _ scale: Float = 1) -> [Float] {
        let c = linear(color) * scale
        return [c.x, c.y, c.z]
    }

    // MARK: - The badge glyphs

    /// The badges as one texture, three cells across: the drop, the bolt and
    /// the damage mark. Drawn from **the same paths and colours** the
    /// SpriteKit badges use (`IsoTextureCache.dropPath`, `.boltPath`), so the
    /// drop in one renderer is the drop in the other.
    static func glyphAtlas(cell: Int = 128) -> CGImage? {
        let width = cell * 3
        guard let context = CGContext(data: nil, width: width, height: cell, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let radius = CGFloat(cell) * 0.42
        func plate(at x: CGFloat, stroke: SKColor) {
            let rect = CGRect(x: x + CGFloat(cell) / 2 - radius, y: CGFloat(cell) / 2 - radius,
                              width: radius * 2, height: radius * 2)
            context.setFillColor(NeonStyle.silhouetteFill.cgColor)
            context.fillEllipse(in: rect)
            context.setStrokeColor(stroke.cgColor)
            context.setLineWidth(radius * 0.12)
            context.strokeEllipse(in: rect.insetBy(dx: radius * 0.06, dy: radius * 0.06))
        }
        for (index, isWater) in [true, false].enumerated() {
            let colour = isWater ? RenderPalette.waterColor(for: true) : RenderPalette.powerColor(for: true)
            let x = CGFloat(index * cell)
            plate(at: x, stroke: colour)
            context.saveGState()
            context.translateBy(x: x + CGFloat(cell) / 2, y: CGFloat(cell) / 2)
            context.addPath(isWater ? IsoTextureCache.dropPath(radius) : IsoTextureCache.boltPath(radius))
            context.setFillColor(colour.cgColor)
            context.fillPath()
            context.restoreGState()
        }
        // Damage: a dark rounded square with a cross, drawn white so the
        // service whose absence let it happen can tint it.
        let x = CGFloat(2 * cell), inset = CGFloat(cell) * 0.16
        let square = CGRect(x: x + inset, y: inset, width: CGFloat(cell) - inset * 2, height: CGFloat(cell) - inset * 2)
        context.addPath(CGPath(roundedRect: square, cornerWidth: inset, cornerHeight: inset, transform: nil))
        context.setFillColor(CGColor(gray: 0.03, alpha: 1))
        context.fillPath()
        context.addPath(CGPath(roundedRect: square, cornerWidth: inset, cornerHeight: inset, transform: nil))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(CGFloat(cell) * 0.06)
        context.strokePath()
        let arm = square.width * 0.28
        context.move(to: CGPoint(x: square.midX - arm, y: square.midY - arm))
        context.addLine(to: CGPoint(x: square.midX + arm, y: square.midY + arm))
        context.move(to: CGPoint(x: square.midX - arm, y: square.midY + arm))
        context.addLine(to: CGPoint(x: square.midX + arm, y: square.midY - arm))
        context.strokePath()
        return context.makeImage()
    }
}
