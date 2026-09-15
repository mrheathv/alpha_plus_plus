import AppKit
import Foundation
import UniformTypeIdentifiers

/// The open city, and its relationship to a file on disk.
///
/// Sits between `GameController` (which knows what a city *is*) and the menu
/// commands (which know what the player asked for). It exists so neither of
/// those has to grow a concept it shouldn't own: `GameController` stays about
/// simulation rather than about file paths, and the menu stays about
/// commands rather than about panels and error handling.
///
/// Deliberately *not* `NSDocument`/`DocumentGroup`. Those bring a whole
/// multi-window, multi-document architecture, and `AlphaPlusPlusApp` already
/// made the opposite call explicitly — it removes the New Window menu item
/// because "a city builder is one document in one window for now." This is
/// the smallest thing that honours that decision while still giving the
/// player real Open/Save.
@MainActor
final class CityDocument: ObservableObject {

    let controller: GameController

    /// Where the open city was last saved or loaded from, if anywhere.
    /// `nil` for a city that has never been written to disk, which is what
    /// makes Save fall back to Save As the first time.
    @Published private(set) var currentURL: URL?

    /// Whether the budget sheet is up.
    ///
    /// Lives on the document rather than as view state because the City menu
    /// is what opens it, and menus are built above the view hierarchy with no
    /// way to reach into it.
    @Published var isShowingBudget = false

    /// Set when an open or save fails; `RootView` presents it and clears it.
    /// A published string rather than a thrown error because by the time it
    /// reaches here there is nothing left to do but tell the player.
    @Published var errorMessage: String?

    /// `controller` defaults to `nil` rather than to `GameController()`
    /// because a default argument expression is evaluated at the *call site*,
    /// which is outside this class's `@MainActor` isolation — constructing it
    /// in the body instead keeps that call on the main actor where it
    /// belongs.
    init(controller: GameController? = nil) {
        self.controller = controller ?? GameController()
    }

    /// The document's title, for the window and the save panel.
    var displayName: String {
        currentURL?.deletingPathExtension().lastPathComponent ?? CitySaveFile.defaultFileName
    }

    // MARK: - Commands

    /// Save to the current file, or ask where to put it if there isn't one.
    func save() {
        guard let url = currentURL else {
            saveAs()
            return
        }
        write(to: url)
    }

    /// Always ask where to put it.
    func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = displayName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        applyCityType(to: panel)
        if currentURL == nil, let directory = try? CitySaveFile.defaultDirectory() {
            panel.directoryURL = directory
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url)
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        applyCityType(to: panel)
        if let directory = try? CitySaveFile.defaultDirectory() {
            panel.directoryURL = directory
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(from: url)
    }

    // MARK: - The actual work

    func write(to url: URL) {
        do {
            try CitySaveFile.write(controller.snapshot(), to: url)
            currentURL = url
        } catch {
            errorMessage = CitySaveFile.describe(error)
        }
    }

    /// Reads `url` and, only if that fully succeeds, installs it.
    ///
    /// The ordering matters: `CitySaveFile.read` decodes *and* version-checks
    /// before `restore(from:)` touches anything, so a bad file leaves the
    /// city the player already had completely intact rather than half
    /// replaced by a file that turned out to be unreadable.
    func load(from url: URL) {
        do {
            let save = try CitySaveFile.read(from: url)
            try controller.restore(from: save)
            currentURL = url
        } catch {
            errorMessage = CitySaveFile.describe(error)
        }
    }

    /// Restricts a panel to city files.
    ///
    /// `UTType(filenameExtension:)` returns `nil` when nothing on the system
    /// claims the extension — which is the normal case here, since the app
    /// declares no document types in its Info.plist. Falling back to letting
    /// the panel accept anything is deliberate: a save panel that refuses to
    /// save because the OS has never heard of our extension would be a much
    /// worse failure than one that is simply not filtered.
    private func applyCityType(to panel: NSSavePanel) {
        if let type = UTType(filenameExtension: CitySaveFile.fileExtension) {
            panel.allowedContentTypes = [type]
        }
    }
}
