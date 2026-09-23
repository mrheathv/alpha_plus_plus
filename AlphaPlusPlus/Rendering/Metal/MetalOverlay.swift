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
/// same call the overlay tests ask directly, for the recorded reason
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
    static let billboardFloatCount = 12

    enum Glyph: Float { case water = 0, power = 1, damage = 2 }

    /// Height of a building of this zone and density on this lot, for putting
    /// a badge on its roof and a scaffold between two roofs.
    /// `nil` while it is not known yet: the live game will not stop to
    /// generate a building nobody has drawn, which cost up to 12 ms on a busy
    /// day. A mark whose height is not known yet waits a frame or two.
    var height: (ZoneType, Int, GridPosition) -> Float? = { _, _, _ in 1 }

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

    /// **What a view paints**, apart from the marks on buildings: the ground
    /// and the building washes, and the buried networks drawn over the city.
    /// A pure function of the map and the view, so the live game computes it
    /// off the main thread; it is most of what a view costs (8–14 ms on Apex).
    struct Layer {
        var mode: OverlayMode = .none
        var tiles: [Float] = []
        var tint: [Float] = []
        var hidesBuildings = false
        var schematic: [Float] = []
    }

    /// Rebuilds everything the view shows, all on this thread.
    func update(_ map: CityMap, mode: OverlayMode) {
        apply(Self.layer(for: map, mode: mode, colours: colours))
        updateMarks(map, mode: mode)
    }

    /// Puts a layer computed elsewhere on screen.
    func apply(_ layer: Layer) {
        mode = layer.mode
        tiles = layer.tiles
        tint = layer.tint
        hidesBuildings = layer.hidesBuildings
        schematic = layer.schematic
    }

    /// The layer for `mode`. Safe off the main thread: it reads only the map
    /// it is handed, and `colours` is locked.
    static func layer(for map: CityMap, mode: OverlayMode, colours: ColourCache) -> Layer {
        var layer = Layer(mode: mode, tint: [Float](repeating: 0, count: map.width * map.height * 4))
        guard mode != .none else { return layer }
        layer.tiles.reserveCapacity(map.tiles.count * tileFloatCount * 2)

        /// One overlay tile, appended in place: building it from three small
        /// arrays per tile was part of the rebuild's cost.
        func push(_ x: Float, _ y: Float, _ size: Float, _ lift: Float,
                  _ color: SKColor, _ scale: Float, _ kind: Float) {
            let c = colours.linear(color) * scale
            layer.tiles.append(x); layer.tiles.append(y); layer.tiles.append(size); layer.tiles.append(lift)
            layer.tiles.append(c.x); layer.tiles.append(c.y); layer.tiles.append(c.z); layer.tiles.append(kind)
        }

        let distances = ZoneDistanceField.compute(for: map)
        let transit = mode.routeMode == nil ? nil : Transit.coverage(for: map)
        for tile in map.tiles {
            let position = tile.position
            guard let paint = IsoTileRenderer.paint(for: mode, at: position, in: map,
                                                    using: distances, transit: transit)
            else { continue }
            let x = Float(position.x), y = Float(position.y)
            // The ground: the view's colour as light on the street — at
            // well under full strength. Added at full strength, a field of
            // it was a glaring plate with nothing to read in it; the
            // palette was picked as paint, and as light it goes further.
            push(x, y, 1, 0.035, paint.color, groundLight, 0)

            // The building, once, from its anchor, over its whole footprint.
            guard tile.isBuildingAnchor else { continue }
            let size = tile.zone.footprintSize
            switch paint.buildings {
            case .hidden:
                layer.hidesBuildings = true
            case .flagged(let flag):
                layer.hidesBuildings = true
                // A lot that wants something glows from across the map;
                // one that is fine gets nothing at all.
                if let flag {
                    let c = Float(size) / 2
                    push(x + c, y + c, 1.7 * Float(size), 0.05, flag, 0.55, 1)
                }
            case .connected(let yes):
                // SpriteKit's numbers: hard both ways, so the two answers
                // never read as one picture at two brightnesses.
                let c = colours.linear(paint.buildingColor)
                for cell in map.footprintCells(origin: position, size: size) where map.contains(cell) {
                    let i = (cell.y * map.width + cell.x) * 4
                    layer.tint[i] = c.x; layer.tint[i + 1] = c.y; layer.tint[i + 2] = c.z
                    layer.tint[i + 3] = yes ? 0.78 : 0.92
                }
                // **And the building throws its answer on the ground**, a
                // pool spilling well past its lot, which is what made a
                // served district glow as one field in SpriteKit
                // (`syncGroundGlow`, recoloured). Scaled by the answer's
                // own brightness, so a building that does not need the
                // utility yet — washed toward unlit — casts almost none.
                let half = Float(size) / 2
                push(x + half, y + half, 1.9 * Float(size), 0.05, paint.buildingColor, yes ? 0.2 : 0.22, 1)
            case .highlighted:
                break
            }
        }
        if mode == .water || mode == .power {
            layer.schematic = conduits(map, isPipe: mode == .water, colours: colours)
        }
        if mode == .tram { layer.schematic = rails(map, colours: colours) }
        return layer
    }

    /// The marks a building wears: scaffolds, damage, badges. Cheap, and
    /// asks building heights, which live on the main thread.
    func updateMarks(_ map: CityMap, mode: OverlayMode) {
        traces = []
        billboards = []
        let badges = mode == .none || mode.showsUtilityBadges
        // Scaffolds and damage are Normal view's; a view hides what
        // describes the building, as `applyOverlay` does.
        for tile in map.tiles where tile.isBuildingAnchor {
            let size = Float(tile.zone.footprintSize)
            let x = Float(tile.position.x), y = Float(tile.position.y)
            let building = mode == .none && tile.isUnderConstruction
            let damage = mode == .none ? tile.damagedBy : nil
            let missing = badges && tile.zone.maxDensity > 0
                ? IsoTileRenderer.missingUtilities(
                    of: tile, hasWaterSupply: Water.hasSupply(at: tile.position, in: map),
                    hasPowerSupply: PowerGrid.hasSupply(at: tile.position, in: map))
                : (water: false, power: false)
            // Only a lot that carries a mark asks its height: asking every
            // building made a busy day generate each new one here, on the
            // main thread, beside the background job making it too.
            guard building || damage != nil || missing.water || missing.power,
                  let roof = height(tile.zone, tile.density, tile.position) else { continue }
            if building {
                scaffold(tile, at: SIMD2(x, y), size: size, roof: roof)
            }
            if let service = damage {
                let c = colours.linear(RenderPalette.fullColor(for: service)) * 1.6
                billboards += [x + size / 2, y + size / 2, roof * 0.6 + 0.1, 30,
                               c.x, c.y, c.z, Glyph.damage.rawValue, 0, 0, 0, 0]
            }
            // Side by side when a block is short of both, which is the
            // state that most wants reading.
            let glyphs = (missing.water ? [Glyph.water] : []) + (missing.power ? [Glyph.power] : [])
            for (index, glyph) in glyphs.enumerated() {
                // Shifted on the screen, not in the world: a world offset
                // shrinks with the camera, and zoomed out the two badges
                // landed on each other and only the bolt showed.
                let shift = (Float(index) - Float(glyphs.count - 1) / 2) * 36
                billboards += [x + size / 2, y + size / 2, roof + 0.4, 34,
                               1.3, 1.3, 1.3, glyph.rawValue, shift, 0, 0, 0]
            }
        }
    }

    /// A wireframe of the building that is coming, from today's roof to the
    /// next storey's, and a lit deck that climbs it as the work is done —
    /// `IsoTileRenderer.syncConstructionSite`'s drawing, in light.
    private func scaffold(_ tile: Tile, at corner: SIMD2<Float>, size: Float, roof: Float) {
        let target = tile.density + 1
        // Not known yet: the scaffold's floor stands in for a frame or two.
        let top = max(height(tile.zone, target, tile.position) ?? 0, roof + 0.5)
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
        let amber = colours.linear(NeonStyle.scaffoldColor)
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
    private static func conduits(_ map: CityMap, isPipe: Bool, colours: ColourCache) -> [Float] {
        var traces: [Float] = []
        for tile in map.tiles where isPipe ? tile.hasPipe : tile.hasPowerLine {
            let live = isPipe ? map.waterSupply.isSupplied(at: tile.position)
                              : map.powerSupply.isSupplied(at: tile.position)
            let color = colours.linear(RenderPalette.conduitColor(isPipe: isPipe, live: live)) * (live ? 2.2 : 1.2)
            run(from: tile.position, mask: Infrastructure.conduitMask(at: tile.position, in: map, isPipe: isPipe),
                color: color, width: 0.07, into: &traces)
        }
        return traces
    }

    /// The rails, in the one view with something to say about the ground: a
    /// tram is the only mode that costs the street anything.
    private static func rails(_ map: CityMap, colours: ColourCache) -> [Float] {
        var traces: [Float] = []
        let color = colours.linear(RenderPalette.transitLineColor(for: .tram)) * 1.8
        for position in map.tramTracks {
            var mask = 0
            for (bit, dx, dy) in [(1, 1, 0), (2, -1, 0), (4, 0, 1), (8, 0, -1)]
            where map.tramTracks.contains(GridPosition(x: position.x + dx, y: position.y + dy)) { mask |= bit }
            run(from: position, mask: mask, color: color, width: 0.05, into: &traces)
        }
        return traces
    }

    private static func run(from position: GridPosition, mask: Int, color: SIMD3<Float>, width: Float,
                            into traces: inout [Float]) {
        let centre = SIMD3<Float>(Float(position.x) + 0.5, Float(position.y) + 0.5, 0.06)
        var drew = false
        for (bit, dx, dy) in [(1, 1, 0), (2, -1, 0), (4, 0, 1), (8, 0, -1)] as [(Int, Float, Float)]
        where mask & bit != 0 {
            traces += MetalMotion.trace(from: centre, to: centre + SIMD3(dx * 0.5, dy * 0.5, 0),
                                        width: width, mode: 1, color: color, alpha: 1)
            drew = true
        }
        if !drew {
            // An isolated length still shows as a stub, so a single tile of
            // pipe is visible rather than nothing.
            traces += MetalMotion.trace(from: centre - SIMD3(0.12, 0, 0), to: centre + SIMD3(0.12, 0, 0),
                                        width: width, mode: 1, color: color, alpha: 1)
        }
    }

    /// How much of a view's colour lands on the ground as light.
    static let groundLight: Float = 0.32

    static func linear(_ color: SKColor) -> SIMD3<Float> { MetalCityMesh.linear(color) }

    /// `linear`, remembered. The view colours arrive in Generic RGB, and
    /// converting one to sRGB goes through the system's colour management:
    /// 4.6 ms for a map's worth on Apex, a third of a whole view rebuild. A
    /// view uses a few hundred distinct colours (284 for Land Value on
    /// Apex), so each is converted once and a rebuild mostly converts
    /// nothing. The same conversion, so the same result. Locked, because the
    /// live game computes a view's layer off the main thread.
    final class ColourCache: @unchecked Sendable {
        private var converted: [SKColor: SIMD3<Float>] = [:]
        private let lock = NSLock()

        func linear(_ color: SKColor) -> SIMD3<Float> {
            lock.lock()
            let known = converted[color]
            lock.unlock()
            if let known { return known }
            let value = MetalOverlay.linear(color)
            lock.lock()
            if converted.count > 20_000 { converted.removeAll(keepingCapacity: true) }
            converted[color] = value
            lock.unlock()
            return value
        }
    }

    let colours = ColourCache()
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
