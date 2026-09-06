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
    func testAllSixFundableServicesTrackIndependently() {
        var funding = ServiceFunding()
        funding.setLevel(0.5, for: .policeStation)
        funding.setLevel(0.75, for: .fireStation)
        funding.setLevel(1.25, for: .publicTransit)
        funding.setLevel(1.5, for: .powerPlant)
        funding.setLevel(0.25, for: .stadium)
        funding.setLevel(0.6, for: .subway)

        XCTAssertEqual(funding.level(for: .policeStation), 0.5)
        XCTAssertEqual(funding.level(for: .fireStation), 0.75)
        XCTAssertEqual(funding.level(for: .publicTransit), 1.25)
        XCTAssertEqual(funding.level(for: .powerPlant), 1.5)
        XCTAssertEqual(funding.level(for: .stadium), 0.25)
        XCTAssertEqual(funding.level(for: .subway), 0.6)
    }

    /// Zoned land, roads, `.highway`, and `.empty` aren't fundable —
    /// `setLevel` is a harmless no-op for them rather than trapping, so a
    /// caller iterating every `ZoneType` doesn't need to filter down to the
    /// fundable ones first. `.highway` specifically: it's a pricier road,
    /// not a service — no staff to fund, same as plain `.road`.
    func testSetLevelIsANoOpForNonFundableZones() {
        var funding = ServiceFunding()
        funding.setLevel(0.1, for: .residential)
        funding.setLevel(0.1, for: .commercial)
        funding.setLevel(0.1, for: .industrial)
        funding.setLevel(0.1, for: .road)
        funding.setLevel(0.1, for: .highway)
        funding.setLevel(0.1, for: .empty)

        for zone in ZoneType.allCases {
            XCTAssertEqual(funding.level(for: zone), 1.0)
        }
    }
}
