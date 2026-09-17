import XCTest
import SwiftUI
@testable import AlphaPlusPlus

/// Renders the cockpit's components to a PNG.
///
/// **Why the UI needs this as much as the buildings did.** Every art decision
/// in this project is reviewed on a render rather than argued about, because
/// "look at the art, don't imagine it" has caught something every single time.
/// The chrome had no such render — it was only ever checked by running the app,
/// which on this machine means a remote desktop session that does not reliably
/// hand back a screenshot.
///
/// `ImageRenderer` turns a SwiftUI view into a bitmap with no window involved,
/// so the toolbar gets the same treatment the map already has: change it, look
/// at it, then decide.
@MainActor
final class RetroUIContactSheetTests: XCTestCase {

    func testRenderComponentSheet() throws {
        try render(name: "retro-ui", content: componentSheet)
    }

    /// The **real** `GameView`, not a reconstruction of it.
    ///
    /// The cockpit render assembles the same components in the same order, but
    /// it is still a second copy of the layout — and a second copy can drift
    /// from the first without either one failing. This renders the view the app
    /// actually shows. The map itself comes out blank (an `NSViewRepresentable`
    /// has no window here), which is fine: the map has its own renders, and
    /// what this is checking is the chrome around it.
    func testRenderLiveGameView() throws {
        let controller = GameController()
        controller.selectTool(.commercial)
        // With the pointer over a lot, so the inspector is in the picture. It
        // overlays the map's top-right corner, which is exactly the sort of
        // placement that looks fine in isolation and covers something it
        // should not once it is in the real view.
        controller.inspect(at: GridPosition(x: 4, y: 4))
        try render(name: "retro-live", content:
            GameView(controller: controller).frame(width: 1400, height: 760))
    }

    /// **City Hall has no render, and it is the panel that most needs one.**
    /// Phase 4 of the cockpit found two bugs in it by rendering it — a
    /// `ScrollView` that blanked the whole body, and a native `Toggle` that
    /// did not draw — and then the render went away with the mock cockpit
    /// sheet. It is the tallest thing in the UI, it lays out in two hand-split
    /// columns, and phase 6 just added three funding rows to it. A layout that
    /// splits by hand and grows by hand is exactly the layout that quietly
    /// stops fitting.
    func testRenderCityPanel() throws {
        let controller = GameController()
        controller.setFundingLevel(0.5, for: .road)
        controller.setOrdinance(\.neighborhoodWatch, active: true)
        try render(name: "retro-city-hall", content:
            CityPanel(controller: controller, dismiss: {}))
    }

