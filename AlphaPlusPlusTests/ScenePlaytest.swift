import SpriteKit
import XCTest
@testable import AlphaPlusPlus

/// Plays the game, and checks the picture kept up.
///
/// **Why this exists.** Three bugs in a row came back from play with the same
/// shape: the simulation right and the scene quietly disagreeing — a pipe that
/// existed but was not drawn, a building that grew but was not redrawn, cars
/// driving around a stopped city. Not one of them could have been caught by
/// anything in the suite, and not by accident: **every render test takes a
/// still picture of a freshly built scene**, and all three bugs need *change
/// over time* to exist at all.
///
/// So this drives a real `GameScene` through real actions — place, lay pipe,
/// change view, pause, tick — and after each one asks whether the scene still
/// agrees with the map.
///
/// It goes in below the mouse handlers, at `GameScene.place(at:)`. Every bug
/// so far has lived there or deeper, and synthesising `NSEvent`s would mostly
/// re-test coordinate maths that `testTileNodesSitWhereTheProjectionSaysTheyDo`
/// already pins.
@MainActor
final class ScenePlaytest {

    let controller: GameController
    let scene: GameScene

    init(map: CityMap, seed: UInt64 = 0xA1F4) {
        controller = GameController(map: map, rng: SeededRNG(seed: seed),
                                    peakPopulation: Unlocks.everythingUnlocked)
        scene = GameScene(controller: controller)
        scene.size = CGSize(width: 900, height: 700)
        let view = SKView(frame: NSRect(origin: .zero, size: scene.size))
        view.presentScene(scene)
        scene.rebuildEntireGrid()
        scene.refreshAll()
    }

    // MARK: - Playing

    /// A click with a tool armed. Goes through the scene, so the view's own
    /// click routing — pipe, power line, route stop — is exercised too.
    func click(_ tool: ZoneType, at position: GridPosition) {
        controller.selectTool(tool)
        scene.beginStroke()
        scene.place(at: position)
    }

    /// A drag, which is how anybody actually lays a road or a run of pipe.
    func drag(_ tool: ZoneType, from: GridPosition, to: GridPosition) {
        controller.selectTool(tool)
        scene.beginStroke()
        for step in from.line(to: to) { scene.place(at: step) }
    }

    /// A click while a view is up, where the view rather than the toolbar
    /// decides what happens — laying pipe, adding a stop to a line.
    func clickInView(at position: GridPosition) {
        scene.beginStroke()
        scene.place(at: position)
    }

    func dragInView(from: GridPosition, to: GridPosition) {
        scene.beginStroke()
        for step in from.line(to: to) { scene.place(at: step) }
    }

    func bulldoze(at position: GridPosition) {
        scene.beginStroke()
        scene.bulldoze(at: position)
    }

    /// Changing view, the way `GameView` does it — set the mode, refresh.
    func look(at overlay: OverlayMode) {
        controller.overlayMode = overlay
        scene.refreshAll()
    }

    func pause() {
        controller.isRunning = false
        frame()
    }

    func play() {
        controller.isRunning = true
        frame()
    }

    /// One turn of the run loop.
    ///
    /// The real game calls `update` sixty times a second and a driver that
    /// never did would be testing a scene nothing was driving — which showed
    /// up immediately as cars that had never been told the city was stopped.
    func frame() {
        scene.update(sceneTime)
        sceneTime += 1
    }

    /// Days passing, through the scene rather than the controller — so
    /// `refreshAll` runs and the picture is asked to keep up, which is the
    /// whole point.
    func tick(_ count: Int = 1) {
        for _ in 0 ..< count { scene.runSimulationTick() }
    }

    private var sceneTime: TimeInterval = 0

    // MARK: - Checking

    /// Asserts the scene agrees with the map, naming what does not.
    func check(_ what: String = "", file: StaticString = #filePath, line: UInt = #line) {
        frame()
        let problems = SceneAgreement.violations(in: scene, controller: controller)
        guard !problems.isEmpty else { return }
        let label = what.isEmpty ? "" : " after \(what)"
        XCTFail("the picture stopped agreeing with the city\(label):\n  "
                + problems.prefix(8).joined(separator: "\n  ")
                + (problems.count > 8 ? "\n  …and \(problems.count - 8) more" : ""),
                file: file, line: line)
    }
}

