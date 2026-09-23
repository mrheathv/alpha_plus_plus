import XCTest
@testable import AlphaPlusPlus

/// The guided first city.
///
/// The one test here that matters most is the walk-through: a real
/// controller, real placements and real ticks, finishing each step by doing
/// what its text says. A guide whose steps can only be finished in a unit test
/// that hands it a `State` is a guide nobody can finish.
@MainActor
final class FirstCityGuideTests: XCTestCase {

    private func foundedCity() -> GameController {
        let controller = GameController(rng: AlwaysZeroRNG())
        controller.resetMap(guided: true)
        return controller
    }

    @discardableResult
    private func build(_ zone: ZoneType, at positions: [GridPosition],
                       in controller: GameController) -> [GameController.PlacementOutcome] {
        controller.selectTool(zone)
        return positions.map { controller.place(at: $0) }
    }

    private let street = (0 ..< 12).map { GridPosition(x: $0, y: 4) }

    // MARK: - The walk-through

    func testAFirstCityCanBeWalkedThroughByDoingWhatEachStepSays() {
        let controller = foundedCity()
        XCTAssertEqual(controller.guide?.current, .road)

        build(.road, at: street, in: controller)
        XCTAssertEqual(controller.guide?.current, .housing)

        build(.residential, at: [GridPosition(x: 0, y: 5), GridPosition(x: 2, y: 5)], in: controller)
        XCTAssertEqual(controller.guide?.current, .jobs)

        build(.commercial, at: [GridPosition(x: 4, y: 5)], in: controller)
        XCTAssertEqual(controller.guide?.current, .jobs, "shops alone are not jobs *and* industry")
        build(.industrial, at: [GridPosition(x: 6, y: 5)], in: controller)
        XCTAssertEqual(controller.guide?.current, .play)

        controller.perform(.play)
        XCTAssertEqual(controller.guide?.current, .growth)

        for _ in 0 ..< 200 where controller.population == 0 {
            controller.advanceSimulation()
        }
        XCTAssertGreaterThan(controller.population, 0, "the fixture never grew, so the growth step is untested")
        XCTAssertEqual(controller.guide?.current, .water)

        build(.waterPump, at: [GridPosition(x: 8, y: 5)], in: controller)
        XCTAssertEqual(controller.guide?.current, .power)

        build(.generator, at: [GridPosition(x: 9, y: 5)], in: controller)
        XCTAssertEqual(controller.guide?.current, .problems)

        controller.perform(.showView(.problems))
        XCTAssertEqual(controller.guide?.current, .services)
    }

    // MARK: - Progress is a record, not a reading

    /// A pump put down before the clock was ever started has done the water
    /// step. Asking for it again later would be teaching the player something
    /// they have already shown they know.
    func testAStepDoneEarlyIsAlreadyDoneWhenTheGuideReachesIt() {
        let controller = foundedCity()
        build(.waterPump, at: [GridPosition(x: 8, y: 8)], in: controller)

        XCTAssertEqual(controller.guide?.current, .road, "doing a later step must not skip the earlier ones")
        XCTAssertTrue(controller.guide?.completed.contains(.water) ?? false)
    }

    func testBulldozingTheRoadDoesNotUnteachRoads() {
        let controller = foundedCity()
        build(.road, at: street, in: controller)
        XCTAssertEqual(controller.guide?.current, .housing)

        build(.empty, at: street, in: controller)
        XCTAssertEqual(controller.guide?.current, .housing)
    }

    /// A transient state — a view left, a panel closed — still counts, because
    /// the player did the thing.
    func testLeavingTheViewAfterwardsKeepsTheStep() {
        let controller = foundedCity()
        controller.perform(.showView(.problems))
        controller.overlayMode = .none
        XCTAssertTrue(controller.guide?.completed.contains(.problems) ?? false)
    }

    // MARK: - Every step can be answered right now

