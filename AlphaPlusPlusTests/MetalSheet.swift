import AppKit
import CoreImage
import XCTest
@testable import AlphaPlusPlus

/// **Contact sheets drawn by the renderer the game uses** (M8).
///
/// The art instruments used to rasterise each building through SpriteKit
/// (`IsometricBuilding.node` into an `SKView`), which stopped being what the
/// game draws the day Metal became the only renderer. Each cell here is one
/// lot on a small plumbed map, drawn by `MetalCityRenderer.render` with the
/// camera framed on it: the same lighting, neon, detail tiers and
/// neighbourhood height the city gets.
///
/// **A lot's variant comes from its position**, so a cell asking for a
/// particular variant is placed on a position that gives it, exactly as
/// `DetailBaselineTests` does. A massing no lot would ever generate (the
/// shape toolkit) is handed to the renderer with `drawForTesting`.
@MainActor
enum MetalSheet {

    struct Cell {
        var label: String
        var zone: ZoneType
        var density: Int = 0
        /// The variant wanted, or `nil` for any (a service has one look).
        var variant: Int?
        /// A massing to draw instead of the generated one.
        var massing: BuildingMassing?
        /// Camera scale in points per pixel; `nil` fits the building. A fixed
        /// scale also stands the ground at the same row in every cell, so a
        /// sheet comparing heights compares them from one ground line.
        var scale: CGFloat?
    }

    /// The first variant whose canonical seed passes `wanted`: how a sheet
    /// asks for "a landmark" or "a deco tower", since a lot draws variant
    /// `v` from `canonicalSeed(for: v)`.
    static func variant(where wanted: (GridPosition) -> Bool) -> Int? {
        (0 ..< IsoTextureCache.variantCount).first { wanted(IsoTextureCache.canonicalSeed(for: $0)) }
    }

    /// The map every cell stands on: 48 × 48, pipes and lines on every tile,
    /// fed from a corner well out of shot, so no building wears a badge.
    private static let side = 48

    /// A position near the middle whose variant is `variant`, with room for a
    /// footprint of `size`.
    static func origin(forVariant variant: Int?, size: Int) -> GridPosition {
        let middle = GridPosition(x: side / 2 - size / 2, y: side / 2 - size / 2)
        guard let variant else { return middle }
        func distance(_ p: GridPosition) -> Int { abs(p.x - middle.x) + abs(p.y - middle.y) }
        var candidates: [GridPosition] = []
        for y in 12 ..< side - 12 - size {
            for x in 12 ..< side - 12 - size { candidates.append(GridPosition(x: x, y: y)) }
        }
        candidates.sort { distance($0) < distance($1) }
        return candidates.first { IsoTextureCache.variant(for: $0) == variant } ?? middle
    }

    /// The map for one cell, and where its lot stands.
    static func map(for cell: Cell) -> (CityMap, GridPosition) {
        var map = CityMap(width: side, height: side)
        let origin = origin(forVariant: cell.variant, size: cell.zone.footprintSize)
        map.placeBuilding(zone: .powerPlant, origin: GridPosition(x: 0, y: 0))
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 0, y: side - 4))
        map.placeBuilding(zone: cell.zone, origin: origin)
        if cell.zone.maxDensity > 0 { map[origin].density = cell.density }
        for y in 0 ..< side {
            for x in 0 ..< side {
                map[GridPosition(x: x, y: y)].hasPipe = true
                map[GridPosition(x: x, y: y)].hasPowerLine = true
            }
        }
        map.waterSupply = Water.computeSupply(for: map)
        map.powerSupply = PowerGrid.computeSupply(for: map, outageActive: false)
        return (map, origin)
    }

    /// The highest point of a massing, in tile units.
    static func top(of massing: BuildingMassing?) -> CGFloat {
        massing?.solids.flatMap { $0.volume.faces.flatMap(\.points) }.map(\.z).max() ?? 1
    }

    /// One cell's picture, `pixels` across.
    static func render(_ cell: Cell, pixels: CGSize, with renderer: MetalCityRenderer) throws -> CGImage {
        let (map, origin) = map(for: cell)
        let size = cell.zone.footprintSize
        let variant = IsoTextureCache.variant(for: origin)
        if let massing = cell.massing {
            renderer.drawForTesting(massing, zone: cell.zone, density: cell.density, variant: variant)
        }
        let massing = cell.massing ?? ZoneMassing.make(for: cell.zone, density: cell.density,
                                                       seed: IsoTextureCache.canonicalSeed(for: variant))
        let top = top(of: massing)
            * CGFloat(MetalCityMesh.heightScale(zone: cell.zone, density: cell.density, at: origin, in: map))
        let projection = Isometric()
        let n = CGFloat(size)
        var centre = projection.project(CGFloat(origin.x) + n / 2, CGFloat(origin.y) + n / 2, top / 2)
        let across = n * projection.tileWidth, tall = n * projection.tileHeight + top * projection.heightUnit
        let fit = max(across / pixels.width, tall / pixels.height) * 1.2
        if let scale = cell.scale {
            // The lot's near corner a tenth of the way up the cell.
            let ground = projection.project(CGFloat(origin.x) + n, CGFloat(origin.y) + n, 0)
            centre = CGPoint(x: ground.x, y: ground.y + scale * pixels.height * 0.4)
        }
        let camera = MetalCityRenderer.Camera(centre: centre, scale: cell.scale ?? fit, size: pixels)
        return try XCTUnwrap(renderer.render(map, camera: camera, wetness: 0, time: 2)?.image,
                             "\(cell.label) did not render")
    }

    /// Every cell, drawn and written as `build/ContactSheet/<name>.png`.
    @discardableResult
    static func write(_ cells: [Cell], columns: Int, cell pixels: CGSize = CGSize(width: 260, height: 300),
                      greyscale: Bool = false, named name: String) throws -> [NSImage] {
        let renderer = try XCTUnwrap(MetalCityRenderer(), "no Metal device")
        var frames: [(String, NSImage)] = []
        for cell in cells {
            let image = try render(cell, pixels: pixels, with: renderer)
            frames.append((cell.label, greyscale ? Self.greyscale(image) : NSImage(cgImage: image, size: pixels)))
        }
        try MetalSpikeTests.writeGrid(frames, columns: columns, cell: pixels, named: name)
        return frames.map(\.1)
    }

    static func greyscale(_ image: CGImage) -> NSImage {
        let input = CIImage(cgImage: image)
        let filter = CIFilter(name: "CIColorControls")!
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(0, forKey: kCIInputSaturationKey)
        let output = CIContext().createCGImage(filter.outputImage!, from: input.extent)!
        return NSImage(cgImage: output, size: NSSize(width: image.width, height: image.height))
    }
}
