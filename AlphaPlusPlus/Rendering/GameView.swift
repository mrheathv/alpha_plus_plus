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
struct GameView: View {

    /// `@StateObject` (not a plain `let`/`@State`) because `GameController`
    /// is a *class* that SwiftUI needs to subscribe to: it re-renders this
    /// view's body whenever `map` or `selectedTool` change, which is how the
    /// stats bar updates after a click the SpriteKit scene handled.
    /// `@StateObject` guarantees SwiftUI creates it exactly once for this
    /// view's lifetime, the same "don't rebuild it on every body
    /// evaluation" concern `scene` below has.
    @StateObject private var controller = GameController()

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
    }

    // MARK: - Toolbar

    /// Two rows: zoning/simulation controls (what you're actively doing) on
    /// top, view options and the stats readout (what you're watching) below.
    /// One long row of ~14 controls plus three stats stopped being scannable
    /// once transit, overlays, and map size all landed in the same pass.
    private var toolbar: some View {
        VStack(spacing: 8) {
            zoningRow
            viewAndStatsRow
        }
        .padding(8)
        .background(.bar)
    }

    private var zoningRow: some View {
        HStack {
            ForEach(ZoneType.allCases, id: \.self) { zone in
                Button(toolLabel(for: zone)) {
                    controller.selectedTool = zone
                }
                .buttonStyle(.borderedProminent)
                .tint(controller.selectedTool == zone ? .accentColor : Color.gray.opacity(0.4))
            }

            Spacer(minLength: 12)

            Button(controller.isRunning ? "Pause" : "Play") {
                controller.isRunning.toggle()
            }
            .buttonStyle(.borderedProminent)
            .tint(controller.isRunning ? .orange : .green)

            // Takes effect on the very next tick check, whether paused or
            // running — no need to gate this behind `isRunning`.
            Picker("Speed", selection: $controller.simulationSpeed) {
                ForEach(SimulationSpeed.allCases) { speed in
                    Text(speed.displayName).tag(speed)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)

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
        }
    }

    private var viewAndStatsRow: some View {
        HStack(spacing: 16) {
            Picker("Overlay", selection: $controller.overlayMode) {
                ForEach(OverlayMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)

            HStack(spacing: 6) {
                Text("New city size:").foregroundStyle(.secondary)
                Picker("Map size", selection: $controller.selectedMapSize) {
                    ForEach(MapSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            .font(.callout)

            // Resize takes effect here, not when the picker above changes —
            // `resetMap()` reads `selectedMapSize` at the moment it runs.
            // Rebuilds the whole scene grid rather than `performFullMapChange`'s
            // `refreshAll()`, since a size change means the tile *count*
            // changed, not just tile contents (see `GameScene.rebuildEntireGrid()`).
            Button("Reset", role: .destructive) {
                controller.resetMap()
                scene?.rebuildEntireGrid()
            }

            Spacer()

            statsReadout
        }
    }

    private var statsReadout: some View {
        HStack(spacing: 14) {
            statTile(label: "Population", value: "\(controller.population)", history: controller.history.map(\.population), color: .green)
            statTile(label: "Jobs", value: "\(controller.jobs)", history: controller.history.map(\.jobs), color: .blue)
            statTile(label: "Treasury", value: "$\(controller.treasury) (\(netRevenueLabel)/tick)", history: controller.history.map(\.treasury), color: .yellow)
        }
    }

    /// "+$484" for a city in the black, "-$20" for one whose upkeep outpaces
    /// its tax base — `netRevenue` can go negative now that services cost
    /// something to run, so this can't just always prepend "+" the way the
    /// old tax-only readout did.
    private var netRevenueLabel: String {
        let net = controller.netRevenue
        return net < 0 ? "-$\(-net)" : "+$\(net)"
    }

    private func statTile(label: String, value: String, history: [Int], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label): \(value)").font(.callout)
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
