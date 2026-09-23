import XCTest
@testable import AlphaPlusPlus

/// What `RandomScenePlayer` needs from a session, so the same player drives
/// the SpriteKit scene (until M8 deletes it) and the scene-free Metal
/// session below.
@MainActor
protocol PlaytestSession: AnyObject {
    var controller: GameController { get }
    /// Whether the session wants a frame after every action. A renderer that
    /// is asked each frame whether the city moved only sees a change the
    /// revision does not announce if something looks between changes.
    var wantsFramePerAction: Bool { get }
    func frame()
    func click(_ tool: ZoneType, at position: GridPosition)
    func drag(_ tool: ZoneType, from: GridPosition, to: GridPosition)
    func clickInView(at position: GridPosition)
    func dragInView(from: GridPosition, to: GridPosition)
    func bulldoze(at position: GridPosition)
    func look(at overlay: OverlayMode)
    func pause()
    func play()
    func beginLine(_ mode: TransitRoute.Mode)
    func finishLine()
    func borrowIfShort()
    func tick(_ count: Int)
    func check(_ what: String, file: StaticString, line: UInt)
}

extension ScenePlaytest: PlaytestSession {
    var wantsFramePerAction: Bool { metal != nil }
}

/// **The playtest with no scene in it** (M8). The same actions as
/// `ScenePlaytest`, driven the way the game now is: clicks through
/// `MapInteraction`, days through `CityClock`, the city drawn by a
/// `MetalCityRenderer` that reads the controller each frame exactly as the
/// Metal view does, and every check asked of `MetalAgreement`: is the
/// renderer updated change by change holding what one built fresh would?
@MainActor
final class CityPlaytest: PlaytestSession {

    let controller: GameController
    let input: MapInteraction
    let clock: CityClock
    let metal: MetalCityRenderer

    /// What has been done, printed with a failure, since a seeded random
    /// session cannot otherwise say how it got there.
    private(set) var log: [String] = []
    private func record(_ action: String) { log.append(action) }

    var wantsFramePerAction: Bool { true }

    init?(map: CityMap, seed: UInt64 = 0xA1F4) {
        guard let metal = MetalCityRenderer() else { return nil }
        controller = GameController(map: map, rng: SeededRNG(seed: seed),
                                    peakPopulation: Unlocks.everythingUnlocked)
        input = MapInteraction(controller: controller)
        clock = CityClock(controller: controller)
        self.metal = metal
        frame()
    }

    /// One turn of the frame loop: the renderer reads the controller, the
    /// way `MetalMapView` does.
    func frame() {
        metal.showsTraffic = controller.overlayMode.showsRoadNetwork
        metal.overlayMode = controller.overlayMode
        metal.update(controller.map, revision: controller.mapRevision)
    }

    // MARK: - Playing

    func click(_ tool: ZoneType, at position: GridPosition) {
        record("click \(tool.rawValue) at \(position)")
        controller.selectTool(tool)
        clickInView(silently: position)
    }

    func drag(_ tool: ZoneType, from: GridPosition, to: GridPosition) {
        record("drag \(tool.rawValue) \(from)→\(to)")
        controller.selectTool(tool)
        stroke(from.line(to: to))
    }

    func clickInView(at position: GridPosition) {
        record("click in \(controller.overlayMode.displayName) at \(position)")
        clickInView(silently: position)
    }

    private func clickInView(silently position: GridPosition) {
        input.pointerMoved(to: position)
        input.press(at: position)
        input.release()
    }

    func dragInView(from: GridPosition, to: GridPosition) {
        record("drag in \(controller.overlayMode.displayName) \(from)→\(to)")
        stroke(from.line(to: to))
    }

    /// A press, then one drag event per tile, then a release: the events
    /// AppKit delivers, through the same handlers the view calls.
    private func stroke(_ positions: [GridPosition]) {
        guard let first = positions.first else { return }
        input.press(at: first)
        for step in positions.dropFirst() { input.drag(to: step) }
        input.release()
    }

    func bulldoze(at position: GridPosition) {
        record("bulldoze \(position)")
        input.rightPress(at: position)
        input.release()
    }

    func look(at overlay: OverlayMode) {
        record("look at \(overlay.displayName)")
        controller.overlayMode = overlay
    }

    func pause() {
        record("pause")
        controller.isRunning = false
        frame()
    }

    func play() {
        record("play")
        controller.isRunning = true
        frame()
    }

    func beginLine(_ mode: TransitRoute.Mode) {
        record("begin a \(TransitText.modeName(mode).lowercased()) line")
        controller.beginTransitRoute(mode: mode)
    }

    func finishLine() {
        record("finish the line")
        controller.commitTransitRoute()
    }

    func borrowIfShort() {
        guard controller.treasury < 2_000 else { return }
        record("issue a bond")
        _ = controller.issueBond()
    }

    func tick(_ count: Int = 1) {
        record("\(count) day\(count == 1 ? "" : "s") pass")
        for _ in 0 ..< count { clock.runSimulationTick() }
    }

    // MARK: - Checking

    func check(_ what: String = "", file: StaticString = #filePath, line: UInt = #line) {
        frame()
        let problems = MetalAgreement.violations(in: metal, controller: controller)
        guard !problems.isEmpty else { return }
        let label = what.isEmpty ? "" : " after \(what)"
        let trail = log.suffix(12).enumerated()
            .map { "    \(log.count - min(12, log.count) + $0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        XCTFail("""
            the picture stopped agreeing with the city\(label):
              \(problems.prefix(8).joined(separator: "\n  "))\
            \(problems.count > 8 ? "\n  …and \(problems.count - 8) more" : "")
              how it got here (last \(min(12, log.count)) of \(log.count) steps):
            \(trail)
            """, file: file, line: line)
    }
}
