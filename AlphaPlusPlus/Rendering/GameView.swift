import SwiftUI
import SpriteKit

/// SwiftUI wrapper that hosts the SpriteKit scene, plus the chrome around
/// it: a tool picker, simulation controls, overlay/size pickers, and a
/// stats readout with trend sparklines.
///
/// Hosts via `GameSpriteView` (a custom `NSViewRepresentable`), not
/// SwiftUI's built-in `SpriteView` — this file's own doc comment used to say
/// "if we later need AppKit-level control, we swap this one file for an
/// `NSViewRepresentable` wrapping an `SKView`; `GameScene` doesn't change."
/// Trackpad pan/zoom turned out to be exactly that case, and the swap
/// happened exactly as predicted: this file changed one line, `GameScene`
/// didn't change at all (see `GameSKView`'s doc comment for why `SpriteView`
/// couldn't support it no matter how `GameScene` was written).
///
/// The toolbar itself is styled entirely through `RetroUITheme`/
/// `RetroButtonStyle`/`RetroSegmentedPicker`/`RetroStepper` rather than
/// default SwiftUI chrome — the one piece of the Phase 3 retrowave pass
/// that hadn't reached yet, a light OS panel sitting on top of a fully
/// neon game world until now.
struct GameView: View {

    /// `@ObservedObject`, and injected rather than created here.
    ///
    /// This was a `@StateObject` owned by this view until save/load arrived.
    /// The menu bar needs to reach the same controller in order to snapshot
    /// or replace the city, and menu commands are built in `AlphaPlusPlusApp`
    /// — above this view, with no way to reach down into its private state.
    /// So ownership moved up to `CityDocument`, which both this view and the
    /// commands are handed. `@ObservedObject` still subscribes exactly as
    /// `@StateObject` did; the only thing that changed is who guarantees the
    /// single instance, and `CityDocument` being the App's own `@StateObject`
    /// guarantees it just as well.
    @ObservedObject var controller: GameController

    /// The SpriteKit scene, created once and held here.
    ///
    /// This can't just be `@State private var scene = GameScene(controller: controller)`
    /// the way the single-`@State` version worked before: a property
    /// initializer runs before `controller` exists as a `@StateObject`, so
    /// there's nothing yet to hand the scene. Instead this starts `nil` and
    /// `.onAppear` fills it in exactly once — the `if scene == nil` guard is
    /// what makes "exactly once" true even though `.onAppear` can technically
    /// fire again (e.g. if the view is removed and reinserted).
    @State private var scene: GameScene?

    /// Which group of tools the zoning row is showing. See `ToolCategory` for
    /// why the row is grouped at all.
    @State private var toolCategory: ToolCategory = .zones

