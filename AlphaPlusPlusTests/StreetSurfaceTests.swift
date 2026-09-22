import SpriteKit
import XCTest
@testable import AlphaPlusPlus

/// **The ground under a street, which had never had a pass.**
///
/// 42% of a frame is road or bare land — 1,387 + 353 tiles of 4,096 on the
/// densest city this project ships — and until now all of it was a flat
/// diamond with a lane line on top. A kerb is the first mark ever added to
/// that surface.
@MainActor
final class StreetSurfaceTests: XCTestCase {

    private func cache() -> IsoTextureCache {
        IsoTextureCache(projection: Isometric(tileWidth: 64))
    }

    /// A kerb is a statement about *neighbours*, like a lane line — so the
    /// mask has to reach the texture, and a dead end cannot share a picture
    /// with a crossroads.
    func testTheConnectionMaskReachesTheGroundTexture() throws {
        let textures = cache()
        let crossroads = try XCTUnwrap(
            textures.ground(for: .road, density: 0, footprint: 1, kerbMask: 0b1111))
        let deadEnd = try XCTUnwrap(
            textures.ground(for: .road, density: 0, footprint: 1, kerbMask: 0b0001))
        let island = try XCTUnwrap(
            textures.ground(for: .road, density: 0, footprint: 1, kerbMask: 0))

        XCTAssertNotEqual(crossroads.texture, deadEnd.texture,
                          "a dead end and a crossroads drew the same ground — the mask is not "
                          + "in the key, so no street will ever grow a kerb")
        XCTAssertNotEqual(deadEnd.texture, island.texture)
        XCTAssertEqual(crossroads.size, island.size,
                       "the pavement changed the tile's footprint, which would shift every "
                       + "street half a kerb out of line with the lots beside it")
    }

    /// And nothing that is not a street is affected by it, or every lot in
    /// the city would be keyed on its neighbours for no reason — sixteen
    /// times the ground textures to draw the same picture.
    func testOnlyStreetsCareAboutTheMask() throws {
        let textures = cache()
        for zone in [ZoneType.residential, .empty, .park, .policeStation] {
            let a = try XCTUnwrap(textures.ground(for: zone, density: 0, footprint: 1,
                                                  kerbMask: 0b1111))
            let b = try XCTUnwrap(textures.ground(for: zone, density: 0, footprint: 1,
                                                  kerbMask: 0))
            XCTAssertEqual(a.texture, b.texture,
                           "\(zone) drew two different grounds for two masks it cannot use")
        }
    }

    /// **It costs textures, not nodes**, which is the whole reason a kerb is
    /// in the ground's picture rather than a sprite laid over it. Sixteen
    /// masks against two street zones is a few dozen more entries in a cache
    /// that already holds a hundred; a sprite would have been one more node
    /// on every road tile in the city, and a built-out map has 1,387 of them.
    func testAKerbAddsNoNodes() {
        let renderer = IsoTileRenderer(projection: Isometric(tileWidth: 64))
        let tile = Tile(position: GridPosition(x: 4, y: 4), zone: .road, density: 0)
        let surrounded = renderer.makeNode(for: tile, roadNeighbours: 0b1111)
        let stub = renderer.makeNode(for: tile, roadNeighbours: 0)
        XCTAssertEqual(surrounded.children.count, stub.children.count,
                       "a kerbed street carries more nodes than an uninterrupted one")
        XCTAssertEqual(stub.children.filter { $0 is SKShapeNode }.count, 0,
                       "the pavement arrived as shape nodes, which do not batch")
    }
}
