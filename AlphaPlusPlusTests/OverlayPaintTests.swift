import AppKit
import XCTest
@testable import AlphaPlusPlus

/// **What each view says about each tile**, asked of `IsoTileRenderer.paint`
/// directly: the one decision both renderers draw from (M8). Moved out of
/// `IsometricCityTests`, which tested SpriteKit's nodes and goes with them;
/// these never touched a node, so they survive it.
final class OverlayPaintTests: XCTestCase {

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

    /// The two supply routes have different shapes, and the difference between
    /// them is the pipe you did not need to lay.
    func testTheGroundTellsRadiusCoverageApartFromPipeCoverage() {
        let unserved = RenderPalette.supplyGroundColor(isPipe: true, supplied: false, direct: false)
        let viaRadius = RenderPalette.supplyGroundColor(isPipe: true, supplied: true, direct: true)
        let viaPipe = RenderPalette.supplyGroundColor(isPipe: true, supplied: true, direct: false)

        func brightness(_ color: NSColor) -> CGFloat {
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
        func brightness(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat) {
            let c = color.usingColorSpace(.deviceRGB)!
            return (c.redComponent, c.greenComponent, c.blueComponent)
        }
        let water = brightness(RenderPalette.conduitColor(isPipe: true, live: true))
        let power = brightness(RenderPalette.conduitColor(isPipe: false, live: true))
        XCTAssertGreaterThan(water.2, water.0, "water does not read as blue")
        XCTAssertGreaterThan(power.0, power.2, "power does not read as yellow")
    }
}