    var body: some View {
        VStack(spacing: 0) {
            if !controller.isScreenshotMode { toolRail }
            Group {
                if let scene {
                    // With the Metal renderer on, it draws the city underneath
                    // and the SpriteKit view on top keeps input, the camera
                    // and everything not yet ported. See `MapRenderer`.
                    ZStack {
                        if controller.mapRenderer == .metal {
                            MetalMapView(controller: controller, scene: scene)
                        }
                        GameSpriteView(scene: scene)
                    }
                } else {
                    Color.clear
                }
            }
            .frame(minWidth: 760, minHeight: 420)
            .overlay(alignment: .topTrailing) { if !controller.isScreenshotMode { inspector } }
            .overlay(alignment: .topLeading) {
                if !controller.isScreenshotMode {
                    transitEditor
                    landPanel
                }
            }
            .overlay(alignment: .bottomLeading) { if !controller.isScreenshotMode { guidePanel } }
            // **Focus on the map, not on the window.** `onKeyPress` needs a
            // focusable view, and putting it here rather than on the whole
            // `VStack` is what makes the City Hall sheet behave: a sheet takes
            // focus, so WASD stops steering the camera the moment a panel is
            // open, with no explicit "is a sheet up" check to forget about.
            .focusable()
            .focusEffectDisabled()
            .focused($mapHasFocus)
            // **Focused on appear**, or the feature is broken on launch: a
            // focusable view is not a focused one, and WASD would do nothing
            // until the player happened to click the map. Nobody discovers a
            // keyboard control they have to earn first.
            .onAppear { mapHasFocus = true }
            .onKeyPress(phases: [.down, .up]) { press in handle(press) }
            // A key held down when the window loses focus never sends its
            // `.up`, which would leave the camera sliding forever.
            .onChange(of: heldKeys.isEmpty) { syncKeyboardPan() }
            if !controller.isScreenshotMode { dashboard }
        }
        .onChange(of: controller.cityGeneration) {
            // A load can change the tile count, so the scene's sprites no
            // longer match the map one-to-one — the same rebuild-and-recentre
            // the Reset button does for a map-size change. See
            // `GameController.cityGeneration`.
            scene?.rebuildEntireGrid()
            scene?.centerCameraOnMap()
        }
        .onChange(of: controller.screenshotRequests) { saveScreenshot() }
        .onChange(of: controller.restyleRequests) {
            // A style change redraws the same city rather than a different
            // one, so no recentre — the camera should not move under a player
            // who is comparing two looks.
            scene?.restyle()
        }
        .onAppear {
            if scene == nil {
                let made = GameScene(controller: controller)
                made.runsDaysInBackground = true
                made.setDrawsCity(controller.mapRenderer == .classic)
                scene = made
            }
        }
        .onChange(of: controller.mapRenderer) {
            scene?.setDrawsCity(controller.mapRenderer == .classic)
        }
        // `overlayMode` is bound directly to the Picker below (`$controller.overlayMode`),
        // so nothing else runs when it changes — but every tile's *color*
        // needs to be recomputed when it does. `GameScene` never refreshes
        // on its own; every other full-map change (Advance, Reset) already
        // triggers its own explicit follow-up right at its call site.
        .onChange(of: controller.overlayMode) {
            scene?.refreshAll()
        }
        // The route diagram draws the line being drawn, and the panel's own
        // buttons — Undo, Cancel, Finish — change it without a click ever
        // reaching the map. Without this the draft on screen would only ever
        // update when you clicked a station, so pressing Cancel would leave a
        // dashed line lying across the city.
        .onChange(of: controller.routeDraft) {
            scene?.refreshTransitDiagram()
        }
        // The Simulation menu can't reach the scene, so it bumps a counter and
        // this turns it into a real tick — which flashes hazards the way an
        // automatic tick does, unlike calling `advanceSimulation()` directly.
        .onChange(of: controller.manualAdvanceRequests) {
            scene?.runSimulationTick()
        }
        // The whole toolbar is hand-colored against a dark background
        // regardless of the system appearance — forcing dark here keeps
        // native chrome that leaks through anywhere (menus, tooltips)
        // from clashing with it, and means the retrowave look doesn't
        // depend on the player's own Light/Dark Mode setting.
        .sheet(isPresented: $controller.isShowingNewCityPanel) {
            NewCityPanel(controller: controller) { controller.isShowingNewCityPanel = false }
        }
        .sheet(isPresented: $controller.isShowingSettingsPanel) {
            SettingsPanel(controller: controller) { controller.isShowingSettingsPanel = false }
        }
        .sheet(isPresented: $controller.isShowingCityPanel) {
            CityPanel(controller: controller) { controller.isShowingCityPanel = false }
        }
        .onChange(of: controller.isShowingCityPanel) {
            // Any key still held when the sheet opened never sends its `.up`,
            // so the camera would slide forever behind the panel.
            heldKeys.removeAll()
            syncKeyboardPan()
            if !controller.isShowingCityPanel { mapHasFocus = true }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Toolbar

    /// Five rows: zoning tools, then simulation controls, then view
    /// options and the stats readout (what you're watching), then budget
    /// levers (what you're paying for), then ordinances (city-wide
    /// policies you're paying for) on the bottom. This used to be three,
    /// zoning and simulation sharing one row — fine with compact native
    /// button chrome, not once `RetroButtonStyle`'s bigger, bolder buttons
    /// made 13 zone tools plus Play/Speed/Advance wider than a lot of
    /// window widths could hold, silently pushing Play off the visible
    /// edge. Same "split it when it stops fitting" reasoning this file
    /// keeps applying: ordinances could have joined `budgetRow` (they're
    /// another budget lever), but that row is already tax rate plus seven
    /// funding steppers plus the bonds control — adding three more toggles
    /// there risks the exact overflow this reasoning already fixed once.
    /// Everything you *do*, above the map.
    ///
    /// Split from the readouts deliberately. The old toolbar stacked both in
    /// one block above the map, which is how a row carrying ten things ended
    /// up with no give left: tools and readouts were competing for the same
    /// width, and the readouts always lost because the tools are what a player
    /// clicks. They are different kinds of thing — one is a verb, the other is
    /// the city answering back — so they get different edges of the screen.
    /// Writes a capture wherever the player says.
    ///
    /// A save panel rather than a fixed folder, because a screenshot is
    /// something you are about to *do something with* — attach it, upload it,
    /// put it in a listing — and having to go and find it first is the kind
    /// of small tax that makes a feature not get used.
    private func saveScreenshot() {
        guard let data = scene?.captureImage() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        // Named for the city's own calendar, so a folder of captures sorts
        // into the order the city grew in.
        let date = controller.map.date
        panel.nameFieldStringValue =
            String(format: "Alpha++ %04d-%02d-%02d.png", date.year, date.month, date.dayOfMonth)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    /// Everything you *do*, in two rows above the map.
    ///
    /// **Play, Speed, View and City Hall used to live in the dashboard**, in
    /// a panel called Simulation, and that was a straight violation of the
    /// rule this file states one comment up: verbs above the map, readouts
    /// below it. It cost real screen. The dashboard is an `HStack` of panels,
    /// so it is as tall as its tallest child — and that child was the View
    /// picker, thirteen overlay chips wrapped onto three rows, which grows
    /// every time an overlay is added. Measured at 1400×760 the chrome took
    /// **44% of the window** and the four readout panels beside it sat in
    /// whitespace matching a height none of them wanted.
    ///
    /// Moving the verbs up gives the map back about **126 points, a third
    /// more city**, and changes what the next overlay costs: it widens a rail
    /// that has room instead of pushing the map up.
    ///
    /// The View row is its own full-width line rather than sharing one.
    /// Thirteen chips want about 1,200 points, which is most of a window —
    /// and `ViewThatFits` steps the wrap down rather than letting it clip, so
    /// a narrow window gets two shorter rows instead of losing the overlays
    /// on the right. That is the same failure mode the tool row has already
    /// hit twice: the things that vanish first are the ones furthest right,
    /// which are the ones a player most needs to find.
    private var toolRail: some View {
        VStack(alignment: .leading, spacing: 6) {
            // **The rail decides the wrap, not the chip row inside it.**
            //
            // The first version put the run controls after the tool chips on
            // one line with a `Spacer` between, and at 900 points the chips
            // disappeared completely: the run group held its width, the chips
            // were squeezed to nothing, and the chip row's own `ViewThatFits`
            // then picked its scrolling variant — which `ImageRenderer`
            // cannot measure, so the most important row in the UI rendered
            // empty. That is the same failure this project already fixed once
            // with `ViewThatFits`, re-created by putting something greedy
            // beside it.
            //
            // The lesson is about nesting rather than about either control:
            // **a `ViewThatFits` whose last candidate always fits makes every
            // container above it think it fits too.** The scrolling row is
            // exactly such a candidate, so the choice has to be made here,
            // where the flat row is still the thing being measured.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: RetroMetrics.gutter) {
                    zoningRow(chips: toolChips)
                    runControls
                }
                VStack(alignment: .leading, spacing: 6) {
                    zoningRow(chips: toolChips)
                    runControls
                }
                VStack(alignment: .leading, spacing: 6) {
                    zoningRow(chips: ScrollView(.horizontal, showsIndicators: false) { toolChips })
                    runControls
                }
            }
            viewRow
        }
            .padding(.horizontal, RetroMetrics.gutter)
            .padding(.vertical, 8)
            // Span the window. Without this the row is only as wide as its
            // contents, so its background stops where the last chip does and
            // the window's own colour shows through either side — a white band
            // in a game that is otherwise entirely night. The old row got this
            // for free from a trailing `Spacer`, which went when the chips
            // moved into `ViewThatFits`.
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RetroUITheme.background)
            .overlay(alignment: .bottom) { neonSeam }
    }

