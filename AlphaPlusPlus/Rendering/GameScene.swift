import SpriteKit
import AppKit

/// The SpriteKit scene that draws the city.
///
/// Key idea: the scene *owns no rules*. It reads a `CityMap` (data) through
/// the shared `GameController`, asks `TileRenderer` to turn each tile into a
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

    private let layout: GridLayout
    private let tileRenderer: TileRenderer

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

    /// A radial gradient, white fading to transparent, tinted by
    /// `sunGlowNode.color` — the same "cache one shared gradient texture,
    /// tint and additively blend it per use" technique
    /// `TileRenderer.glowTexture` uses for road/highway network glow,
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
    private var tileNodes: [GridPosition: SKSpriteNode] = [:]

    /// An `SKCameraNode` lets us pan and zoom by moving *one* node instead of
    /// repositioning thousands of tiles — see `scrollWheel(with:)` and
    /// `magnify(with:)` below, which are the trackpad gestures that move it.
    private let cameraNode = SKCameraNode()

    /// `didMove(to:)` can fire more than once (e.g. if the scene is presented
    /// again after a view change), and building the grid twice would stack
    /// duplicate sprites. This guard makes setup idempotent.
    private var hasBuiltScene = false

    // MARK: - Init

    init(controller: GameController, layout: GridLayout = GridLayout()) {
        self.controller = controller
        self.layout = layout
        self.tileRenderer = TileRenderer(layout: layout)

        // Note: `layout` here is the *parameter*, not `self.layout`. Swift
        // forbids touching `self` before `super.init`, and the parameter
        // shadows the property, so this is legal (and a very common
        // stumbling block when writing Swift initializers). `controller.map`
        // is fine to read already, since `self.controller` was just set.
        //
        // The starting size barely matters because `.resizeFill` below makes the
        // scene adopt the view's size, so one scene point == one screen point
        // and nothing gets stretched.
        super.init(size: layout.contentSize(of: controller.map))

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

        tileLayer.zPosition = 0
        retroEffectLayer.shader = RetroShader.make()
        retroEffectLayer.addChild(tileLayer)
        addChild(retroEffectLayer)
        RetroShader.updateAspect(retroEffectLayer.shader!, size: size)

        placementPreviewNode.name = "placementPreview"
        placementPreviewNode.isHidden = true
        placementPreviewNode.lineWidth = 2.5
        placementPreviewNode.zPosition = 5
        retroEffectLayer.addChild(placementPreviewNode)

        sunGlowNode.texture = Self.sunGlowTexture
        sunGlowNode.color = RenderPalette.sunGlow
        sunGlowNode.colorBlendFactor = 1
        sunGlowNode.blendMode = .add
        sunGlowNode.zPosition = -1
        retroEffectLayer.addChild(sunGlowNode)

        buildTileNodes()
        centerCameraOnMap()
        positionSunGlow()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        // Window resized: keep the map centered rather than pinned to a
        // corner. Known trade-off now that panning exists: resizing the
        // window recenters the camera and discards a manual pan. Leaving
        // that as-is for now rather than adding "did the player pan on
        // purpose?" tracking for a fairly minor annoyance.
        centerCameraOnMap()
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
    func zoom(byMagnification magnification: CGFloat) {
        let requestedScale = cameraNode.xScale * (1 - magnification)
        cameraNode.setScale(min(max(requestedScale, minimumZoomScale), maximumZoomScale))
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
    override func update(_ currentTime: TimeInterval) {
        super.update(currentTime)

        guard controller.isRunning else {
            // Paused: forget when we last ticked, so resuming waits a full
            // tick interval before the next step instead of ticking
            // immediately on whatever time happens to have passed while paused.
            lastTickTime = nil
            return
        }
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
    /// camera, so it lines up with what `GridLayout` expects.
    ///
    /// Left button paints the selected tool; `mouseDragged` fires
    /// continuously while the button stays down, so holding and moving
    /// paints a whole stroke of tiles instead of just the one under the
    /// initial click. Right button is a standing "quick bulldoze" shortcut,
    /// so clearing tiles never requires switching the toolbar away from
    /// whatever zone you're placing.
    override func mouseDown(with event: NSEvent) {
        lastPaintPosition = nil
        placementPreviewNode.isHidden = true
        place(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        place(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        lastBulldozePosition = nil
        placementPreviewNode.isHidden = true
        bulldoze(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        bulldoze(with: event)
    }

    private func place(with event: NSEvent) {
        guard let position = gridPosition(of: event) else { return }

        // The Water overlay doubles as the pipe-editing layer — whatever
        // zone tool happens to be selected on the toolbar is irrelevant
        // while looking at it. See `Tile.hasPipe`'s doc comment for why
        // pipes live here instead of as another toolbar button. The Power
        // overlay is the exact same idea for `Tile.hasPowerLine`.
        if controller.overlayMode == .water {
            for step in stroke(from: lastPaintPosition, to: position) {
                let outcome = controller.layPipe(at: step)
                refresh(step)
                if outcome == .insufficientFunds {
                    flashInsufficientFunds(at: step)
                    break // same tile-price-doesn't-change-mid-stroke reasoning as below
                }
            }
            lastPaintPosition = position
            return
        }
        if controller.overlayMode == .power {
            for step in stroke(from: lastPaintPosition, to: position) {
                let outcome = controller.layPowerLine(at: step)
                refresh(step)
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
                rebuildEntireGrid()
                lastPaintPosition = position
                return
            }
            for step in stroke(from: lastPaintPosition, to: position) {
                controller.bulldoze(at: step)
                refresh(step)
                refreshRoadNeighbors(of: step)
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
            rebuildEntireGrid()
            if outcome == .insufficientFunds { flashInsufficientFunds(at: position) }
            if outcome == .blocked { flashBlockedPlacement(at: position) }
            lastPaintPosition = position
            return
        }

        for step in stroke(from: lastPaintPosition, to: position) {
            let outcome = controller.place(at: step)
            refresh(step)
            refreshRoadNeighbors(of: step)
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

        if controller.overlayMode == .water {
            for step in stroke(from: lastBulldozePosition, to: position) {
                controller.removePipe(at: step)
                refresh(step)
            }
            lastBulldozePosition = position
            return
        }
        if controller.overlayMode == .power {
            for step in stroke(from: lastBulldozePosition, to: position) {
                controller.removePowerLine(at: step)
                refresh(step)
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
            rebuildEntireGrid()
            lastBulldozePosition = position
            return
        }

        for step in stroke(from: lastBulldozePosition, to: position) {
            controller.bulldoze(at: step)
            refresh(step)
            refreshRoadNeighbors(of: step)
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
        layout.position(for: event.location(in: self), in: map)
    }

    // MARK: - Placement preview

    /// Called by `GameSKView.mouseMoved`. Shows a footprint-sized outline
    /// at whatever grid cell the cursor is over — sized and positioned
    /// with the exact same `GridLayout` math a real placement uses
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
    /// (`GridLayout.centerPoint(ofFootprintOrigin:size:)`'s own doc
    /// comment), so a multi-tile building extends up and to the right
    /// from wherever you click, not centered on it and not extending some
    /// other direction — exactly what this outline now shows up front.
    func updatePlacementPreview(at event: NSEvent) {
        guard let position = gridPosition(of: event) else {
            placementPreviewNode.isHidden = true
            return
        }

        // Laying a pipe (or a power line) never conflicts with anything
        // already on the surface — there's no "blocked" state to warn
        // about the way a surface building has, so this is always a
        // plain 1×1 "clear" tile.
        if controller.overlayMode == .water || controller.overlayMode == .power {
            placementPreviewNode.fillColor = RenderPalette.placementPreviewClearFill
            placementPreviewNode.strokeColor = RenderPalette.placementPreviewClearStroke
            let size = layout.spriteSize(forFootprint: 1)
            placementPreviewNode.path = CGPath(rect: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height), transform: nil)
            placementPreviewNode.position = layout.centerPoint(ofFootprintOrigin: position, size: 1)
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

        let wouldReplaceSomething = footprint.contains { map[$0].zone != .empty }
        placementPreviewNode.fillColor = wouldReplaceSomething ? RenderPalette.placementPreviewBlockedFill : RenderPalette.placementPreviewClearFill
        placementPreviewNode.strokeColor = wouldReplaceSomething ? RenderPalette.placementPreviewBlockedStroke : RenderPalette.placementPreviewClearStroke

        let size = layout.spriteSize(forFootprint: footprintSize)
        placementPreviewNode.path = CGPath(rect: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height), transform: nil)
        placementPreviewNode.position = layout.centerPoint(ofFootprintOrigin: position, size: footprintSize)
        placementPreviewNode.isHidden = false
    }

    /// Cursor left the grid, or a click just started an active paint
    /// stroke (where tiles are already being placed live, so a "here's
    /// what *would* happen" preview would be redundant/confusing).
    func clearPlacementPreview() {
        placementPreviewNode.isHidden = true
    }

    /// Briefly flash a tile red to explain why a click did nothing: the
    /// treasury can't cover it. `SKAction.colorize` animates a sprite's
    /// `color` over time — the same property `TileRenderer` sets directly —
    /// so this just animates out to the zone flash color and back to
    /// whatever color the tile actually is, without touching any data.
    private func flashInsufficientFunds(at position: GridPosition) {
        guard let node = tileNodes[position] else { return }
        let restoreColor = currentColor(at: position)
        node.run(.sequence([
            .colorize(with: RenderPalette.insufficientFundsFlash, colorBlendFactor: 1, duration: 0.05),
            .colorize(with: restoreColor, colorBlendFactor: 1, duration: 0.2),
        ]), withKey: "insufficientFundsFlash")
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
        let restoreColor = currentColor(at: position)
        node.run(.sequence([
            .colorize(with: RenderPalette.blockedPlacementFlash, colorBlendFactor: 1, duration: 0.05),
            .colorize(with: restoreColor, colorBlendFactor: 1, duration: 0.2),
        ]), withKey: "blockedPlacementFlash")
    }

    /// Briefly flash a tile to make a `CityHazards.Strike` visible — without
    /// this, a hazard is silent: a density number that's just a bit lower
    /// next time you look. `service` picks the color (`RenderPalette.fireHazardFlash`
    /// for `.fireStation`, `.crimeHazardFlash` for `.policeStation`) so
    /// which hazard struck is legible from the flash color alone, the same
    /// way `flashInsufficientFunds` reuses `colorize` to animate out and
    /// back without touching any data.
    ///
    /// Runs *after* `refreshAll()` in `runSimulationTick()`, so `currentColor(at:)`
    /// (what it fades back to) already reflects this tick's new density —
    /// a tile that lost density flashes and settles at its new, dimmer
    /// color, not the one it had before the hazard struck.
    private func flashHazard(at position: GridPosition, service: ZoneType) {
        guard let node = tileNodes[position] else { return }
        let flashColor = service == .fireStation ? RenderPalette.fireHazardFlash : RenderPalette.crimeHazardFlash
        let restoreColor = currentColor(at: position)
        node.run(.sequence([
            .colorize(with: flashColor, colorBlendFactor: 1, duration: 0.08),
            .colorize(with: restoreColor, colorBlendFactor: 1, duration: 0.35),
        ]), withKey: "hazardFlash")
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
    func rebuildEntireGrid() {
        tileLayer.removeAllChildren()
        tileNodes.removeAll()
        buildTileNodes()
        positionSunGlow()
    }

    /// Point the camera at the middle of the map. The camera's position is
    /// the scene point that appears at the center of the view. Called from
    /// `didMove(to:)` on first load and explicitly by `GameView`'s Reset
    /// button after `rebuildEntireGrid()` — never implicitly by
    /// `rebuildEntireGrid()` itself any more; see that method's own doc
    /// comment for why.
    func centerCameraOnMap() {
        cameraNode.position = layout.centerPoint(of: map)
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
        let content = layout.contentSize(of: map)
        let diameter = max(content.width, content.height) * 1.6
        sunGlowNode.size = CGSize(width: diameter, height: diameter)
        sunGlowNode.position = CGPoint(x: content.width / 2, y: -diameter * 0.4)
    }

    // MARK: - Refreshing from data

    /// Push current tile data into the existing sprites.
    ///
    /// Called after every click, and after every simulation step. It exists
    /// to make the intended data flow explicit: change data -> refresh
    /// view. Never the reverse.
    func refresh(_ position: GridPosition) {
        guard let node = tileNodes[position] else { return }
        switch controller.overlayMode {
        case .none:
            tileRenderer.update(node, for: map[position])
            tileRenderer.clearPipeMarker(on: node)
            tileRenderer.clearPowerLineMarker(on: node)
            tileRenderer.clearBuildingShadow(on: node)
            syncLaneLine(at: position)
            // Damage is drawn on the anchor's sprite only, since that's the
            // one cell of a building that gets a sprite at all.
            tileRenderer.syncDamageMarker(on: node, damagedBy: map[position].damagedBy)
            // Normal view only — the Water/Power overlays already have
            // their own, bigger signal for this (the tile's whole color),
            // so a small corner badge on top of that would be redundant.
            tileRenderer.syncUtilityWarning(
                on: node,
                density: map[position].density,
                hasWaterSupply: Water.hasSupply(at: position, in: map),
                hasPowerSupply: PowerGrid.hasSupply(at: position, in: map)
            )
        case .landValue:
            node.color = RenderPalette.landValueColor(for: LandValue.value(at: position, in: map, using: overlayDistances))
            tileRenderer.clearPips(on: node)
            tileRenderer.clearIcon(on: node)
            tileRenderer.clearNetworkGlow(on: node)
            tileRenderer.clearPipeMarker(on: node)
            tileRenderer.clearPowerLineMarker(on: node)
            tileRenderer.clearBuildingShadow(on: node)
            tileRenderer.clearLaneLine(on: node)
            tileRenderer.clearUtilityWarning(on: node)
            tileRenderer.clearDamageMarker(on: node)
        case .traffic:
            node.color = RenderPalette.trafficColor(for: Traffic.congestion(at: position, in: map))
            tileRenderer.clearPips(on: node)
            tileRenderer.clearIcon(on: node)
            tileRenderer.clearNetworkGlow(on: node)
            tileRenderer.clearPipeMarker(on: node)
            tileRenderer.clearPowerLineMarker(on: node)
            tileRenderer.clearBuildingShadow(on: node)
            tileRenderer.clearLaneLine(on: node)
            tileRenderer.clearUtilityWarning(on: node)
            tileRenderer.clearDamageMarker(on: node)
        case .water:
            node.color = RenderPalette.waterColor(for: Water.hasSupply(at: position, in: map))
            tileRenderer.clearPips(on: node)
            tileRenderer.clearIcon(on: node)
            tileRenderer.clearNetworkGlow(on: node)
            tileRenderer.clearPowerLineMarker(on: node)
            tileRenderer.clearLaneLine(on: node)
            tileRenderer.clearUtilityWarning(on: node)
            tileRenderer.clearDamageMarker(on: node)
            // Reads `hasPipe` directly rather than the cached
            // `map.waterSupply`, so a pipe you just laid shows up right
            // away — the *supply* coloring above still only updates once
            // the next simulation tick recomputes it, same as it already
            // does for a newly-placed Water Tower.
            tileRenderer.syncPipeMarker(on: node, hasPipe: map[position].hasPipe)
            // The building-visibility fix: a dimmed copy of whatever's
            // normally here, so you can still see which tiles you're
            // routing pipe to/around instead of a featureless supply-color
            // block. See `syncBuildingShadow`'s own doc comment.
            tileRenderer.syncBuildingShadow(on: node, zone: map[position].zone, density: map[position].density, footprintSize: map[position].zone.footprintSize, seed: position)
        case .power:
            node.color = RenderPalette.powerColor(for: PowerGrid.hasSupply(at: position, in: map))
            tileRenderer.clearPips(on: node)
            tileRenderer.clearIcon(on: node)
            tileRenderer.clearNetworkGlow(on: node)
            tileRenderer.clearPipeMarker(on: node)
            tileRenderer.clearLaneLine(on: node)
            tileRenderer.clearUtilityWarning(on: node)
            tileRenderer.clearDamageMarker(on: node)
            // Same "read the layer directly, not the cached supply" reasoning
            // `syncPipeMarker` documents just above, for the parallel layer.
            tileRenderer.syncPowerLineMarker(on: node, hasPowerLine: map[position].hasPowerLine)
            // Same building-visibility fix as Water, just above.
            tileRenderer.syncBuildingShadow(on: node, zone: map[position].zone, density: map[position].density, footprintSize: map[position].zone.footprintSize, seed: position)
        }
        syncTrafficAnimation(at: position)
    }

    /// Adds (or removes) a road/highway tile's glowing lane-line detail,
    /// shaped to match what's actually connected to it
    /// (`Traffic.roadConnections(at:in:)`) — see `TileRenderer.syncLaneLine`'s
    /// own doc comment for why that connectivity answer has to be computed
    /// here, with the full `map`, and passed down rather than computed
    /// inside `TileRenderer` itself.
    private func syncLaneLine(at position: GridPosition) {
        guard let node = tileNodes[position] else { return }
        let zone = map[position].zone
        guard zone == .road || zone == .highway else {
            tileRenderer.clearLaneLine(on: node)
            return
        }
        tileRenderer.syncLaneLine(on: node, zone: zone, connections: Traffic.roadConnections(at: position, in: map))
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

    func refreshAll() {
        if controller.overlayMode == .landValue {
            overlayDistances = ZoneDistanceField.compute(for: map)
        }
        defer { overlayDistances = nil }
        for position in tileNodes.keys {
            refresh(position)
        }
    }

    // MARK: - Traffic animation

    private static let trafficCarNodeName = "trafficCar"

    /// A horizontal gradient, transparent at its left edge fading to
    /// near-opaque at its right — the raw material for each car's speed
    /// trail below. Same "cache one shared gradient texture, tint and
    /// additively blend it per use" technique `TileRenderer.glowTexture`
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
        let trailLength = layout.spriteSize.width * (0.3 + speedFactor * 1.4)
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
    private func syncTrafficAnimation(at position: GridPosition) {
        guard let node = tileNodes[position] else { return }
        let existingCars = node.children.filter { $0.name == Self.trafficCarNodeName }

        let zone = map[position].zone
        guard controller.overlayMode == .none, zone == .road || zone == .highway else {
            existingCars.forEach { $0.removeFromParent() }
            return
        }

        let congestion = Traffic.congestion(at: position, in: map)
        let carCount = Traffic.carCount(forCongestion: congestion)
        guard existingCars.count != carCount else { return }
        existingCars.forEach { $0.removeFromParent() }
        guard carCount > 0 else { return }

        let horizontal = Traffic.isHorizontallyOriented(at: position, in: map)
        // Which way most *actual* routed traffic crosses this tile, not
        // an arbitrary fixed screen direction — a car here should look
        // like it's headed toward the job it's actually commuting to.
        let flowsPositive = map.trafficLoad.netHeadingIsPositive(at: position, horizontal: horizontal)
        // Busier roads get slower-crossing cars too, not just more of them —
        // reads as "jammed," not just "popular."
        let crossingDuration = 1.2 + congestion * 1.8
        let half = layout.spriteSize.width / 2 * 0.8
        let laneSpacing = layout.spriteSize.width * 0.2
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
        let lane = flowsPositive ? laneSpacing : -laneSpacing
        // How free-flowing this tile's traffic actually is, 1 (empty
        // road) down to 0 (gridlocked) — the same signal `crossingDuration`
        // above already reads off `congestion`, reused here so the speed
        // trail agrees with how fast the car it's attached to actually
        // looks like it's crossing the tile.
        let speedFactor = CGFloat(1 - congestion)
        let travelAngle: CGFloat
        if horizontal {
            travelAngle = flowsPositive ? 0 : .pi
        } else {
            travelAngle = flowsPositive ? .pi / 2 : -.pi / 2
        }

        for index in 0 ..< carCount {
            let carSize = horizontal ? CGSize(width: 8, height: 5) : CGSize(width: 5, height: 8)
            let car = SKShapeNode(rectOf: carSize, cornerRadius: 1.5)
            car.name = Self.trafficCarNodeName
            car.fillColor = RenderPalette.trafficCarBody
            car.strokeColor = RenderPalette.trafficCarOutline
            car.lineWidth = 1
            car.zPosition = 2
            car.addChild(makeSpeedTrail(
                zone: zone,
                travelAngle: travelAngle,
                carLength: horizontal ? carSize.width : carSize.height,
                carThickness: horizontal ? carSize.height : carSize.width,
                speedFactor: speedFactor
            ))

            let lowEnd = horizontal ? CGPoint(x: -half, y: lane) : CGPoint(x: lane, y: -half)
            let highEnd = horizontal ? CGPoint(x: half, y: lane) : CGPoint(x: lane, y: half)
            let start = flowsPositive ? lowEnd : highEnd
            let end = flowsPositive ? highEnd : lowEnd
            car.position = start

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
            let drive = SKAction.move(to: end, duration: crossingDuration)
            let fadeOutAtEnd = SKAction.fadeOut(withDuration: 0.2)
            let teleportToStart = SKAction.move(to: start, duration: 0)
            let fadeInAtStart = SKAction.fadeIn(withDuration: 0.2)
            let loop = SKAction.repeatForever(.sequence([drive, fadeOutAtEnd, teleportToStart, fadeInAtStart]))
            // Stagger each car's start so a multi-car tile doesn't drive in
            // lockstep.
            let stagger = crossingDuration * Double(index) / Double(carCount)
            car.run(.sequence([.wait(forDuration: stagger), loop]))

            node.addChild(car)
        }
    }

    /// What color a tile is drawn right now — used only by
    /// `flashInsufficientFunds` to know what to fade *back to* once the
    /// flash ends. Mirrors the same overlay-or-zone choice `refresh(_:)`
    /// makes, kept separate because that one needs to hand a plain
    /// `SKColor` to an `SKAction`, not update a node directly.
    private func currentColor(at position: GridPosition) -> SKColor {
        switch controller.overlayMode {
        case .none:
            let tile = map[position]
            return RenderPalette.color(for: tile.zone, density: tile.density)
        case .landValue:
            return RenderPalette.landValueColor(for: LandValue.value(at: position, in: map, using: overlayDistances))
        case .traffic:
            return RenderPalette.trafficColor(for: Traffic.congestion(at: position, in: map))
        case .water:
            return RenderPalette.waterColor(for: Water.hasSupply(at: position, in: map))
        case .power:
            return RenderPalette.powerColor(for: PowerGrid.hasSupply(at: position, in: map))
        }
    }
}
