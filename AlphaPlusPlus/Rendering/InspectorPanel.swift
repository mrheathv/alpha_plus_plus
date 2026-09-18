import SwiftUI

/// What is wrong with this block, and what to do about it.
///
/// **Structured as a diagnosis, not a dump.** The temptation with a dozen
/// available numbers is to list all of them, and that fails the way
/// `NeonStyle.minimumDetailSize` describes for art: past a certain density,
/// more marks stop adding information and start averaging into noise. So the
/// panel is one headline — the thing actually holding this lot back, from
/// `LotStatus` — one line of advice, and then supporting evidence in two
/// groups underneath. A player who only reads the first line has still been
/// told the useful thing.
///
/// It sits over the map rather than in the dashboard because the dashboard is
/// full, and because an inspector belongs near what it is inspecting. It is
/// narrow and fixed-width: the text wraps, and a panel that resized itself as
/// the pointer moved between lots would be unreadable.
struct InspectorPanel: View {
    let report: TileReport

    private var accent: Color { InspectorText.accent(for: report.status) }

    var body: some View {
        RetroPanel(accent: accent) {
            VStack(alignment: .leading, spacing: 10) {
                header
                if let advice = InspectorText.advice(for: report) {
                    Text(advice)
                        .font(.system(size: 10))
                        .foregroundStyle(RetroUITheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case let .underConstruction(remaining, total) = report.status, total > 0 {
                    RetroMeter(
                        label: "Progress",
                        fill: Double(total - remaining) / Double(total),
                        // A wait is the one number a player most wants in
                        // their own units rather than the simulation's.
                        detail: "\(CalendarText.days(remaining)) left",
                        accent: accent
                    )
                }
                if report.maxDensity > 0 {
                    utilities
                    services
                }
                surroundings
                warnings
            }
            .frame(width: 210, alignment: .leading)
        }
        // **Its own opaque ground, unlike every other panel.** `RetroPanel`
        // fills at 55% so the dashboard reads as one continuous surface, which
        // is right for a panel sitting on the dashboard's own background. This
        // one floats over the *map* — a lit neon city that would show straight
        // through a paragraph of 10-point text. The live render made that
        // immediately obvious and nothing else would have: over the plain
        // background of the component sheet it looks perfect.
        .background(
            ChamferedRectangle()
                .fill(RetroUITheme.background.opacity(0.93))
                .shadow(color: .black.opacity(0.6), radius: 10)
        )
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(InspectorText.title(for: report.zone).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                    // `.empty` is the near-black "night" the whole map sits
                    // on, which as *text* is invisible — the same trap that
                    // once drew the Road button black on black. Bare ground
                    // gets the panel's own secondary colour instead.
                    .foregroundStyle(report.zone == .empty
                        ? RetroUITheme.textSecondary
                        : Color(nsColor: RenderPalette.fullColor(for: report.zone)))
                Spacer(minLength: 4)
                if let level = InspectorText.level(for: report) {
                    Text(level)
                        .font(.system(size: 9))
                        .foregroundStyle(RetroUITheme.textSecondary)
                }
            }
            // A lot that does not grow has no diagnosis to give, and its
            // headline is just its own name again — which the title line above
            // has already said. Saying it twice is how a panel teaches a
            // player to stop reading it.
            if report.status != .notGrowable {
                HStack(spacing: 6) {
                    // The headline is the panel's whole reason to exist, so it
                    // is the one thing here drawn at a size you cannot skim
                    // past.
                    Text(InspectorText.headline(for: report))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(accent)
                    if report.status.isDeteriorating {
                        // A lot that is *getting worse* is a different kind of
                        // news from one that is merely stuck, and that
                        // difference is what decides whether the player deals
                        // with it now.
                        Text("▼")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(accent)
                    }
                }
            }
            if let occupancy = InspectorText.occupancy(for: report) {
                Text(occupancy)
                    .font(.system(size: 10))
                    .foregroundStyle(RetroUITheme.textPrimary)
            }
        }
    }

    // MARK: - Groups

    /// Water and power as a pair of pills rather than meters: the question is
    /// binary, and the whole-city load meters in the cockpit already answer
    /// the "how much headroom" version of it.
    private var utilities: some View {
        HStack(spacing: 5) {
            pill("Water", on: report.hasWater, accent: RetroUITheme.accent(for: .waterTower))
            pill("Power", on: report.hasPower, accent: RetroUITheme.accent(for: .powerPlant))
        }
    }

    private var services: some View {
        VStack(alignment: .leading, spacing: 5) {
            RetroSectionLabel(text: "Services in range")
            HStack(spacing: 5) {
                pill("Police", on: report.policeCoverage >= CityHazards.crime.coverageThreshold,
                     accent: RetroUITheme.accent(for: .policeStation))
                pill("Fire", on: report.fireCoverage >= CityHazards.fire.coverageThreshold,
                     accent: RetroUITheme.accent(for: .fireStation))
            }
            HStack(spacing: 5) {
                pill("School", on: report.schoolCoverage >= CitySimulator.educationCoverageThreshold,
                     accent: RetroUITheme.accent(for: .school))
                pill("Hospital", on: report.hospitalCoverage >= CityHazards.fire.coverageThreshold,
                     accent: RetroUITheme.accent(for: .hospital))
            }
        }
    }

    private var surroundings: some View {
        VStack(alignment: .leading, spacing: 5) {
            RetroSectionLabel(text: "Surroundings")
            RetroMeter(label: "Desirable", fill: report.landValue,
                       detail: InspectorText.desirability(report.landValue),
                       accent: RetroUITheme.primaryAccent, segments: 6)
            RetroMeter(label: "Pollution", fill: report.pollution,
                       detail: InspectorText.pollution(report.pollution),
                       accent: RetroUITheme.accent(for: .industrial), segments: 6)
            RetroMeter(label: "Traffic", fill: report.congestion,
                       detail: InspectorText.traffic(report.congestion),
                       accent: RetroUITheme.accent(for: .road), segments: 6)
        }
    }

    /// The things that are not stopping this lot *yet*.
    ///
    /// Kept separate from the headline on purpose. An uncovered block is not
    /// broken — it is exposed, which is a risk rather than a fault, and
    /// promoting it to the headline would bury the thing that actually is
    /// wrong underneath a warning about something that has not happened.
    @ViewBuilder private var warnings: some View {
        let worn = report.infrastructureCondition < 0.7
        let commute = InspectorText.commute(for: report)
        if report.isExposedToFire || report.isExposedToCrime || worn || commute != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let commute {
                    RetroBadge(text: "⚠ \(commute)", accent: .orange)
                }
                if report.isExposedToFire {
                    RetroBadge(text: "⚠ No fire cover", accent: .orange)
                }
                if report.isExposedToCrime {
                    RetroBadge(text: "⚠ No police cover", accent: .orange)
                }
                if worn {
                    RetroBadge(
                        text: "⚠ Roads here are \(InspectorText.condition(report.infrastructureCondition).lowercased())",
                        accent: .orange
                    )
                }
            }
        }
    }

    private func pill(_ title: String, on: Bool, accent: Color) -> some View {
        RetroBadge(text: title, accent: on ? accent : RetroUITheme.textSecondary, isUrgent: on)
    }
}
