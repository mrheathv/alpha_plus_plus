import XCTest
@testable import AlphaPlusPlus

/// **A funding dial added later must not make every existing city unreadable.**
///
/// `ServiceFunding` decodes through the synthesised `Codable` conformance,
/// which throws on a *missing* key even where the property has a default —
/// the trap `CitySave` already records for `CityMap` itself, where
/// `pollution`, `ordinances` and `taxRate` each silently broke saves and none
/// bumped the format version.
///
/// Adding `ports` for the seaport and the airport walked straight into it.
/// These tests are written against the shape of the bug rather than that one
/// field, so the *next* dial cannot reintroduce it.
final class ServiceFundingCodableTests: XCTestCase {

    private func decode(_ json: String) throws -> ServiceFunding {
        try JSONDecoder().decode(ServiceFunding.self, from: Data(json.utf8))
    }

    /// A city saved before the ports dial existed. Every key it knew about,
    /// and nothing else.
    private let cityFromBeforeTheDocks = """
    {"policeStation":1.0,"fireStation":1.0,"publicTransit":1.0,"powerPlant":1.0,
     "stadium":1.0,"subway":1.0,"tramStop":1.0,"railStation":1.0,
     "waterTower":1.0,"school":1.0,"hospital":1.0,"road":1.0}
    """

    func testASaveWrittenBeforeThePortsDialStillLoads() throws {
        let funding = try decode(cityFromBeforeTheDocks)
        XCTAssertEqual(funding.ports, 1.0, "a missing dial has to come back as its default")
        XCTAssertEqual(funding.hospital, 1.0)
    }

    /// The general form, and the reason this file exists rather than one
    /// assertion about `ports`: **any** single dial may be absent, because
    /// that is what a save written before it looked like.
    func testEveryDialCanBeAbsent() throws {
        let all = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(ServiceFunding())
        ) as? [String: Any] ?? [:]
        XCTAssertFalse(all.isEmpty, "nothing encoded — the shape of this test is wrong")

        for missing in all.keys {
            var trimmed = all
            trimmed.removeValue(forKey: missing)
            let data = try JSONSerialization.data(withJSONObject: trimmed)
            XCTAssertNoThrow(
                try JSONDecoder().decode(ServiceFunding.self, from: data),
                "a save with no \"\(missing)\" key is unreadable — adding that dial "
                + "broke every city written before it"
            )
        }
    }

    /// And the values that *are* present still arrive, so decoding leniently
    /// has not quietly turned the whole type into its defaults.
    func testWhatIsPresentIsStillRead() throws {
        var funding = ServiceFunding()
        funding.hospital = 0.25
        funding.ports = 1.75
        let round = try JSONDecoder().decode(
            ServiceFunding.self, from: try JSONEncoder().encode(funding)
        )
        XCTAssertEqual(round, funding)
    }
}