    /// **Every step's button does its step**, or equips the one tool that does.
    ///
    /// This project's standing rule — every warning has an answer the player
    /// can act on right now — applied to instructions. A shortcut that opened
    /// the wrong view, or a tool that could not finish the step, would be a
    /// button that lies, and it would look exactly like a working one.
    func testEveryShortcutAnswersItsOwnStep() {
        for step in FirstCityGuide.Step.allCases {
            guard let shortcut = step.shortcut else { continue }
            let controller = foundedCity()
            controller.perform(shortcut)

            switch shortcut {
            case .selectTool(let zone):
                XCTAssertEqual(controller.selectedTool, zone, "\(step)")
                XCTAssertEqual(controller.overlayMode, .none,
                               "\(step): a picked tool must place rather than edit a network")
                // The tool has to be one that can actually finish the step.
                var state = FirstCityGuide.State()
                switch zone {
                case .road: state.roadTiles = FirstCityGuide.Step.roadTilesWanted
                case .residential: state.residentialLots = 2
                case .commercial: state.commercialLots = 1; state.industrialLots = 1
                case .waterPump: state.hasWaterSource = true
                case .generator: state.hasPowerSource = true
                case .fireStation: state.hasEmergencyService = true
                default: XCTFail("\(step): no fixture for \(zone)")
                }
                XCTAssertTrue(step.isDone(in: state), "\(step): \(zone) cannot finish it")
            default:
                XCTAssertTrue(controller.guide?.completed.contains(step) ?? false,
                              "\(step): its own button did not finish it")
            }
        }
    }

    /// The only step whose tool is locked on a fresh city is the fire station,
    /// and the panel says so rather than offering a button that does nothing.
    /// Pinned so a new step that asks for something locked has to be noticed.
    func testOnlyTheServicesStepAsksForALockedTool() {
        let controller = foundedCity()
        let locked = FirstCityGuide.Step.allCases.filter {
            guard case .selectTool(let zone)? = $0.shortcut else { return false }
            return !controller.isUnlocked(zone)
        }
        XCTAssertEqual(locked, [.services])
    }

    // MARK: - Lifecycle

    func testAPlainResetFoundsACityWithNoGuide() {
        let controller = GameController()
        controller.resetMap()
        XCTAssertNil(controller.guide)
    }

    func testLoadingACityEndsTheGuide() throws {
        let controller = foundedCity()
        try controller.restore(from: GameController().snapshot())
        XCTAssertNil(controller.guide)
    }

    /// The new city's guide must not inherit anything from the old one.
    func testFoundingAgainStartsTheGuideFromTheTop() {
        let controller = foundedCity()
        build(.road, at: street, in: controller)
        controller.resetMap(guided: true)
        XCTAssertEqual(controller.guide?.completedCount, 0)
    }

    func testTheGuideFinishesAndCanBePutAway() {
        var guide = FirstCityGuide()
        var state = FirstCityGuide.State()
        state.roadTiles = 10; state.residentialLots = 2; state.commercialLots = 1
        state.industrialLots = 1; state.isRunning = true; state.population = 5
        state.hasWaterSource = true; state.hasPowerSource = true
        state.overlay = .problems; state.hasEmergencyService = true
        XCTAssertFalse(guide.update(with: state) && guide.isFinished, "City Hall has not been visited")
        state.isShowingCityPanel = true
        guide.update(with: state)
        XCTAssertTrue(guide.isFinished)

        let controller = foundedCity()
        controller.dismissGuide()
        XCTAssertNil(controller.guide)
    }

    func testEveryStepHasWords() {
        for step in FirstCityGuide.Step.allCases {
            XCTAssertFalse(GuideText.title(for: step).isEmpty, "\(step)")
            XCTAssertFalse(GuideText.body(for: step).isEmpty, "\(step)")
            // One or two sentences. A step that needs a paragraph is two steps.
            XCTAssertLessThan(GuideText.body(for: step).count, 140, "\(step)")
        }
    }
}
