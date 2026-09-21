import SpriteKit
import AppKit

/// The SpriteKit scene that draws the city.
///
/// Key idea: the scene *owns no rules*. It reads a `CityMap` (data) through
/// the shared `GameController`, asks `IsoTileRenderer` to turn each tile into a
/// node, and keeps a lookup table so it can update individual tiles later
/// without rebuilding the world. When Phase 2 adds a simulation tick, it will
/// hand this scene new data and the scene will re-sync — it will never
/// compute population itself. Click-to-place follows the same rule: a click
/// or drag asks the controller (`place(at:)` or `bulldoze(at:)`) to apply the
/// change, then asks the scene to re-read that one tile. The scene never
/// mutates a tile directly.
final class GameScene: SKScene {

    // MARK: - Data

    /// Owned by `GameView`, not by this scene, so SwiftUI's toolbar and stats
    /// see the same `CityMap` this scene draws.
    private let controller: GameController

    /// Convenience so the rest of this file reads exactly as it did when
    /// `map` was a stored property here.
    private var map: CityMap { controller.map }

    // MARK: - Rendering

    private let projection: Isometric
    /// `var` rather than `let` because `IsoTileRenderer` is a value type and
    /// carries the one piece of state the scene drives into it: how wet the
    /// streets are. See `syncWeather`.
    private var tileRenderer: IsoTileRenderer

    /// All tile sprites live under one parent node rather than directly on the
    /// scene. That gives us a single thing to move, scale, or hide, and keeps
    /// future layers (overlays, UI, effects) cleanly separated by z-order.
    private let tileLayer = SKNode()

    /// Sits between the scene and `tileLayer`, carrying the one shader
    /// effect this project has (`RetroShader`) — see that file for why an
    /// `SKEffectNode` and not `tileLayer` itself. Not rasterized: the map
    /// underneath changes every simulation tick (new density, hazard
    /// flashes, traffic cars, panning/zooming), so the offscreen render
    /// this node composites has to redo every frame, same as any other
    /// live post-process. That's a real per-frame cost, but it's one
    /// Metal shader pass over the whole map, not per-tile or per-icon
    /// work, so it scales with screen resolution rather than city size.
    private let retroEffectLayer = SKEffectNode()

    /// The footprint-sized outline that follows the cursor before a click
    /// commits — see `updatePlacementPreview(at:)`. A sibling of `tileLayer`
    /// (not a child of it) specifically so `rebuildEntireGrid()`'s
    /// `tileLayer.removeAllChildren()` never takes it out along with the
    /// tiles; still a child of `retroEffectLayer` so it picks up the same
    /// retro shader treatment everything else on the map gets.
    private let placementPreviewNode = SKShapeNode()

    /// The Bus/Subway overlays' route diagram — see
    /// `IsoTileRenderer.transitDiagram(for:in:)`.
    ///
    /// A sibling of `tileLayer` rather than something hung off a tile, for the
    /// reason `placementPreviewNode` documents (it survives
    /// `rebuildEntireGrid()`) and one more: a route spans arbitrary tiles, so
    /// there is no one tile it belongs to. Its `zPosition` has to clear
    /// **1,000**, not the map's depth range — a buried conduit already sits at
    /// 1,000 *inside* `tileLayer` to draw over the city, and SpriteKit sorts
    /// on accumulated z, so a sibling at 1 would be painted over by a pipe.
    private let transitDiagramNode = SKNode()

    /// A soft, warm glow parked at a fixed point in world space, well
    /// below the map's own bottom edge — the retrowave "sun behind the
    /// skyline" motif every reference image this project's art pass has
    /// pulled from includes, adapted for a camera that's strictly
    /// top-down and so has no literal horizon for a sun to sit on. Not a
    /// light source anything in the simulation reacts to, purely
    /// backdrop — the same role `RenderPalette.background`'s flat "night
    /// sky" color already plays, just with one warm glow bleeding up into
    /// it from a fixed spot rather than a flat color everywhere. Opaque
    /// tile sprites (every tile, zoned or not, is one) occlude it
    /// wherever the map itself covers that screen area — by construction
    /// it can only ever show through in the empty space beyond the map's
    /// own edge, which is exactly the "sun peeking from behind the city"
    /// read this is going for. A sibling of `tileLayer`, same reasoning
    /// `placementPreviewNode` documents: survives `rebuildEntireGrid()`'s
    /// `tileLayer.removeAllChildren()`, and still picks up the retro
    /// shader pass.
    private let sunGlowNode = SKSpriteNode()

    /// **The land the city sits in.**
    ///
    /// Everything outside the map used to be the scene's flat background
    /// colour, so a city read as a diamond island floating on nothing — a
    /// diagram on a desktop rather than a place at night. The single biggest
    /// thing holding the look back, and it is not a styling problem: there
    /// was simply no world there.
    ///
    /// So the ground carries on past the map's edge: the same isometric grid,
    /// unclaimed and unlit, fading out with distance. The city is then
    /// somewhere *in* a landscape, and its boundary reads as where your land
    /// stops rather than where the drawing stops.
    ///
    /// A sibling of `tileLayer` for the reasons `sunGlowNode` already
    /// documents — it survives `rebuildEntireGrid()` and still takes the
    /// retro shader pass — and sits below the sun, which bleeds up over it.
    ///
    /// **Bounded rather than infinite, and that is affordable because the
    /// camera is clamped.** Panning cannot wander off into open space, so the
    /// backdrop only has to cover the map plus a generous margin; it is one
    /// sprite and one texture rather than a shader or a tile map.
    private let backdropNode = SKSpriteNode()

    /// A radial gradient, white fading to transparent, tinted by
    /// `sunGlowNode.color` — the same "cache one shared gradient texture,
    /// tint and additively blend it per use" technique
    /// `NeonStyle.glowTexture` uses for road/highway network glow,
    /// just larger (this gets stretched across a much bigger sprite) and
    /// generated here rather than there since it's a scene-level backdrop
    /// element, not a per-tile one.
    private static let sunGlowTexture: SKTexture = {
        let diameter = 512
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: diameter, height: diameter, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return SKTexture() }

