import XCTest
import SpriteKit
@testable import AlphaPlusPlus

/// Renders a whole city isometrically, through `IsoTileRenderer` and the
/// texture cache, at every zoom the camera has.
///
/// This is the isometric streetscape: the acceptance test for everything the
/// scene has to get right that a per-building contact sheet cannot show —
/// draw order between neighbours, multi-tile buildings sorting against the
/// tiles they cover, roads joining at junctions, and whether three zones still
/// read as three zones at the size they are played at.
///
/// It replaces `IsometricSpikeTests`, whose job — deciding whether isometric
/// was worth the migration, and at what height scale — is done.
final class IsometricCityTests: XCTestCase {

    private static let tilesWide = 21
    private static let tilesHigh = 16
    private static let roadEvery = 5

    private static let zoomLevels: [(name: String, tileWidth: CGFloat)] = [
        ("zoomed in (camera 0.5)", 64),
        ("default (camera 1.0)", 32),
        ("zoomed out (camera 3.0)", 11),
    ]

    /// Height scale stays proportional to tile width, so each panel is the same
    /// city at a different zoom rather than a differently-shaped one.
    private static func projection(tileWidth: CGFloat) -> Isometric {
        Isometric(tileWidth: tileWidth, heightUnit: 32 * tileWidth / 64)
    }

    // MARK: - The city

    /// A hand-built city: roads on a grid, 2×2 lots of every zone and tier
    /// including unbuilt ones, and the services that exercise multi-tile
    /// ordering.
    private static func city() -> CityMap {
        var map = CityMap(width: tilesWide, height: tilesHigh)
        for y in 0 ..< tilesHigh {
            for x in 0 ..< tilesWide where x % roadEvery == 0 || y % roadEvery == 0 {
                map[GridPosition(x: x, y: y)].zone = .road
            }
        }

        func place(_ zone: ZoneType, _ density: Int, at origin: GridPosition) {
            let size = zone.footprintSize
            for dx in 0 ..< size {
                for dy in 0 ..< size {
                    let position = GridPosition(x: origin.x + dx, y: origin.y + dy)
                    guard map.contains(position) else { return }
                    map[position].zone = zone
                    map[position].density = density
                    map[position].buildingOrigin = origin
                }
            }
        }

        var blockIndex = 0
        for blockY in stride(from: 1, to: tilesHigh - 3, by: roadEvery) {
            for blockX in stride(from: 1, to: tilesWide - 3, by: roadEvery) {
                let zone: ZoneType = [.residential, .commercial, .industrial][blockIndex % 3]
                let distance = abs(blockX - 11) / 5 + abs(blockY - 6) / 5
                let density = [5, 3, 1, 0][min(distance, 3)]
                for dy in stride(from: 0, to: 4, by: 2) {
                    for dx in stride(from: 0, to: 4, by: 2) {
                        place(zone, density, at: GridPosition(x: blockX + dx, y: blockY + dy))
                    }
                }
                blockIndex += 1
            }
        }

        // Services, including a 3×3 that has to sort against the tiles it
        // covers — the case a per-building sheet cannot exercise.
        place(.powerPlant, 0, at: GridPosition(x: 16, y: 1))
        place(.waterTower, 0, at: GridPosition(x: 11, y: 11))
        place(.fireStation, 0, at: GridPosition(x: 6, y: 11))
        place(.school, 0, at: GridPosition(x: 1, y: 11))
        // Parks are 1×1, so they thread between blocks where nothing else
        // fits — which is the whole point of them and needs to be visible.
        for spot in [GridPosition(x: 5, y: 4), GridPosition(x: 9, y: 8), GridPosition(x: 14, y: 5)] {
            place(.park, 0, at: spot)
        }

        // A handful of lots mid-build, at four different stages, so the
        // renders below show what a scaffold looks like next to the finished
        // buildings it will become — the one thing a screenshot of a settled
        // city can never show, and the only way to check that a rising deck
        // still reads as a rising deck when it is nine pixels tall.
        // Two blocks alight, so the render shows what an active disaster looks
        // like next to the ordinary city — and specifically next to the damage
        // badge, since "still burning" and "burnt down" are the two states a
        // player most needs to tell apart at a glance.
        for origin in [GridPosition(x: 5, y: 5), GridPosition(x: 13, y: 9)]
        where map.contains(origin) && map[origin].zone.maxDensity > 0 {
            for cell in map.footprintCells(origin: map[origin].buildingOrigin, size: 2) {
                map[cell].fireTicks = 2
            }
        }

        var site = 0
        for position in positions(of: map) where map[position].isBuildingAnchor
            && map[position].zone.maxDensity > 0 {
            site += 1
            guard site % 5 == 0 else { continue }
            let target = map[position].density + 1
            guard target <= map[position].zone.maxDensity else { continue }
            let total = CitySimulator.constructionTicks(toReach: target)
            // 4/5, 3/5, 2/5, 1/5 built, cycling.
            let remaining = total * (1 + site / 5 % 4) / 5
            for cell in map.footprintCells(origin: position, size: map[position].zone.footprintSize) {
                map[cell].constructionRemaining = remaining
            }
        }
        return map
    }

