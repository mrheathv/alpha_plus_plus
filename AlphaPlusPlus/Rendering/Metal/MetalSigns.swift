import CoreGraphics
import CoreText
import SpriteKit
import simd

/// **Large, clean neon signs** — the retrowave direction's signage pass.
///
/// A skyline of lit windows is a skyline of offices; what makes a city read
/// as *this* city at night is its signs. Three kinds, each where a real one
/// would be:
///
/// - **A rooftop billboard** on two posts, facing the camera, on the flat top
///   of a building big enough to carry one.
/// - **A blade**: a tall narrow sign standing off a building's front wall,
///   its letters stacked top to bottom.
/// - **A marquee**: a band of lettering round a shop's ground floor.
///
/// **Real words, as neon tubes.** The lettering is drawn once into one
/// texture (`atlas`) as outlined strokes with a soft halo, the way a bent
/// glass tube reads, and each sign samples a word from it and adds its
/// colour as light. A word a player can read is what separates signage from
/// decoration; an abstract glyph pattern at this size is just more windows.
///
/// **Planned per lot, not per building design.** The building a lot draws is
/// one of 32 cached variants; the sign is seeded by the lot's own position.
/// Two lots drawing the same tower carry different signs, which is variety
/// the variant cache cannot give — and a sign is part of what keeps a city
/// from repeating.
///
/// Signs live here rather than in the massing so the building generators stay
/// pure descriptions of architecture. The sign's frame — backing board,
/// posts — is ordinary lit geometry in the chunk; the letters are a separate
/// additive instance per sign.
enum MetalSigns {

    /// One sign's letters, exactly as the shader reads them: 20 floats.
    /// `origin` is the bottom-left corner in world tiles, `u` runs along the
    /// text and `v` up it; `rect` is the word's place in the atlas (u0, v top,
    /// u1, v bottom, normalised).
    static let floatCount = 20

    /// Off only for the test that measures what signs add to a frame.
    static var enabled = true

    static let horizontalWords = [
        "MOTEL", "ARCADE", "VIDEO", "DINER", "DISCO", "HOTEL", "RADIO", "PIZZA",
        "NEON", "CLUB", "TAXI", "CINEMA", "ROLLER", "LASER", "SYNTH", "PALMS",
        "SUNSET", "VINYL", "CAFE", "OPEN", "24 HR", "RETRO", "TOKYO", "CHROME",
    ]
    static let verticalWords = ["HOTEL", "BAR", "CLUB", "CAFE", "DISCO", "VIDEO", "NEON", "TAXI"]

    // Atlas layout: horizontal cells 512×128 in a 4-wide grid, then vertical
    // cells 128×512 in one row beneath them.
    static let atlasWidth = 2048
    static let horizontalCell = (w: 512, h: 128)
    static let verticalCell = (w: 128, h: 512)
    static var horizontalRows: Int { (horizontalWords.count + 3) / 4 }
    static var atlasHeight: Int { horizontalRows * horizontalCell.h + verticalCell.h }

    /// The neon a sign is bent in: magenta, cyan, gold, sunset orange, violet
    /// and hot pink — the palette's own, in linear light.
    static let colors: [SIMD3<Float>] = [
        SIMD3(1.0, 0.18, 0.72), SIMD3(0.2, 0.9, 1.0), SIMD3(1.0, 0.82, 0.3),
        SIMD3(1.0, 0.45, 0.15), SIMD3(0.72, 0.42, 1.0), SIMD3(1.0, 0.35, 0.55),
    ].map { SIMD3(powf($0.x, 2.2), powf($0.y, 2.2), powf($0.z, 2.2)) }

    // MARK: - The atlas