/// Does the scene show what the city actually is?
///
/// **Measured against a scene rebuilt from scratch, not against a second copy
/// of the renderer's rules.** That distinction is the whole design: this
/// project has been bitten three times by a yardstick that reimplemented the
/// thing it measured and therefore agreed with itself forever — a streetscape
/// painting its own flat tiles, an overlay render carrying its own stale
/// switch, hazard damage computed twice. Writing down what a lot "should" draw
/// would be a fourth.
///
/// So the question asked here is narrower and much harder to fake: **is the
/// incrementally-updated scene the same as one built from this map right
/// now?** It cannot catch a renderer that draws the wrong thing consistently.
/// It catches a renderer that has fallen behind — which is every bug play has
/// found so far.
@MainActor
enum SceneAgreement {

    static func violations(in scene: GameScene, controller: GameController) -> [String] {
        var problems = pauseViolations(in: scene, controller: controller)

        // A second scene on the same city, built from nothing. Discarded
        // immediately; the live one is never touched, so a session can keep
        // accumulating whatever drift it is going to accumulate.
        let reference = GameScene(controller: controller)
        reference.size = scene.size
        let view = SKView(frame: NSRect(origin: .zero, size: reference.size))
        view.presentScene(reference)
        reference.rebuildEntireGrid()
        reference.refreshAll()

        let live = snapshot(scene)
        let fresh = snapshot(reference)

        for anchor in Set(live.keys).union(fresh.keys).sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            switch (live[anchor], fresh[anchor]) {
            case (nil, .some):
                problems.append("\(anchor): the city has a building here and the map draws nothing")
            case (.some, nil):
                problems.append("\(anchor): a sprite left behind for a building that is gone")
            case let (.some(a), .some(b)):
                problems.append(contentsOf: a.differences(from: b, at: anchor))
            case (nil, nil):
                break
            }
        }
        return problems
    }

    /// What one tile is showing: how many of each kind of decoration, and the
    /// state each was built from.
    ///
    /// The cache key is included deliberately. Counting the children catches a
    /// decoration that is missing or duplicated — a pipe segment under a
    /// covered cell — but not one that is simply *stale*, because a building
    /// drawn at the wrong density is still exactly one building. The key is
    /// what the renderer itself recorded about the state it drew, so comparing
    /// two of them compares two runs of the same code rather than inventing a
    /// second opinion.
    struct TileShape {
        var counts: [String: Int] = [:]
        var keys: [String: String] = [:]

        func differences(from other: TileShape, at anchor: GridPosition) -> [String] {
            var problems: [String] = []
            for name in Set(counts.keys).union(other.counts.keys).sorted() {
                let mine = counts[name] ?? 0
                let theirs = other.counts[name] ?? 0
                if mine != theirs {
                    problems.append("\(anchor): \(theirs) × \(name) expected, \(mine) drawn")
                } else if let a = keys[name], let b = other.keys[name], a != b {
                    problems.append("\(anchor): \(name) is stale — showing \(a), should be \(b)")
                }
            }
            return problems
        }
    }

    /// Nodes that are an animation *in flight* rather than a fact about the
    /// city — they add themselves on a click and take themselves away a beat
    /// later. A scene rebuilt from the map has none by definition, so
    /// comparing them would report every recent click as a disagreement.
    private static let transient: Set<String> = [IsoTileRenderer.flashNodeNameForTesting]

    private static func snapshot(_ scene: GameScene) -> [GridPosition: TileShape] {
        scene.tileNodesForTesting.mapValues { node in
            var shape = TileShape()
            for child in node.children {
                guard let name = child.name, !transient.contains(name) else { continue }
                shape.counts[name, default: 0] += 1
            }
            for (name, key) in (node.userData as? [String: Any] ?? [:]) {
                shape.keys[name] = key as? String
            }
            return shape
        }
    }

    /// The one thing a rebuilt scene cannot answer, because it has never been
    /// told the game is paused: whether what the simulation drives has stopped
    /// along with it.
    private static func pauseViolations(in scene: GameScene, controller: GameController) -> [String] {
        let shouldBePaused = !controller.isRunning
        var problems: [String] = []
        for (anchor, node) in scene.tileNodesForTesting {
            for child in node.children
            where GameScene.simulationDrivenNodeNamesForTesting.contains(child.name ?? "") {
                if child.isPaused != shouldBePaused {
                    problems.append("\(anchor): \(child.name ?? "?") is "
                        + "\(child.isPaused ? "stopped" : "moving") in a "
                        + "\(shouldBePaused ? "paused" : "running") city")
                }
            }
        }
        return problems
    }
}
