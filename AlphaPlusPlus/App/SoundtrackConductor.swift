import AppKit
import Foundation

/// **The soundtrack, playing.** Owns the `SoundtrackPlayer` and the
/// `MusicDirector` and ties them to the app: ten times a second it reads what
/// the city is doing, asks the director which cue that earns, and hands the
/// answer to the player, which crossfades.
///
/// Everything it drives already existed and was tested — the synth, the
/// score, the director, the player. What was missing was this: the half-dozen
/// lines that own a player and watch the game. A module nobody calls is a
/// control that does nothing, one level up, and the music had never played.
///
/// **Off unless the app turns it on**, for the reason `CityAutosave` is: only
/// `AlphaPlusPlusApp` constructs one. Every test builds a `CityDocument`
/// without it, so the suite never opens an audio device.
///
/// A timer rather than the frame loop because the music runs on the title
/// screen too, where there is no scene to hang it on — and ten ticks a second
/// is plenty for crossfades measured in seconds and a director that waits
/// forty seconds between changes.
@MainActor
final class SoundtrackConductor {

    /// Settings, in `UserDefaults` — the panel writes them through
    /// `@AppStorage`, and this reads them each tick, so there is one copy of
    /// the value and no second place to keep in step with it.
    static let volumeKey = "musicVolume"
    static let defaultVolume = 0.6

    private let player: SoundtrackPlayer
    private var director = MusicDirector()
    private weak var document: CityDocument?
    private let defaults: UserDefaults
    private var timer: Timer?
    private var last = CACurrentMediaTime()

    /// `player` defaults to `nil` rather than to a new player because a
    /// default argument is evaluated at the call site, outside this class's
    /// main-actor isolation — the trap `CityDocument.init` already records.
    init(document: CityDocument, defaults: UserDefaults = .standard, player: SoundtrackPlayer? = nil) {
        self.document = document
        self.defaults = defaults
        self.player = player ?? SoundtrackPlayer()
        defaults.register(defaults: [Self.volumeKey: Self.defaultVolume])
    }

    func start() {
        player.start()
        // The title theme first, since it is what plays first; the rest
        // render behind it in the background.
        player.warmUp([.title] + MusicDirector.Cue.allCases.filter { $0 != .title })
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let elapsed = min(now - last, 0.5)
        last = now
        guard let document else { return }

        let volume = defaults.double(forKey: Self.volumeKey)
        player.volume = volume
        player.isMuted = volume <= 0

        let controller = document.controller
        // The title screen is not a city, whatever is loaded behind it.
        let mood = document.isShowingTitle
            ? MusicDirector.CityMood()
            : MusicDirector.CityMood.of(map: controller.map, population: controller.population,
                                        peakPopulation: controller.peakPopulation,
                                        isRunning: controller.isRunning)
        let cue = director.update(mood, elapsed: elapsed)
        player.play(cue)
        player.update(elapsed: elapsed)
    }
}

/// The music levels the Settings panel offers. Four steps rather than a
/// slider: a native slider is the stock AppKit chrome the rest of the panel
/// has had to replace (a `Toggle` there once did not even render), and four
/// levels are what anybody actually sets music to.
enum MusicLevel: Double, CaseIterable {
    case off = 0, low = 0.3, medium = 0.6, high = 1.0

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// The nearest level to a stored volume, so a value from anywhere still
    /// shows as one of the four.
    static func nearest(to volume: Double) -> MusicLevel {
        allCases.min { abs($0.rawValue - volume) < abs($1.rawValue - volume) } ?? .medium
    }
}
