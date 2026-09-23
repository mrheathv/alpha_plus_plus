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

    /// Set when an open or save fails; `RootView` presents it and clears it.
    /// A published string rather than a thrown error because by the time it
    /// reaches here there is nothing left to do but tell the player.
    @Published var errorMessage: String?

    /// Whether the title screen is up.
    ///
    /// On the document rather than the controller because it is a statement
    /// about the *app* — which screen you are looking at — and the controller
    /// is the city. Starts true: a game opens on something that tells you
    /// what it is.
    @Published var isShowingTitle = true {
        didSet {
            // Back to the title is a natural checkpoint: the player may quit
            // from there, and a city left behind should be the one saved.
            if isShowingTitle, !oldValue { autosave?.saveIfChanged(controller, origin: currentURL) }
        }
    }

    // MARK: - Autosave

    /// See `CityAutosave`. `nil` in every test, so the suite never writes into
    /// a player's Application Support folder.
    let autosave: CityAutosave?

    /// Whether the previous session ended without a clean quit — a crash, a
    /// force-quit, a flat battery. Read once, at launch.
    let previousSessionEndedBadly: Bool

    /// The autosave on offer, if any. Refreshed when the title screen asks.
    @Published private(set) var recoverable: CityAutosave.Metadata?

    private var autosaveTimer: Timer?
    private var terminationObserver: NSObjectProtocol?

    /// `controller` defaults to `nil` rather than to `GameController()`
    /// because a default argument expression is evaluated at the *call site*,
    /// which is outside this class's `@MainActor` isolation — constructing it
    /// in the body instead keeps that call on the main actor where it
    /// belongs.
    init(controller: GameController? = nil, autosave: CityAutosave? = nil) {
        self.controller = controller ?? GameController()
        self.autosave = autosave
        self.previousSessionEndedBadly = autosave?.beginSession() ?? false
        self.recoverable = autosave?.available
        guard autosave != nil else { return }

        autosaveTimer = Timer.scheduledTimer(withTimeInterval: CityAutosave.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.autosave?.saveIfChanged(self.controller, origin: self.currentURL)
            }
        }
        // Synchronous on quit: there is no "later" for a background write to
        // finish in once the process is going away.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.autosave?.saveNow(self.controller, origin: self.currentURL)
                self.autosave?.endSession()
            }
        }
    }

    /// Loads the autosave and picks up where it left off.
    ///
    /// **The origin comes back with it**, so Cmd-S afterwards writes to the
    /// player's own file rather than into the autosave slot, where the next
    /// autosave would overwrite it.
    func resumeAutosave() {
        guard let autosave, let metadata = autosave.available else { return }
        do {
            try controller.restore(from: autosave.read())
            currentURL = metadata.origin
            isShowingTitle = false
        } catch {
            errorMessage = CitySaveFile.describe(error)
        }
    }

    func refreshRecoverable() {
        recoverable = autosave?.available
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