    /// Every word, as white neon tubes with a halo, on black. Grey, one
    /// channel: the colour comes from each sign.
    static func atlas() -> CGImage? {
        let width = atlasWidth, height = atlasHeight
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        func line(_ text: String, size: CGFloat) -> CTLine {
            let font = CTFontCreateWithName("Futura-Bold" as CFString, size, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .strokeColor: CGColor(gray: 1, alpha: 1),
                // Positive: outline only, which is what a bent tube is.
                .strokeWidth: 7,
                .kern: size * 0.08,
            ]
            return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
        /// Glow first, then the crisp tube over it.
        func draw(_ line: CTLine, at point: CGPoint) {
            context.saveGState()
            context.setShadow(offset: .zero, blur: 18, color: CGColor(gray: 1, alpha: 0.9))
            context.textPosition = point
            CTLineDraw(line, context)
            context.restoreGState()
            context.textPosition = point
            CTLineDraw(line, context)
        }

        for (index, word) in horizontalWords.enumerated() {
            let rect = cellRect(horizontal: index)
            var size: CGFloat = 92
            var text = line(word, size: size)
            var bounds = CTLineGetBoundsWithOptions(text, .useGlyphPathBounds)
            let room = rect.width - 60
            if bounds.width > room {
                size *= room / bounds.width
                text = line(word, size: size)
                bounds = CTLineGetBoundsWithOptions(text, .useGlyphPathBounds)
            }
            // CG's origin is bottom-left, the cell rect's is top-left.
            let bottom = CGFloat(height) - rect.maxY
            draw(text, at: CGPoint(x: rect.midX - bounds.width / 2 - bounds.minX,
                                   y: bottom + (rect.height - bounds.height) / 2 - bounds.minY))
        }
        for (index, word) in verticalWords.enumerated() {
            let rect = cellRect(vertical: index)
            let letters = Array(word)
            let slot = (rect.height - 40) / CGFloat(max(letters.count, 4))
            let size = min(84, slot * 0.95)
            let top = CGFloat(height) - rect.minY - 20
            for (k, letter) in letters.enumerated() {
                let text = line(String(letter), size: size)
                let bounds = CTLineGetBoundsWithOptions(text, .useGlyphPathBounds)
                let centreY = top - slot * (CGFloat(k) + 0.5)
                draw(text, at: CGPoint(x: rect.midX - bounds.width / 2 - bounds.minX,
                                       y: centreY - bounds.height / 2 - bounds.minY))
            }
        }
        return context.makeImage()
    }

    /// A horizontal word's cell, in atlas pixels with a top-left origin.
    static func cellRect(horizontal index: Int) -> CGRect {
        CGRect(x: (index % 4) * horizontalCell.w, y: (index / 4) * horizontalCell.h,
               width: horizontalCell.w, height: horizontalCell.h)
    }

    static func cellRect(vertical index: Int) -> CGRect {
        CGRect(x: index * verticalCell.w, y: horizontalRows * horizontalCell.h,
               width: verticalCell.w, height: verticalCell.h)
    }

    private static func normalised(_ rect: CGRect) -> [Float] {
        [Float(rect.minX) / Float(atlasWidth), Float(rect.minY) / Float(atlasHeight),
         Float(rect.maxX) / Float(atlasWidth), Float(rect.maxY) / Float(atlasHeight)]
    }

    // MARK: - Planning

    /// What a lot's building is, in world units, for deciding where a sign
    /// can go: its top, and the box its top volume occupies.
    struct Shape {
        var top: Float
        /// The roof a billboard can stand on — not the very top, which on
        /// most tall buildings is a mast or plant too narrow for a board, but
        /// the highest level at least most of a tile wide.
        var roofZ: Float
        var roof: (x0: Float, y0: Float, x1: Float, y1: Float)
        /// The furthest the walls reach at street level, +x and +y.
        var frontX: Float, frontY: Float
        /// The same at mid height, for a blade.
        var midX: Float
    }

    /// Measured off a building's own triangles, so a sign sits on the roof
    /// that is actually there.
    ///
    /// **The first version took "the roof" to be everything within a hair of
    /// the top**, which on nearly every tall building is its mast, so almost
    /// no billboard was ever placed and the signs came out as blades alone —
    /// found by diffing a frame with and without them.
    static func shape(of vertices: [Float], stride: Int) -> Shape? {
        var top: Float = 0
        var levels: [Int: (x0: Float, y0: Float, x1: Float, y1: Float)] = [:]
        var frontX = -Float.infinity, frontY = -Float.infinity
        var index = 0
        while index < vertices.count {
            let x = vertices[index], y = vertices[index + 1], z = vertices[index + 2]
            top = max(top, z)
            let level = Int((z * 50).rounded())
            let e = levels[level] ?? (Float.infinity, Float.infinity, -Float.infinity, -Float.infinity)
            levels[level] = (min(e.x0, x), min(e.y0, y), max(e.x1, x), max(e.y1, y))
            if z < 0.45 { frontX = max(frontX, x); frontY = max(frontY, y) }
            index += stride
        }
        guard top > 0.2 else { return nil }
        var midX = -Float.infinity
        index = 0
        while index < vertices.count {
            let z = vertices[index + 2]
            if z > top * 0.35, z < top * 0.65 { midX = max(midX, vertices[index]) }
            index += stride
        }
        // The highest level broad enough for a board, in the building's upper
        // half; failing that, the top itself (which will be too narrow, and
        // so carry no billboard).
        var roofZ = top
        var roof = levels[Int((top * 50).rounded())] ?? (0, 0, 0, 0)
        for level in levels.keys.sorted(by: >) {
            let z = Float(level) / 50
            guard z >= top * 0.5, let e = levels[level] else { continue }
            if min(e.x1 - e.x0, e.y1 - e.y0) >= 0.8 { roofZ = z; roof = e; break }
        }
        return Shape(top: top, roofZ: roofZ, roof: roof, frontX: frontX, frontY: frontY, midX: midX)
    }

    /// The signs a lot carries: letters to add as light, and the frame they
    /// hang on as geometry. Empty for most lots — a sign is an event.
    static func plan(for tile: Tile, shape: Shape) -> (letters: [Float], frame: [Float]) {
        guard enabled else { return ([], []) }
        var random = BuildingRandom(seed: tile.position, salt: 1500)
        let isShop = tile.zone == .commercial
        let chance: Double
        switch tile.zone {
        case .commercial: chance = tile.density >= 6 ? 0.8 : (tile.density >= 2 ? 0.5 : 0.2)
        case .residential: chance = tile.density >= 6 ? 0.25 : 0
        case .neonArcade: chance = 1
        default: chance = 0
        }
        guard chance > 0, random.chance(chance) else { return ([], []) }
        let color = random.pick(colors)
        let lot = (x0: Float(tile.position.x), y0: Float(tile.position.y),
                   x1: Float(tile.position.x + tile.zone.footprintSize),
                   y1: Float(tile.position.y + tile.zone.footprintSize))
        var letters: [Float] = [], frame: [Float] = []

        let roofWidth = min(shape.roof.x1 - shape.roof.x0, shape.roof.y1 - shape.roof.y0)
        let wantsBlade = shape.top > 1.4 && random.chance(0.35)
        let horizontal = tile.zone == .neonArcade ? horizontalWords.firstIndex(of: "ARCADE")!
            : (tile.zone == .residential ? horizontalWords.firstIndex(of: "HOTEL")!
               : random.int(in: 0 ... horizontalWords.count - 1))

        if wantsBlade, shape.midX > -Float.infinity {
            // A blade off the +x wall, near the +y end, facing +y — the side
            // the camera sees. It may reach no further than its own lot.
            let reach = min(0.45, lot.x1 - shape.midX - 0.02)
            if reach > 0.18 {
                let height = min(shape.top * 0.55, 2.6)
                let z0 = max(0.5, shape.top * 0.3)
                let y = min(lot.y1 - 0.08, shape.frontY - 0.15)
                let x0 = shape.midX + 0.02, x1 = shape.midX + reach
                appendBox(x0: x0, y0: y - 0.03, x1: x1, y1: y, z0: z0, z1: z0 + height, color: color,
                          into: &frame)
                let word = random.int(in: 0 ... verticalWords.count - 1)
                letters += [x0 + 0.01, y + 0.012, z0 + 0.02, 0,
                            x1 - x0 - 0.02, 0, 0, 0,
                            0, 0, height - 0.04, 0]
                    + color.asArray + [0] + normalised(cellRect(vertical: word))
            }
        } else if roofWidth > 0.7, shape.roofZ > 0.6 {
            // A billboard on the roof, set toward the front edge, facing one
            // of the two sides the camera sees.
            let facesX = random.chance(0.5)
            let span = facesX ? shape.roof.y1 - shape.roof.y0 : shape.roof.x1 - shape.roof.x0
            // Wider than the roof it stands on, as real rooftop billboards
            // are: held to the roof's width they came out small enough to
            // read as trim rather than as signage.
            let width = min(2.0, span * 1.25)
            let height = width / 4 * 1.25
            let z0 = shape.roofZ + 0.14
            if facesX {
                let x = shape.roof.x1 - 0.12
                let mid = (shape.roof.y0 + shape.roof.y1) / 2
                appendBox(x0: x - 0.04, y0: mid - width / 2, x1: x, y1: mid + width / 2, z0: z0, z1: z0 + height,
                          color: color, into: &frame)
                for post in [mid - width * 0.35, mid + width * 0.35] {
                    appendBox(x0: x - 0.04, y0: post - 0.02, x1: x, y1: post + 0.02, z0: shape.roofZ, z1: z0,
                              color: color * 0.3, into: &frame)
                }
                // Facing +x the text runs along -y, from the far end.
                letters += [x + 0.012, mid + width / 2, z0, 0,
                            0, -width, 0, 0,
                            0, 0, height, 0]
                    + color.asArray + [0] + normalised(cellRect(horizontal: horizontal))
            } else {
                let y = shape.roof.y1 - 0.12
                let mid = (shape.roof.x0 + shape.roof.x1) / 2
                appendBox(x0: mid - width / 2, y0: y - 0.04, x1: mid + width / 2, y1: y, z0: z0, z1: z0 + height,
                          color: color, into: &frame)
                for post in [mid - width * 0.35, mid + width * 0.35] {
                    appendBox(x0: post - 0.02, y0: y - 0.04, x1: post + 0.02, y1: y, z0: shape.roofZ, z1: z0,
                              color: color * 0.3, into: &frame)
                }
                // Facing +y the text runs along +x.
                letters += [mid - width / 2, y + 0.012, z0, 0,
                            width, 0, 0, 0,
                            0, 0, height, 0]
                    + color.asArray + [0] + normalised(cellRect(horizontal: horizontal))
            }
        }

        if isShop, tile.density <= 4, shape.frontY > -Float.infinity, random.chance(0.6) {
            // A marquee round the ground floor, on the +y face.
            let x0 = lot.x0 + 0.2, x1 = min(lot.x1 - 0.2, shape.frontX - 0.05)
            if x1 - x0 > 0.6 {
                let height = min(0.24, (x1 - x0) / 4)
                let word = random.int(in: 0 ... horizontalWords.count - 1)
                letters += [x0, shape.frontY + 0.012, 0.42, 0,
                            x1 - x0, 0, 0, 0,
                            0, 0, height, 0]
                    + (random.pick(colors)).asArray + [0] + normalised(cellRect(horizontal: word))
            }
        }
        return (letters, frame)
    }

    /// A dark board edged in the sign's colour: the frame the letters hang on.
    private static func appendBox(x0: Float, y0: Float, x1: Float, y1: Float, z0: Float, z1: Float,
                                  color: SIMD3<Float>, into vertices: inout [Float]) {
        let centre = SIMD3((x0 + x1) / 2, (y0 + y1) / 2, 0)
        MetalMotion.block(centre, along: SIMD3(1, 0, 0), length: x1 - x0, width: y1 - y0, z0: z0, z1: z1,
                          albedo: SIMD3(0.04, 0.035, 0.06), emissive: .zero, rim: color * 0.9,
                          into: &vertices)
    }
}

private extension SIMD3 where Scalar == Float {
    var asArray: [Float] { [x, y, z] }
}
