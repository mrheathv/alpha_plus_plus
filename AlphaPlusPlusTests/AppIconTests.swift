import XCTest
import AppKit
import SpriteKit
@testable import AlphaPlusPlus

/// **The app icon, drawn from the same palette as the game.**
///
/// The icon that shipped predates the entire art direction — CLAUDE.md
/// records it as an explicit exception to the grayboxing rule at the time, on
/// the grounds that an icon is chrome *around* the game rather than game art.
/// That was fair then and stopped being fair the day the game became
/// isometric: the old icon is a **flat front-elevation skyline**, which is
/// precisely the "two viewpoints in one picture" mismatch the whole
/// projection change existed to fix. It is a picture of a game this is not.
///
/// What survives is the sun, because the sun was always right — and it is now
/// the same sun, drawn the same way, as `TitleScreen`. What replaces the
/// skyline is a handful of isometric blocks in the zones' own neon.
///
/// **Generated rather than authored**, like everything else here. An icon has
/// to be a raster asset, which makes it the one place this project cannot
/// avoid shipping PNGs — but it does not have to make them a mystery. This
/// writes every size in the asset catalogue from code, so the icon is
/// re-derivable when the palette moves rather than being a file nobody can
/// edit.
///
/// **It writes into the source tree, deliberately**, which is unusual for a
/// test and worth being explicit about. The alternative — emit to `build/`
/// and copy by hand — is a manual step, and a manual step drifts. The drawing
/// is deterministic, so the bytes only change when the *art* does: a palette
/// edit shows up as a diff on the icon, which is exactly the behaviour
/// wanted. The icon cannot silently fall out of step with the game the way
/// the one it replaces did.
@MainActor
final class AppIconTests: XCTestCase {

    /// The sizes `AppIcon.appiconset` asks for, as (file, pixels).
    private static let sizes: [(String, Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    func testRenderAppIcon() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let iconset = root
            .appendingPathComponent("AlphaPlusPlus/Assets.xcassets/AppIcon.appiconset")

        for (name, pixels) in Self.sizes {
            let data = try XCTUnwrap(Self.icon(size: CGFloat(pixels)),
                                     "failed to draw the icon at \(pixels)px")
            try data.write(to: iconset.appendingPathComponent("\(name).png"))
        }

        // And one at review size, next to every other render in the project.
        let sheet = root.appendingPathComponent("build/ContactSheet/app-icon.png")
        try FileManager.default.createDirectory(
            at: sheet.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try XCTUnwrap(Self.icon(size: 512)).write(to: sheet)
        print("🎨 App icon: \(sheet.path)")
    }

    // MARK: - Drawing

    private static func icon(size: CGFloat) -> Data? {
        let pixels = Int(size)
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // macOS bakes the rounded square into the art, which is what the icon
        // that shipped does too.
        let squircle = CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
                              cornerWidth: size * 0.22, cornerHeight: size * 0.22,
                              transform: nil)
        context.addPath(squircle)
        context.clip()

        sky(context, size)
        sun(context, size)
        city(context, size)

        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private static func sky(_ context: CGContext, _ size: CGFloat) {
        let horizon = size * 0.34

        // **The ground goes down first.** The first version painted only the
        // sky and left everything below the horizon unpainted, which in a
        // bitmap with an alpha channel is not "dark", it is *nothing* — the
        // icon came back with a white bottom half.
        context.setFillColor(RenderPalette.background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))

        let colours = [
            SKColor(srgbRed: 0.05, green: 0.02, blue: 0.16, alpha: 1).cgColor,
            SKColor(srgbRed: 0.28, green: 0.06, blue: 0.36, alpha: 1).cgColor,
            SKColor(srgbRed: 0.72, green: 0.12, blue: 0.48, alpha: 1).cgColor,
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colours, locations: [0, 0.55, 1]) {
            // CGContext counts up from the bottom, so the horizon is low here
            // and the deep sky is at the top.
            context.saveGState()
            context.clip(to: CGRect(x: 0, y: horizon, width: size, height: size - horizon))
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size),
                                       end: CGPoint(x: 0, y: horizon), options: [])
            context.restoreGState()
        }