    // MARK: - Keyboard

    /// Which pan keys are down right now.
    ///
    /// Tracked rather than acted on directly because holding a key should pan
    /// *continuously*: `onKeyPress` would otherwise deliver one event, pause
    /// for the OS key-repeat delay, and then repeat at the system rate, which
    /// reads as a stutter. `GameScene` integrates a velocity per frame
    /// instead — see `KeyboardControls.panPointsPerSecond`.
    @State private var heldKeys: Set<KeyEquivalent> = []

    /// Whether the map is what the keyboard is talking to. Given back to the
    /// map whenever a sheet closes, since a dismissed City Hall would
    /// otherwise leave the camera unsteerable with no visible reason why.
    @FocusState private var mapHasFocus: Bool

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard let command = KeyboardControls.command(for: press.key) else { return .ignored }

        guard KeyboardControls.isHeld(command) else {
            // A toggle fires once, on the way down. Acting on `.up` as well
            // would undo it the instant the player lifted the key.
            if press.phase == .down, case .togglePause = command {
                controller.isRunning.toggle()
            }
            return .handled
        }

        if press.phase == .down {
            heldKeys.insert(press.key)
        } else {
            heldKeys.remove(press.key)
        }
        syncKeyboardPan()
        return .handled
    }

    /// Sums every held direction into one velocity for the scene.
    ///
    /// Summing rather than taking the latest is what makes two keys at once
    /// travel diagonally, and what makes pressing opposite keys cancel out
    /// rather than fighting.
    private func syncKeyboardPan() {
        var pan = CGVector.zero
        for key in heldKeys {
            guard case let .pan(dx, dy) = KeyboardControls.command(for: key) else { continue }
            pan.dx += dx
            pan.dy += dy
        }
        scene?.keyboardPan = pan
    }

    /// The hover inspector, over the map's top-right corner.
    ///
    /// **Over the map rather than in the dashboard**, on two counts. The
    /// dashboard is full — it was already split off from the toolbar once
    /// because a single row carrying ten things had no give left — and an
    /// inspector belongs beside the thing it inspects, so the eye travels a
    /// short distance from the lot to the answer about it.
    ///
    /// **Docked rather than following the pointer.** A panel that chased the
    /// cursor would jitter as it moved, would cover the very lot being
    /// inspected, and would fall off the window edge near the map's corners —
    /// and this one carries a paragraph of text, which is the worst possible
    /// content for a target that keeps moving. Top-trailing specifically,
    /// because the tool rail is top-leading and the map's tallest buildings
    /// draw upward: the top-right is the emptiest part of an isometric
    /// diamond.
    ///
    /// `allowsHitTesting(false)` so it never eats a click meant for the map
    /// underneath — the panel appears exactly where a player might be about
    /// to build, and a read-only readout must not become an obstacle.
    @ViewBuilder private var inspector: some View {
        if let report = controller.inspectedReport {
            InspectorPanel(report: report)
                .padding(RetroMetrics.gutter)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// The route editor, over the map's top-left corner.
    ///
    /// Only while one of its own views is up, which is also when clicking a
    /// station means something — so the panel and the mode it belongs to
    /// appear and disappear together, and there is never a Finish button on
    /// screen for a gesture the map is not accepting.
    ///
    /// Unlike the inspector this one *takes* clicks: it has buttons. It sits
    /// under the tool rail rather than in it for the same reason the inspector
    /// is not in the dashboard — a control for the thing you are doing belongs
    /// next to where you are doing it.
    @ViewBuilder private var transitEditor: some View {
        if let mode = controller.overlayMode.routeMode {
            TransitPanel(
                mode: mode,
                routes: controller.map.transit.routes(mode: mode),
                // A bus draft is not the Subway view's business. Switching
                // views with a line half-drawn keeps the draft — you come back
                // to it — but the other view must not offer to finish it.
                draft: controller.routeDraft?.mode == mode ? controller.routeDraft : nil,
                workingStops: controller.workingStopCounts(),
                capacity: controller.routeCapacities(),
                ridership: { controller.map.trafficLoad.ridership(onRoute: $0) },
                onBegin: { controller.beginTransitRoute(mode: mode) },
                onEdit: { controller.editTransitRoute(id: $0) },
                onDelete: { controller.removeTransitRoute(id: $0) },
                onUndo: { controller.undoLastStop() },
                onCommit: { controller.commitTransitRoute() },
                onCancel: { controller.cancelTransitRoute() }
            )
            .padding(RetroMetrics.gutter)
            .transition(.opacity)
        }
    }

    /// The Land view's price and rank limit, where the route editor sits —
    /// the two are never up at once, since each belongs to its own view.
    @ViewBuilder private var landPanel: some View {
        if controller.overlayMode == .land, let land = controller.map.land {
            LandPanel(land: land, rank: controller.milestone, treasury: controller.treasury)
                .padding(RetroMetrics.gutter)
                .transition(.opacity)
        }
    }

    /// Whether a parcel could be bought right now, for the Alerts hint.
    ///
    /// Asked of the controller's own rule rather than restated: it is for
    /// sale if *some* parcel touching the city passes `landRefusal`.
    private var landIsForSale: Bool {
        guard controller.overlayMode != .land, let land = controller.map.land, !land.isComplete,
              land.owned.count < LandOwnership.allowance(for: controller.milestone),
              controller.treasury >= land.nextPrice else { return false }
        return true
    }

    /// The first-city guide, over the map's bottom-left. See `GuidePanel`.
    ///
    /// The only lock a step's shortcut can hit is an unlock, so that is the
    /// only reason worded here — and it is worded the way a locked toolbar
    /// chip words it, so the two say the same thing about the same tool.
    @ViewBuilder private var guidePanel: some View {
        if let guide = controller.guide {
            let locked: String? = {
                guard case .selectTool(let zone)? = guide.current?.shortcut,
                      !controller.isUnlocked(zone) else { return nil }
                return "\(controller.residentsNeeded(for: zone)) more residents"
            }()
            GuidePanel(
                guide: guide,
                lockedReason: locked,
                onShortcut: { controller.perform($0) },
                onDismiss: { controller.dismissGuide() }
            )
            .padding(RetroMetrics.gutter)
            .transition(.opacity)
        }
    }

    /// Everything the city tells *you*, below the map.
    /// The city answering back, and nothing you can press.
    ///
    /// **Readouts only, which is what fixed its height.** This used to open
    /// with a Simulation panel holding Play, Speed, the View picker and City
    /// Hall — every one of them a verb, in the strip this file reserves for
    /// the other kind of thing. Because the row is an `HStack` of panels it
    /// stood as tall as its tallest child, and that child was a picker that
    /// grows by a row every time an overlay lands. The four panels that
    /// remain want about a hundred points between them and were being
    /// stretched to nearly three hundred.
    ///
    /// They are all the same shape now — a label and a number, or a label and
    /// a bar — so the strip is as tall as a stat tile and stays that way as
    /// the game grows. See `toolRail` for where the verbs went.
    private var dashboard: some View {
        // **The goal gives way before anything else is squeezed.** The first
        // version always drew the requirements grid, and the narrow render
        // showed what that costs: at 1000 points the grid held its width and
        // Alerts truncated to "A…" — the urgent panel losing to the one that
        // can wait. A one-line goal panel did not fit either, because the
        // problem is a fifth panel, not how tall it is. So when the row cannot
        // hold it, the goal becomes one badge inside Alerts, beside the "Next:
        // Police Station at 40" that is already a goal of the same kind.
        ViewThatFits(in: .horizontal) {
            dashboardRow(compactGoal: false)
            dashboardRow(compactGoal: true)
        }
        .padding(RetroMetrics.gutter)
        .background(RetroUITheme.background)
        .overlay(alignment: .top) { sunBleed }
        .overlay(alignment: .top) { neonSeam }
    }

    private func dashboardRow(compactGoal: Bool) -> some View {
        HStack(alignment: .top, spacing: RetroMetrics.gutter) {
            // **The rank is the panel's title**, so the city's name for
            // itself costs no height in a strip whose height is the thing
            // this file keeps fighting for. See `Milestone`.
            RetroPanel(title: MilestoneText.title(for: controller.milestone),
                       accent: RetroUITheme.primaryAccent) {
                HStack(alignment: .top, spacing: 16) {
                    // **The date, first.** The cockpit used to say
                    // "+$1,798/tick", which is the simulation's own
                    // bookkeeping leaking into the game — nobody lives in
                    // ticks. One tick is one day (see `CityDate`), so the city
                    // can simply say what day it is and how long it has been
                    // going.
                    statTile(label: "Date", value: CalendarText.full(controller.map.date),
                             detail: CalendarText.age(controller.map.date), color: .purple)
                    statTile(label: "Population", value: "\(controller.population)",
                             history: controller.history.map(\.population), color: .green)
                    statTile(label: "Jobs", value: "\(controller.jobs)",
                             history: controller.history.map(\.jobs), color: .cyan)
                    statTile(label: "Treasury", value: "$\(controller.treasury)",
                             detail: "\(netRevenueLabel)/day",
                             history: controller.history.map(\.treasury), color: .yellow)
                        .help(budgetBreakdown)
                }
            }

            RetroPanel(title: "Demand", accent: RetroUITheme.secondaryAccent) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        DemandBar(label: "R", value: controller.cityDemand.residential)
                        DemandBar(label: "C", value: controller.cityDemand.commercial)
                        DemandBar(label: "I", value: controller.cityDemand.industrial)
                    }
                    regionMood
                }
            }

            RetroPanel(title: "Utilities", accent: RetroUITheme.accent(for: .waterTower)) {
                utilityTile
            }

            if !compactGoal { goalPanel }

            RetroPanel(title: "Alerts", accent: .orange) {
                alerts(withGoal: compactGoal)
            }

            Spacer(minLength: 0)
        }
    }

    /// "14 blocks need attention" — and, when something is failing rather
    /// than merely stuck, said louder.
    ///
    /// Counts rather than a list, because a list of four hundred lots is not
    /// an improvement on hovering over four hundred lots. The number tells you
    /// whether to look; the Problems view tells you where.
    @ViewBuilder private var attentionBadge: some View {
        let counts = controller.lotsNeedingAttention()
        let failing = (counts[.failing] ?? 0) + (counts[.critical] ?? 0)
        let blocked = counts[.blocked] ?? 0
        if failing > 0 {
            RetroBadge(text: "▼ \(failing) block\(failing == 1 ? "" : "s") failing · see Problems",
                       accent: .red, isUrgent: true)
        }
        if blocked > 0 {
            RetroBadge(text: "\(blocked) block\(blocked == 1 ? "" : "s") stuck · see Problems",
                       accent: RetroUITheme.secondaryAccent)
        }
    }

    /// What the region outside the city is doing, under the RCI bars it is
    /// pushing on.
    ///
    /// **It sits in the Demand panel rather than in Alerts**, because it is
    /// not an alert: a slump is weather, not a fault, and there is nothing
    /// broken to go and fix. It belongs next to the bars because it is the
    /// explanation for them — a player who sees R sagging needs to know
    /// whether they over-zoned housing or whether the whole region is down,
    /// since those two call for opposite responses. Without it the bars move
    /// for reasons nothing on screen accounts for, which is the shape of an
    /// unfair game.
    private var regionMood: some View {
        let mood = controller.map.regionalEconomy.mood
        return HStack(spacing: 6) {
            Text("REGION")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(RetroUITheme.textSecondary)
            RetroBadge(
                text: mood.label,
                accent: Self.moodAccent(mood),
                // Only a slump shouts. A boom is good news and needs no more
                // than a colour; making both urgent would train the player to
                // stop reading the badge.
                isUrgent: mood == .slump
            )
        }
    }

    private static func moodAccent(_ mood: RegionalEconomy.Mood) -> Color {
        switch mood {
        case .boom: return RetroUITheme.accent(for: .residential)
        case .steady: return RetroUITheme.textSecondary
        case .slump: return .orange
        }
    }

    /// A thin glowing seam where the chrome meets the map, echoing the neon
    /// outline every building already has instead of a plain hairline.
    private var neonSeam: some View {
        LinearGradient(
            colors: [RetroUITheme.primaryAccent.opacity(0.7), RetroUITheme.secondaryAccent.opacity(0.7)],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(height: 1.5)
    }

    /// Warm light bleeding up out of the dashboard.
    ///
    /// The map keeps a sun parked in world space below its own bottom edge —
    /// the retrowave "sun behind the skyline" the whole palette is built on.
    /// The dashboard sits exactly there on screen, so a warm glow along its top
    /// edge reads as that same sun continuing behind the chrome, rather than
    /// the city ending at a hard line and a control panel starting.
    private var sunBleed: some View {
        LinearGradient(
            colors: [Color(nsColor: RenderPalette.sunGlow).opacity(0.16), .clear],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: 46)
        .allowsHitTesting(false)
    }

    /// What the city is shouting about.
    ///
    /// **Alerts had no home, and one of them was invisible.** The power-outage
    /// warning lived inside the overlay hint, which only renders while the
    /// Power overlay is up — so a city could be blacked out and never say so
    /// unless the player happened to be looking at the right overlay. Anything
    /// urgent belongs somewhere always on screen.
    @ViewBuilder
    private func alerts(withGoal: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            // Fire goes first, above even the outage. It is the only thing in
            // the game that gets *worse* while you read about it, and the
            // answer to it — bulldoze the block, or get a fire station there —
            // is one the player has to take now rather than soon.
            if controller.burningBlocks > 0 {
                RetroBadge(
                    text: controller.burningBlocks == 1
                        ? "🔥 Fire — 1 block alight"
                        : "🔥 Fire — \(controller.burningBlocks) blocks alight",
                    accent: .orange,
                    isUrgent: true
                )
            }
            if controller.isPowerOutageActive {
                RetroBadge(text: "⚠ Outage — grid unpowered", accent: .red, isUrgent: true)
            }
            // How many blocks want looking at, and the overlay that shows
            // *which*. A count with no way to act on it would be worse than
            // silence, so the badge names the view that answers it.
            attentionBadge
            // An answer the player can act on right now, so it earns a line:
            // a city that can afford to grow and is allowed to should be told
            // where the land is sold.
            if landIsForSale, let price = controller.map.land?.nextPrice {
                RetroBadge(text: "Land for sale: $\(price) · Land view", accent: .orange)
            }
            if let rank = controller.newlyEarnedMilestones.last {
                RetroBadge(text: MilestoneText.earned(rank), accent: .green)
            } else if withGoal, let next = controller.nextMilestone {
                // The narrow form of the Goal panel: the rank, and the first
                // thing standing between the city and it.
                let blocking = next.requirements.first {
                    !$0.isMet(by: controller.scorecard, netRevenue: controller.netRevenue)
                }
                RetroBadge(
                    text: blocking.map {
                        "\(MilestoneText.name(next)): \(MilestoneText.label($0)) "
                            + MilestoneText.status($0, card: controller.scorecard, netRevenue: controller.netRevenue)
                    } ?? "\(MilestoneText.name(next)): all met",
                    accent: .green
                )
            }
            if let earned = controller.newlyUnlockedZones.first {
                RetroBadge(text: "Unlocked: \(RenderPalette.displayName(for: earned))", accent: .green)
            } else if let next = nextUnlock {
                RetroBadge(
                    text: "Next: \(RenderPalette.displayName(for: next)) at \(Unlocks.requiredPopulation(for: next))",
                    accent: RetroUITheme.primaryAccent
                )
            }
            switch controller.overlayMode {
            case .water:
                RetroBadge(text: "Click to lay pipe · Right-click removes",
                           accent: RetroUITheme.accent(for: .waterTower))
            case .power:
                RetroBadge(text: "Click to lay power line · Right-click removes",
                           accent: RetroUITheme.accent(for: .powerPlant))
            case .none:
                EmptyView()
            default:
                RetroBadge(text: "Overlay: \(controller.overlayMode.displayName)",
                           accent: RetroUITheme.textSecondary)
            }
        }
    }

    /// The bulldozer, a group picker, and the tools in the chosen group.
    ///
    /// Seventeen tools in one row had stopped fitting; see `ToolCategory`.
    /// Bulldoze sits outside the groups and never moves, because having to
    /// change category before you can undo a mistake would be miserable.
    private func zoningRow(chips: some View) -> some View {
        HStack(spacing: 10) {
            chip(for: .bulldozer)

            Rectangle().fill(RetroUITheme.textSecondary.opacity(0.3)).frame(width: 1, height: 20)

            RetroSegmentedPicker(
                options: ToolCategory.allCases,
                label: \.displayName,
                selection: Binding(
                    get: { toolCategory },
                    set: { category in
                        toolCategory = category
                        // Move the selection to something in the group the
                        // player just opened, so the highlighted tool is always
                        // one they can actually see.
                        if let first = category.tools.first, !category.tools.contains(controller.selectedTool) {
                            controller.selectedTool = first
                        }
                    }
                )
            )

            Rectangle().fill(RetroUITheme.textSecondary.opacity(0.3)).frame(width: 1, height: 20)

            // **Lays out flat when it fits, scrolls when it does not.**
            //
            // A squeezed `HStack` shrinks the last things it lays out first, so
            // the row's rightmost tools were the ones that vanished — and those
            // are the *locked* ones, which is to say exactly the ones a player
            // needs to see to know what they are working toward.
            //
            // A plain `ScrollView` fixes that and costs something that turned
            // out to matter more: `ImageRenderer` cannot measure scrolling
            // content, so the tool row — the most important row in the UI —
            // rendered completely empty in its own contact sheet. `ViewThatFits`
            // gets both: the flat row when there is room, which is the common
            // case and the one that renders, and the scrolling row only when
            // the window is genuinely too narrow.
            chips
        }
        // Keep the picker honest when something else changes the tool — a
        // future keyboard shortcut, or restoring a save.
        .onChange(of: controller.selectedTool) {
            if let category = ToolCategory.containing(controller.selectedTool), category != toolCategory {
                toolCategory = category
            }
        }
    }

    /// Play, how fast, and the way in to City Hall.
    ///
    /// Grouped apart from the tools because they are a different kind of verb
    /// — a tool acts on a lot, these act on the city — and kept on the same
    /// rail because both are things you press, which is the split `toolRail`
    /// exists to draw against the readouts below the map.
    private var runControls: some View {
        HStack(spacing: 10) {
            Button(controller.isRunning ? "Pause" : "Play") {
                controller.isRunning.toggle()
            }
            .buttonStyle(RetroButtonStyle(
                accent: controller.isRunning ? .orange : .green, isSelected: true
            ))

            // **On screen, not only in a menu.** The speed control existed
            // and worked from the day the simulation clock did, bound in the
            // menu bar and nowhere else — the last survivor of the problem
            // that once left tax, funding, ordinances and debt menu-only and
            // the whole economic half of the game invisible to anyone who did
            // not go looking.
            //
            // Next to Play because it *is* Play: how fast is the same
            // question as whether.
            RetroSegmentedPicker(
                options: SimulationSpeed.allCases,
                label: \.displayName,
                selection: $controller.simulationSpeed,
                accent: controller.isRunning ? .orange : RetroUITheme.textSecondary
            )

            Rectangle().fill(RetroUITheme.textSecondary.opacity(0.3)).frame(width: 1, height: 20)

            // Reachable without the menu bar, for the same reason.
            Button("City Hall…") { controller.isShowingCityPanel = true }
                .buttonStyle(RetroButtonStyle(accent: RetroUITheme.secondaryAccent))

            Button("Settings…") { controller.isShowingSettingsPanel = true }
                .buttonStyle(RetroButtonStyle(accent: RetroUITheme.textSecondary))
        }
    }

    /// Which map you are looking at.
    ///
    /// **Labelled, and it has to be.** Putting the speed control beside this
    /// one once produced two pickers whose selected chip both read "Normal" —
    /// one meaning 1× speed and the other meaning no overlay. The row had
    /// been unlabelled since it was written and got away with it only by
    /// being alone.
    private var viewRow: some View {
        HStack(spacing: 10) {
            RetroSectionLabel(text: "View")

            // Widest that fits, rather than a fixed wrap. At full width the
            // whole set is one line; narrower, it steps down to two or three
            // shorter ones. Nothing is ever clipped, which is the property
            // that matters — a picker missing its right-hand half looks like
            // a picker with fewer overlays in it.
            ViewThatFits(in: .horizontal) {
                overlayPicker(perRow: OverlayMode.allCases.count)
                overlayPicker(perRow: 7)
                overlayPicker(perRow: 5)
            }

            Spacer(minLength: RetroMetrics.gutter)

            // A keyboard control nobody is told about is a keyboard control
            // nobody uses. It rides the leftover width of this row rather
            // than costing a line of its own.
            Text("Space to pause · WASD or arrows to pan")
                .font(.system(size: 9))
                .foregroundStyle(RetroUITheme.textSecondary)
                .fixedSize()
        }
    }

    private func overlayPicker(perRow: Int) -> some View {
        RetroSegmentedPicker(
            options: OverlayMode.allCases,
            label: \.displayName,
            selection: $controller.overlayMode,
            perRow: perRow
        )
    }

    private var toolChips: some View {
        HStack(spacing: RetroMetrics.gutter) {
            ForEach(toolCategory.entries) { entry in
                chip(for: entry)
            }
        }
        .padding(.vertical, 1)
    }

    /// One toolbar entry, whatever kind it is.
    ///
    /// The layout used to branch: zones were drawn by one function, and pipes
    /// and power lines by another, reached through an `if category ==
    /// .utilities` wedged into the middle of the row. Anything that was not a
    /// `ZoneType` would have needed a third branch. `ToolbarEntry` says what a
    /// button *does*, so there is one builder and the row renders a list.
    @ViewBuilder
    private func chip(for entry: ToolbarEntry) -> some View {
        switch entry.action {
        case .zone(let zone):
            let unlocked = controller.isUnlocked(zone)
            RetroToolChip(
                title: entry.title,
                cost: entry.cost,
                accent: RetroUITheme.accent(for: entry.accentZone),
                isSelected: controller.selectedTool == zone && controller.overlayMode == .none,
                lockedBy: unlocked ? nil : lockHint(for: zone),
                // `selectTool` rather than assigning directly: picking a zone
                // also leaves a network overlay, so the two stay exclusive.
                action: { controller.selectTool(zone) }
            )
        case .network(let overlay):
            let unlocked = entry.unlockedBy.map { controller.isUnlocked($0) } ?? true
            RetroToolChip(
                title: entry.title,
                cost: entry.cost,
                accent: RetroUITheme.accent(for: entry.accentZone),
                isSelected: controller.overlayMode == overlay,
                lockedBy: unlocked ? nil : entry.unlockedBy.map {
                    "\(controller.residentsNeeded(for: $0)) more residents"
                },
                action: {
                    guard unlocked else { return }
                    if controller.overlayMode == overlay {
                        controller.overlayMode = .none
                        controller.cancelTransitRoute()
                    } else {
                        controller.overlayMode = overlay
                        // A route tool that raised its view and left you with
                        // no line to draw would be a mode with nothing in it.
                        // Picking it *is* starting a line, the way picking Pipe
                        // is starting to lay pipe.
                        if let mode = overlay.routeMode, controller.map.transit.routes(mode: mode).isEmpty {
                            controller.beginTransitRoute(mode: mode)
                        }
                    }
                }
            )
        }
    }

    /// What the next rank asks for, and where the city stands on each.
    ///
    /// **Every requirement at once**, in two columns rather than one line of
    /// progress. A rank is earned on a day the city meets all of them
    /// together, so a single bar would hide the one thing a player needs —
    /// *which* condition is holding them back. Two columns keep the panel to
    /// three rows, which is inside the height a stat tile already gives this
    /// strip: the dashboard stands as tall as its tallest panel, and phase 6
    /// of the cockpit was spent getting that height back.
    @ViewBuilder private var goalPanel: some View {
        if let next = controller.nextMilestone {
            RetroPanel(title: "Next: \(MilestoneText.name(next))", accent: .green) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    let requirements = next.requirements
                    ForEach(0 ..< (requirements.count + 1) / 2, id: \.self) { row in
                        GridRow {
                            requirementLine(requirements[row * 2])
                            if row * 2 + 1 < requirements.count {
                                requirementLine(requirements[row * 2 + 1])
                            }
                        }
                    }
                }
            }
        } else {
            RetroPanel(title: MilestoneText.topOfTheLadder, accent: .green) { EmptyView() }
        }
    }

    /// Met is lit, unmet is dim — the same way round as every other readout
    /// here. The tick carries it too, because a colour alone is a channel a
    /// colourblind player does not have (see `ColourAccessibilityTests`).
    private func requirementLine(_ requirement: Milestone.Requirement) -> some View {
        let met = requirement.isMet(by: controller.scorecard, netRevenue: controller.netRevenue)
        return HStack(spacing: 5) {
            Text(met ? "✓" : "·")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .frame(width: 8)
            Text(MilestoneText.label(requirement))
                .font(.system(size: 10, weight: .semibold))
            Text(MilestoneText.status(requirement, card: controller.scorecard,
                                      netRevenue: controller.netRevenue))
                .font(.system(size: 10, design: .monospaced))
                .opacity(0.8)
        }
        .fixedSize()
        .foregroundStyle(met ? Color.green : RetroUITheme.textSecondary)
    }

    /// What a locked tool is waiting for, in the words the gate uses: a rank
    /// reward names its rank, everything else the residents it still needs.
    private func lockHint(for zone: ZoneType) -> String {
        if let rank = RewardBuildings.requiredRank(for: zone),
           (controller.milestone.map { $0 < rank } ?? true) {
            return "Reach \(MilestoneText.name(rank))"
        }
        return "\(controller.residentsNeeded(for: zone)) more residents"
    }

    /// The cheapest still-locked tool, by the population it asks for.
    ///
    /// Rank rewards are left out: they ask for no residents, so by this
    /// measure they would always be "next, at 0" — and the Goal panel already
    /// names what they are waiting for.
    private var nextUnlock: ZoneType? {
        ZoneType.allCases
            .filter { !controller.isUnlocked($0) && RewardBuildings.requiredRank(for: $0) == nil }
            .min { Unlocks.requiredPopulation(for: $0) < Unlocks.requiredPopulation(for: $1) }
    }

    /// Water and power draw against capacity.
    ///
    /// Compact text rather than another sparkline tile: these are a
    /// current-state signal ("am I about to run out"), not a trend, the same
    /// reasoning `demandTile` already uses for the RCI bars. Turns red the
    /// moment a network is overloaded, because an overloaded network silently
    /// stops every high-density building in the city from growing — the
    /// single least guessable stall in the game without a readout.
    private var utilityTile: some View {
        VStack(alignment: .leading, spacing: 6) {
            meter(label: "Water", load: controller.waterLoad, accent: RetroUITheme.accent(for: .waterTower))
            meter(label: "Power", load: controller.powerLoad, accent: RetroUITheme.accent(for: .powerPlant))
            // Roads sit with the utilities rather than anywhere else because
            // the question is identical in shape: how much headroom is left
            // before something stops working. It reads as a *load* — a full
            // red bar means the network is falling apart — so it points the
            // same way the two above it do, which is what lets a player scan
            // all three without reading the labels.
            RetroMeter(
                label: "Roads",
                fill: controller.infrastructureWear,
                detail: "\(Int(controller.infrastructureWear * 100))% worn",
                accent: RetroUITheme.accent(for: .road)
            )
        }
        .frame(width: 104)
    }

    private func meter(label: String, load: UtilityLoad, accent: Color) -> some View {
        RetroMeter(
            label: label,
            // Zero capacity is "no utility built at all", which is not the same
            // as "empty" — an empty bar there would claim headroom the city
            // does not have.
            fill: load.capacity > 0 ? Double(load.demand) / Double(load.capacity) : (load.demand > 0 ? 2 : 0),
            detail: "\(load.demand)/\(load.capacity)",
            accent: accent
        )
    }

    /// The one place `CitySimulator`'s demand-gated growth (see
    /// `GameController.cityDemand`'s own doc comment) is actually visible
    /// to the player — three `DemandBar`s, not sparklines, since demand
    /// is a current-state signal ("what does the city want right now"),
    /// not a history worth trending.
    private var demandTile: some View {
        VStack(alignment: .leading, spacing: 2) {
            RetroSectionLabel(text: "Demand")
            HStack(spacing: 8) {
                DemandBar(label: "R", value: controller.cityDemand.residential)
                DemandBar(label: "C", value: controller.cityDemand.commercial)
                DemandBar(label: "I", value: controller.cityDemand.industrial)
            }
        }
    }

    /// "+$484" for a city in the black, "-$20" for one whose upkeep outpaces
    /// its tax base — `netRevenue` can go negative now that services cost
    /// something to run, so this can't just always prepend "+" the way the
    /// old tax-only readout did.
    /// Every term behind `netRevenueLabel`, spelled out for the tooltip.
    private var budgetBreakdown: String {
        let ordinances = controller.map.ordinances.totalUpkeepCost(population: controller.population)
        return [
            "Tax revenue:    +\(controller.taxRevenue)",
            "Infrastructure: -\(controller.upkeepCost)",
            "Civic services: -\(controller.civicUpkeep)",
            "Bond interest:  -\(controller.bondInterest)",
            "Ordinances:     -\(ordinances)",
        ].joined(separator: "\n")
    }

    private var netRevenueLabel: String {
        let net = controller.netRevenue
        return net < 0 ? "-$\(-net)" : "+$\(net)"
    }

    /// `history` defaults to empty: the date has no sparkline, because a
    /// number that only ever counts up by one draws a straight line and says
    /// nothing.
    private func statTile(label: String, value: String, detail: String? = nil,
                          history: [Int] = [], color: Color) -> some View {
        RetroStatTile(label: label, value: value, detail: detail, history: history, accent: color)
    }

}
