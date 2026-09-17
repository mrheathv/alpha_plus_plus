import XCTest
@testable import AlphaPlusPlus

final class ServiceFundingTests: XCTestCase {

    func testEveryZoneReportsFullFundingByDefault() {
        let funding = ServiceFunding()
        for zone in ZoneType.allCases {
            XCTAssertEqual(funding.level(for: zone), 1.0)
        }
    }

    func testSetLevelChangesOnlyTheTargetedZone() {
        var funding = ServiceFunding()
        funding.setLevel(0.5, for: .fireStation)

        XCTAssertEqual(funding.level(for: .fireStation), 0.5)
        XCTAssertEqual(funding.level(for: .policeStation), 1.0)
        XCTAssertEqual(funding.level(for: .publicTransit), 1.0)
        XCTAssertEqual(funding.level(for: .powerPlant), 1.0)
        XCTAssertEqual(funding.level(for: .stadium), 1.0)
    }

    /// Every fundable service gets its own independent dial — setting one
    /// must never bleed into another.
    func testAllSevenFundableServicesTrackIndependently() {
        var funding = ServiceFunding()
        funding.setLevel(0.5, for: .policeStation)
        funding.setLevel(0.75, for: .fireStation)
        funding.setLevel(1.25, for: .publicTransit)
        funding.setLevel(1.5, for: .powerPlant)
        funding.setLevel(0.25, for: .stadium)
        funding.setLevel(0.6, for: .subway)
        funding.setLevel(0.8, for: .waterTower)

        XCTAssertEqual(funding.level(for: .policeStation), 0.5)
        XCTAssertEqual(funding.level(for: .fireStation), 0.75)
        XCTAssertEqual(funding.level(for: .publicTransit), 1.25)
        XCTAssertEqual(funding.level(for: .powerPlant), 1.5)
        XCTAssertEqual(funding.level(for: .stadium), 0.25)
        XCTAssertEqual(funding.level(for: .subway), 0.6)
        XCTAssertEqual(funding.level(for: .waterTower), 0.8)
    }

    /// Zoned land and `.empty` aren't fundable — `setLevel` is a harmless
    /// no-op for them rather than trapping, so a caller iterating every
    /// `ZoneType` doesn't need to filter down to the fundable ones first. (A
    /// pipe isn't a `ZoneType` at all any more — see `Tile.hasPipe` — so
    /// there's no "is a pipe fundable" case to even ask about here.)
    ///
    /// **`.road` and `.highway` used to be on this list**, on the reasoning
    /// that a road is infrastructure rather than a service: no staff to fund.
    /// Phase 6 makes them fundable, and the old reasoning was right about
    /// coverage and wrong about cost — a road has no catchment for funding to
    /// scale, but it does wear out, and public works is the budget that keeps
    /// it from doing so. See `Infrastructure`.
    func testSetLevelIsANoOpForZonedLand() {
        var funding = ServiceFunding()
        funding.setLevel(0.1, for: .residential)
        funding.setLevel(0.1, for: .commercial)
        funding.setLevel(0.1, for: .industrial)
        funding.setLevel(0.1, for: .empty)

        for zone in ZoneType.allCases {
            XCTAssertEqual(funding.level(for: zone), 1.0,
                           "\(zone.rawValue) took a funding level it should have ignored")
        }
    }

    /// The counterpart, so "roads are fundable now" is pinned rather than
    /// merely no longer contradicted.
    func testRoadsAreFundableAndShareOneDialWithHighways() {
        var funding = ServiceFunding()
        funding.setLevel(0.1, for: .road)

        XCTAssertEqual(funding.level(for: .road), 0.1)
        XCTAssertEqual(funding.level(for: .highway), 0.1,
                       "a highway is still a road as far as the public-works budget goes")
        // And nothing else moved with it.
        for zone in ZoneType.allCases where zone != .road && zone != .highway {
            XCTAssertEqual(funding.level(for: zone), 1.0,
                           "funding public works also changed \(zone.rawValue)")
        }
    }
}
