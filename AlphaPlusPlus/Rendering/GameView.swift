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
            .background(RetroUITheme.background)
            .overlay(alignment: .bottom) { neonSeam }
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
                }
            }

            RetroPanel(title: "City", accent: RetroUITheme.primaryAccent) {
                HStack(alignment: .top, spacing: 16) {
                    statTile(label: "Population", value: "\(controller.population)",
                             history: controller.history.map(\.population), color: .green)
                    statTile(label: "Jobs", value: "\(controller.jobs)",
                             history: controller.history.map(\.jobs), color: .cyan)
                    statTile(label: "Treasury", value: "$\(controller.treasury)",
                             detail: "\(netRevenueLabel)/tick",
                             history: controller.history.map(\.treasury), color: .yellow)
                        .help(budgetBreakdown)
                }
            }

            RetroPanel(title: "Demand", accent: RetroUITheme.secondaryAccent) {
                HStack(spacing: 8) {
                    DemandBar(label: "R", value: controller.cityDemand.residential)
                    DemandBar(label: "C", value: controller.cityDemand.commercial)
                    DemandBar(label: "I", value: controller.cityDemand.industrial)
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
        .overlay(alignment: .top) { neonSeam }
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
            if controller.isPowerOutageActive {
                RetroBadge(text: "⚠ Outage — grid unpowered", accent: .red, isUrgent: true)
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

            // **Scrolls rather than overflows.** A squeezed `HStack` shrinks
            // the last things it lays out first, so the row's rightmost tools
            // were the ones that vanished — and they are the ones still
            // locked, which is to say the ones a player most needs to see to
            // know what they are working toward. `.fixedSize()` on the chips
            // stops them compressing; this stops the row clipping them.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: RetroMetrics.gutter) {
                    ForEach(toolCategory.entries) { entry in
                        chip(for: entry)
                    }
                }
                .padding(.vertical, 1)
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
            RetroToolChip(
                title: entry.title,
                cost: entry.cost,
                accent: RetroUITheme.accent(for: entry.accentZone),
                isSelected: controller.overlayMode == overlay,
                action: {
                    controller.overlayMode = (controller.overlayMode == overlay) ? .none : overlay
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

    private func statTile(label: String, value: String, detail: String? = nil,
                          history: [Int], color: Color) -> some View {
        RetroStatTile(label: label, value: value, detail: detail, history: history, accent: color)
    }

    private func toolLabel(for zone: ZoneType) -> String {
        let name = RenderPalette.displayName(for: zone)
        guard zone.placementCost > 0 else { return name }
        return "\(name) $\(zone.placementCost)"
    }

}
