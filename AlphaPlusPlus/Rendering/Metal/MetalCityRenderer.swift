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
    }

    struct CompositeSettings {
        var bloomStrength: Float = 0.55
        var hazeStrength: Float = 0.35
        var exposure: Float = 1.0
        var grain: Float = 0.035
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
    let projection: Isometric
    var settings = CompositeSettings()

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
              let cullPipeline = try? device.makeComputePipelineState(function: cull)
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
        var lights: [Float]
        /// The tallest thing in it, for deciding whether it is on screen.
        var height: Float
        var region: MetalCityMesh.Region
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

    /// What the last `update` did, for the timing tests.
    private(set) var chunksRebuiltLastUpdate = 0

    /// Everything about a chunk's tiles that decides what it draws — and
    /// nothing that does not. Read one tile past the edge, because a lane
    /// line is a statement about its neighbours.
    private static func signature(of region: MetalCityMesh.Region, in map: CityMap) -> Int {
        var hasher = Hasher()
        for y in max(0, region.y0 - 1) ..< min(map.height, region.y1 + 1) {
            for x in max(0, region.x0 - 1) ..< min(map.width, region.x1 + 1) {
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
        if let revision, revision == builtRevision { return }
        builtRevision = revision
        mapExtent = Float(map.width + map.height + 20 + 4 * Int(Self.backdropMargin))
        mapSizePacked = UInt32(map.width) | (UInt32(map.height) << 16)
        updateBackdrop(for: map)
        let size = Self.chunkSize
        let across = (map.width + size - 1) / size, down = (map.height + size - 1) / size
        if chunkGrid != (across, down, map.width, map.height) {
            chunkGrid = (across, down, map.width, map.height)
            chunks = (0 ..< across * down).map { index in
                let cx = index % across, cy = index / across
                return Chunk(signature: 0, buffer: nil, vertexCount: 0, lights: [], height: 0,
                             region: .init(x0: cx * size, y0: cy * size,
                                           x1: min(map.width, (cx + 1) * size),
                                           y1: min(map.height, (cy + 1) * size)))
            }
        }
        var rebuilt = 0
        for index in chunks.indices {
            let signature = Self.signature(of: chunks[index].region, in: map)
            guard signature != chunks[index].signature || chunks[index].buffer == nil else { continue }
            let built = MetalCityMesh.build(map, cache: cache, region: chunks[index].region)
            let count = built.vertices.count / GPUVertex.floatCount
            var height: Float = 0
            var z = 2
            while z < built.vertices.count { height = max(height, built.vertices[z]); z += GPUVertex.floatCount }
            chunks[index] = Chunk(
                signature: signature,
                buffer: count == 0 ? nil : device.makeBuffer(bytes: built.vertices, length: built.vertices.count * 4),
                vertexCount: count, lights: built.lights, height: height, region: chunks[index].region)
            rebuilt += 1
        }
        chunksRebuiltLastUpdate = rebuilt
        if rebuilt > 0 { allLights = chunks.flatMap(\.lights) }
    }

    /// Is any of this chunk on screen? Its box, top to bottom, projected — or
    /// mirrored under the street for the reflection pass.
    private func isVisible(_ chunk: Chunk, through matrix: simd_float4x4, mirrored: Bool) -> Bool {
        let r = chunk.region
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
    private func visibleLights(through matrix: simd_float4x4, camera: Camera) -> [Float] {
        let pixelsPerTile = Float(projection.tileWidth / camera.scale)
        var kept: [Float] = []
        let stride = GPULight.floatCount
        var index = 0
        while index + stride <= allLights.count, kept.count / stride < Self.maximumLights {
            let p = SIMD4<Float>(allLights[index], allLights[index + 1], allLights[index + 2], 1)
            let clip = matrix * p
            // How far the light reaches, in normalised screen units.
            let reach = allLights[index + 3] * pixelsPerTile / Float(camera.size.width) * 2 + 0.05
            if abs(clip.x) <= 1 + reach && abs(clip.y) <= 1 + reach * 2 {
                kept.append(contentsOf: allLights[index ..< index + stride])
            }
            index += stride
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

    // MARK: - Drawing

    /// Encodes one whole frame into `output`, which is either the live view's
    /// drawable or a readable texture a test will copy out.
    @discardableResult
    private func encode(into commands: MTLCommandBuffer, output: MTLTexture, camera: Camera,
                        wetness: Float, time: Float) -> (triangles: Int, lights: Int)? {
        let encodeStarted = DispatchTime.now().uptimeNanoseconds
        defer {
            lastEncodeMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - encodeStarted) / 1e6
        }
        guard chunks.contains(where: { $0.vertexCount > 0 }), let targets = targets(for: camera.size) else { return nil }
        let matrix = viewProjection(for: camera, mapExtent: mapExtent)
        let lights = diagnostics.skipPointLights ? [] : visibleLights(through: matrix, camera: camera)
        let lightCount = lights.count / GPULight.floatCount
        var uniforms = Uniforms(
            viewProjection: matrix,
            frame: SIMD4(Float(camera.size.width), Float(camera.size.height), wetness, 0),
            moonAndTime: SIMD4(SIMD3<Float>(-0.35, 0.55, 0.76), time),
            counts: SIMD4(UInt32(lightCount), UInt32(targets.tilesAcross), UInt32(Self.tileSize), mapSizePacked)
        )
        let lightData = lights.isEmpty ? [Float](repeating: 0, count: GPULight.floatCount) : lights
        guard let lightBuffer = device.makeBuffer(bytes: lightData, length: lightData.count * 4) else { return nil }

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
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.012, green: 0.008, blue: 0.03,
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
            encoder.setFragmentTexture(mirrored ? nil : targets.reflection, index: 0)
            if !mirrored, let backdrop {
                encoder.setVertexBuffer(backdrop.buffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: backdrop.vertexCount)
            }
            // One draw per visible chunk: the ones off screen never reach the
            // GPU at all.
            for chunk in chunks where chunk.vertexCount > 0 {
                guard let buffer = chunk.buffer, isVisible(chunk, through: matrix, mirrored: mirrored)
                else { continue }
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: chunk.vertexCount)
                if !mirrored { drawn += chunk.vertexCount / 3 }
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
        // The widest level still holding only itself, for the haze.
        let haze = targets.bloom[3]
        for index in stride(from: targets.bloom.count - 1, to: 0, by: -1) where !diagnostics.skipBloom {
            compute.setTexture(targets.bloom[index], index: 0)
            compute.setTexture(targets.bloom[index - 1], index: 1)
            dispatch(bloomUp, over: targets.bloom[index - 1])
        }
        var composite = settings
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
    func draw(in view: MTKView, camera: Camera, wetness: Float, time: Float) {
        guard let drawable = view.currentDrawable, let commands = queue.makeCommandBuffer(),
              encode(into: commands, output: drawable.texture, camera: camera,
                     wetness: wetness, time: time) != nil
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
    func render(_ map: CityMap, camera: Camera, wetness: Float, time: Float = 0) -> Frame? {
        update(map, revision: nil)
        let width = Int(camera.size.width), height = Int(camera.size.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .shared
        guard let output = device.makeTexture(descriptor: descriptor),
              let commands = queue.makeCommandBuffer(),
              let counts = encode(into: commands, output: output, camera: camera, wetness: wetness, time: time)
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
    }

    /// Every distinct building, turned into triangles once.
    ///
    /// The same idea as `IsoTextureCache`, one level up: a lot draws one of a
    /// fixed set of variants per zone and density, so the massing for that
    /// variant is generated once and every lot that draws it copies the
    /// floats, offset to where it stands. Stored relative to the lot's corner.
    final class Cache {
        struct Key: Hashable { let zone: ZoneType; let density: Int; let variant: Int }
        var entries: [Key: Built] = [:]
    }

    /// sRGB colour to linear light. Every colour in this project was picked
    /// as an sRGB value on a screen; lighting maths has to happen in linear,
    /// or every blend and every falloff comes out wrong.
    static func linear(_ color: SKColor) -> SIMD3<Float> {
        let c = color.usingColorSpace(.sRGB) ?? color
        func f(_ v: CGFloat) -> Float { Float(pow(max(0, v), 2.2)) }
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

    static func build(_ map: CityMap, cache: Cache = Cache(), region: Region? = nil) -> Built {
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

        // The buildings, from the variant the texture cache would draw —
        // generated once per variant and copied into place.
        for tile in tilesInRegion where tile.isBuildingAnchor {
            let key = Cache.Key(zone: tile.zone, density: tile.density,
                                variant: IsoTextureCache.variant(for: tile.position))
            let local: Built
            if let hit = cache.entries[key] {
                local = hit
            } else {
                local = building(key)
                cache.entries[key] = local
            }
            let dx = Float(tile.position.x), dy = Float(tile.position.y)
            var vertices = local.vertices
            var index = 0
            while index < vertices.count {
                vertices[index] += dx
                vertices[index + 1] += dy
                index += MetalCityRenderer.GPUVertex.floatCount
            }
            built.vertices += vertices
            var lights = local.lights
            index = 0
            while index < lights.count {
                lights[index] += dx
                lights[index + 1] += dy
                index += MetalCityRenderer.GPULight.floatCount
            }
            built.lights += lights
        }
        return built
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
            let accent = linear(ZoneMassing.accent(for: key.zone, density: key.density))
            let body = SIMD3<Float>(0.11, 0.095, 0.15) + accent * 0.05
            let footprint = Float(key.zone.footprintSize)

            for solid in massing.solids {
                let faces = solid.volume.faces
                switch solid.style {
                case .structure:
                    for face in faces {
                        polygon(face.points.map(world), normal: SIMD3(Float(face.normal.x), Float(face.normal.y),
                                                                          Float(face.normal.z)),
                                albedo: body, rim: accent * 1.7)
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
                    addLight(centre, glow * 0.9, radius: 2.6)
                }
            }

            // Windows and glazing: lit panels, pushed a hair off their wall
            // so they do not fight it for the depth test. Dark panels —
            // recesses, mullions, cladding — stay surface, not light.
            var lightPerFace: [Panel.Face: (sum: SIMD3<Float>, area: Float, centre: SIMD3<Float>, n: Float)] = [:]
            for panel in massing.panels {
                let normal: SIMD3<Float> = panel.face == .right ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
                let corners = panel.corners.map { world($0) + normal * 0.004 }
                let color = linear(panel.color) * Float(panel.color.alphaComponent)
                if luminance(color) > 0.08 {
                    polygon(corners, normal: normal, albedo: .zero, emissive: color * 0.95)
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
            }
            // One light per lit wall: its windows, together, spilling onto
            // the street in front of it.
            for (face, entry) in lightPerFace where entry.n > 0 {
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
