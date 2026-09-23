import Foundation

/// A route the player is in the middle of drawing.
///
/// **Not part of the city**, which is why it lives here rather than on
/// `CityMap` and is absent from `CitySave` — it is the same kind of thing as
/// `selectedTool`: how you are *editing* a city, not anything about the town.
/// A save that restored a half-drawn line would be saving the cursor.
///
/// It carries `editing` so that adding a stop to a line you already have is
/// the same gesture as drawing a new one, rather than a second mode with its
/// own rules. Committing writes the stops back to that route; committing a
/// draft with no `editing` adds a line.
struct TransitRouteDraft: Equatable {
    let mode: TransitRoute.Mode

    /// The existing line this is a revision of, or `nil` for a new one.
    let editing: TransitRoute.ID?

    private(set) var stops: [GridPosition] = []

    init(mode: TransitRoute.Mode, editing: TransitRoute.ID? = nil, stops: [GridPosition] = []) {
        self.mode = mode
        self.editing = editing
        self.stops = stops
    }

    /// Is there enough here to be a line? See `TransitRoute.minimumStops`.
    var isCommittable: Bool { stops.count >= TransitRoute.minimumStops }

    /// What a click on a station did.
    enum StopOutcome: Equatable {
        case added
        /// Clicking the stop you just added takes it off again — undo by
        /// clicking the same place, so the correction for a misclick is in the
        /// same gesture as the mistake.
        case removed
        /// Not a station of this line's kind. Clicking empty ground, a house,
        /// or a subway entrance while drawing a bus route.
        case notAStation
    }

    /// Appends `station`, or removes it if it is the one most recently added.
    ///
    /// Clicking a station that is *already on the line but not last* appends
    /// it again rather than removing it, which is what makes a loop — A, B, C,
    /// A — expressible at all. A rule of "click to toggle" would have made the
    /// common correction work and the loop impossible.
    mutating func toggle(_ station: GridPosition) -> StopOutcome {
        if stops.last == station {
            stops.removeLast()
            return .removed
        }
        stops.append(station)
        return .added
    }

    mutating func undoLastStop() {
        guard !stops.isEmpty else { return }
        stops.removeLast()
    }
}
