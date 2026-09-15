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
            simulationRow
            viewAndStatsRow
            budgetRow
            ordinancesRow
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

    private var zoningRow: some View {
        HStack {
            ForEach(ZoneType.allCases, id: \.self) { zone in
                let unlocked = controller.isUnlocked(zone)
                Button(toolLabel(for: zone)) {
                    controller.selectedTool = zone
                }
                .buttonStyle(RetroButtonStyle(accent: RetroUITheme.accent(for: zone), isSelected: controller.selectedTool == zone))
                // Disabled and dimmed rather than hidden. A tool you can see
                // but cannot use yet is the thing to aim at — hiding it would
                // turn the ladder into a series of surprises, and a player
                // would have no idea the stadium exists until it appears.
                .disabled(!unlocked)
                .opacity(unlocked ? 1 : 0.35)
                .help(unlocked
                      ? toolLabel(for: zone)
                      : "\(toolLabel(for: zone)) — needs \(Unlocks.requiredPopulation(for: zone)) residents "
                        + "(\(controller.residentsNeeded(for: zone)) to go)")
            }
            Spacer()
        }
    }

    private var simulationRow: some View {
        HStack {
            Button(controller.isRunning ? "Pause" : "Play") {
                controller.isRunning.toggle()
            }
            .buttonStyle(RetroButtonStyle(accent: controller.isRunning ? .orange : .green, isSelected: true))

            // Takes effect on the very next tick check, whether paused or
            // running — no need to gate this behind `isRunning`.
            RetroSegmentedPicker(options: SimulationSpeed.allCases, label: \.displayName, selection: $controller.simulationSpeed)

            // Manual single-step, independent of Play/Pause — useful for
            // watching one step at a time even while otherwise paused.
            // Pressing it while playing just adds one extra step; harmless,
            // so there's no need to disable it based on `isRunning`. Routes
            // through the scene's `runSimulationTick()` — the same method
            // the automatic clock calls — so a manual Advance flashes
            // hazard strikes exactly like an automatic tick does.
            Button("Advance") {
                scene?.runSimulationTick()
            }
            .buttonStyle(RetroButtonStyle(accent: RetroUITheme.secondaryAccent))

            Spacer()
        }
    }

    private var viewAndStatsRow: some View {
        HStack(spacing: 16) {
            // The hint below is scoped to the same 320pt column the picker
            // itself occupies (a `VStack`, not another item alongside it in
            // this already-crowded `HStack`) specifically so it never
            // widens this row — an earlier version put it inline here and
            // squeezed `statsReadout` at the far end into an unreadable,
            // character-wrapped column once the row ran out of width.
            VStack(alignment: .leading, spacing: 2) {
                RetroSegmentedPicker(options: OverlayMode.allCases, label: \.displayName, selection: $controller.overlayMode)
                    .frame(width: 410, alignment: .leading) // 5 segments now that Power joined Normal/Land Value/Traffic/Water

                // Pipes and power lines are edited here, not on the zoning
                // toolbar — see `Tile.hasPipe`'s doc comment for why. This
                // is the only hint a player gets that clicking now lays
                // pipe/power line instead of whatever zone tool happens to
                // be selected.
                if controller.overlayMode == .water {
                    Text("Click to lay pipe \u{00B7} Right-click to remove")
                        .font(.caption)
                        .foregroundStyle(RetroUITheme.textSecondary)
                        .frame(width: 320, alignment: .leading)
                } else if controller.overlayMode == .power {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Click to lay power line \u{00B7} Right-click to remove")
                            .font(.caption)
                            .foregroundStyle(RetroUITheme.textSecondary)
                        if controller.isPowerOutageActive {
                            Text("⚠ Outage in progress — grid unpowered this tick")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(width: 320, alignment: .leading)
                }
            }

            HStack(spacing: 6) {
                Text("New city size:").foregroundStyle(RetroUITheme.textSecondary)
                RetroSegmentedPicker(options: MapSize.allCases, label: \.displayName, selection: $controller.selectedMapSize)
            }
            .font(.callout)

            // Resize takes effect here, not when the picker above changes —
            // `resetMap()` reads `selectedMapSize` at the moment it runs.
            // Rebuilds the whole scene grid rather than `performFullMapChange`'s
            // `refreshAll()`, since a size change means the tile *count*
            // changed, not just tile contents (see `GameScene.rebuildEntireGrid()`).
            Button("Reset") {
                controller.resetMap()
                scene?.rebuildEntireGrid()
                // Explicit, and only here: a size change may have made the
                // old camera position invalid, so this is the one place
                // recentering actually belongs — see
                // `GameScene.rebuildEntireGrid()`'s own doc comment for why
                // it doesn't do this on its own any more.
                scene?.centerCameraOnMap()
            }
            .buttonStyle(RetroButtonStyle(accent: .red))

            Spacer()

            statsReadout
        }
    }

    /// The two levers `GameController` exposes for "how well-funded is the
    /// city" — one city-wide tax rate, plus one funding level per fundable
    /// service. Every other zone (`.residential`/`.commercial`/`.industrial`/
    /// `.road`/`.empty`) has nothing to show here: `ServiceFunding.level(for:)`
    /// always reports 1.0 for them because funding isn't a concept that
    /// applies, so this row only ever lists the five that actually respond
    /// to it — hard-coded rather than filtered from `ZoneType.allCases` at
    /// view-build time, since the set of fundable zones is exactly as fixed
    /// as `ServiceFunding`'s own five named fields.
    private static let fundableZones: [ZoneType] = [.policeStation, .fireStation, .publicTransit, .subway, .powerPlant, .stadium, .waterTower]

    private var budgetRow: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Text("Tax Rate").foregroundStyle(RetroUITheme.textSecondary)
                // 0% is a real setting (a tax holiday), same reasoning as
                // funding's floor below.
                RetroStepper(value: $controller.taxRate, range: 0 ... 2.0, step: 0.25)
            }

            Rectangle().fill(RetroUITheme.textSecondary.opacity(0.3)).frame(width: 1, height: 16)

            Text("Funding:").foregroundStyle(RetroUITheme.textSecondary)
            ForEach(Self.fundableZones, id: \.self) { zone in
                fundingControl(for: zone)
            }

            Rectangle().fill(RetroUITheme.textSecondary.opacity(0.3)).frame(width: 1, height: 16)

            bondsControl

            Spacer()
        }
        .font(.callout)
    }

    /// Borrowing against future tax revenue — see `GameController.issueBond()`'s
    /// own doc comment for the mechanic. Shows the running balance and its
    /// per-tick interest (the same "preview before it's charged" role
    /// `taxRevenue`/`netRevenueLabel` play elsewhere), plus the two actions:
    /// `+$5,000` deposits one bond's worth immediately (a no-op past
    /// `maxBondBalance`); `-$5,000` pays that much back early, clamped to
    /// whatever's actually outstanding and affordable. Both buttons stay
    /// tappable rather than disabling at the limits — clicking either one
    /// past its own guard is already a harmless no-op, the same shape
    /// `layPipe`'s "already piped" guard has.
    private var bondsControl: some View {
        HStack(spacing: 4) {
            Text("Bonds:").foregroundStyle(RetroUITheme.textSecondary)
            Text("$\(controller.bondBalance) owed (-$\(controller.bondInterest)/tick)")
                .foregroundStyle(RetroUITheme.textPrimary)
                .lineLimit(1)
            Button("+$\(GameController.bondIssueAmount)") {
                controller.issueBond()
            }
            .buttonStyle(RetroButtonStyle(accent: .yellow, isSelected: false))
            Button("-$\(GameController.bondIssueAmount)") {
                controller.repayBond(GameController.bondIssueAmount)
            }
            .buttonStyle(RetroButtonStyle(accent: .yellow, isSelected: false))
        }
    }

    /// City-wide policy toggles — see `Ordinances`' own doc comment for
    /// what each one actually does. A plain toggle button per ordinance,
    /// not a stepper: unlike tax rate or per-service funding, an ordinance
    /// is binary in every reference game that has one, so there's no
    /// in-between strength to dial. `isSelected` doubles as "currently
    /// active," the same way `zoningRow`'s buttons highlight whichever
    /// tool is selected right now.
    private var ordinancesRow: some View {
        HStack(spacing: 12) {
            Text("Ordinances:").foregroundStyle(RetroUITheme.textSecondary)
            ordinanceToggle(\.neighborhoodWatch, label: "Neighborhood Watch", accent: RetroUITheme.accent(for: .policeStation))
            ordinanceToggle(\.fireInspections, label: "Fire Inspections", accent: RetroUITheme.accent(for: .fireStation))
            ordinanceToggle(\.businessTaxBreak, label: "Business Tax Break", accent: RetroUITheme.accent(for: .commercial))
            Text("(-$\(Ordinances.costPerOrdinance(population: controller.population))/tick each, while active)")
                .font(.caption)
                .foregroundStyle(RetroUITheme.textSecondary)
                .lineLimit(1)
            Spacer()
        }
    }

    /// One ordinance's toggle button, tinted with the same accent the
    /// zone/service it affects already uses elsewhere (police blue for
    /// Neighborhood Watch, fire red for Fire Inspections, commercial blue
    /// for the tax break) — same "the control glows the color of the
    /// thing it controls" idea `fundingControl(for:)` already uses.
    /// `WritableKeyPath` rather than a named setter per ordinance, the
    /// same reasoning `GameController.setOrdinance(_:active:)`'s own doc
    /// comment gives.
    private func ordinanceToggle(_ ordinance: WritableKeyPath<Ordinances, Bool>, label: String, accent: Color) -> some View {
        let isActive = controller.isOrdinanceActive(ordinance)
        return Button(label) {
            controller.setOrdinance(ordinance, active: !isActive)
        }
        .buttonStyle(RetroButtonStyle(accent: accent, isSelected: isActive))
    }

    /// One `RetroStepper` per fundable service, each tinted with that
    /// service's own `RetroUITheme.accent(for:)` — a Police funding
    /// stepper glows the same blue the Police Station and its tool
    /// button do, rather than every stepper sharing one neutral color.
    /// Reads/writes through `GameController.fundingLevel(for:)`/
    /// `setFundingLevel(_:for:)` rather than binding to a `@Published`
    /// property directly — funding isn't one flat property on the
    /// controller, it's per-zone state living on `CityMap.serviceFunding`
    /// (see that type's own doc comment for why), so this small
    /// hand-built `Binding` is the adapter between "SwiftUI wants a
    /// single value to bind a control to" and "the real value is keyed
    /// by which service this particular control is for."
    private func fundingControl(for zone: ZoneType) -> some View {
        let binding = Binding<Double>(
            get: { controller.fundingLevel(for: zone) },
            set: { controller.setFundingLevel($0, for: zone) }
        )
        return HStack(spacing: 4) {
            Text(RenderPalette.displayName(for: zone)).foregroundStyle(RetroUITheme.textPrimary)
            // 0% is a real, expected lever (genre convention: fully
            // defund a service you can't afford right now, rather than
            // bulldoze it and lose the building entirely) -- not just a
            // "reduced" floor at 50%.
            RetroStepper(value: binding, range: 0 ... 2.0, step: 0.25, accent: RetroUITheme.accent(for: zone))
        }
    }

    private var statsReadout: some View {
        HStack(spacing: 14) {
            statTile(label: "Population", value: "\(controller.population)", history: controller.history.map(\.population), color: .green)
            statTile(label: "Jobs", value: "\(controller.jobs)", history: controller.history.map(\.jobs), color: .cyan)
            statTile(label: "Treasury", value: "$\(controller.treasury) (\(netRevenueLabel)/tick)", history: controller.history.map(\.treasury), color: .yellow)
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
        VStack(alignment: .leading, spacing: 2) {
            utilityLine(label: "Water", load: controller.waterLoad)
            utilityLine(label: "Power", load: controller.powerLoad)
        }
    }

    private func utilityLine(label: String, load: UtilityLoad) -> some View {
        Text("\(label): \(load.demand)/\(load.capacity)")
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(load.isOverloaded ? Color.red : RetroUITheme.textSecondary)
    }

    /// The one place `CitySimulator`'s demand-gated growth (see
    /// `GameController.cityDemand`'s own doc comment) is actually visible
    /// to the player — three `DemandBar`s, not sparklines, since demand
    /// is a current-state signal ("what does the city want right now"),
    /// not a history worth trending.
    private var demandTile: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Demand").font(.callout).foregroundStyle(RetroUITheme.textPrimary)
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

    private func statTile(label: String, value: String, history: [Int], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // `.lineLimit(1)` is the actual fix for a real bug a live
            // playtest found: this text's length grows with `controller`'s
            // own numbers (population, jobs, and especially treasury, which
            // this project's balance-tuning pass confirmed can climb into
            // 6-7+ digits over a long session) with nothing capping it.
            // Without a line limit, once it grew long enough to not fit
            // this HStack's available width, SwiftUI would wrap it to a
            // second line instead of truncating — changing this row's own
            // height, which changes the SpriteKit view's height below it,
            // which fires `GameScene.didChangeSize`, which recenters the
            // camera. Every tick these volatile numbers wobbled across
            // that wrap threshold, the *whole map* would visibly jump —
            // reading as "the city is shifting up and down," not as a
            // rendering performance problem at all.
            Text("\(label): \(value)").font(.callout).foregroundStyle(RetroUITheme.textPrimary).lineLimit(1)
            Sparkline(values: history, color: color)
                .frame(width: 70, height: 16)
        }
    }

    /// "Residential $100", but plain "Bulldoze" for `.empty` — it's free, so
    /// a "$0" suffix would just be noise on every press of that button.
    private func toolLabel(for zone: ZoneType) -> String {
        let name = RenderPalette.displayName(for: zone)
        guard zone.placementCost > 0 else { return name }
        return "\(name) $\(zone.placementCost)"
    }

}
