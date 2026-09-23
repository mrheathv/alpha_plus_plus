import AppKit
import XCTest
@testable import AlphaPlusPlus

/// **A hand-built city and every terrain, drawn by the renderer the game
/// uses** (M8). The renders `IsometricCityTests` made through SpriteKit, moved
/// onto `MetalCityRenderer.render` so they outlive it. The overlay render is
/// not repeated here: `MetalOverlayTests.testRenderEveryView` already draws
/// every view through Metal.
@MainActor
final class CityRenderTests: XCTestCase {

    private static let tilesWide = 21
    private static let tilesHigh = 16
    private static let roadEvery = 5

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

    private static func positions(of map: CityMap) -> [GridPosition] {
        (0 ..< map.height).flatMap { y in (0 ..< map.width).map { GridPosition(x: $0, y: y) } }
    }

    /// The whole map at `scale` points per pixel, centred.
    private func render(_ map: CityMap, scale: CGFloat, size: CGSize) throws -> NSImage {
        let renderer = try XCTUnwrap(MetalCityRenderer(), "no Metal device")
        let bounds = Isometric().contentBounds(of: map)
        let camera = MetalCityRenderer.Camera(centre: CGPoint(x: bounds.midX, y: bounds.midY), scale: scale, size: size)
        let image = try XCTUnwrap(renderer.render(map, camera: camera, wetness: 0, time: 2)?.image, "nothing rendered")
        return NSImage(cgImage: image, size: size)
    }

    /// The same city at the closest, resting and widest cameras, since art is
    /// judged at the size it is played at (0.3 draws the near tier).
    func testRenderIsometricCity() throws {
        var map = Self.city()
        // Plumbed and wired, so the picture is of buildings rather than of
        // the badges an unserved block wears; the fixture's own tower and
        // plant feed it.
        for position in Self.positions(of: map) {
            map[position].hasPipe = true
            map[position].hasPowerLine = true
        }
        map.waterSupply = Water.computeSupply(for: map)
        map.powerSupply = PowerGrid.computeSupply(for: map, outageActive: false)
        let size = CGSize(width: 1200, height: 800)
        var panels: [(String, NSImage)] = []
        for (name, scale) in [("near (0.3)", 0.3), ("resting (0.5)", 0.5), ("wide (1.2)", 1.2)] as [(String, CGFloat)] {
            panels.append((name, try render(map, scale: scale, size: size)))
        }
        try MetalSpikeTests.writeGrid(panels, columns: 1, cell: size, named: "isometric-city")
    }

    /// Every terrain, with a plain grid laid over whatever is dry and the
    /// river bridged where the road rows reach it.
    func testRenderTerrain() throws {
        var panels: [(String, NSImage)] = []
        for terrain in Terrain.allCases {
            // Four columns wider than the grid, for a strip of utilities.
            var map = CityMap(width: 44, height: 40)
            TerrainGenerator.apply(terrain, to: &map, seed: 11)
            // A plain grid over whatever is dry. Deliberately laid without
            // looking at the water, so the shoreline is what interrupts it —
            // which is exactly what a player's first few roads do.
            for y in stride(from: 2, to: 38, by: 3) {
                for x in 2 ..< 38 where !map[GridPosition(x: x, y: y)].isWater {
                    map[GridPosition(x: x, y: y)].zone = .road
                }
            }
            for y in stride(from: 3, to: 37, by: 3) {
                for x in stride(from: 2, to: 36, by: 3) {
                    let origin = GridPosition(x: x, y: y)
                    let cells = map.footprintCells(origin: origin, size: 2)
                    guard cells.count == 4, cells.allSatisfy({ !map[$0].isWater }) else { continue }
                    let zone: ZoneType = [.residential, .commercial, .industrial][(x / 3 + y / 3) % 3]
                    map.placeBuilding(zone: zone, origin: origin)
                    for cell in cells { map[cell].density = 2 + (x + y) % 3 }
                }
            }
            // Bridge the river wherever a road ran into it, which is what a
            // player does about ten seconds after founding a river city —
            // and the only way to see whether a deck reads as carried rather
            // than laid.
            // **Carry the road rows across, and nothing else.** The first
            // version bridged every wet tile that merely *touched* a road,
            // and since the grid runs every third row that was very nearly
            // the whole river — a paved channel, which shows neither a bridge
            // nor a river. A crossing is a road continuing, so it is the road
            // rows that continue.
            if terrain == .river {
                for y in stride(from: 2, to: 38, by: 3) {
                    for x in 2 ..< 38 where map[GridPosition(x: x, y: y)].isWater {
                        map[GridPosition(x: x, y: y)].zone = .road
                    }
                }
            }
            // **Plumbed**, so the picture is of terrain rather than of badges:
            // mains and lines everywhere, fed from a strip of towers and
            // plants to the east with room for the whole grid's demand.
            for y in stride(from: 1, to: 37, by: 4) {
                map.placeBuilding(zone: y < 13 ? .powerPlant : .waterTower, origin: GridPosition(x: 40, y: y))
            }
            for y in 0 ..< map.height {
                for x in 0 ..< map.width {
                    map[GridPosition(x: x, y: y)].hasPipe = true
                    map[GridPosition(x: x, y: y)].hasPowerLine = true
                }
            }
            map.waterSupply = Water.computeSupply(for: map)
            map.powerSupply = PowerGrid.computeSupply(for: map, outageActive: false)
            let size = CGSize(width: 1100, height: 640)
            let bounds = Isometric().contentBounds(of: map)
            panels.append((terrain.displayName,
                           try render(map, scale: max(bounds.width / size.width, bounds.height / size.height) * 1.05,
                                      size: size)))
        }
        try MetalSpikeTests.writeGrid(panels, columns: 2, cell: CGSize(width: 1100, height: 640), named: "terrain")
    }
}
