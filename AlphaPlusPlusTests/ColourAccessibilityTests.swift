import SpriteKit
import XCTest
@testable import AlphaPlusPlus

/// **This game says almost everything in hue, and some players cannot hear it.**
///
/// Zone identity, every overlay, supplied against wanting, crime against fire —
/// all of it is carried by colour. The map itself turns out to be in better
/// shape than that sounds, because the massing port gave each zone a silhouette
/// vocabulary that survives greyscale. The overlays did not get that, and they
/// are where a meaning can have no second channel at all.
///
/// This file's own standing rule, arrived at twice already — once when an
/// ember-coloured fire turned out to be invisible on an already-orange factory,
/// and once when a utility badge distinguished water from power by hue alone:
/// **a mark whose only channel is hue vanishes on anything sharing the hue.**
/// Colour vision deficiency is that rule applied to the player rather than to
/// the background.
///
/// And it is already written down as a suspicion. The three-answer utility
/// overlay records: *"water's blue-against-red is unmistakable, power's
/// amber-against-red less so. If it bites, the answer is a second channel
/// rather than a third hue."* This measures whether it bites.
@MainActor
final class ColourAccessibilityTests: XCTestCase {

    /// **An approximation, and it says so.** These are the Brettel/Viénot
    /// matrices the accessibility tooling everyone uses is built on. They are
    /// good enough for the only question being asked here — *do these two
    /// meanings collapse into one colour* — and they are not a clinical
    /// simulation of anybody's sight.
    private enum Vision: String, CaseIterable {
        case unimpaired, deuteranopia, protanopia, tritanopia

        var matrix: [[CGFloat]] {
            switch self {
            case .unimpaired:   return [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
            case .deuteranopia: return [[0.625, 0.375, 0], [0.700, 0.300, 0], [0, 0.300, 0.700]]
            case .protanopia:   return [[0.567, 0.433, 0], [0.558, 0.442, 0], [0, 0.242, 0.758]]
            case .tritanopia:   return [[0.950, 0.050, 0], [0, 0.433, 0.567], [0, 0.475, 0.525]]
            }
        }
    }

