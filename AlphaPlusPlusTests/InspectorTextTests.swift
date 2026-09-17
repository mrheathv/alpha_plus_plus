import XCTest
@testable import AlphaPlusPlus

/// The inspector's wording — the layer that turns what the simulation knows
/// into what a player reads.
@MainActor
final class InspectorTextTests: XCTestCase {

    private func report(_ status: LotStatus, zone: ZoneType = .residential,
                        density: Int = 2, landValue: Double = 0.5) -> TileReport {
        TileReport(
            position: GridPosition(x: 0, y: 0), zone: zone, status: status,
            density: density, maxDensity: zone.maxDensity,
            population: density * zone.populationPerDensityLevel,
            jobs: density * zone.jobsPerDensityLevel,
            hasWater: false, hasPower: false,
            policeCoverage: 0, fireCoverage: 0, schoolCoverage: 0, hospitalCoverage: 0,
            landValue: landValue, pollution: 0, congestion: 0, infrastructureCondition: 1,
            commuteFound: nil, isExposedToCrime: false, isExposedToFire: false
        )
    }

    private var everyStatus: [LotStatus] {
        [.notGrowable, .noRoadAccess, .burning, .damaged(waitingFor: .fireStation),
         .underConstruction(remaining: 3, total: 8), .beingAbandoned,
         .decliningToSustainable(sustainable: 2), .atMaximumDensity,
         .needsLandValue(required: 0.8, current: 0.5), .needsWater, .needsPower,
         .needsSchool, .readyToGrow(demand: 0.5), .readyToGrow(demand: -0.5)]
    }

    // MARK: - Every state says something

    func testEveryStatusHasAHeadline() {
        for status in everyStatus {
            let headline = InspectorText.headline(for: report(status))
            XCTAssertFalse(headline.isEmpty, "\(status) has no headline")
            XCTAssertFalse(headline.hasPrefix("Optional"), "\(status) leaked a description")
        }
    }

    /// Anything a player can act on has to say what the action *is*. This
    /// project's standing rule is that every warning the game raises has an
    /// answer the player can take right now, and a panel that names a problem
    /// without naming its fix is the exact failure that rule exists to stop.
    func testEveryActionableStatusSaysWhatToDo() {
        let nothingToDo: [LotStatus] = [
            .notGrowable, .atMaximumDensity, .underConstruction(remaining: 3, total: 8),
            .readyToGrow(demand: 0.5),
        ]
        for status in everyStatus where !nothingToDo.contains(status) {
            let advice = InspectorText.advice(for: report(status))
            XCTAssertNotNil(advice, "\(status) names a problem and not its fix")
            XCTAssertGreaterThan(advice?.count ?? 0, 20, "\(status)'s advice is too terse to be advice")
        }
        for status in nothingToDo {
            XCTAssertNil(InspectorText.advice(for: report(status)),
                         "\(status) is fine and the panel is telling the player to fix it")
        }
    }

    /// "Nothing is wrong" and "nothing is wrong but the city wants no more of
    /// this" are different news, and only one of them is something to act on.
    func testWaitingForDemandReadsDifferentlyFromReadyToGrow() {
        XCTAssertEqual(InspectorText.headline(for: report(.readyToGrow(demand: 0.5))), "Ready to grow")
        XCTAssertEqual(InspectorText.headline(for: report(.readyToGrow(demand: -0.5))), "Waiting for demand")
        XCTAssertNil(InspectorText.advice(for: report(.readyToGrow(demand: 0.5))))
        XCTAssertNotNil(InspectorText.advice(for: report(.readyToGrow(demand: -0.5))))
    }

    /// A lot that is shrinking reads louder than one that is merely stuck.
    func testDeterioratingStatesGetTheLoudestColour() {
        for status in everyStatus where status.isDeteriorating {
            let accent = InspectorText.accent(for: status)
            XCTAssertNotEqual(accent, RetroUITheme.primaryAccent,
                              "\(status) is getting worse and reads as ordinary")
        }
        XCTAssertEqual(InspectorText.accent(for: .atMaximumDensity), RetroUITheme.primaryAccent)
    }

