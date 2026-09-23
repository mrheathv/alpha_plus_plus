import Foundation

/// **What a click on the map means, without a scene** (M8).
///
/// Everything `GameScene`'s input section decided (which view takes a click,
/// strokes, bulldozing, route stops, buying land, laying mains, what the
/// cursor says and when a click earns a flash) moved here, in terms of tiles
/// rather than `NSEvent`s or nodes. The view turns events into tiles
/// (`CityMTKView`) and the renderer draws `cursor` and the flashes
/// (`MetalMarks`); neither decides anything.
///
/// It does no drawing and asks for none: every action goes through
/// `GameController`, whose map writes bump `mapRevision`, which is what the
/// Metal renderer already watches. `revision` here moves only when the
/// cursor or the flash queue does.
@MainActor
final class MapInteraction: MapInput {

    let controller: GameController

    var camera: CityCamera
    var keyboardPan: CGVector = .zero

    /// What the cursor should show, or `nil` when it should show nothing: the
    /// pointer is off the map, a stroke is in progress, or the footprint does
    /// not fit from this corner.
    private(set) var cursor: MapMarks.Cursor? {
        didSet { if cursor != oldValue { revision &+= 1 } }
    }

    /// Bumped whenever `cursor` changes or a flash is queued.
    private(set) var revision = 0

    private var flashes: [MapMarks.Flash] = []

    /// The last tile of the current left stroke. `mouseDragged` reports
    /// where the pointer *is*, roughly once a frame, not the path it took, so
    /// a fast drag jumps tiles; this is what the gap is filled back to.
    /// `nil` between strokes.
    private var lastPaintPosition: GridPosition?

    /// Same, for the right-button stroke, kept apart so the two never
    /// interpolate through each other's history.
    private var lastBulldozePosition: GridPosition?

    /// The tile the pointer last hovered, so the cursor can be recomputed
    /// after a click changes what is under it.
    private var hovered: GridPosition?

    init(controller: GameController, camera: CityCamera = CityCamera()) {
        self.controller = controller
        self.camera = camera
    }

    private var map: CityMap { controller.map }

    // MARK: - Flashes

    /// The flashes queued since the last call, oldest first. The renderer
    /// takes them once and fades each on its own wall clock.
    func takeFlashes() -> [MapMarks.Flash] {
        defer { flashes.removeAll() }
        return flashes
    }

    /// Queue a flash over the building at `position` (or the tile, if bare).
    func flash(_ kind: MapMarks.Flash.Kind, at position: GridPosition) {
        guard map.contains(position) else { return }
        let origin = map[position].buildingOrigin
        flashes.append(MapMarks.Flash(origin: origin, size: max(1, map[origin].zone.footprintSize), kind: kind))
        revision &+= 1
    }

    // MARK: - MapInput

    func pointerMoved(to tile: GridPosition?) {
        hovered = tile
        guard let tile else {
            cursor = nil
            controller.inspect(at: nil)
            return
        }
        // The inspector rides the cursor's tracking; `inspect(at:)` no-ops
        // unless the pointer crossed onto a different lot.
        controller.inspect(at: tile)
        cursor = Self.cursor(at: tile, controller: controller)
    }

    func press(at tile: GridPosition?) {
        beginStroke()
        guard let tile else { return }
        place(at: tile)
    }

    func drag(to tile: GridPosition?) {
        guard let tile, dragPaints else { return }
        place(at: tile)
    }

    func release() {
        lastPaintPosition = nil
        lastBulldozePosition = nil
        // The stroke may have changed what is under the pointer.
        if let hovered { cursor = Self.cursor(at: hovered, controller: controller) }
    }

    func rightPress(at tile: GridPosition?) {
        beginStroke()
        guard let tile else { return }
        bulldoze(at: tile)
    }

    func rightDrag(to tile: GridPosition?) {
        guard let tile else { return }
        bulldoze(at: tile)
    }

    // MARK: - Strokes

    /// What a fresh press clears before the first tile: the drag state, so
    /// the stroke starts here, and the cursor, since a stroke is placing
    /// tiles live and a "what would happen" outline would only confuse.
    func beginStroke() {
        lastPaintPosition = nil
        lastBulldozePosition = nil
        cursor = nil
    }

    /// Should a drag paint at all? A route is drawn by naming stations, so a
    /// drag across one must not add it every frame. **That is a fact about
    /// the view taking the click, not about a draft existing somewhere**: a
    /// half-drawn bus line once stopped every pipe drag in the game. A drag
    /// paints unless this view is the one drawing that line.
    var dragPaints: Bool {
        guard let mode = controller.overlayMode.routeMode else { return true }
        return controller.routeDraft?.mode != mode
    }

