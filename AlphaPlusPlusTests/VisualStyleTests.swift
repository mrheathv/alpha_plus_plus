import XCTest
@testable import AlphaPlusPlus

/// The look switch, and the screenshot controls beside it.
///
/// Whether Classic and Cinematic actually draw differently is asserted on the
/// Metal frame itself (`MetalLookTests`); these pin that the setting reaches
/// the value the renderer reads, and that the screenshot controls reach the
/// view.
@MainActor
final class VisualStyleTests: XCTestCase {

    /// `VisualStyle.current` is global, so a test that leaves it moved would
    /// silently restyle every render test that runs after it.
    private var original: VisualStyle!

    override func setUp() {
        super.setUp()
        original = VisualStyle.current
    }

    override func tearDown() {
        VisualStyle.current = original
        super.tearDown()
    }

    private func controller() -> GameController {
        var map = CityMap(width: 12, height: 12)
        for x in 2 ..< 10 { map[GridPosition(x: x, y: 5)].zone = .road }
        return GameController(map: map, rng: SeededRNG(seed: 4))
    }

    func testTheControllerAndTheRendererNeverDisagree() {
        let controller = controller()
        controller.visualStyle = .classic
        XCTAssertEqual(VisualStyle.current, .classic)
        controller.visualStyle = .cinematic
        XCTAssertEqual(VisualStyle.current, .cinematic,
                       "the published setting and the value the renderer reads have drifted apart")
    }

    /// Screenshot mode is a mode, so it has to be one someone can leave.
    func testScreenshotModeIsOffByDefaultAndReversible() {
        let controller = controller()
        XCTAssertFalse(controller.isScreenshotMode)
        controller.isScreenshotMode = true
        controller.isScreenshotMode = false
        XCTAssertFalse(controller.isScreenshotMode)
    }

    /// The menu cannot reach the map view's renderer, so it bumps a counter
    /// the view watches, the same shape `cityGeneration` uses.
    func testAskingForACaptureReachesTheView() {
        let controller = controller()
        let before = controller.screenshotRequests
        controller.requestScreenshot()
        XCTAssertEqual(controller.screenshotRequests, before + 1,
                       "the capture command does not reach the view that draws the city")
    }
}
