import SpriteKit

/// **The value ladder, and a switch to compare two of them.**
///
/// Everything on this map is lit, which is the point — but *everything* being
/// lit equally is what made a screenshot read as busy rather than as night.
/// A night skyline is mostly dark with a few things blazing, and the contrast
/// is most of what sells it.
///
/// The ladder this style sets, darkest to brightest:
///
/// | | |
/// |---|---|
/// | ground, asphalt | near-black — the bed everything else is bright against |
/// | lane lines | dim neon: infrastructure, everywhere, must recede |
/// | building silhouettes | the mid tones |
/// | lit windows, signage | bright — the thing you are looking at |
/// | fire, flagged problems | peak — nothing else is allowed up here |
///
/// The ladder was upside down at the top two rungs: a lane line drew at full
/// alpha, additively, in full-saturation magenta, with a glow, on about a
/// third of the tiles in a normal grid.
///
/// **Why a switch rather than just better numbers.** This is the one part of
/// an art pass that cannot be settled by argument or by a test — it is a
/// judgement about how a thing feels, and the only way to make it is to see
/// both. `classic` is exactly what the game looked like before; `cinematic`
/// is the graded version. Flipping it rebuilds the texture cache, since the
/// palette is baked into every texture.
///
/// Deliberately *not* the shape a permanent theming system would take. Two
/// structural renderers kept alive forever would double the cost of every
/// feature that follows; this holds two sets of **numbers**, which is cheap,
/// and is expected to collapse to one once the question is answered.
enum VisualStyle: String, CaseIterable, Identifiable, Hashable {
    /// What the game looked like before the value pass.
    case classic
    /// Graded: the pavement recedes and the buildings carry the light.
    case cinematic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .cinematic: return "Cinematic"
        }
    }

    /// The style everything draws in.
    ///
    /// A global rather than something threaded through every call, because it
    /// is read by `RenderPalette` and `NeonStyle` — free functions the whole
    /// renderer calls — and passing a style into all of them to answer a
    /// question that is the same everywhere on screen would be ceremony. It
    /// lives in `Rendering/`, so the simulation still knows nothing about it.
    static var current: VisualStyle = .cinematic

    // MARK: - The numbers that differ

    /// How much of its brightness an ordinary street keeps.
    var roadLaneAlpha: Double {
        switch self {
        case .classic: return 1.0
        case .cinematic: return 0.52
        }
    }

    /// An arterial keeps more, so the two kinds of road differ by weight and
    /// not only by hue.
    var highwayLaneAlpha: Double {
        switch self {
        case .classic: return 1.0
        case .cinematic: return 0.78
        }
    }

    /// How hard the frame blooms, and what counts as bright enough to.
    ///
    /// **Zero for `classic`, which is the point of having it here.** Bloom is
    /// the first thing in this project the GPU actually does, and whether a
    /// lit frame is better than a baked one is a judgement, not a
    /// measurement — so it goes on the same switch the value ladder did, and
    /// can be turned off and looked at.
    ///
    /// The threshold sits high on purpose: below it this stops being a bloom
    /// and becomes a blur, and a blurred city is a smeared one. Only the
    /// windows, signage, lane lines and fire are meant to cross it.
    var bloomStrength: Double {
        switch self {
        case .classic: return 0
        case .cinematic: return 0.55
        }
    }

    var bloomThreshold: Double {
        switch self {
        case .classic: return 1
        case .cinematic: return 0.62
        }
    }

    /// How much the water moves. `classic` is the still fill terrain
    /// shipped with, so the switch answers this too.
    var waterShimmer: Double {
        switch self {
        case .classic: return 0
        case .cinematic: return 0.55
        }
    }

    /// How hard a building's neon burns, by growth tier.
    ///
    /// **The contrast is bought at the bottom, not the top**, and that is a
    /// correction rather than a preference. `IsometricBuilding.glowLayer`
    /// ends in `alpha = min(1, 0.85 * intensity)`, so the channel saturates
    /// at an intensity of about 1.18 — the first attempt at this raised the
    /// top tier from 1.15 to 1.40 and moved its alpha from 0.98 to 1.0, which
    /// is to say it did nothing at all. Only the glow's *width* kept scaling,
    /// and width is not brightness.
    ///
    /// So the top sits just under the ceiling and the low tiers come *down*.
    /// That is the better version of the idea anyway: a night skyline is
    /// mostly dim with a few things blazing, and widening the ratio is what
    /// reads as contrast. The tier-3-to-tier-1 ratio goes from 2.1× to 2.8×.
    ///
    /// Not pushed further at the bottom on purpose — a brand-new city is all
    /// tier 1, and there is a point where "dim" stops reading as night and
    /// starts reading as broken.
    var glowIntensity: [CGFloat] {
        switch self {
        case .classic: return [0.55, 0.78, 1.15]
        // 1.17 rather than a rounder 1.2: the clamp bites at 1/0.85 ≈ 1.176,
        // and a top tier asking for more than the layer can give is a number
        // that looks like a decision and is really just waste. The test
        // asserting this caught 1.18.
        case .cinematic: return [0.42, 0.75, 1.17]
        }
    }
}
