import SwiftUI

/// What the inspector *says*, as opposed to what it knows.
///
/// Every word a player reads about a lot lives here rather than on
/// `TileReport` or `LotStatus`, for the reason the project structure rule
/// already gives: `Simulation/` may import Foundation only, and what a thing
/// is called is a statement about presentation. `RenderPalette.displayName`
/// is not on `ZoneType` for exactly this reason.
///
/// **Two rules run through all of it.**
///
/// *The headline names a fix, not a mechanism.* A player reading "needs water"
/// knows what to do; one reading "water gate failed at level 3" has been shown
/// the implementation and told nothing. Every status that a player can act on
/// carries the action as its second line, which is this project's standing
/// rule about warnings — every one the game raises has to have an answer they
/// can take right now.
///
/// *Ratings where a number means nothing.* "Desirability 0.62" is a debug
/// readout. A player reasons in levels, residents and jobs, so those stay as
/// numbers; land value, pollution and congestion are continuous fields whose
/// absolute value carries no meaning outside the simulation, so they become
/// words with a bar behind them.
enum InspectorText {

    // MARK: - The headline

    /// What to call this lot.
    ///
    /// Not `RenderPalette.displayName` alone: that is the *toolbar's* name for
    /// a zone, and the toolbar's name for `.empty` is "Bulldoze" — which is
    /// the tool that produces bare ground, not a description of it. The render
    /// caught bare ground introducing itself as BULLDOZE.
    static func title(for zone: ZoneType) -> String {
        zone == .empty ? "Unzoned land" : RenderPalette.displayName(for: zone)
    }

    /// The short form: what is happening to this lot.
    static func headline(for report: TileReport) -> String {
        switch report.status {
        case .notGrowable:
            return title(for: report.zone)
        case .noRoadAccess:
            return report.density > 0 ? "Cut off" : "No road access"
        case .burning:
            return "On fire"
        case .damaged:
            return "Burnt out"
        case .underConstruction:
            return "Building"
        case .beingAbandoned:
            return "Emptying out"
        case .decliningToSustainable:
            return "Running down"
        case .atMaximumDensity:
            return "Fully built"
        case .needsLandValue:
            return "Not desirable enough"
        case .needsWater:
            return "Needs water"
        case .needsPower:
            return "Needs power"
        case .needsSchool:
            return "Needs a school"
        case .needsRapidTransit:
            return "Needs a subway or rail station"
        case .readyToGrow(let demand):
            // The two halves of "nothing is wrong" are completely different
            // news. A lot that will grow shortly needs no attention; a lot
            // held back because the city wants no more of its kind is telling
            // the player to go and zone something else, which is advice.
            return demand > 0 ? "Ready to grow" : "Waiting for demand"
        }
    }

    /// The second line: what to do about it, or `nil` when there is nothing to
    /// do and saying so would be noise.
    static func advice(for report: TileReport) -> String? {
        switch report.status {
        case .notGrowable, .atMaximumDensity:
            return nil
        case .noRoadAccess:
            return "Nothing can reach this lot. Run a road, or a transit stop, up against it."
        case .burning:
            return "Bulldoze it to break the fire's path, or get a fire station in range."
        case .damaged(let service):
            return "A \(RenderPalette.displayName(for: service).lowercased()) in range will rebuild "
                + "it. Bulldozing works too, and costs you the building."
        case .underConstruction:
            return nil
        case .beingAbandoned:
            return "The city has more \(zoneNoun(report.zone)) than it wants. "
                + "Zone less of it, or lower the tax rate."
        case .decliningToSustainable(let sustainable):
            return sustainable > 0
                ? "Its surroundings only support level \(sustainable). Add services nearby, "
                    + "or clear the pollution and traffic dragging it down."
                : "Its surroundings support nothing at all. This lot will empty completely."
        case .needsLandValue:
            return "Police, fire, schools and transit nearby make a lot more desirable. "
                + "Pollution and heavy traffic make it less."
        case .needsWater:
            return "Put a tower or a pump within a few tiles, or run a pipe to it."
        case .needsPower:
            return "Put a plant or a generator within a few tiles, or run a power line to it."
        case .needsSchool:
            return "A school in range is what unlocks the fifth level."
        case .needsRapidTransit:
            return "The skyline grows around rapid transit: build a subway entrance or a rail "
                + "station within a short walk."
        case .readyToGrow(let demand):
            return demand > 0 ? nil : "Nothing is wrong here — the city just wants no more "
                + "\(zoneNoun(report.zone)) yet. Watch the demand bars."
        }
    }

