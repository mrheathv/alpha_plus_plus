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
            toolRail
            Group {
                if let scene {
                    GameSpriteView(scene: scene)
                } else {
                    Color.clear
                }
            }
            .frame(minWidth: 760, minHeight: 420)
            .overlay(alignment: .topTrailing) { inspector }
            .overlay(alignment: .topLeading) { transitEditor }
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
            dashboard
        }
        .onChange(of: controller.cityGeneration) {
            // A load can change the tile count, so the scene's sprites no
            // longer match the map one-to-one — the same rebuild-and-recentre
            // the Reset button does for a map-size change. See
            // `GameController.cityGeneration`.
            scene?.rebuildEntireGrid()
            scene?.centerCameraOnMap()
        }
        .onChange(of: controller.restyleRequests) {
            // A style change redraws the same city rather than a different
            // one, so no recentre — the camera should not move under a player
            // who is comparing two looks.
            scene?.restyle()
        }
        .onAppear {
            if scene == nil {
                scene = GameScene(controller: controller)
            }
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
    private var toolRail: some View {
        zoningRow
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

    /// Everything the city tells *you*, below the map.
    private var dashboard: some View {
        HStack(alignment: .top, spacing: RetroMetrics.gutter) {
            RetroPanel(title: "Simulation", accent: RetroUITheme.primaryAccent) {
                VStack(alignment: .leading, spacing: 8) {
                    Button(controller.isRunning ? "Pause" : "Play") {
                        controller.isRunning.toggle()
                    }
                    .buttonStyle(RetroButtonStyle(
                        accent: controller.isRunning ? .orange : .green, isSelected: true
                    ))
                    // **On screen, not only in a menu.** The speed control
                    // has existed and worked since the simulation clock did,
                    // bound in the menu bar and nowhere else — the last of the
                    // things this project already had to drag out of a menu
                    // once, when tax, funding, ordinances and debt were all
                    // menu-only and the whole economic half of the game was
                    // invisible to anyone who did not go looking.
                    //
                    // Next to Play because it *is* Play: how fast is the same
                    // question as whether.
                    // **Both rows are labelled, and they have to be.** Adding
                    // the speed control put two pickers next to each other
                    // whose selected chip both read "Normal" — one meaning 1×
                    // speed and the other meaning no overlay. The render made
                    // that obvious instantly; unlabelled, the pair is a wall
                    // of eleven identical buttons with the same word lit twice
                    // in it. The overlay row had been unlabelled since it was
                    // written and got away with it only by being alone.
                    RetroSectionLabel(text: "Speed")
                    RetroSegmentedPicker(
                        options: SimulationSpeed.allCases,
                        label: \.displayName,
                        selection: $controller.simulationSpeed,
                        accent: controller.isRunning ? .orange : RetroUITheme.textSecondary
                    )
                    RetroSectionLabel(text: "View")
                    RetroSegmentedPicker(
                        options: OverlayMode.allCases,
                        label: \.displayName,
                        selection: $controller.overlayMode
                    )
                    // Reachable without the menu bar. Tax, funding, ordinances
                    // and debt were all menu-only, which made the whole
                    // economic half of the game invisible to anyone who did
                    // not go looking in a menu for it.
                    Button("City Hall…") { controller.isShowingCityPanel = true }
                        .buttonStyle(RetroButtonStyle(accent: RetroUITheme.secondaryAccent))
                    // A keyboard control nobody is told about is a keyboard
                    // control nobody uses. One line, under the button the
                    // space bar duplicates, which is where a player looking
                    // for a faster way to do this would already be looking.
                    Text("Space to pause · WASD or arrows to pan")
                        .font(.system(size: 9))
                        .foregroundStyle(RetroUITheme.textSecondary)
                }
            }

            RetroPanel(title: "City", accent: RetroUITheme.primaryAccent) {
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

            RetroPanel(title: "Alerts", accent: .orange) {
                alerts
            }

            Spacer(minLength: 0)
        }
        .padding(RetroMetrics.gutter)
        .background(RetroUITheme.background)
        .overlay(alignment: .top) { sunBleed }
        .overlay(alignment: .top) { neonSeam }
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
    private var alerts: some View {
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
    private var zoningRow: some View {
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
            ViewThatFits(in: .horizontal) {
                toolChips
                ScrollView(.horizontal, showsIndicators: false) { toolChips }
            }

        }
        // Keep the picker honest when something else changes the tool — a
        // future keyboard shortcut, or restoring a save.
        .onChange(of: controller.selectedTool) {
            if let category = ToolCategory.containing(controller.selectedTool), category != toolCategory {
                toolCategory = category
            }
        }
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
                lockedBy: unlocked ? nil : "\(controller.residentsNeeded(for: zone)) more residents",
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

    /// The cheapest still-locked tool, by the population it asks for.
    private var nextUnlock: ZoneType? {
        ZoneType.allCases
            .filter { !controller.isUnlocked($0) }
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
