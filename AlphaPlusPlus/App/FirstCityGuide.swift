import Foundation

/// **A guided first city: one system at a time, then out of the way.**
///
/// Seventeen tools, thirteen views and about ten interacting systems, and a
/// new city opened on an empty map with nothing on screen saying where to
/// start. Genre veterans find their way; nobody else does, and the refund
/// window is two hours.
///
/// The guide is a short ordered list of things a first city needs, each
/// finished by *doing* it rather than by reading about it: it watches the city
/// and moves on when the road exists, when the houses are zoned, when the
/// pump is down. There is no "Next" button, because a step you can click past
/// without doing is a step that teaches nothing.
///
/// Three decisions worth recording:
///
/// - **Every step can be completed out of order, and stays completed.** A
///   player who puts a pump down before pressing Play has already done the
///   water step, and should never be asked to do it again. And bulldozing the
///   road does not un-teach roads: progress is a record of what the player has
///   learned, not a live reading of the map.
/// - **Every step carries a shortcut that does it** (or picks the tool that
///   does). This project's standing rule is that every warning the game raises
///   has an answer the player can act on right now; an instruction is the same
///   kind of thing, and one that names a tool the player then has to go and
///   find in a grouped toolbar has only done half its job.
/// - **It watches state, not events.** "Opened the Problems view" is read as
///   `overlayMode == .problems` whenever the guide looks, rather than hooked
///   into the picker — so there is no second path into any of these things
///   that the guide could fail to hear about.
///
/// Lives in `App/` because it reads controller state (`isRunning`, the view,
/// whether City Hall is open) that `Simulation/` has no concept of. The words
/// live in `Rendering/GuideText`, for the reason `InspectorText` does.
struct FirstCityGuide: Equatable {

    enum Step: Int, CaseIterable, Equatable {
        case road
        case housing
        case jobs
        case play
        case growth
        case water
        case power
        case problems
        case services
        case cityHall

        /// What finishes this step.
        ///
        /// The thresholds are small on purpose: a step asks for enough that
        /// the player has plainly *done the thing*, not for a well-built
        /// city. Two lots of housing is "I know how to zone"; forty is a
        /// chore.
        func isDone(in state: State) -> Bool {
            switch self {
            case .road: return state.roadTiles >= Self.roadTilesWanted
            case .housing: return state.residentialLots >= 2
            case .jobs: return state.commercialLots >= 1 && state.industrialLots >= 1
            case .play: return state.isRunning
            case .growth: return state.population > 0
            case .water: return state.hasWaterSource
            case .power: return state.hasPowerSource
            case .problems: return state.overlay == .problems
            case .services: return state.hasEmergencyService
            case .cityHall: return state.isShowingCityPanel
            }
        }

        /// A short street rather than a single tile, so the step cannot be
        /// finished by a misclick — but short enough that one drag does it.
        static let roadTilesWanted = 6

        /// What the guide's button does for this step, if anything.
        ///
        /// `.growth` has none, and deliberately: its whole content is "wait,
        /// and watch the scaffolds", and a button there would imply there is
        /// something to press.
        var shortcut: Shortcut? {
            switch self {
            case .road: return .selectTool(.road)
            case .housing: return .selectTool(.residential)
            case .jobs: return .selectTool(.commercial)
            case .play: return .play
            case .growth: return nil
            case .water: return .selectTool(.waterPump)
            case .power: return .selectTool(.generator)
            case .problems: return .showView(.problems)
            case .services: return .selectTool(.fireStation)
            case .cityHall: return .openCityHall
            }
        }
    }

    enum Shortcut: Equatable {
        case selectTool(ZoneType)
        case play
        case showView(OverlayMode)
        case openCityHall
    }

    /// Everything the steps read, taken from the controller in one place.
    ///
    /// A value rather than a reference to the controller so the steps are
    /// testable as plain functions, and so "what does a step look at" is
    /// answered by reading this struct rather than every step's body.
    struct State: Equatable {
        var roadTiles = 0
        var residentialLots = 0
        var commercialLots = 0
        var industrialLots = 0
        var hasWaterSource = false
        var hasPowerSource = false
        var hasEmergencyService = false
        var population = 0
        var isRunning = false
        var overlay: OverlayMode = .none
        var isShowingCityPanel = false

        /// Counts *lots*, by anchor, rather than tiles — a 2×2 house is one
        /// house, and a threshold written in tiles would quietly mean
        /// something different for every footprint.
        init(map: CityMap, population: Int, isRunning: Bool,
             overlay: OverlayMode, isShowingCityPanel: Bool) {
            for tile in map.tiles {
                switch tile.zone {
                case .road, .highway: roadTiles += 1
                default: break
                }
                guard tile.isBuildingAnchor else { continue }
                switch tile.zone {
                case .residential: residentialLots += 1
                case .commercial: commercialLots += 1
                case .industrial: industrialLots += 1
                case .waterPump, .waterTower: hasWaterSource = true
                case .generator, .powerPlant: hasPowerSource = true
                case .fireStation, .policeStation: hasEmergencyService = true
                default: break
                }
            }
            self.population = population
            self.isRunning = isRunning
            self.overlay = overlay
            self.isShowingCityPanel = isShowingCityPanel
        }

        init() {}
    }

    private(set) var completed: Set<Step> = []

    /// The first step not yet done, or `nil` once every one is.
    var current: Step? { Step.allCases.first { !completed.contains($0) } }

    var isFinished: Bool { current == nil }

    /// How many steps are done, for the progress row.
    var completedCount: Int { completed.count }

    /// Marks every step the city already satisfies.
    ///
    /// Every step, not just the current one: see the type's doc comment for
    /// why a pump put down early counts. Returns whether anything changed, so
    /// the caller can avoid publishing a value that did not move.
    @discardableResult
    mutating func update(with state: State) -> Bool {
        let before = completed.count
        for step in Step.allCases where !completed.contains(step) && step.isDone(in: state) {
            completed.insert(step)
        }
        return completed.count != before
    }
}
