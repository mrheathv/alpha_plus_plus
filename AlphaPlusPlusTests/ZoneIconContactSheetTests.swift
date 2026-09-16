import XCTest
import SpriteKit
@testable import AlphaPlusPlus

/// Renders every `ZoneIcon` variant in the game to a single PNG contact
/// sheet, and asserts along the way that each one actually draws something.
///
/// **Why this is a test and not an app feature.** Looking at a single icon
/// used to mean *playing* to it: commit 243276c had to place a water tower
/// and a pipe network purely to clear `CitySimulator`'s density-3 water gate,
/// so a Commercial lot would reach tier 2, so one rooftop satellite dish
/// could be eyeballed. That is minutes of setup per look, which makes art
/// iteration expensive enough that it doesn't happen. The test target is
/// already app-hosted (`TEST_HOST` is `AlphaPlusPlus.app`), so it has a real
/// Metal context and can render SpriteKit nodes offscreen — meaning a test
/// is the cheapest headless renderer this project can have without adding a
/// whole new target. `swift`-side, one `xcodebuild test -only-testing:` run
/// now replaces the entire play-to-it loop.
///
/// **It is also a genuine regression test, not just a screenshot tool.**
/// `ZoneIcon.makeNode(for:density:seed:)` returns an optional and composes
/// shapes procedurally, so an icon can fail two silent ways: return `nil`
/// where a building is expected, or return a node that draws nothing (an
/// empty path, a zero-size frame). Today either one is invisible until a
/// city happens to grow a lot to that exact tier and variant. The
/// assertions below turn both into an immediate, named test failure.
final class ZoneIconContactSheetTests: XCTestCase {

    // MARK: - The catalog

    /// One cell of the sheet: a single icon the game can draw.
    private struct Entry {
        let zone: ZoneType
        let density: Int
        let seed: GridPosition
        let label: String
    }

    /// The two seeds that select variant 0 and variant 1.
    ///
    /// `ZoneIcon.variant(for:optionCount:)` is `abs(x &* 31 &+ y) % count`,
    /// so `(0,0)` picks variant 0 and `(0,1)` picks variant 1 for every
    /// two-option zone in the game. Deliberately derived from that formula
    /// rather than hardcoded as "some seed that happens to work": if the
    /// variant hash is ever changed, `testEveryVariantIsReachable` below
    /// fails loudly instead of the sheet quietly rendering the same variant
    /// twice in adjacent columns.
    private static let variantSeeds = [GridPosition(x: 0, y: 0), GridPosition(x: 0, y: 1)]

    /// How many different lots to draw for a *generated* zone.
    ///
    /// The hand-written zones have exactly two looks and there is nothing more
    /// to show. A parametric zone's whole point is that the count is unbounded
    /// (see `IndustrialBuilding`), so the sheet has to show enough seeds to
    /// judge whether the variety is real — a generator that technically
    /// produces thousands of buildings which all look alike is no better than
    /// the two hand-drawn ones it replaced. Ten is CLAUDE.md's stated target.
    private static let generatedVariantCount = 10

    /// Zones drawn by a parametric generator rather than fixed functions.
    private static let generatedZones: Set<ZoneType> = [.residential, .commercial, .industrial]

    /// Lot positions to draw a generated zone at. Spread apart rather than
    /// consecutive, so neighbouring seeds cannot flatter the result by
    /// accident.
    private static func generatedSeeds() -> [GridPosition] {
        (0 ..< generatedVariantCount).map { GridPosition(x: $0 * 7, y: $0 * 3) }
    }

    /// Which density stands in for each growth tier.
    ///
    /// `RenderPalette.growthTier(for:)` maps 1-2 to tier 1, 3-4 to tier 2,
    /// and 5+ to tier 3, so one density per tier covers every distinct icon:
    /// density 1 and 2 draw the same shape in the same tier color.
    private static let tierDensities = [1: 1, 2: 3, 3: 5]

    /// Every service/infrastructure zone that draws an icon. `.empty`,
    /// `.road`, and `.highway` deliberately draw none (see `ZoneIcon`'s own
    /// doc comment), so they are absent here rather than expected-nil.
    private static let serviceZones: [ZoneType] = [
        .policeStation, .fireStation, .publicTransit,
        .powerPlant, .stadium, .subway, .waterTower,
        .waterPump, .generator, .school, .hospital,
    ]

