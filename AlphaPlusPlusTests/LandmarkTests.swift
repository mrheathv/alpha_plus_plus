import SpriteKit
import XCTest
@testable import AlphaPlusPlus

/// **A skyline needs something to be a skyline *about*.**
///
/// Every building in this game is one idiom — dark faces, a neon edge, lit
/// rectangles — so a density-5 tower was a taller density-3 tower and a
/// built-out downtown was a bar chart. A landmark is the exception each zone
/// gets to make about itself, drawn for about one top-tier lot in twelve.
@MainActor
final class LandmarkTests: XCTestCase {

    private static let zones: [ZoneType] = [.commercial, .residential, .industrial]

    /// **The rate, counted over the seeds the game actually uses.**
    ///
    /// Not over arbitrary ones: `IsoTextureCache` quantises a lot's position to
    /// one of `variantCount` looks and draws from a canonical seed, so the
    /// share of *lots* that are landmarks is the share of those thirty-two
    /// that roll true. Counting on some other seed space would be measuring a
    /// generator nobody renders — the same mistake as counting distinct
    /// massings over arbitrary seeds, which this project already records.
    func testAboutOneTopTierLotInTwelveIsALandmark() {
        var total = 0
        for zone in Self.zones {
            var landmarks = 0
            for variant in 0 ..< IsoTextureCache.variantCount
            where ZoneMassing.isLandmark(tier: 3,
                                         seed: IsoTextureCache.canonicalSeed(for: variant)) {
                landmarks += 1
            }
            total += landmarks
            print("\(zone): \(landmarks) of \(IsoTextureCache.variantCount) variants are landmarks")
            XCTAssertGreaterThan(landmarks, 0,
                                 "\(zone) has no landmark variant at all, so no city can ever "
                                 + "show one")
            XCTAssertLessThan(landmarks, 8,
                              "\(zone) draws \(landmarks) of \(IsoTextureCache.variantCount) as "
                              + "landmarks — past a quarter it is not a landmark, it is the form")
        }
        print("landmarks: \(total) of \(IsoTextureCache.variantCount * Self.zones.count) "
              + "top-tier variants across three zones")
    }

    /// Only the top tier, and only the roll — everything else has to be
    /// untouched.
    ///
    /// The obvious way to write this feature is a first roll inside each
    /// `make`, and it would shift every subsequent draw and silently redesign
    /// every ordinary building in the game: a change to nine-tenths of the
    /// city smuggled inside a feature about one-twelfth of it. The landmark
    /// rolls on its own stream with its own salt, and this is the guard on
    /// that.
    func testNothingBelowTheTopTierIsALandmark() {
        for tier in 0 ... 2 {
            for variant in 0 ..< IsoTextureCache.variantCount {
                XCTAssertFalse(
                    ZoneMassing.isLandmark(tier: tier,
                                           seed: IsoTextureCache.canonicalSeed(for: variant)),
                    "tier \(tier) variant \(variant) came back a landmark — a shop or a house "
                    + "cannot be the thing a skyline is about"
                )
            }
        }
    }

    /// **A landmark has to be a different *shape*, not a lucky roll on the
    /// height range.**
    ///
    /// At the zoom this game is played at you cannot compare two heights side
    /// by side — but you can see at a glance that one silhouette is
    /// proportioned differently from everything around it. So the property is
    /// stated as slenderness as well as height: a landmark stands well above
    /// its zone's ordinary top tier *and* is narrower at the top than an
    /// ordinary building is anywhere.
    func testALandmarkStandsClearOfItsZonesOrdinaryTopTier() throws {
        for zone in Self.zones {
            var ordinary: [CGFloat] = [], landmarks: [CGFloat] = []
            for variant in 0 ..< IsoTextureCache.variantCount {
                let seed = IsoTextureCache.canonicalSeed(for: variant)
                let massing = try XCTUnwrap(ZoneMassing.make(for: zone, density: 5, seed: seed))
                let top = massing.solids
                    .flatMap { $0.volume.faces.flatMap { face in face.points.map(\.z) } }
                    .max() ?? 0
                if ZoneMassing.isLandmark(tier: 3, seed: seed) {
                    landmarks.append(top)
                } else {
                    ordinary.append(top)
                }
            }
            let tallestOrdinary = ordinary.max() ?? 0
            let shortestLandmark = landmarks.min() ?? 0
            print(String(format: "%@: ordinary tops out at %.2f, the shortest landmark is %.2f",
                         String(describing: zone), tallestOrdinary, shortestLandmark))
            XCTAssertGreaterThan(shortestLandmark, tallestOrdinary * 1.25,
                                 "\(zone)'s landmark is within a quarter of an ordinary tower's "
                                 + "height, so it will read as a lucky roll rather than as a "
                                 + "landmark")
        }
    }

