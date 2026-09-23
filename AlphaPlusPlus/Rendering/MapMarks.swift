import Foundation

/// **What the input layer asks the renderer to draw** (M8): the cursor, and
/// the short flashes that answer a click. Plain values, so the decision about
/// what the cursor says lives with the input (`MapInteraction`) and the
/// drawing lives with the renderer, and neither holds a copy of the other.
enum MapMarks {

    /// The placement cursor: a ground outline over `size` × `size` tiles from
    /// `origin`, with corner risers, in the clear or the blocked colour.
    struct Cursor: Equatable {
        enum Kind: Equatable {
            /// A tool's footprint, a pipe or a power line.
            case tool
            /// A land parcel, in the Land view.
            case land
            /// A station while a route is being drawn: the whole station.
            case routeStop
        }
        var origin: GridPosition
        var size: Int
        var blocked: Bool
        var kind: Kind
    }

    /// A short fading mark over a lot, answering something that just
    /// happened there. It fades on the renderer's own wall clock, not the
    /// simulation's: a flash answers a click, and clicks happen while paused.
    struct Flash: Equatable {
        enum Kind: Equatable {
            /// A click the treasury could not pay for.
            case insufficientFunds
            /// A click the rules refused.
            case blocked
            /// A hazard struck this building today, let through by the absence
            /// of `service` (a fire or a police station), which picks the colour.
            case hazard(ZoneType)
        }
        var origin: GridPosition
        var size: Int
        var kind: Kind
    }
}
