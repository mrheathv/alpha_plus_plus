import SpriteKit
import XCTest
@testable import AlphaPlusPlus

/// **Density reads as darkness, and the whole mechanic reduces to one number.**
///
/// Every building in this game is rasterised alone — that is the point of
/// `IsoTextureCache` — so a tower wedged into a packed block was lit
/// identically to one standing by itself in a field. The frame's bloom adds
/// light and nothing in this renderer ever took any away.
///
/// The property to pin is a comparison rather than a value: the same building,
/// same seed, same tier, drawn twice, and the enclosed one has to come out
/// measurably darker. A bound on the absolute brightness would be a statement
/// about the palette instead.
@MainActor
final class OcclusionTests: XCTestCase {

    /// A tower at (4, 4), with a ring of neighbours or without one.
    private func city(enclosed: Bool) -> CityMap {
        var map = CityMap(width: 20, height: 20)
        // A street grid the lots front onto, so the subject is comparable to
        // anything the game actually grows.
        for x in 0 ..< 20 where x % 3 == 0 {
            for y in 0 ..< 20 { map[GridPosition(x: x, y: y)].zone = .road }
        }
        func tower(_ origin: GridPosition) {
            map.placeBuilding(zone: .commercial, origin: origin)
            for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = 5 }
        }
        tower(GridPosition(x: 4, y: 4))
        guard enclosed else { return map }
        // Orthogonally around it — which is what `occlusion(at:)` reads, and
        // deliberately so: see its doc comment for why diagonals are out.
        for origin in [GridPosition(x: 4, y: 2), GridPosition(x: 4, y: 6),
                       GridPosition(x: 2, y: 4), GridPosition(x: 6, y: 4)] {
            tower(origin)
        }
        return map
    }

    private func scene(for map: CityMap) -> GameScene {
        let controller = GameController(map: map, rng: SeededRNG(seed: 3))
        let scene = GameScene(controller: controller)
        scene.size = CGSize(width: 900, height: 700)
        let view = SKView(frame: NSRect(origin: .zero, size: scene.size))
        view.presentScene(scene)
        scene.rebuildEntireGrid()
        scene.refreshAll()
        return scene
    }

    private func subject(_ scene: GameScene, named name: String) -> SKNode? {
        scene.tileNodesForTesting[GridPosition(x: 4, y: 4)]?
            .children.first { $0.name == name }
    }

    func testABuildingHemmedInByItsNeighboursIsDarkerThanOneStandingAlone() throws {
        let open = scene(for: city(enclosed: false))
        let packed = scene(for: city(enclosed: true))

        let openOcclusion = open.occlusion(at: GridPosition(x: 4, y: 4))
        let packedOcclusion = packed.occlusion(at: GridPosition(x: 4, y: 4))
        print(String(format: "occlusion: alone %.3f, hemmed in %.3f",
                     openOcclusion, packedOcclusion))
        XCTAssertEqual(openOcclusion, 0, accuracy: 0.001,
                       "a tower with only streets around it is not enclosed by anything")
        XCTAssertGreaterThan(packedOcclusion, 0.4,
                             "four towers pressed against every side barely registered")

        // **The light at its feet is where it has to show**, because that is
        // where the mechanic puts it: on a ground this dark there is nothing
        // to take away, so occlusion turns down the light that is there
        // rather than painting a shadow.
        let lit = try XCTUnwrap(subject(open, named: IsoTileRenderer.contactNodeName)
                                    as? SKSpriteNode)
        let shaded = try XCTUnwrap(subject(packed, named: IsoTileRenderer.contactNodeName)
                                       as? SKSpriteNode)
        print(String(format: "contact light: alone %.3f, hemmed in %.3f", lit.alpha, shaded.alpha))
        XCTAssertLessThan(shaded.alpha, lit.alpha * 0.7,
                          "the enclosed lot's contact light is no dimmer than the open one's")

        // And the silhouette goes with it, a little.
        let tall = try XCTUnwrap(subject(open, named: IsoTileRenderer.buildingNodeName)
                                     as? SKSpriteNode)
        let dim = try XCTUnwrap(subject(packed, named: IsoTileRenderer.buildingNodeName)
                                    as? SKSpriteNode)
        XCTAssertEqual(tall.colorBlendFactor, 0, accuracy: 0.001)
        XCTAssertGreaterThan(dim.colorBlendFactor, 0.05,
                             "the enclosed building carries no shade at all")
        // **And the cache did not grow.** That is the property the whole
        // approach rests on: a tint is a fact about the *sprite*, so one
        // cached variant still serves every lot that draws it and a lot whose
        // neighbour grew re-tints without rasterising anything. Put enclosure
        // in the key instead and the catalogue is multiplied by six.
        //
        // Counted rather than compared texture-to-texture, which was the first
        // version and was measuring the wrong thing: each `GameScene` owns its
        // own `IsoTextureCache`, so two scenes hand back two distinct objects
        // with identical content and the assertion failed on a working
        // mechanic.
        //
        // Measured by changing a lot's enclosure *within one city* and
        // watching the count. The first version compared two cities and was
        // measuring the fixture: the packed one holds five towers against the
        // open one's one, so of course it had more textures, and the
        // assertion failed on a working mechanic.
        let before = packed.textureCountForTesting
        packed.bulldoze(at: GridPosition(x: 4, y: 2))
        packed.refreshAll()
        let after = packed.textureCountForTesting
        let reshaded = try XCTUnwrap(subject(packed, named: IsoTileRenderer.buildingNodeName)
                                         as? SKSpriteNode)
        print("textures: \(before) → \(after) after a neighbour came down; "
              + String(format: "subject shade %.3f → %.3f",
                       dim.colorBlendFactor, reshaded.colorBlendFactor))
        XCTAssertLessThan(reshaded.colorBlendFactor, dim.colorBlendFactor,
                          "losing a neighbour did not lighten the lot — the tint is not "
                          + "tracking its surroundings")
        XCTAssertEqual(after, before,
                       "re-shading a lot rasterised a new texture — enclosure has leaked into "
                       + "the cache key, which multiplies the whole catalogue by six")
    }

    /// **What the spread actually is on the largest city this project ships.**
    ///
    /// The reading this mechanic exists to create is a *gradient*, and a scale
    /// that saturates would give a flat dim downtown instead — which says
    /// nothing about density and is worse than leaving it alone. So the
    /// distribution is measured on a real built-out city rather than on the
    /// fixture above, and printed into the build log, which is what makes a
    /// regression visible before it is a picture nobody likes.
    func testReportTheSpreadOfEnclosureOnABuiltOutCity() throws {
        let url = try CitySaveFile.defaultDirectory().appendingPathComponent("Apex.alphacity")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Apex has not been minted on this machine")
        }
        let save = try CitySaveFile.read(from: url)
        let scene = scene(for: save.map)

        var buckets = [Int](repeating: 0, count: 6)
        var lots = 0
        for tile in save.map.tiles where tile.position == tile.buildingOrigin {
            guard tile.zone != .empty, !Traffic.isRoadLike(tile.zone) else { continue }
            lots += 1
            buckets[IsoTileRenderer.occlusionStep(scene.occlusion(at: tile.position))] += 1
        }
        let shares = buckets.map { String(format: "%.0f%%", Double($0) / Double(lots) * 100) }
        print("enclosure across \(lots) lots, step 0…5: \(shares.joined(separator: " "))")

        // Two-sided on purpose. If almost everything lands in one bucket the
        // mechanic is a flat tint on the whole city; if almost nothing leaves
        // bucket zero it is not doing anything at all.
        let biggest = buckets.max() ?? 0
        XCTAssertLessThan(Double(biggest) / Double(lots), 0.8,
                          "\(shares.joined(separator: " ")) — enclosure has collapsed into one "
                          + "bucket, so it is a uniform tint rather than a gradient")
        XCTAssertLessThan(Double(buckets[0]) / Double(lots), 0.7,
                          "most of a built-out city reads as open sky")
    }

    /// The reading this exists to create: a *gradient across a block* rather
    /// than one flat dim downtown. A lot on the edge of a built-up patch sees
    /// more sky than one in the middle of it, and if that were not true the
    /// whole district would simply go darker and say nothing.
    func testTheMiddleOfABlockIsDarkerThanItsEdge() {
        var map = CityMap(width: 24, height: 24)
        for x in 0 ..< 24 where x % 9 == 0 {
            for y in 0 ..< 24 { map[GridPosition(x: x, y: y)].zone = .road }
        }
        for x in stride(from: 1, to: 8, by: 2) {
            for y in stride(from: 1, to: 8, by: 2) {
                let origin = GridPosition(x: x, y: y)
                map.placeBuilding(zone: .residential, origin: origin)
                for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = 5 }
            }
        }
        let scene = scene(for: map)
        let middle = scene.occlusion(at: GridPosition(x: 3, y: 3))
        let edge = scene.occlusion(at: GridPosition(x: 1, y: 1))
        print(String(format: "occlusion: block middle %.3f, block corner %.3f", middle, edge))
        XCTAssertGreaterThan(middle, edge + 0.15,
                             "a lot in the middle of a block is no more enclosed than one on its "
                             + "corner — the whole district would just be dimmer, which says "
                             + "nothing about density")
    }

    /// **A picture of the gradient, which is the only thing that can judge it.**
    ///
    /// A number says the middle of a block is more enclosed than its corner. It
    /// cannot say whether that reads as depth or as a stain, and it cannot say
    /// whether the deepest step has gone too far — the two failures this
    /// mechanic has are "you cannot see it" and "the whole district went grey",
    /// and both are questions about a picture.
    ///
    /// So: one city holding a packed block *and* lone towers standing in the
    /// open, photographed together at the resting camera. The comparison has
    /// to be in one frame, because every other render in this project has
    /// shown that a mark judged on its own flatters itself.
    func testRenderEnclosureAgainstOpenGround() throws {
        var map = CityMap(width: 26, height: 26)
        for x in 0 ..< 26 where x % 9 == 0 {
            for y in 0 ..< 26 { map[GridPosition(x: x, y: y)].zone = .road }
        }
        for y in 0 ..< 26 where y % 9 == 0 {
            for x in 0 ..< 26 { map[GridPosition(x: x, y: y)].zone = .road }
        }
        func tower(_ x: Int, _ y: Int, _ zone: ZoneType = .commercial) {
            let origin = GridPosition(x: x, y: y)
            map.placeBuilding(zone: zone, origin: origin)
            for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = 5 }
        }
        // A block packed solid — every lot in it is enclosed, and the ones in
        // the middle much more than the ones on the street.
        for x in stride(from: 1, to: 8, by: 2) {
            for y in stride(from: 1, to: 8, by: 2) { tower(x, y) }
        }
        // And the same building standing on its own, twice, with open ground
        // all round it. This is the control, and without it in the same frame
        // there is nothing to compare the block against.
        tower(11, 3)
        tower(15, 12, .residential)

        // **Plumbed, because an unserved city is a picture of badges.** The
        // first run of this was exactly that — a drop and a bolt over every
        // roof with a city somewhere behind them — which is the same trap the
        // rain render already recorded. And laying pipe is not enough on its
        // own: funding buys *capacity*, not just coverage, so eighteen lots at
        // density 5 need more than one tower or the city sits in an outage
        // that looks identical to having no mains at all.
        for tile in map.tiles where Traffic.isRoadLike(tile.zone) {
            map[tile.position].hasPipe = true
            map[tile.position].hasPowerLine = true
        }
        for origin in [GridPosition(x: 19, y: 1), GridPosition(x: 22, y: 1),
                       GridPosition(x: 19, y: 5)] {
            map.placeBuilding(zone: .waterTower, origin: origin)
        }
        for origin in [GridPosition(x: 19, y: 10), GridPosition(x: 19, y: 16)] {
            map.placeBuilding(zone: .powerPlant, origin: origin)
        }

        let scene = scene(for: map)
        scene.controllerForTesting.recomputeUtilitySupply()
        scene.refreshAll()
        scene.centerCameraOnMap()
        scene.setCameraScaleForTesting(1.15)
        scene.update(0)

        let size = scene.size
        let view = try XCTUnwrap(scene.view)
        let shot = try XCTUnwrap(view.texture(from: scene,
                                              crop: CGRect(origin: .zero, size: size)))
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ContactSheet")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("enclosure.png")
        let image = NSImage(cgImage: shot.cgImage(), size: size)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("could not encode the frame")
        }
        try png.write(to: url)
        print("wrote \(url.path) — a packed block and two lone towers in one frame")
    }

    /// Occlusion has to be quantised before it reaches a cache key, for the
    /// reason road wear is: it is a continuous number a neighbour can nudge by
    /// a thousandth, and a raw key would miss on every tile every tick and
    /// rebuild the whole city once a second.
    func testOcclusionIsQuantisedBeforeItReachesACacheKey() {
        XCTAssertEqual(IsoTileRenderer.occlusionStep(0), 0)
        XCTAssertEqual(IsoTileRenderer.occlusionStep(0.0001), 0,
                       "a thousandth of enclosure moved the key")
        XCTAssertEqual(IsoTileRenderer.occlusionStep(1), 5)
        XCTAssertEqual(IsoTileRenderer.occlusionStep(2), 5, "the step ran off its own scale")
        XCTAssertEqual(IsoTileRenderer.occlusionStep(-1), 0)
    }
}
