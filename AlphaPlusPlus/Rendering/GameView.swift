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
            toolbar
            Group {
                if let scene {
                    GameSpriteView(scene: scene)
                } else {
                    Color.clear
                }
            }
            .frame(minWidth: 760, minHeight: 520)
            .ignoresSafeArea(edges: .bottom)
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
    private var toolbar: some View {
        VStack(spacing: 10) {
            zoningRow
            statusRow
        }
        .padding(10)
        .background(RetroUITheme.background)
        .overlay(alignment: .bottom) {
            // A thin glowing seam where the chrome ends and the map
            // begins, echoing the neon outline every building on the map
            // already has instead of a plain hairline divider.
            LinearGradient(
                colors: [RetroUITheme.primaryAccent.opacity(0.7), RetroUITheme.secondaryAccent.opacity(0.7)],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 1.5)
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

            ForEach(toolCategory.entries) { entry in
                chip(for: entry)
            }

            Spacer()
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

    /// One row: Play/Pause, the editing hint for whichever overlay is up, and
    /// the stats readout.
    ///
    /// Everything else that used to live here — speed, overlay picker, map
    /// size, Reset, the whole budget row and the ordinance toggles — moved to
    /// the Simulation, Overlay and City menus. The toolbar had grown to five
    /// rows and this file's own doc comments had twice flagged the overflow
    /// risk; adding the starter utilities to the zoning row is what finally
    /// spent the last of the width. What stayed is what you click constantly:
    /// the zoning tools, and Play.
    private var statusRow: some View {
        HStack(spacing: 16) {
            Button(controller.isRunning ? "Pause" : "Play") {
                controller.isRunning.toggle()
            }
            .buttonStyle(RetroButtonStyle(accent: controller.isRunning ? .orange : .green, isSelected: true))

            RetroSegmentedPicker(
                options: OverlayMode.allCases,
                label: \.displayName,
                selection: $controller.overlayMode
            )

            overlayHint

            Spacer()

            statsReadout
        }
    }

    /// Pipes and power lines are edited through the overlays, not the zoning
    /// toolbar (see `Tile.hasPipe`'s doc comment for why). This is the only
    /// hint a player gets that clicking now lays pipe or power line rather
    /// than applying whatever zone tool is selected — so it has to stay on
    /// screen even though the overlay picker itself moved to a menu.
    @ViewBuilder
    private var overlayHint: some View {
        switch controller.overlayMode {
        case .water:
            Text("Click to lay pipe \u{00B7} Right-click to remove")
                .font(.caption)
                .foregroundStyle(RetroUITheme.textSecondary)
                .lineLimit(1)
        case .power:
            VStack(alignment: .leading, spacing: 2) {
                Text("Click to lay power line \u{00B7} Right-click to remove")
                    .font(.caption)
                    .foregroundStyle(RetroUITheme.textSecondary)
                    .lineLimit(1)
                if controller.isPowerOutageActive {
                    Text("⚠ Outage — grid unpowered this tick")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
        default:
            // Naming the active overlay, since the picker that used to show it
            // is now behind a menu.
            if controller.overlayMode != .none {
                Text("Overlay: \(controller.overlayMode.displayName)")
                    .font(.caption)
                    .foregroundStyle(RetroUITheme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private var statsReadout: some View {
        HStack(spacing: 14) {
            statTile(label: "Population", value: "\(controller.population)", history: controller.history.map(\.population), color: .green)
            statTile(label: "Jobs", value: "\(controller.jobs)", history: controller.history.map(\.jobs), color: .cyan)
            statTile(label: "Treasury", value: "$\(controller.treasury)", detail: "\(netRevenueLabel)/tick", history: controller.history.map(\.treasury), color: .yellow)
                // A tooltip rather than another visible tile: `netRevenueLabel`
                // is one number with five things behind it, and the one a
                // player is least likely to guess at is `civicUpkeep` — it
                // scales with population rather than with anything they
                // placed, so without a breakdown it reads as money vanishing.
                // A tooltip shows it on demand without spending the toolbar
                // width this file's own doc comments already warn is scarce.
                .help(budgetBreakdown)
            demandTile
            utilityTile
            unlockTile
        }
    }

    /// What the city has just earned, or what it is working toward.
    ///
    /// The whole point of the ladder is having something to aim at, which only
    /// works if the next rung is visible. Shows the newest unlock the moment it
    /// lands, and otherwise the nearest one still out of reach.
    private var unlockTile: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let earned = controller.newlyUnlockedZones.first {
                Text("Unlocked: \(toolLabel(for: earned))")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(RetroUITheme.primaryAccent)
            } else if let next = nextUnlock {
                Text("Next: \(toolLabel(for: next)) at \(Unlocks.requiredPopulation(for: next))")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(RetroUITheme.textSecondary)
            } else {
                Text("All tools unlocked")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(RetroUITheme.textSecondary)
            }
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