    /// Services drawn with a single look rather than two.
    ///
    /// The starter utilities sit on a 1×1 and a 2×2 lot, which leaves very
    /// little room to say anything with — a second variant would be the same
    /// box with a window moved. They are still catalogued and still have to
    /// draw something; they are only exempt from the two-looks rule.
    private static let singleVariantZones: Set<ZoneType> = [.waterPump, .generator, .school, .hospital]

    private static let growableZones: [ZoneType] = [.residential, .commercial, .industrial]

    /// Every icon the game can draw, in sheet order: the three growable
    /// zones by tier, then the services.
    private static func catalog() -> [Entry] {
        var entries: [Entry] = []
        for zone in growableZones {
            for tier in tierDensities.keys.sorted() {
                let density = tierDensities[tier]!
                let seeds = generatedZones.contains(zone) ? generatedSeeds() : variantSeeds
                for (index, seed) in seeds.enumerated() {
                    entries.append(Entry(
                        zone: zone,
                        density: density,
                        seed: seed,
                        label: "\(displayName(zone)) T\(tier).\(index)"
                    ))
                }
            }
        }
        for zone in serviceZones {
            let seeds = singleVariantZones.contains(zone) ? [variantSeeds[0]] : variantSeeds
            for (index, seed) in seeds.enumerated() {
                entries.append(Entry(
                    zone: zone,
                    density: 0,
                    seed: seed,
                    label: seeds.count == 1 ? displayName(zone) : "\(displayName(zone)).\(index)"
                ))
            }
        }
        return entries
    }

