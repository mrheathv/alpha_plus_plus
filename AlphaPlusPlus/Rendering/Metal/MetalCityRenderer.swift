import CoreGraphics
import Metal
import SpriteKit
import simd

/// **The spike: the city drawn in real 3D on Metal, offscreen.**
///
/// Not wired into the game. It exists to answer one question with a picture —
/// does drawing the city as lit geometry beat drawing it as pre-rasterised
/// sprites, by enough to be worth a migration — and it answers it by drawing
/// the *same data* the game draws: `ZoneMassing` for every building, the same
/// variants the texture cache would pick, and a camera matched exactly to
/// `Isometric`'s projection so a side-by-side with SpriteKit is fair.
///
/// Everything SpriteKit could only fake, this does for real:
///
/// - **Neon is light.** Each building's lit solids and window panels become
///   point lights that fall on nearby walls and on the street, instead of a
///   glow baked into one building's own picture.
/// - **The wet street reflects the city**, by drawing the city mirrored under
///   the ground plane into its own texture — which, for a flat mirror and a
///   fixed camera, is exactly what a reflection is.
/// - **Bloom is a chain**, five levels down and back up, which is the shape
///   real lens bloom has and what one blur of one size cannot give.
/// - **Depth is a depth buffer.** No painter's algorithm, no sort-key ties, no
///   texture cache, no effect node sized to the whole world.
///
/// The look it aims at is the one the project settled on: Mini Motorways'
/// restraint in the *shapes* — dark, flat, clean faces — and Cyberpunk's
/// richness in the *light*.
final class MetalCityRenderer {

    // MARK: - GPU layouts, mirrored in MetalCityShaders

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
    /// camera uses: a point in isometric screen space and points per pixel.
    struct Camera {
        var centre: CGPoint
        /// Screen points per output pixel — `SKCameraNode`'s scale.
        var scale: CGFloat
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
    let projection: Isometric
    var settings = CompositeSettings()

    static let sampleCount = 4

    init?(projection: Isometric = Isometric()) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: MetalCityShaders.source, options: nil),
              let vertex = library.makeFunction(name: "sceneVertex"),
              let fragment = library.makeFunction(name: "sceneFragment"),
              let down = library.makeFunction(name: "bloomDown"),
              let up = library.makeFunction(name: "bloomUp"),
              let composite = library.makeFunction(name: "composite")
        else { return nil }
        self.device = device
        self.queue = queue
        self.projection = projection

