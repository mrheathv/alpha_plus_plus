import XCTest
@testable import AlphaPlusPlus

/// `ZoneDistanceField` replaces a full map scan with a precomputed distance
/// transform, so the only thing that really matters about it is that it gives
/// *exactly* the same answers. A faster land-value calculation that is subtly
/// different is not an optimization, it is a balance change nobody asked for.
///
/// These tests therefore lean on equivalence against the original scan rather
/// than on hand-computed expectations: the scan is the specification.
final class ZoneDistanceFieldTests: XCTestCase {

    /// The scan `LandValue.distanceToNearest` does when no field is supplied,
    /// reproduced here so a test can compare against it directly.
    private func scanDistance(to zone: ZoneType, from position: GridPosition, in map: CityMap) -> Int? {
        map.tiles
            .filter { $0.zone == zone }
            .map { position.manhattanDistance(to: $0.position) }
            .min()
    }

    /// A map with every queried zone type on it, placed irregularly rather
    /// than on a neat grid — a distance transform that only works for
    /// symmetric layouts would pass a tidier fixture.
    private func makeMixedMap(size: Int = 24) -> CityMap {
        var map = CityMap(width: size, height: size)
        map.placeBuilding(zone: .road, origin: GridPosition(x: 3, y: 0))
        for x in 0 ..< size {
            map.placeBuilding(zone: .road, origin: GridPosition(x: x, y: 5))
        }
        for y in 6 ..< size {
            map.placeBuilding(zone: .highway, origin: GridPosition(x: 17, y: y))
        }
        map.placeBuilding(zone: .publicTransit, origin: GridPosition(x: 2, y: 9))
        map.placeBuilding(zone: .subway, origin: GridPosition(x: 21, y: 2))
        map.placeBuilding(zone: .policeStation, origin: GridPosition(x: 8, y: 12))
        map.placeBuilding(zone: .fireStation, origin: GridPosition(x: 14, y: 3))
        map.placeBuilding(zone: .stadium, origin: GridPosition(x: 5, y: 18))
        map.placeBuilding(zone: .powerPlant, origin: GridPosition(x: 19, y: 19))
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 0, y: 22))
        map.placeBuilding(zone: .residential, origin: GridPosition(x: 10, y: 7))
        map.placeBuilding(zone: .commercial, origin: GridPosition(x: 12, y: 15))
        map.placeBuilding(zone: .industrial, origin: GridPosition(x: 2, y: 2))
        return map
    }

    // MARK: - Equivalence with the scan it replaces

    func testTheFieldMatchesTheScanForEveryZoneAtEveryTile() {
        let map = makeMixedMap()
        let field = ZoneDistanceField.compute(for: map)

        for zone in ZoneType.allCases {
            for y in 0 ..< map.height {
                for x in 0 ..< map.width {
                    let position = GridPosition(x: x, y: y)
                    XCTAssertEqual(
                        field.distance(to: zone, at: position),
                        scanDistance(to: zone, from: position, in: map),
                        "disagreement for \(zone) at (\(x), \(y))"
                    )
                }
            }
        }
    }

    /// The property that makes the whole optimization safe: land value
    /// computed with a field equals land value computed without one, tile for
    /// tile. This is the assertion that would catch the field being wired up
    /// wrongly even if the raw distances were right.
    func testLandValueIsIdenticalWithAndWithoutAField() {
        let map = makeMixedMap()
        let field = ZoneDistanceField.compute(for: map)

        for y in 0 ..< map.height {
            for x in 0 ..< map.width {
                let position = GridPosition(x: x, y: y)
                XCTAssertEqual(
                    LandValue.value(at: position, in: map, using: field),
                    LandValue.value(at: position, in: map),
                    accuracy: 1e-12,
                    "land value differs at (\(x), \(y))"
                )
            }
        }
    }

    /// Same equivalence for the coverage query `CityHazards` uses, which asks
    /// about one specific service rather than the combined score.
    func testFalloffValueIsIdenticalWithAndWithoutAField() {
        let map = makeMixedMap()
        let field = ZoneDistanceField.compute(for: map)

        for zone in [ZoneType.policeStation, .fireStation] {
            for y in 0 ..< map.height {
                for x in 0 ..< map.width {
                    let position = GridPosition(x: x, y: y)
                    XCTAssertEqual(
                        LandValue.falloffValue(
                            nearestZone: zone, falloffDistance: LandValue.serviceFalloffDistance,
                            at: position, in: map, using: field
                        ),
                        LandValue.falloffValue(
                            nearestZone: zone, falloffDistance: LandValue.serviceFalloffDistance,
                            at: position, in: map
                        ),
                        accuracy: 1e-12,
                        "\(zone) coverage differs at (\(x), \(y))"
                    )
                }
            }
        }
    }

    /// Service funding must keep working through the field path — it is read
    /// live rather than baked in, so that moving a slider takes effect at once
    /// instead of at the next field rebuild.
    func testFundingStillScalesValuesReadThroughAField() {
        var map = makeMixedMap()
        let position = GridPosition(x: 8, y: 14)
        let field = ZoneDistanceField.compute(for: map)

        let fullyFunded = LandValue.falloffValue(
            nearestZone: .policeStation, falloffDistance: LandValue.serviceFalloffDistance,
            at: position, in: map, using: field
        )
        XCTAssertGreaterThan(fullyFunded, 0)

        map.serviceFunding.setLevel(0.5, for: .policeStation)
        // Same field — only the funding changed.
        let halfFunded = LandValue.falloffValue(
            nearestZone: .policeStation, falloffDistance: LandValue.serviceFalloffDistance,
            at: position, in: map, using: field
        )
        XCTAssertEqual(halfFunded, fullyFunded * 0.5, accuracy: 1e-12)
    }

    // MARK: - Direct properties

    func testDistanceIsZeroOnTheZoneItself() {
        let map = makeMixedMap()
        let field = ZoneDistanceField.compute(for: map)
        XCTAssertEqual(field.distance(to: .fireStation, at: GridPosition(x: 14, y: 3)), 0)
    }

    func testDistanceIsNilForAZoneThatIsNotOnTheMap() {
        let map = CityMap(width: 8, height: 8)
        let field = ZoneDistanceField.compute(for: map)
        XCTAssertNil(field.distance(to: .policeStation, at: GridPosition(x: 0, y: 0)))
    }

    func testDistanceIsNilOutsideTheMap() {
        let map = makeMixedMap()
        let field = ZoneDistanceField.compute(for: map)
        XCTAssertNil(field.distance(to: .road, at: GridPosition(x: -1, y: 0)))
        XCTAssertNil(field.distance(to: .road, at: GridPosition(x: 0, y: map.height)))
    }

    /// A transform that only swept in one direction would get distances right
    /// for sources below-and-left of a tile and wrong for sources above or to
    /// the right. This pins both sweeps by putting the only source in the
    /// far corner and measuring from the origin.
    func testDistanceIsCorrectForASourceAboveAndRightOfTheQuery() {
        var map = CityMap(width: 10, height: 10)
        map.placeBuilding(zone: .road, origin: GridPosition(x: 9, y: 9))
        let field = ZoneDistanceField.compute(for: map)

        XCTAssertEqual(field.distance(to: .road, at: GridPosition(x: 0, y: 0)), 18)
        XCTAssertEqual(field.distance(to: .road, at: GridPosition(x: 9, y: 0)), 9)
        XCTAssertEqual(field.distance(to: .road, at: GridPosition(x: 0, y: 9)), 9)
    }

    /// Non-square maps are supported (`CityMap` allows them, even though
    /// `MapSize` only offers squares), and are exactly where a row/column
    /// indexing mistake shows up.
    func testANonSquareMapIndexesCorrectly() {
        var map = CityMap(width: 13, height: 5)
        map.placeBuilding(zone: .road, origin: GridPosition(x: 12, y: 4))
        let field = ZoneDistanceField.compute(for: map)

        for y in 0 ..< map.height {
            for x in 0 ..< map.width {
                let position = GridPosition(x: x, y: y)
                XCTAssertEqual(
                    field.distance(to: .road, at: position),
                    scanDistance(to: .road, from: position, in: map),
                    "disagreement at (\(x), \(y)) on a non-square map"
                )
            }
        }
    }
}
