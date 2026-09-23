import XCTest
@testable import AlphaPlusPlus

/// The isometric contact sheet: every zone `ZoneMassing` can build, at every
/// tier, across enough seeds to judge whether the variety is real.
///
/// The elevation sheet's counterpart, and it grows the same way the migration
/// does — `ZoneMassing` returns `nil` for zones not yet ported, so this renders
/// exactly what exists and nothing else. When the last zone lands, this sheet
/// is the one that stays.
///
/// **Lots are placed at a fixed point in their cell rather than centred on the
/// building.** The elevation renderer had to centre and scale by the
/// drawn frame because an elevation has no real size. Massing does: a building
/// occupies actual space in an actual lot. Anchoring the *lot* instead of the
/// building keeps sizes honest across cells — a tier-1 shed should look small
/// on its lot, and a sheet that quietly scales every cell to fill would hide
/// exactly that.
final class IsometricContactSheetTests: XCTestCase {

    private static let projection = Isometric()
    private static let variantCount = 8
    private static let tierDensities = [1: 1, 2: 3, 3: 5, 4: 6]

    private struct Entry {
        let zone: ZoneType
        let density: Int
        let tier: Int
        let seed: GridPosition
        let label: String
    }

    /// Spread apart rather than consecutive, so neighbouring seeds cannot
    /// flatter the result by accident.
    private static func seeds() -> [GridPosition] {
        (0 ..< variantCount).map { GridPosition(x: $0 * 7, y: $0 * 3) }
    }

    /// Growable zones appear once per tier; everything else appears once.
    ///
    /// A service has no density — `maxDensity` is zero and its massing ignores
    /// the value entirely — so cataloguing it at three "tiers" rendered three
    /// identical copies of every fire station, which is noise pretending to be
    /// coverage.
    private static func catalog() -> [Entry] {
        var entries: [Entry] = []
        for zone in ZoneType.allCases {
            let cases: [(tier: Int, density: Int)] = zone.maxDensity > 0
                ? tierDensities.keys.sorted().map { ($0, tierDensities[$0]!) }
                : [(0, 0)]
            for (tier, density) in cases {
                for (index, seed) in seeds().enumerated() where density <= zone.maxDensity {
                    guard ZoneMassing.make(for: zone, density: density, seed: seed) != nil else { continue }
                    entries.append(Entry(
                        zone: zone, density: density, tier: tier, seed: seed,
                        label: zone.maxDensity > 0
                            ? "\(zone.rawValue) T\(tier).\(index)"
                            : "\(zone.rawValue).\(index)"
                    ))
                }
            }
        }
        return entries
    }

    // MARK: - Assertions

    func testEveryPortedZoneBuildsSomething() {
        let entries = Self.catalog()
        XCTAssertFalse(entries.isEmpty, "nothing has been ported to massing yet")
        for entry in entries {
            let massing = ZoneMassing.make(for: entry.zone, density: entry.density, seed: entry.seed)
            XCTAssertNotNil(massing, "\(entry.label): massing vanished between catalog and render")
            XCTAssertFalse(massing?.solids.isEmpty ?? true, "\(entry.label): no volumes at all")
        }
    }

    /// Nothing may stick out of its own lot. In elevation this was enforced by
    /// rescaling the whole building to fit, which is how a factory's storage
    /// tanks silently shrank the works they were attached to. Massing occupies
    /// real space, so the constraint is a real one and can simply be checked.
    func testMassingStaysInsideItsFootprint() {
        for entry in Self.catalog() {
            guard let massing = ZoneMassing.make(for: entry.zone, density: entry.density, seed: entry.seed) else {
                continue
            }
            let footprint = CGFloat(entry.zone.footprintSize)
            for solid in massing.solids {
                for face in solid.volume.faces {
                    for point in face.points {
                        XCTAssertGreaterThanOrEqual(point.x, -0.01, "\(entry.label): overhangs its lot at -x")
                        XCTAssertGreaterThanOrEqual(point.y, -0.01, "\(entry.label): overhangs its lot at -y")
                        XCTAssertLessThanOrEqual(point.x, footprint + 0.01, "\(entry.label): overhangs its lot at +x")
                        XCTAssertLessThanOrEqual(point.y, footprint + 0.01, "\(entry.label): overhangs its lot at +y")
                        XCTAssertGreaterThanOrEqual(point.z, -0.01, "\(entry.label): sinks below the ground")
                    }
                }
            }
        }
    }