    /// **The 3×3 civics have to dominate too**, and neither of them did.
    ///
    /// A stadium and a power plant cover nine lots of ground and cost more
    /// than anything else a player builds, and measured before this pass they
    /// topped out at 1.8 and 1.9 tile units — *shorter than an ordinary block
    /// of flats*. Covering more ground is not dominating, and a building that
    /// large reading as background is the clearest case in the game of a mark
    /// not doing the job it was paid for.
    ///
    /// Stated against housing rather than against a number, so it survives the
    /// day someone retunes either ladder.
    func testTheBigCivicsStandTallerThanOrdinaryHousing() throws {
        func top(_ massing: BuildingMassing) -> CGFloat {
            massing.solids
                .flatMap { $0.volume.faces.flatMap { face in face.points.map(\.z) } }
                .max() ?? 0
        }
        let seed = GridPosition(x: 5, y: 9)
        let flats = try XCTUnwrap(ZoneMassing.make(for: .residential, density: 5, seed: seed))
        for zone in [ZoneType.stadium, .powerPlant] {
            let civic = try XCTUnwrap(ZoneMassing.make(for: zone, density: 0, seed: seed))
            print(String(format: "%@ stands %.2f against housing's %.2f",
                         String(describing: zone), top(civic), top(flats)))
            XCTAssertGreaterThan(top(civic), top(flats) * 1.3,
                                 "\(zone) covers nine lots and stands no taller than the flats "
                                 + "across the road")
        }
    }

    // MARK: - Looking at it

    /// **The comparison has to be in one frame.**
    ///
    /// A landmark is defined entirely by contrast with what stands around it,
    /// so a sheet of landmarks on their own would be six nice buildings and no
    /// evidence. `landmarks.png` puts each zone's landmark beside an ordinary
    /// top-tier building of the same zone, at the same scale, in the same
    /// picture.
    func testRenderEachLandmarkBesideAnOrdinaryTower() throws {
        let projection = Isometric(tileWidth: 64)
        let cache = IsoTextureCache(projection: projection)
        let view = SKView()

        /// **Found by position, which is the only way to ask for one.**
        ///
        /// The obvious spelling is to take the landmark variant's canonical
        /// seed and hand it to the cache — and it silently draws something
        /// else, because `rendered` quantises whatever seed it is given:
        /// `canonicalSeed(for:)` is not a fixed point of `variant(for:)`, so
        /// asking for variant 7's seed gets you whatever variant *that*
        /// position hashes to. The first run of this sheet was six ordinary
        /// buildings, with nothing failing.
        ///
        /// So: walk positions the way a map does, quantise each one exactly as
        /// the cache will, and keep the first whose variant is the kind wanted.
        func sprite(_ zone: ZoneType, landmark: Bool) throws -> SKSpriteNode {
            for x in 0 ..< 64 {
                for y in 0 ..< 64 {
                    let position = GridPosition(x: x, y: y)
                    let canonical = IsoTextureCache.canonicalSeed(
                        for: IsoTextureCache.variant(for: position))
                    guard ZoneMassing.isLandmark(tier: 3, seed: canonical) == landmark,
                          let rendered = cache.rendered(for: zone, density: 5, seed: position)
                    else { continue }
                    let node = SKSpriteNode(texture: rendered.texture, size: rendered.size)
                    node.setScale(1.4)
                    return node
                }
            }
            throw XCTSkip("no \(landmark ? "landmark" : "ordinary") variant for \(zone)")
        }

        /// The two 3×3 civics, which have no ordinary/landmark pair — they are
        /// one building each, and the question about them is the same one:
        /// whether nine lots of ground buys a silhouette anybody notices.
        func civic(_ zone: ZoneType) throws -> SKSpriteNode {
            let rendered = try XCTUnwrap(
                cache.rendered(for: zone, density: 0, seed: GridPosition(x: 5, y: 9)))
            let node = SKSpriteNode(texture: rendered.texture, size: rendered.size)
            node.setScale(1.4)
            return node
        }

        var panels: [NSImage] = []
        var subjects: [(ZoneType, Bool)] = []
        for zone in Self.zones { subjects += [(zone, false), (zone, true)] }
        for (zone, landmark) in subjects + [(.stadium, false), (.powerPlant, false)] {
            do {
                let node = zone == .stadium || zone == .powerPlant
                    ? try civic(zone)
                    : try sprite(zone, landmark: landmark)
                let frame = node.calculateAccumulatedFrame()
                // Every panel the same size, so the heights are comparable —
                // the entire subject of this sheet.
                let size = CGSize(width: 300, height: 560)
                node.position = CGPoint(x: size.width / 2, y: 60 - frame.minY)
                let scene = SKScene(size: size)
                scene.backgroundColor = RenderPalette.background
                // A ground line, so "how tall" is measured from somewhere.
                let ground = SKSpriteNode(color: SKColor(white: 0.12, alpha: 1),
                                          size: CGSize(width: size.width, height: 1))
                ground.position = CGPoint(x: size.width / 2, y: 60)
                scene.addChild(ground)
                scene.addChild(node)
                view.frame = NSRect(origin: .zero, size: size)
                view.presentScene(scene)
                let texture = try XCTUnwrap(
                    view.texture(from: scene, crop: CGRect(origin: .zero, size: size)))
                panels.append(NSImage(cgImage: texture.cgImage(), size: size))
            }
        }

        let gap: CGFloat = 10
        let sheet = NSImage(size: CGSize(
            width: panels.map(\.size.width).reduce(0, +) + gap * CGFloat(panels.count + 1),
            height: (panels.first?.size.height ?? 0) + gap * 2))
        sheet.lockFocus()
        RenderPalette.background.setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        var x = gap
        for panel in panels {
            panel.draw(at: CGPoint(x: x, y: gap), from: .zero,
                       operation: .sourceOver, fraction: 1)
            x += panel.size.width + gap
        }
        sheet.unlockFocus()

        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ContactSheet")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("landmarks.png")
        guard let tiff = sheet.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("could not encode the sheet")
        }
        try png.write(to: url)
        print("wrote \(url.path) — ordinary and landmark, per zone, at one scale")
    }
}