    /// **Every state the inspector can be in, side by side.**
    ///
    /// The panel's whole job is telling states apart, so reviewing it one
    /// state at a time would flatter it exactly the way the overlay render did
    /// while it had no pipes in the fixture. A player never sees these
    /// together; the point of putting them together is that *I* can tell
    /// whether "on fire" and "not desirable enough" read differently at a
    /// glance, which is the property that matters and the one a single panel
    /// cannot show.
    func testRenderInspectorStates() throws {
        let states = Self.inspectorStates()
        try render(name: "retro-inspector", content:
            VStack(alignment: .leading, spacing: 14) {
                Text("INSPECTOR — EVERY STATE")
                    .font(.system(size: 13, weight: .bold)).tracking(2)
                    .foregroundStyle(RetroUITheme.textPrimary)
                ForEach(Array(stride(from: 0, to: states.count, by: 3)), id: \.self) { start in
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(states[start ..< min(start + 3, states.count)], id: \.0) { state in
                            InspectorPanel(report: state.1)
                        }
                    }
                }
            }
            .padding(20)
            .background(RetroUITheme.background)
        )
    }

    /// One real `TileReport` per interesting `LotStatus`, built by putting a
    /// city into the state rather than by hand-assembling a report — a
    /// hand-made report could describe a city that cannot exist.
    private static func inspectorStates() -> [(String, TileReport)] {
        let origin = GridPosition(x: 0, y: 0)
        func base(_ zone: ZoneType = .residential, density: Int = 0) -> CityMap {
            var map = CityMap(width: 20, height: 20)
            for x in 0 ..< 20 { map[GridPosition(x: x, y: 2)].zone = .road }
            map.placeBuilding(zone: zone, origin: origin)
            for cell in map.footprintCells(origin: origin, size: zone.footprintSize) {
                map[cell].density = density
            }
            map.cityDemand = CityDemand(residential: 0.6, commercial: 0.6, industrial: 0.6)
            return map
        }
        func report(_ map: CityMap) -> TileReport { TileReport.make(at: origin, in: map) }

        var burning = base(.industrial, density: 4)
        for cell in burning.footprintCells(origin: origin, size: 2) {
            burning[cell].fireTicks = 2
            burning[cell].damagedBy = .fireStation
        }

        var building = base(density: 1)
        for cell in building.footprintCells(origin: origin, size: 2) {
            building[cell].constructionRemaining = 5
        }

        var abandoning = base(density: 3)
        abandoning.cityDemand = CityDemand(residential: -1, commercial: -1, industrial: -1)

        var cutOff = base(density: 3)
        for x in 0 ..< 20 { cutOff[GridPosition(x: x, y: 2)].zone = .empty }

        var worn = base(density: 2)
        worn[GridPosition(x: 1, y: 2)].wear = 0.8

        // **A lot with everything.** Without it every pill in the sheet is
        // drawn in its "off" state and the render says nothing about whether
        // "covered" and "not covered" are distinguishable — which is the only
        // question a row of pills exists to answer. Same trap the overlay
        // render fell into with a fixture that had no pipes in it.
        var served = base(density: 4)
        served.placeBuilding(zone: .policeStation, origin: GridPosition(x: 3, y: 0))
        served.placeBuilding(zone: .fireStation, origin: GridPosition(x: 6, y: 0))
        served.placeBuilding(zone: .school, origin: GridPosition(x: 9, y: 0))
        served.placeBuilding(zone: .hospital, origin: GridPosition(x: 12, y: 0))
        // Piped and wired rather than merely nearby: the first version put the
        // tower and generator a few tiles off and trusted
        // `Water.directSupplyRadius` to bridge the gap, and the render showed
        // both pills dark — so the "fully served" panel was quietly reporting
        // a lot with no utilities and a headline to match.
        served.placeBuilding(zone: .waterTower, origin: GridPosition(x: 3, y: 4))
        served.placeBuilding(zone: .generator, origin: GridPosition(x: 6, y: 4))
        for x in 0 ... 7 {
            served[GridPosition(x: x, y: 3)].hasPipe = true
            served[GridPosition(x: x, y: 3)].hasPowerLine = true
        }
        for y in 0 ... 4 {
            served[GridPosition(x: 1, y: y)].hasPipe = true
            served[GridPosition(x: 1, y: y)].hasPowerLine = true
        }
        served[GridPosition(x: 3, y: 4)].hasPipe = true
        served[GridPosition(x: 6, y: 4)].hasPowerLine = true
        served.waterSupply = Water.computeSupply(for: served)
        served.powerSupply = PowerGrid.computeSupply(for: served, outageActive: false)

        return [
            ("served", report(served)),
            ("ready", report(base(density: 1))),
            ("needs-water", report(base(density: CitySimulator.waterRequiredFromLevel - 1))),
            ("burning", report(burning)),
            ("abandoning", report(abandoning)),
            ("cut-off", report(cutOff)),
            ("building", report(building)),
            ("worn", report(worn)),
            ("empty", TileReport.make(at: GridPosition(x: 15, y: 15), in: base())),
        ]
    }

    private var componentSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("RETRO UI — COCKPIT PARTS")
                .font(.system(size: 13, weight: .bold)).tracking(2)
                .foregroundStyle(RetroUITheme.textPrimary)

            RetroPanel(title: "Tools", accent: RetroUITheme.secondaryAccent) {
                HStack(spacing: RetroMetrics.gutter) {
                    RetroToolChip(title: "Bulldoze", accent: .red, action: {})
                    RetroToolChip(title: "Residential", cost: 100,
                                  accent: RetroUITheme.accent(for: .residential),
                                  isSelected: true, action: {})
                    RetroToolChip(title: "Road", cost: 10,
                                  accent: RetroUITheme.accent(for: .road), action: {})
                    RetroToolChip(title: "Stadium", cost: 5000,
                                  accent: RetroUITheme.accent(for: .stadium),
                                  lockedBy: "740 more residents", action: {})
                }
            }

            HStack(alignment: .top, spacing: RetroMetrics.gutter) {
                RetroPanel(title: "Utilities", accent: RetroUITheme.accent(for: .waterTower)) {
                    VStack(alignment: .leading, spacing: 8) {
                        RetroMeter(label: "Water", fill: 0.6, detail: "120/200",
                                   accent: RetroUITheme.accent(for: .waterTower))
                        RetroMeter(label: "Power", fill: 1.3, detail: "520/400",
                                   accent: RetroUITheme.accent(for: .powerPlant))
                    }
                    .frame(width: 150)
                }
                RetroPanel(title: "City", accent: RetroUITheme.primaryAccent) {
                    HStack(spacing: 16) {
                        RetroStatTile(label: "Population", value: "3,984",
                                      history: [10, 220, 900, 2600, 3984], accent: .green)
                        RetroStatTile(label: "Treasury", value: "$1,482,910", detail: "+$1,798/tick",
                                      history: [100, 900, 1400, 1300, 1482], accent: .yellow,
                                      minimumWidth: 132)
                    }
                }
                RetroPanel(title: "Alerts", accent: .orange) {
                    VStack(alignment: .leading, spacing: 6) {
                        RetroBadge(text: "⚠ Outage — grid unpowered", accent: .red, isUrgent: true)
                        RetroBadge(text: "Unlocked: Hospital", accent: .green)
                    }
                }
            }
        }
        .padding(20)
        .background(RetroUITheme.background)
    }

    private func render(name: String, content: some View) throws {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "ImageRenderer produced nothing")
        let data = try XCTUnwrap(
            NSBitmapImageRep(data: image.tiffRepresentation ?? Data())?.representation(using: .png, properties: [:]),
            "failed to encode \(name)"
        )
        let destination = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ContactSheet/\(name).png")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: destination)
        print("🎛  \(name): \(destination.path) (\(data.count) bytes)")
        XCTAssertGreaterThan(data.count, 0)
    }
}