    /// A generator whose thousands of buildings all look alike is no better
    /// than the two hand-drawn ones it replaced. Counted on the massing itself
    /// — volume count, roof kind, height — rather than on pixels, which is both
    /// cheaper and a stricter test of the thing that actually varies.
    ///
    /// **The bar is lower for services, and not in order to make this pass.** A
    /// growable zone tiles the map: hundreds of lots sit side by side, so
    /// repetition reads as wallpaper and real variety is the requirement. A
    /// city has two fire stations. What a service owes the player is an
    /// *identity* — the one silhouette that makes it findable while scanning
    /// for coverage gaps — and demanding eight distinguishable fire stations
    /// would trade that identity for a property nobody can perceive. They still
    /// have to not be literally one building, which is what the lower bound is.
    func testSeedsProduceStructurallyDifferentBuildings() {
        for zone in ZoneType.allCases {
            let cases: [(Int, Int)] = zone.maxDensity > 0
                ? Self.tierDensities.map { ($0.key, $0.value) }
                : [(0, 0)]
            for (tier, density) in cases where density <= zone.maxDensity {
                let signatures = Set(Self.seeds().compactMap { seed -> String? in
                    guard let massing = ZoneMassing.make(for: zone, density: density, seed: seed) else { return nil }
                    let kinds = massing.solids.map { solid -> String in
                        switch solid.volume {
                        case .box: return "b"
                        case .ridge: return "r"
                        case .cylinder: return "c"
                        case .shape: return "s"
                        }
                    }.joined()
                    let height = massing.solids.reduce(CGFloat(0)) { result, solid in
                        switch solid.volume {
                        case .box(let box): return max(result, box.z + box.height)
                        case .ridge(let ridge): return max(result, ridge.z + ridge.height)
                        case .cylinder(let cylinder): return max(result, cylinder.z + cylinder.height)
                        case .shape(let shape): return max(result, shape.topZ)
                        }
                    }
                    return "\(kinds)-\(Int(height * 12))-\(massing.panels.count)"
                })
                guard !signatures.isEmpty else { continue }
                XCTAssertGreaterThanOrEqual(
                    signatures.count, zone.maxDensity > 0 ? 6 : 2,
                    "\(zone.rawValue) tier \(tier): only \(signatures.count) distinct buildings across \(Self.variantCount) seeds"
                )
            }
        }
    }

    /// Geometry creep, guarded.
    ///
    /// **This test used to compare against the elevation renderer**, which was
    /// the right question while both existed — an isometric building is three
    /// faces per volume where an elevation was one flat silhouette, and finding
    /// out it cost four times as much was worth doing at one zone ported rather
    /// than six. The elevation path is gone now, so there is nothing to compare
    /// against and the comparison would only measure itself.
    ///
    /// What is still worth guarding is the *absolute* number, in the Metal
    /// renderer's own currency: triangles at the resting camera's tier, over
    /// the variants the game actually draws. A generator that quietly grew
    /// to several thousand triangles a building would still look fine on a
    /// contact sheet, and would come straight back as frame time on Apex.
    func testABuildingsGeometryStaysBounded() {
        var worst = (label: "", count: 0)
        var total = 0
        var buildings = 0
        for zone in ZoneType.allCases {
            let densities = zone.maxDensity > 0 ? Self.tierDensities.values.filter { $0 <= zone.maxDensity } : [0]
            for density in densities {
                for variant in 0 ..< IsoTextureCache.variantCount {
                    let built = MetalCityMesh.building(.init(zone: zone, density: density, variant: variant,
                                                             tier: .standard))
                    let count = built.vertices.count / MetalCityRenderer.GPUVertex.floatCount / 3
                    guard count > 0 else { continue }
                    total += count
                    buildings += 1
                    if count > worst.count { worst = ("\(zone.rawValue) L\(density) v\(variant)", count) }
                }
            }
        }
        let average = Double(total) / Double(max(buildings, 1))
        print("🧮 triangles per building — average \(String(format: "%.0f", average)), worst \(worst.count) (\(worst.label))")
        XCTAssertLessThan(average, 300, "average building geometry has grown")
        XCTAssertLessThan(worst.count, 1_000, "\(worst.label) is far heavier than anything else")
    }

    // MARK: - The render

    /// Every zone at every tier, eight variants each, drawn by the Metal
    /// renderer the game uses (`MetalSheet`) — the variants a player sees,
    /// rather than arbitrary seeds the cache would never hand out.
    @MainActor
    func testRenderIsometricContactSheet() throws {
        var cells: [MetalSheet.Cell] = []
        for zone in ZoneType.allCases {
            let cases: [(tier: Int, density: Int)] = zone.maxDensity > 0
                ? Self.tierDensities.keys.sorted().map { ($0, Self.tierDensities[$0]!) }.filter { $0.density <= zone.maxDensity }
                : [(0, 0)]
            for (tier, density) in cases {
                for variant in 0 ..< Self.variantCount {
                    guard ZoneMassing.make(for: zone, density: density,
                                           seed: IsoTextureCache.canonicalSeed(for: variant)) != nil else { continue }
                    cells.append(.init(label: zone.maxDensity > 0 ? "\(zone.rawValue) T\(tier).\(variant)"
                                                                   : "\(zone.rawValue).\(variant)",
                                       zone: zone, density: density, variant: variant))
                }
            }
        }
        // Two sheets, because one is taller than a bitmap may be (16,384
        // pixels) and comes out blank: the growable zones, then everything else.
        let growable = cells.filter { $0.zone.maxDensity > 0 }
        try MetalSheet.write(growable, columns: 8, cell: CGSize(width: 220, height: 220), named: "isometric-zones")
        try MetalSheet.write(cells.filter { $0.zone.maxDensity == 0 }, columns: 8, cell: CGSize(width: 220, height: 220),
                             named: "isometric-services")
    }
}