    // MARK: - The two the render caught

    /// **Bare ground introduced itself as "BULLDOZE".**
    /// `RenderPalette.displayName` is the *toolbar's* name for a zone, and the
    /// toolbar's name for `.empty` is the tool that produces it.
    func testBareGroundIsNotNamedAfterTheToolThatMakesIt() {
        XCTAssertEqual(InspectorText.title(for: .empty), "Unzoned land")
        XCTAssertEqual(InspectorText.headline(for: report(.notGrowable, zone: .empty)), "Unzoned land")
        // And the real zones keep the name the rest of the UI uses, so the
        // inspector and the toolbar never call the same thing two things.
        for zone in [ZoneType.residential, .commercial, .industrial, .road, .fireStation] {
            XCTAssertEqual(InspectorText.title(for: zone), RenderPalette.displayName(for: zone))
        }
    }

    /// **Plain road frontage read as "Prime".**
    ///
    /// Even bands over 0…1 put the *baseline* — a lot with a road and nothing
    /// else, which is 0.75 — in the top word, telling the player they had done
    /// a great job of a lot that cannot reach the top tier. The bands are cut
    /// at `CitySimulator.requiredLandValue` instead, so each word names the
    /// level that land actually supports.
    func testDesirabilityIsNamedAgainstTheLevelsItUnlocks() {
        XCTAssertEqual(InspectorText.desirability(0), "Poor")
        XCTAssertEqual(InspectorText.desirability(0.1), "Poor",
                       "land that cannot reach level 2 is not 'Fair'")

        let top = CitySimulator.requiredLandValue(toReach: ZoneType.residential.maxDensity)
        XCTAssertEqual(InspectorText.desirability(top), "Prime")
        XCTAssertEqual(InspectorText.desirability(1), "Prime")
        XCTAssertNotEqual(InspectorText.desirability(top - 0.01), "Prime",
                          "land one notch short of the top tier is being called Prime")

        // Monotonic, which a hand-written ladder is easy to get wrong.
        let ladder = stride(from: 0.0, through: 1.0, by: 0.05).map { InspectorText.desirability($0) }
        var seen: [String] = []
        for word in ladder where seen.last != word { seen.append(word) }
        XCTAssertEqual(seen, ["Poor", "Fair", "Good", "Strong", "Prime"],
                       "the desirability ladder skips or repeats a rung")
    }

    // MARK: - The other ratings

    func testTheEnvironmentRatingsCoverTheirWholeRange() {
        for (name, rate) in [("pollution", InspectorText.pollution),
                             ("traffic", InspectorText.traffic),
                             ("condition", InspectorText.condition)] {
            let words = stride(from: 0.0, through: 1.0, by: 0.05).map(rate)
            XCTAssertGreaterThan(Set(words).count, 2, "\(name) barely changes across its range")
            XCTAssertNotEqual(rate(0), rate(1), "\(name) reads the same empty as it does full")
        }
    }

    func testOccupancyReportsResidentsOrJobsAndSaysNothingWhenThereAreNeither() {
        XCTAssertEqual(InspectorText.occupancy(for: report(.atMaximumDensity, zone: .residential, density: 3)),
                       "\(3 * ZoneType.residential.populationPerDensityLevel) residents")
        XCTAssertEqual(InspectorText.occupancy(for: report(.atMaximumDensity, zone: .commercial, density: 2)),
                       "\(2 * ZoneType.commercial.jobsPerDensityLevel) jobs")
        // An empty lot saying "0 residents" is worse than saying nothing.
        XCTAssertNil(InspectorText.occupancy(for: report(.readyToGrow(demand: 0), density: 0)))
    }

    func testLevelIsOnlyReportedForSomethingThatGrows() {
        XCTAssertEqual(InspectorText.level(for: report(.atMaximumDensity, density: 4)), "Level 4 of 5")
        XCTAssertNil(InspectorText.level(for: report(.notGrowable, zone: .road, density: 0)))
    }
}
