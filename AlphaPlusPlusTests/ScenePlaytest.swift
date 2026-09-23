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

    /// What has been done so far.
    ///
    /// A scripted session names its own steps in the assertion; a *random*
    /// one cannot, and a two-hundred-step failure with no account of how it
    /// got there is a failure nobody can act on. The seed makes a run
    /// reproducible; this makes it readable.
    private(set) var log: [String] = []

    private func record(_ action: String) { log.append(action) }

    /// The Metal renderer drawing this session's city, when it is the one
    /// under test — see `drawWithMetal`.
    private(set) var metal: MetalCityRenderer?

    /// Hands the city to the Metal renderer, the way the Renderer setting
    /// does: SpriteKit stops drawing tiles, and every frame the Metal view
    /// reads the controller exactly as `MetalMapView` does. From then on
    /// `check` asks `MetalAgreement` rather than `SceneAgreement`, because
    /// the scene is no longer the thing drawing the city.
    func drawWithMetal() {
        metal = MetalCityRenderer()
        scene.setDrawsCity(false)
        frame()
    }

    /// The view the scene is presented on — kept because a filmstrip frame is
    /// `SKView.texture(from:)`, and it has to come from *this* view showing
    /// *this* scene. Rendering a freshly built one instead would be a picture
    /// of the thing the bugs are not in.
    private let view: SKView

    /// `size` is the frame every capture comes out at, since
    /// `SKView.texture(from:)` renders at the scene's own size. The default is
    /// what every session in the suite uses; a figure destined for a page
    /// somebody will read at full width asks for more pixels, and there is no
    /// backing scale to get them from — a headless view has no window.
    init(map: CityMap, seed: UInt64 = 0xA1F4,
         size: CGSize = CGSize(width: 900, height: 700)) {
        controller = GameController(map: map, rng: SeededRNG(seed: seed),
                                    peakPopulation: Unlocks.everythingUnlocked)
        scene = GameScene(controller: controller)
        scene.size = size
        view = SKView(frame: NSRect(origin: .zero, size: scene.size))
        view.presentScene(scene)
        scene.rebuildEntireGrid()
        scene.refreshAll()
        scene.centerCameraOnMap()
        frameTheWholeMap()
    }

    /// Pulls the camera back until the whole city is in shot.
    ///
    /// `centerCameraOnMap` points it at the middle and says nothing about
    /// zoom, which for a filmstrip meant most of every frame was empty night.
    /// A picture I am going to read has to be mostly city.
    func frameTheWholeMap() {
        let bounds = Isometric().contentBounds(of: controller.map)
        let fit = max(bounds.width / scene.size.width, bounds.height / scene.size.height)
        scene.camera?.setScale(max(fit * 1.08, 0.1))
        scene.centerCameraOnMap()
    }

    // MARK: - Looking at it

    private var filmstrip: [(String, NSImage)] = []

    /// Photographs the city as it stands.
    ///
    /// **The point of the whole harness, from my side of it.** Everything else
    /// here asserts; this is the only part that lets the picture be *looked
    /// at* — and every render this project had before it was a still of a
    /// freshly built scene, which is precisely the state none of these bugs
    /// can exist in.
    func capture(_ label: String) {
        guard let texture = view.texture(from: scene, crop: CGRect(origin: .zero, size: scene.size))
        else { return }
        filmstrip.append((label, NSImage(cgImage: texture.cgImage(), size: scene.size)))
    }

    /// Writes the frames captured so far as one image, the way every other
    /// contact sheet in this project is written.
    @discardableResult
    func writeFilmstrip(named name: String) -> URL? {
        guard let data = Self.stack(filmstrip) else { return nil }
        let destination = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ContactSheet/\(name).png")
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: destination)
        print("🎞  \(name): \(destination.path) (\(filmstrip.count) frames)")
        return destination
    }

    private static func stack(_ frames: [(String, NSImage)]) -> Data? {
        guard !frames.isEmpty else { return nil }
        let captionHeight: CGFloat = 26, margin: CGFloat = 16
        let width = (frames.map { $0.1.size.width }.max() ?? 0) + margin * 2
        let height = frames.reduce(margin) { $0 + $1.1.size.height + captionHeight } + margin
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = CGSize(width: width, height: height)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        RenderPalette.background.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Menlo-Bold", size: 13) ?? NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor(white: 0.82, alpha: 1),
        ]
        var y = height - margin
        for (label, image) in frames {
            y -= captionHeight
            label.draw(at: NSPoint(x: margin, y: y + 6), withAttributes: attributes)
            y -= image.size.height
            image.draw(in: NSRect(x: margin, y: y, width: image.size.width, height: image.size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Playing

    /// A click with a tool armed. Goes through the scene, so the view's own
    /// click routing — pipe, power line, route stop — is exercised too.
    func click(_ tool: ZoneType, at position: GridPosition) {
        record("click \(tool.rawValue) at \(position)")
        controller.selectTool(tool)
        scene.beginStroke()
        scene.place(at: position)
    }

    /// A drag, which is how anybody actually lays a road or a run of pipe.
    func drag(_ tool: ZoneType, from: GridPosition, to: GridPosition) {
        record("drag \(tool.rawValue) \(from)→\(to)")
        controller.selectTool(tool)
        stroke(from.line(to: to))
    }

    /// A click while a view is up, where the view rather than the toolbar
    /// decides what happens — laying pipe, adding a stop to a line.
    func clickInView(at position: GridPosition) {
        record("click in \(controller.overlayMode.displayName) at \(position)")
        scene.beginStroke()
        scene.place(at: position)
    }

    func dragInView(from: GridPosition, to: GridPosition) {
        record("drag in \(controller.overlayMode.displayName) \(from)→\(to)")
        stroke(from.line(to: to))
    }

    /// A drag with the press and the movement told apart, the way AppKit
    /// delivers them.
    ///
    /// This used to call `place(at:)` for every tile, which is what a *click*
    /// does — so every decision `mouseDragged` makes before calling it was
    /// unreachable from here, and a drag that silently refused to paint
    /// looked identical to one that painted fine. `dragTo` is the real
    /// handler's own body rather than a copy of it, which is the only version
    /// of this that can catch the next such bug.
    private func stroke(_ positions: [GridPosition]) {
        guard let first = positions.first else { return }
        scene.beginStroke()
        scene.place(at: first)
        for step in positions.dropFirst() { scene.dragTo(step) }
    }

    /// The lane line on a tile, or `nil` if the view is not drawing streets.
    func laneLine(at position: GridPosition) -> SKNode? {
        scene.tileNodesForTesting[position]?
            .children.first { $0.name == IsoTileRenderer.laneNodeNameForTesting }
    }

    func bulldoze(at position: GridPosition) {
        record("bulldoze \(position)")
        scene.beginStroke()
        scene.bulldoze(at: position)
    }

    /// Changing view, the way `GameView` does it — set the mode, refresh.
    func look(at overlay: OverlayMode) {
        record("look at \(overlay.displayName)")
        controller.overlayMode = overlay
        scene.refreshAll()
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

    /// One turn of the run loop.
    ///
    /// The real game calls `update` sixty times a second and a driver that
    /// never did would be testing a scene nothing was driving — which showed
    /// up immediately as cars that had never been told the city was stopped.
    func frame() {
        scene.update(sceneTime)
        sceneTime += 1
        if let metal {
            metal.showsTraffic = controller.overlayMode.showsRoadNetwork
            metal.overlayMode = controller.overlayMode
            metal.update(controller.map, revision: controller.mapRevision)
        }
    }

    /// Tightens the shot after `frameTheWholeMap`.
    ///
    /// An isometric map is a wide, shallow diamond, so fitting it inside a
    /// rectangle leaves the frame mostly empty night above and below it — fine
    /// for a filmstrip nobody publishes, wrong for a figure somebody reads.
    /// A factor below 1 moves the camera closer.
    func zoom(by factor: CGFloat) {
        guard let camera = scene.camera else { return }
        camera.setScale(camera.xScale * factor)
        frame()
    }

    /// Arming a route tool, which is what raises its view and starts a line.
    func beginLine(_ mode: TransitRoute.Mode) {
        record("begin a \(TransitText.modeName(mode).lowercased()) line")
        controller.beginTransitRoute(mode: mode)
        scene.refreshAll()
    }

    func finishLine() {
        record("finish the line")
        controller.commitTransitRoute()
        scene.refreshAll()
    }

    /// Borrows when the money runs out, the way a player would rather than
    /// through a backdoor into the treasury.
    func borrowIfShort() {
        guard controller.treasury < 2_000 else { return }
        record("issue a bond")
        _ = controller.issueBond()
    }

    /// Days passing, through the scene rather than the controller — so
    /// `refreshAll` runs and the picture is asked to keep up, which is the
    /// whole point.
    func tick(_ count: Int = 1) {
        record("\(count) day\(count == 1 ? "" : "s") pass")
        for _ in 0 ..< count { scene.runSimulationTick() }
    }

    private var sceneTime: TimeInterval = 0

    // MARK: - Checking

    /// Asserts the scene agrees with the map, naming what does not.
    func check(_ what: String = "", file: StaticString = #filePath, line: UInt = #line) {
        frame()
        let problems = metal.map { MetalAgreement.violations(in: $0, controller: controller) }
            ?? SceneAgreement.violations(in: scene, controller: controller)
        guard !problems.isEmpty else { return }
        let label = what.isEmpty ? "" : " after \(what)"
        let trail = log.suffix(12).enumerated()
            .map { "    \(log.count - 12 + $0.offset + 1). \($0.element)" }
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


/// **`SceneAgreement` for the Metal renderer** — migration phase M5.
///
/// The same question, asked of the same kind of yardstick: is the renderer
/// that has been updated change by change — chunks rebuilt only where a
/// signature moved, a motion plan rebuilt only when its key moved, a view
/// rebuilt on each new revision — holding exactly what a renderer built
/// fresh from this city right now would hold? Every chunk's triangles and
/// lights, byte for byte; the motion plan; the view.
///
/// It compares **what was handed to the GPU**, not pixels: two renderers
/// holding the same buffers draw the same frame, and a buffer names the
/// chunk that fell behind where a pixel diff would only say "somewhere".
@MainActor
enum MetalAgreement {

    static func violations(in live: MetalCityRenderer, controller: GameController) -> [String] {
        guard let fresh = MetalCityRenderer() else { return ["no Metal device"] }
        fresh.showsTraffic = live.showsTraffic
        fresh.overlayMode = live.overlayMode
        fresh.update(controller.map, revision: nil)

        var problems: [String] = []
        let a = live.chunksForTesting(), b = fresh.chunksForTesting()
        if a.count != b.count {
            problems.append("\(a.count) chunks drawn, \(b.count) expected")
        }
        for (mine, theirs) in zip(a, b) where mine != theirs {
            let region = "chunk (\(theirs.x0),\(theirs.y0))–(\(theirs.x1),\(theirs.y1))"
            if mine.vertices.count != theirs.vertices.count {
                problems.append("\(region): \(mine.vertices.count / 20) vertices drawn, \(theirs.vertices.count / 20) expected")
            } else if mine.vertices != theirs.vertices {
                problems.append("\(region) is stale: same size, different triangles")
            }
            if mine.lights != theirs.lights { problems.append("\(region): its lights are stale") }
            if mine.groundCount != theirs.groundCount { problems.append("\(region): ground and buildings split wrong") }
        }

        let plan = live.motion.planForTesting, expected = fresh.motion.planForTesting
        if plan.cars != expected.cars {
            problems.append("traffic is stale: \(plan.cars.count / 13) cars planned, \(expected.cars.count / 13) expected")
        }
        if plan.runs != expected.runs { problems.append("a tram, ship or engine is on a stale route") }
        if plan.airports != expected.airports { problems.append("an aircraft is flying from an airport that moved") }
        if plan.fires != expected.fires { problems.append("the flames are stale: \(plan.fires.count / 4) drawn, \(expected.fires.count / 4) burning") }
        if plan.smoke != expected.smoke { problems.append("factory smoke is stale") }

        let view = live.overlay, reference = fresh.overlay
        if view.tiles != reference.tiles { problems.append("the \(live.overlayMode) view is stale on the ground") }
        if view.tint != reference.tint { problems.append("the \(live.overlayMode) view's building wash is stale") }
        if view.hidesBuildings != reference.hidesBuildings { problems.append("buildings shown/hidden wrongly under \(live.overlayMode)") }
        if view.traces != reference.traces { problems.append("a scaffold is stale") }
        if view.schematic != reference.schematic { problems.append("a pipe, power line or rail is stale") }
        if view.billboards != reference.billboards { problems.append("a badge is stale") }
        return problems
    }
}