    /// `city()` with a network that reaches *some* of it.
    ///
    /// **The overlay render used to use the bare city, which has no pipes and
    /// no power lines at all** — so every building came back unsupplied and
    /// the picture showed one state, twice. An overlay's whole job is telling
    /// two states apart, and a render in which only one of them occurs cannot
    /// show whether it does. Same trap as the streetscape that painted its own
    /// flat tiles while the renderer had moved on: a yardstick that cannot
    /// express the thing it measures always reports success.
    private static func cityWithPartialUtilities() -> CityMap {
        var map = city()
        // A pipe run west from the tower at (11, 11), and a power line run
        // south from the plant at (16, 1) — each reaching part of the city and
        // leaving the rest dry or dark.
        for x in 0 ... 11 { map[GridPosition(x: x, y: 11)].hasPipe = true }
        for y in 8 ... 11 { map[GridPosition(x: 3, y: y)].hasPipe = true }
        for y in 1 ... 8 { map[GridPosition(x: 16, y: y)].hasPowerLine = true }
        for x in 10 ... 16 { map[GridPosition(x: x, y: 8)].hasPowerLine = true }
        // A run of pipe that reaches nothing, because "did that connect?" is
        // the only question a player is asking while laying it — and a fixture
        // where every conduit is live cannot show whether the answer is
        // visible. Same reason this fixture had to grow a partial network in
        // the first place.
        for y in 2 ... 6 { map[GridPosition(x: 18, y: y)].hasPipe = true }
        for x in 15 ... 18 { map[GridPosition(x: x, y: 2)].hasPipe = true }

        map.waterSupply = Water.computeSupply(for: map)
        map.powerSupply = PowerGrid.computeSupply(for: map, outageActive: false)
        // And the cached fields the heatmaps read. `CityMap` defaults these to
        // empty, so without this the pollution overlay renders a uniform black
        // field — which looks exactly like the overlay being broken, and was
        // indistinguishable from it while it actually was.
        map.pollution = Pollution.compute(for: map)
        map.trafficLoad = Traffic.computeLoad(for: map)
        // A police station, so the crime overlay has a covered half and an
        // uncovered half to tell apart. `city()` already has a fire station.
        // Without one the whole map is uncovered and the picture shows a
        // single state twice — the trap this fixture already had to be fixed
        // for once, when it had no pipes in it.
        map.placeBuilding(zone: .policeStation, origin: GridPosition(x: 3, y: 6))
        return map
    }

    private static func positions(of map: CityMap) -> [GridPosition] {
        (0 ..< map.height).flatMap { y in (0 ..< map.width).map { GridPosition(x: $0, y: y) } }
    }

    // MARK: - Assertions

    /// The whole point of the texture cache: a built-out map must cost about
    /// one sprite per building, not fifty shapes.
    func testACityCostsOneSpritePerBuilding() throws {
        let map = Self.city()
        let projection = Self.projection(tileWidth: 32)
        let renderer = IsoTileRenderer(projection: projection)

        var anchors = 0
        var buildings = 0
        for position in Self.positions(of: map) where map[position].isBuildingAnchor {
            anchors += 1
            let node = renderer.makeNode(for: map[position])
            let sprites = node.children.compactMap { $0 as? SKSpriteNode }
            buildings += sprites.contains { $0.texture != nil && $0.size.width > 8 } ? 1 : 0
            XCTAssertTrue(
                node.children.allSatisfy { !($0 is SKEffectNode) },
                "a tile node must contain no blur pass — the cache is what pays for those, once"
            )
        }
        XCTAssertGreaterThan(buildings, 20, "expected a built-out city")
        XCTAssertLessThanOrEqual(
            renderer.textures.count, IsoTextureCache.variantCount * 12,
            "the cache should be bounded by variants, not by lots — \(anchors) anchors produced \(renderer.textures.count) textures"
        )
    }

    /// A lot must look the same on every launch. The cache picks a variant from
    /// the lot's position, and if that ever used `hashValue` — which Swift
    /// randomises per process — cities would reshuffle themselves between runs.
    func testVariantChoiceIsStable() {
        for index in 0 ..< 200 {
            let seed = GridPosition(x: index % 17, y: index / 17)
            let first = IsoTextureCache.variant(for: seed)
            XCTAssertEqual(first, IsoTextureCache.variant(for: seed))
            XCTAssertTrue((0 ..< IsoTextureCache.variantCount).contains(first))
        }
        // And it must actually spread: all one variant would be a cache that
        // hits perfectly and renders one building everywhere.
        let spread = Set((0 ..< 120).map { IsoTextureCache.variant(for: GridPosition(x: $0 % 11, y: $0 / 11)) })
        XCTAssertGreaterThan(spread.count, IsoTextureCache.variantCount / 2)
    }

    /// Multi-tile buildings must sort in front of the tiles they cover, or a
    /// power plant is painted over by its own footprint.
    func testMultiTileBuildingsSortInFrontOfTheirFootprint() {
        let plant = GridPosition(x: 16, y: 1)
        let plantDepth = Isometric.depth(of: plant, footprint: 3)
        for dx in 0 ..< 3 {
            for dy in 0 ..< 3 {
                let covered = GridPosition(x: plant.x + dx, y: plant.y + dy)
                XCTAssertGreaterThanOrEqual(plantDepth, Isometric.depth(of: covered),
                                            "the plant sorts behind (\(covered.x), \(covered.y)), which it covers")
            }
        }
    }

