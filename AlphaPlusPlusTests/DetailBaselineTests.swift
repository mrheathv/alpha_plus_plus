import AppKit
import CoreImage
import XCTest
@testable import AlphaPlusPlus

/// **P0 of the building-detail plan: look first, and count.**
///
/// Every change the detail plan makes is judged against two things this file
/// produces: a picture of the buildings at each camera the game has, drawn by
/// the Metal renderer the game uses, and the number of triangles each
/// building costs at each detail tier (far, standard, near and street).
///
/// An extension of `MetalLookTests` so it lives in the Full plan with the
/// other Metal renders: it draws dozens of frames and is not a per-commit
/// check.
///
/// **The cameras, in the Metal renderer's own units.** `Camera.scale` is
/// screen points per output pixel, which is the game camera's scale divided by
/// the backing scale. So the game's resting camera is 0.5 here, 128 pixels a
/// tile. Widest is 1.5 (43 px a tile), the near tier is 0.3 (213 px) and the
/// closest zoom is 0.1 (640 px).
extension MetalLookTests {

    private static let widest: CGFloat = 1.5
    private static let resting: CGFloat = 0.5
    private static let near: CGFloat = 0.3
    private static let closest: CGFloat = 0.1

    /// One building placed in the showcase: what it is, where its lot is, and
    /// the height of the top of its massing for aiming a camera at it.
    private struct Placed {
        let label: String
        let zone: ZoneType
        let density: Int
        let origin: GridPosition
        let top: CGFloat
    }

