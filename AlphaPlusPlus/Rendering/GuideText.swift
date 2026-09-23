import Foundation

/// Every word the first-city guide says.
///
/// Separate from `FirstCityGuide` for the reason `InspectorText` is separate
/// from `TileReport`: the steps are rules about the game and the sentences
/// are presentation, and a rewrite of one should never be able to move the
/// other.
///
/// Two rules for the copy, both borrowed from the inspector because they
/// already worked there:
///
/// - **The title names the thing to do, not the system.** "Bring water", not
///   "Water supply" — a player reads the first line and has been told the
///   useful thing.
/// - **The body says why, in one or two sentences.** Why is what turns an
///   instruction into something learned; a step that only says *what* is
///   remembered for exactly as long as it is on screen.
enum GuideText {

    static func title(for step: FirstCityGuide.Step) -> String {
        switch step {
        case .road: return "Lay a road"
        case .housing: return "Zone housing beside it"
        case .jobs: return "Give them somewhere to work"
        case .play: return "Start the clock"
        case .growth: return "Watch it grow"
        case .water: return "Bring water"
        case .power: return "Switch the power on"
        case .problems: return "Find what's stuck"
        case .services: return "Protect it"
        case .cityHall: return "Visit City Hall"
        }
    }

    static func body(for step: FirstCityGuide.Step) -> String {
        switch step {
        case .road:
            return "Everything in a city hangs off its streets. Pick Road and drag a line across the map."
        case .housing:
            return "Drag Residential along the road. A lot with no road beside it never grows."
        case .jobs:
            return "Zone some Commercial and some Industrial too. People move in for work, so housing alone empties."
        case .play:
            return "The city is paused. Press Play, or Space, and it starts building what you zoned."
        case .growth:
            return "Amber scaffolds are construction. A block takes days to finish, and it only grows while people want to live here."
        case .water:
            return "Past the first storey a block needs water. A pump serves everything within a few tiles of it."
        case .power:
            return "Higher still needs power. Put a generator near your blocks, the same way you put down the pump."
        case .problems:
            return "The Problems view lights up every block that wants something. Hover one to see what it needs."
        case .services:
            return "Fires and crime come with a bigger city. A fire station stops a fire spreading, and it unlocks at 40 residents."
        case .cityHall:
            return "Taxes, funding and loans live in City Hall. The budget is what decides how big the city can get."
        }
    }

    /// The label on the step's button.
    static func action(for shortcut: FirstCityGuide.Shortcut) -> String {
        switch shortcut {
        case .selectTool(let zone): return "Pick \(RenderPalette.displayName(for: zone))"
        case .play: return "Play"
        case .showView(let mode): return "Show \(mode.displayName)"
        case .openCityHall: return "Open City Hall"
        }
    }

    static let finishedTitle = "That's a city"
    static let finishedBody = "Everything else — transit, schools, ports — unlocks as the city grows. Hover any block and it will say what it needs."

    static func progress(_ done: Int) -> String {
        "First city · \(done) of \(FirstCityGuide.Step.allCases.count)"
    }
}
