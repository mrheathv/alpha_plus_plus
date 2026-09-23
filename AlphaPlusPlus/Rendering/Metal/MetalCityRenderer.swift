import CoreGraphics
import Metal
import MetalKit
import SpriteKit
import simd

/// **The city drawn as lit geometry on Metal** — migration phase M0.
///
/// Began as the spike (see CLAUDE.md, "The Metal spike") and is now the
/// renderer behind *Settings ▸ Renderer ▸ Metal (beta)*. During the migration
/// SpriteKit stays in charge of input, the camera, cursors and everything not
/// yet ported; this draws the city underneath it, reading SpriteKit's camera
/// every frame. Each phase moves another piece across.
///
/// It draws the *same data* the game always has — `ZoneMassing` for every
/// building, the variant the texture cache would pick — through a camera
/// matched exactly to `Isometric`'s projection. What it adds is everything a
/// sprite engine could only fake: light that falls on walls and streets, a
/// wet street that genuinely mirrors the city, a bloom chain, haze, and
/// sharpness at any zoom.
///
/// Four passes: the city mirrored under the street (the reflection), the city
/// itself (4× MSAA, in on-chip memory), a five-level bloom chain, and a
/// composite — written straight into the view's drawable when live, or into a
/// readable texture when a test asks for a picture.
final class MetalCityRenderer {

    // MARK: - GPU layouts, mirrored in MetalCity.metal

    struct GPUVertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
        var albedo: SIMD3<Float>
        var emissive: SIMD3<Float>
        var rim: SIMD3<Float>
        var uv: SIMD2<Float>
        var size: SIMD2<Float>
        var ground: Float

