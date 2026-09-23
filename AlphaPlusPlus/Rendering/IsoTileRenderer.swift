/// **A namespace, since M8.** This was SpriteKit's city renderer: one node per
/// building, its ground, its light and its decorations. Metal draws the city
/// now and the node code is gone. What both renderers shared stays, as
/// extensions in `OverlayPaint.swift`: the decision about what each view paints
/// (`paint`, `OverlayPaint`, `OverlayBuildings`), `missingUtilities`, and the
/// occlusion step.
enum IsoTileRenderer {}