    /// **The showcase city.** A street grid every three tiles with a 2×2 lot
    /// in every block, and each wanted building dropped on a lot whose own
    /// position gives the variant wanted — which is the only way a lot gets
    /// a variant, since the renderer takes it from the position.
    ///
    /// Plumbed and wired on every tile, with a tower and a plant, so no
    /// close-up is a picture of a utility badge.
    private static func showcase() -> (CityMap, [String: [Placed]]) {
        var map = CityMap(width: 40, height: 36)
        for y in 0 ..< 36 {
            for x in 0 ..< 40 where x % 3 == 0 && x <= 33 || y % 3 == 0 && x <= 33 {
                map.placeBuilding(zone: .road, origin: GridPosition(x: x, y: y))
            }
        }
        var free = (0 ..< 11).flatMap { j in (0 ..< 11).map { i in GridPosition(x: 3 * i + 1, y: 3 * j + 1) } }
        var families: [String: [Placed]] = [:]

        func canonical(_ origin: GridPosition) -> GridPosition {
            IsoTextureCache.canonicalSeed(for: IsoTextureCache.variant(for: origin))
        }
        // Towers take lots from the back of the grid and everything else from
        // the front, nearest the camera, so no tower stands in front of a
        // house it would hide.
        func place(_ family: String, _ label: String, _ zone: ZoneType, _ density: Int,
                   where wanted: (GridPosition) -> Bool) {
            let fromFront = family != "skyline"
            guard let index = fromFront ? free.lastIndex(where: { wanted(canonical($0)) })
                                        : free.firstIndex(where: { wanted(canonical($0)) }) else { return }
            let origin = free.remove(at: index)
            map.placeBuilding(zone: zone, origin: origin)
            if zone.maxDensity > 0 { map[origin].density = density }
            let massing = ZoneMassing.make(for: zone, density: density, seed: canonical(origin))
            // The top of the *body*: volumes at least a third of a tile
            // across, so a needle or a mast does not pull the camera into the
            // sky above the building it stands on.
            let body = massing?.solids.reduce(CGFloat(0)) { result, solid in
                switch solid.volume {
                case .box(let box) where min(box.width, box.depth) >= 0.3:
                    return max(result, box.z + box.height)
                case .ridge(let ridge): return max(result, ridge.z + ridge.height)
                case .cylinder(let cylinder) where cylinder.radius >= 0.15:
                    return max(result, cylinder.z + cylinder.height)
                default: return result
                }
            } ?? 1
            // Metal stretches downtown housing and shops by their
            // neighbourhood, so aim at the height it will actually draw.
            let top = body * CGFloat(MetalCityMesh.heightScale(zone: zone, density: density, at: origin, in: map))
            families[family, default: []].append(Placed(label: label, zone: zone, density: density,
                                                        origin: origin, top: top))
        }

        // Skyscrapers: six forms a zone, chosen to cover different silhouettes.
        for (zone, forms) in [(ZoneType.commercial, [SkyscraperMassing.Form.deco, .twin, .telescope, .cantilever, .halo, .ribbed]),
                              (.residential, [.pyramid, .round, .ziggurat, .splitTop, .stacked, .obelisk])] {
            for form in forms {
                place("skyline", "\(zone == .commercial ? "shops" : "homes") L6 \(form)", zone, 6) {
                    !ZoneMassing.isLandmark(tier: 4, seed: $0) && SkyscraperMassing.form(for: $0) == form
                }
            }
        }
        // The rest of the ladder: two different variants a family.
        for (zone, density, name) in [(ZoneType.commercial, 5, "shops L5"), (.residential, 5, "homes L5"),
                                      (.industrial, 5, "industry L5"), (.residential, 1, "homes L1"),
                                      (.commercial, 1, "shops L1"), (.industrial, 1, "industry L1"),
                                      (.residential, 3, "homes L3"), (.commercial, 3, "shops L3"),
                                      (.industrial, 3, "industry L3")] {
            var used: Set<Int> = []
            for index in 0 ..< 2 {
                place("lowrise", "\(name) #\(index + 1)", zone, density) { seed in
                    let variant = seed.x / 31
                    guard !used.contains(variant), !ZoneMassing.isLandmark(tier: RenderPalette.growthTier(for: density), seed: seed)
                    else { return false }
                    used.insert(variant)
                    return true
                }
            }
        }
        for icon in IconBuildings.all {
            place("icons", RenderPalette.displayName(for: icon), icon, 0) { _ in true }
        }

        // Utilities, off the grid on the east strip, and conduits everywhere.
        map.placeBuilding(zone: .powerPlant, origin: GridPosition(x: 35, y: 1))
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 35, y: 6))
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 35, y: 10))
        for y in 0 ..< map.height {
            for x in 0 ..< map.width {
                map[GridPosition(x: x, y: y)].hasPipe = true
                map[GridPosition(x: x, y: y)].hasPowerLine = true
            }
        }
        map.waterSupply = Water.computeSupply(for: map)
        map.powerSupply = PowerGrid.computeSupply(for: map, outageActive: false)
        return (map, families)
    }

    private static func centre(of placed: Placed, atFraction fraction: CGFloat) -> CGPoint {
        Isometric().project(CGFloat(placed.origin.x) + 1, CGFloat(placed.origin.y) + 1, placed.top * fraction)
    }

    private static func greyscale(_ image: CGImage) -> NSImage {
        let input = CIImage(cgImage: image)
        let filter = CIFilter(name: "CIColorControls")!
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(0, forKey: kCIInputSaturationKey)
        let context = CIContext()
        let output = context.createCGImage(filter.outputImage!, from: input.extent)!
        return NSImage(cgImage: output, size: NSSize(width: image.width, height: image.height))
    }

    /// The pictures: the whole showcase at the widest and resting cameras, in
    /// colour and greyscale, then every building at the near and closest
    /// cameras, one sheet a family.
    func testRenderTheDetailBaseline() throws {
        let (map, families) = Self.showcase()
        XCTAssertEqual(families["skyline"]?.count, 12, "a skyscraper form found no lot")
        XCTAssertEqual(families["icons"]?.count, IconBuildings.all.count)
        let renderer = try XCTUnwrap(MetalCityRenderer())

        let overviewSize = CGSize(width: 1400, height: 875)
        // Centred on the buildings rather than the map: they fill the lots
        // in grid order, so the map's middle is empty street.
        let placedAll = families.values.flatMap { $0 }
        let middle = placedAll.map { Self.centre(of: $0, atFraction: 0.3) }.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x / CGFloat(placedAll.count), y: $0.y + $1.y / CGFloat(placedAll.count))
        }
        var overview: [(String, NSImage)] = []
        for (label, scale) in [("widest", Self.widest), ("resting", Self.resting)] {
            let camera = MetalCityRenderer.Camera(centre: middle, scale: scale, size: overviewSize)
            let frame = try XCTUnwrap(renderer.render(map, camera: camera, wetness: 0, time: 2))
            overview.append(("showcase · \(label)", NSImage(cgImage: frame.image, size: overviewSize)))
            overview.append(("showcase · \(label) · greyscale", Self.greyscale(frame.image)))
        }
        try MetalSpikeTests.writeGrid(overview, columns: 2, cell: overviewSize, named: "detail-p0-overview")

        let closeSize = CGSize(width: 960, height: 600)
        for family in ["skyline", "lowrise", "icons"] {
            var frames: [(String, NSImage)] = []
            for placed in families[family] ?? [] {
                // Near frames the whole building; closest aims at its upper
                // floors, which is where a skyscraper's detail is and what a
                // player zoomed in on it is looking at.
                for (label, scale, fraction) in [("near", Self.near, CGFloat(0.5)),
                                                 ("closest", Self.closest, CGFloat(0.75))] {
                    let camera = MetalCityRenderer.Camera(centre: Self.centre(of: placed, atFraction: fraction),
                                                          scale: scale, size: closeSize)
                    let frame = try XCTUnwrap(renderer.render(map, camera: camera, wetness: 0, time: 2))
                    frames.append(("\(placed.label) · \(label)", NSImage(cgImage: frame.image, size: closeSize)))
                }
            }
            try MetalSpikeTests.writeGrid(frames, columns: 4, cell: closeSize, named: "detail-p0-\(family)")
        }
    }

    /// **The count.** Triangles per building for every zone and level, at the
    /// detail tier, over the 32 looks the game caches:
    /// the mean and the heaviest. Written to `detail-p0-triangles.txt` so the
    /// baseline is a file later phases can diff against, and bounded loosely
    /// so a generator that explodes fails here rather than in a frame budget.
    func testCountTrianglesPerBuilding() throws {
        var lines = ["zone            level  tier      mean     max"]
        var heaviest = (label: "", triangles: 0)
        for zone in ZoneType.allCases {
            let densities = zone.maxDensity > 0 ? Array(1 ... zone.maxDensity) : [0]
            for density in densities {
                guard ZoneMassing.make(for: zone, density: density, seed: IsoTextureCache.canonicalSeed(for: 0)) != nil
                else { continue }
                for tier in DetailTier.allCases {
                    let near = tier  // named for the label below
                    let counts = (0 ..< IsoTextureCache.variantCount).map { variant in
                        MetalCityMesh.building(MetalCityMesh.Cache.Key(zone: zone, density: density,
                                                                        variant: variant, tier: tier))
                            .vertices.count / MetalCityRenderer.GPUVertex.floatCount / 3
                    }
                    let mean = counts.reduce(0, +) / counts.count
                    let most = counts.max() ?? 0
                    let label = "\(zone.rawValue) \(density) \(near)"
                    if most > heaviest.triangles { heaviest = (label, most) }
                    lines.append(String(format: "%-15@ %5d  %-8@ %5d  %6d",
                                        zone.rawValue as NSString, density,
                                        "\(near)" as NSString, mean, most))
                }
            }
        }
        lines.append("heaviest: \(heaviest.label), \(heaviest.triangles) triangles")
        let report = lines.joined(separator: "\n")
        print(report)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ContactSheet/detail-p0-triangles.txt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try report.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertLessThan(heaviest.triangles, 20_000, "\(heaviest.label) has exploded")
    }
}