        /// Packed exactly as the shader's `Vertex`: SIMD3 in Swift is 16
        /// bytes, the shader's `packed_float3` is 12, so the vertex is written
        /// out as plain floats rather than trusting the struct's layout.
        var floats: [Float] {
            [position.x, position.y, position.z, normal.x, normal.y, normal.z,
             albedo.x, albedo.y, albedo.z, emissive.x, emissive.y, emissive.z,
             rim.x, rim.y, rim.z, uv.x, uv.y, size.x, size.y, ground]
        }
        static let floatCount = 20
    }

    struct GPULight {
        var position: SIMD3<Float>
        var radius: Float
        var color: SIMD3<Float>

        var floats: [Float] { [position.x, position.y, position.z, radius, color.x, color.y, color.z, 0] }
        static let floatCount = 8
    }

    struct Uniforms {
        var viewProjection: simd_float4x4
        var frame: SIMD4<Float>
        var moonAndTime: SIMD4<Float>
        var counts: SIMD4<UInt32>
        var overlay: SIMD4<Float> = .zero
        var fog: SIMD4<Float> = .zero
        var zenith: SIMD4<Float> = .zero
        var horizon: SIMD4<Float> = .zero
    }

    /// **The look, as data**: the air, the sky, the gloss and the grade, all in
    /// one value so a whole direction can be swapped — which is what the mood
    /// frames are for. `neonNoir` is exactly the look M6 ended on; the others
    /// are candidates for the retrowave direction. Colours are linear.
    struct Look: Equatable {
        var name: String
        var lowFog: Float = 0
        var fogHeight: Float = 1
        var distanceHaze: Float = 0
        var streetGloss: Float = 0.16
        var groundGloss: Float = 0
        var zenith = SIMD3<Float>(0.012, 0.008, 0.03)
        var horizon = SIMD3<Float>(0.012, 0.008, 0.03)
        var grain: Float = 0.035
        var toe: Float = 0.35
        var saturation: Float = 1.15
        var exposure: Float = 1
        var scanlines: Float = 0

        static let neonNoir = Look(name: "Neon noir (now)")
        static let sunsetHaze = Look(name: "Sunset haze", lowFog: 0.3, fogHeight: 1.2, distanceHaze: 0.45,
                                     streetGloss: 0.3, groundGloss: 0.08,
                                     zenith: SIMD3(0.018, 0.01, 0.055), horizon: SIMD3(0.3, 0.06, 0.2),
                                     grain: 0, toe: 0.12, saturation: 1.1)
        static let chromeNight = Look(name: "Chrome night", lowFog: 0.18, fogHeight: 0.8, distanceHaze: 0.25,
                                      streetGloss: 0.55, groundGloss: 0.22,
                                      zenith: SIMD3(0.01, 0.012, 0.05), horizon: SIMD3(0.1, 0.035, 0.2),
                                      grain: 0, toe: 0.15, saturation: 1.2)
        static let miamiDusk = Look(name: "Miami dusk", lowFog: 0.28, fogHeight: 1.6, distanceHaze: 0.55,
                                    streetGloss: 0.35, groundGloss: 0.12,
                                    zenith: SIMD3(0.04, 0.018, 0.09), horizon: SIMD3(0.5, 0.15, 0.22),
                                    grain: 0, toe: 0, saturation: 1.05, exposure: 1.1, scanlines: 0.06)
        /// **The chosen direction, for now**: Chrome night's gloss and crisp
        /// streets up close, Sunset haze's pink horizon for depth. Picked by
        /// the player from the mood frames — clean retrowave rather than
        /// gritty cyberpunk, with the far side of the city fading into a
        /// sunset instead of into black. Low fog is light, because a street
        /// washed pink up close was the one thing Sunset haze got wrong.
        static let retrowave = Look(name: "Retrowave", lowFog: 0.1, fogHeight: 0.8, distanceHaze: 0.45,
                                    streetGloss: 0.5, groundGloss: 0.18,
                                    zenith: SIMD3(0.01, 0.012, 0.05), horizon: SIMD3(0.3, 0.06, 0.2),
                                    grain: 0, toe: 0.15, saturation: 1.15)
        static let candidates: [Look] = [.neonNoir, .sunsetHaze, .chromeNight, .retrowave]
    }

    /// The look the frame is drawn in.
    var look = Look.retrowave

    /// Mirrors `MotionUniforms` in MetalCity.metal.
    struct MotionUniforms {
        var viewProjection: simd_float4x4
        var frame: SIMD4<Float>
        var area: SIMD4<Float>
        var params: SIMD4<Float>
    }

    /// Mirrors `SkyParams` in MetalCity.metal.
    struct SkyParams {
        var frame: SIMD4<Float>
        var sun: SIMD4<Float>
        var zenith: SIMD4<Float>
        var horizon: SIMD4<Float>
    }

    /// **Where the sun sits**: centred over the far tip of the land past the
    /// map, on a horizon level with that tip, with its lower part below it —
    /// the title screen's composition, found at the edge of the world. In this
    /// projection the far side of the city is the top of the screen, so the
    /// sun appears when the camera looks toward the back of the map or pulls
    /// all the way out.
    static let sunRadiusTiles: Float = 9
    /// How far past the map's far corner the horizon sits, in tiles: close
    /// enough that the sun is found by looking at the back of the city.
    static let sunBeyondCorner: Float = 5

    private func skyParams(through matrix: simd_float4x4, camera: Camera) -> SkyParams {
        let tip = -Self.sunBeyondCorner
        let clip = matrix * SIMD4<Float>(tip, tip, 0, 1)
        let width = Float(camera.size.width), height = Float(camera.size.height)
        let x = (clip.x + 1) / 2 * width, horizonY = (1 - clip.y) / 2 * height
        let radius = Self.sunRadiusTiles * Float(projection.tileWidth / 2 / camera.scale)
        return SkyParams(frame: SIMD4(width, height, 0, 0),
                         sun: SIMD4(x, horizonY - radius * 0.34, radius, horizonY),
                         zenith: SIMD4(look.zenith, 0), horizon: SIMD4(look.horizon, 0))
    }

    struct CompositeSettings {
        var bloomStrength: Float = 0.55
        var hazeStrength: Float = 0.35
        var exposure: Float = 1.0
        var grain: Float = 0.035
        var saturation: Float = 1.15
        var toe: Float = 0.35
        var scanlines: Float = 0
        var pad1: Float = 0

        /// **Classic and Cinematic carried across.** Classic is the ungraded
        /// frame — no bloom, no haze, no grain, no grade — the same promise
        /// the setting makes for SpriteKit ("flat, unbloomed and ungraded"),
        /// so the switch keeps answering the one question it exists for.
        static func `for`(_ style: VisualStyle) -> CompositeSettings {
            switch style {
            case .cinematic: return CompositeSettings()
            case .classic: return CompositeSettings(bloomStrength: 0, hazeStrength: 0, exposure: 1,
                                                    grain: 0, saturation: 1, toe: 0)
            }
        }
    }

    /// Where the camera looks and how close, in the same terms `GameScene`'s
    /// camera uses: a point in isometric screen space, and points per pixel.
    struct Camera {
        var centre: CGPoint
        /// Screen points per output pixel — `SKCameraNode`'s scale divided by
        /// the display's backing scale.
        var scale: CGFloat
        /// Output size in pixels.
        var size: CGSize
    }

    // MARK: - Setup

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let scenePipeline: MTLRenderPipelineState
    private let reflectionPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let bloomDown: MTLComputePipelineState
    private let bloomUp: MTLComputePipelineState
    private let compositePipeline: MTLComputePipelineState
    private let cullPipeline: MTLComputePipelineState
    private let tracePipeline: MTLRenderPipelineState
    private let traceReflectionPipeline: MTLRenderPipelineState
    private let rainPipeline: MTLRenderPipelineState
    private let smokePipeline: MTLRenderPipelineState
    private let flamePipeline: MTLRenderPipelineState
    private let skyPipeline: MTLRenderPipelineState
    private let sunPipeline: MTLRenderPipelineState
    private let overlayTilePipeline: MTLRenderPipelineState
    private let billboardPipeline: MTLRenderPipelineState
    private let signPipeline: MTLRenderPipelineState
    private let signReflectionPipeline: MTLRenderPipelineState
    private let signAtlas: MTLTexture?
    /// Drawn over everything: a mark the player came to a view to find.
    private let alwaysDepthState: MTLDepthStencilState
    private let glyphAtlas: MTLTexture?
    /// Bound wherever a pass has no real texture to give: the reflection pass
    /// has no reflection to read, and a view may have no wash. Leaving the
    /// slot empty is invalid under Metal's API validation (on for a Debug run)
    /// even when the shader's branch that reads it never runs.
    private let placeholder: MTLTexture
    /// Depth-tested against the city, never written: a trace behind a tower
    /// is hidden, and two traces crossing add up rather than one winning.
    private let readOnlyDepthState: MTLDepthStencilState
    let projection: Isometric
    /// `nil` follows `VisualStyle.current`; a test can pin its own.
    var settingsOverride: CompositeSettings?
    var settings: CompositeSettings {
        if let settingsOverride { return settingsOverride }
        var settings = CompositeSettings.for(VisualStyle.current)
        // Classic stays the ungraded frame whatever the look; the look is
        // Cinematic's.
        if VisualStyle.current == .cinematic {
            settings.grain = look.grain
            settings.toe = look.toe
            settings.saturation = look.saturation
            settings.exposure = look.exposure
            settings.scanlines = look.scanlines
        }
        return settings
    }

    static let sampleCount = 4

    init?(projection: Isometric = Isometric()) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "sceneVertex"),
              let fragment = library.makeFunction(name: "sceneFragment"),
              let reflectionFragment = library.makeFunction(name: "reflectionFragment"),
              let down = library.makeFunction(name: "bloomDown"),
              let up = library.makeFunction(name: "bloomUp"),
              let composite = library.makeFunction(name: "composite"),
              let cull = library.makeFunction(name: "cullLights"),
              let cullPipeline = try? device.makeComputePipelineState(function: cull),
              let traceVertex = library.makeFunction(name: "traceVertex"),
              let rainVertex = library.makeFunction(name: "rainVertex"),
              let traceFragment = library.makeFunction(name: "traceFragment"),
              let smokeVertex = library.makeFunction(name: "smokeVertex"),
              let smokeFragment = library.makeFunction(name: "smokeFragment"),
              let overlayTileVertex = library.makeFunction(name: "overlayTileVertex"),
              let overlayTileFragment = library.makeFunction(name: "overlayTileFragment"),
              let billboardVertex = library.makeFunction(name: "billboardVertex"),
              let billboardFragment = library.makeFunction(name: "billboardFragment"),
              let skyVertex = library.makeFunction(name: "skyVertex"),
              let skyFragment = library.makeFunction(name: "skyFragment"),
              let sunFragment = library.makeFunction(name: "sunFragment"),
              let sunVertex = library.makeFunction(name: "sunVertex")
        else { return nil }
        self.cullPipeline = cullPipeline
        self.device = device
        self.queue = queue
        self.projection = projection

        func pipeline(samples: Int, fragment: MTLFunction) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            descriptor.depthAttachmentPixelFormat = .depth32Float
            descriptor.rasterSampleCount = samples
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true

        /// A blended pass over the city: `additive` for light, otherwise
        /// premultiplied alpha. Alpha itself is never written, because in the
        /// reflection pass it carries the height of what was reflected.
        func blended(_ vertex: MTLFunction, _ fragment: MTLFunction, samples: Int,
                     additive: Bool) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.rasterSampleCount = samples
            descriptor.depthAttachmentPixelFormat = .depth32Float
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = .rgba16Float
            color.isBlendingEnabled = true
            color.writeMask = [.red, .green, .blue]
            color.sourceRGBBlendFactor = .one
            color.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        let readOnly = MTLDepthStencilDescriptor()
        readOnly.depthCompareFunction = .less
        readOnly.isDepthWriteEnabled = false
        guard let tracePipeline = blended(traceVertex, traceFragment, samples: Self.sampleCount, additive: true),
              let traceReflectionPipeline = blended(traceVertex, traceFragment, samples: 1, additive: true),
              let rainPipeline = blended(rainVertex, traceFragment, samples: Self.sampleCount, additive: true),
              let smokePipeline = blended(smokeVertex, smokeFragment, samples: Self.sampleCount, additive: false),
              let flamePipeline = blended(traceVertex, traceFragment, samples: Self.sampleCount, additive: false),
              let overlayTilePipeline = blended(overlayTileVertex, overlayTileFragment,
                                                samples: Self.sampleCount, additive: true),
              let billboardPipeline = blended(billboardVertex, billboardFragment,
                                              samples: Self.sampleCount, additive: false),
              let signVertex = library.makeFunction(name: "signVertex"),
              let signFragment = library.makeFunction(name: "signFragment"),
              let signPipeline = blended(signVertex, signFragment, samples: Self.sampleCount, additive: true),
              let signReflectionPipeline = blended(signVertex, signFragment, samples: 1, additive: true),
              let readOnlyDepthState = device.makeDepthStencilState(descriptor: readOnly)
        else { return nil }
        self.tracePipeline = tracePipeline
        self.traceReflectionPipeline = traceReflectionPipeline
        self.rainPipeline = rainPipeline
        self.smokePipeline = smokePipeline
        self.flamePipeline = flamePipeline
        let sky = MTLRenderPipelineDescriptor()
        sky.vertexFunction = skyVertex
        sky.fragmentFunction = skyFragment
        sky.colorAttachments[0].pixelFormat = .rgba16Float
        sky.depthAttachmentPixelFormat = .depth32Float
        sky.rasterSampleCount = Self.sampleCount
        guard let skyPipeline = try? device.makeRenderPipelineState(descriptor: sky),
              let sunPipeline = blended(sunVertex, sunFragment, samples: Self.sampleCount, additive: false)
        else { return nil }
        self.skyPipeline = skyPipeline
        self.sunPipeline = sunPipeline
        self.overlayTilePipeline = overlayTilePipeline
        self.billboardPipeline = billboardPipeline
        self.signPipeline = signPipeline
        self.signReflectionPipeline = signReflectionPipeline
        let always = MTLDepthStencilDescriptor()
        always.depthCompareFunction = .always
        always.isDepthWriteEnabled = false
        guard let alwaysDepthState = device.makeDepthStencilState(descriptor: always) else { return nil }
        self.alwaysDepthState = alwaysDepthState
        let blank = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1,
                                                             mipmapped: false)
        blank.usage = .shaderRead
        guard let placeholder = device.makeTexture(descriptor: blank) else { return nil }
        placeholder.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                            withBytes: [Float](repeating: 0, count: 4), bytesPerRow: 16)
        self.placeholder = placeholder
        // Built from the pixels rather than through `MTKTextureLoader`, which
        // turned the one-channel grey image down without saying so — and a
        // missing atlas skips the draw, so every sign quietly vanished.
        self.signAtlas = Self.makeSignAtlas(device: device, queue: queue)
        self.glyphAtlas = MetalOverlay.glyphAtlas().flatMap {
            try? MTKTextureLoader(device: device).newTexture(cgImage: $0, options: [.SRGB: false])
        }
        self.readOnlyDepthState = readOnlyDepthState

        guard let scene = pipeline(samples: Self.sampleCount, fragment: fragment),
              let reflection = pipeline(samples: 1, fragment: reflectionFragment),
              let depthState = device.makeDepthStencilState(descriptor: depth),
              let bloomDown = try? device.makeComputePipelineState(function: down),
              let bloomUp = try? device.makeComputePipelineState(function: up),
              let compositePipeline = try? device.makeComputePipelineState(function: composite)
        else { return nil }
        self.scenePipeline = scene
        self.reflectionPipeline = reflection
        self.depthState = depthState
        self.bloomDown = bloomDown
        self.bloomUp = bloomUp
        self.compositePipeline = compositePipeline
    }

    // MARK: - The camera

    /// `Isometric.project` as a matrix, plus a depth axis.
    ///
    /// The projection is affine — x and y go to the screen by the 2:1
    /// diamond, z goes straight up by `heightUnit` — so it is one matrix, not
    /// an approximation of one. Depth is distance along `Isometric.toCamera`,
    /// the direction the whole project already agrees the camera sits in.
    ///
    /// **A real camera matrix on purpose**: the migration plan keeps the
    /// fixed view for now, and a rotating or tilting camera later is a change
    /// to this function rather than another migration.
    func viewProjection(for camera: Camera, mapExtent: Float) -> simd_float4x4 {
        let kx = Float(1 / camera.scale / (camera.size.width / 2))
        let ky = Float(1 / camera.scale / (camera.size.height / 2))
        let halfWidth = Float(projection.tileWidth / 2)
        let halfHeight = Float(projection.tileHeight / 2)
        let rise = Float(projection.heightUnit)
        let cx = Float(camera.centre.x), cy = Float(camera.centre.y)
        let toward = Isometric.toCamera
        let depthScale = 1 / (4 * mapExtent)
        return simd_float4x4(rows: [
            SIMD4(halfWidth * kx, -halfWidth * kx, 0, -cx * kx),
            SIMD4(-halfHeight * ky, -halfHeight * ky, rise * ky, -cy * ky),
            SIMD4(-Float(toward.x) * depthScale, -Float(toward.y) * depthScale,
                  -Float(toward.z) * depthScale, 0.5),
            SIMD4(0, 0, 0, 1),
        ])
    }

    // MARK: - The city on the GPU

    private let cache = MetalCityMesh.Cache()

    /// Everything that moves — see `MetalMotion`.
    let motion = MetalMotion()

    /// What the map tells you — see `MetalOverlay`.
    let overlay = MetalOverlay()
    private var overlayTint: MTLTexture?
    private var overlayBuffers: (tiles: MTLBuffer?, scaffolds: MTLBuffer?, schematic: MTLBuffer?,
                                 billboards: MTLBuffer?) = (nil, nil, nil, nil)

    /// The view up: `GameController.overlayMode`.
    var overlayMode: OverlayMode = .none {
        didSet {
            guard overlayMode != oldValue else { return }
            builtRevision = nil
            plannedMotion = nil
        }
    }

    /// The running-time clock the motion was last planned at, so a tram line
    /// that is rebuilt starts from where the city's clock actually is.
    private var lastMotionClock: Double = 0

    /// Whether ambient traffic is drawn: off under every view that hides the
    /// street network, the rule `OverlayMode.showsRoadNetwork` states.
    var showsTraffic: Bool {
        get { motion.showsTraffic }
        set {
            guard newValue != motion.showsTraffic else { return }
            motion.showsTraffic = newValue
            builtRevision = nil
            plannedMotion = nil
        }
    }

    /// How tall the building on an anchor tile stands, from its mesh.
    private func buildingHeight(_ tile: Tile) -> Float {
        buildingHeight(zone: tile.zone, density: tile.density, at: tile.position)
    }

    private func buildingHeight(zone: ZoneType, density: Int, at position: GridPosition) -> Float {
        let rise = lastMap.map { MetalCityMesh.heightScale(zone: zone, density: density, at: position, in: $0) } ?? 1
        return baseHeight(zone: zone, density: density, at: position) * rise
    }

    private func baseHeight(zone: ZoneType, density: Int, at position: GridPosition) -> Float {
        let key = MetalCityMesh.Cache.Key(zone: zone, density: density,
                                          variant: IsoTextureCache.variant(for: position))
        if let known = heights[key] { return known }
        let built = cache.entries[key] ?? MetalCityMesh.building(key)
        cache.entries[key] = built
        var height: Float = 0
        var z = 2
        while z < built.vertices.count { height = max(height, built.vertices[z]); z += GPUVertex.floatCount }
        heights[key] = height
        return height
    }
    private var heights: [MetalCityMesh.Cache.Key: Float] = [:]

    private struct MotionKey: Equatable {
        let day: Int
        let showsTraffic: Bool
        let overlay: OverlayMode
        let reduceMotion: Bool
        let fires: Int
        let routes: Int
    }
    private var plannedMotion: MotionKey?
    private var plannedReduceMotion = VisualStyle.reduceMotion
    /// Every light in the city, on the CPU: culled to the view each frame.
    private var allLights: [Float] = []
    private var builtRevision: Int?
    private var mapSizePacked: UInt32 = 0
    private var mapExtent: Float = 1

    /// **The city in 8×8-tile chunks, each with its own buffer.**
    ///
    /// One mechanism for two of M1's jobs. A chunk is rebuilt only when its
    /// own tiles changed — and traffic, wear and supply change every day
    /// without changing a single triangle, so most days rebuild nothing. And
    /// a chunk off screen is never handed to the GPU. Chosen over instancing:
    /// a building is a couple of hundred triangles copied out of `Cache`, so
    /// instancing would buy little and cost the per-variant colours the
    /// vertices carry, where chunks buy both of the things that were measured
    /// as costing.
    private struct Chunk {
        var signature: Int
        var buffer: MTLBuffer?
        var vertexCount: Int
        /// Vertices that are ground; the rest are buildings.
        var groundCount: Int
        /// Whether its buildings carry the close-up detail.
        var near = false
        var lights: [Float]
        /// The tallest thing in it, for deciding whether it is on screen.
        var height: Float
        var region: MetalCityMesh.Region
        var signs: [Float] = []
        var signBuffer: MTLBuffer?
    }

    static let chunkSize = 8
    private var chunks: [Chunk] = []
    private var chunkGrid: (across: Int, down: Int, width: Int, height: Int) = (0, 0, 0, 0)

    /// The land beyond the map: one quad, remade only when the map's size
    /// changes, drawn under the chunks in the main pass only (it is ground,
    /// and ground is not reflected).
    private var backdrop: (buffer: MTLBuffer, vertexCount: Int, width: Int, height: Int)?

    /// How far the land carries on past the map's edge, in tiles — the same
    /// margin the Classic backdrop uses.
    static let backdropMargin: Float = 36

    private func updateBackdrop(for map: CityMap) {
        guard backdrop?.width != map.width || backdrop?.height != map.height else { return }
        let m = Self.backdropMargin, w = Float(map.width), h = Float(map.height)
        var vertices: [Float] = []
        // Below the water, not just below the land: rivers are sunk behind
        // quays, and a backdrop at street level would lid them over.
        let z: Float = -0.2
        MetalCityMesh.appendPolygon(
            [SIMD3(-m, -m, z), SIMD3(w + m, -m, z), SIMD3(w + m, h + m, z), SIMD3(-m, h + m, z)],
            normal: SIMD3(0, 0, 1), albedo: SIMD3(0.15, 0.12, 0.19) * 0.38, emissive: .zero, rim: .zero,
            ground: 4, into: &vertices)
        guard let buffer = device.makeBuffer(bytes: vertices, length: vertices.count * 4) else { return }
        backdrop = (buffer, vertices.count / GPUVertex.floatCount, map.width, map.height)
    }

    private static func makeSignAtlas(device: MTLDevice, queue: MTLCommandQueue) -> MTLTexture? {
        guard let image = MetalSigns.atlas(), let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: image.width, height: image.height, mipmapped: true)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: image.bytesPerRow)
        // Mipmaps, so a word seen from across the city averages to its glow
        // rather than sparkling.
        if let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
        }
        return texture
    }

    /// Whether the sign lettering loaded, for the test that a missing atlas
    /// is noticed rather than silently drawing nothing.
    var hasSignAtlas: Bool { signAtlas != nil }

    private func storeSigns(_ signs: [Float], at index: Int) {
        chunks[index].signs = signs
        chunks[index].signBuffer = signs.isEmpty ? nil
            : device.makeBuffer(bytes: signs, length: signs.count * 4)
    }

    /// What the last `update` did, for the timing tests.
    private(set) var chunksRebuiltLastUpdate = 0
    /// How many building variants have been generated so far — a miss on the
    /// cache is massing generated on the frame that needed it.
    var cachedBuildingCount: Int { cache.entries.count }

    /// Everything about a chunk's tiles that decides what it draws — and
    /// nothing that does not. Read one tile past the edge, because a lane
    /// line is a statement about its neighbours.
    private static func signature(of region: MetalCityMesh.Region, in map: CityMap) -> Int {
        var hasher = Hasher()
        // Three tiles past the edge: a lane line reads its neighbours, and a
        // building's height reads the density of everything within three
        // tiles (`MetalCityMesh.heightScale`), so a neighbour growing has to
        // rebuild this chunk too.
        for y in max(0, region.y0 - 3) ..< min(map.height, region.y1 + 3) {
            for x in max(0, region.x0 - 3) ..< min(map.width, region.x1 + 3) {
                let position = GridPosition(x: x, y: y)
                let tile = map[position]
                hasher.combine(tile.zone)
                hasher.combine(tile.density)
                hasher.combine(tile.isWater)
                hasher.combine(tile.buildingOrigin.x)
                hasher.combine(tile.buildingOrigin.y)
                hasher.combine(map.isOwned(position))
            }
        }
        return hasher.finalize()
    }

    /// Brings the city's chunks up to date with `map`. `revision` is
    /// `GameController.mapRevision`; `nil` always checks, which is what a
    /// test taking one picture wants.
    func update(_ map: CityMap, revision: Int?) {
        // Reduce Motion changes what is drawn without changing the map, so no
        // revision will ever announce it; the plan is asked again when it moves.
        if VisualStyle.reduceMotion != plannedReduceMotion {
            plannedReduceMotion = VisualStyle.reduceMotion
            builtRevision = nil
        }
        if let revision, revision == builtRevision { return }
        builtRevision = revision
        lastMap = map
        mapExtent = Float(map.width + map.height + 20 + 4 * Int(Self.backdropMargin))
        mapSizePacked = UInt32(map.width) | (UInt32(map.height) << 16)
        updateBackdrop(for: map)
        let size = Self.chunkSize
        let across = (map.width + size - 1) / size, down = (map.height + size - 1) / size
        if chunkGrid != (across, down, map.width, map.height) {
            chunkGrid = (across, down, map.width, map.height)
            chunks = (0 ..< across * down).map { index in
                let cx = index % across, cy = index / across
                return Chunk(signature: 0, buffer: nil, vertexCount: 0, groundCount: 0, lights: [], height: 0,
                             region: .init(x0: cx * size, y0: cy * size,
                                           x1: min(map.width, (cx + 1) * size),
                                           y1: min(map.height, (cy + 1) * size)))
            }
        }
        var rebuilt = 0
        for index in chunks.indices {
            let signature = Self.signature(of: chunks[index].region, in: map)
            guard signature != chunks[index].signature || chunks[index].buffer == nil else { continue }
            let built = MetalCityMesh.build(map, cache: cache, region: chunks[index].region, near: nearDetail)
            let count = built.vertices.count / GPUVertex.floatCount
            var height: Float = 0
            var z = 2
            while z < built.vertices.count { height = max(height, built.vertices[z]); z += GPUVertex.floatCount }
            chunks[index] = Chunk(
                signature: signature,
                buffer: count == 0 ? nil : device.makeBuffer(bytes: built.vertices, length: built.vertices.count * 4),
                vertexCount: count, groundCount: built.groundFloats / GPUVertex.floatCount,
                lights: built.lights, height: height, region: chunks[index].region)
            chunks[index].near = nearDetail
            storeSigns(built.signs, at: index)
            rebuilt += 1
        }
        chunksRebuiltLastUpdate = rebuilt
        if rebuilt > 0 { allLights = chunks.flatMap(\.lights) }
        // **The motion plan moves when the city does**: a new day (traffic is
        // re-routed every tick) or something built or bulldozed. A write that
        // changes neither — and an unchanged city asked again, which is what
        // the budget test's quiet update is — costs nothing here.
        // A tram line drawn or a fire started while paused moves neither.
        var routes = Hasher()
        for route in map.transit.routes(mode: .tram) { for stop in route.stops { routes.combine(stop) } }
        let motionKey = MotionKey(day: map.elapsedDays, showsTraffic: motion.showsTraffic,
                                  overlay: overlayMode,
                                  reduceMotion: VisualStyle.reduceMotion,
                                  fires: map.tiles.reduce(0) { $0 + ($1.isBurning ? 1 : 0) },
                                  routes: routes.finalize())
        if rebuilt > 0 || motionKey != plannedMotion {
            plannedMotion = motionKey
            motion.buildingHeight = { [unowned self] in self.buildingHeight($0) }
            motion.overlayActive = overlayMode != .none
            motion.update(map, clock: lastMotionClock, reduceMotion: VisualStyle.reduceMotion)
        }
        // The view is rebuilt on every change of the map, because anything
        // can change what a view says — a pipe laid while paused, a building
        // finishing a storey.
        overlay.height = { [unowned self] in self.buildingHeight(zone: $0, density: $1, at: $2) }
        overlay.update(map, mode: overlayMode)
        overlayTint = makeTint(width: map.width, height: map.height)
        // Uploaded here, once per change of the map, rather than every frame:
        // a view is one instance per tile, and copying a whole map's worth to
        // the GPU 120 times a second to draw something that changes once a
        // day was the largest per-frame cost that grew with the city.
        func upload(_ floats: [Float]) -> MTLBuffer? {
            floats.isEmpty ? nil : device.makeBuffer(bytes: floats, length: floats.count * 4)
        }
        overlayBuffers = (upload(overlay.tiles), upload(overlay.traces), upload(overlay.schematic),
                          upload(overlay.billboards))
    }

    // MARK: - Close-up detail

    /// Whether buildings are drawn with their close-up marks. Chosen from the
    /// camera in pixels per tile, with the hysteresis SpriteKit's detail tier
    /// has for the same reason: one number read in both directions makes a
    /// pinch resting on the boundary flip the whole city back and forth.
    private(set) var nearDetail = false
    static let nearEngages: Float = 178
    static let nearReleases: Float = 164
    private var lastMap: CityMap?

    /// Moves the detail tier to suit `camera`, and rebuilds up to `budget`
    /// chunks that are on the wrong one — the ones on screen first. `nil`
    /// rebuilds them all, which is what a still picture wants.
    ///
    /// **Spread over frames**, because crossing the threshold asks every
    /// visible building for a variant it may never have built, and SpriteKit
    /// measured that as a 49 ms frame before it learned to spread the same
    /// work (`pendingRefresh`).
    func settleDetail(for camera: Camera, budget: Int?) {
        let pixelsPerTile = Float(projection.tileWidth / camera.scale)
        if nearDetail, pixelsPerTile < Self.nearReleases { nearDetail = false }
        if !nearDetail, pixelsPerTile >= Self.nearEngages { nearDetail = true }
        guard let map = lastMap else { return }
        let matrix = viewProjection(for: camera, mapExtent: mapExtent)
        var stale = chunks.indices.filter { chunks[$0].near != nearDetail && chunks[$0].vertexCount > 0 }
        guard !stale.isEmpty else { return }
        stale.sort { isVisible(chunks[$0], through: matrix, mirrored: false)
            && !isVisible(chunks[$1], through: matrix, mirrored: false) }
        for index in stale.prefix(budget ?? stale.count) {
            let built = MetalCityMesh.build(map, cache: cache, region: chunks[index].region, near: nearDetail)
            let count = built.vertices.count / GPUVertex.floatCount
            chunks[index].buffer = count == 0 ? nil
                : device.makeBuffer(bytes: built.vertices, length: built.vertices.count * 4)
            chunks[index].vertexCount = count
            chunks[index].groundCount = built.groundFloats / GPUVertex.floatCount
            chunks[index].lights = built.lights
            chunks[index].near = nearDetail
            storeSigns(built.signs, at: index)
        }
        allLights = chunks.flatMap(\.lights)
    }

    /// What one chunk holds, read back off the GPU, for `MetalAgreement` —
    /// the test that a renderer updated change by change holds exactly what
    /// one built fresh from the same city would.
    struct ChunkSnapshot: Equatable {
        let x0, y0, x1, y1: Int
        let vertices: [Float]
        let groundCount: Int
        let lights: [Float]
        let signs: [Float]
    }

    func chunksForTesting() -> [ChunkSnapshot] {
        chunks.map { chunk in
            let count = chunk.vertexCount * GPUVertex.floatCount
            let floats = chunk.buffer.map {
                Array(UnsafeBufferPointer(start: $0.contents().bindMemory(to: Float.self, capacity: count),
                                          count: count))
            } ?? []
            return ChunkSnapshot(x0: chunk.region.x0, y0: chunk.region.y0, x1: chunk.region.x1,
                                 y1: chunk.region.y1, vertices: floats,
                                 groundCount: chunk.groundCount, lights: chunk.lights, signs: chunk.signs)
        }
    }

    /// Is any of this chunk on screen? Its box, top to bottom, projected — or
    /// mirrored under the street for the reflection pass.
    private func isVisible(_ chunk: Chunk, through matrix: simd_float4x4, mirrored: Bool) -> Bool {
        // Padded toward +x and +y by the widest footprint less one: a 3×3
        // building anchored at a chunk's last column reaches two tiles into the
        // next, and tested on its own region its chunk went off screen while
        // the overhang was still in view — buildings popped at the edges.
        let pad = 2
        let r = MetalCityMesh.Region(x0: chunk.region.x0, y0: chunk.region.y0,
                                     x1: chunk.region.x1 + pad, y1: chunk.region.y1 + pad)
        let low: Float = mirrored ? -chunk.height : 0, high: Float = mirrored ? 0 : chunk.height
        var minX = Float.infinity, maxX = -Float.infinity, minY = Float.infinity, maxY = -Float.infinity
        for x in [Float(r.x0), Float(r.x1)] {
            for y in [Float(r.y0), Float(r.y1)] {
                for z in [low, high] {
                    let clip = matrix * SIMD4(x, y, z, 1)
                    minX = min(minX, clip.x); maxX = max(maxX, clip.x)
                    minY = min(minY, clip.y); maxY = max(maxY, clip.y)
                }
            }
        }
        return maxX >= -1.05 && minX <= 1.05 && maxY >= -1.05 && minY <= 1.05
    }

    /// Stages to leave out, for measuring what each one costs. Only the
    /// timing tests set these; a frame drawn with any of them set is wrong.
    struct Diagnostics {
        var skipReflection = false
        var skipPointLights = false
        var skipBloom = false
    }
    var diagnostics = Diagnostics()

    /// CPU spent preparing the last frame: light cull, chunk cull, encoding.
    private(set) var lastEncodeMilliseconds: Double = 0

    /// Triangles handed to the GPU on the last frame, after the chunk cull.
    private(set) var trianglesDrawnLastFrame = 0

    /// Only the lights that can reach what is on screen, and at most
    /// `maximumLights` of them.
    ///
    /// **A stopgap until M1's tiled culling**, and an honest one: every pixel
    /// still checks every light it is handed, so the count handed over is the
    /// cost. A light whose reach does not touch the view cannot change a
    /// visible pixel, so dropping it is free — and on a zoomed-in view of a
    /// big city that is almost all of them.
    ///
    /// **Moving lights first.** A fire, an engine's beacon, a ship's deck
    /// lights: when the frame or a screen tile runs out of room, the lights
    /// listed first are the ones kept, and these are the ones that matter most
    /// — a fire nobody can see lighting its street is a fire that reads as a
    /// flat decal. The two lists are scanned in turn rather than joined, so
    /// the city's thousands of static lights are not copied every frame.
    private func visibleLights(_ sources: [[Float]], through matrix: simd_float4x4, camera: Camera) -> [Float] {
        let pixelsPerTile = Float(projection.tileWidth / camera.scale)
        var kept: [Float] = []
        let stride = GPULight.floatCount
        for lights in sources {
            var index = 0
            while index + stride <= lights.count, kept.count / stride < Self.maximumLights {
                let p = SIMD4<Float>(lights[index], lights[index + 1], lights[index + 2], 1)
                let clip = matrix * p
                // How far the light reaches, in normalised screen units.
                let reach = lights[index + 3] * pixelsPerTile / Float(camera.size.width) * 2 + 0.05
                if abs(clip.x) <= 1 + reach && abs(clip.y) <= 1 + reach * 2 {
                    kept.append(contentsOf: lights[index ..< index + stride])
                }
                index += stride
            }
        }
        return kept
    }

    /// Lights handed to the GPU per frame, after the view cull. Generous now
    /// that the tile cull decides what each pixel actually looks at.
    static let maximumLights = 4096

    /// Screen tile edge for light culling, in pixels.
    static let tileSize = 32
    /// Must match `maxLightsPerTile` in MetalCity.metal.
    static let maxLightsPerTile = 64

    struct CullParams {
        var viewProjection: simd_float4x4
        var viewportAndExtent: SIMD4<Float>
        var counts: SIMD4<UInt32>
    }

    // MARK: - Frame resources

    private struct Targets {
        let size: CGSize
        let reflection: MTLTexture
        let reflectionDepth: MTLTexture
        let msaa: MTLTexture
        let msaaDepth: MTLTexture
        let hdr: MTLTexture
        let bloom: [MTLTexture]
        let tilesAcross: Int
        let tilesDown: Int
        let tileCounts: MTLBuffer
        let tileLights: MTLBuffer
    }

    private var targets: Targets?

    /// Offscreen textures for a frame of `size`, remade only when it changes.
    ///
    /// The MSAA colour and depth are **memoryless**: on Apple Silicon a
    /// render pass happens in on-chip tile memory, and a texture that is only
    /// ever resolved or discarded never needs to exist in RAM at all. That is
    /// why 4× anti-aliasing is nearly free on these GPUs.
    private func targets(for size: CGSize) -> Targets? {
        if let targets, targets.size == size { return targets }
        let width = Int(size.width), height = Int(size.height)
        func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, samples: Int = 1,
                     usage: MTLTextureUsage, storage: MTLStorageMode = .private) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: max(1, w), height: max(1, h), mipmapped: false)
            descriptor.textureType = samples > 1 ? .type2DMultisample : .type2D
            descriptor.sampleCount = samples
            descriptor.usage = usage
            descriptor.storageMode = storage
            return device.makeTexture(descriptor: descriptor)
        }
        let target: MTLTextureUsage = [.renderTarget, .shaderRead]
        // The reflection is blurred by the street anyway, so half size is
        // indistinguishable and a quarter of the cost.
        guard let reflection = texture(.rgba16Float, width / 2, height / 2, usage: target),
              let reflectionDepth = texture(.depth32Float, width / 2, height / 2, usage: .renderTarget,
                                            storage: .memoryless),
              let msaa = texture(.rgba16Float, width, height, samples: Self.sampleCount,
                                 usage: .renderTarget, storage: .memoryless),
              let msaaDepth = texture(.depth32Float, width, height, samples: Self.sampleCount,
                                      usage: .renderTarget, storage: .memoryless),
              let hdr = texture(.rgba16Float, width, height, usage: target)
        else { return nil }
        var bloom: [MTLTexture] = []
        var w = width / 2, h = height / 2
        for _ in 0 ..< 5 {
            guard let level = texture(.rgba16Float, w, h, usage: [.shaderRead, .shaderWrite]) else { return nil }
            bloom.append(level)
            w = max(1, w / 2); h = max(1, h / 2)
        }
        let tilesAcross = (width + Self.tileSize - 1) / Self.tileSize
        let tilesDown = (height + Self.tileSize - 1) / Self.tileSize
        guard let tileCounts = device.makeBuffer(length: tilesAcross * tilesDown * 4, options: .storageModePrivate),
              let tileLights = device.makeBuffer(length: tilesAcross * tilesDown * Self.maxLightsPerTile * 4,
                                                 options: .storageModePrivate)
        else { return nil }
        let made = Targets(size: size, reflection: reflection, reflectionDepth: reflectionDepth,
                           msaa: msaa, msaaDepth: msaaDepth, hdr: hdr, bloom: bloom,
                           tilesAcross: tilesAcross, tilesDown: tilesDown,
                           tileCounts: tileCounts, tileLights: tileLights)
        targets = made
        return made
    }

    /// The view's building wash as a small texture, one texel a tile.
    private func makeTint(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: max(1, width), height: max(1, height), mipmapped: false)
        descriptor.usage = .shaderRead
        guard overlay.tint.count == width * height * 4,
              let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        overlay.tint.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * 16)
        }
        return texture
    }

    // MARK: - Drawing

    /// The ground the camera can see, as a rectangle in tile units — where
    /// rain falls. Stretched toward the viewer by the height drops fall from,
    /// because a drop high over ground just below the screen is on screen.
    private func rainArea(for camera: Camera) -> SIMD4<Float> {
        let halfWidth = projection.tileWidth / 2, halfHeight = projection.tileHeight / 2
        let spanX = camera.size.width / 2 * camera.scale, spanY = camera.size.height / 2 * camera.scale
        var xs: [CGFloat] = [], ys: [CGFloat] = []
        for sx in [-spanX, spanX] {
            for sy in [-spanY, spanY] {
                let a = (camera.centre.x + sx) / halfWidth       // x - y
                let b = -(camera.centre.y + sy) / halfHeight     // x + y
                xs.append((a + b) / 2); ys.append((b - a) / 2)
            }
        }
        let reach = 7 * projection.heightUnit / halfHeight / 2
        let x0 = xs.min()! - 1, y0 = ys.min()! - 1
        let x1 = xs.max()! + reach + 1, y1 = ys.max()! + reach + 1
        return SIMD4(Float(x0), Float(y0), Float(x1 - x0), Float(y1 - y0))
    }

    /// Encodes one whole frame into `output`, which is either the live view's
    /// drawable or a readable texture a test will copy out.
    @discardableResult
    private func encode(into commands: MTLCommandBuffer, output: MTLTexture, camera: Camera,
                        wetness: Float, time: Float, motionClock: Double,
                        rainfall: Float) -> (triangles: Int, lights: Int)? {
        let encodeStarted = DispatchTime.now().uptimeNanoseconds
        defer {
            lastEncodeMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - encodeStarted) / 1e6
        }
        guard chunks.contains(where: { $0.vertexCount > 0 }), let targets = targets(for: camera.size) else { return nil }
        let matrix = viewProjection(for: camera, mapExtent: mapExtent)
        lastMotionClock = motionClock
        let moving = motion.frame(at: motionClock, near: nearDetail)
        let lights = diagnostics.skipPointLights ? []
            : visibleLights([moving.lights, allLights], through: matrix, camera: camera)
        let lightCount = lights.count / GPULight.floatCount
        var uniforms = Uniforms(
            viewProjection: matrix,
            frame: SIMD4(Float(camera.size.width), Float(camera.size.height), wetness, 0),
            moonAndTime: SIMD4(SIMD3<Float>(-0.35, 0.55, 0.76), time),
            counts: SIMD4(UInt32(lightCount), UInt32(targets.tilesAcross), UInt32(Self.tileSize), mapSizePacked),
            overlay: SIMD4(overlayMode != .none && overlayTint != nil ? 1 : 0,
                           Float(motionClock.truncatingRemainder(dividingBy: 10_000)),
                           // Rain falling now, for the rings it makes on the
                           // wet street. Off with Reduce Motion, like the drops.
                           VisualStyle.reduceMotion ? 0 : rainfall, 0),
            // **No fog under a view.** A view answers one question with
            // colour, and sunset-tinted air pulled Power's "wanting" and "not
            // applicable" together for a colourblind eye — measured by
            // `testTheRenderedViewsKeepTheirMeaningsApart`, which failed the
            // day the retrowave look became the default. Atmosphere describes
            // the city; a view hides what describes the city.
            fog: overlayMode == .none
                ? SIMD4(look.lowFog, look.fogHeight, look.distanceHaze, look.streetGloss)
                : SIMD4(0, 1, 0, look.streetGloss),
            zenith: SIMD4(look.zenith, min(1, max(0, 64 / Float(projection.tileWidth / camera.scale)))),
            horizon: SIMD4(look.horizon, look.groundGloss)
        )
        let lightData = lights.isEmpty ? [Float](repeating: 0, count: GPULight.floatCount) : lights
        guard let lightBuffer = device.makeBuffer(bytes: lightData, length: lightData.count * 4) else { return nil }

        // What moves this frame, on the GPU. Small: a few thousand traces and
        // a ship or two.
        let traceCount = moving.traces.count / MetalMotion.traceFloatCount
        let traceBuffer = traceCount == 0 ? nil
            : device.makeBuffer(bytes: moving.traces, length: moving.traces.count * 4)
        let hideBuildings = overlayMode != .none && overlay.hidesBuildings
        let overlayTileBuffer = overlayBuffers.tiles
        let overlayTileCount = overlay.tiles.count / MetalOverlay.tileFloatCount
        let scaffoldBuffer = overlayBuffers.scaffolds
        let scaffoldCount = overlay.traces.count / MetalMotion.traceFloatCount
        let schematicBuffer = overlayBuffers.schematic
        let schematicCount = overlay.schematic.count / MetalMotion.traceFloatCount
        let billboardBuffer = overlayBuffers.billboards
        let billboardCount = overlay.billboards.count / MetalOverlay.billboardFloatCount
        let flameCount = moving.flames.count / MetalMotion.traceFloatCount
        let flameBuffer = flameCount == 0 ? nil
            : device.makeBuffer(bytes: moving.flames, length: moving.flames.count * 4)
        let solidCount = moving.solids.count / GPUVertex.floatCount
        let solidBuffer = solidCount == 0 ? nil
            : device.makeBuffer(bytes: moving.solids, length: moving.solids.count * 4)
        let emitters = motion.smokeEmitters
        let smokeBuffer = emitters.isEmpty ? nil
            : device.makeBuffer(bytes: emitters, length: emitters.count * MemoryLayout<SIMD4<Float>>.stride)
        let smokePerEmitter = 20
        let rainArea = rainArea(for: camera)
        let drops = VisualStyle.reduceMotion || rainfall <= 0 ? 0
            : min(9000, Int(rainArea.z * rainArea.w * 3 * rainfall))
        var skyParams = skyParams(through: matrix, camera: camera)
        var motionUniforms = MotionUniforms(
            viewProjection: matrix,
            frame: SIMD4(Float(camera.size.width), Float(camera.size.height),
                         Float(projection.tileWidth / camera.scale) * 0.7, 0),
            area: rainArea,
            params: SIMD4(Float(motionClock.truncatingRemainder(dividingBy: 10_000)), rainfall,
                          Float(smokePerEmitter), 0))

        // Cull first: every tile's list of the lights that can reach it.
        // How far one tile of light radius reaches on screen, in pixels: the
        // projection stretches x and y differently, so the box is too.
        let pointsX = projection.tileWidth / 2 * 2.squareRoot()
        let pointsY = ((projection.tileHeight / 2) * (projection.tileHeight / 2) * 2
            + projection.heightUnit * projection.heightUnit).squareRoot()
        var cull = CullParams(
            viewProjection: matrix,
            viewportAndExtent: SIMD4(Float(camera.size.width), Float(camera.size.height),
                                     Float(pointsX / camera.scale), Float(pointsY / camera.scale)),
            counts: SIMD4(UInt32(lightCount), UInt32(targets.tilesAcross), UInt32(targets.tilesDown),
                          UInt32(Self.tileSize))
        )
        if let culling = commands.makeComputeCommandEncoder() {
            culling.setComputePipelineState(cullPipeline)
            culling.setBuffer(lightBuffer, offset: 0, index: 0)
            culling.setBytes(&cull, length: MemoryLayout<CullParams>.stride, index: 1)
            culling.setBuffer(targets.tileCounts, offset: 0, index: 2)
            culling.setBuffer(targets.tileLights, offset: 0, index: 3)
            let tiles = targets.tilesAcross * targets.tilesDown
            culling.dispatchThreadgroups(MTLSize(width: (tiles + 63) / 64, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            culling.endEncoding()
        }

        var drawn = 0
        func scenePass(into color: MTLTexture, depth: MTLTexture, resolve: MTLTexture?, mirrored: Bool) {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = color
            pass.colorAttachments[0].loadAction = .clear
            // Alpha is height in the reflection pass, so empty sky clears to
            // zero — at one it would blur like the top of a tower.
            pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(look.zenith.x), green: Double(look.zenith.y),
                                                                blue: Double(look.zenith.z),
                                                                alpha: mirrored ? 0 : 1)
            if let resolve {
                pass.colorAttachments[0].resolveTexture = resolve
                pass.colorAttachments[0].storeAction = .multisampleResolve
            } else {
                pass.colorAttachments[0].storeAction = .store
            }
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 1
            pass.depthAttachment.storeAction = .dontCare
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.setRenderPipelineState(mirrored ? reflectionPipeline : scenePipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setCullMode(.none)
            uniforms.frame.w = mirrored ? 1 : 0
            // The shader reads the frame size to find its place in the
            // reflection texture, which is the *full* frame's size even when
            // the reflection itself is drawn at half.
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBuffer(lightBuffer, offset: 0, index: 2)
            encoder.setFragmentBuffer(targets.tileCounts, offset: 0, index: 3)
            encoder.setFragmentBuffer(targets.tileLights, offset: 0, index: 4)
            encoder.setFragmentTexture(mirrored ? placeholder : targets.reflection, index: 0)
            encoder.setFragmentTexture(overlayTint ?? placeholder, index: 1)
            if !mirrored {
                // The sky first, at the far plane and writing no depth, so
                // everything drawn after lands on top of it.
                encoder.setRenderPipelineState(skyPipeline)
                encoder.setDepthStencilState(readOnlyDepthState)
                encoder.setFragmentBytes(&skyParams, length: MemoryLayout<SkyParams>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.setRenderPipelineState(scenePipeline)
                encoder.setDepthStencilState(depthState)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            }
            if !mirrored, let backdrop {
                encoder.setVertexBuffer(backdrop.buffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: backdrop.vertexCount)
                // The sun over the land past the map and under the city.
                encoder.setRenderPipelineState(sunPipeline)
                encoder.setDepthStencilState(alwaysDepthState)
                encoder.setVertexBytes(&skyParams, length: MemoryLayout<SkyParams>.stride, index: 0)
                encoder.setFragmentBytes(&skyParams, length: MemoryLayout<SkyParams>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                encoder.setRenderPipelineState(scenePipeline)
                encoder.setDepthStencilState(depthState)
            }
            // One draw per visible chunk: the ones off screen never reach the
            // GPU at all.
            for chunk in chunks where chunk.vertexCount > 0 {
                guard let buffer = chunk.buffer, isVisible(chunk, through: matrix, mirrored: mirrored)
                else { continue }
                // A heatmap's data is on the ground, and a tower would hide it.
                let count = hideBuildings ? chunk.groundCount : chunk.vertexCount
                guard count > 0 else { continue }
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
                if !mirrored { drawn += count / 3 }
            }
            // Ships are lit geometry like the city they sail through.
            if let solidBuffer {
                encoder.setVertexBuffer(solidBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: solidCount)
            }
            motionUniforms.frame.w = mirrored ? 1 : 0
            encoder.setDepthStencilState(readOnlyDepthState)
            encoder.setVertexBytes(&motionUniforms, length: MemoryLayout<MotionUniforms>.stride, index: 1)
            // Smoke hides what is behind it, so it goes under the light.
            // Neither smoke nor rain is reflected: both are in the air, and a
            // mirrored copy of either reads as noise on the street.
            if !mirrored, let smokeBuffer {
                encoder.setRenderPipelineState(smokePipeline)
                encoder.setVertexBuffer(smokeBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                       instanceCount: emitters.count * smokePerEmitter)
            }
            if let flameBuffer {
                // In the reflection a flame is only light on the water, so it
                // is added there like everything else.
                encoder.setRenderPipelineState(mirrored ? traceReflectionPipeline : flamePipeline)
                encoder.setVertexBuffer(flameBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: flameCount)
            }
            if let traceBuffer {
                encoder.setRenderPipelineState(mirrored ? traceReflectionPipeline : tracePipeline)
                encoder.setVertexBuffer(traceBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: traceCount)
            }
            // Neon lettering, as light: hidden by what stands in front of it,
            // and reflected in a wet street like any other light. A view hides
            // it with the flames — it describes the building, not the answer.
            if !hideBuildings, overlayMode == .none, let signAtlas {
                encoder.setRenderPipelineState(mirrored ? signReflectionPipeline : signPipeline)
                encoder.setFragmentTexture(signAtlas, index: 0)
                for chunk in chunks where !chunk.signs.isEmpty {
                    guard let buffer = chunk.signBuffer, isVisible(chunk, through: matrix, mirrored: mirrored)
                    else { continue }
                    encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                           instanceCount: chunk.signs.count / MetalSigns.floatCount)
                }
            }
            if !mirrored, drops > 0 {
                encoder.setRenderPipelineState(rainPipeline)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: drops)
            }
            if !mirrored {
                // The view's light on the ground, under what is standing on it.
                if let overlayTileBuffer {
                    encoder.setRenderPipelineState(overlayTilePipeline)
                    encoder.setVertexBuffer(overlayTileBuffer, offset: 0, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                           instanceCount: overlayTileCount)
                }
                if let scaffoldBuffer {
                    encoder.setRenderPipelineState(tracePipeline)
                    encoder.setVertexBuffer(scaffoldBuffer, offset: 0, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                           instanceCount: scaffoldCount)
                }
                // Over everything: a pipe run in the Water view and a badge
                // are what the player came to find.
                encoder.setDepthStencilState(alwaysDepthState)
                if let schematicBuffer {
                    encoder.setRenderPipelineState(tracePipeline)
                    encoder.setVertexBuffer(schematicBuffer, offset: 0, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                           instanceCount: schematicCount)
                }
                if let billboardBuffer, let glyphAtlas {
                    encoder.setRenderPipelineState(billboardPipeline)
                    encoder.setVertexBuffer(billboardBuffer, offset: 0, index: 0)
                    encoder.setFragmentTexture(glyphAtlas, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                           instanceCount: billboardCount)
                }
            }
            encoder.endEncoding()
        }

        if !diagnostics.skipReflection {
            scenePass(into: targets.reflection, depth: targets.reflectionDepth, resolve: nil, mirrored: true)
        }
        scenePass(into: targets.msaa, depth: targets.msaaDepth, resolve: targets.hdr, mirrored: false)

        guard let compute = commands.makeComputeCommandEncoder() else { return nil }
        func dispatch(_ pipeline: MTLComputePipelineState, over texture: MTLTexture) {
            let group = MTLSize(width: 8, height: 8, depth: 1)
            let grid = MTLSize(width: (texture.width + 7) / 8, height: (texture.height + 7) / 8, depth: 1)
            compute.setComputePipelineState(pipeline)
            compute.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
        }
        var threshold: Float = 1.0
        var source: MTLTexture = targets.hdr
        for level in targets.bloom where !diagnostics.skipBloom {
            compute.setTexture(source, index: 0)
            compute.setTexture(level, index: 1)
            compute.setBytes(&threshold, length: 4, index: 0)
            dispatch(bloomDown, over: level)
            threshold = 0
            source = level
        }
        // The haze: the second-widest level, which by now also carries the
        // widest one added into it on the way up — the broadest, softest light
        // in the chain, which is what reads as wet air.
        let haze = targets.bloom[3]
        for index in stride(from: targets.bloom.count - 1, to: 0, by: -1) where !diagnostics.skipBloom {
            compute.setTexture(targets.bloom[index], index: 0)
            compute.setTexture(targets.bloom[index - 1], index: 1)
            dispatch(bloomUp, over: targets.bloom[index - 1])
        }
        var composite = settings
        // **Bloom and haze follow the camera.** Pulled back, three times as
        // many lights land in every region of the frame, and at one strength
        // they summed to a white veil over the whole city; at the resting
        // camera the strength is what M1 tuned it to.
        let pixelsPerTile = Float(projection.tileWidth / camera.scale)
        let zoomFactor = min(1, max(0.4, pixelsPerTile / 128))
        composite.bloomStrength *= zoomFactor
        composite.hazeStrength *= zoomFactor * zoomFactor
        compute.setTexture(targets.hdr, index: 0)
        compute.setTexture(targets.bloom[0], index: 1)
        compute.setTexture(haze, index: 2)
        compute.setTexture(output, index: 3)
        compute.setBytes(&composite, length: MemoryLayout<CompositeSettings>.stride, index: 0)
        dispatch(compositePipeline, over: output)
        compute.endEncoding()
        trianglesDrawnLastFrame = drawn
        return (drawn, lightCount)
    }

    /// Frames actually handed to the display, for the test that checks the
    /// live path draws at all — it writes into a drawable, which the picture
    /// path used by every other test never touches.
    private(set) var framesPresented = 0

    /// One frame into the live view.
    func draw(in view: MTKView, camera: Camera, wetness: Float, time: Float,
              motionClock: Double, rainfall: Float) {
        settleDetail(for: camera, budget: 4)
        guard let drawable = view.currentDrawable, let commands = queue.makeCommandBuffer(),
              encode(into: commands, output: drawable.texture, camera: camera,
                     wetness: wetness, time: time, motionClock: motionClock, rainfall: rainfall) != nil
        else { return }
        commands.present(drawable)
        commands.commit()
        framesPresented += 1
    }

    struct Frame {
        let image: CGImage
        let gpuMilliseconds: Double
        let triangles: Int
        let lights: Int
    }

    /// One frame into a picture, for the render tests.
    func render(_ map: CityMap, camera: Camera, wetness: Float, time: Float = 0,
                motionClock: Double? = nil, rainfall: Float = 0) -> Frame? {
        lastMotionClock = motionClock ?? Double(time)
        update(map, revision: nil)
        settleDetail(for: camera, budget: nil)
        let width = Int(camera.size.width), height = Int(camera.size.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .shared
        guard let output = device.makeTexture(descriptor: descriptor),
              let commands = queue.makeCommandBuffer(),
              let counts = encode(into: commands, output: output, camera: camera, wetness: wetness, time: time,
                                  motionClock: motionClock ?? Double(time), rainfall: rainfall)
        else { return nil }
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { return nil }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        output.getBytes(&bytes, bytesPerRow: width * 4,
                        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent)
        else { return nil }
        return Frame(image: image,
                     gpuMilliseconds: (commands.gpuEndTime - commands.gpuStartTime) * 1000,
                     triangles: counts.triangles, lights: counts.lights)
    }
}

// MARK: - The mesh

/// The city as triangles and lights, from the same data the game draws.
enum MetalCityMesh {

    struct Built {
        var vertices: [Float] = []
        var lights: [Float] = []
        /// How many of `vertices`' floats are ground — streets, land, water —
        /// with the buildings after them, so a view that hides buildings can
        /// draw the first part alone.
        var groundFloats = 0
        /// Neon lettering, `MetalSigns.floatCount` floats a sign, drawn as
        /// light over the city rather than as part of it.
        var signs: [Float] = []
    }

    /// Every distinct building, turned into triangles once.
    ///
    /// The same idea as `IsoTextureCache`, one level up: a lot draws one of a
    /// fixed set of variants per zone and density, so the massing for that
    /// variant is generated once and every lot that draws it copies the
    /// floats, offset to where it stands. Stored relative to the lot's corner.
    final class Cache {
        struct Key: Hashable {
            let zone: ZoneType; let density: Int; let variant: Int
            /// With the marks a building gains up close — mullions and slab
            /// lines, `IsometricBuilding.nearDetail`.
            var near = false
        }
        var entries: [Key: Built] = [:]
    }

    /// sRGB colour to linear light. Every colour in this project was picked
    /// as an sRGB value on a screen; lighting maths has to happen in linear,
    /// or every blend and every falloff comes out wrong.
    ///
    /// Almost every colour in the palette is built with `srgbRed:` already,
    /// and asking AppKit to convert one into the space it is in costs a few
    /// microseconds — which, once per tile, was most of the 13 ms a view took
    /// to repaint on Apex. Those skip the conversion.
    static func linear(_ color: SKColor) -> SIMD3<Float> {
        let c = color.colorSpace == .sRGB ? color : (color.usingColorSpace(.sRGB) ?? color)
        func f(_ v: CGFloat) -> Float { powf(max(0, Float(v)), 2.2) }
        return SIMD3(f(c.redComponent), f(c.greenComponent), f(c.blueComponent))
    }

    static func luminance(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    /// A polygon, fanned into triangles. Quads carry a uv and a size so the
    /// shader can put neon on their edges; anything else does not.
    static func appendPolygon(_ points: [SIMD3<Float>], normal: SIMD3<Float>, albedo: SIMD3<Float>,
                              emissive: SIMD3<Float>, rim: SIMD3<Float>, ground: Float,
                              into vertices: inout [Float]) {
        guard points.count >= 3 else { return }
        let isQuad = points.count == 4
        let size = isQuad
            ? SIMD2(simd_length(points[1] - points[0]), simd_length(points[3] - points[0]))
            : SIMD2<Float>(0, 0)
        let uvs: [SIMD2<Float>] = isQuad ? [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
                                         : Array(repeating: SIMD2(0.5, 0.5), count: points.count)
        for index in 1 ..< points.count - 1 {
            for corner in [0, index, index + 1] {
                vertices += MetalCityRenderer.GPUVertex(
                    position: points[corner], normal: normal, albedo: albedo, emissive: emissive,
                    rim: rim, uv: uvs[corner], size: size, ground: ground).floats
            }
        }
    }

    /// The tiles `build` covers: the whole map, or one chunk of it.
    struct Region {
        var x0, y0, x1, y1: Int   // half-open
        static func whole(_ map: CityMap) -> Region { Region(x0: 0, y0: 0, x1: map.width, y1: map.height) }
        func contains(_ p: GridPosition) -> Bool { p.x >= x0 && p.x < x1 && p.y >= y0 && p.y < y1 }
    }

    static func build(_ map: CityMap, cache: Cache = Cache(), region: Region? = nil,
                      near: Bool = false) -> Built {
        let region = region ?? .whole(map)
        let tilesInRegion: [Tile] = (region.y0 ..< region.y1).flatMap { y in
            (region.x0 ..< region.x1).map { x in map[GridPosition(x: x, y: y)] }
        }
        var built = Built()
        func addLight(_ at: SIMD3<Float>, _ color: SIMD3<Float>, radius: Float) {
            built.lights += MetalCityRenderer.GPULight(position: at, radius: radius, color: color).floats
        }

        func polygon(_ points: [SIMD3<Float>], normal: SIMD3<Float>, albedo: SIMD3<Float>,
                     emissive: SIMD3<Float> = .zero, rim: SIMD3<Float> = .zero, ground: Float = 0) {
            appendPolygon(points, normal: normal, albedo: albedo, emissive: emissive, rim: rim,
                          ground: ground, into: &built.vertices)
        }

        // **The ground and the streets** (migration M2), as real geometry:
        // a kerb is a step with a face that catches the light, a lamp is a
        // post with a lit head that casts a real pool, and a bridge is a deck
        // standing over the water with sides the river reflects.
        //
        // Real albedos, so light can land on them: asphalt is dark but not
        // black, land a little lighter. The night is the lighting's job.
        let asphalt = SIMD3<Float>(0.09, 0.085, 0.11)
        let pavement = SIMD3<Float>(0.17, 0.155, 0.21)
        let land = SIMD3<Float>(0.15, 0.12, 0.19)
        let water = SIMD3<Float>(0.01, 0.03, 0.07)
        let streetLane = linear(RenderPalette.networkAccentColor(for: .road)) * 1.35
        let highwayLane = linear(RenderPalette.networkAccentColor(for: .highway)) * 1.5
        let kerbLight = SIMD3<Float>(0.35, 0.3, 0.5)
        let sodium = SIMD3<Float>(1.0, 0.5, 0.18)
        let up = SIMD3<Float>(0, 0, 1)

        /// A box's top and four sides — no bottom, nothing sees it.
        func box(_ x0: Float, _ y0: Float, _ z0: Float, _ x1: Float, _ y1: Float, _ z1: Float,
                 albedo: SIMD3<Float>, emissive: SIMD3<Float> = .zero, rim: SIMD3<Float> = .zero,
                 topGround: Float = 0) {
            polygon([SIMD3(x0, y0, z1), SIMD3(x1, y0, z1), SIMD3(x1, y1, z1), SIMD3(x0, y1, z1)],
                    normal: up, albedo: albedo, emissive: emissive, rim: rim, ground: topGround)
            polygon([SIMD3(x1, y0, z0), SIMD3(x1, y1, z0), SIMD3(x1, y1, z1), SIMD3(x1, y0, z1)],
                    normal: SIMD3(1, 0, 0), albedo: albedo, emissive: emissive, rim: rim)
            polygon([SIMD3(x0, y1, z0), SIMD3(x1, y1, z0), SIMD3(x1, y1, z1), SIMD3(x0, y1, z1)],
                    normal: SIMD3(0, 1, 0), albedo: albedo, emissive: emissive, rim: rim)
            polygon([SIMD3(x0, y0, z0), SIMD3(x0, y1, z0), SIMD3(x0, y1, z1), SIMD3(x0, y0, z1)],
                    normal: SIMD3(-1, 0, 0), albedo: albedo, emissive: emissive, rim: rim)
            polygon([SIMD3(x0, y0, z0), SIMD3(x1, y0, z0), SIMD3(x1, y0, z1), SIMD3(x0, y0, z1)],
                    normal: SIMD3(0, -1, 0), albedo: albedo, emissive: emissive, rim: rim)
        }

        for tile in tilesInRegion {
            let x = Float(tile.position.x), y = Float(tile.position.y)
            let isRoad = Traffic.isRoadLike(tile.zone)
            let owned = map.isOwned(tile.position)
            // Unowned land sits between owned land and the landscape beyond
            // the map: the first version dimmed it below the backdrop, and the
            // map's own edge read inside-out.
            let dim: Float = owned ? 1 : 0.6

            // **Water sits below the street, behind a quay.** Flush with the
            // land, a river read as a flat line painted on the ground; sunk
            // and walled, it has a bank, and the city has a waterfront.
            let waterLevel: Float = -0.14
            let quayStone = SIMD3<Float>(0.07, 0.065, 0.09)
            func quayWalls(below top: Float) {
                for side in [(1, 0), (-1, 0), (0, 1), (0, -1)] as [(Int, Int)] {
                    let next = GridPosition(x: tile.position.x + side.0, y: tile.position.y + side.1)
                    guard map.contains(next), !map[next].isWater else { continue }
                    let face: [SIMD3<Float>]
                    switch side {
                    case (1, 0): face = [SIMD3(x + 1, y, waterLevel), SIMD3(x + 1, y + 1, waterLevel), SIMD3(x + 1, y + 1, top), SIMD3(x + 1, y, top)]
                    case (-1, 0): face = [SIMD3(x, y, waterLevel), SIMD3(x, y + 1, waterLevel), SIMD3(x, y + 1, top), SIMD3(x, y, top)]
                    case (0, 1): face = [SIMD3(x, y + 1, waterLevel), SIMD3(x + 1, y + 1, waterLevel), SIMD3(x + 1, y + 1, top), SIMD3(x, y + 1, top)]
                    default: face = [SIMD3(x, y, waterLevel), SIMD3(x + 1, y, waterLevel), SIMD3(x + 1, y, top), SIMD3(x, y, top)]
                    }
                    // Facing into the water, with the lit edge along its top
                    // that makes a quay read from across the map.
                    polygon(face, normal: -SIMD3(Float(side.0), Float(side.1), 0),
                            albedo: quayStone * dim, rim: kerbLight * 0.9 * dim)
                }
            }

            guard isRoad else {
                if tile.isWater {
                    polygon([SIMD3(x, y, waterLevel), SIMD3(x + 1, y, waterLevel),
                             SIMD3(x + 1, y + 1, waterLevel), SIMD3(x, y + 1, waterLevel)],
                            normal: up, albedo: water * dim, ground: 3)
                    quayWalls(below: 0)
                    continue
                }
                var albedo = land
                // A zoned lot with nothing on it yet is the first thing a new
                // player sees: its ground carries its zone's colour clearly
                // enough to read as "this is housing".
                if tile.zone.maxDensity > 0 {
                    let tint = tile.density == 0 ? 0.14 : 0.05
                    albedo = albedo * 0.75 + linear(RenderPalette.fullColor(for: tile.zone)) * Float(tint)
                }
                // `ground` says how a surface reflects — see the shader: 1
                // land, only its puddles in rain; 3 water, a mirror always.
                polygon([SIMD3(x, y, 0), SIMD3(x + 1, y, 0), SIMD3(x + 1, y + 1, 0), SIMD3(x, y + 1, 0)],
                        normal: up, albedo: albedo * dim, ground: tile.isWater ? 3 : 1)
                continue
            }

            // Which of the four sides carry on into more street.
            let sides: [(dx: Int, dy: Int)] = [(1, 0), (-1, 0), (0, 1), (0, -1)]
            let continues = sides.map { side -> Bool in
                let next = GridPosition(x: tile.position.x + side.dx, y: tile.position.y + side.dy)
                return map.contains(next) && Traffic.isRoadLike(map[next].zone)
            }

            // **A bridge is a deck over the water**, not asphalt painted on
            // it: the river runs underneath and mirrors the deck's lit sides.
            let deck: Float = tile.isWater ? 0.14 : 0
            if tile.isWater {
                polygon([SIMD3(x, y, waterLevel), SIMD3(x + 1, y, waterLevel),
                         SIMD3(x + 1, y + 1, waterLevel), SIMD3(x, y + 1, waterLevel)],
                        normal: up, albedo: water, ground: 3)
                quayWalls(below: 0)
                // The deck's top carries no rim and its sides only where it
                // meets open water: rimmed all round, every tile of a bridge
                // drew its own outline and the span read as a row of crates.
                polygon([SIMD3(x, y, deck), SIMD3(x + 1, y, deck), SIMD3(x + 1, y + 1, deck), SIMD3(x, y + 1, deck)],
                        normal: up, albedo: asphalt * 0.8, ground: 2)
                for (index, side) in sides.enumerated() where !continues[index] {
                    let face: [SIMD3<Float>]
                    switch (side.dx, side.dy) {
                    case (1, 0): face = [SIMD3(x + 1, y, deck - 0.1), SIMD3(x + 1, y + 1, deck - 0.1), SIMD3(x + 1, y + 1, deck), SIMD3(x + 1, y, deck)]
                    case (-1, 0): face = [SIMD3(x, y, deck - 0.1), SIMD3(x, y + 1, deck - 0.1), SIMD3(x, y + 1, deck), SIMD3(x, y, deck)]
                    case (0, 1): face = [SIMD3(x, y + 1, deck - 0.1), SIMD3(x + 1, y + 1, deck - 0.1), SIMD3(x + 1, y + 1, deck), SIMD3(x, y + 1, deck)]
                    default: face = [SIMD3(x, y, deck - 0.1), SIMD3(x + 1, y, deck - 0.1), SIMD3(x + 1, y, deck), SIMD3(x, y, deck)]
                    }
                    polygon(face, normal: SIMD3(Float(side.dx), Float(side.dy), 0),
                            albedo: asphalt * 0.6, rim: kerbLight * 1.4)
                }
            } else {
                // `ground` 2: street — glossy dry, a mirror in rain.
                polygon([SIMD3(x, y, 0), SIMD3(x + 1, y, 0), SIMD3(x + 1, y + 1, 0), SIMD3(x, y + 1, 0)],
                        normal: up, albedo: asphalt * dim, ground: 2)
            }

            // **Pavements and kerbs** along every side the street does not
            // carry on from — so a crossroads has none and a dead end three,
            // as the Classic renderer draws them. A raised step, whose face
            // toward the carriageway catches the light as a kerb line.
            let w: Float = 0.18, kerb: Float = 0.025
            for (index, side) in sides.enumerated() where !continues[index] {
                let (x0, y0, x1, y1): (Float, Float, Float, Float)
                switch (side.dx, side.dy) {
                case (1, 0): (x0, y0, x1, y1) = (x + 1 - w, y, x + 1, y + 1)
                case (-1, 0): (x0, y0, x1, y1) = (x, y, x + w, y + 1)
                case (0, 1): (x0, y0, x1, y1) = (x, y + 1 - w, x + 1, y + 1)
                default: (x0, y0, x1, y1) = (x, y, x + 1, y + w)
                }
                // The top has no rim, and only the kerb face — the one toward
                // the carriageway — has one. With a rim round every face the
                // first render drew every pavement tile as its own outlined
                // box, and a street read as a segmented ladder. The kerb line
                // is the edge that means something.
                polygon([SIMD3(x0, y0, deck + kerb), SIMD3(x1, y0, deck + kerb),
                         SIMD3(x1, y1, deck + kerb), SIMD3(x0, y1, deck + kerb)],
                        normal: up, albedo: pavement * dim, ground: 1)
                let face: [SIMD3<Float>]
                switch (side.dx, side.dy) {
                case (1, 0): face = [SIMD3(x0, y0, deck), SIMD3(x0, y1, deck), SIMD3(x0, y1, deck + kerb), SIMD3(x0, y0, deck + kerb)]
                case (-1, 0): face = [SIMD3(x1, y0, deck), SIMD3(x1, y1, deck), SIMD3(x1, y1, deck + kerb), SIMD3(x1, y0, deck + kerb)]
                case (0, 1): face = [SIMD3(x0, y0, deck), SIMD3(x1, y0, deck), SIMD3(x1, y0, deck + kerb), SIMD3(x0, y0, deck + kerb)]
                default: face = [SIMD3(x0, y1, deck), SIMD3(x1, y1, deck), SIMD3(x1, y1, deck + kerb), SIMD3(x0, y1, deck + kerb)]
                }
                polygon(face, normal: -SIMD3(Float(side.dx), Float(side.dy), 0),
                        albedo: pavement * dim * 0.7, rim: kerbLight * dim)

                // A lamp on every other footway: a thin post, a lit head, and
                // a real warm pool — sodium against the neon, the way the
                // Classic renderer's footway wash reads.
                guard (tile.position.x + tile.position.y) % 2 == 0 else { continue }
                let px = (x0 + x1) / 2 + Float(side.dx) * 0.02
                let py = (y0 + y1) / 2 + Float(side.dy) * 0.02
                let post: Float = 0.018, height: Float = 0.62
                box(px - post, py - post, deck + kerb, px + post, py + post, deck + height,
                    albedo: SIMD3(0.05, 0.045, 0.07), rim: sodium * 0.35)
                box(px - 0.045, py - 0.045, deck + height, px + 0.045, py + 0.045, deck + height + 0.04,
                    albedo: .zero, emissive: sodium * 2.2)
                // A street lamp lights its stretch of street, not the block:
                // at 2.1 tiles of reach the lamps put Apex over its frame
                // budget (9.4 ms against 8), because a light's cost is the
                // pixels it covers and that grows with the square of its
                // reach. Tighter and a touch brighter reads the same.
                addLight(SIMD3(px - Float(side.dx) * 0.25, py - Float(side.dy) * 0.25, deck + height),
                         sodium * 1.15, radius: 1.35)
            }

            // **Lane lines as glowing tubes**, strong enough to bloom: from
            // the centre toward every side the street carries on to. A
            // highway is a dual carriageway — two tubes, brighter and wider —
            // so an arterial reads as the bigger road from across the map.
            let isHighway = tile.zone == .highway
            let glow = isHighway ? highwayLane : streetLane
            let half: Float = isHighway ? 0.028 : 0.032
            let offsets: [Float] = isHighway ? [-0.12, 0.12] : [0]
            let z = deck + 0.006
            let centre = SIMD3<Float>(x + 0.5, y + 0.5, z)
            for (index, side) in sides.enumerated() where continues[index] {
                let along = SIMD3<Float>(Float(side.dx), Float(side.dy), 0)
                let across = SIMD3<Float>(Float(-side.dy), Float(side.dx), 0)
                for offset in offsets {
                    let start = centre + across * offset - along * half
                    let end = centre + across * offset + along * 0.5
                    polygon([start - across * half, end - across * half, end + across * half, start + across * half],
                            normal: up, albedo: .zero, emissive: glow * dim, ground: 1)
                }
            }
        }

        built.groundFloats = built.vertices.count

        // The buildings, from the variant the texture cache would draw —
        // generated once per variant and copied into place.
        for tile in tilesInRegion where tile.isBuildingAnchor {
            let key = Cache.Key(zone: tile.zone, density: tile.density,
                                variant: IsoTextureCache.variant(for: tile.position), near: near)
            let local: Built
            if let hit = cache.entries[key] {
                local = hit
            } else {
                local = building(key)
                cache.entries[key] = local
            }
            let dx = Float(tile.position.x), dy = Float(tile.position.y)
            let rise = heightScale(zone: tile.zone, density: tile.density, at: tile.position, in: map)
            var vertices = local.vertices
            var index = 0
            while index < vertices.count {
                vertices[index] += dx
                vertices[index + 1] += dy
                vertices[index + 2] *= rise
                index += MetalCityRenderer.GPUVertex.floatCount
            }
            // Signs, from the building as it actually stands on this lot.
            if let shape = MetalSigns.shape(of: vertices, stride: MetalCityRenderer.GPUVertex.floatCount) {
                let signs = MetalSigns.plan(for: tile, shape: shape)
                vertices += signs.frame
                built.signs += signs.letters
            }
            built.vertices += vertices
            var lights = local.lights
            index = 0
            while index < lights.count {
                lights[index] += dx
                lights[index + 1] += dy
                lights[index + 2] *= rise
                index += MetalCityRenderer.GPULight.floatCount
            }
            built.lights += lights
        }
        return built
    }
    // MARK: - A readable skyline (retrowave step 2)

    /// **Not every building shouts.** Every outline in the city glowed as hard
    /// as every other, so nothing led the eye and the wide view was one level
    /// of noise. Housing is the most of a city and speaks quietest; shops keep
    /// their colour; industry sits between; what the player built on purpose —
    /// services, and the landmarks a rank earns — is brightest. The Mini
    /// Motorways half of the brief: legibility is hierarchy.
    static func prominence(_ key: Cache.Key) -> (rim: Float, windows: Float) {
        if key.zone.maxDensity > 0,
           ZoneMassing.isLandmark(tier: RenderPalette.growthTier(for: key.density),
                                  seed: IsoTextureCache.canonicalSeed(for: key.variant)) {
            return (1.35, 1.1)
        }
        switch key.zone {
        case .residential: return (0.6, 0.85)
        case .industrial: return (0.8, 1)
        case .commercial: return (1, 1)
        default: return (1.2, 1)
        }
    }

    /// **A family of colours, not one colour per zone and tier.** Every
    /// mid-density shop was the same hue, so a district was one tone repeated
    /// — most of why the city read as a pattern from afar. Each variant now
    /// shifts a little in hue, saturation and brightness within its zone's
    /// family, seeded by the variant so a lot keeps its colour. Small on
    /// purpose: zone identity is the one thing a colour must still say.
    static func varied(_ color: SKColor, _ key: Cache.Key) -> SKColor {
        guard key.zone.maxDensity > 0 else { return color }
        let c = color.usingColorSpace(.sRGB) ?? color
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        let zoneIndex = ZoneType.allCases.firstIndex(of: key.zone) ?? 0
        var random = BuildingRandom(seed: GridPosition(x: key.variant, y: key.density), salt: 5_000 + zoneIndex)
        // **Industry gets a wider family, leaning to amber.** Its tiers are
        // one orange and one red-orange, so a district read as one block from
        // afar. The spread runs further toward amber than toward red, since
        // red is the direction of shops' magenta and zone identity is the one
        // thing this colour must still say.
        let spread: ClosedRange<Double> = key.zone == .industrial ? -0.03 ... 0.075 : -0.045 ... 0.045
        let hue = (h + CGFloat(random.value(in: spread)) + 1).truncatingRemainder(dividingBy: 1)
        let saturation = min(1, sat * CGFloat(random.value(in: key.zone == .industrial ? 0.7 ... 1.1 : 0.82 ... 1.1)))
        let brightness = min(1, b * CGFloat(random.value(in: 0.82 ... 1.08)))
        return SKColor(hue: hue, saturation: saturation, brightness: brightness, alpha: a)
            .usingColorSpace(.sRGB) ?? color
    }

    /// **The skyline follows the city.** Every building of one density stood
    /// at the same height, so the skyline was a flat canopy. Housing and
    /// shops now rise with how dense their neighbourhood is — the mean density
    /// of growable lots within three tiles — so downtown is a cluster that
    /// climbs, and a lone tower in the suburbs stands a little lower. A small
    /// per-lot wobble stops a block of equals lining up. Industry keeps its
    /// height: wide and low is its identity.
    static func heightScale(zone: ZoneType, density: Int, at position: GridPosition, in map: CityMap) -> Float {
        guard zone == .residential || zone == .commercial, density >= 3 else { return 1 }
        var sum = 0, most = 0
        for dy in -3 ... 3 {
            for dx in -3 ... 3 {
                let p = GridPosition(x: position.x + dx, y: position.y + dy)
                guard map.contains(p) else { continue }
                let t = map[p]
                if t.zone.maxDensity > 0 { sum += t.density; most += t.zone.maxDensity }
            }
        }
        // Against each lot's own ceiling, since housing and shops reach 6 and
        // industry stops at 5.
        let cluster = most == 0 ? 0 : Float(sum) / Float(most)
        let wobble = Float((position.x &* 73_856_093 ^ position.y &* 19_349_663) & 1023) / 1023 * 0.12 - 0.06
        return 0.85 + 0.6 * cluster * cluster + wobble
    }

    /// One building's triangles and lights, relative to its lot's corner.
    static func building(_ key: Cache.Key) -> Built {
        var built = Built()
        func add(_ v: MetalCityRenderer.GPUVertex) { built.vertices += v.floats }
        func addLight(_ at: SIMD3<Float>, _ color: SIMD3<Float>, radius: Float) {
            built.lights += MetalCityRenderer.GPULight(position: at, radius: radius, color: color).floats
        }
        func polygon(_ points: [SIMD3<Float>], normal: SIMD3<Float>, albedo: SIMD3<Float>,
                     emissive: SIMD3<Float> = .zero, rim: SIMD3<Float> = .zero, ground: Float = 0) {
            appendPolygon(points, normal: normal, albedo: albedo, emissive: emissive, rim: rim,
                          ground: ground, into: &built.vertices)
        }
        do {
            guard let massing = ZoneMassing.make(for: key.zone, density: key.density,
                                                 seed: IsoTextureCache.canonicalSeed(for: key.variant))
            else { return built }
            let origin = SIMD3<Float>(0, 0, 0)
            func world(_ p: Point3) -> SIMD3<Float> { origin + SIMD3(Float(p.x), Float(p.y), Float(p.z)) }
            let accentColor = varied(ZoneMassing.accent(for: key.zone, density: key.density), key)
            let accent = linear(accentColor)
            let body = SIMD3<Float>(0.11, 0.095, 0.15) + accent * 0.05
            let role = prominence(key)
            let footprint = Float(key.zone.footprintSize)

            // Lit volumes' lights, gathered rather than added one by one: a
            // level-6 drum carries a dozen lit rings, and a light each put
            // Apex 1.5 ms over its budget (point lights are most of a frame).
            var litSources: [(centre: SIMD3<Float>, glow: SIMD3<Float>)] = []
            for solid in massing.solids {
                let faces = solid.volume.faces
                switch solid.style {
                case .structure:
                    for face in faces {
                        polygon(face.points.map(world), normal: SIMD3(Float(face.normal.x), Float(face.normal.y),
                                                                          Float(face.normal.z)),
                                albedo: body, rim: accent * 1.7 * role.rim)
                    }
                case .lit(let color):
                    let glow = linear(color)
                    for face in faces {
                        // A lit volume's *top* is a whole footprint facing the
                        // camera, and at full strength it is a glaring plate —
                        // the same thing `IsometricBuilding` learned and dims.
                        let top = face.normal.z > 0.9
                        polygon(face.points.map(world), normal: SIMD3(Float(face.normal.x), Float(face.normal.y),
                                                                          Float(face.normal.z)),
                                albedo: .zero, emissive: glow * (top ? 0.35 : 0.9), rim: glow * 1.4)
                    }
                    let centre = faces.reduce(SIMD3<Float>.zero) { sum, face in
                        sum + face.points.map(world).reduce(.zero, +) / Float(face.points.count)
                    } / Float(max(1, faces.count))
                    litSources.append((centre, glow))
                }
            }
            // **Two lights at most per building, one low and one high.** A
            // building with one or two lit parts keeps exactly what it had.
            // More than that are merged by height, in massing order, so a
            // rebuilt chunk lists them identically (the M5 ordering lesson).
            if litSources.count <= 2 {
                for source in litSources { addLight(source.centre, source.glow * 0.9, radius: 2.6) }
            } else {
                let middle = litSources.map(\.centre.z).sorted()[litSources.count / 2]
                for high in [false, true] {
                    let group = litSources.filter { ($0.centre.z >= middle) == high }
                    guard !group.isEmpty else { continue }
                    let n = Float(group.count)
                    let centre = group.reduce(SIMD3<Float>.zero) { $0 + $1.centre } / n
                    let glow = group.reduce(SIMD3<Float>.zero) { $0 + $1.glow } / n
                    // A little brighter than one part's light, not
                    // the sum of them all, which would blow out to white.
                    addLight(centre, glow * 1.1, radius: 2.6)
                }
            }

            // Windows and glazing: lit panels, pushed a hair off their wall
            // so they do not fight it for the depth test. Dark panels —
            // recesses, mullions, cladding — stay surface, not light.
            var lightPerFace: [Panel.Face: (sum: SIMD3<Float>, area: Float, centre: SIMD3<Float>, n: Float)] = [:]
            var ledged: Set<String> = []
            for panel in massing.panels {
                let normal: SIMD3<Float> = panel.face == .right ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
                let color = linear(panel.color) * Float(panel.color.alphaComponent)
                let lit = luminance(color) > 0.08
                // **Lit panels stand further out than dark ones.** Both used
                // to sit 0.004 off the wall, so wherever a window crossed the
                // cladding behind it — piers, precast bands — the two fought
                // pixel by pixel and the window edges came out ragged. The
                // massing already layers cladding first and glazing over it
                // (`NeonStyle.Cladding`); the offsets now say the same.
                let corners = panel.corners.map { world($0) + normal * (lit ? 0.009 : 0.004) }
                if lit {
                    // Tagged 0.25, so the shader can calm windows from afar
                    // without touching the neon that carries the form.
                    polygon(corners, normal: normal, albedo: .zero, emissive: color * 0.95 * role.windows,
                            ground: 0.25)
                    let area = simd_length(corners[1] - corners[0]) * simd_length(corners[3] - corners[0])
                    var entry = lightPerFace[panel.face] ?? (.zero, 0, .zero, 0)
                    entry.sum += color * area
                    entry.area += area
                    entry.centre += corners.reduce(.zero, +) / 4
                    entry.n += 1
                    lightPerFace[panel.face] = entry
                } else {
                    polygon(corners, normal: normal, albedo: color)
                }
                // **Up close, the facade comes apart into panes** — the same
                // marks, from the same derivation, SpriteKit's near tier
                // draws. Standing proud of the panel they mark, for the
                // reason lit panels stand proud of the cladding.
                guard key.near else { continue }
                for mark in IsometricBuilding.nearDetail(on: panel, accent: accentColor, in: Isometric(),
                                                         ledged: &ledged) {
                    let markColor = linear(mark.color) * Float(mark.color.alphaComponent)
                    let markCorners = mark.corners.map { world($0) + normal * 0.013 }
                    if luminance(markColor) > 0.03 {
                        polygon(markCorners, normal: normal, albedo: .zero, emissive: markColor * 1.3)
                    } else {
                        polygon(markCorners, normal: normal, albedo: SIMD3(0.02, 0.015, 0.03))
                    }
                }
            }
            // One light per lit wall: its windows, together, spilling onto
            // the street in front of it.
            // **In a fixed order.** A dictionary's iteration order is not
            // stable between two dictionaries holding the same keys, so two
            // builds of the same building listed its lights differently —
            // invisible until a screen tile is full, where the order decides
            // which lights survive the 64-light cap. `MetalAgreement` found it
            // as "lights are stale" on chunks whose triangles were identical:
            // the same shape as `Traffic.computeLoad`'s `Set`-order bug.
            for (face, entry) in lightPerFace.sorted(by: { "\($0.key)" < "\($1.key)" }) where entry.n > 0 {
                let normal: SIMD3<Float> = face == .right ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
                let at = entry.centre / entry.n + normal * 0.6
                addLight(at, entry.sum / max(entry.area, 1e-3) * min(1.2, entry.area * 0.7), radius: 2.2)
            }
            // And the building's own colour on the ground at its feet — the
            // contact pool SpriteKit paints, here as light it actually throws.
            addLight(origin + SIMD3(footprint / 2, footprint / 2, 0.35), accent * 0.5,
                     radius: footprint * 1.5)
        }
        return built
    }

}
