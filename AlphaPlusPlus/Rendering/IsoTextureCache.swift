/// **A namespace, since M8.** This was SpriteKit's texture cache, which
/// rasterised each distinct building, ground and lane mark once. Metal draws
/// geometry and caches meshes instead (`MetalCityMesh.Cache`). What the
/// renderers shared stays, as extensions in `BuildingVariants.swift`: the
/// quantised variant a lot draws (`variant(for:)`, `canonicalSeed(for:)`,
/// `variantCount`), the vehicle kinds, and the badge glyph paths.
enum IsoTextureCache {}
