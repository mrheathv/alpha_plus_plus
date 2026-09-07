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

        buildTileNodes()
        centerCameraOnMap()
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
        // pipes live here instead of as another toolbar button.
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
            lastPaintPosition = position
            return
        }

        for step in stroke(from: lastPaintPosition, to: position) {
            let outcome = controller.place(at: step)
            refresh(step)
            if outcome == .insufficientFunds {
                flashInsufficientFunds(at: step)
                // The tool's cost doesn't change mid-stroke, so if this tile
                // was unaffordable, every remaining tile in the line would
                // be too — stop here instead of flashing each one in turn.
                break
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
        }
        lastBulldozePosition = position
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
    /// cover. Green while every cell it would cover is `.empty`; red if
    /// any of them already have a road or building on them — placing there
    /// would silently replace it via `place(at:)`'s existing auto-replace
    /// path (see `involvesAFootprint` in `mouseDown`/`place(with:)`), and
    /// this is what makes that visible *before* the click instead of only
    /// discoverable after it already happened. A player who intends to
    /// replace something can still just click through a red outline —
    /// this warns, it doesn't block.
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

        // Laying a pipe never conflicts with anything already on the
        // surface — there's no "blocked" state to warn about the way a
        // surface building has, so this is always a plain 1×1 "clear" tile.
        if controller.overlayMode == .water {
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
        }
    }

    /// Tear down and rebuild every tile sprite from scratch, then recenter
    /// the camera. `refreshAll()` isn't enough for this — it re-syncs the
    /// sprites that already exist, but a map-size change means the *number*
    /// of tiles changed (a smaller map has stale sprites with nowhere valid
    /// to point; a larger one has positions with no sprite yet). This is
    /// what `GameView`'s Reset calls when `selectedMapSize` might have
    /// changed, instead of `performFullMapChange`'s `refreshAll()`.
    func rebuildEntireGrid() {
        tileLayer.removeAllChildren()
        tileNodes.removeAll()
        buildTileNodes()
        centerCameraOnMap()
    }

    /// Point the camera at the middle of the map. The camera's position is the
    /// scene point that appears at the center of the view.
    private func centerCameraOnMap() {
        cameraNode.position = layout.centerPoint(of: map)
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
        case .landValue:
            node.color = RenderPalette.landValueColor(for: LandValue.value(at: position, in: map))
            tileRenderer.clearPips(on: node)
            tileRenderer.clearIcon(on: node)
            tileRenderer.clearNetworkGlow(on: node)
            tileRenderer.clearPipeMarker(on: node)
        case .traffic:
            node.color = RenderPalette.trafficColor(for: Traffic.congestion(at: position, in: map))
            tileRenderer.clearPips(on: node)
            tileRenderer.clearIcon(on: node)
            tileRenderer.clearNetworkGlow(on: node)
            tileRenderer.clearPipeMarker(on: node)
        case .water:
            node.color = RenderPalette.waterColor(for: Water.hasSupply(at: position, in: map))
            tileRenderer.clearPips(on: node)
            tileRenderer.clearIcon(on: node)
            tileRenderer.clearNetworkGlow(on: node)
            // Reads `hasPipe` directly rather than the cached
            // `map.waterSupply`, so a pipe you just laid shows up right
            // away — the *supply* coloring above still only updates once
            // the next simulation tick recomputes it, same as it already
            // does for a newly-placed Water Tower.
            tileRenderer.syncPipeMarker(on: node, hasPipe: map[position].hasPipe)
        }
        syncTrafficAnimation(at: position)
    }

    func refreshAll() {
        for position in tileNodes.keys {
            refresh(position)
        }
    }

    // MARK: - Traffic animation

    private static let trafficCarNodeName = "trafficCar"

    /// Ambient "cars" driving back and forth across a road tile — purely
    /// decorative, visualizing `Traffic.congestion(at:in:)` (more, slower
    /// cars as a road gets busier) without needing "Show Traffic" turned
    /// on. Cleared during either overlay, same as pips/icons, and for
    /// anything that isn't a road.
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
        // Busier roads get slower-crossing cars too, not just more of them —
        // reads as "jammed," not just "popular."
        let crossingDuration = 1.2 + congestion * 1.8
        let half = layout.spriteSize.width / 2 * 0.8
        let laneSpacing = layout.spriteSize.width * 0.2
        let laneOffsets: [CGFloat] = [0, -laneSpacing, laneSpacing]

        for index in 0 ..< carCount {
            let carSize = horizontal ? CGSize(width: 8, height: 5) : CGSize(width: 5, height: 8)
            let car = SKShapeNode(rectOf: carSize, cornerRadius: 1.5)
            car.name = Self.trafficCarNodeName
            car.fillColor = RenderPalette.trafficCarBody
            car.strokeColor = RenderPalette.trafficCarOutline
            car.lineWidth = 1
            car.zPosition = 2

            let lane = laneOffsets[index % laneOffsets.count]
            let start = horizontal ? CGPoint(x: -half, y: lane) : CGPoint(x: lane, y: -half)
            let end = horizontal ? CGPoint(x: half, y: lane) : CGPoint(x: lane, y: half)
            car.position = start

            let drive = SKAction.move(to: end, duration: crossingDuration)
            let loopBack = SKAction.move(to: start, duration: 0)
            let loop = SKAction.repeatForever(.sequence([drive, loopBack]))
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
            return RenderPalette.landValueColor(for: LandValue.value(at: position, in: map))
        case .traffic:
            return RenderPalette.trafficColor(for: Traffic.congestion(at: position, in: map))
        case .water:
            return RenderPalette.waterColor(for: Water.hasSupply(at: position, in: map))
        }
    }
}
