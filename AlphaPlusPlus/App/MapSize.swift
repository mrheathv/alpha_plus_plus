import Foundation

/// The map dimensions a new city can start at. A fixed 20×20 was fine for
/// proving the core loop, but is a real ceiling once a city can actually
/// grow — this is a first, simple way to lift it: pick a size before
/// starting over, not a mid-game expansion (which would need to decide what
/// happens to a camera and existing tiles mid-play — a bigger design
/// question than this pass is trying to answer).
///
/// Bumped up (20/32/48 -> 32/48/64) once most buildings became 2×2 and a
/// couple are now 3×3 (`ZoneType.footprintSize`) — a 20×20 map only fits
/// ~100 2×2 lots, half what it used to hold in 1×1 tiles, so the same
/// numbers no longer meant the same amount of buildable city.
enum MapSize: String, CaseIterable, Identifiable, Hashable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var dimension: Int {
        switch self {
        case .small: return 32
        case .medium: return 48
        case .large: return 64
        }
    }

    var displayName: String {
        "\(dimension)\u{00D7}\(dimension)"
    }
}