    /// How loudly to say it. Three levels, because a player scanning the panel
    /// should be able to tell "on fire" from "not desirable enough" without
    /// reading either.
    static func accent(for status: LotStatus) -> Color {
        switch status {
        case .burning:
            return .orange
        case .noRoadAccess, .beingAbandoned, .decliningToSustainable, .damaged:
            return .red
        case .needsLandValue, .needsWater, .needsPower, .needsSchool, .needsRapidTransit:
            return RetroUITheme.secondaryAccent
        case .notGrowable, .atMaximumDensity, .underConstruction, .readyToGrow:
            return RetroUITheme.primaryAccent
        }
    }

    // MARK: - Ratings

    /// Four bands, named from the player's point of view rather than the
    /// field's. Four rather than a percentage because the number itself has no
    /// meaning outside the simulation — what a player needs to know is which
    /// end of the range they are at and which way to push.
    private static func band(_ value: Double, _ names: [String]) -> String {
        let index = Swift.max(0, Swift.min(names.count - 1, Int(value * Double(names.count))))
        return names[index]
    }

    /// **Named against the gates, not against the range.**
    ///
    /// Even bands were the obvious thing and the render showed them lying: a
    /// lot with plain road frontage and no amenities at all reads 0.75, which
    /// on a flat four-way split came out as "Prime" — telling the player they
    /// had done a great job of a lot that is in fact one notch short of
    /// supporting the top tier. The number's meaning comes entirely from
    /// `CitySimulator.requiredLandValue`, so the words are cut at exactly
    /// those thresholds and each one now says which level this land supports.
    static func desirability(_ value: Double) -> String {
        for level in stride(from: ZoneType.residential.maxDensity, through: 2, by: -1)
        where value >= CitySimulator.requiredLandValue(toReach: level) {
            return ["", "", "Fair", "Good", "Strong", "Prime", "Skyline"][level]
        }
        return "Poor"
    }

    static func pollution(_ value: Double) -> String {
        band(value, ["Clean", "Hazy", "Dirty", "Toxic"])
    }

    static func traffic(_ value: Double) -> String {
        band(value, ["Clear", "Steady", "Slow", "Jammed"])
    }

    static func condition(_ value: Double) -> String {
        band(value, ["Failing", "Poor", "Worn", "Good"])
    }

    /// What this lot is, for a sentence rather than a title.
    private static func zoneNoun(_ zone: ZoneType) -> String {
        switch zone {
        case .residential: return "housing"
        case .commercial: return "shops"
        case .industrial: return "industry"
        default: return RenderPalette.displayName(for: zone).lowercased()
        }
    }

    /// What to say about this block's commute, or `nil` when there is
    /// nothing to say — which is most of the time, and is why this is a
    /// separate line rather than part of the headline.
    ///
    /// **Not promoted to the headline**, even though it is often the most
    /// interesting thing on the panel. Unemployment does not stop a lot
    /// growing — it feeds `Demand`, which is a city-wide pressure — so putting
    /// it where the blocking gate goes would claim a causation the simulation
    /// does not have. It belongs with the other things that are true about the
    /// lot but not currently stopping it.
    static func commute(for report: TileReport) -> String? {
        guard let found = report.commuteFound else { return nil }
        guard found else { return "Nobody here can reach a job" }
        guard let commute = report.commute else { return nil }
        // **Minutes, because that is how anybody describes a commute.** The
        // simulation has priced every journey in them since the transit graph
        // landed, and this is the one place that number reaches the player —
        // it is also the only place the mode decision surfaces, so a line
        // that is genuinely faster than driving is visible as the reason
        // these particular people are on it.
        let how = commute.boarding == nil
            ? "driving"
            : (commute.transfers > 0
                ? "by transit, \(commute.transfers) change\(commute.transfers == 1 ? "" : "s")"
                : "by transit")
        return "\(Int(commute.minutes.rounded())) minutes to work, \(how)"
    }

    /// "Level 3 of 5", or nothing at all for something that does not grow.
    static func level(for report: TileReport) -> String? {
        guard report.maxDensity > 0 else { return nil }
        return "Level \(report.density) of \(report.maxDensity)"
    }

    /// Residents and jobs, only when there are any — a line reading "0
    /// residents" is worse than no line.
    static func occupancy(for report: TileReport) -> String? {
        if report.population > 0 { return "\(report.population) residents" }
        if report.jobs > 0 { return "\(report.jobs) jobs" }
        return nil
    }
}