    /// Re-syncing an unchanged tile must not rebuild anything.
    ///
    /// `GameScene.refreshAll()` runs every decoration for every tile on every
    /// simulation tick. Without cache keys that tears down and rebuilds
    /// thousands of shape nodes a second and re-hangs every building sprite —
    /// which is exactly the churn CLAUDE.md records as "why the map blinked".
    /// The top-down renderer grew its keys after a live playtest surfaced the
    /// problem; this pins them for the isometric one before.
    func testRefreshingAnUnchangedTileRebuildsNothing() {
        let projection = Self.projection(tileWidth: 32)
        let renderer = IsoTileRenderer(projection: projection)
        var tile = Tile(position: GridPosition(x: 3, y: 4), zone: .residential, density: 4)

        let node = renderer.makeNode(for: tile)
        let before = node.children.map { ObjectIdentifier($0) }
        renderer.update(node, for: tile)
        XCTAssertEqual(node.children.map { ObjectIdentifier($0) }, before,
                       "an unchanged tile replaced its own children")

        tile.density = 5
        renderer.update(node, for: tile)
        XCTAssertNotEqual(node.children.map { ObjectIdentifier($0) }, before,
                          "a tile that grew a tier kept its old building")
    }

    /// Switching to an overlay and back has to restore the building.
    ///
    /// The cache key is what decides whether a decoration is rebuilt, so an
    /// overlay that removed nodes without invalidating their keys would leave
    /// the map permanently blank once the player looked at land value — and it
    /// would look exactly like the overlay working.
    func testLeavingAnOverlayRestoresTheBuilding() {
        let projection = Self.projection(tileWidth: 32)
        let renderer = IsoTileRenderer(projection: projection)
        let tile = Tile(position: GridPosition(x: 2, y: 2), zone: .commercial, density: 5)

        let node = renderer.makeNode(for: tile)
        func hasBuilding() -> Bool {
            node.childNode(withName: IsoTileRenderer.buildingNodeName) != nil
        }
        XCTAssertTrue(hasBuilding())

        renderer.applyOverlay(on: node, buildings: .hidden, color: .green)
        XCTAssertFalse(hasBuilding(), "the overlay left the building showing")

        renderer.update(node, for: tile)
        XCTAssertTrue(hasBuilding(), "leaving the overlay did not bring the building back")
    }

