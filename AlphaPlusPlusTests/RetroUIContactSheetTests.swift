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
        // A city a couple of years old, so the date readout shows a real date
        // rather than the founding day — the case where every field is at its
        // shortest and nothing can be seen to overflow. Set rather than
        // ticked: eight hundred ticks of a live simulation cost this render
        // twenty seconds to produce a string.
        var map = CityMap(width: MapSize.medium.dimension, height: MapSize.medium.dimension)
        map.regionalEconomy = RegionalEconomy(elapsed: 800)
        let controller = GameController(map: map)
        controller.selectTool(.commercial)
        // With the pointer over a lot, so the inspector is in the picture. It
        // overlays the map's top-right corner, which is exactly the sort of
        // placement that looks fine in isolation and covers something it
        // should not once it is in the real view.
        controller.inspect(at: GridPosition(x: 4, y: 4))
        try render(name: "retro-live", content:
            GameView(controller: controller).frame(width: 1400, height: 760))
    }

    /// **The narrow window, which is where rows go wrong.**
    ///
    /// Every overflow this project has shipped looked fine at the width it
    /// was rendered at: the tool row that clipped its locked tools, the
    /// Alerts panel truncated to "Next: Police Stati…", the stat tiles that
    /// came out "POPULA…". There was no render anywhere at a width that
    /// squeezes, so the one thing that reliably breaks these rows was the one
    /// thing no picture could show.
    ///
    /// The View picker steps its wrap down through `ViewThatFits` rather than
    /// clipping, and the tool chips scroll rather than dropping the locked
    /// tools off the right — both only observable here.
    ///
    /// 1000×700 rather than smaller, because the map carries a
    /// `minHeight: 420` and the chrome wants about 215 on top of it — below
    /// roughly 640 points tall the whole `VStack` overflows and clips its own
    /// first row, which is a statement about the window's minimum size rather
    /// than about how these rows wrap.
    func testRenderLiveGameViewNarrow() throws {
        var map = CityMap(width: MapSize.medium.dimension, height: MapSize.medium.dimension)
        map.regionalEconomy = RegionalEconomy(elapsed: 800)
        let controller = GameController(map: map)
        controller.selectTool(.commercial)
        try render(name: "retro-live-narrow", content:
            GameView(controller: controller).frame(width: 1000, height: 700))
    }

    /// **City Hall has no render, and it is the panel that most needs one.**
    /// Phase 4 of the cockpit found two bugs in it by rendering it — a
    /// `ScrollView` that blanked the whole body, and a native `Toggle` that
    /// did not draw — and then the render went away with the mock cockpit
    /// sheet. It is the tallest thing in the UI, it lays out in two hand-split
    /// columns, and phase 6 just added three funding rows to it. A layout that
    /// splits by hand and grows by hand is exactly the layout that quietly
    /// stops fitting.
    /// **A panel without a render ships bugs**, and this project has the
    /// receipts: City Hall shipped two — a `ScrollView` that blanked the whole
    /// body, and a native `Toggle` that was the one control whose state was
    /// the point and the one control nobody could see — during the pass when
    /// it had no picture. `NewCityPanel` was given one from the start and it
    /// earned itself twice in the first minute.
    ///
    /// Both states of the motion toggle, because a chip that looks identical
    /// selected and unselected is exactly the failure the ordinance chips
    /// replaced a `Toggle` to avoid.
    func testRenderSettingsPanel() throws {
        let off = GameController()
        try render(name: "retro-settings", content:
            SettingsPanel(controller: off, dismiss: {}))

        let on = GameController()
        on.reduceMotion = true
        on.visualStyle = .classic
        defer { on.reduceMotion = false; on.visualStyle = .cinematic }
        try render(name: "retro-settings-reduced", content:
            SettingsPanel(controller: on, dismiss: {}))
    }

    func testRenderCityPanel() throws {
        let controller = GameController()
        controller.setFundingLevel(0.5, for: .road)
        controller.setOrdinance(\.neighborhoodWatch, active: true)
        try render(name: "retro-city-hall", content:
            CityPanel(controller: controller, dismiss: {}))
    }

    /// **The first thing anybody sees.**
    ///
    /// Also the one screen that has to survive being an App Store thumbnail,
    /// which is a question only a picture can answer. Rendered at a wide
    /// aspect, because the sun's placement and the horizon height are
    /// composed against the frame rather than centred in it.
    func testRenderTitleScreen() throws {
        let document = CityDocument()
        try render(name: "retro-title", size: CGSize(width: 900, height: 560),
                   content: TitleScreen(document: document, start: {}))
    }

    /// **The founding panel, and the reason it has a render at all.**
    ///
    /// City Hall shipped two bugs while it had no picture — a `ScrollView`
    /// that blanked the whole body, and a native `Toggle` whose state was the
    /// one thing nobody could see. This is the first screen a new player ever
    /// meets, so it gets one from the start.
    ///
    /// Rendered on `.river`, which is the only option whose summary line is
    /// load-bearing: a player picking it needs to know the map will be cut in
    /// two *before* they find out by building into it.
    func testRenderNewCityPanel() throws {
        let controller = GameController()
        controller.selectedTerrain = .river
        controller.selectedMapSize = .medium
        try render(name: "retro-new-city", content:
            NewCityPanel(controller: controller, dismiss: {}))
    }

    /// **The guide's three kinds of card, side by side**: a step with a
    /// button, a step whose tool is still locked, and the closing card.
    ///
    /// The locked one is the reason this exists. It is the only card whose
    /// button must *look* unavailable, and a neon button that looks identical
    /// disabled and enabled is a failure this project has already shipped
    /// once — the route editor's Finish button, found by rendering it.
    func testRenderGuidePanelStates() throws {
        var early = FirstCityGuide()
        var state = FirstCityGuide.State()
        state.roadTiles = 8
        early.update(with: state)

        var late = early
        state.residentialLots = 2; state.commercialLots = 1; state.industrialLots = 1
        state.isRunning = true; state.population = 12
        state.hasWaterSource = true; state.hasPowerSource = true; state.overlay = .problems
        late.update(with: state)

        var finished = late
        state.hasEmergencyService = true; state.isShowingCityPanel = true
        finished.update(with: state)

        try render(name: "retro-guide", content:
            HStack(alignment: .top, spacing: 14) {
                GuidePanel(guide: early, lockedReason: nil, onShortcut: { _ in }, onDismiss: {})
                GuidePanel(guide: late, lockedReason: "28 more residents", onShortcut: { _ in }, onDismiss: {})
                GuidePanel(guide: finished, lockedReason: nil, onShortcut: { _ in }, onDismiss: {})
            }
            .padding(16)
            .background(RetroUITheme.background)
        )
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

    /// **Every state the route editor can be in, side by side** — for the
    /// same reason the inspector gets this treatment. The panel is two
    /// completely different faces, a list and an editor, and each of those has
    /// states a player must be able to tell apart at a glance: a line with no
    /// riders yet against a line whose station has been demolished, a draft
    /// that can be finished against one that cannot.
    func testRenderTransitPanelStates() throws {
        var map = CityMap(width: 30, height: 12)
        for x in 0 ..< 30 { map[GridPosition(x: x, y: 0)].zone = .road }
        let stops = [GridPosition(x: 2, y: 2), GridPosition(x: 12, y: 2), GridPosition(x: 24, y: 2)]
        for stop in stops { map.placeBuilding(zone: .publicTransit, origin: stop) }
        let running = map.transit.add(mode: .bus, stops: [stops[0], stops[1]])
        let broken = map.transit.add(mode: .bus, stops: [stops[2], GridPosition(x: 28, y: 2)])
        let short = map.transit.add(mode: .bus, stops: [stops[0]])
        let full = map.transit.add(mode: .bus, stops: [stops[0], stops[2]])
        let routes = map.transit.routes(mode: .bus)

        func panel(_ draft: TransitRouteDraft?) -> TransitPanel {
            TransitPanel(
                mode: .bus, routes: routes, draft: draft,
                workingStops: [running: 2, broken: 1, short: 1, full: 2],
                capacity: [running: 2 * TransitRoute.Mode.bus.capacityPerStop,
                           full: 2 * TransitRoute.Mode.bus.capacityPerStop],
                // A line that has not been routed yet reports "no data"
                // rather than zero, which are different facts — and one line
                // is over its capacity, which is the state that tells a player
                // to build another.
                ridership: { $0 == running ? 74 : ($0 == full ? 138 : nil) },
                onBegin: {}, onEdit: { _ in }, onDelete: { _ in },
                onUndo: {}, onCommit: {}, onCancel: {}
            )
        }

        try render(name: "retro-transit", content:
            VStack(alignment: .leading, spacing: 14) {
                Text("TRANSIT — EVERY STATE")
                    .font(.system(size: 13, weight: .bold)).tracking(2)
                    .foregroundStyle(RetroUITheme.textPrimary)
                HStack(alignment: .top, spacing: 12) {
                    panel(nil)
                    panel(TransitRouteDraft(mode: .bus))
                    panel(TransitRouteDraft(mode: .bus, stops: [stops[0]]))
                    panel(TransitRouteDraft(mode: .bus, editing: running, stops: Array(stops.prefix(3))))
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

    /// `size` for the screens that are *composed against a frame* rather
    /// than sized by their own content — the title screen puts its horizon
    /// and its sun at fractions of the view, so rendering it at its
    /// intrinsic size would be a picture of a shape nobody sees.
    private func render(name: String, size: CGSize? = nil, content: some View) throws {
        let renderer = ImageRenderer(
            content: AnyView(size.map { AnyView(content.frame(width: $0.width, height: $0.height)) }
                             ?? AnyView(content))
        )
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
