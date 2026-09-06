import SpriteKit

/// The SpriteKit scene that draws the city.
///
/// Key idea: the scene *owns no rules*. It holds a `CityMap` (data), asks
/// `TileRenderer` to turn each tile into a node, and keeps a lookup table so it
/// can update individual tiles later without rebuilding the world. When Phase 2
/// adds a simulation tick, it will hand this scene new data and the scene will
/// re-sync — it will never compute population itself.
final class GameScene: SKScene {

    // MARK: - Data

    /// The city. `private(set)` for now — mutation arrives with click-to-place.
    private(set) var map: CityMap

    // MARK: - Rendering

    private let layout: GridLayout
    private let tileRenderer: TileRenderer

    /// All tile sprites live under one parent node rather than directly on the
    /// scene. That gives us a single thing to move, scale, or hide, and keeps
    /// future layers (overlays, UI, effects) cleanly separated by z-order.
    private let tileLayer = SKNode()

    /// Grid coordinate -> sprite, so updating one tile is O(1) instead of a
    /// scene-graph search.
    private var tileNodes: [GridPosition: SKSpriteNode] = [:]

    /// An `SKCameraNode` lets us pan and zoom by moving *one* node instead of
    /// repositioning thousands of tiles. We don't move it yet, but adopting it
    /// now means pan/zoom is a later change to the camera, not a rewrite.
    private let cameraNode = SKCameraNode()

    /// `didMove(to:)` can fire more than once (e.g. if the scene is presented
    /// again after a view change), and building the grid twice would stack
    /// duplicate sprites. This guard makes setup idempotent.
    private var hasBuiltScene = false

    // MARK: - Init

    init(map: CityMap = CityMap(width: 20, height: 20), layout: GridLayout = GridLayout()) {
        self.map = map
        self.layout = layout
        self.tileRenderer = TileRenderer(layout: layout)

        // Note: `layout` and `map` here are the *parameters*, not `self.layout` /
        // `self.map`. Swift forbids touching `self` before `super.init`, and the
        // parameters shadow the properties, so this is legal (and a very common
        // stumbling block when writing Swift initializers).
        //
        // The starting size barely matters because `.resizeFill` below makes the
        // scene adopt the view's size, so one scene point == one screen point
        // and nothing gets stretched.
        super.init(size: layout.contentSize(of: map))

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
        addChild(tileLayer)

        buildTileNodes()
        centerCameraOnMap()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        // Window resized: keep the map centered rather than pinned to a corner.
        centerCameraOnMap()
    }

    // MARK: - Building the grid

    private func buildTileNodes() {
        for tile in map.tiles {
            let node = tileRenderer.makeNode(for: tile)
            tileLayer.addChild(node)
            tileNodes[tile.position] = node
        }
    }

    /// Point the camera at the middle of the map. The camera's position is the
    /// scene point that appears at the center of the view.
    private func centerCameraOnMap() {
        cameraNode.position = layout.centerPoint(of: map)
    }

    // MARK: - Refreshing from data

    /// Push current tile data into the existing sprites.
    ///
    /// Unused in this step — click-to-place and the Phase 2 tick will both call
    /// it. It exists now to make the intended data flow explicit:
    /// change data -> refresh view. Never the reverse.
    func refresh(_ position: GridPosition) {
        guard let node = tileNodes[position] else { return }
        tileRenderer.update(node, for: map[position])
    }

    func refreshAll() {
        for tile in map.tiles {
            if let node = tileNodes[tile.position] {
                tileRenderer.update(node, for: tile)
            }
        }
    }
}
