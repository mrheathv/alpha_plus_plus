import SwiftUI

/// The route editor: the line being drawn, and the lines already running.
///
/// **It floats over the map rather than opening as a sheet**, because building
/// a route means clicking stations on the map — a modal panel would cover the
/// one thing you have to be able to see and click. City Hall can be a sheet
/// precisely because nothing in it needs the map.
///
/// Top-leading, under the tool rail: the inspector already owns top-trailing,
/// and an isometric map's emptiest ground is its two upper corners.
struct TransitPanel: View {
    let mode: TransitRoute.Mode
    let routes: [TransitRoute]
    let draft: TransitRouteDraft?
    /// How many of each route's stops are actually in service — see
    /// `Transit.coverage(for:)` for why that is not simply `stops.count`.
    let workingStops: [TransitRoute.ID: Int]

    /// What each line can carry today — see `Transit.dailyCapacity`, which is
    /// where a bus line's congestion penalty is applied.
    let capacity: [TransitRoute.ID: Int]
    let ridership: (TransitRoute.ID) -> Int?

    let onBegin: () -> Void
    let onEdit: (TransitRoute.ID) -> Void
    let onDelete: (TransitRoute.ID) -> Void
    let onUndo: () -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void

    private var accent: Color {
        Color(nsColor: RenderPalette.transitLineColor(for: mode))
    }

    var body: some View {
        RetroPanel(title: "\(TransitText.modeName(mode)) Lines", accent: accent) {
            VStack(alignment: .leading, spacing: 8) {
                if let draft {
                    editor(draft)
                } else {
                    list
                }
            }
            .frame(width: 210, alignment: .leading)
        }
        // Its own opaque ground and a shadow, for the reason `InspectorPanel`
        // documents: `RetroPanel` fills at 55%, which is right on the
        // dashboard and unreadable over a lit neon city.
        .background(
            ChamferedRectangle()
                .fill(RetroUITheme.background.opacity(0.93))
                .shadow(color: .black.opacity(0.6), radius: 10)
        )
    }

    // MARK: - Drawing a line

    private func editor(_ draft: TransitRouteDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Named, not just "EDITING". A player with four lines needs to
            // know which one they opened before they start adding stops to
            // it — and the list it came from is no longer on screen.
            Text(editingName(draft) ?? "NEW LINE")
                .font(.system(size: 9, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(accent)
            Text(TransitText.draftPrompt(for: draft))
                .font(.system(size: 10))
                .foregroundStyle(RetroUITheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(TransitText.stops(draft.stops.count))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(RetroUITheme.textPrimary)

            HStack(spacing: 6) {
                Button("Finish") { onCommit() }
                    .buttonStyle(RetroButtonStyle(accent: accent, isSelected: draft.isCommittable))
                    // **Disabled rather than hidden**, so the reason a line
                    // will not finish is legible: the button is there, and the
                    // stop count next to it says what it is waiting for.
                    .disabled(!draft.isCommittable)
                Button("Undo") { onUndo() }
                    .buttonStyle(RetroButtonStyle(accent: RetroUITheme.primaryAccent))
                    .disabled(draft.stops.isEmpty)
                Button("Cancel") { onCancel() }
                    .buttonStyle(RetroButtonStyle(accent: .orange))
            }
        }
    }

    private func editingName(_ draft: TransitRouteDraft) -> String? {
        guard let id = draft.editing, let route = routes.first(where: { $0.id == id }) else { return nil }
        return "EDITING \(TransitText.name(for: route, numberedWithin: routes).uppercased())"
    }

    // MARK: - The lines already running

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            if routes.isEmpty {
                Text("No \(TransitText.modeName(mode).lowercased()) lines yet.")
                    .font(.system(size: 10))
                    .foregroundStyle(RetroUITheme.textSecondary)
            }
            ForEach(routes) { route in
                row(route)
            }
            Button("New Line") { onBegin() }
                .buttonStyle(RetroButtonStyle(accent: accent, isSelected: true))
        }
    }

    private func row(_ route: TransitRoute) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(TransitText.name(for: route, numberedWithin: routes))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(accent)
                Spacer(minLength: 4)
                Text(TransitText.stops(route.stops.count))
                    .font(.system(size: 9))
                    .foregroundStyle(RetroUITheme.textSecondary)
            }
            // **Ridership is the whole readout.** A route panel that only
            // listed lines would say nothing a glance at the map does not —
            // the number a player steers by is how many people actually used
            // the thing they paid for.
            if let fault = TransitText.fault(for: route, workingStops: workingStops[route.id] ?? 0) {
                Text(fault)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            } else if let riders = ridership(route.id), let seats = capacity[route.id], seats > 0 {
                // **A fraction is a number; a meter is a status.** The same
                // reasoning the utility load meters were built on: a full line
                // turns people away, and "how close am I to the ceiling" is
                // exactly what a bar that fills and reddens answers at a
                // glance. It is also the one readout that says *build another
                // line*, which is the decision this whole phase exists to
                // create.
                RetroMeter(
                    label: "Riders",
                    fill: Double(riders) / Double(seats),
                    detail: "\(riders.formatted()) / \(seats.formatted()) a day",
                    accent: accent
                )
            } else {
                Text(TransitText.ridership(ridership(route.id)))
                    .font(.system(size: 10))
                    .foregroundStyle(RetroUITheme.textPrimary)
            }
            HStack(spacing: 6) {
                Button("Edit") { onEdit(route.id) }
                    .buttonStyle(RetroButtonStyle(accent: RetroUITheme.primaryAccent))
                Button("Delete") { onDelete(route.id) }
                    .buttonStyle(RetroButtonStyle(accent: .orange))
            }
        }
    }
}