        let components: [CGFloat] = [1, 1, 1, 0.9, 1, 1, 1, 0]
        guard let gradient = CGGradient(colorSpace: colorSpace, colorComponents: components, locations: [0, 1], count: 2) else {
            return SKTexture()
        }
        let center = CGPoint(x: CGFloat(diameter) / 2, y: CGFloat(diameter) / 2)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: CGFloat(diameter) / 2, options: [])

        guard let image = context.makeImage() else { return SKTexture() }
        return SKTexture(cgImage: image)
    }()

    /// Grid coordinate -> sprite, so updating one tile is O(1) instead of a
    /// scene-graph search.
    private var tileNodes: [GridPosition: SKNode] = [:]

    /// An `SKCameraNode` lets us pan and zoom by moving *one* node instead of
    /// repositioning thousands of tiles — see `scrollWheel(with:)` and
    /// `magnify(with:)` below, which are the trackpad gestures that move it.
    private let cameraNode = SKCameraNode()

    /// `didMove(to:)` can fire more than once (e.g. if the scene is presented
    /// again after a view change), and building the grid twice would stack
    /// duplicate sprites. This guard makes setup idempotent.
    private var hasBuiltScene = false

    // MARK: - Init

    init(controller: GameController, projection: Isometric = Isometric()) {
        self.controller = controller
        self.projection = projection
        self.tileRenderer = IsoTileRenderer(projection: projection)

        // Note: `layout` here is the *parameter*, not `self.layout`. Swift
        // forbids touching `self` before `super.init`, and the parameter
        // shadows the property, so this is legal (and a very common
        // stumbling block when writing Swift initializers). `controller.map`
        // is fine to read already, since `self.controller` was just set.
        //
        // The starting size barely matters because `.resizeFill` below makes the
        // scene adopt the view's size, so one scene point == one screen point
        // and nothing gets stretched.
        super.init(size: projection.contentBounds(of: controller.map).size)

        scaleMode = .resizeFill
        backgroundColor = RenderPalette.background

        // With an `SKCameraNode` in play the camera decides what's on screen,
        // but pinning the anchor point to the middle of the view makes the
        // "camera position == center of what you see" relationship hold
        // unambiguously, which keeps later pan/zoom math simple.
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
    }

    /// Required because `SKScene` conforms to `NSCoding`. We never load this
    /// scene from a storyboard or `.sks` file — we build it in code — so this
    /// path should never run.
    required init?(coder aDecoder: NSCoder) {
        fatalError("GameScene is created in code, not from a coder")
    }

    // MARK: - Scene lifecycle

    override func didMove(to view: SKView) {
        super.didMove(to: view)
        guard !hasBuiltScene else { return }
        hasBuiltScene = true

        camera = cameraNode
        addChild(cameraNode)

        tileLayer.name = "tiles"
        tileLayer.zPosition = 0
        retroEffectLayer.shader = RetroShader.make()
        retroEffectLayer.addChild(tileLayer)
        addChild(retroEffectLayer)
        RetroShader.updateAspect(retroEffectLayer.shader!, size: size)

        placementPreviewNode.name = "placementPreview"
        placementPreviewNode.isHidden = true
        placementPreviewNode.lineWidth = 3.5
        placementPreviewNode.glowWidth = 3
        // Above every tile node, whose own `zPosition` now runs up to the
        // map's width plus height — a preview at 5 would sit behind most of
        // the city on any map bigger than a few tiles.
        placementPreviewNode.zPosition = 10_000
        transitDiagramNode.name = "transit"
        transitDiagramNode.zPosition = 2_000
        retroEffectLayer.addChild(transitDiagramNode)

        retroEffectLayer.addChild(placementPreviewNode)

        sunGlowNode.texture = Self.sunGlowTexture
        sunGlowNode.color = RenderPalette.sunGlow
        sunGlowNode.colorBlendFactor = 1
        sunGlowNode.blendMode = .add
        sunGlowNode.name = "sunGlow"
        sunGlowNode.zPosition = -1
        retroEffectLayer.addChild(sunGlowNode)

        backdropNode.name = "backdrop"
        backdropNode.zPosition = -2
        retroEffectLayer.addChild(backdropNode)

        buildTileNodes()
        centerCameraOnMap()
        positionSunGlow()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        // **A resize keeps the camera where the player left it**, and only
        // re-clamps so the map stays findable.
        //
        // This used to recentre, with a comment calling the lost pan "a fairly
        // minor annoyance" because a resize meant dragging a window edge.
        // Moving the simulation controls into the tool rail made it anything
        // but: the rail changes height when a tool category with more chips
        // wraps it to a second row, so **picking a different tool resized the
        // map view and threw away where you were looking**. Reported from
        // play within minutes.
        //
        // Recentring was never doing the job it claimed anyway. What keeps a
        // map findable after a resize is the clamp, which is right here — the
        // recentre on top of it was only discarding information.
        clampCameraToMap()
        if let shader = retroEffectLayer.shader {
            RetroShader.updateAspect(shader, size: size)
        }
    }

    // MARK: - Camera pan & zoom

    /// Range the camera can zoom across, as an `SKCameraNode` scale factor
    /// (smaller scale = more zoomed in — see `zoom(byMagnification:)`).
    /// Bounds exist just to stop a pinch gesture from producing a useless
    /// view (the map shrunk to a speck, or blown up past recognizing
    /// individual tiles), not because either number is precisely tuned.
    private let minimumZoomScale: CGFloat = 0.5
    private let maximumZoomScale: CGFloat = 3.0

    /// Pan the camera by a trackpad scroll gesture's delta.
    ///
    /// Plain methods, not `override func scrollWheel`/`magnify` — those
    /// compile (inherited from `NSResponder` further up `SKScene`'s chain)
    /// but macOS `SKScene` only forwards a specific, documented subset of
    /// AppKit events to itself: mouse clicks/drags and keyboard. Scroll and
    /// magnify aren't in that subset, so an override there would silently
    /// never fire — this project's original mistake. `GameSKView` is the
    /// real `NSView` that actually receives these events and calls these
    /// methods directly.
    ///
    /// `deltaX`/`deltaY` should already be `NSEvent.scrollingDeltaX/Y`
    /// (accounts for the system's "natural scrolling" preference, unlike
    /// raw `deltaX/deltaY`) — that's `GameSKView`'s job to pass in, not
    /// this method's to know about `NSEvent` at all. The camera is the
    /// *viewport*, not the content, so moving it by the gesture's delta is
    /// what makes the map appear to follow the gesture, matching the
    /// direction two-finger scrolling moves content everywhere else on macOS.
    func pan(deltaX: CGFloat, deltaY: CGFloat) {
        cameraNode.position.x -= deltaX
        cameraNode.position.y += deltaY
        clampCameraToMap()
    }

    // MARK: - Test seams
    //
    // Three read-only windows onto state that is otherwise private, so the
    // keyboard tests can assert on where the camera actually went rather than
    // on whether a method was called. Named `…ForTesting` so nothing in the
    // app reaches for them by accident.

    var cameraPositionForTesting: CGPoint { cameraNode.position }
    var controllerForTesting: GameController { controller }
    var cameraClampBoundsForTesting: CGRect {
        projection.contentBounds(of: map).insetBy(
            dx: -projection.tileWidth * 2, dy: -projection.tileHeight * 2
        )
    }

    /// Which way the keyboard is currently steering, in camera terms: `dy`
    /// positive is up the screen. Zero when nothing is held.
    ///
    /// A *velocity* the frame loop integrates, not a position — see
    /// `KeyboardControls.panPointsPerSecond` for why holding a key has to be
    /// smooth rather than a series of nudges paced by the OS key-repeat rate.
    var keyboardPan: CGVector = .zero

    /// Applies `keyboardPan` for one frame.
    ///
    /// Scaled by the camera's own zoom so a key press covers the same
    /// *fraction of the screen* however far out you are. Without it panning
    /// crawls when zoomed out — which is exactly when you are trying to cross
    /// the map — and skitters when zoomed in.
    private func applyKeyboardPan(elapsed: TimeInterval) {
        guard keyboardPan != .zero else { return }
        let distance = KeyboardControls.panPointsPerSecond * CGFloat(elapsed) * cameraNode.xScale
        // Normalised, so travelling diagonally is not 1.41x faster than
        // travelling straight — the classic bug of adding two axes together.
        let length = (keyboardPan.dx * keyboardPan.dx + keyboardPan.dy * keyboardPan.dy).squareRoot()
        cameraNode.position.x += keyboardPan.dx / length * distance
        cameraNode.position.y += keyboardPan.dy / length * distance
        clampCameraToMap()
    }

    /// Keep the camera over the map.
    ///
    /// **This never existed top-down and it should have.** Panning was
    /// unbounded, so a stray two-finger flick left you looking at empty
    /// background with no landmark to steer back by — survivable when the map
    /// was a big square filling most of the view, and much worse now that it is
    /// a diamond whose corners are the only thing near the edges of the screen.
    ///
    /// Clamped against the *ground* bounds rather than everything drawn:
    /// buildings rise above the diamond's top edge, and including them would
    /// let the view drift off the map whenever a tall tower stood near a
    /// corner. The margin is generous on purpose — the point is to keep the map
    /// findable, not to fence the player in.
    private func clampCameraToMap() {
        let bounds = projection.contentBounds(of: map).insetBy(
            dx: -projection.tileWidth * 2, dy: -projection.tileHeight * 2
        )
        cameraNode.position.x = min(max(cameraNode.position.x, bounds.minX), bounds.maxX)
        cameraNode.position.y = min(max(cameraNode.position.y, bounds.minY), bounds.maxY)
    }

    /// Zoom the camera by one trackpad pinch gesture's magnification delta.
    ///
    /// `magnification` is the *change* since the last call in the same
    /// gesture (`NSEvent.magnification`, not an absolute value), so it's
    /// applied multiplicatively to the camera's current scale rather than
    /// replacing it outright. A *smaller* `SKCameraNode` scale shows the
    /// world *larger* (a smaller window onto the same content looks zoomed
    /// in), so pinching out (positive magnification, the standard "zoom in"
    /// gesture) reduces scale.
    /// - Parameter anchor: the scene point to keep still, which should be
    ///   whatever is under the cursor. **Zooming at the screen's centre is the
    ///   wrong default for a map**: the thing a player is pinching toward is
    ///   the thing they are looking at, and centre-anchored zoom slides it out
    ///   from under them, so getting closer to a district means zoom, pan,
    ///   zoom, pan. Passing `nil` keeps the old behaviour for callers with no
    ///   cursor to speak of — the keyboard, and the tests about clamping.
    func zoom(byMagnification magnification: CGFloat, anchoredAt anchor: CGPoint? = nil) {
        let before = cameraNode.xScale
        let requestedScale = before * (1 - magnification)
        let after = min(max(requestedScale, minimumZoomScale), maximumZoomScale)
        cameraNode.setScale(after)

        // Keep `anchor` where it was on screen. A point's screen offset from
        // the centre is `(point - camera) / scale`, so holding that constant
        // across the change gives the camera position below. Taken off the
        // *clamped* scale rather than the requested one, or a pinch that hits
        // the zoom limit would still shove the camera sideways.
        if let anchor, before > 0 {
            let ratio = after / before
            cameraNode.position = CGPoint(
                x: anchor.x - (anchor.x - cameraNode.position.x) * ratio,
                y: anchor.y - (anchor.y - cameraNode.position.y) * ratio
            )
        }
        clampCameraToMap()
    }

    // MARK: - Simulation clock

    /// Scene time (`currentTime` from `update(_:)`) the last tick happened
    /// at, or `nil` when paused / just resumed. `SKScene.update(_:)` passes
    /// scene-relative time, not wall-clock time, but the two advance at the
    /// same rate, so subtracting two `currentTime` values gives real elapsed
    /// seconds either way.
    private var lastTickTime: TimeInterval?

    /// SpriteKit calls this once per frame (~60 times a second at the
    /// `SpriteView`'s configured frame rate). Most frames it does nothing —
    /// `isRunning` is the on/off switch, and `controller.simulationSpeed.tickInterval`
    /// throttles how often a `true` value actually turns into a simulation
    /// step, rather than growing the city 60 times a second. Reading the
    /// interval from `controller` (instead of a fixed constant) each frame
    /// means changing the speed picker mid-game takes effect on the very
    /// next check, with nothing to reset.
    /// Scene time of the previous frame, for the elapsed-time term in
    /// keyboard panning. Separate from `lastTickTime` below, which is reset
    /// whenever the simulation pauses — the camera keeps moving when the city
    /// does not, and sharing one clock would freeze panning exactly when a
    /// player has paused to go and look at something.
    private var lastFrameTime: TimeInterval?

    /// The decorations that are *the city moving*, and therefore stop when
    /// it does.
    ///
    /// **Deliberately not the whole tile layer, and deliberately not the
    /// scene.** `SKScene.isPaused` would take the camera with it, and looking
    /// around a stopped city is most of what pausing is for — the same reason
    /// `update` pans before it checks the pause. Pausing `tileLayer` wholesale
    /// would be nearly right and wrong in one place that matters: the
    /// placement and hazard flashes are `SKAction`s too, they fire in response
    /// to *clicks*, and clicks happen while paused. A paused flash would
    /// never fade and never remove itself, leaving a coloured diamond stuck
    /// on the map.
    ///
    /// So the rule is by name: things the simulation is driving stop, things
    /// answering the player do not.
    ///
    /// **Ambient cars came off this list** when they moved onto the per-frame
    /// driver. They stop now because nothing advances them, which is strictly
    /// better than being told to stop: a car built *while* the game is paused
    /// used to need `applyAnimationPause` to catch it on the way out, and a
    /// missed call left it driving. Nothing to miss now.
    private static let animatedBySimulation: Set<String> = [
        IsoTileRenderer.fireNodeName, rainNodeName,
        // A lot's light breathing is the city being inhabited, so it stops
        // when the city does — same side of the line as the traffic, and the
        // opposite side from a placement flash, which answers a *click* and
        // so has to keep running while paused or it would never fade away.
        IsoTileRenderer.contactNodeName,
        // A chimney smoking over a stopped city is the same bug as the cars
        // that kept driving: smoke is the factory *working*, and work is what
        // the pause stops.
        IsoTileRenderer.smokeNodeName,
    ]

    /// Applies the current pause state to one tile's animations — for
    /// decorations built *while* paused, which happens whenever a placement
    /// refreshes a tile with the game stopped.
    ///
    /// Reads `isRunning` at the point of use rather than a flag cached by
    /// `syncAnimationPause`. The cached version was wrong whenever a refresh
    /// happened before the first frame — which the real app never does and a
    /// test harness does constantly, and which is the same "a cache that can
    /// be stale" shape as every bug this harness exists to find.
    private func applyAnimationPause(to node: SKNode) {
        for child in node.children where Self.animatedBySimulation.contains(child.name ?? "") {
            child.isPaused = !controller.isRunning
        }
    }

    /// And to the whole map, when the player presses Play or Pause.
    ///
    /// Walked on the transition rather than every frame: a 64×64 map is about
    /// five hundred tile nodes, which is nothing once, and pointless sixty
    /// times a second.
    private func syncAnimationPause() {
        guard renderedRunning != controller.isRunning else { return }
        renderedRunning = controller.isRunning
        for node in tileNodes.values {
            applyAnimationPause(to: node)
        }
        // Transit vehicles hang off `transitDiagramNode`, which is a *sibling*
        // of `tileLayer` — so the walk above, which only visits tile nodes,
        // cannot reach them. A bus still running its line around a stopped
        // city is the same bug as the cars that used to keep driving, one
        // layer up.
        applyAnimationPause(to: transitDiagramNode)
    }

    /// Whether the tiles were last touched while the city was running — only
    /// to spot the *transition*, never to decide what a node should be.
    private var renderedRunning: Bool?

    override func update(_ currentTime: TimeInterval) {
        super.update(currentTime)
        syncAnimationPause()
        // **The scene notices the view changed, rather than waiting to be
        // told.** `GameView` does tell it, and that is what makes the change
        // immediate — but the mode can also change from underneath, because
        // picking a zone tool drops a network overlay on purpose
        // (`GameController.selectTool`, so the two stay mutually exclusive).
        // Nothing announced *that*, so the map kept painting the view the
        // player had just left until something else happened to refresh it.
        //
        // Correctness should not rest on a SwiftUI binding firing; this
        // project has been caught by "the view did not tell the scene" before,
        // when a freshly laid pipe stayed dark because the game starts paused.
        if renderedOverlay != controller.overlayMode { refreshAll() }

        // Before the pause check, deliberately. Looking around a stopped city
        // is most of what pausing is for.
        let frameDelta = lastFrameTime.map { min(currentTime - $0, 0.1) } ?? 0
        if lastFrameTime != nil { applyKeyboardPan(elapsed: frameDelta) }
        lastFrameTime = currentTime
        // Before the pause check, with the panning: the backdrop follows the
        // camera, and looking around a stopped city is most of what pausing
        // is for.
        showVisibleSliceOfBackground()
        cullTilesOutsideTheView()
        matchBuildingDetailToTheCamera()
        matchBloomReachToTheCamera()

        guard controller.isRunning else {
            // Paused: forget when we last ticked, so resuming waits a full
            // tick interval before the next step instead of ticking
            // immediately on whatever time happens to have passed while paused.
            lastTickTime = nil
            return
        }
        advancePathVehicles(by: frameDelta)
        advanceTrafficCars(by: frameDelta)
        advanceDiagramVehicles(by: frameDelta)
        advanceAircraft(by: frameDelta)

        guard let lastTickTime else {
            // Just resumed (or this is the first frame ever): start the
            // clock from now rather than ticking on this very frame.
            self.lastTickTime = currentTime
            return
        }
        guard currentTime - lastTickTime >= controller.simulationSpeed.tickInterval else { return }

        self.lastTickTime = currentTime
        runSimulationTick()
    }

    /// Runs one simulation step and reflects it visually: resync every
    /// sprite, then flash any tile a hazard struck this step. The one place
    /// both the automatic clock above and `GameView`'s manual "Advance"
    /// button funnel through, so the two can never show a tick differently.
    func runSimulationTick() {
        controller.advanceSimulation()
        refreshAll()
        for strike in controller.lastHazardStrikes {
            flashHazard(at: strike.position, service: strike.coveringService)
        }
    }

    // MARK: - Input

    /// The last tile touched by the current left-button stroke, if any.
    ///
    /// `mouseDragged` only reports where the cursor *is* on each event —
    /// roughly once per frame — not the path it took to get there. A fast
    /// drag can jump several tiles between two events, which without this
    /// would leave gaps in what should be a continuous line of road or
    /// zoning. Remembering the last tile lets `mouseDragged` fill in
    /// everything between it and the new tile with `GridPosition.line(to:)`.
    /// `nil` between strokes (and at the start of a new one) means "nothing
    /// to connect to yet — just paint this one tile."
    private var lastPaintPosition: GridPosition?

    /// Same idea as `lastPaintPosition`, kept separate so a left-button
    /// stroke and a right-button stroke never interpolate through each
    /// other's history.
    private var lastBulldozePosition: GridPosition?

    /// macOS SpriteKit scenes get raw AppKit mouse events, not SwiftUI
    /// gestures — `SKScene` sits inside an `SKView`, which is an `NSView`.
    /// `event.location(in: self)` converts the click from window coordinates
    /// into this scene's coordinate space, already accounting for the
    /// camera, so it lines up with what `Isometric` expects.
    ///
    /// Left button paints the selected tool; `mouseDragged` fires
    /// continuously while the button stays down, so holding and moving
    /// paints a whole stroke of tiles instead of just the one under the
    /// initial click. Right button is a standing "quick bulldoze" shortcut,
    /// so clearing tiles never requires switching the toolbar away from
    /// whatever zone you're placing.
    override func mouseDown(with event: NSEvent) {
        beginStroke()
        place(with: event)
    }

    /// What a fresh press clears before the first tile of a stroke: the drag
    /// state, so the stroke starts here rather than continuing from wherever
    /// the pointer last was.
    func beginStroke() {
        lastPaintPosition = nil
        lastBulldozePosition = nil
        placementPreviewNode.isHidden = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let position = gridPosition(of: event) else { return }
        dragTo(position)
    }

    /// Continuing a stroke onto `position` — what `mouseDragged` does once the
    /// pointer has been turned into a tile.
    ///
    /// Split from the `NSEvent` for exactly the reason `place(at:)` was, and
    /// it matters more here than it looks: the scene playtest drives
    /// `place(at:)` directly for every step of a drag, so anything the *drag*
    /// handler decides before calling it was invisible to the harness. A drag
    /// is not a series of clicks, and the one line that made it different was
    /// the one line nothing could reach.
    func dragTo(_ position: GridPosition) {
        guard dragPaints else { return }
        place(at: position)
    }

    /// Should a drag paint at all?
    ///
    /// A route is drawn by naming buildings, not by painting tiles, so a drag
    /// across a station must not add it once per frame. **But that is a fact
    /// about the view taking the click, not about a draft existing
    /// somewhere.** The first version asked `routeDraft == nil`, and picking
    /// a route tool *starts* a draft deliberately — so a half-drawn bus line
    /// silently stopped every pipe and power-line drag in the game, for as
    /// long as it stayed open. A single click still worked, because only the
    /// drag was guarded, which is what made it read as "it doesn't place"
    /// rather than as a mode being stuck.
    ///
    /// The condition is now the same one `place(at:)` uses to decide a click
    /// is a route click, asked one layer up. A drag paints unless this view
    /// is the one drawing that line.
    var dragPaints: Bool {
        guard let mode = controller.overlayMode.routeMode else { return true }
        return controller.routeDraft?.mode != mode
    }

    override func rightMouseDown(with event: NSEvent) {
        beginStroke()
        bulldoze(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        bulldoze(with: event)
    }

    private func place(with event: NSEvent) {
        guard let position = gridPosition(of: event) else { return }
        place(at: position)
    }

    /// Everything a left click does once the pointer has been turned into a
    /// tile — which view is taking the click, the drag stroke, the refresh.
    ///
    /// Split from the `NSEvent` so it can be driven without one. The scene
    /// playtest walks *this*, not the mouse handler above it: every bug play
    /// has turned up so far has lived below the pointer, and synthesising
    /// `NSEvent`s would mostly re-test the coordinate maths, which
    /// `testTileNodesSitWhereTheProjectionSaysTheyDo` already pins.
    func place(at position: GridPosition) {

        // The Water overlay doubles as the pipe-editing layer — whatever
        // zone tool happens to be selected on the toolbar is irrelevant
        // while looking at it. See `Tile.hasPipe`'s doc comment for why
        // pipes live here instead of as another toolbar button. The Power
        // overlay is the exact same idea for `Tile.hasPowerLine`.
        if controller.overlayMode == .water {
            for step in stroke(from: lastPaintPosition, to: position) {
                let outcome = controller.layPipe(at: step)
                refreshConduitNeighbours(of: step)
                if outcome == .insufficientFunds {
                    flashInsufficientFunds(at: step)
                    break // same tile-price-doesn't-change-mid-stroke reasoning as below
                }
            }
            lastPaintPosition = position
            return
        }
        // The Bus and Subway views are the same idea one layer up: while a
        // line is being drawn, a click names a station rather than placing
        // whatever the toolbar has armed. Single clicks only — a route is a
        // short ordered list of buildings, not something you paint, and a drag
        // across a station would add it several times over.
        if let mode = controller.overlayMode.routeMode, controller.routeDraft?.mode == mode {
            switch controller.addStopToRoute(at: position) {
            case .added, .removed:
                syncTransitDiagram()
            case .notAStation:
                // The same mark a blocked placement gets, for the same reason:
                // the click did nothing and the player needs to know it was
                // the target rather than the tool.
                flashBlockedPlacement(at: position)
            }
            lastPaintPosition = position
            return
        }
        if controller.overlayMode == .power {
            for step in stroke(from: lastPaintPosition, to: position) {
                let outcome = controller.layPowerLine(at: step)
                refreshConduitNeighbours(of: step)
                if outcome == .insufficientFunds {
                    flashInsufficientFunds(at: step)
                    break
                }
            }
            lastPaintPosition = position
            return
        }

        // The "Bulldoze" toolbar tool is `.empty` selected as the left-click
        // tool — clearing whatever's here, for free, meant as the same
        // operation the dedicated right-click gesture already performs via
        // `bulldoze(at:)`. Routing it there too (instead of falling through
        // to `place(at:)` below) is the actual fix for a real bug a live
        // playtest found: `place(at:)` refuses to place over anything but
        // bare `.empty` land — a deliberate rule for the *other* tools (see
        // its own doc comment) — which made this toolbar button a no-op
        // against every occupied tile, exactly backwards for the one tool
        // whose entire purpose is clearing occupied tiles. Mirrors
        // `bulldoze(with:)`'s own multi-tile/stroke split immediately below,
        // since it's functionally the same operation now, just reachable
        // from the left-click toolbar instead of only the right-click one.
        if controller.selectedTool == .empty {
            if map[position].zone.footprintSize > 1 {
                guard lastPaintPosition == nil else { return }
                controller.bulldoze(at: position)
                rebuildRegion(around: position)
                lastPaintPosition = position
                return
            }
            for step in stroke(from: lastPaintPosition, to: position) {
                controller.bulldoze(at: step)
                refresh(step)
                refreshRoadNeighbors(of: step)
                refreshReflectionNeighbours(of: step)
            }
            lastPaintPosition = position
            return
        }

        // A multi-tile building is placed one at a time, not painted in a
        // stroke — and it can overlap-clear a *different* multi-tile
        // building whose sprite lives at another anchor entirely, which a
        // targeted `refresh(step)` can't account for. `involvesAFootprint`
        // covers both directions: the tool being placed is multi-tile, or
        // the cell being clicked already belongs to one.
        if involvesAFootprint(at: position, with: controller.selectedTool) {
            guard lastPaintPosition == nil else { return } // ignore drags past the initial click
            let outcome = controller.place(at: position)
            rebuildRegion(around: position)
            if outcome == .insufficientFunds { flashInsufficientFunds(at: position) }
            if outcome == .blocked { flashBlockedPlacement(at: position) }
            lastPaintPosition = position
            return
        }

        for step in stroke(from: lastPaintPosition, to: position) {
            let outcome = controller.place(at: step)
            refresh(step)
            refreshRoadNeighbors(of: step)
            refreshReflectionNeighbours(of: step)
            if outcome == .insufficientFunds {
                flashInsufficientFunds(at: step)
                // The tool's cost doesn't change mid-stroke, so if this tile
                // was unaffordable, every remaining tile in the line would
                // be too — stop here instead of flashing each one in turn.
                break
            }
            if outcome == .blocked {
                flashBlockedPlacement(at: step)
                // Unlike funds, "occupied" is a per-tile fact — the rest of
                // a drag stroke can easily cross back onto bare land (e.g.
                // painting road around an existing building), so this
                // continues the loop instead of breaking out of it.
            }
        }
        lastPaintPosition = position
    }

    private func bulldoze(with event: NSEvent) {
        guard let position = gridPosition(of: event) else { return }
        bulldoze(at: position)
    }

    /// The right-click erase, below the pointer — see `place(at:)`.
    func bulldoze(at position: GridPosition) {

        if controller.overlayMode == .water {
            for step in stroke(from: lastBulldozePosition, to: position) {
                controller.removePipe(at: step)
                refreshConduitNeighbours(of: step)
            }
            lastBulldozePosition = position
            return
        }
        if controller.overlayMode == .power {
            for step in stroke(from: lastBulldozePosition, to: position) {
                controller.removePowerLine(at: step)
                refreshConduitNeighbours(of: step)
            }
            lastBulldozePosition = position
            return
        }

        if map[position].zone.footprintSize > 1 {
            // Same reasoning as `place(with:)`: clearing a multi-tile
            // building removes a sprite that might not even be at `position`
            // (a non-anchor cell was clicked) — rebuild rather than target
            // a `refresh` that could miss it, and treat this as one clear
            // per click rather than something to drag across.
            guard lastBulldozePosition == nil else { return }
            controller.bulldoze(at: position)
            rebuildRegion(around: position)
            lastBulldozePosition = position
            return
        }

        for step in stroke(from: lastBulldozePosition, to: position) {
            controller.bulldoze(at: step)
            refresh(step)
            refreshRoadNeighbors(of: step)
            refreshReflectionNeighbours(of: step)
        }
        lastBulldozePosition = position
    }

    /// Also refreshes `position`'s orthogonal neighbors that are
    /// themselves road/highway tiles — placing or clearing a road tile
    /// can change a *neighboring* road tile's own turn/intersection shape
    /// (a dead-end growing a new connection, a straight run gaining a
    /// branch), but that neighbor's own sprite was never touched by this
    /// click, so its lane line wouldn't otherwise pick up the change until
    /// the next simulation tick's `refreshAll()`. Immediate correctness
    /// matters more here than for most one-tick lags this project already
    /// tolerates elsewhere (`syncTrafficAnimation`'s own doc comment) —
    /// roads are drawn in long strokes the player is watching closely as
    /// they happen, not placed once and left alone.
    /// Redraws a buried tile *and the four around it*.
    ///
    /// **A conduit's mark is a statement about its neighbours**, exactly as a
    /// road's lane line is — `Infrastructure.conduitMask` reads all four — so
    /// laying one changes how the ones already there should be drawn. Nothing
    /// told them: every joint in a freshly dragged run stayed drawn as the
    /// dead end it was when it went down, and the whole run read as a chain of
    /// disconnected stubs until a tick repainted the map. While paused, which
    /// is when a player actually lays pipe, that is never.
    ///
    /// `refreshRoadNeighbors` has done the same thing for lane lines since
    /// roads had connectivity; the buried layers simply never got their
    /// version. Unconditional about zone, because a conduit goes under
    /// anything.
    private func refreshConduitNeighbours(of position: GridPosition) {
        refresh(position)
        for neighbour in position.orthogonalNeighbors() where map.contains(neighbour) {
            refresh(neighbour)
        }
    }

    /// Redraw what the tiles *in front of* `position` reflect.
    ///
    /// A reflection is a statement about a neighbour, exactly as a road's lane
    /// mask is — and this project has already had to learn that once, when a
    /// freshly dragged conduit run drew every joint as a dead end because
    /// nothing told the tiles already down that their neighbours had changed.
    ///
    /// `refreshRoadNeighbors` is not enough on its own: it only refreshes
    /// neighbours that are *road*, and a reflection lands on bare ground too.
    /// Placing a park at (9, 7) left (10, 7) and (9, 8) — its two down-screen
    /// neighbours, both empty — still reflecting nothing, which is how the
    /// scene playtest caught this.
    private func refreshReflectionNeighbours(of position: GridPosition) {
        // Down-screen is increasing x and increasing y: those are the tiles a
        // building's reflection can fall on.
        for ahead in [GridPosition(x: position.x + 1, y: position.y),
                      GridPosition(x: position.x, y: position.y + 1)]
        where map.contains(ahead) {
            refresh(ahead)
        }
    }

    private func refreshRoadNeighbors(of position: GridPosition) {
        for neighbor in position.orthogonalNeighbors() where map.contains(neighbor) {
            let zone = map[neighbor].zone
            guard zone == .road || zone == .highway else { continue }
            refresh(neighbor)
        }
    }

    /// Would placing `tool` at `position` touch a multi-tile building —
    /// either because `tool` itself spans more than one cell, or because
    /// whatever's already at `position` does? Either case needs the
    /// single-click-and-rebuild path in `place(with:)` instead of normal
    /// stroke-painting.
    private func involvesAFootprint(at position: GridPosition, with tool: ZoneType) -> Bool {
        tool.footprintSize > 1 || map[position].zone.footprintSize > 1
    }

    /// The tiles one drag event should act on: the whole line back to the
    /// previous tile in this stroke, or just `to` if there is no previous
    /// tile (the first tile of a stroke). Positions outside the map can
    /// appear in that line — e.g. a stroke that dips off an edge and back —
    /// but `controller.place`/`bulldoze` already ignore those, so this
    /// doesn't need to filter them itself.
    private func stroke(from: GridPosition?, to: GridPosition) -> [GridPosition] {
        guard let from else { return [to] }
        return from.line(to: to)
    }

    private func gridPosition(of event: NSEvent) -> GridPosition? {
        projection.position(for: event.location(in: self), in: map)
    }

    // MARK: - Placement preview

    /// Called by `GameSKView.mouseMoved`. Shows a footprint-sized outline
    /// at whatever grid cell the cursor is over — sized and positioned
    /// with the exact same `Isometric` math a real placement uses
    /// (`spriteSize(forFootprint:)`/`centerPoint(ofFootprintOrigin:size:)`),
    /// so the outline always shows precisely what a click right now would
    /// cover. Green while every cell it would cover is `.empty`; red if any
    /// of them already have a road or building on them — since `place(at:)`
    /// now genuinely refuses to place over anything but bare land, red here
    /// means the click really will do nothing (past a `blockedPlacementFlash`)
    /// until whatever's there gets bulldozed first, not just a heads-up
    /// about a silent auto-replace the way it used to.
    ///
    /// A click's grid tile is the footprint's minimum-x/minimum-y corner
    /// (`Isometric.project`'s own doc
    /// comment), so a multi-tile building extends up and to the right
    /// from wherever you click, not centered on it and not extending some
    /// other direction — exactly what this outline now shows up front.
    func updatePlacementPreview(at event: NSEvent) {
        updatePlacementPreview(at: gridPosition(of: event))
    }

    /// The preview once the pointer is a tile — split from the `NSEvent` for
    /// the reason `place(at:)` and `dragTo(_:)` were: what the cursor *says*
    /// is logic, and logic nothing can drive is logic nothing can check.
    func updatePlacementPreview(at position: GridPosition?) {
        guard let position else {
            placementPreviewNode.isHidden = true
            controller.inspect(at: nil)
            return
        }
        // The inspector rides the preview's tracking, which already computes
        // exactly the grid cell it needs. `inspect(at:)` no-ops unless the
        // pointer has actually crossed onto a different lot.
        controller.inspect(at: position)

        // Laying a pipe (or a power line) never conflicts with anything
        // already on the surface — there's no "blocked" state to warn
        // about the way a surface building has, so this is always a
        // plain 1×1 "clear" tile.
        if controller.overlayMode == .water || controller.overlayMode == .power {
            placementPreviewNode.fillColor = RenderPalette.placementPreviewClearFill
            placementPreviewNode.strokeColor = RenderPalette.placementPreviewClearStroke
            placementPreviewNode.path = projection.footprintCursor(size: 1)
            placementPreviewNode.position = projection.project(CGFloat(position.x), CGFloat(position.y), 0)
            placementPreviewNode.isHidden = false
            return
        }

        // **Drawing a line asks a different question of the tile.**
        //
        // Reported from play: *"it could be more apparent that you're
        // selecting a valid stop when making a route."* It was worse than
        // unclear — the cursor was actively lying. While a line is being
        // drawn a click names a *station*, but the preview went on describing
        // whatever zoning tool happened to be armed, and its "would this
        // replace something" test is true of every building on the map. So
        // the bus stop you were meant to click was drawn in the blocked
        // colour: the one tile that works, marked forbidden.
        //
        // It now answers the question the click will actually be asked, and
        // wraps the whole station rather than the tool's footprint, so a 2×2
        // rail terminus lights up as one thing.
        if let mode = controller.overlayMode.routeMode, controller.routeDraft?.mode == mode {
            let station = map[position].buildingOrigin
            let isStation = map[station].zone == mode.stationZone
            placementPreviewNode.fillColor = isStation
                ? RenderPalette.placementPreviewClearFill
                : RenderPalette.placementPreviewBlockedFill
            placementPreviewNode.strokeColor = isStation
                ? RenderPalette.placementPreviewClearStroke
                : RenderPalette.placementPreviewBlockedStroke
            let size = isStation ? map[station].zone.footprintSize : 1
            placementPreviewNode.path = projection.footprintCursor(size: CGFloat(size))
            placementPreviewNode.position = projection.project(
                CGFloat(isStation ? station.x : position.x),
                CGFloat(isStation ? station.y : position.y), 0
            )
            placementPreviewNode.isHidden = false
            return
        }

        let footprintSize = controller.selectedTool.footprintSize
        let footprint = map.footprintCells(origin: position, size: footprintSize)
        guard !footprint.isEmpty else {
            // Footprint doesn't fit the map from this corner (e.g. hovering
            // the last column with a 2×2 tool selected) — same "can't
            // place here" case `place(at:)` itself already no-ops on.
            placementPreviewNode.isHidden = true
            return
        }

        // **The cursor asks the question the click will be asked.** It used
        // to test "would this replace something", which was the whole rule
        // when it was written and has been a partial one since water landed:
        // a house hovered over a river, and a seaport hovered over dry land,
        // both drew clear and then refused. `placementRefusal` is the rule,
        // owned once by the controller.
        //
        // Affordability is deliberately *not* drawn as blocked. It already
        // has its own feedback — the red flash on the click — and a cursor
        // that turns red across the whole map the moment you are broke is
        // saying something about your treasury, not about this lot.
        let refusal = controller.placementRefusal(of: controller.selectedTool, at: position)
        let wouldBeRefused = refusal != nil && refusal != .insufficientFunds
        placementPreviewNode.fillColor = wouldBeRefused ? RenderPalette.placementPreviewBlockedFill : RenderPalette.placementPreviewClearFill
        placementPreviewNode.strokeColor = wouldBeRefused ? RenderPalette.placementPreviewBlockedStroke : RenderPalette.placementPreviewClearStroke

        placementPreviewNode.path = projection.footprintCursor(size: CGFloat(footprintSize))
        placementPreviewNode.position = projection.project(CGFloat(position.x), CGFloat(position.y), 0)
        placementPreviewNode.isHidden = false
    }

    /// Cursor left the grid, or a click just started an active paint
    /// stroke (where tiles are already being placed live, so a "here's
    /// what *would* happen" preview would be redundant/confusing).
    func clearPlacementPreview() {
        placementPreviewNode.isHidden = true
        controller.inspect(at: nil)
    }

    /// Briefly flash a tile red to explain why a click did nothing: the
    /// treasury can't cover it. `SKAction.colorize` animates a sprite's
    /// `color` over time — the property the old sprite-based renderer set —
    /// so this just animates out to the zone flash color and back to
    /// whatever color the tile actually is, without touching any data.
    private func flashInsufficientFunds(at position: GridPosition) {
        guard let node = tileNodes[position] else { return }
        tileRenderer.flash(on: node, tile: map[position],
                           color: RenderPalette.insufficientFundsFlash, duration: 0.35)
    }

    /// Briefly flash a tile to explain why a click did nothing: it's not
    /// empty. `place(at:)` no longer auto-replaces whatever's already
    /// there (see its own doc comment for why) — without this flash, that
    /// change would read as "clicking on an occupied tile silently does
    /// nothing," indistinguishable from a bug. Same `colorize`-out-and-back
    /// mechanism as `flashInsufficientFunds`, just `blockedPlacementFlash`
    /// instead — the same red the pre-click placement-preview outline
    /// already warns with.
    private func flashBlockedPlacement(at position: GridPosition) {
        guard let node = tileNodes[position] else { return }
        tileRenderer.flash(on: node, tile: map[position],
                           color: RenderPalette.blockedPlacementFlash, duration: 0.35)
    }

    /// Briefly flash a tile to make a `CityHazards.Strike` visible — without
    /// this, a hazard is silent: a density number that's just a bit lower
    /// next time you look. `service` picks the color (`RenderPalette.fireHazardFlash`
    /// for `.fireStation`, `.crimeHazardFlash` for `.policeStation`) so
    /// which hazard struck is legible from the flash color alone, the same
    /// way `flashInsufficientFunds` reuses `colorize` to animate out and
    /// back without touching any data.
    ///
    /// A faded overlay rather than a colorized tile, so it needs no "fade
    /// back to" colour at all — which also retired `currentColor(at:)`, a
    /// whole switch over every overlay mode that existed only to answer that.
    private func flashHazard(at position: GridPosition, service: ZoneType) {
        guard let node = tileNodes[position] else { return }
        let color = service == .fireStation ? RenderPalette.fireHazardFlash : RenderPalette.crimeHazardFlash
        tileRenderer.flash(on: node, tile: map[position], color: color, duration: 0.55)
    }

    // MARK: - Building the grid

    /// One sprite per *building*, not per cell — a 2×2 zone gets a single
    /// sprite spanning its footprint, so only anchor tiles
    /// (`Tile.isBuildingAnchor`) get one. A non-anchor cell's data (zone,
    /// density) is kept in sync with its building's anchor everywhere that
    /// writes it (`GameController.place`/`bulldoze`, `CitySimulator`,
    /// `CityHazards`), so it never needs a sprite of its own to represent.
    private func buildTileNodes() {
        for tile in map.tiles where tile.isBuildingAnchor {
            let node = tileRenderer.makeNode(for: tile)
            tileLayer.addChild(node)
            tileNodes[tile.position] = node
            syncTrafficAnimation(at: tile.position)
            syncAircraftAnimation(at: tile.position)
            syncLaneLine(at: tile.position)
        }
    }

    /// Tear down and rebuild every tile sprite from scratch. `refreshAll()`
    /// isn't enough for this — it re-syncs the sprites that already exist,
    /// but a map-size change means the *number* of tiles changed (a
    /// smaller map has stale sprites with nowhere valid to point; a larger
    /// one has positions with no sprite yet). Also what `place(with:)` and
    /// `bulldoze(with:)` call for a multi-tile footprint, since clearing or
    /// placing one can touch a sprite that isn't even at the clicked
    /// position (a non-anchor cell) — see their own doc comments.
    ///
    /// Deliberately does *not* touch the camera — a live playtest surfaced
    /// this as a real bug, not a nice-to-have: residential/commercial/
    /// industrial/police/fire/water tower are all 2×2, so *every* one of
    /// those placements or clears used to call `centerCameraOnMap()` too,
    /// snapping the view back to the middle of the map on every single one.
    /// Barely noticeable on a small map worked from its own center; on a
    /// 64×64 map worked from a far corner, it reads as "placing a building
    /// teleports the camera away" — and after a bulldoze, as "bulldoze did
    /// nothing," since the view yanks away from the exact spot you were
    /// just looking at. `GameView`'s Reset button — the one place recentering
    /// actually belongs, since `selectedMapSize` may have changed and the
    /// old camera position might not even be valid any more — calls
    /// `centerCameraOnMap()` itself, explicitly, right after this.
    /// Read-only views of the scene's sprite bookkeeping, so
    /// `GameSceneRebuildTests` can check that a bounded rebuild leaves exactly
    /// the state a full one would. Exposed rather than made internal wholesale
    /// so the mutable bookkeeping itself stays private.
    var tileNodesForTesting: [GridPosition: SKNode] { tileNodes }

    /// A PNG of the city as it stands.
    ///
    /// **Captured from the live view rather than an offscreen one**, and that
    /// is a constraint rather than a preference: `presentScene` *replaces*
    /// what a view is showing, so rendering this scene into a second view to
    /// get a bigger image would swap the running game out from under the
    /// player. This project has already shipped that bug once — the texture
    /// cache borrowed `GameScene`'s own view and froze the map the first time
    /// a building grew. A capture takes the backing scale it is given, which
    /// on any Mac worth screenshotting on is already 2×.
    ///
    /// Includes the shader pass, because the scanlines and the vignette are
    /// the look — a capture without them would be a picture of a frame the
    /// game never draws, which is the same objection `ZoneStreetscapeTests`
    /// records about rendering without the post-process.
    func captureImage() -> Data? {
        guard let view, let texture = view.texture(from: self) else { return nil }
        let image = NSBitmapImageRep(cgImage: texture.cgImage())
        return image.representation(using: .png, properties: [:])
    }

    /// The surrounding land, for the test that it is actually there.
    ///
    /// Worth pinning because nothing else in the suite would notice it going:
    /// `IsometricCityTests` renders through `IsoTileRenderer` on a plain
    /// `SKScene` of its own, so it cannot see anything that lives at scene
    /// level — the backdrop, or for that matter the sun, which has never
    /// appeared in that render either.
    var backdropNodeForTesting: SKSpriteNode { backdropNode }

    /// What the frame is actually blooming at, for the test that a style
    /// change reaches the shader and not only the textures.
    var bloomStrengthForTesting: Float? {
        retroEffectLayer.shader?.uniforms.first { $0.name == "u_bloomStrength" }?.floatValue
    }

    /// The transit diagram and what is running on it, for the tests that the
    /// lines are drawn at all and that something moves along them.
    var transitDiagramForTesting: SKNode { transitDiagramNode }

    /// Switch the whole post-process off, for the benchmark that asks what a
    /// frame actually spends its time on. `RetroShader` is per-*pixel*, so
    /// its cost scales with the window rather than with the city, and telling
    /// that apart from node count is the first question any frame-rate
    /// complaint has to answer.
    /// Take the backdrop and the sun out of the shaded area, for the
    /// measurement that decides whether culling tiles is worth writing.
    func detachBackdropForTesting() {
        backdropNode.removeFromParent()
        sunGlowNode.removeFromParent()
    }

    /// Hide every tile more than `radius` tiles from the map's middle, and
    /// report how many. For the measurement that decides how culling has to
    /// be written.
    func hideTilesOutsideForTesting(radius: Int) -> Int {
        let middle = GridPosition(x: map.width / 2, y: map.height / 2)
        var count = 0
        for (position, node) in tileNodes
        where abs(position.x - middle.x) > radius || abs(position.y - middle.y) > radius {
            node.isHidden = true
            count += 1
        }
        return count
    }

    /// The same, but detached from the layer rather than hidden.
    func detachTilesOutsideForTesting(radius: Int) -> Int {
        let middle = GridPosition(x: map.width / 2, y: map.height / 2)
        var count = 0
        for (position, node) in tileNodes
        where abs(position.x - middle.x) > radius || abs(position.y - middle.y) > radius {
            node.removeFromParent()
            count += 1
        }
        return count
    }

    /// Every child of the post-process layer and how much area it forces the
    /// shader to cover. The only way to find out which one is expensive
    /// without guessing.
    var postProcessContributorsForTesting: [(String, CGSize)] {
        retroEffectLayer.children.map {
            (($0.name ?? String(describing: type(of: $0))), $0.calculateAccumulatedFrame().size)
        }
    }

    /// How big an area the post-process is actually shading.
    ///
    /// `SKEffectNode` renders its children into an offscreen texture sized to
    /// their accumulated frame, so this is the number that decides what the
    /// shader costs — and if it is the whole map rather than the window, the
    /// shader is being run over a city nobody can see.
    var postProcessAreaForTesting: CGSize {
        retroEffectLayer.calculateAccumulatedFrame().size
    }

    func setPostProcessEnabledForTesting(_ enabled: Bool) {
        retroEffectLayer.shouldEnableEffects = enabled
    }

    /// Poke one post-process term, for isolating which of them is
    /// responsible for something seen in a frame. Seven uniforms run over the
    /// finished picture and a still of all of them together cannot say which
    /// one did anything.
    func setShaderUniformForTesting(_ name: String, _ value: Float) {
        retroEffectLayer.shader?.uniforms.first { $0.name == name }?.floatValue = value
    }

    /// The things travelling a real path across the map — trams on their
    /// rails, ships in their channel — for the tests about whether they do.
    var pathVehicleCountForTesting: Int { pathVehicles.count }
    var pathVehiclePositionsForTesting: [CGPoint] { pathVehicles.map(\.holder.position) }

    var transitVehicleCountForTesting: Int {
        transitDiagramNode.children.filter { $0.name == Self.transitVehicleNodeName }.count
    }

    /// Where the vehicles running the route diagram currently are.
    ///
    /// **This used to report `isPaused`**, which was the mechanism rather than
    /// the property — and it stopped being true the moment these moved onto
    /// the per-frame driver, where a vehicle holds still because nothing
    /// advances it. Positions survive both designs.
    var transitVehiclePositionsForTesting: [CGPoint] {
        transitDiagramNode.children
            .filter { $0.name == Self.transitVehicleNodeName }
            .map(\.position)
    }

    /// The placement cursor, for the tests about what it says.
    var placementPreviewForTesting: SKShapeNode { placementPreviewNode }
    var tileLayerChildCountForTesting: Int { tileLayer.children.count }

    static var trafficCarNodeNameForTesting: String { trafficCarNodeName }
    static var transitVehicleNodeNameForTesting: String { transitVehicleNodeName }

    static var simulationDrivenNodeNamesForTesting: Set<String> { animatedBySimulation }

    func rebuildEntireGrid() {
        // Every tile node is about to be replaced, so every reference in
        // here is about to dangle.
        trafficCars.removeAll()
        aircraft.removeAll()
        // The trams live in `tileLayer`, so they go with it — and the key has
        // to be cleared too, or `syncTramRuns` decides nothing has changed and
        // they never come back. Exactly the stale-cache shape an overlay has
        // to invalidate the keys of what it hides for.
        pathVehicles = []
        pathVehiclesKey = nil
        tileLayer.removeAllChildren()
        tileNodes.removeAll()
        buildTileNodes()
        positionSunGlow()
        positionBackdrop()
    }

    /// Redraw the whole city in the current `VisualStyle`.
    ///
    /// A style change is not a map change, so it does not go through
    /// `cityGeneration` — but it needs strictly more than a rebuild, because
    /// the palette is baked into every cached texture. Purge first, then
    /// rebuild, or the map comes back in exactly the style it was just
    /// switched away from.
    func restyle() {
        tileRenderer.textures.purge()
        backgroundColor = RenderPalette.background
        // Bloom lives in the shader rather than in a texture, so it is the
        // one part of a style change that a purge-and-rebuild would *not*
        // pick up on its own.
        if let shader = retroEffectLayer.shader { RetroShader.applyStyle(shader) }
        // Water is the other effect that lives in a shader rather than a
        // texture, so a purge-and-rebuild alone would leave the river moving
        // in the style just switched away from.
        WaterShader.applyStyle(IsoTileRenderer.water)
        rebuildEntireGrid()
        refreshAll()
    }

    /// How far around a placement `rebuildRegion(around:)` reaches.
    ///
    /// A placement can clear a building whose *anchor* sits outside the
    /// footprint that was clicked — a 3×3 plant's anchor is up to two tiles
    /// away in each axis from any cell it covers, and the new building can be
    /// 3×3 as well. Four tiles covers both with a margin, and is still two
    /// orders of magnitude fewer nodes than the whole map.
    private static let rebuildRadius = 4

    /// Rebuilds the sprites around `position` rather than the whole map.
    ///
    /// **This is the fix for the map visibly blinking on every click.**
    /// Placing a multi-tile building used to call `rebuildEntireGrid()`, which
    /// tears down and recreates every sprite on the map — measured at 202 ms
    /// for a built-out 64×64 city in a Debug build, on the main thread, in
    /// response to a single click. Every growable zone is 2×2, so that was
    /// *every* zone placement.
    ///
    /// A full rebuild was used because a footprint placement changes which
    /// tiles are anchors at all — four single tiles becoming one 2×2 building
    /// means three sprites have to go and one has to appear, which a per-tile
    /// `refresh` cannot express. That is still true, but it is only true
    /// *locally*: nothing outside the clicked neighbourhood can change anchor
    /// status, so the same work over a small window is correct and bounded.
    func rebuildRegion(around position: GridPosition) {
        let radius = Self.rebuildRadius
        for dy in -radius ... radius {
            for dx in -radius ... radius {
                let cell = GridPosition(x: position.x + dx, y: position.y + dy)
                guard map.contains(cell) else { continue }
                if let existing = tileNodes.removeValue(forKey: cell) {
                    existing.removeFromParent()
                }
            }
        }
        for dy in -radius ... radius {
            for dx in -radius ... radius {
                let cell = GridPosition(x: position.x + dx, y: position.y + dy)
                guard map.contains(cell), map[cell].isBuildingAnchor else { continue }
                let node = tileRenderer.makeNode(for: map[cell])
                tileLayer.addChild(node)
                tileNodes[cell] = node
                // **A full refresh, not two hand-picked decorations.** This
                // used to sync the traffic and the lane line and nothing else,
                // so a rebuilt tile came back missing its utility warning, its
                // damage marker, its scaffold, its fire — and, once overlays
                // existed, wearing no overlay at all. Placing anything
                // therefore stripped a nine-by-nine patch of the map back to
                // a bare Normal view until the next tick repainted it, which
                // while the game is paused is never.
                //
                // Found by the scene playtest, which is exactly the shape of
                // bug it was built for: nothing failed, the map was simply
                // showing less than it knew.
                refresh(cell)
            }
        }
    }

    /// Point the camera at the middle of the map. The camera's position is
    /// the scene point that appears at the center of the view. Called from
    /// `didMove(to:)` on first load and explicitly by `GameView`'s Reset
    /// button after `rebuildEntireGrid()` — never implicitly by
    /// `rebuildEntireGrid()` itself any more; see that method's own doc
    /// comment for why.
    func centerCameraOnMap() {
        cameraNode.position = projection.centerPoint(of: map)
    }

    /// Re-anchor `sunGlowNode` to the current map's size — called whenever
    /// the map itself might have changed size (`rebuildEntireGrid()`), not
    /// just once at startup. Sized and placed off of `contentSize(of:)`
    /// rather than a fixed constant so a 64×64 map's sun is proportionally
    /// the same "how much of the view does this fill" as a 32×32 map's.
    /// Centered horizontally on the map, low enough that only its topmost
    /// sliver would fall inside the map's own bottom edge (where tiles
    /// occlude it) — the rest sits in the empty space below the map,
    /// where it's actually visible.
    private func positionSunGlow() {
        let content = projection.contentBounds(of: map)
        let diameter = max(content.width, content.height) * 1.6
        sunGlowWorldBounds = CGRect(
            x: content.midX - diameter / 2,
            y: content.minY - diameter * 0.35 - diameter / 2,
            width: diameter, height: diameter
        )
        showVisibleSliceOfBackground()
    }

    private var sunGlowWorldBounds: CGRect = .zero

    /// How far the surrounding land actually reaches, in world points.
    ///
    /// **Not the backdrop node's size**, which is only the slice currently on
    /// screen — see `clipToView`. A test asking the node how big the world is
    /// gets the size of the window instead, which is how the land-extends-past
    /// -the-map assertion started failing on a change that did not move an
    /// inch of land.
    var backdropReachForTesting: CGRect { backdropWorldBounds }

    /// How far past the map's own edge the land carries on, in tiles.
    ///
    /// Generous enough that the camera — clamped to the map's bounds, but
    /// clamped *loosely*, so the corners stay reachable — can never pan far
    /// enough to find the end of it.
    private static let backdropMarginTiles = 36

    /// How many tiles apart the surrounding grid is ruled — see
    /// `positionBackdrop` for why this is not 1.
    private static let backdropGridPitch = 4

    /// Rebuilds the surrounding land for the current map.
    ///
    /// The grid is drawn by projecting real tile coordinates rather than by
    /// working out where the lines would fall on screen. Same rule the
    /// streetscape render had to learn: a second implementation of the
    /// projection would line up until the day it did not, and a backdrop
    /// grid a half-tile out of step with the city standing on it is worse
    /// than no grid at all.
    private func positionBackdrop() {
        let margin = CGFloat(Self.backdropMarginTiles)
        let low = -margin, highX = CGFloat(map.width) + margin, highY = CGFloat(map.height) + margin

        // The projected extent of that extended grid — its four corners are
        // the four corners of the tile range.
        let corners = [
            projection.project(low, low, 0), projection.project(highX, low, 0),
            projection.project(highX, highY, 0), projection.project(low, highY, 0),
        ]
        let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!
        let minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
        let bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        // Drawn well below 1:1. A faint grid fading into the dark is the one
        // thing in this renderer that genuinely does not need crisp pixels,
        // and a 64×64 map's surroundings at full scale would be a 30 MB
        // texture to say something almost invisible.
        let scale = Swift.min(1, 1_200 / Swift.max(bounds.width, bounds.height))
        let pixelWidth = Int(bounds.width * scale), pixelHeight = Int(bounds.height * scale)
        guard pixelWidth > 4, pixelHeight > 4,
              let context = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return }

        // Into texture space: the projection's origin is somewhere inside
        // `bounds`, and CGContext counts up from the bottom-left.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)

        // The surface first. Drawn as the projected quad of the extended tile
        // range rather than as the whole texture rect, so the land is a
        // diamond of ground with the grid ruled across it — filling the
        // rectangle would put four bright corners beyond where any tile is.
        context.setFillColor(RenderPalette.unclaimedGround.cgColor)
        context.beginPath()
        context.move(to: corners[0])
        for corner in corners.dropFirst() { context.addLine(to: corner) }
        context.closePath()
        context.fillPath()

        // **Ruled every few tiles, not every tile.** Per-tile lines out here
        // are not ground, they are a quilt: at the zoom a player actually
        // plans at, a 36-tile margin of one-tile diamonds collapses into a
        // moiré pattern that fights the city instead of sitting behind it.
        // A coarse pitch reads as large unclaimed parcels, which is both
        // calmer and closer to what it is meant to say.
        //
        // The same `minimumDetailSize` argument the buildings already follow:
        // a mark too small to resolve does not add detail, it adds noise.
        context.setStrokeColor(RenderPalette.unclaimedGrid.cgColor)
        context.setLineWidth(1.2 / scale)
        let pitch = CGFloat(Self.backdropGridPitch)
        for x in stride(from: low, through: highX, by: pitch) {
            context.move(to: projection.project(x, low, 0))
            context.addLine(to: projection.project(x, highY, 0))
        }
        for y in stride(from: low, through: highY, by: pitch) {
            context.move(to: projection.project(low, y, 0))
            context.addLine(to: projection.project(highX, y, 0))
        }
        context.strokePath()

        // **The claimed land reads as a plate laid on the wild land.**
        //
        // The macro version of the same idea as a building's contact light:
        // without it the map is simply a differently-coloured region of the
        // same flat surface, and a city needs to look like it sits *on*
        // somewhere. Filling the map's own diamond with a shadow set spills a
        // soft dark fringe down-screen past its edge — the only part that
        // shows, since the map's own tiles cover everything inside it.
        //
        // Drawn before the radial fade so the fringe fades out with the land
        // it falls on rather than hanging on after it.
        context.saveGState()
        context.setBlendMode(.normal)
        context.setShadow(
            offset: CGSize(width: 0, height: -projection.tileHeight * 0.9),
            blur: projection.tileHeight * 1.6,
            color: SKColor.black.withAlphaComponent(0.75).cgColor
        )
        context.setFillColor(RenderPalette.unclaimedGround.cgColor)
        let plate = [
            projection.project(0, 0, 0), projection.project(CGFloat(map.width), 0, 0),
            projection.project(CGFloat(map.width), CGFloat(map.height), 0),
            projection.project(0, CGFloat(map.height), 0),
        ]
        context.beginPath()
        context.move(to: plate[0])
        for corner in plate.dropFirst() { context.addLine(to: corner) }
        context.closePath()
        context.fillPath()
        context.restoreGState()

        // Fade it out toward the edges, so the land reads as continuing into
        // the dark rather than stopping at a rectangle. Multiplied into the
        // alpha that is already there rather than painted over it, which is
        // what keeps the grid lines themselves crisp where they are visible.
        context.resetClip()
        context.setBlendMode(.destinationIn)
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        if let fade = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                SKColor.white.cgColor,
                SKColor.white.withAlphaComponent(0.55).cgColor,
                SKColor.white.withAlphaComponent(0).cgColor,
            ] as CFArray,
            // Holds most of the way out and then falls off, rather than
            // fading from the middle — the land nearest the city is the part
            // doing the work, and a gradient that starts dropping at once
            // takes it away exactly where it is wanted.
            locations: [0, 0.72, 1]
        ) {
            context.drawRadialGradient(
                fade, startCenter: centre, startRadius: 0,
                endCenter: centre, endRadius: Swift.max(bounds.width, bounds.height) / 2,
                options: []
            )
        }

        guard let image = context.makeImage() else { return }
        backdropTexture = SKTexture(cgImage: image)
        backdropWorldBounds = bounds
        backdropNode.colorBlendFactor = 0
        showVisibleSliceOfBackground()
    }

    /// **Detach tiles nobody can see.**
    ///
    /// The other half of the same problem the backdrop had: everything in
    /// `tileLayer` counts toward the accumulated frame of the `SKEffectNode`
    /// running `RetroShader`, so a tile forty screens away still costs shader
    /// area. With the backdrop fixed, the tiles were the whole of what was
    /// left — measured at 3130×1646 for a 48×48 city against a 1280×800
    /// window, dropping to 922×554 once they were detached.
    ///
    /// **Detached, not hidden**, and that is not a style preference: a hidden
    /// node still counts toward `calculateAccumulatedFrame()`. Hiding 1,059
    /// tiles changed the shaded area by exactly nothing, which is the measured
    /// reason this is written the more awkward way.
    ///
    /// Recomputed only when the camera has actually moved a tile's worth, so
    /// an idle frame costs one comparison.
    private func cullTilesOutsideTheView() {
        let visible = CGRect(
            x: cameraNode.position.x - size.width * cameraNode.xScale / 2,
            y: cameraNode.position.y - size.height * cameraNode.yScale / 2,
            width: size.width * cameraNode.xScale,
            height: size.height * cameraNode.yScale
        )
        // A generous margin: a building is drawn well above its tile's own
        // origin, so a lot whose *ground* is off screen can still have a tower
        // reaching into it. Cheaper to keep a border of them than to work out
        // how tall each one is.
        let margin = projection.tileHeight * 12
        let wanted = visible.insetBy(dx: -margin, dy: -margin)
        guard wanted != culledFor else { return }
        culledFor = wanted

        for (position, node) in tileNodes {
            let point = projection.project(CGFloat(position.x), CGFloat(position.y), 0)
            let inside = wanted.contains(point)
            if inside, node.parent == nil {
                tileLayer.addChild(node)
                // **A tile coming back has to be asked whether it is still
                // current**, because things change while it is detached — and
                // the detail tier is the one that changes *because* it is
                // detached, since a tier swap only redraws what is on screen.
                // The cache keys make this a handful of dictionary lookups
                // when nothing has moved, which is the common case by far.
                refresh(position)
            } else if !inside, node.parent != nil {
                node.removeFromParent()
            }
        }
    }

    /// The view the tiles were last culled for.
    private var culledFor: CGRect?

    // MARK: - Bloom

    /// How far the bloom reaches, in **screen** points.
    ///
    /// Bloom is a lens artefact: it happens in the camera, so it covers a
    /// fixed distance on the glass however far away the thing being
    /// photographed is. That is not what it was doing.
    ///
    /// `u_bloomRadius` is a fraction of the *render target*, and an
    /// `SKEffectNode` sizes its target to whatever its children cover — which
    /// `cullTilesOutsideTheView` deliberately made camera-dependent. So the
    /// reach drifted with zoom, and in the worst possible direction:
    /// **33 points at the closest camera against 14 at the widest**, a 2.3×
    /// swing, largest exactly where a lit window is already four times its
    /// resting size. Nobody chose that; it fell out of the cull margin.
    ///
    /// 23 points because that is what the resting camera was already getting,
    /// so the view the game is mostly played at is unchanged and only the
    /// ends of the range move.
    private static let bloomReachInPoints: CGFloat = 23

    /// What the shaded area was last measured as, and for what camera.
    ///
    /// **`calculateAccumulatedFrame()` walks every node under the effect
    /// layer**, which on a built-out city is eight thousand of them — measured
    /// at 0.35 ms, against 0.42 ms for the whole of `update()`. Calling it
    /// every frame made one bookkeeping line five sixths of the frame's own
    /// work. It only changes when the culling attaches or detaches something
    /// or the camera moves, and both of those are already tracked.
    private var bloomShadedHeight: CGFloat = 0
    private var bloomMeasuredFor: (cull: CGRect, scale: CGFloat)?

    private func matchBloomReachToTheCamera() {
        guard let shader = retroEffectLayer.shader else { return }
        let key = (cull: culledFor ?? .zero, scale: cameraNode.yScale)
        if bloomMeasuredFor?.cull != key.cull || bloomMeasuredFor?.scale != key.scale {
            bloomMeasuredFor = key
            bloomShadedHeight = retroEffectLayer.calculateAccumulatedFrame().height
        }
        let shaded = bloomShadedHeight
        guard shaded > 1 else { return }
        // A screen point is `cameraScale` world points, and the shader's
        // radius is a fraction of the target's height in world points.
        let fraction = Self.bloomReachInPoints * cameraNode.yScale / shaded
        shader.uniforms.first { $0.name == "u_bloomRadius" }?.floatValue = Float(fraction)
    }

    /// What the bloom currently reaches, in screen points, for the test that
    /// it is the same at every zoom.
    var bloomReachInPointsForTesting: CGFloat {
        guard let shader = retroEffectLayer.shader,
              let radius = shader.uniforms.first(where: { $0.name == "u_bloomRadius" })?.floatValue,
              cameraNode.yScale > 0
        else { return 0 }
        return CGFloat(radius) * retroEffectLayer.calculateAccumulatedFrame().height
            / cameraNode.yScale
    }

    // MARK: - Detail tier

    /// The camera scale at or below which buildings are drawn with their near
    /// detail.
    ///
    /// Camera scale runs the other way from magnification — `minimumZoomScale`
    /// (0.5) is the *closest* view — so this engages in the near half of the
    /// range between resting (1.0) and closest. Deliberately not "always on":
    /// a mullion is 1.5 points, and at rest that is three physical pixels on a
    /// Retina display, which is precisely the grey speckle
    /// `NeonStyle.minimumDetailSize` exists to delete. Detail that cannot be
    /// resolved does not add information, it averages the facade toward mud.
    /// Hysteresis, for the reason `CitySimulator.declineMargin` has it: read
    /// the same number in both directions and a pinch resting on the boundary
    /// flips the whole map back and forth forever.
    private static let nearDetailScale: CGFloat = 0.72
    private static let farDetailScale: CGFloat = 0.78

    /// Which tier the tiles on screen were drawn at.
    private var drawnForDetail: IsometricBuilding.Detail = .standard

    /// **The scene notices for itself**, the same way it notices an overlay
    /// changing under it, rather than every caller that can move the camera
    /// remembering to say so — and there are several: the pinch, the keyboard,
    /// `centerCameraOnMap`, and a load.
    ///
    /// Affordable per frame because it is a comparison, and affordable when it
    /// *does* fire because tiles outside the view have already been detached
    /// by `cullTilesOutsideTheView`. At the zoom this engages at that is about
    /// twenty buildings, which is the whole reason a detail tier is possible
    /// at all: the marks are expensive per building and there are almost none
    /// of them on screen when you are close enough to see them.
    private func matchBuildingDetailToTheCamera() {
        let scale = cameraNode.xScale
        let wanted: IsometricBuilding.Detail
        if scale <= Self.nearDetailScale { wanted = .near }
        else if scale >= Self.farDetailScale { wanted = .standard }
        else { return }
        guard wanted != drawnForDetail else { return }
        drawnForDetail = wanted
        tileRenderer.detail = wanted

        // **Only what is on screen**, which is what makes the swap affordable.
        // `refreshAll` walks every tile the map has, attached or not, so on a
        // built-out city it would ask the cache to rasterise the whole near
        // variant set in one frame — about 650 ms of blur, as a freeze, the
        // instant the player zooms in. The rest are redrawn by
        // `cullTilesOutsideTheView` as they come back into view, a band at a
        // time, which is also when their tier can first be seen.
        for position in tileNodes.keys where tileNodes[position]?.parent != nil {
            refresh(position)
        }
    }

    /// Testing accessor: put the camera over one tile, clamped the way a pan
    /// is. Used by `CityPortraitTests` to frame a shot on the downtown rather
    /// than on whatever happens to sit at the middle of the map.
    func centerCameraForTesting(on position: GridPosition) {
        cameraNode.position = projection.centerPoint(ofFootprintOrigin: position, size: 1)
        clampCameraToMap()
    }

    /// Testing accessor: the whole map's ground diamond, for a caller working
    /// out a zoom that fits it.
    var contentBoundsForTesting: CGRect { projection.contentBounds(of: map) }

    /// Testing accessor: put the camera at `scale`, clamped the way a pinch
    /// is, so a test cannot assert against a view the game cannot reach.
    func setCameraScaleForTesting(_ scale: CGFloat) {
        cameraNode.setScale(min(max(scale, minimumZoomScale), maximumZoomScale))
    }

    /// The renderer, so a benchmark can ask its texture cache how much it is
    /// holding. Testing accessor.
    var tileRendererForTesting: IsoTileRenderer { tileRenderer }

    /// Which detail tier the scene is currently drawing. Testing accessor.
    var buildingDetailForTesting: IsometricBuilding.Detail { drawnForDetail }

    /// The whole backdrop, and the world rect it covers.
    ///
    /// Kept so the sprite can show a *slice* of it rather than all of it.
    private var backdropTexture: SKTexture?
    private var backdropWorldBounds: CGRect = .zero

    /// **Show only the part of the backdrop that is on screen.**
    ///
    /// The sprite used to be the size of the whole extended grid — thousands
    /// of points across — and that turned out to be the single most expensive
    /// thing in the renderer, for a reason that is not obvious from reading
    /// it: `SKEffectNode` renders its children into an offscreen texture sized
    /// to their **accumulated frame**, and this node is inside the one that
    /// runs `RetroShader`. So the post-process was running over the entire
    /// map every frame.
    ///
    /// Measured on a 64×64 city at a 1280×800 window: the shader was covering
    /// **8704×8771 points — 74× the area of the window**. That is why frame
    /// cost tracked the size of the city and barely moved when the resolution
    /// doubled, which is backwards for anything per-pixel and was the clue.
    ///
    /// The fix costs nothing per frame: the texture is unchanged and still
    /// drawn once, and this only moves the sprite and picks a sub-rect of it.
    /// Note that `isHidden` would *not* have worked — a hidden node still
    /// counts toward the accumulated frame. Only detaching or shrinking does,
    /// which is a thing worth knowing before writing any culling.
    private func showVisibleSliceOfBackground() {
        if let texture = backdropTexture {
            clipToView(backdropNode, of: texture, covering: backdropWorldBounds)
        }
        // **The sun needs exactly the same treatment**, and finding that out
        // took a second measurement. Fixing the backdrop alone took a 64×64
        // map's shaded area from 8704×8771 to 6554×7471 — barely a third of
        // the win — because the sun glow is sized `contentBounds × 1.6`, which
        // is 6554 points across on that map, and it was still whole.
        //
        // Listing each child's accumulated frame is what found it. Reasoning
        // about which node "ought" to be big had already sent me to the wrong
        // one twice.
        clipToView(sunGlowNode, of: Self.sunGlowTexture, covering: sunGlowWorldBounds)
    }

    /// Show only the part of a world-sized background sprite that is on
    /// screen, by moving it and picking a sub-rect of its texture.
    ///
    /// Everything in `retroEffectLayer` counts toward the accumulated frame
    /// that `SKEffectNode` sizes its offscreen render target from, so a sprite
    /// spanning the map makes `RetroShader` run over the map — including all
    /// of it nobody can see. The texture here is unchanged and still drawn
    /// once; this only costs a position and a rect per frame.
    private func clipToView(_ node: SKSpriteNode, of texture: SKTexture, covering bounds: CGRect) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        // A margin, so a fast pan cannot outrun it between frames.
        let visible = CGSize(width: size.width * cameraNode.xScale * 1.2,
                             height: size.height * cameraNode.yScale * 1.2)
        let wanted = CGRect(
            x: cameraNode.position.x - visible.width / 2,
            y: cameraNode.position.y - visible.height / 2,
            width: visible.width, height: visible.height
        ).intersection(bounds)
        guard !wanted.isNull, wanted.width > 1, wanted.height > 1 else {
            node.isHidden = true
            return
        }
        node.isHidden = false
        node.texture = SKTexture(
            rect: CGRect(x: (wanted.minX - bounds.minX) / bounds.width,
                         y: (wanted.minY - bounds.minY) / bounds.height,
                         width: wanted.width / bounds.width,
                         height: wanted.height / bounds.height),
            in: texture
        )
        node.size = wanted.size
        node.position = CGPoint(x: wanted.midX, y: wanted.midY)
    }

    // MARK: - Refreshing from data

    /// Push current tile data into the existing sprites.
    ///
    /// Called after every click, and after every simulation step. It exists
    /// to make the intended data flow explicit: change data -> refresh
    /// view. Never the reverse.
    /// The buildings that *feed* each network, and so stay bright in its
    /// overlay rather than dimming with everything else.
    private static func suppliesWater(_ zone: ZoneType) -> Bool {
        zone == .waterTower || zone == .waterPump
    }

    private static func suppliesPower(_ zone: ZoneType) -> Bool {
        zone == .powerPlant || zone == .generator
    }

    /// How a building is drawn in a utility overlay — the overlay's real
    /// answer to "is this on my network?".
    ///
    /// The source of the network is `.highlighted` and keeps its own colours,
    /// because that is the thing the player is hunting for. Everything else
    /// carries the answer itself rather than a brightness, so the renderer can
    /// paint a supplied building in the utility's colour — see
    /// `IsoTileRenderer.OverlayBuildings.connected`.
    private static func overlayBuildings(isSource: Bool, isSupplied: Bool) -> IsoTileRenderer.OverlayBuildings {
        isSource ? .highlighted : .connected(isSupplied)
    }

    func refresh(_ position: GridPosition) {
        // **A covered tile has no node of its own.** One node exists per
        // *building*, so the three cells of a 2×2 that are not its anchor
        // refresh nothing — which is invisible for anything drawn from the
        // building's own state, and was not invisible at all for the buried
        // layers, where laying a pipe under a block changed the map and
        // redrew nothing. Redirect to whatever owns this ground.
        // Everything below is about the *building*, so it works in the
        // building's own coordinates from here on — `position` is only the
        // ground somebody touched.
        let anchor = map[position].buildingOrigin
        guard let node = tileNodes[anchor] else { return }
        let tile = map[anchor]

        // **One overlay branch, not ten `clear…` calls each.** The top-down
        // version repeated a block of ten in every branch, and every
        // decoration added since had to be remembered in all five — the kind
        // of repetition that goes stale silently, since a forgotten line
        // leaves a stray building floating over a heatmap rather than failing
        // anything. `applyOverlay` is the whole idea: hide what describes the
        // building, tint the ground.
        switch controller.overlayMode {
        case .none:
            tileRenderer.restoreFromOverlay(on: node)
            tileRenderer.update(node, for: tile, reflecting: reflection(at: tile.position))
            tileRenderer.syncConduits(on: node, isPipe: true, segments: [])
            tileRenderer.syncConduits(on: node, isPipe: false, segments: [])
            tileRenderer.syncTramTrack(on: node, present: false, mask: 0)
            syncLaneLine(at: anchor)
            // Damage is drawn on the anchor's node only, since that is the one
            // cell of a building that gets a node at all.
            tileRenderer.syncDamageMarker(on: node, tile: tile, damagedBy: tile.damagedBy)
            // Same reasoning, and the same anchor-only placement: a scaffold
            // belongs to a building, not to each of its cells.
            tileRenderer.syncConstructionSite(on: node, tile: tile)
            tileRenderer.syncFireMarker(on: node, tile: tile)
            // Normal view only — the Water/Power overlays already have their
            // own, bigger signal for this (the whole lot's colour), so a badge
            // on top of that would be redundant.
            tileRenderer.syncUtilityWarning(
                on: node, tile: tile,
                hasWaterSupply: Water.hasSupply(at: anchor, in: map),
                hasPowerSupply: PowerGrid.hasSupply(at: anchor, in: map)
            )
        default:
            // One call for every overlay, from the shared decision in
            // `IsoTileRenderer.paint` — see its doc comment for why this
            // stopped being a switch here.
            if let paint = IsoTileRenderer.paint(
                for: controller.overlayMode, at: anchor, in: map,
                using: overlayDistances, transit: overlayTransitCoverage
            ) {
                // **The building first, then the paint over it.** An overlay
                // *tints* what is there; it has never built anything. So a lot
                // that grew — or appeared — while a view was up kept whatever
                // sprite it had, and only came right when the player flipped
                // to Normal and back, which is how this was reported.
                //
                // Safe to call every tick now that the cache keys are cleared
                // on the *view* changing rather than on every tile of every
                // tick: an unchanged lot costs a dictionary lookup, and a
                // changed one rebuilds exactly once.
                tileRenderer.update(node, for: tile, reflecting: reflection(at: tile.position))
                tileRenderer.applyOverlay(on: node, buildings: paint.buildings, color: paint.color,
                                     buildingColor: paint.buildingColor,
                                     keepingRoads: paint.showsRoads)
                // The Traffic view is a heatmap *of the streets*, so the
                // streets stay drawn — and a road laid while it is up appears
                // straight away rather than looking like a click that did
                // nothing.
                if paint.showsRoads { syncLaneLine(at: anchor) }
            }
            // The buried layers stay here: they are drawn *on top of* the
            // overlay rather than being part of it, and they read `hasPipe` /
            // `hasPowerLine` directly rather than the cached supply, so a line
            // you just laid shows up right away — the supply colouring above
            // still waits for the next tick to recompute it, same as for a
            // newly-placed tower.
            // **Every cell of the building, not just its anchor.** A pipe
            // goes under anything, including the cells of a block that have
            // no node of their own — see `IsoTileRenderer.syncConduits`.
            // **Both layers, every time — one of them empty.** These used to
            // be drawn only by the view that owns them and never taken away by
            // any other, so going from Water to Power left the pipes on the
            // map underneath the power lines. Asking for the empty set is how
            // a layer gets cleared; skipping the call is how it lingers.
            tileRenderer.syncConduits(
                on: node, isPipe: true,
                segments: controller.overlayMode == .water ? conduitSegments(of: tile, isPipe: true) : []
            )
            tileRenderer.syncConduits(
                on: node, isPipe: false,
                segments: controller.overlayMode == .power ? conduitSegments(of: tile, isPipe: false) : []
            )
            // The rails, in the one view that has something to say about the
            // ground — a tram is the only mode that costs the street
            // anything, so the Tram view has to show which streets paid.
            tileRenderer.syncTramTrack(
                on: node,
                present: controller.overlayMode == .tram && map.tramTracks.contains(anchor),
                mask: tramTrackMask(at: anchor)
            )
        }
        syncTrafficAnimation(at: anchor)
        syncAircraftAnimation(at: anchor)
        // Last, so anything just rebuilt inherits the pause state rather than
        // starting to drive around a stopped city. The list is down to the
        // fire and the rain — every vehicle in the game is driven per frame
        // now, and stops because nothing advances it.
        applyAnimationPause(to: node)
    }

    /// Every buried segment under the building anchored at `tile`.
    ///
    /// Live means "this length traces back to a source" — the supply
    /// computation has known it every tick since pipes existed, and it is
    /// what tells an orphaned run from a working one.
    private func conduitSegments(of tile: Tile, isPipe: Bool) -> [IsoTileRenderer.Segment] {
        map.footprintCells(origin: tile.position, size: tile.zone.footprintSize)
            .compactMap { cell in
                guard isPipe ? map[cell].hasPipe : map[cell].hasPowerLine else { return nil }
                return IsoTileRenderer.Segment(
                    offset: GridPosition(x: cell.x - tile.position.x, y: cell.y - tile.position.y),
                    mask: Infrastructure.conduitMask(at: cell, in: map, isPipe: isPipe),
                    live: isPipe
                        ? map.waterSupply.isSupplied(at: cell)
                        : map.powerSupply.isSupplied(at: cell)
                )
            }
    }

    /// Which of a track tile's neighbours also carry rails, in the same
    /// four-bit shape `Infrastructure.conduitMask` uses — so the rails draw as
    /// a connected run through a junction rather than as a chain of separate
    /// marks, and reuse the conduit rasteriser rather than needing their own.
    private func tramTrackMask(at position: GridPosition) -> Int {
        var mask = 0
        let neighbours: [(Int, GridPosition)] = [
            (1, GridPosition(x: position.x + 1, y: position.y)),
            (2, GridPosition(x: position.x - 1, y: position.y)),
            (4, GridPosition(x: position.x, y: position.y + 1)),
            (8, GridPosition(x: position.x, y: position.y - 1)),
        ]
        for (bit, neighbour) in neighbours where map.tramTracks.contains(neighbour) {
            mask |= bit
        }
        return mask
    }

    /// Adds (or removes) a road/highway tile's glowing lane-line detail,
    /// shaped to match what's actually connected to it
    /// (`Traffic.roadConnections(at:in:)`) — see `IsoTileRenderer.syncLaneLine`'s
    /// own doc comment for why that connectivity answer has to be computed
    /// here, with the full `map`, and passed down rather than computed
    /// inside `IsoTileRenderer` itself.
    private func syncLaneLine(at position: GridPosition) {
        guard let node = tileNodes[position] else { return }
        let zone = map[position].zone
        tileRenderer.syncLaneLine(
            on: node, zone: zone,
            connections: Traffic.roadConnections(at: position, in: map),
            // How worn the road is decides how brightly its lane line burns.
            condition: Infrastructure.condition(of: map[position])
        )
    }

    /// A `ZoneDistanceField` held only for the duration of a `refreshAll()`.
    ///
    /// The land-value overlay colors every tile by `LandValue.value(at:)`,
    /// which without a precomputed field scans the whole map eight times
    /// *per tile* — on a 64×64 map that is the same `O(tiles²)` cost that
    /// made `CitySimulator.advance` 72% of a tick, except paid on the render
    /// thread. Computing one field for the sweep makes it linear.
    ///
    /// Deliberately `nil` outside `refreshAll()` rather than kept as a
    /// standing cache: a single `refresh(_:)` after one click would have to
    /// decide whether an existing field were still valid, and a stale
    /// land-value field would paint the map with values that no longer match
    /// what the simulation would compute. One tile's worth of scanning is
    /// cheap; being wrong is not.
    private var overlayDistances: ZoneDistanceField?

    /// `overlayDistances`' counterpart for the transit overlays, held for
    /// exactly as long and absent for the same reason.
    private var overlayTransitCoverage: TransitCoverage?

    /// Which view the tiles were last drawn for, so a change to it can clear
    /// their cache keys — see `IsoTileRenderer.overlayDisturbedNodes`.
    private var renderedOverlay: OverlayMode?

    /// Forgets what every tile is showing when the player changes view.
    ///
    /// Once per change rather than once per tile per tick, which is what lets
    /// the keys do their job in between — including keeping the buildings
    /// current under an overlay that keeps them.
    private func syncOverlayGeneration() {
        guard renderedOverlay != controller.overlayMode else { return }
        renderedOverlay = controller.overlayMode
        for node in tileNodes.values {
            tileRenderer.invalidateOverlayNodes(on: node)
        }
    }

    func refreshAll() {
        syncOverlayGeneration()
        syncPathVehicles()
        syncWeather()
        // **Every overlay that reads distances, not just land value.** This
        // said `== .landValue` when land value was the only one, and by the
        // time Crime, Fire Risk and Problems arrived it was quietly making
        // each of them rebuild a whole-map distance field *per tile* — the
        // `O(tiles²)` cost `ZoneDistanceField` exists to delete, paid on the
        // render thread. Cheaper to compute one field for any overlay than to
        // keep a list of which ones happen to need it.
        if controller.overlayMode != .none {
            overlayDistances = ZoneDistanceField.compute(for: map)
        }
        if controller.overlayMode == .bus || controller.overlayMode == .subway {
            overlayTransitCoverage = Transit.coverage(for: map)
        }
        defer {
            overlayDistances = nil
            overlayTransitCoverage = nil
        }
        syncTransitDiagram()
        for position in tileNodes.keys {
            refresh(position)
        }
    }

    /// Draws the route diagram when one of its overlays is up, and takes it
    /// down otherwise.
    ///
    /// Rebuilt wholesale rather than cached on a key, unlike every per-tile
    /// decoration: there are a handful of routes against thousands of tiles,
    /// so the churn this would be protecting against does not exist — and the
    /// thing that decides the diagram's appearance is the whole network, which
    /// is not a cheap key to compare.
    func refreshTransitDiagram() {
        syncTransitDiagram()
    }

    private func syncTransitDiagram() {
        transitDiagramNode.removeAllChildren()
        // The sprites just went; the list that drives them has to go with
        // them, or it holds references to nodes no longer in the scene.
        diagramVehicles.removeAll()
        // **`routeMode`, not a second switch.** This was a `case .bus` /
        // `case .subway` with a `default: return`, written when those were
        // the only two lines — so tram and rail routes were never drawn in
        // their own views at all. Nothing failed: every test asks
        // `IsoTileRenderer.transitDiagram` directly, and the renderer was
        // always right; it was the scene's dispatch that had gone stale.
        //
        // `OverlayMode` already answers "which line is this view drawing",
        // and this was the fifth copy of that question — `view(for:)` was
        // introduced to kill four of them and missed this one.
        guard let mode = controller.overlayMode.routeMode else { return }
        guard let diagram = tileRenderer.transitDiagram(
            for: mode, in: map, drawing: controller.routeDraft
        ) else { return }
        transitDiagramNode.addChild(diagram)
        runVehicles(for: mode)
    }

    /// **Something actually running the line.**
    ///
    /// The transit module has four modes, routes, ridership and capacity, and
    /// until now *nothing ever moved along a line* — the lines were a
    /// diagram, and the only evidence a route carried anyone was a number in
    /// a panel. A vehicle travelling it is the one piece of feedback that
    /// says the thing you drew is working.
    ///
    /// **Only in the route's own view**, and that is honest rather than
    /// timid: a route here is schematic, a straight run between stations
    /// rather than a path along streets (see `TransitRoute`). A bus cutting
    /// diagonally across blocks would be a lie in Normal view; over the
    /// diagram it is exactly what the diagram means.
    private func runVehicles(for mode: TransitRoute.Mode) {
        for route in map.transit.routes(mode: mode) {
            let stops = Transit.workingStops(of: route, in: map)
            guard stops.count >= 2 else { continue }

            let points = stops.map {
                projection.centerPoint(ofFootprintOrigin: $0, size: map[$0].zone.footprintSize)
            }
            let path = CGMutablePath()
            path.addLines(between: points)
            let back = CGMutablePath()
            back.addLines(between: points.reversed())

            // Paced off the mode's own `minutesPerTile`, so a subway visibly
            // outruns a bus over the same stations — the same constant the
            // router weighs the journey with, rather than a second number
            // that could disagree with it.
            let tiles = zip(stops, stops.dropFirst()).reduce(0.0) { total, pair in
                total + Double(abs(pair.1.x - pair.0.x) + abs(pair.1.y - pair.0.y))
            }
            let duration = max(2.0, tiles * mode.minutesPerTile * 0.55)

            // A trace of light, like everything else that moves. And
            // **oriented to the path**, which a box could not be: the boxes
            // came in one texture per axis, so a route running at any other
            // angle had a vehicle pointing the wrong way along it. A streak
            // has no faces to get wrong.
            let vehicle = streakSprite(for: .transit(mode),
                                       length: projection.tileWidth * 0.95, alpha: 0.75)
            vehicle.name = Self.transitVehicleNodeName
            vehicle.zPosition = 1_200
            // **Parked at the first stop before the action runs.** `follow`
            // only moves the node once it ticks, so without this a vehicle
            // spends its first frame at the scene's origin — which is off the
            // map entirely, and showed up in the render as a streak floating
            // above the city. Brief in play, and wrong every time a route is
            // drawn or the view is switched.
            vehicle.position = points[0]
            transitDiagramNode.addChild(vehicle)
            diagramVehicles.append(DiagramVehicle(sprite: vehicle, points: points,
                                                  duration: duration))
        }
    }

    // MARK: - The last two animations driven per frame

    /// A vehicle running a route diagram.
    ///
    /// It was `SKAction.follow` there and back, which is the right tool right
    /// up until something outside SpriteKit needs to advance it — a
    /// recording, a benchmark, a test asking whether anything moved. The whole
    /// motion is a fraction along a polyline, so it is arithmetic wearing an
    /// action's clothes.
    private struct DiagramVehicle {
        let sprite: SKSpriteNode
        let points: [CGPoint]
        /// Cumulative length at each point, so the walk is a search rather
        /// than a re-measure of the whole line every frame.
        let lengths: [CGFloat]
        /// Seconds for one pass. A line is a there-and-back service rather
        /// than a loop, so a full cycle is twice this.
        let duration: TimeInterval

        init(sprite: SKSpriteNode, points: [CGPoint], duration: TimeInterval) {
            self.sprite = sprite
            self.points = points
            self.duration = duration
            var running: CGFloat = 0
            var lengths: [CGFloat] = [0]
            for (a, b) in zip(points, points.dropFirst()) {
                running += hypot(b.x - a.x, b.y - a.y)
                lengths.append(running)
            }
            self.lengths = lengths
        }
    }

    /// An aircraft on its take-off run.
    ///
    /// **Invisible except while moving**, which is the whole basis for drawing
    /// it at all: parked at the threshold it is a grey lump on the apron, and
    /// that is exactly why the static aircraft was cut from
    /// `ServiceMassing.airport`.
    private struct Aircraft {
        let sprite: SKSpriteNode
        let start: CGPoint
        let end: CGPoint
        /// Where in the cycle this one is, so two airports do not launch in
        /// lockstep. Seeded from the lot, like everything else here.
        let phase: TimeInterval
    }

    private var diagramVehicles: [DiagramVehicle] = []
    private var aircraft: [GridPosition: Aircraft] = [:]

    /// Seconds an aircraft waits at the threshold, then rolls.
    private static let aircraftWait: TimeInterval = 2.5
    private static let aircraftRoll: TimeInterval = 2.2

    /// Where a fraction along a polyline lands, and which way it is heading.
    private static func walk(_ points: [CGPoint], _ lengths: [CGFloat],
                             fraction: CGFloat) -> (point: CGPoint, angle: CGFloat) {
        guard points.count > 1, let total = lengths.last, total > 0 else {
            return (points.first ?? .zero, 0)
        }
        let target = min(max(fraction, 0), 1) * total
        var index = 1
        while index < lengths.count - 1, lengths[index] < target { index += 1 }
        let a = points[index - 1], b = points[index]
        let span = lengths[index] - lengths[index - 1]
        let f = span > 0 ? (target - lengths[index - 1]) / span : 0
        return (CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f),
                atan2(b.y - a.y, b.x - a.x))
    }

    private func advanceDiagramVehicles(by delta: TimeInterval) {
        guard !diagramVehicles.isEmpty else { return }
        diagramClock += delta
        for vehicle in diagramVehicles {
            let cycle = vehicle.duration * 2
            let t = diagramClock.truncatingRemainder(dividingBy: cycle)
            // Out, then back the other way rather than snapping to the start:
            // a line is a there-and-back service, not a loop.
            let outbound = t < vehicle.duration
            let f = outbound
                ? CGFloat(t / vehicle.duration)
                : CGFloat(1 - (t - vehicle.duration) / vehicle.duration)
            let (point, angle) = Self.walk(vehicle.points, vehicle.lengths, fraction: f)
            vehicle.sprite.position = point
            // Facing the way it is travelling, which is what `orientToPath`
            // was doing — and on the way back that is the other way round.
            vehicle.sprite.zRotation = outbound ? angle : angle + .pi
        }
    }

    private func advanceAircraft(by delta: TimeInterval) {
        guard !aircraft.isEmpty else { return }
        aircraftClock += delta
        let wait = Self.aircraftWait, roll = Self.aircraftRoll
        for craft in aircraft.values {
            let t = (aircraftClock + craft.phase).truncatingRemainder(dividingBy: wait + roll)
            guard t >= wait else {
                craft.sprite.position = craft.start
                craft.sprite.alpha = 0
                continue
            }
            let elapsed = t - wait
            let f = CGFloat(elapsed / roll)
            craft.sprite.position = CGPoint(
                x: craft.start.x + (craft.end.x - craft.start.x) * f,
                y: craft.start.y + (craft.end.y - craft.start.y) * f)
            // Fades up as it accelerates away and out as it goes, so the
            // reset to the threshold happens behind a beat of invisibility
            // rather than as a visible snap back down the runway.
            craft.sprite.alpha = elapsed < 0.3 ? CGFloat(elapsed / 0.3)
                : elapsed < 1.7 ? 1
                : max(0, CGFloat(1 - (elapsed - 1.7) / 0.5))
        }
    }

    /// Picks up the aircraft `IsoTileRenderer` just built, with the runway
    /// ends it recorded on the sprite.
    private func syncAircraftAnimation(at position: GridPosition) {
        guard let node = tileNodes[position],
              let sprite = node.childNode(withName: IsoTileRenderer.aircraftNodeName)
                as? SKSpriteNode,
              let data = sprite.userData,
              let x0 = data["x0"] as? CGFloat, let y0 = data["y0"] as? CGFloat,
              let x1 = data["x1"] as? CGFloat, let y1 = data["y1"] as? CGFloat
        else {
            aircraft[position] = nil
            return
        }
        var random = BuildingRandom(seed: position, salt: 733)
        aircraft[position] = Aircraft(sprite: sprite,
                                      start: CGPoint(x: x0, y: y0),
                                      end: CGPoint(x: x1, y: y1),
                                      phase: random.value(in: 0 ... (Self.aircraftWait
                                                                     + Self.aircraftRoll)))
    }

    /// How many vehicles are being driven per frame, for the tests about
    /// whether any of this moves.
    var drivenAnimationCountForTesting: (cars: Int, diagram: Int, aircraft: Int) {
        (trafficCarCountForTesting, diagramVehicles.count, aircraft.count)
    }

    // MARK: - Weather

    private var rainNode: SKEmitterNode?
    private var wetnessDrawn: CGFloat = -1

    /// Rain, and the wet street it leaves behind.
    ///
    /// Both come off `Weather`, which is a pure function of the day the city
    /// is on — so a filmstrip taken on day 200 is wet every run, and the
    /// forecast is something a player can read rather than noise that
    /// re-rolls under them.
    ///
    /// The two are deliberately separate. Rain is particles in front of the
    /// camera and costs one node; wetness is a texture-key on every lot, so
    /// it changes far less often — `Weather.wetness` is quantised into steps
    /// precisely so this does not rebuild the city every tick.
    private func syncWeather() {
        let day = map.elapsedDays
        let rainfall = CGFloat(Weather.rainfall(onDay: day))
        let wet = CGFloat(Weather.wetness(onDay: day))

        if wet != wetnessDrawn {
            wetnessDrawn = wet
            tileRenderer.wetness = wet
            // Every tile's reflection key just changed meaning, and the ones
            // that reflect are *ground* tiles whose own data did not move —
            // so nothing else would rebuild them. Same shape as an overlay
            // having to invalidate the keys of what it hides.
            for node in tileNodes.values {
                tileRenderer.invalidateDecoration(IsoTileRenderer.reflectionNodeName, on: node)
            }
        }

        // **Sized in points, not world units.** A child of the camera is
        // drawn at its local coordinate *in screen points* — the camera's own
        // scale cancels out — so multiplying by the zoom spread the rain over
        // an area several times the screen and the first render came back with
        // about four visible drops. The view is simply the scene's size.
        let view = size
        guard rainfall > 0, VisualStyle.current.wetReflection > 0 else {
            rainNode?.removeFromParent()
            rainNode = nil
            return
        }
        if rainNode == nil {
            let node = Emitters.rain(size: view, intensity: rainfall)
            node.name = Self.rainNodeName
            // Above the city and below nothing: rain falls in front of
            // everything, which is the one thing on screen that is allowed to.
            node.zPosition = 5_000
            node.targetNode = cameraNode
            cameraNode.addChild(node)
            // Now that it has a parent and a target, roll it forward so a
            // shower is already falling rather than filling the screen from
            // the top over the next second and a half.
            node.advanceSimulationTime(2.0)
            rainNode = node
        }
        rainNode?.particleBirthRate = 1_600 * rainfall
        rainNode?.particleAlpha = 0.5 * rainfall
        rainNode?.position = CGPoint(x: 0, y: view.height * 0.75)
        rainNode?.particlePositionRange = CGVector(dx: view.width * 1.4, dy: 0)
        rainNode?.particleSpeed = view.height * 1.5
    }

    /// What the wet ground at `position` throws back.
    ///
    /// **A reflection belongs to the ground it lands on, not to the building
    /// that casts it**, and getting that backwards is why the first version
    /// was invisible. Hung off the building's own tile node, a reflection
    /// falls on ground that building is already standing on, and anything
    /// reaching past its lot is painted over by the tile in front — which is
    /// drawn later and opaque. The render showed reflections *only* where
    /// they happened to hang over the edge of the map into open ground.
    ///
    /// So the ground asks the question instead. It looks up-screen — the two
    /// neighbours at `(x-1, y)` and `(x, y-1)`, which are the tiles nearer the
    /// back of the picture — and reports whatever building stands there. That
    /// puts the mark on the road in front of a tower, which is exactly where
    /// you would see it, and it is drawn with that road rather than behind it.
    ///
    /// Only bare ground reflects. A tile with its own building on it has no
    /// visible floor to catch anything, and water is already doing something
    /// far better of its own (`WaterShader`).
    private func reflection(at position: GridPosition) -> IsoTileRenderer.Reflected? {
        guard VisualStyle.current.wetReflection > 0, wetnessDrawn > 0 else { return nil }
        let here = map[position]
        guard !here.isWater, here.zone == .road || here.zone == .highway || here.zone == .empty
        else { return nil }

        for behind in [GridPosition(x: position.x - 1, y: position.y),
                       GridPosition(x: position.x, y: position.y - 1)] {
            guard map.contains(behind) else { continue }
            let anchor = map[behind].buildingOrigin
            let building = map[anchor]
            // A zone with no building on it reflects nothing — bare road, and
            // a zoned lot that has not grown yet.
            guard building.zone != .empty, building.zone != .road, building.zone != .highway,
                  building.zone.maxDensity == 0 || building.density > 0
            else { continue }
            return .init(zone: building.zone, density: building.density, seed: anchor)
        }
        return nil
    }

    private static let rainNodeName = "rain"

    /// Rain stops when the city does — it is on the simulation's clock, and a
    /// downpour over a stopped map is the "cars kept driving" bug in weather.
    var rainIsFallingForTesting: Bool { rainNode != nil }
    var wetnessForTesting: CGFloat { wetnessDrawn }

    // MARK: - Things that travel a path across the map

    /// Something that travels a path of tiles, and where it has got to.
    ///
    /// One mechanism for both the tram on its rails and the ship in its
    /// channel, because they are the same problem: a vehicle whose route is
    /// *real ground* rather than a schematic between stations, so it has to
    /// be sorted against the city it moves through.
    ///
    /// **Driven per frame rather than by an `SKAction`**, which buys two
    /// things the diagram's vehicles do without. Depth: a tram crosses tiles,
    /// so its painter's-algorithm key changes as it goes, and a node running
    /// an action would need its `zPosition` rewritten every frame anyway —
    /// at which point the action is only supplying the position. And pause:
    /// this advances after `update`'s own `isRunning` guard, so a stopped
    /// city stops its trams for free, with none of the `animatedBySimulation`
    /// bookkeeping an `SKAction` needs to avoid the "cars kept driving around
    /// a paused map" bug.
    private struct PathVehicle {
        let holder: SKNode
        /// A box drawn along each axis, or one streak rotated to the heading.
        ///
        /// **A streak can point anywhere; a box cannot.** The projected boxes
        /// come in two flavours because they are little volumes with faces,
        /// so a turn swaps textures rather than rotating. A trace of light has
        /// no faces to get wrong, which is the other quiet advantage of
        /// drawing vehicles as light.
        let alongX: SKNode
        let alongY: SKNode
        let streak: SKSpriteNode?
        /// The track, in order.
        let tiles: [GridPosition]
        /// Tiles per second.
        let speed: CGFloat
        /// How far along `tiles`, in index units.
        var travelled: CGFloat
        /// A line is a there-and-back service, not a loop.
        var outbound: Bool
        /// **An engine does not shuttle.** It runs to the fire and the next
        /// one leaves the station — a vehicle sliding back to its depot in
        /// reverse would be saying something untrue about what it is doing.
        let oneWay: Bool
    }

    private var pathVehicles: [PathVehicle] = []
    private var pathVehiclesKey: String?

    /// Rebuild the trams when the lines or the track have changed, and not
    /// otherwise.
    ///
    /// Called from `refreshAll`, so it is checked once a tick rather than
    /// once a frame — and the key is cheap on purpose, because the work it
    /// guards is a breadth-first search per segment of every tram line.
    /// `map.tramTracks` is already cached on `CityMap` for
    /// `Traffic.congestion`, so its count costs nothing and catches a street
    /// being cut or laid under an existing line.
    private func syncPathVehicles() {
        let routes = map.transit.routes(mode: .tram)
        let lane = ShippingLane.path(in: map)
        // **The fires have to be in the key.** They are the one thing here
        // that changes on its own: a tram line is drawn once and a shipping
        // lane lasts as long as the dock, but a block catches alight and goes
        // out on the simulation's own clock. Keyed without them, an engine
        // would only ever appear if the player happened to redraw a tram
        // route at the same moment something was burning.
        let fires = map.tiles.filter { $0.isBuildingAnchor && $0.isBurning }
            .map { "\($0.position.x),\($0.position.y)" }.sorted().joined(separator: ";")
        let key = routes.map { $0.stops.map { "\($0.x),\($0.y)" }.joined(separator: ";") }
            .joined(separator: "|")
            + "#\(map.tramTracks.count)"
            + "~\(lane.count)/\(lane.first.map { "\($0.x),\($0.y)" } ?? "-")"
            + "!\(fires)"
        guard key != pathVehiclesKey else { return }
        pathVehiclesKey = key

        for run in pathVehicles { run.holder.removeFromParent() }
        pathVehicles = []

        add(.transit(.tram), along: routes.map { Transit.tramPath(of: $0, in: map) },
            tilesPerSecond: 1 / CGFloat(TransitRoute.Mode.tram.minutesPerTile * 0.55))
        // A ship is slow. Speed is most of what tells a hull from a tram at a
        // glance once both are small on screen.
        add(.ship, along: [lane], tilesPerSecond: 0.55)

        // **Engines that actually go to the fire**, rather than traffic that
        // happens to be red near one. Fast, because the one thing everybody
        // knows about a fire engine is that it is in a hurry, and speed is
        // legible at this size where a shape is not.
        add(.fire, along: EmergencyResponse.fireRoutes(in: map),
            tilesPerSecond: 2.6, oneWay: true)
    }

    private func add(_ vehicle: IsoTextureCache.Vehicle,
                     along paths: [[GridPosition]], tilesPerSecond: CGFloat,
                     oneWay: Bool = false) {
        for tiles in paths {
            // Two tiles is the shortest thing that has a direction. A severed
            // line returns nothing, and drawing a tram gliding across the gap
            // would claim a connection the simulation does not have.
            guard tiles.count >= 2 else { continue }

            let holder = SKNode()
            // Road vehicles are traces of light now, so anything that runs on
            // streets is drawn that way too — a fire engine as a little box
            // among streaks would be the one thing on the road still trying
            // to be a shape.
            // **Everything that runs on a street is light now** — the tram
            // included. A tram drawn as a little box among traces would be the
            // one vehicle on the road still trying to be a shape, and it is
            // the mode whose whole point is that it shares the street.
            //
            // The ship keeps its hull: it is the largest moving thing in the
            // game and a streak would throw away the silhouette that makes a
            // seaport read as trading at all.
            let isLight = vehicle == .fire || vehicle == .transit(.tram)
            let streak: SKSpriteNode? = isLight
                ? streakSprite(for: vehicle,
                               length: projection.tileWidth * (vehicle == .fire ? 0.75 : 0.95),
                               alpha: vehicle == .fire ? 0.85 : 0.7)
                : nil
            let alongX = streak ?? tileRenderer.carSprite(vehicle, alongX: true)
            let alongY = streak == nil ? tileRenderer.carSprite(vehicle, alongX: false) : SKNode()
            if streak == nil { alongY.isHidden = true }
            holder.addChild(alongX)
            if streak == nil { holder.addChild(alongY) }
            // Into `tileLayer` rather than the diagram node: `zPosition` is
            // only comparable against the tiles when it shares their parent,
            // and being sorted against the city is the whole point of a
            // vehicle that runs on the map instead of over a schematic.
            tileLayer.addChild(holder)

            pathVehicles.append(PathVehicle(
                holder: holder, alongX: alongX, alongY: alongY, streak: streak,
                tiles: tiles, speed: tilesPerSecond, travelled: 0,
                outbound: true, oneWay: oneWay
            ))
        }
    }

    private func advancePathVehicles(by delta: TimeInterval) {
        guard !pathVehicles.isEmpty, delta > 0 else { return }
        for index in pathVehicles.indices {
            var run = pathVehicles[index]
            let last = CGFloat(run.tiles.count - 1)

            run.travelled += run.speed * CGFloat(delta) * (run.outbound ? 1 : -1)
            if run.travelled >= last {
                // One-way runs restart from the depot rather than reversing.
                if run.oneWay { run.travelled = 0 } else { run.travelled = last; run.outbound = false }
            }
            if run.travelled <= 0 { run.travelled = 0; run.outbound = true }

            let step = min(Int(run.travelled), run.tiles.count - 2)
            let fraction = run.travelled - CGFloat(step)
            let from = run.tiles[step], to = run.tiles[step + 1]
            let x = CGFloat(from.x) + CGFloat(to.x - from.x) * fraction
            let y = CGFloat(from.y) + CGFloat(to.y - from.y) * fraction

            run.holder.position = projection.project(x + 0.5, y + 0.5, 0)
            // Half a step above the tile it is over, so it draws on top of
            // the street and still behind whatever stands on the next one.
            run.holder.zPosition = x + y + 0.5
            // Which way the track runs decides which of the two vehicle
            // textures shows, the same pair the traffic uses — a tram turning
            // a corner swaps rather than rotating, because these are little
            // projected boxes and not sprites with a free angle.
            if let streak = run.streak {
                // A trace points wherever it is going; no texture to swap.
                streak.zRotation = atan2(
                    projection.project(CGFloat(to.x), CGFloat(to.y), 0).y
                        - projection.project(CGFloat(from.x), CGFloat(from.y), 0).y,
                    projection.project(CGFloat(to.x), CGFloat(to.y), 0).x
                        - projection.project(CGFloat(from.x), CGFloat(from.y), 0).x
                )
            } else {
                let alongXNow = to.x != from.x
                run.alongX.isHidden = !alongXNow
                run.alongY.isHidden = alongXNow
            }

            pathVehicles[index] = run
        }
    }

    private static let transitVehicleNodeName = "transitVehicle"

    // MARK: - Traffic animation

    private static let trafficCarNodeName = "trafficCar"

    /// A horizontal gradient, transparent at its left edge fading to
    /// near-opaque at its right — the raw material for each car's speed
    /// trail below. Same "cache one shared gradient texture, tint and
    /// additively blend it per use" technique `NeonStyle.glowTexture`
    /// and `GameScene`'s own sun glow use, just linear instead of radial:
    /// a streak of light has a direction, a glow doesn't.
    private static let speedTrailTexture: SKTexture = {
        let width = 128
        let height = 16
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return SKTexture() }

        let components: [CGFloat] = [1, 1, 1, 0, 1, 1, 1, 0.9]
        guard let gradient = CGGradient(colorSpace: colorSpace, colorComponents: components, locations: [0, 1], count: 2) else {
            return SKTexture()
        }
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height) / 2), end: CGPoint(x: CGFloat(width), y: CGFloat(height) / 2), options: [])

        guard let image = context.makeImage() else { return SKTexture() }
        return SKTexture(cgImage: image)
    }()

    /// A retrowave light-trail streaking behind a car, opposite its
    /// direction of travel — a synthwave highway shot is defined by long
    /// motion-blurred light trails, not sharply-frozen cars, and a car
    /// that's just sliding across a tile doesn't read as "fast" without
    /// one. Length and brightness both scale with how free-flowing the
    /// traffic actually is (`speedFactor`, `1 - congestion`): free-flowing
    /// traffic streaks long and bright, jammed traffic barely trails at
    /// all — reusing the exact signal `crossingDuration` already encodes,
    /// so the streak reinforces "this road is fast/slow" rather than
    /// adding a second, uncoordinated one. Tinted the same
    /// `RenderPalette.networkAccentColor` the road's own lane line and
    /// glow already use, so a trail reads as light spilling from the same
    /// source as the street it's on, not a color competing with it.
    /// Parented to `car` itself (not animated separately) so it rides
    /// along for free with whatever `SKAction` is already moving the car.
    private func makeSpeedTrail(zone: ZoneType, travelAngle: CGFloat, carLength: CGFloat, carThickness: CGFloat, speedFactor: CGFloat) -> SKSpriteNode {
        let trail = SKSpriteNode(texture: Self.speedTrailTexture)
        let trailLength = projection.tileWidth * (0.3 + speedFactor * 1.4)
        trail.size = CGSize(width: trailLength, height: carThickness * 0.7)
        trail.color = RenderPalette.networkAccentColor(for: zone)
        trail.colorBlendFactor = 1
        trail.blendMode = .add
        trail.alpha = 0.4 + speedFactor * 0.5
        trail.zRotation = travelAngle
        let offset = carLength / 2 + trailLength / 2
        trail.position = CGPoint(x: -cos(travelAngle) * offset, y: -sin(travelAngle) * offset)
        return trail
    }

    /// Ambient "cars" driving back and forth across a road tile — purely
    /// decorative, visualizing `Traffic.congestion(at:in:)` (more, slower
    /// cars as a road gets busier) without needing "Show Traffic" turned
    /// on. Cleared during either overlay, same as pips/icons, and for
    /// anything that isn't a road. Each car also gets a `makeSpeedTrail`
    /// light streak behind it — the retrowave-highway-shot look, and a
    /// second read of the exact same congestion signal (long bright
    /// streak = free-flowing, short dim one = jammed) rather than a purely
    /// decorative addition.
    ///
    /// Still one tile's worth of loop, not a car actually driving the
    /// full route `Traffic.computeLoad` routed it over — a real
    /// per-vehicle journey across tiles is exactly the individual-agent
    /// rendering complexity this project's aggregate simulation doesn't
    /// need to earn its keep. What *is* real: which way, along the
    /// tile's own axis, the car actually travels — `TrafficLoad.netHeadingIsPositive`
    /// reads the same routed paths `computeLoad` already found, so a car
    /// here points toward wherever most of that tile's real commute
    /// traffic is actually headed, not an arbitrary fixed screen direction.
    ///
    /// Only rebuilds the cars when `Traffic.carCount(forCongestion:)`
    /// actually changes, not on every call — `refresh(_:)` runs after
    /// *every* simulation tick (`refreshAll()`), and restarting each car's
    /// `SKAction` from scratch every second (even with the same count)
    /// would make them visibly snap back to their start position instead
    /// of driving smoothly. A small known gap from this: a road's car count
    /// only actually updates when *that road* gets refreshed, so a road
    /// whose congestion changed because a neighboring building was
    /// bulldozed (not the road itself) won't catch up until the next
    /// simulation tick's `refreshAll()` — a one-tick lag, not incorrect data.
    /// Does this road run alongside industry? What decides whether its
    /// traffic is lorries or cars.
    private func servesIndustry(at position: GridPosition) -> Bool {
        position.orthogonalNeighbors().contains {
            map.contains($0) && map[$0].zone == .industrial
        }
    }

    /// What is driving down this particular street.
    ///
    /// **Where a vehicle's colour comes from.** Ordinary traffic is the
    /// quietest thing on the road on purpose — it is also most of it, and a
    /// street of individually interesting cars is a street nobody can read.
    /// The exceptions are the ones that mean something:
    ///
    /// - **Freight** where the road runs past industry, which is the rule the
    ///   lorry silhouette was added for and never managed to convey at this
    ///   size.
    /// - **A fire engine** where something nearby is alight. This is the one
    ///   that stops being decoration: red streaks converging on a burning
    ///   block tell you where the emergency is from across the map, which no
    ///   amount of shape ever could.
    /// - **A patrol car** where a police station covers the street, so the
    ///   service you paid for is visible doing something.
    /// One trace of light, for anything that moves on a street or a line.
    ///
    /// Shared by the three things that used to draw their own little box: road
    /// traffic, the vehicles running a transit line over its diagram, and the
    /// path vehicles (trams on real rails, fire engines). Drawing them three
    /// different ways was how the traffic ended up saying one thing about
    /// congestion and the buses another.
    ///
    /// **Additive, held well below the ceiling.** Saturation is a function of
    /// alpha, not of additive — at this level a saturated hue tints the lane
    /// it crosses rather than bleaching it, which is what keeps a cyan car and
    /// a red engine visibly different colours. Alpha blending was tried first
    /// and produced pale bars painted on the road: a trace that cannot be
    /// brighter than what it lies on is paint, not light.
    private func streakSprite(for vehicle: IsoTextureCache.Vehicle,
                              length: CGFloat, alpha: CGFloat) -> SKSpriteNode {
        let streak = SKSpriteNode(texture: Self.speedTrailTexture)
        // Thin: a trace is mostly length, and thickness is what makes one look
        // like an object instead.
        streak.size = CGSize(width: length, height: max(2.5, projection.tileWidth * 0.06))
        streak.color = RenderPalette.vehicleColor(for: vehicle)
        streak.colorBlendFactor = 1
        streak.blendMode = .add
        streak.alpha = alpha
        return streak
    }

    private func vehicleKind(at position: GridPosition,
                             random: inout BuildingRandom) -> IsoTextureCache.Vehicle {
        if Fire.count(in: map) > 0, isNear(position, { self.map[$0].isBurning }, within: 6),
           random.chance(0.6) {
            return .fire
        }
        if isNear(position, { self.map[$0].zone == .policeStation }, within: 5),
           random.chance(0.35) {
            return .police
        }
        return random.chance(servesIndustry(at: position) ? 0.55 : 0.12) ? .lorry : .car
    }

    /// Is anything matching `test` within `radius` tiles?
    ///
    /// Square rather than a true radius, and deliberately small: this runs per
    /// car per rebuild, and the answer only decides a colour.
    private func isNear(_ position: GridPosition,
                        _ test: (GridPosition) -> Bool, within radius: Int) -> Bool {
        for dy in -radius ... radius {
            for dx in -radius ... radius {
                let cell = GridPosition(x: position.x + dx, y: position.y + dy)
                if map.contains(cell), test(cell) { return true }
            }
        }
        return false
    }

    private func syncTrafficAnimation(at position: GridPosition) {
        guard let node = tileNodes[position] else { return }
        let existingCars = node.children.filter { $0.name == Self.trafficCarNodeName }

        let zone = map[position].zone
        // Cars are the traffic, so the Traffic view is the last place they
        // should be taken away — see `OverlayMode.showsRoadNetwork`.
        guard controller.overlayMode.showsRoadNetwork, zone == .road || zone == .highway else {
            existingCars.forEach { $0.removeFromParent() }
            trafficCars[position] = nil
            return
        }

        let congestion = Traffic.congestion(at: position, in: map)
        let carCount = Traffic.carCount(forCongestion: congestion)
        // The node count is the cache key, and the driven list has to agree
        // with it: a tile whose sprites survive keeps the entry that moves
        // them, and one that rebuilds replaces both together.
        guard existingCars.count != carCount || trafficCars[position] == nil else { return }
        existingCars.forEach { $0.removeFromParent() }
        trafficCars[position] = nil
        guard carCount > 0 else { return }
        var driven: [TrafficCar] = []

        let horizontal = Traffic.isHorizontallyOriented(at: position, in: map)
        // Which way most *actual* routed traffic crosses this tile, not
        // an arbitrary fixed screen direction — a car here should look
        // like it's headed toward the job it's actually commuting to.
        let flowsPositive = map.trafficLoad.netHeadingIsPositive(at: position, horizontal: horizontal)
        // Busier roads get slower-crossing cars too, not just more of them —
        // reads as "jammed," not just "popular."
        let crossingDuration = 1.2 + congestion * 1.8
        // **Lanes are in tile units and projected, not in screen axes.** A
        // road running east-west is a horizontal line on a top-down map and a
        // down-right diagonal in isometric, so laying cars out along screen x
        // or y — which is what this did — would drive them off the road at
        // forty-five degrees. Everything below is expressed in the lot's own
        // coordinates and passed through the projection, which is also why the
        // car's rotation now comes from the projected direction rather than a
        // fixed angle per axis.
        let laneOffset: CGFloat = 0.16
        // Real two-way roads never carry traffic down the center line —
        // every car this tile renders shares the same net flow direction
        // (`flowsPositive`), so they all belong in the one lane that
        // direction actually drives in, offset to one side or the other
        // depending which way that is (an arbitrary but consistent side,
        // there's no real left/right-hand-traffic convention modeled here).
        // Multiple simultaneous cars stay visually distinct via the
        // temporal stagger below — each at a different point along that
        // same lane — rather than being spread across invented parallel
        // lanes a single-lane-each-way road doesn't actually have. This
        // used to include a third, centered offset (0) that every tile
        // with exactly one car — the common case at low congestion — sat
        // on by default, reading as straddling the center line rather
        // than driving in a lane.
        let lane = 0.5 + (flowsPositive ? laneOffset : -laneOffset)
        let entry = horizontal ? projection.project(0, lane, 0) : projection.project(lane, 0, 0)
        let exit = horizontal ? projection.project(1, lane, 0) : projection.project(lane, 1, 0)
        // How free-flowing this tile's traffic actually is, 1 (empty
        // road) down to 0 (gridlocked) — the same signal `crossingDuration`
        // above already reads off `congestion`, reused here so the speed
        // trail agrees with how fast the car it's attached to actually
        // looks like it's crossing the tile.
        let speedFactor = CGFloat(1 - congestion)
        let lowEnd = entry, highEnd = exit
        let heading = flowsPositive
            ? CGPoint(x: highEnd.x - lowEnd.x, y: highEnd.y - lowEnd.y)
            : CGPoint(x: lowEnd.x - highEnd.x, y: lowEnd.y - highEnd.y)
        let travelAngle = atan2(heading.y, heading.x)

        for index in 0 ..< carCount {
            // One shape, rotated to the projected heading — there is no
            // "horizontal car" and "vertical car" in isometric, only a car
            // pointing down one of two diagonals.
            let carSize = CGSize(width: max(6, projection.tileWidth * 0.26),
                                 height: max(4, projection.tileWidth * 0.16))
            // **What is on this street depends on what is beside it.** A road
            // running past a factory carries lorries; one through a
            // neighbourhood does not. Seeded from the tile so a street keeps
            // its own mix rather than reshuffling on every refresh, and mixed
            // with the car's index so three vehicles on one tile are not
            // three of the same thing.
            var random = BuildingRandom(seed: position, salt: 400 + index)
            let vehicle = vehicleKind(at: position, random: &random)
            // **A trace of light, not a little box.**
            //
            // Two real defects were fixed in the boxes — they bloomed into
            // identical white lozenges, and every tile staggered its cars the
            // same way so a street read as a dotted line — and they still
            // looked wrong afterwards, because a box is the wrong object. A
            // vehicle is about eleven screen points across at the zoom this
            // is played at, and a form that small cannot show its form. That
            // is exactly the case `NeonStyle.minimumDetailSize` says to cut
            // rather than shrink.
            //
            // A streak has no such problem: it is a direction and a colour,
            // and both survive any zoom. It is also this art direction's own
            // rule applied to the one thing that moves — *colour comes from
            // the light a thing throws, not from repainting it* — and it is
            // what finally makes the **kind** of vehicle legible, because hue
            // reads at a size silhouette never could.
            let car = streakSprite(
                for: vehicle,
                length: projection.tileWidth * (0.18 + speedFactor * 0.8),
                alpha: 0.3 + speedFactor * 0.35
            )
            car.zRotation = travelAngle
            car.name = Self.trafficCarNodeName
            car.zPosition = 2

            let start = flowsPositive ? lowEnd : highEnd
            let end = flowsPositive ? highEnd : lowEnd
            car.position = start
            let baseAlpha = car.alpha

            // A car can't actually drive its full routed commute across
            // every tile along the way — that's the individual-agent
            // rendering complexity this file's own doc comment above
            // already rules out — so it has to reset back to this tile's
            // own start point somewhere. The reset itself used to be an
            // instant, zero-duration teleport, which read exactly as a
            // visible stutter: a car (and its speed trail, since that's a
            // child of `car` and fades right along with it) would glide
            // smoothly across, then pop backward with no transition at
            // all. Fading out just before the teleport and back in right
            // after masks the jump behind a beat of invisibility instead
            // of showing it — the car glides away, and a fresh one glides
            // in, rather than one car visibly snapping in place.
            // Stagger each car's start so a multi-car tile doesn't drive in
            // lockstep — **and offset the whole tile by a seeded phase**, or
            // every tile staggers identically and the street comes out as an
            // evenly spaced dotted line marching in step. That is what the
            // three-zoom render showed: not traffic, a conveyor.
            //
            // Seeded from the position for the reason `BuildingRandom` always
            // is: a street keeps its own rhythm across refreshes and launches
            // rather than reshuffling every time a tile is rebuilt.
            var phaseRandom = BuildingRandom(seed: position, salt: 911)
            let tilePhase = CGFloat(phaseRandom.value(in: 0 ... 1))
            let stagger = crossingDuration
                * (Double(index) + Double(tilePhase)) / Double(carCount)

            node.addChild(car)
            driven.append(TrafficCar(sprite: car, start: start, end: end,
                                     crossing: crossingDuration,
                                     phase: stagger, baseAlpha: baseAlpha))
        }
        trafficCars[position] = driven
    }

    // MARK: - Ambient traffic, driven per frame

    /// One ambient car.
    ///
    /// **It used to be an `SKAction` loop and is now a handful of numbers**,
    /// for the three reasons `PathVehicle` already gives: SpriteKit runs
    /// actions on its own loop, so nothing that drives the scene from outside
    /// — a recording, a test, a benchmark — can advance them; a paused city
    /// then needs the separate `animatedBySimulation` walk to stop them; and
    /// the motion is a pure function of elapsed time anyway, so an action is
    /// storing a program to compute something arithmetic.
    ///
    /// The recorder is what forced it. Over a full second of a running city
    /// it measured **0.06% of the frame changing** — one tram — because every
    /// vehicle on every street was frozen in a headless capture. A tool for
    /// judging motion that cannot see the main thing that moves is not a tool.
    private struct TrafficCar {
        let sprite: SKSpriteNode
        let start: CGPoint
        let end: CGPoint
        /// Seconds to cross its tile.
        let crossing: TimeInterval
        /// Where in the cycle this car starts.
        let phase: TimeInterval
        /// What it should be drawn at while crossing.
        ///
        /// **This is a bug fix, not bookkeeping.** The action sequence ended
        /// in `SKAction.fadeIn`, which fades to *1.0* rather than back to
        /// whatever the node had — so every ambient car in the game jumped to
        /// full opacity after its first loop and stayed there. The streaks are
        /// deliberately drawn at 0.3–0.65, because this file records that a
        /// saturated hue at modest alpha tints the lane while the same hue at
        /// high alpha bleaches whatever it crosses. Traffic has been running
        /// at the bleaching end since the streaks landed.
        let baseAlpha: CGFloat
    }

    /// How long a car spends invisible while it returns to the start of its
    /// tile. A car cannot drive its whole routed commute — that is the
    /// individual-agent rendering this project rules out — so it has to reset
    /// somewhere, and the reset used to be a visible backward pop. Fading out
    /// just before it and in just after hides the jump behind a beat of
    /// invisibility: one car glides away, a fresh one glides in.
    private static let carResetSeconds: TimeInterval = 0.2

    private var trafficCars: [GridPosition: [TrafficCar]] = [:]
    private var trafficClock: TimeInterval = 0
    private var diagramClock: TimeInterval = 0
    private var aircraftClock: TimeInterval = 0

    /// Moves every ambient car. Called from `update` on the running side of
    /// the pause guard, which is what makes a stopped city stop its traffic
    /// without anything having to walk the map looking for it.
    private func advanceTrafficCars(by delta: TimeInterval) {
        guard !trafficCars.isEmpty else { return }
        trafficClock += delta
        let fade = Self.carResetSeconds
        for (position, cars) in trafficCars {
            // Tiles outside the view are detached by the culling, and moving a
            // sprite nobody can see is the one cost this design adds over an
            // action. One dictionary lookup skips a whole street of them.
            guard tileNodes[position]?.parent != nil else { continue }
            for car in cars {
                let cycle = car.crossing + fade * 2
                var t = (trafficClock + car.phase).truncatingRemainder(dividingBy: cycle)
                if t < 0 { t += cycle }
                if t < car.crossing {
                    let f = CGFloat(t / car.crossing)
                    car.sprite.position = CGPoint(
                        x: car.start.x + (car.end.x - car.start.x) * f,
                        y: car.start.y + (car.end.y - car.start.y) * f)
                    car.sprite.alpha = car.baseAlpha
                } else if t < car.crossing + fade {
                    car.sprite.position = car.end
                    car.sprite.alpha = car.baseAlpha * CGFloat(1 - (t - car.crossing) / fade)
                } else {
                    car.sprite.position = car.start
                    car.sprite.alpha = car.baseAlpha
                        * CGFloat((t - car.crossing - fade) / fade)
                }
            }
        }
    }

    /// How many ambient cars are being driven, for the tests about whether
    /// the streets carry anything.
    var trafficCarCountForTesting: Int { trafficCars.values.reduce(0) { $0 + $1.count } }
}