        func pipeline(samples: Int) -> MTLRenderPipelineState? {
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

        guard let scene = pipeline(samples: Self.sampleCount),
              let reflection = pipeline(samples: 1),
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
    /// the direction the whole project already agrees the camera sits in, so
    /// nearer things win the depth test for the same reason they win the
    /// painter's sort today.
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

    // MARK: - Rendering

    struct Frame {
        let image: CGImage
        let gpuMilliseconds: Double
        let triangles: Int
        let lights: Int
    }

    func render(_ map: CityMap, camera: Camera, wetness: Float, time: Float = 0) -> Frame? {
        let mesh = MetalCityMesh.build(map)
        let width = Int(camera.size.width), height = Int(camera.size.height)
        guard !mesh.vertices.isEmpty,
              let vertexBuffer = device.makeBuffer(bytes: mesh.vertices, length: mesh.vertices.count * 4),
              let lightBuffer = device.makeBuffer(
                  bytes: mesh.lights.isEmpty ? [Float](repeating: 0, count: 8) : mesh.lights,
                  length: max(32, mesh.lights.count * 4))
        else { return nil }
        let vertexCount = mesh.vertices.count / GPUVertex.floatCount
        let lightCount = mesh.lights.count / 8

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
        guard let reflection = texture(.rgba16Float, width, height, usage: target),
              let reflectionDepth = texture(.depth32Float, width, height, usage: .renderTarget),
              let msaa = texture(.rgba16Float, width, height, samples: Self.sampleCount, usage: .renderTarget),
              let msaaDepth = texture(.depth32Float, width, height, samples: Self.sampleCount, usage: .renderTarget),
              let hdr = texture(.rgba16Float, width, height, usage: target),
              let output = texture(.rgba8Unorm, width, height, usage: [.shaderWrite, .shaderRead], storage: .shared),
              let commands = queue.makeCommandBuffer()
        else { return nil }

        var uniforms = Uniforms(
            viewProjection: viewProjection(for: camera, mapExtent: Float(map.width + map.height + 20)),
            frame: SIMD4(Float(width), Float(height), wetness, 0),
            moonAndTime: SIMD4(SIMD3<Float>(-0.35, 0.55, 0.76), time),
            counts: SIMD4(UInt32(lightCount), 0, 0, 0)
        )

        func scenePass(into color: MTLTexture, depth: MTLTexture, resolve: MTLTexture?, mirrored: Bool) {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = color
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.012, green: 0.008, blue: 0.03, alpha: 1)
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
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBuffer(lightBuffer, offset: 0, index: 2)
            encoder.setFragmentTexture(mirrored ? nil : reflection, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
            encoder.endEncoding()
        }

        scenePass(into: reflection, depth: reflectionDepth, resolve: nil, mirrored: true)
        scenePass(into: msaa, depth: msaaDepth, resolve: hdr, mirrored: false)

        // Bloom: five levels, halving each time.
        let rw: MTLTextureUsage = [.shaderRead, .shaderWrite]
        var levels: [MTLTexture] = []
        var w = width / 2, h = height / 2
        for _ in 0 ..< 5 {
            guard let level = texture(.rgba16Float, w, h, usage: rw) else { return nil }
            levels.append(level)
            w = max(1, w / 2); h = max(1, h / 2)
        }
        guard let compute = commands.makeComputeCommandEncoder() else { return nil }
        func dispatch(_ pipeline: MTLComputePipelineState, over texture: MTLTexture) {
            let group = MTLSize(width: 8, height: 8, depth: 1)
            let grid = MTLSize(width: (texture.width + 7) / 8, height: (texture.height + 7) / 8, depth: 1)
            compute.setComputePipelineState(pipeline)
            compute.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
        }
        var threshold: Float = 1.0
        var source: MTLTexture = hdr
        for level in levels {
            compute.setTexture(source, index: 0)
            compute.setTexture(level, index: 1)
            compute.setBytes(&threshold, length: 4, index: 0)
            dispatch(bloomDown, over: level)
            threshold = 0
            source = level
        }
        // The widest level, kept as it is, for the haze.
        let haze = levels[3]
        for index in stride(from: levels.count - 1, to: 0, by: -1) {
            compute.setTexture(levels[index], index: 0)
            compute.setTexture(levels[index - 1], index: 1)
            dispatch(bloomUp, over: levels[index - 1])
        }
        var composite = settings
        compute.setTexture(hdr, index: 0)
        compute.setTexture(levels[0], index: 1)
        compute.setTexture(haze, index: 2)
        compute.setTexture(output, index: 3)
        compute.setBytes(&composite, length: MemoryLayout<CompositeSettings>.stride, index: 0)
        dispatch(compositePipeline, over: output)
        compute.endEncoding()

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
                     triangles: vertexCount / 3, lights: lightCount)
    }
}

// MARK: - The mesh

/// The city as triangles and lights, from the same data the game draws.
enum MetalCityMesh {

    struct Built {
        var vertices: [Float] = []
        var lights: [Float] = []
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