    /// `ZoneType.rawValue` is camelCase (`policeStation`); split it for a
    /// legible cell caption.
    private static func displayName(_ zone: ZoneType) -> String {
        var out = ""
        for character in zone.rawValue {
            if character.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(character)
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    // MARK: - Assertions

    func testEveryCatalogedIconDrawsSomething() {
        for entry in Self.catalog() {
            guard let node = ZoneIcon.makeNode(for: entry.zone, density: entry.density, seed: entry.seed) else {
                XCTFail("\(entry.label): ZoneIcon.makeNode returned nil, expected a building")
                continue
            }
            let frame = node.calculateAccumulatedFrame()
            XCTAssertGreaterThan(frame.width, 0, "\(entry.label): icon has zero width — nothing would render")
            XCTAssertGreaterThan(frame.height, 0, "\(entry.label): icon has zero height — nothing would render")
        }
    }

    /// The sheet is only honest if its two columns per tier really are two
    /// *different* buildings. This pins the seeds above to the variant hash:
    /// if `ZoneIcon.variant(for:optionCount:)` changes so both seeds collapse
    /// onto one variant, the sheet would silently show duplicates.
    func testEveryVariantIsReachable() {
        for zone in Self.growableZones + Self.serviceZones
        where !Self.singleVariantZones.contains(zone) && !Self.generatedZones.contains(zone) {
            let density = zone.maxDensity > 0 ? 5 : 0
            let shapes = Self.variantSeeds.map { seed -> String in
                let node = ZoneIcon.makeNode(for: zone, density: density, seed: seed)
                return Self.structuralSignature(of: node)
            }
            XCTAssertNotEqual(
                shapes[0], shapes[1],
                "\(Self.displayName(zone)): both contact-sheet seeds select the same variant, "
                + "so the sheet would show it twice instead of both looks"
            )
        }
    }

    /// A generator has to actually generate. Ten seeds producing ten
    /// structurally identical buildings would satisfy every other test in this
    /// file while being no better than the two hand-drawn looks it replaced.
    func testGeneratedZonesProduceGenuinelyDifferentBuildings() {
        for zone in Self.generatedZones {
            for tier in Self.tierDensities.keys.sorted() {
                let density = Self.tierDensities[tier]!
                let signatures = Self.generatedSeeds().map { seed in
                    Self.structuralSignature(of: ZoneIcon.makeNode(for: zone, density: density, seed: seed))
                }
                let distinct = Set(signatures).count
                XCTAssertGreaterThanOrEqual(
                    distinct, 7,
                    "\(Self.displayName(zone)) tier \(tier) drew only \(distinct) distinct buildings "
                    + "from \(signatures.count) seeds — the generator is not generating"
                )
            }
        }
    }

    /// The same lot must draw the same building every time, or a city visibly
    /// reshuffles itself while the player watches.
    func testGeneratedBuildingsAreStableForAGivenLot() {
        let seed = GridPosition(x: 5, y: 9)
        for zone in Self.generatedZones {
            let first = Self.structuralSignature(of: ZoneIcon.makeNode(for: zone, density: 5, seed: seed))
            for _ in 0 ..< 5 {
                XCTAssertEqual(
                    Self.structuralSignature(of: ZoneIcon.makeNode(for: zone, density: 5, seed: seed)),
                    first,
                    "\(zone) drew a different building for the same lot on a redraw"
                )
            }
        }
    }

    /// A cheap structural fingerprint of a node tree — child count and
    /// rounded frame per descendant. Enough to tell two different building
    /// silhouettes apart without depending on `ZoneIcon`'s private shape
    /// functions or on exact floating-point geometry.
    private static func structuralSignature(of node: SKNode?) -> String {
        guard let node else { return "nil" }
        var parts: [String] = []
        func walk(_ current: SKNode, depth: Int) {
            let frame = current.calculateAccumulatedFrame()
            parts.append("\(depth):\(current.children.count):"
                + "\(Int(frame.width.rounded()))x\(Int(frame.height.rounded()))")
            for child in current.children { walk(child, depth: depth + 1) }
        }
        walk(node, depth: 0)
        return parts.joined(separator: "|")
    }

    // MARK: - The sheet

    /// Renders the catalog to a PNG.
    ///
    /// Writes to `$CONTACT_SHEET_PATH` when set, otherwise
    /// `build/ContactSheet/zone-icons.png` under the repo root — `build/` is
    /// already gitignored, so the sheet never becomes a committed binary. The
    /// path is printed to the test log either way, since that is how you
    /// actually find it.
    ///
    /// **Note on that environment variable:** `xcodebuild` does not pass the
    /// invoking shell's environment through to the test process. To override
    /// the path from the command line the variable needs a `TEST_RUNNER_`
    /// prefix, which xcodebuild strips before handing it to the test:
    ///
    ///     TEST_RUNNER_CONTACT_SHEET_PATH=/tmp/sheet.png xcodebuild ... test \
    ///       -only-testing:AlphaPlusPlusTests/ZoneIconContactSheetTests
    ///
    /// **Why each cell is rendered in its own pass.** The obvious
    /// implementation — build one big scene holding all 32 cells, call
    /// `SKView.texture(from:)` once — silently renders only the first several
    /// cells and leaves the rest of the sheet blank, with no error and a
    /// passing test. Every `ZoneIcon` shape is wrapped in `withGlow`, an
    /// `SKEffectNode` running a Gaussian blur, and a single render pass will
    /// not service 32 of them; it quits partway through. It is genuinely
    /// budget-driven rather than a fixed cap, which is what makes it such a
    /// trap: rendering the catalog in reverse order got 24 cells out instead
    /// of 12, because the service icons are simpler shapes than the
    /// residential and commercial towers and more of them fit under the same
    /// ceiling. One pass per cell keeps every pass to a single building's
    /// worth of effect nodes, and Core Graphics composes the finished sheet,
    /// where no such budget exists.
    func testRenderContactSheet() throws {
        let entries = Self.catalog()
        let layout = GridLayout(tileSize: Self.cellIconSize, gap: 0)

        let columns = 6
        let rows = Int((Double(entries.count) / Double(columns)).rounded(.up))
        let sheetSize = CGSize(
            width: CGFloat(columns) * Self.cellSize.width + 2 * Self.margin,
            height: CGFloat(rows) * Self.cellSize.height + 2 * Self.margin + Self.titleHeight
        )

        // One view, reused for all 32 single-icon passes.
        let iconBox = CGSize(width: Self.cellIconSize, height: Self.cellIconSize)
        let view = SKView(frame: NSRect(origin: .zero, size: iconBox))

        var cellImages: [NSImage] = []
        for entry in entries {
            cellImages.append(try renderCell(for: entry, size: iconBox, view: view, layout: layout))
        }

        let sheet = try XCTUnwrap(
            Self.compose(cells: cellImages, entries: entries, columns: columns, sheetSize: sheetSize),
            "failed to compose the contact sheet bitmap"
        )

        let destination = Self.outputURL()
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try sheet.write(to: destination)

        print("📇 Contact sheet: \(destination.path) (\(entries.count) icons, \(sheet.count) bytes)")
        XCTAssertGreaterThan(sheet.count, 0)
    }

    /// Renders one icon on its zone's own tile color, in its own SpriteKit
    /// pass — see `testRenderContactSheet`'s doc comment for why that
    /// isolation is load-bearing rather than just tidy.
    private func renderCell(
        for entry: Entry,
        size: CGSize,
        view: SKView,
        layout: GridLayout
    ) throws -> NSImage {
        let scene = SKScene(size: size)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        let plate = SKSpriteNode(
            color: RenderPalette.color(for: entry.zone, density: entry.density),
            size: size
        )
        plate.position = center
        scene.addChild(plate)

        if let icon = ZoneIcon.makeNode(for: entry.zone, density: entry.density, seed: entry.seed) {
            // Footprint 1 for every cell regardless of the zone's real
            // `footprintSize`: the sheet's cells are uniform, and what
            // matters here is how much of its lot an icon claims, which is
            // identical at any footprint. The caption carries the real size.
            TileRenderer.fitIconToTile(icon, footprintSize: 1, layout: layout)
            icon.position = center
            scene.addChild(icon)
        }

        view.presentScene(scene)
        let texture = try XCTUnwrap(
            view.texture(from: scene, crop: CGRect(origin: .zero, size: size)),
            "\(entry.label): SKView produced no texture — no Metal context in the test host?"
        )
        return NSImage(cgImage: texture.cgImage(), size: size)
    }

    /// Lays the rendered cells out on one bitmap with their captions.
    ///
    /// Core Graphics rather than SpriteKit: this stage is pure compositing of
    /// already-rasterized images, so it has none of the effect-node budget
    /// that broke the all-in-one-scene approach.
    private static func compose(
        cells: [NSImage],
        entries: [Entry],
        columns: Int,
        sheetSize: CGSize
    ) -> Data? {
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(sheetSize.width * scale),
            pixelsHigh: Int(sheetSize.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = sheetSize

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        RenderPalette.background.setFill()
        NSRect(origin: .zero, size: sheetSize).fill()

        let title = "ZoneIcon catalog — \(entries.count) icons"
        title.draw(
            at: NSPoint(x: margin, y: sheetSize.height - margin - 22),
            withAttributes: [
                .font: NSFont(name: "Menlo-Bold", size: 20) ?? NSFont.boldSystemFont(ofSize: 20),
                .foregroundColor: NSColor.white,
            ]
        )

        let captionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Menlo", size: 9) ?? NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor(white: 0.78, alpha: 1),
        ]

        for (index, entry) in entries.enumerated() {
            let column = index % columns
            let row = index / columns
            let originX = margin + CGFloat(column) * cellSize.width
            let originY = sheetSize.height - margin - titleHeight - CGFloat(row + 1) * cellSize.height

            let iconRect = NSRect(
                x: originX + (cellSize.width - cellIconSize) / 2,
                y: originY + captionHeight,
                width: cellIconSize,
                height: cellIconSize
            )
            cells[index].draw(in: iconRect)

            let footprint = entry.zone.footprintSize
            let caption = footprint > 1 ? "\(entry.label)  \(footprint)×\(footprint)" : entry.label
            let captionSize = caption.size(withAttributes: captionAttributes)
            caption.draw(
                at: NSPoint(
                    x: originX + (cellSize.width - captionSize.width) / 2,
                    y: originY + (captionHeight - captionSize.height) / 2
                ),
                withAttributes: captionAttributes
            )
        }

        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Layout + output plumbing

    private static let cellIconSize: CGFloat = 132
    private static let captionHeight: CGFloat = 22
    private static let margin: CGFloat = 20
    private static let titleHeight: CGFloat = 34
    private static var cellSize: CGSize {
        CGSize(width: cellIconSize + 16, height: cellIconSize + captionHeight + 8)
    }

    private static func outputURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["CONTACT_SHEET_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        // This file lives at <repo>/AlphaPlusPlusTests/, so two levels up is
        // the repo root — more reliable than the test runner's cwd, which is
        // not the repo when xcodebuild drives the run.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.appendingPathComponent("build/ContactSheet/zone-icons.png")
    }
}
