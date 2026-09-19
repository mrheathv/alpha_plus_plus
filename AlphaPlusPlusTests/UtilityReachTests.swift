import XCTest
import SpriteKit
@testable import AlphaPlusPlus

/// A main is an area, not a line.
///
/// Laying pipe used to be a *tracing* exercise — follow every street past
/// every building, where the only skill was not missing one. With a radius it
/// is a *spacing* one, and the decision is where the trunk mains go.
@MainActor
final class UtilityReachTests: XCTestCase {

    /// A source at the far corner and a single main running east, with
    /// nothing else on the map — so anything served is served by the pipe.
    private func trunk(length: Int = 30, at y: Int = 10) -> CityMap {
        var map = CityMap(width: length, height: 20)
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 0, y: y))
        for x in 0 ..< length { map[GridPosition(x: x, y: y)].hasPipe = true }
        map.waterSupply = Water.computeSupply(for: map)
        return map
    }

    private func served(_ map: CityMap, _ x: Int, _ y: Int) -> Bool {
        Water.hasSupply(at: GridPosition(x: x, y: y), in: map)
    }

    // MARK: - The reach

    /// **The mechanic.** A building three streets from the main still gets
    /// water, which is the whole difference between laying a lattice and
    /// tracing every frontage.
    func testAMainServesWellBeyondWhatItTouches() {
        let map = trunk()
        let far = 20  // clear of the tower's own `directSupplyRadius`
        for distance in 0 ... Water.pipeSupplyRadius {
            XCTAssertTrue(served(map, far, 10 + distance),
                          "a main did not reach \(distance) tiles")
        }
        XCTAssertFalse(served(map, far, 10 + Water.pipeSupplyRadius + 1),
                       "a main reached past its own radius")
    }

    /// And the reach is a *diamond*, the same Manhattan shape every other
    /// coverage question in this game uses — not a square, which would make
    /// a main quietly better on the diagonal for no reason anyone could work
    /// out.
    ///
    /// Measured past the **end** of a run, because a continuous one cannot
    /// show it: every band along a straight main merges into a straight edge,
    /// so the nearest pipe to any tile beside it is the one directly across,
    /// and the corner never appears. The first version of this test asserted
    /// against the middle of a run and was simply wrong about its own
    /// geometry.
    func testTheReachIsTheSameShapeAsEveryOtherCoverage() {
        var map = CityMap(width: 40, height: 20)
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 0, y: 10))
        for x in 0 ... 20 { map[GridPosition(x: x, y: 10)].hasPipe = true }
        map.waterSupply = Water.computeSupply(for: map)

        let r = Water.pipeSupplyRadius
        // Straight off the end: served at exactly the radius.
        XCTAssertTrue(served(map, 20 + r, 10))
        // The same Chebyshev distance, but one further by Manhattan — which
        // is the corner a square would have covered and a diamond does not.
        XCTAssertFalse(served(map, 20 + r, 11), "the reach is a square, not a diamond")
        XCTAssertTrue(served(map, 20 + r - 1, 11))
    }

    /// **The spacing puzzle, stated as a test.** Two mains whose bands meet
    /// leave no gap; pull them apart and a street in the middle goes dry.
    /// That is the decision the radius exists to create.
    func testTrunkMainsCoverEverythingBetweenThemUntilTheyAreTooFarApart() {
        func city(gap: Int) -> CityMap {
            var map = CityMap(width: 30, height: 40)
            map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 0, y: 0))
            for x in 0 ..< 30 {
                map[GridPosition(x: x, y: 20)].hasPipe = true
                map[GridPosition(x: x, y: 20 + gap)].hasPipe = true
            }
            // The trunk that ties them back to the tower.
            for y in 0 ... 20 + gap { map[GridPosition(x: 0, y: y)].hasPipe = true }
            map.waterSupply = Water.computeSupply(for: map)
            return map
        }

        let touching = city(gap: Water.pipeSupplyRadius * 2 + 1)
        for y in 20 ... 20 + Water.pipeSupplyRadius * 2 + 1 {
            XCTAssertTrue(served(touching, 20, y), "a gap at y=\(y) between mains that should meet")
        }

        let tooFar = city(gap: Water.pipeSupplyRadius * 2 + 3)
        XCTAssertFalse(served(tooFar, 20, 20 + Water.pipeSupplyRadius + 1),
                       "mains spaced too far apart left no dry street between them")
    }

    /// A run that reaches no source reaches nobody, radius or not. "Did that
    /// connect?" is still the only question a player is asking while laying
    /// pipe.
    func testAnOrphanedRunServesNothingInsideItsRadius() {
        var map = trunk()
        for y in 0 ..< 20 { map[GridPosition(x: 25, y: y)].hasPipe = true }
        // Cut it off from the trunk.
        map[GridPosition(x: 25, y: 10)].hasPipe = false
        map.waterSupply = Water.computeSupply(for: map)

        XCTAssertFalse(served(map, 25, 3), "an orphaned run supplied a building anyway")
    }

    // MARK: - Condition

    /// **A neglected main stops reaching the far side of the street before it
    /// bursts.** Without this the radius quietly undid all of phase 6: mains
    /// laid three rows apart cover each other two and three times over, so
    /// losing one to a burst changed nothing, and the playtest harness
    /// measured neglect becoming the *dominant* strategy — a city that
    /// stopped paying for public works ended up richer and no smaller.
    func testAWornMainReachesLessFar() {
        var fresh = trunk()
        var worn = trunk()
        for x in 0 ..< worn.width { worn[GridPosition(x: x, y: 10)].wear = 0.7 }
        worn.waterSupply = Water.computeSupply(for: worn)

        let edge = 10 + Water.pipeSupplyRadius
        XCTAssertTrue(served(fresh, 20, edge))
        XCTAssertFalse(served(worn, 20, edge), "wear cost a main none of its reach")
        // It has not failed outright — it still serves what is beside it.
        XCTAssertTrue(served(worn, 20, 11), "a merely worn main stopped serving anything at all")
        _ = fresh
    }

    // MARK: - Power says the same thing

    /// The two utilities behave identically on purpose: two networks that
    /// differed for no reason a player could work out is the kind of rule
    /// this project has had to go back and delete before.
    func testPowerLinesReachExactlyAsFarAsPipes() {
        XCTAssertEqual(PowerGrid.lineSupplyRadius, Water.pipeSupplyRadius)

        var map = CityMap(width: 30, height: 20)
        map.placeBuilding(zone: .powerPlant, origin: GridPosition(x: 0, y: 9))
        for x in 0 ..< 30 { map[GridPosition(x: x, y: 10)].hasPowerLine = true }
        map.powerSupply = PowerGrid.computeSupply(for: map, outageActive: false)

        let far = 20
        XCTAssertTrue(PowerGrid.hasSupply(at: GridPosition(x: far, y: 10 + PowerGrid.lineSupplyRadius), in: map))
        XCTAssertFalse(PowerGrid.hasSupply(at: GridPosition(x: far, y: 10 + PowerGrid.lineSupplyRadius + 1), in: map))
    }

    // MARK: - What the overlay says about it

    /// **Three answers, not two.** A house too small to need water yet and a
    /// tower dying for want of a main are not the same thing, and painting
    /// both near-black made the map claim a problem that was not there —
    /// exactly the failure the crime overlay had to be fixed for.
    func testTheOverlayTellsWantingApartFromNotNeeding() throws {
        var map = CityMap(width: 20, height: 20)
        for x in 0 ..< 20 { map[GridPosition(x: x, y: 0)].zone = .road }
        // One lot too small to care, one big enough to be held back.
        let small = GridPosition(x: 2, y: 1)
        let big = GridPosition(x: 8, y: 1)
        for (origin, density) in [(small, 0), (big, 3)] {
            map.placeBuilding(zone: .residential, origin: origin)
            for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = density }
        }

        func paint(_ at: GridPosition) throws -> IsoTileRenderer.OverlayPaint {
            try XCTUnwrap(IsoTileRenderer.paint(for: .water, at: at, in: map, using: nil))
        }
        let quiet = try paint(small)
        let wanting = try paint(big)

        XCTAssertEqual(quiet.buildings, .connected(false), "a lot that wants nothing was flagged")
        XCTAssertEqual(wanting.buildings, .connected(true),
                       "a lot held back for want of water was painted as quietly irrelevant")
        XCTAssertEqual(components(wanting.buildingColor), components(RenderPalette.utilityWanted))
        XCTAssertNotEqual(components(quiet.buildingColor), components(wanting.buildingColor))
    }

    /// And a served building is neither of those: it says so in the utility's
    /// own colour, which is the reading all four network overlays share.
    func testAServedBuildingStillReadsAsServed() throws {
        var map = CityMap(width: 20, height: 20)
        for x in 0 ..< 20 { map[GridPosition(x: x, y: 0)].zone = .road }
        let home = GridPosition(x: 8, y: 1)
        map.placeBuilding(zone: .residential, origin: home)
        for cell in map.footprintCells(origin: home, size: 2) { map[cell].density = 3 }
        map.placeBuilding(zone: .waterTower, origin: GridPosition(x: 8, y: 5))
        map.waterSupply = Water.computeSupply(for: map)

        let paint = try XCTUnwrap(IsoTileRenderer.paint(for: .water, at: home, in: map, using: nil))
        XCTAssertEqual(paint.buildings, .connected(true))
        XCTAssertEqual(components(paint.buildingColor),
                       components(RenderPalette.conduitColor(isPipe: true, live: true)))
    }

    private func components(_ color: SKColor) -> [CGFloat] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.usingColorSpace(.deviceRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a].map { ($0 * 1000).rounded() / 1000 }
    }
}