    static func build(_ map: CityMap) -> Built {
        var built = Built()
        func add(_ v: MetalCityRenderer.GPUVertex) { built.vertices += v.floats }
        func addLight(_ at: SIMD3<Float>, _ color: SIMD3<Float>, radius: Float) {
            guard built.lights.count / 8 < 512 else { return }
            built.lights += MetalCityRenderer.GPULight(position: at, radius: radius, color: color).floats
        }

        /// A polygon, fanned into triangles. Quads carry a uv and a size so
        /// the shader can put neon on their edges; anything else does not.
        func polygon(_ points: [SIMD3<Float>], normal: SIMD3<Float>, albedo: SIMD3<Float>,
                     emissive: SIMD3<Float> = .zero, rim: SIMD3<Float> = .zero, ground: Float = 0) {
            guard points.count >= 3 else { return }
            let isQuad = points.count == 4
            let size = isQuad
                ? SIMD2(simd_length(points[1] - points[0]), simd_length(points[3] - points[0]))
                : SIMD2<Float>(0, 0)
            let uvs: [SIMD2<Float>] = isQuad ? [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
                                             : Array(repeating: SIMD2(0.5, 0.5), count: points.count)
            for index in 1 ..< points.count - 1 {
                for corner in [0, index, index + 1] {
                    add(.init(position: points[corner], normal: normal, albedo: albedo, emissive: emissive,
                              rim: rim, uv: uvs[corner], size: size, ground: ground))
                }
            }
        }

        // The ground, one quad per tile.
        // Real albedos, so light can land on them: asphalt is dark but not
        // black, land a little lighter. The night is the lighting's job.
        let asphalt = SIMD3<Float>(0.09, 0.085, 0.11)
        let land = SIMD3<Float>(0.15, 0.12, 0.19)
        let laneColor = linear(RenderPalette.networkAccentColor(for: .road)) * 0.9
        let up = SIMD3<Float>(0, 0, 1)
        for tile in map.tiles {
            let x = Float(tile.position.x), y = Float(tile.position.y)
            let isRoad = Traffic.isRoadLike(tile.zone)
            var albedo = isRoad ? asphalt : land
            if tile.isWater { albedo = SIMD3(0.01, 0.03, 0.07) }
            if tile.zone.maxDensity > 0 {
                albedo = albedo * 0.8 + linear(RenderPalette.fullColor(for: tile.zone)) * 0.04
            }
            // `ground` 2 marks street, which is what gets wet enough to
            // mirror the city; 1 is land, which only shines in its puddles.
            polygon([SIMD3(x, y, 0), SIMD3(x + 1, y, 0), SIMD3(x + 1, y + 1, 0), SIMD3(x, y + 1, 0)],
                    normal: up, albedo: albedo, ground: isRoad ? 2 : 1)
            guard isRoad else { continue }

            // The lane line: a thin strip from the centre toward every
            // neighbour that carries on into street, like `syncLaneLine`.
            let centre = SIMD3<Float>(x + 0.5, y + 0.5, 0.004)
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let next = GridPosition(x: tile.position.x + dx, y: tile.position.y + dy)
                guard map.contains(next), Traffic.isRoadLike(map[next].zone) else { continue }
                let end = centre + SIMD3(Float(dx) * 0.5, Float(dy) * 0.5, 0)
                let across = SIMD3<Float>(Float(-dy), Float(dx), 0) * 0.025
                polygon([centre - across, end - across, end + across, centre + across],
                        normal: up, albedo: .zero, emissive: laneColor, ground: 1)
            }
            // Street lamps every few tiles: warm pools the neon sits over.
            if (tile.position.x + tile.position.y * 3) % 5 == 0 {
                addLight(SIMD3(x + 0.5, y + 0.5, 0.7), SIMD3(1.0, 0.45, 0.16) * 1.1, radius: 2.6)
            }
        }

        // The buildings, from the variant the texture cache would draw.
        for tile in map.tiles where tile.isBuildingAnchor {
            let variant = IsoTextureCache.variant(for: tile.position)
            guard let massing = ZoneMassing.make(for: tile.zone, density: tile.density,
                                                 seed: IsoTextureCache.canonicalSeed(for: variant))
            else { continue }
            let origin = SIMD3(Float(tile.position.x), Float(tile.position.y), 0)
            func world(_ p: Point3) -> SIMD3<Float> { origin + SIMD3(Float(p.x), Float(p.y), Float(p.z)) }
            let accent = linear(ZoneMassing.accent(for: tile.zone, density: tile.density))
            let body = SIMD3<Float>(0.11, 0.095, 0.15) + accent * 0.05
            let footprint = Float(tile.zone.footprintSize)

            for solid in massing.solids {
                let faces = solid.volume.faces
                switch solid.style {
                case .structure:
                    for face in faces {
                        polygon(face.points.map(world), normal: SIMD3(Float(face.normal.x), Float(face.normal.y),
                                                                          Float(face.normal.z)),
                                albedo: body, rim: accent * 1.25)
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