    private func seen(_ colour: SKColor, as vision: Vision) -> (CGFloat, CGFloat, CGFloat) {
        guard let rgb = colour.usingColorSpace(.sRGB) else { return (0, 0, 0) }
        let (r, g, b) = (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        let m = vision.matrix
        return (m[0][0] * r + m[0][1] * g + m[0][2] * b,
                m[1][0] * r + m[1][1] * g + m[1][2] * b,
                m[2][0] * r + m[2][1] * g + m[2][2] * b)
    }

    /// How far apart two colours land once a given eye has had them. Plain
    /// Euclidean in sRGB — crude as a perceptual metric, and adequate for
    /// "these two are the same colour now", which is the only verdict wanted.
    private func distance(_ a: SKColor, _ b: SKColor, as vision: Vision) -> CGFloat {
        let (r1, g1, b1) = seen(a, as: vision)
        let (r2, g2, b2) = seen(b, as: vision)
        return sqrt(pow(r1 - r2, 2) + pow(g1 - g2, 2) + pow(b1 - b2, 2))
    }

    /// Every pair of colours in this game that means two *different* things and
    /// is told apart by nothing else.
    private func meanings() -> [(view: String, a: (String, SKColor), b: (String, SKColor))] {
        let water = RenderPalette.conduitColor(isPipe: true, live: true)
        let power = RenderPalette.conduitColor(isPipe: false, live: true)
        return [
            ("Water", ("supplied", water), ("wants water", RenderPalette.utilityWanted)),
            ("Water", ("supplied", water), ("not applicable", RenderPalette.unlitBuilding)),
            ("Water", ("wants water", RenderPalette.utilityWanted),
                      ("not applicable", RenderPalette.unlitBuilding)),
            ("Power", ("supplied", power), ("wants power", RenderPalette.utilityWanted)),
            ("Power", ("supplied", power), ("not applicable", RenderPalette.unlitBuilding)),
            ("Power", ("wants power", RenderPalette.utilityWanted),
                      ("not applicable", RenderPalette.unlitBuilding)),
            ("Zones", ("residential", RenderPalette.tierColor(for: .residential, tier: 3)),
                      ("commercial", RenderPalette.tierColor(for: .commercial, tier: 3))),
            ("Zones", ("commercial", RenderPalette.tierColor(for: .commercial, tier: 3)),
                      ("industrial", RenderPalette.tierColor(for: .industrial, tier: 3))),
            ("Zones", ("residential", RenderPalette.tierColor(for: .residential, tier: 3)),
                      ("industrial", RenderPalette.tierColor(for: .industrial, tier: 3))),
        ]
    }

    func testReportWhichMeaningsCollapse() {
        print("view   | meanings                        | " +
              Vision.allCases.map { String($0.rawValue.prefix(6)).padding(toLength: 6,
                                                                          withPad: " ",
                                                                          startingAt: 0) }
                  .joined(separator: " | "))
        var worst: [(String, String, CGFloat)] = []
        for pair in meanings() {
            let row = Vision.allCases.map { vision in
                String(format: "%6.3f", distance(pair.a.1, pair.b.1, as: vision))
            }
            let label = "\(pair.a.0) / \(pair.b.0)".padding(toLength: 32, withPad: " ",
                                                            startingAt: 0)
            print("\(pair.view.padding(toLength: 6, withPad: " ", startingAt: 0)) | "
                  + "\(label) | \(row.joined(separator: " | "))")
            let impaired = Vision.allCases.dropFirst()
                .map { distance(pair.a.1, pair.b.1, as: $0) }.min() ?? 1
            worst.append(("\(pair.view): \(pair.a.0) / \(pair.b.0)", pair.view, impaired))
        }
        let collapsed = worst.filter { $0.2 < Self.tellApart }
        print("\ncollapses (< \(Self.tellApart)): "
              + (collapsed.isEmpty ? "none" : collapsed.map(\.0).joined(separator: "; ")))
    }

    /// Below this, two colours are the same colour. Calibrated against the
    /// measurement rather than picked: the pair this game already suspected —
    /// power's amber against the alarm red — is the one that has to fail, and
    /// the pairs nobody has ever had trouble with have to pass.
    static let tellApart: CGFloat = 0.20

    /// **The standing guard, and it is two-sided on purpose.**
    ///
    /// The rule is not "no two colours may be close" — it is *a pair of
    /// meanings may share a colour only if something else tells them apart*.
    /// So this pins the exact set that shares one, which fails in both
    /// directions: a new pair collapsing fails it, and the known pair being
    /// fixed in colour fails it too and asks for this list to be rewritten
    /// rather than quietly widened.
    func testTheOnlyMeaningsSharingAColourAreTheOnesCarryingAGlyph() {
        var collapsed: Set<String> = []
        for pair in meanings() {
            let worst = Vision.allCases.dropFirst()
                .map { distance(pair.a.1, pair.b.1, as: $0) }.min() ?? 1
            if worst < Self.tellApart { collapsed.insert("\(pair.view): \(pair.a.0) / \(pair.b.0)") }
        }
        XCTAssertEqual(
            collapsed, ["Power: supplied / wants power"],
            "the set of meanings a colourblind player cannot tell apart by colour has changed. "
            + "Every member of it needs a second channel — see the Power overlay's badge — and "
            + "this list has to be rewritten rather than relaxed."
        )
    }

    /// And the second channel, asserted where it actually lives.
    ///
    /// A colour test cannot see a glyph, so the half of the fix that matters
    /// has to be checked on a real scene. Both states are present in the one
    /// fixture, because a picture in which the failing case cannot occur
    /// reports success — this file's oldest lesson.
    @MainActor
    func testThePowerOverlayBadgesWhatTheColourCannotSay() {
        var map = CityMap(width: 18, height: 18)
        for x in 0 ..< 18 { map[GridPosition(x: x, y: 7)].zone = .road }
        for origin in [GridPosition(x: 2, y: 8), GridPosition(x: 10, y: 8)] {
            map.placeBuilding(zone: .residential, origin: origin)
            for cell in map.footprintCells(origin: origin, size: 2) { map[cell].density = 5 }
        }
        // **Both blocks get water**, and the first version did not — so the
        // one meant to be *served* wore a badge anyway, for the drop rather
        // than the bolt, and the test failed on a working fix. The badge shows
        // whichever utility is missing, so a fixture where a second one is
        // also missing cannot say anything about the first. Same shape as
        // every fixture note in this project: a picture in which the failing
        // case cannot occur reports success, and its twin reports failure.
        map.placeBuilding(zone: .waterPump, origin: GridPosition(x: 5, y: 9))
        map.placeBuilding(zone: .waterPump, origin: GridPosition(x: 8, y: 9))
        // Only the second block gets power, and the generator is far enough
        // from the first to be out of its direct-supply radius.
        map.placeBuilding(zone: .generator, origin: GridPosition(x: 13, y: 8))

        let controller = GameController(map: map, rng: SeededRNG(seed: 2))
        controller.recomputeUtilitySupply()
        let scene = GameScene(controller: controller)
        scene.size = CGSize(width: 800, height: 600)
        let view = SKView(frame: NSRect(origin: .zero, size: scene.size))
        view.presentScene(scene)
        controller.overlayMode = .power
        scene.rebuildEntireGrid()
        scene.refreshAll()

        func badged(_ position: GridPosition) -> Bool {
            scene.tileNodesForTesting[position]?
                .children.contains { $0.name == IsoTileRenderer.warningNodeNameForTesting } ?? false
        }
        // The fixture has to actually be in the state it claims, or the
        // assertions below measure nothing.
        XCTAssertTrue(Water.hasSupply(at: GridPosition(x: 2, y: 8), in: controller.map),
                      "the unpowered block has no water either, so its badge says nothing "
                      + "about power")
        XCTAssertTrue(Water.hasSupply(at: GridPosition(x: 10, y: 8), in: controller.map))
        XCTAssertTrue(PowerGrid.hasSupply(at: GridPosition(x: 10, y: 8), in: controller.map),
                      "the block meant to be served has no power")
        XCTAssertFalse(PowerGrid.hasSupply(at: GridPosition(x: 2, y: 8), in: controller.map))

        XCTAssertTrue(badged(GridPosition(x: 2, y: 8)),
                      "a block with no power carries no badge in the Power overlay — and to a "
                      + "deuteranope its colour is the same as a powered one's")
        XCTAssertFalse(badged(GridPosition(x: 10, y: 8)),
                       "a powered block is flagged as wanting power")
    }
}
