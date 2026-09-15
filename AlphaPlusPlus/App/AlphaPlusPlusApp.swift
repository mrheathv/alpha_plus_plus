import SwiftUI

/// Application entry point.
///
/// `@main` on a `SwiftUI.App` replaces the old `AppDelegate` + `main.swift` +
/// `MainMenu.xib` trio. We keep this file deliberately thin: it is the *shell*
/// (window, menus, app lifecycle) and knows nothing about the game beyond
/// "show a `GameView`" — plus, now, which menu commands exist.
@main
struct AlphaPlusPlusApp: App {

    /// The open city. Owned here rather than inside `GameView` because the
    /// File menu below needs the same instance the view is showing, and menu
    /// commands are built out here where a view's private state is out of
    /// reach. See `GameView.controller`'s own doc comment.
    @StateObject private var document = CityDocument()

    /// A binding onto one ordinance, so the City menu can show it as a
    /// checkmarked toggle.
    private func ordinance(_ keyPath: WritableKeyPath<Ordinances, Bool>) -> Binding<Bool> {
        Binding(
            get: { document.controller.isOrdinanceActive(keyPath) },
            set: { document.controller.setOrdinance(keyPath, active: $0) }
        )
    }

    var body: some Scene {
        WindowGroup("Alpha++") {
            RootView(document: document)
        }
        .commands {
            // A city builder is one document in one window for now. Dropping
            // the "New Window" menu item avoids a player accidentally opening
            // a second, unrelated city — still true now that save/load
            // exists, since one window is a deliberate scope decision rather
            // than something that was blocked on saving.
            CommandGroup(replacing: .newItem) { }

            CommandGroup(replacing: .saveItem) {
                Button("Open City…") { document.open() }
                    .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Save City") { document.save() }
                    .keyboardShortcut("s", modifiers: .command)

                Button("Save City As…") { document.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            // Everything below used to be toolbar rows. `GameView`'s own doc
            // comments had flagged the overflow risk twice before it actually
            // ran out of width; playing the game settled it. What moved is
            // what you set occasionally rather than click constantly — the
            // zoning tools stay on screen, since those *are* the game.
            CommandMenu("Simulation") {
                Button(document.controller.isRunning ? "Pause" : "Play") {
                    document.controller.isRunning.toggle()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Advance One Step") { document.controller.requestManualAdvance() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)

                Divider()

                Picker("Speed", selection: Binding(
                    get: { document.controller.simulationSpeed },
                    set: { document.controller.simulationSpeed = $0 }
                )) {
                    ForEach(SimulationSpeed.allCases) { speed in
                        Text(speed.displayName).tag(speed)
                    }
                }

                Divider()

                Menu("New City") {
                    ForEach(MapSize.allCases) { size in
                        Button(size.displayName) {
                            document.controller.selectedMapSize = size
                            document.controller.resetMap()
                        }
                    }
                }
            }

            CommandMenu("Overlay") {
                ForEach(Array(OverlayMode.allCases.enumerated()), id: \.element) { index, mode in
                    Button(mode.displayName) { document.controller.overlayMode = mode }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(index)")),
                            modifiers: .command
                        )
                }
            }

            CommandMenu("City") {
                Button("Budget…") { document.isShowingBudget = true }
                    .keyboardShortcut("b", modifiers: .command)

                Divider()

                Button("Issue Bond (+$\(GameController.bondIssueAmount))") {
                    _ = document.controller.issueBond()
                }
                Button("Repay Bond (-$\(GameController.bondIssueAmount))") {
                    document.controller.repayBond(GameController.bondIssueAmount)
                }

                Divider()

                // Toggles rather than a submenu: an ordinance is binary, and a
                // checkmark next to its name says its state without opening
                // anything.
                Toggle("Neighborhood Watch", isOn: ordinance(\.neighborhoodWatch))
                Toggle("Fire Inspections", isOn: ordinance(\.fireInspections))
                Toggle("Business Tax Break", isOn: ordinance(\.businessTaxBreak))
            }
        }
    }
}

/// Wraps `GameView` with the things that belong to the *document* rather than
/// to the game: the window title, and the alert shown when an open or save
/// fails.
///
/// A separate view rather than putting these on `GameView` directly, because
/// `GameView` is in `Rendering/` and is about drawing a city — whether that
/// city came from a file, and whether reading it worked, is not its concern.
struct RootView: View {
    @ObservedObject var document: CityDocument

    var body: some View {
        GameView(controller: document.controller)
            .navigationTitle(document.displayName)
            .sheet(isPresented: $document.isShowingBudget) {
                BudgetPanel(controller: document.controller) {
                    document.isShowingBudget = false
                }
            }
            .alert(
                "Couldn't open that city",
                isPresented: Binding(
                    get: { document.errorMessage != nil },
                    set: { if !$0 { document.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { document.errorMessage = nil }
            } message: {
                Text(document.errorMessage ?? "")
            }
    }
}