    /// **An overlay has to actually paint its data.**
    ///
    /// This is the regression test for a bug that ran silently for the whole
    /// isometric era: `applyOverlay` recoloured the ground through
    /// `as? SKShapeNode`, and the ground stopped being a shape node the day it
    /// was rasterised into a texture. The cast returned nil, the tint was a
    /// no-op, and *every* overlay in the game painted nothing — the heatmaps
    /// hid the buildings and then showed a blank grid. Nothing failed, because
    /// nothing was checking that the colour arrived.
    ///
    /// So this asserts the colour, not the call. Same lesson as the flashes
    /// that went dead when `SKAction.colorize` met a plain `SKNode`: changing
    /// what a node *is* breaks every cast to what it was, and only a test that
    /// reads the result notices.
    /// Compares colours by their components.
    ///
    /// `SKColor` equality is colour-space sensitive, and SpriteKit converts
    /// what you assign to `SKSpriteNode.color` into device RGB — so a tint
    /// that arrived perfectly intact compares unequal to the `sRGB` value that
    /// was handed to it. The numbers are the thing under test, not the
    /// profile.
    private func assertSameColor(
        _ actual: SKColor?, _ expected: SKColor, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let actual, let a = actual.usingColorSpace(.deviceRGB),
              let b = expected.usingColorSpace(.deviceRGB) else {
            return XCTFail("\(message) — no colour at all", file: file, line: line)
        }
        XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.001, message, file: file, line: line)
        XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: 0.001, message, file: file, line: line)
        XCTAssertEqual(a.blueComponent, b.blueComponent, accuracy: 0.001, message, file: file, line: line)
    }

    func testAnOverlayActuallyTintsTheGround() {
        let renderer = IsoTileRenderer(projection: Self.projection(tileWidth: 32))
        let tile = Tile(position: GridPosition(x: 2, y: 2), zone: .residential, density: 3)
        let node = renderer.makeNode(for: tile)

        func groundColor() -> SKColor? {
            guard let ground = node.childNode(withName: "isoGround") as? SKSpriteNode,
                  ground.colorBlendFactor > 0 else { return nil }
            return ground.color
        }
        XCTAssertNil(groundColor(), "an untinted tile is already carrying an overlay colour")

        renderer.applyOverlay(on: node, buildings: .hidden, color: .green)
        assertSameColor(groundColor(), .green, "the overlay tinted nothing")
    }

    /// And the utility overlays answer with a *colour*, which is the thing a
    /// player reads — "blue means it has water" — rather than a brightness
    /// they would have to compare against a neighbour.
    ///
    /// The partner risk to the one above: a tint that arrives and never
    /// leaves. A city that stayed blue after a visit to the water overlay
    /// would look exactly like the overlay being stuck on.
    func testAUtilityOverlayColoursBuildingsAndThenGivesThemBack() {
        let renderer = IsoTileRenderer(projection: Self.projection(tileWidth: 32))
        let tile = Tile(position: GridPosition(x: 2, y: 2), zone: .residential, density: 3)
        let node = renderer.makeNode(for: tile)

        func building() -> SKSpriteNode? {
            node.childNode(withName: IsoTileRenderer.buildingNodeName) as? SKSpriteNode
        }
        XCTAssertEqual(building()?.colorBlendFactor, 0, "precondition: already tinted")

        let supplied = RenderPalette.waterColor(for: true)
        renderer.applyOverlay(on: node, buildings: .connected(true), color: supplied)
        assertSameColor(building()?.color, supplied, "a supplied building was not coloured")
        XCTAssertGreaterThan(building()?.colorBlendFactor ?? 0, 0.5,
                             "the colour is there but too faint to read as the answer")
        XCTAssertEqual(building()?.alpha, 1)

        // Unsupplied: same channel, opposite end — dark, not merely a
        // different shade of the same brightness.
        renderer.applyOverlay(on: node, buildings: .connected(false),
                              color: RenderPalette.waterColor(for: false))
        XCTAssertLessThan(building()?.alpha ?? 1, 1, "an unsupplied building is drawn just as brightly")

        renderer.restoreFromOverlay(on: node)
        renderer.update(node, for: tile)
        XCTAssertEqual(building()?.colorBlendFactor, 0,
                       "the city stayed tinted after leaving the overlay")
        XCTAssertEqual(building()?.alpha, 1)
    }

    // MARK: - Construction sites

    /// A site appears while work is going on, and goes away when it finishes.
    ///
    /// The "goes away" half is the one worth pinning. Every decoration here is
    /// cached on a key, and a scaffold whose key never said "none" would stay
    /// standing over a finished building forever — which is the failure mode
    /// this renderer's cache has already produced once, for overlays.
    func testAScaffoldStandsOnlyWhileALotIsBuilding() {
        let renderer = IsoTileRenderer(projection: Self.projection(tileWidth: 32))
        var tile = Tile(position: GridPosition(x: 1, y: 1), zone: .residential, density: 1)

        let node = renderer.makeNode(for: tile)
        func hasScaffold() -> Bool {
            node.childNode(withName: IsoTileRenderer.constructionNodeName) != nil
        }
        renderer.syncConstructionSite(on: node, tile: tile)
        XCTAssertFalse(hasScaffold(), "an idle lot is showing a construction site")

        tile.constructionRemaining = CitySimulator.constructionTicks(toReach: 2)
        renderer.syncConstructionSite(on: node, tile: tile)
        XCTAssertTrue(hasScaffold(), "a lot under construction is showing nothing")

        tile.constructionRemaining = nil
        tile.density = 2
        renderer.syncConstructionSite(on: node, tile: tile)
        XCTAssertFalse(hasScaffold(), "the scaffold outlived the building work")
    }

    /// The deck climbs as the work is done — that is the entire signal, so it
    /// is the thing to assert rather than the node merely existing.
    func testTheConstructionDeckRisesWithProgress() {
        let renderer = IsoTileRenderer(projection: Self.projection(tileWidth: 32))
        var tile = Tile(position: GridPosition(x: 1, y: 1), zone: .residential, density: 1)
        let total = CitySimulator.constructionTicks(toReach: 2)

        let node = renderer.makeNode(for: tile)
        func deckHeight() -> CGFloat {
            node.childNode(withName: IsoTileRenderer.constructionNodeName)?
                .childNode(withName: IsoTileRenderer.constructionDeckName)?.position.y ?? -1
        }

        tile.constructionRemaining = total
        renderer.syncConstructionSite(on: node, tile: tile)
        let atStart = deckHeight()
        XCTAssertEqual(atStart, 0, accuracy: 0.001, "a freshly approved site started part-built")

        tile.constructionRemaining = 1
        renderer.syncConstructionSite(on: node, tile: tile)
        let nearlyDone = deckHeight()
        XCTAssertGreaterThan(nearlyDone, atStart, "the deck did not climb")

        // And it is still the *same* node: a site that rebuilt itself every
        // tick would be per-tick shape-node churn on the busiest lots in the
        // city, which is what the key exists to prevent.
        tile.constructionRemaining = 2
        let before = node.childNode(withName: IsoTileRenderer.constructionNodeName)
        renderer.syncConstructionSite(on: node, tile: tile)
        XCTAssertTrue(before === node.childNode(withName: IsoTileRenderer.constructionNodeName),
                      "the scaffold was rebuilt rather than raised")
    }

    // MARK: - The crime and fire-risk overlays

    private func riskCity() -> CityMap {
        var map = CityMap(width: 26, height: 12)
        for x in 0 ..< 24 { map[GridPosition(x: x, y: 4)].zone = .road }
        map.placeBuilding(zone: .policeStation, origin: GridPosition(x: 0, y: 6))
        // Housing next to the station, housing far from it, and a factory far
        // from it — three answers, one of which is not the one its distance
        // suggests.
        for (zone, x) in [(ZoneType.residential, 2), (.residential, 18), (.industrial, 21)] {
            map.placeBuilding(zone: zone, origin: GridPosition(x: x, y: 2))
            for cell in map.footprintCells(origin: GridPosition(x: x, y: 2), size: 2) {
                map[cell].density = 3
            }
        }
        return map
    }

    private func paint(_ mode: OverlayMode, at position: GridPosition, in map: CityMap)
    -> IsoTileRenderer.OverlayPaint? {
        IsoTileRenderer.paint(for: mode, at: position, in: map,
                              using: ZoneDistanceField.compute(for: map))
    }

    /// **The whole point of the crime map**: it shows where crime can *happen*,
    /// not where the stations are. A factory outside every police catchment is
    /// perfectly safe, because crime does not threaten industry — and a map
    /// that drew it as a problem would send the player to build a station they
    /// do not need.
    func testTheCrimeOverlayMarksWhatIsAtRiskRatherThanWhatIsUncovered() {
        let map = riskCity()
        func buildings(at position: GridPosition) -> IsoTileRenderer.OverlayBuildings? {
            paint(.police, at: position, in: map)?.buildings
        }
        XCTAssertEqual(buildings(at: GridPosition(x: 2, y: 2)), .connected(true),
                       "housing beside the station is being drawn as at risk")
        XCTAssertEqual(buildings(at: GridPosition(x: 18, y: 2)), .connected(false),
                       "housing far from any station is being drawn as safe")
        XCTAssertEqual(buildings(at: GridPosition(x: 21, y: 2)), .connected(true),
                       "a factory is being drawn as at risk from crime, which cannot touch it")
        XCTAssertEqual(buildings(at: GridPosition(x: 0, y: 6)), .highlighted,
                       "the station itself is not the thing the player is hunting for")
    }

    /// Fire threatens the opposite half of the city, so the same three lots
    /// answer the other way round — which is what makes these two overlays
    /// worth having separately rather than one "services" map.
    func testTheFireOverlayCoversADifferentSetOfBuildings() {
        var map = riskCity()
        map.placeBuilding(zone: .fireStation, origin: GridPosition(x: 0, y: 8))
        func buildings(at position: GridPosition) -> IsoTileRenderer.OverlayBuildings? {
            paint(.fire, at: position, in: map)?.buildings
        }
        XCTAssertEqual(buildings(at: GridPosition(x: 18, y: 2)), .connected(true),
                       "housing is being drawn as at risk from fire, which cannot touch it")
        XCTAssertEqual(buildings(at: GridPosition(x: 21, y: 2)), .connected(false),
                       "a factory far from any fire station is being drawn as safe")
    }

    /// The ground carries the catchment, so a player can see its edge and put
    /// the next station where it runs out. That is a different question from
    /// which buildings are in danger, and the two are painted separately —
    /// sharing one colour tinted safe factories to near-black along with the
    /// ground they stood on.
    func testTheGroundShowsTheCatchmentFadingWithDistance() {
        let map = riskCity()
        func coverage(_ x: Int) -> CGFloat {
            let color = paint(.police, at: GridPosition(x: x, y: 6), in: map)!.color
            return color.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0
        }
        XCTAssertGreaterThan(coverage(1), coverage(6), "the catchment does not fade with distance")
        XCTAssertGreaterThan(coverage(6), coverage(20), "the far side of the map is not darkest")

        // And the building tint is *not* the ground tint out there, which is
        // the bug this separation exists to prevent.
        let far = paint(.police, at: GridPosition(x: 21, y: 2), in: map)!
        XCTAssertNotEqual(far.color, far.buildingColor,
                          "a safe factory on uncovered ground is being tinted with the ground")
    }

    /// **"It's tough to tell where buildings are in the power/water
    /// overlay."** Reported from play, and the cause was that both states
    /// repainted the building — 85% toward the utility colour if supplied,
    /// 85% toward near-black if not. The second sank a block of flats into
    /// bare ground.
    ///
    /// The colour comes from the light it throws now, so a supplied building
    /// keeps its form and casts a pool of the utility's colour, and an
    /// unsupplied one desaturates to unlit slate while staying plainly a
    /// building.
    func testSupplyLightsABuildingAndTheAbsenceOfItDoesNotEraseOne() {
        let renderer = IsoTileRenderer(projection: Self.projection(tileWidth: 32))
        let tile = Tile(position: GridPosition(x: 2, y: 2), zone: .residential, density: 4)
        let node = renderer.makeNode(for: tile)
        func building() -> SKSpriteNode? {
            node.childNode(withName: IsoTileRenderer.buildingNodeName) as? SKSpriteNode
        }
        func glow() -> SKNode? { node.childNode(withName: "isoGroundGlow") }

        let hue = RenderPalette.conduitColor(isPipe: true, live: true)
        renderer.applyOverlay(on: node, buildings: .connected(true), color: .black, buildingColor: hue)
        assertSameColor(building()?.color, hue, "a supplied building was not lit by its utility")
        XCTAssertEqual(building()?.alpha, 1)
        XCTAssertNotNil(glow(), "a supplied building throws no light on its lot")

        renderer.applyOverlay(on: node, buildings: .connected(false), color: .black,
                              buildingColor: RenderPalette.unlitBuilding)
        // Dark, but emphatically still there: the silhouette is how a player
        // knows a lot is built on at all.
        XCTAssertGreaterThan(building()?.alpha ?? 0, 0.75,
                             "an unsupplied building faded until it was not a building")
        XCTAssertNil(glow(), "an unsupplied building is still lighting its lot")
    }

    /// The two supply routes have different shapes, and the difference between
    /// them is the pipe you did not need to lay.
    func testTheGroundTellsRadiusCoverageApartFromPipeCoverage() {
        let unserved = RenderPalette.supplyGroundColor(isPipe: true, supplied: false, direct: false)
        let viaRadius = RenderPalette.supplyGroundColor(isPipe: true, supplied: true, direct: true)
        let viaPipe = RenderPalette.supplyGroundColor(isPipe: true, supplied: true, direct: false)

        func brightness(_ color: SKColor) -> CGFloat {
            color.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0
        }
        XCTAssertGreaterThan(brightness(viaPipe), brightness(viaRadius),
                             "pipe-fed ground looks the same as a source's free radius")
        XCTAssertGreaterThan(brightness(viaRadius), brightness(unserved),
                             "ground inside a source's radius looks unserved")
    }

    /// Water and power have to be told apart at a glance, or the two overlays
    /// are one overlay shown twice.
    func testWaterAndPowerAreDifferentColours() {
        func brightness(_ color: SKColor) -> (CGFloat, CGFloat, CGFloat) {
            let c = color.usingColorSpace(.deviceRGB)!
            return (c.redComponent, c.greenComponent, c.blueComponent)
        }
        let water = brightness(RenderPalette.conduitColor(isPipe: true, live: true))
        let power = brightness(RenderPalette.conduitColor(isPipe: false, live: true))
        XCTAssertGreaterThan(water.2, water.0, "water does not read as blue")
        XCTAssertGreaterThan(power.0, power.2, "power does not read as yellow")
    }

    // MARK: - Buried conduits

    /// **"Did that connect?" is the only question a player asks while laying
    /// pipe**, and until this it had no answer on screen: an orphaned run and
    /// a live one were drawn identically. The supply computation has known
    /// every tick since pipes existed.
    func testALiveConduitIsDrawnDifferentlyFromAnOrphanedOne() {
        let renderer = IsoTileRenderer(projection: Self.projection(tileWidth: 32))
        let node = renderer.makeNode(for: Tile(position: GridPosition(x: 1, y: 1)))
        func conduit() -> SKSpriteNode? {
            node.childNode(withName: "isoPipe") as? SKSpriteNode
        }

        renderer.syncConduit(on: node, present: true, isPipe: true, mask: 3, live: false)
        let dead = conduit()?.texture
        XCTAssertNotNil(dead, "an orphaned pipe was not drawn at all")

        renderer.syncConduit(on: node, present: true, isPipe: true, mask: 3, live: true)
        XCTAssertNotNil(conduit()?.texture)
        XCTAssertNotEqual(conduit()?.texture, dead,
                          "a pipe that reaches a tower looks the same as one that reaches nothing")
    }

    /// The conduit is the thing the player came to this overlay to see, so it
    /// is drawn over the city rather than inside it — at any ordinary
    /// `zPosition` the depth sort hides a buried network behind whatever
    /// stands in front of it, which is most of a city.
    func testAConduitDrawsOverTheBuildingsInFrontOfIt() {
        let renderer = IsoTileRenderer(projection: Self.projection(tileWidth: 32))
        let node = renderer.makeNode(for: Tile(position: GridPosition(x: 1, y: 1)))
        renderer.syncConduit(on: node, present: true, isPipe: false, mask: 5, live: true)
        let conduit = node.childNode(withName: "isoPowerLine")
        XCTAssertNotNil(conduit)
        XCTAssertGreaterThan(conduit?.zPosition ?? 0, 200,
                             "a buried conduit sorts among the buildings that hide it")
    }

    /// A lone tile of conduit is the first thing anyone places and the one
    /// most likely to be orphaned, so it must not render as nothing.
    func testALoneConduitTileIsStillVisible() {
        let renderer = IsoTileRenderer(projection: Self.projection(tileWidth: 32))
        let node = renderer.makeNode(for: Tile(position: GridPosition(x: 1, y: 1)))
        renderer.syncConduit(on: node, present: true, isPipe: true, mask: 0, live: false)
        XCTAssertNotNil(node.childNode(withName: "isoPipe"), "an isolated pipe drew nothing")
    }

    /// Cached on what it looks like, so a refresh does not rebuild it — and
    /// *not* cached so hard that going live leaves it looking dead.
    func testAConduitRebuildsWhenItGoesLiveAndNotOtherwise() {
        let renderer = IsoTileRenderer(projection: Self.projection(tileWidth: 32))
        let node = renderer.makeNode(for: Tile(position: GridPosition(x: 1, y: 1)))

        renderer.syncConduit(on: node, present: true, isPipe: true, mask: 3, live: false)
        let first = node.childNode(withName: "isoPipe")
        renderer.syncConduit(on: node, present: true, isPipe: true, mask: 3, live: false)
        XCTAssertTrue(first === node.childNode(withName: "isoPipe"),
                      "an unchanged conduit was rebuilt")

        renderer.syncConduit(on: node, present: true, isPipe: true, mask: 3, live: true)
        XCTAssertFalse(first === node.childNode(withName: "isoPipe"),
                       "a pipe that just came alive is still drawn dead")

        renderer.syncConduit(on: node, present: false, isPipe: true, mask: 0, live: false)
        XCTAssertNil(node.childNode(withName: "isoPipe"), "a removed pipe is still drawn")
    }

    /// What a fully built-out map actually costs the renderer.
    ///
    /// The number that matters is **nodes in the scene**, not nodes per
    /// building: `SKShapeNode` does not batch, so the scene graph's size is
    /// roughly the frame's draw-call count. Reported rather than merely
    /// asserted, because a number in a build log is what makes a regression
    /// visible before it is a stutter.
    func testBuiltOutMapCost() throws {
        var map = CityMap(width: 40, height: 40)
        for y in 0 ..< map.height {
            for x in 0 ..< map.width {
                let position = GridPosition(x: x, y: y)
                if x % 5 == 0 || y % 5 == 0 {
                    map[position].zone = .road
                } else {
                    let anchor = GridPosition(x: x - (x % 5 - 1) % 2, y: y - (y % 5 - 1) % 2)
                    map[position].zone = [.residential, .commercial, .industrial][(x / 5 + y / 5) % 3]
                    map[position].density = 5
                    map[position].buildingOrigin = anchor
                }
            }
        }

        let projection = Self.projection(tileWidth: 32)
        let renderer = IsoTileRenderer(projection: projection)
        let layer = SKNode()

        var anchors = 0
        for position in Self.positions(of: map) where map[position].isBuildingAnchor {
            anchors += 1
            layer.addChild(renderer.makeNode(for: map[position]))
        }
        let nodes = Self.nodeCount(layer)
        let perAnchor = Double(nodes) / Double(anchors)
        print("🧮 built-out 40×40 — \(anchors) anchors, \(nodes) nodes (\(String(format: "%.1f", perAnchor))/anchor), \(renderer.textures.count) textures")

        // Shape nodes are the number that matters: they do not batch, so each
        // is its own draw call, and `glowWidth` on one costs more still. Ground,
        // lane lines, cars and buildings are all rasterised now, so a
        // built-out map should be very nearly all sprites.
        let shapes = Self.shapeNodeCount(layer)
        print("🧮 built-out 40×40 — \(shapes) shape nodes of \(nodes) total")
        XCTAssertLessThan(perAnchor, 6, "a lot should cost a handful of nodes, not a building's worth of shapes")
        XCTAssertLessThan(
            Double(shapes) / Double(anchors), 0.2,
            "shape nodes per lot has crept up — something stopped being rasterised"
        )
        XCTAssertLessThan(renderer.textures.count, 260, "the texture cache should be bounded by variants, not lots")
    }

    private static func shapeNodeCount(_ node: SKNode) -> Int {
        (node is SKShapeNode ? 1 : 0) + node.children.reduce(0) { $0 + shapeNodeCount($1) }
    }

    private static func nodeCount(_ node: SKNode) -> Int {
        1 + node.children.reduce(0) { $0 + nodeCount($1) }
    }

    /// Rasterising a building must not disturb whatever is on screen.
    ///
    /// **The regression this exists for.** `IsoTextureCache` renders a
    /// building by presenting a scratch scene on an `SKView` — and the first
    /// version took the view as a parameter, so `GameScene` passed its own.
    /// `presentScene` replaces what a view shows, so the first building a
    /// player placed swapped the live game out for a hundred-pixel scratch
    /// scene: the map froze, clicks stopped landing, the simulation stopped
    /// ticking. Nothing crashed and nothing logged.
    ///
    /// Every test passed, too, because a test hands the cache a scratch view of
    /// its own and never looks at it again — the bug was only reachable when
    /// the borrowed view was one somebody was watching. So this asserts the
    /// property that actually matters: a view the renderer was never given
    /// keeps showing what it was showing.
    func testRasterisingABuildingLeavesOtherScenesAlone() {
        let view = SKView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let gameScene = SKScene(size: CGSize(width: 200, height: 200))
        view.presentScene(gameScene)
        XCTAssertIdentical(view.scene, gameScene)

        let renderer = IsoTileRenderer(projection: Self.projection(tileWidth: 32))
        for density in [1, 3, 5] {
            _ = renderer.makeNode(for: Tile(position: GridPosition(x: density, y: 2),
                                            zone: .commercial, density: density))
        }
        XCTAssertIdentical(
            view.scene, gameScene,
            "rasterising a building replaced what a view was showing — this is what froze the game"
        )
    }

    // MARK: - The render

    func testRenderIsometricCity() throws {
        let map = Self.city()
        var panels: [(String, NSImage)] = []
        for level in Self.zoomLevels {
            panels.append((level.name, try render(map, tileWidth: level.tileWidth)))
        }

        let sheet = try XCTUnwrap(Self.stack(panels), "failed to stack the city panels")
        let destination = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ContactSheet/isometric-city.png")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try sheet.write(to: destination)
        print("🏙  Isometric city: \(destination.path) (\(sheet.count) bytes)")
        XCTAssertGreaterThan(sheet.count, 0)
    }

    /// The same city in Normal, Water and Power, side by side.
    ///
    /// **A render nobody had.** The overlays were ported with the rest of the
    /// scene and never looked at, and the port had quietly dropped the top-down
    /// renderer's dimmed-building pass — so Water and Power became flat
    /// supply-coloured fields with no way to see where the water tower you were
    /// routing from actually stood. Nothing failed; there was simply no picture
    /// of it anywhere. There is one now.
    func testRenderOverlays() throws {
        let map = Self.cityWithPartialUtilities()
        var panels: [(String, NSImage)] = []
        // The heatmaps are here too, and they are the reason this render
        // matters. They were the *worst* casualty of the dead ground tint —
        // `.hidden` removes every building and then the data colour never
        // arrived, so land value, pollution and traffic were three blank
        // grids. A render showing only the utility overlays could not have
        // caught that, because those at least still had buildings in them.
        for overlay in [("normal", OverlayMode.none), ("water", .water), ("power", .power),
                        ("land value", .landValue), ("pollution", .pollution),
                        ("crime", .police), ("fire risk", .fire), ("problems", .problems)] {
            panels.append((overlay.0, try render(map, tileWidth: 26, overlay: overlay.1)))
        }
        let sheet = try XCTUnwrap(Self.stack(panels), "failed to stack the overlay panels")
        let destination = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ContactSheet/isometric-overlays.png")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try sheet.write(to: destination)
        print("🗺  Isometric overlays: \(destination.path)")
        XCTAssertGreaterThan(sheet.count, 0)
    }

    /// **How much of the city does building height hide?**
    ///
    /// `Isometric.project` moves the screen down by `tileHeight / 2` per step
    /// of `x + y` and up by `heightUnit` per unit of `z`. At the shipping
    /// values — `tileHeight / 2` is 16 and `heightUnit` is 32 — **one storey
    /// displaces two grid rows**, so a tier-4 building of height 2.5 stands in
    /// front of five rows of city. That is the street network, and the traffic
    /// on it, for a block in every direction.
    ///
    /// SimCity 4 keeps its road grid readable at any density, and the reason
    /// is not setback — this project's massing already leaves a margin — it is
    /// that its buildings are far shorter relative to the grid they sit on.
    /// Height is the knob, and this render is the way to pick it: the same
    /// city three times, so the trade between drama and legibility is visible
    /// rather than argued about.
    func testRenderHeightBudget() throws {
        let map = Self.city()
        let tileWidth: CGFloat = 44
        let projection = Self.projection(tileWidth: tileWidth)
        // **Rows, not points.** `heightUnit` scales with tile size, so a fixed
        // point value means different things at different zooms — the first
        // version of this render fixed the points and varied the zoom, which
        // quietly compared the shipping look against two exaggerations of it
        // and made today's setting look far worse than it is. What is actually
        // constant, and what actually decides how much a building hides, is
        // the ratio of `heightUnit` to half a tile's height.
        let shippingRows = projection.heightUnit / (projection.tileHeight / 2)
        var panels: [(String, NSImage)] = []
        for rows in [shippingRows, 1.5, 1.0] {
            let unit = rows * projection.tileHeight / 2
            let label = abs(rows - shippingRows) < 0.01
                ? String(format: "%.1f rows per storey — what ships today", rows)
                : String(format: "%.1f rows per storey", rows)
            panels.append((label, try render(map, tileWidth: tileWidth, heightUnit: unit)))
        }
        let sheet = try XCTUnwrap(Self.stack(panels), "failed to stack the height panels")
        let destination = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ContactSheet/isometric-height.png")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try sheet.write(to: destination)
        print("📏 Height budget: \(destination.path)")
        XCTAssertGreaterThan(sheet.count, 0)
    }

    private func render(
        _ map: CityMap, tileWidth: CGFloat, overlay: OverlayMode = .none, heightUnit: CGFloat? = nil
    ) throws -> NSImage {
        var projection = Self.projection(tileWidth: tileWidth)
        if let heightUnit { projection.heightUnit = heightUnit }
        let bounds = projection.contentBounds(of: map)
        let margin: CGFloat = 24
        let headroom = 4 * projection.heightUnit
        let size = CGSize(width: bounds.width + margin * 2, height: bounds.height + margin * 2 + headroom)
        let origin = CGPoint(x: -bounds.minX + margin, y: -bounds.minY + margin)

        // One scene for the whole city. With buildings rasterised there is not
        // a single effect node left in it, which is the entire reason the cache
        // exists — the top-down streetscape had to composite in batches because
        // a scene silently stops servicing blur passes past a budget.
        let view = SKView(frame: NSRect(origin: .zero, size: size))
        let renderer = IsoTileRenderer(projection: projection)
        let scene = SKScene(size: size)
        scene.backgroundColor = RenderPalette.background

        let world = SKNode()
        world.position = origin
        for position in Self.positions(of: map) where map[position].isBuildingAnchor {
            let tile = map[position]
            let node = renderer.makeNode(for: tile)
            if tile.zone == ZoneType.road || tile.zone == ZoneType.highway {
                renderer.syncLaneLine(on: node, zone: tile.zone,
                                      connections: Traffic.roadConnections(at: position, in: map))
            }
            renderer.syncConstructionSite(on: node, tile: tile)
            renderer.syncFireMarker(on: node, tile: tile)
            // **The shared decision, not a second copy of it.** This used
            // to be its own `switch` over the overlay modes, and it only ever
            // grew the water and power cases — so the heatmaps rendered as an
            // ordinary city and the picture cheerfully reported that three
            // overlays were fine while they painted nothing. See
            // `IsoTileRenderer.paint`.
            if let paint = IsoTileRenderer.paint(for: overlay, at: position, in: map, using: nil) {
                renderer.applyOverlay(on: node, buildings: paint.buildings, color: paint.color,
                                     buildingColor: paint.buildingColor)
            }
            // The buried layers, which are only ever drawn in their own
            // overlay — and which this render did not draw at all, so the one
            // picture of the water overlay anybody had was a picture with no
            // pipes in it.
            if overlay == .water {
                renderer.syncConduit(
                    on: node, present: map[position].hasPipe, isPipe: true,
                    mask: Infrastructure.conduitMask(at: position, in: map, isPipe: true),
                    live: map.waterSupply.isSupplied(at: position)
                )
            }
            if overlay == .power {
                renderer.syncConduit(
                    on: node, present: map[position].hasPowerLine, isPipe: false,
                    mask: Infrastructure.conduitMask(at: position, in: map, isPipe: false),
                    live: map.powerSupply.isSupplied(at: position)
                )
            }
            world.addChild(node)
        }
        scene.addChild(world)

        let effect = SKEffectNode()
        effect.shouldEnableEffects = true
        let shader = RetroShader.make()
        RetroShader.updateAspect(shader, size: size)
        effect.shader = shader
        scene.removeAllChildren()
        effect.addChild(world)
        scene.addChild(effect)

        view.presentScene(scene)
        let texture = try XCTUnwrap(
            view.texture(from: scene, crop: CGRect(origin: .zero, size: size)),
            "SKView produced no texture"
        )
        return NSImage(cgImage: texture.cgImage(), size: size)
    }

    private static func stack(_ panels: [(String, NSImage)]) -> Data? {
        let captionHeight: CGFloat = 26, margin: CGFloat = 16
        let width = (panels.map { $0.1.size.width }.max() ?? 0) + margin * 2
        let height = panels.reduce(margin) { $0 + $1.1.size.height + captionHeight } + margin
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = CGSize(width: width, height: height)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        RenderPalette.background.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Menlo-Bold", size: 13) ?? NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor(white: 0.82, alpha: 1),
        ]
        var y = height - margin
        for (label, image) in panels {
            y -= captionHeight
            label.draw(at: NSPoint(x: margin, y: y + 6), withAttributes: attributes)
            y -= image.size.height
            image.draw(in: NSRect(x: margin, y: y, width: image.size.width, height: image.size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