    /// Everything a left click does once the pointer is a tile. See the
    /// matching comments in `GameScene`'s history for why each branch is
    /// shaped the way it is; the rules are unchanged, only the redraws went.
    func place(at position: GridPosition) {
        // The Land view sells land, one parcel per click: a drag buying every
        // parcel it crossed would spend a fortune on a gesture meant to pan.
        if controller.overlayMode == .land {
            guard lastPaintPosition == nil else { return }
            lastPaintPosition = position
            switch controller.buyLand(at: position) {
            case .bought: break
            case .insufficientFunds: flash(.insufficientFunds, at: position)
            case .refused, .nothingForSale: flash(.blocked, at: position)
            }
            return
        }

        // The Water and Power views are the conduit-editing layers. Supply is
        // recomputed once per stroke rather than once a tile: each recompute
        // is two whole-map flood fills.
        if controller.overlayMode == .water || controller.overlayMode == .power {
            let isWater = controller.overlayMode == .water
            var laid = false
            for step in stroke(from: lastPaintPosition, to: position) {
                let outcome = isWater
                    ? controller.layPipe(at: step, recomputingSupply: false)
                    : controller.layPowerLine(at: step, recomputingSupply: false)
                if outcome == .placed { laid = true }
                if outcome == .insufficientFunds {
                    flash(.insufficientFunds, at: step)
                    break // a tile's price does not change mid-stroke
                }
            }
            if laid { controller.recomputeUtilitySupply() }
            lastPaintPosition = position
            return
        }

        // While a line is being drawn in its own view, a click names a
        // station rather than placing whatever the toolbar has armed.
        if let mode = controller.overlayMode.routeMode, controller.routeDraft?.mode == mode {
            if controller.addStopToRoute(at: position) == .notAStation {
                flash(.blocked, at: position)
            }
            lastPaintPosition = position
            return
        }

        // The Bulldoze tool is `.empty` selected as the left-click tool, and
        // clears rather than places: `place` refuses anything but bare land.
        if controller.selectedTool == .empty {
            if map.contains(position), map[position].zone.footprintSize > 1 {
                guard lastPaintPosition == nil else { return }
                controller.bulldoze(at: position)
                lastPaintPosition = position
                return
            }
            for step in stroke(from: lastPaintPosition, to: position) {
                controller.bulldoze(at: step)
            }
            lastPaintPosition = position
            return
        }

        // A multi-tile building is placed once per click, never painted.
        if involvesAFootprint(at: position, with: controller.selectedTool) {
            guard lastPaintPosition == nil else { return }
            let outcome = controller.place(at: position)
            if outcome == .insufficientFunds { flash(.insufficientFunds, at: position) }
            if outcome == .blocked { flash(.blocked, at: position) }
            lastPaintPosition = position
            return
        }

        for step in stroke(from: lastPaintPosition, to: position) {
            let outcome = controller.place(at: step)
            if outcome == .insufficientFunds {
                flash(.insufficientFunds, at: step)
                break // every remaining tile would be unaffordable too
            }
            // "Occupied" is per tile, and a stroke can cross back onto bare
            // land, so a blocked tile flashes and the stroke carries on.
            if outcome == .blocked { flash(.blocked, at: step) }
        }
        lastPaintPosition = position
    }

    /// The right-click erase: conduits in their own views, buildings
    /// elsewhere, and a multi-tile building once per click.
    func bulldoze(at position: GridPosition) {
        if controller.overlayMode == .water || controller.overlayMode == .power {
            let isWater = controller.overlayMode == .water
            for step in stroke(from: lastBulldozePosition, to: position) {
                if isWater { controller.removePipe(at: step) } else { controller.removePowerLine(at: step) }
            }
            lastBulldozePosition = position
            return
        }
        if map.contains(position), map[position].zone.footprintSize > 1 {
            guard lastBulldozePosition == nil else { return }
            controller.bulldoze(at: position)
            lastBulldozePosition = position
            return
        }
        for step in stroke(from: lastBulldozePosition, to: position) {
            controller.bulldoze(at: step)
        }
        lastBulldozePosition = position
    }

    private func involvesAFootprint(at position: GridPosition, with tool: ZoneType) -> Bool {
        tool.footprintSize > 1 || (map.contains(position) && map[position].zone.footprintSize > 1)
    }

    /// The tiles one drag event acts on: the whole line back to the previous
    /// tile, or just `to` at the start of a stroke. Off-map tiles in the line
    /// are ignored by the controller.
    private func stroke(from: GridPosition?, to: GridPosition) -> [GridPosition] {
        guard let from else { return [to] }
        return from.line(to: to)
    }

    // MARK: - The cursor

    /// **What the cursor says: the question the click will be asked.**
    /// Static and pure, so it can be asked of a controller without an
    /// interaction, and so `GameScene`'s own preview can share it until M8
    /// deletes that scene.
    static func cursor(at position: GridPosition, controller: GameController) -> MapMarks.Cursor? {
        let map = controller.map
        guard map.contains(position) else { return nil }

        // Laying a conduit never conflicts with anything: always a clear tile.
        if controller.overlayMode == .water || controller.overlayMode == .power {
            return .init(origin: position, size: 1, blocked: false, kind: .tool)
        }

        // In the Land view the cursor is the whole parcel a click would buy.
        if controller.overlayMode == .land, let land = map.land {
            let origin = land.origin(of: land.parcel(containing: position))
            return .init(origin: origin, size: LandOwnership.parcelSize,
                         blocked: controller.landRefusal(at: position) != nil, kind: .land)
        }

        // Drawing a line: the cursor wraps a station, clear, or marks any
        // other tile blocked. It once described the armed zoning tool instead
        // and drew the one tile that worked, the station, as forbidden.
        if let mode = controller.overlayMode.routeMode, controller.routeDraft?.mode == mode {
            let station = map[position].buildingOrigin
            let isStation = map[station].zone == mode.stationZone
            return .init(origin: isStation ? station : position,
                         size: isStation ? map[station].zone.footprintSize : 1,
                         blocked: !isStation, kind: .routeStop)
        }

        let size = controller.selectedTool.footprintSize
        guard !map.footprintCells(origin: position, size: size).isEmpty else { return nil }
        // Affordability is deliberately not drawn as blocked: it has its own
        // flash, and a cursor red across the whole map the moment you are
        // broke says something about the treasury, not about this lot.
        let refusal = controller.placementRefusal(of: controller.selectedTool, at: position)
        return .init(origin: position, size: size,
                     blocked: refusal != nil && refusal != .insufficientFunds, kind: .tool)
    }
}