        // A couple of grid lines under the city, enough to say "that ground
        // is the game's ground" without becoming texture at 32 pixels.
        guard size >= 128 else { return }
        context.setStrokeColor(SKColor(srgbRed: 1.0, green: 0.18, blue: 0.69, alpha: 0.30).cgColor)
        context.setLineWidth(size * 0.006)
        for step in 1 ... 3 {
            let y = horizon - CGFloat(step) * CGFloat(step) * size * 0.022
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: size, y: y))
        }
        context.strokePath()
    }

    /// The same sun as `TitleScreen`, slats and all.
    private static func sun(_ context: CGContext, _ size: CGFloat) {
        let radius = size * 0.26
        let centre = CGPoint(x: size / 2, y: size * 0.58)
        let bounds = CGRect(x: centre.x - radius, y: centre.y - radius,
                            width: radius * 2, height: radius * 2)

        // **Subtracted from the disc, not punched through it.** The first
        // version clipped to the disc and filled the slats in `.clear`, which
        // does not reveal the sky — it removes the pixels, and the icon came
        // back striped with holes. Exactly the mistake `TitleScreen` records
        // for its own first attempt, made a second time in a different API.
        var disc: CGPath = CGPath(ellipseIn: bounds, transform: nil)
        if size >= 64 {
            let slats = CGMutablePath()
            var y = centre.y - radius * 0.02
            var thickness = radius * 0.04
            while y > centre.y - radius {
                slats.addRect(CGRect(x: bounds.minX, y: y,
                                     width: bounds.width, height: thickness))
                y -= thickness + radius * 0.12
                thickness *= 1.5
            }
            // Below 64px a slat is under a pixel and only turns the disc to
            // mud — the icon's version of `NeonStyle.minimumDetailSize`.
            disc = disc.subtracting(slats)
        }

        context.saveGState()
        context.addPath(disc)
        context.clip()
        let colours = [
            SKColor(srgbRed: 1.0, green: 0.94, blue: 0.55, alpha: 1).cgColor,
            SKColor(srgbRed: 1.0, green: 0.56, blue: 0.24, alpha: 1).cgColor,
            SKColor(srgbRed: 1.0, green: 0.16, blue: 0.56, alpha: 1).cgColor,
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colours, locations: [0, 0.5, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: bounds.maxY),
                                       end: CGPoint(x: 0, y: bounds.minY), options: [])
        }
        context.restoreGState()
    }

    /// A cluster of isometric blocks — the game's own silhouette, where the
    /// icon that shipped drew a flat elevation.
    ///
    /// Five of them, because the icon has to survive 16 pixels: at that size
    /// this is three shapes and a sun, which is a readable mark, where the old
    /// icon's two dozen towers were a smear.
    private static func city(_ context: CGContext, _ size: CGFloat) {
        // Narrower and taller than the first pass, which came out as a pile
        // of cubes. A skyline is buildings, and what makes a box a building
        // is that it is taller than it is wide.
        let unit = size * 0.112
        let origin = CGPoint(x: size / 2, y: size * 0.26)
        // Zone colours straight from the palette the game draws with, so the
        // icon cannot drift away from it.
        let blocks: [(CGFloat, CGFloat, CGFloat, ZoneType)] = [
            (-1.6, 0.0, 1.9, .residential),
            (-0.5, -1.0, 1.2, .industrial),
            (0.5, 0.1, 3.0, .commercial),
            (1.6, -1.0, 1.6, .residential),
            (0.5, 1.2, 1.3, .industrial),
        ]
        // **One tower below 64 pixels, five above.** At 16 and 32 the five
        // overlap into an indistinct dark smudge under the sun — the same
        // argument `NeonStyle.minimumDetailSize` makes about facade details
        // and the slats above make about themselves: a mark that cannot be
        // drawn big enough is cut, not shrunk. A single silhouette against
        // the disc is a readable mark at any size, and the icon's identity is
        // allowed to simplify as it gets smaller.
        let drawn = size < 64
            ? blocks.filter { $0.3 == .commercial }
            : blocks.sorted { $0.0 + $0.1 < $1.0 + $1.1 }  // painter's algorithm, same as the map
        for (column, row, height, zone) in drawn {
            block(context, origin: origin, unit: size < 64 ? unit * 1.35 : unit,
                  column: size < 64 ? column - 0.5 : column, row: row, height: height,
                  colour: RenderPalette.fullColor(for: zone), small: size < 48)
        }
    }

    private static func block(
        _ context: CGContext, origin: CGPoint, unit: CGFloat,
        column: CGFloat, row: CGFloat, height: CGFloat, colour: SKColor, small: Bool
    ) {
        // The projection, spelled out rather than borrowed: `Isometric` works
        // in SpriteKit's y-up scene space against a live map, and an icon is
        // four parallelograms in a bitmap.
        func point(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + (x - y) * unit,
                    y: origin.y - (x + y) * unit * 0.5 + z * unit)
        }
        let x = column, y = row, top = height

        let faces: [[CGPoint]] = [
            // Top
            [point(x, y, top), point(x + 1, y, top), point(x + 1, y + 1, top), point(x, y + 1, top)],
            // Left and right walls
            [point(x, y + 1, top), point(x + 1, y + 1, top), point(x + 1, y + 1, 0), point(x, y + 1, 0)],
            [point(x + 1, y, top), point(x + 1, y + 1, top), point(x + 1, y + 1, 0), point(x + 1, y, 0)],
        ]
        // **Near-black faces with a neon edge**, which is how the game draws
        // every building — a shape cut out of the night, lit only by its own
        // outline. The first version filled them with the zone colour at low
        // alpha and they came out as tinted glass: pretty, and nothing like
        // the thing the icon is advertising.
        let shades: [CGFloat] = [0.30, 0.0, 0.14]

        for (face, shade) in zip(faces, shades) {
            context.beginPath()
            context.move(to: face[0])
            face.dropFirst().forEach { context.addLine(to: $0) }
            context.closePath()
            context.setFillColor(
                NeonStyle.silhouetteFill.blended(withFraction: shade, of: colour)?.cgColor
                    ?? NeonStyle.silhouetteFill.cgColor
            )
            context.fillPath()
        }

        // The neon edge, which is what makes it this game rather than a
        // low-poly render. Dropped at the smallest sizes, where a stroke this
        // fine only fattens the silhouette.
        guard !small else { return }
        context.setStrokeColor(colour.cgColor)
        context.setLineWidth(unit * 0.09)
        context.setLineJoin(.round)
        for face in faces {
            context.beginPath()
            context.move(to: face[0])
            face.dropFirst().forEach { context.addLine(to: $0) }
            context.closePath()
            context.strokePath()
        }
    }
}
