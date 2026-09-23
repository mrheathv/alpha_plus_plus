import SpriteKit
import CoreGraphics

/// The shared drawing vocabulary every building renderer works in.
///
/// **What this used to be.** `ZoneIcon` drew every building in the game as a
/// front elevation, and carried the palette and primitives those drawings were
/// made from. The drawings are gone — buildings are described as
/// `BuildingMassing` and drawn by `IsometricBuilding` now — but the palette and
/// primitives are not, and they were always the more durable half: what makes a
/// lit window the same colour in a factory and a hospital, and what stops the
/// zones drifting into looking like three different games.
///
/// So this is `ZoneIcon` with the icons taken out, and the name says so.
enum NeonStyle {

    // MARK: - Sizing

    /// The smallest a detail may be, in design-space or tile-relative terms, if
    /// it is meant to be *seen* rather than merely present.
    ///
    /// **The rule that follows: if a mark cannot be drawn at least this big,
    /// cut it rather than shrink it.** Learned the expensive way — the art was
    /// first reviewed at the most zoomed-in view the camera has, which is the
    /// rarest one, and window grids, mullions, railing posts and frame lines
    /// that looked like detail there were a grey speckle at the size the game
    /// is actually played at. They did not add detail; they averaged every
    /// facade toward mud and muted the neon.
    ///
    /// It applies to geometry as well as to marks: a cylinder had sixteen sides
    /// for a chimney six points wide, and separate ring volumes for bands two
    /// points tall. Detail below the size it can be seen at is not detail, it
    /// is cost.
    static let minimumDetailSize: CGFloat = 9

    /// How hard a growable building's neon burns, by growth tier.
    ///
    /// Shared so a tier-2 shop and a tier-2 factory carry the same weight as
    /// each other and less than any tier-3 — the hierarchy has to be about
    /// *density*, not about which zone picked a brighter number. `liveliness`
    /// is a small per-building wobble on top, so a row of same-tier lots is not
    /// a row of identical lamps.
    ///
    /// Brightness is a channel because a night skyline is mostly dim with a few
    /// things blazing, and that contrast is most of what makes it look like
    /// night. It also survives distance better than shape: when the camera is
    /// far enough out that a silhouette has stopped resolving, how hard a
    /// building glows still reads.
    static func glowIntensity(forTier tier: Int, liveliness: CGFloat = 1) -> CGFloat {
        let ladder = VisualStyle.current.glowIntensity
        return ladder[max(0, min(ladder.count - 1, tier - 1))] * liveliness
    }

    // MARK: - Palette

    /// Every building's fill — near-black, so a building reads as a shape cut
    /// out of the night, lit only by its own neon. Consistent across every
    /// zone: the *glow colour*, not a different material, is what tells a house
    /// from a shop.
    static let silhouetteFill = SKColor(srgbRed: 0.05, green: 0.03, blue: 0.09, alpha: 1.0)

    /// Windows, shopfronts, lit panels — anything meant to read as lit up at
    /// night. The one element deliberately *not* coloured by the zone's accent:
    /// a lit window glows the same cool cyan-white whatever building it is
    /// punched into, so light reads as its own kind of thing rather than as a
    /// paler version of the building's neon.
    static let litAccent = SKColor(srgbRed: 0.55, green: 0.98, blue: 1.0, alpha: 0.95)

    /// Standing water — a park's pond, and anything else that should read as a
    /// surface rather than a light. Deeper and bluer than `litAccent`, which
    /// is the glow *of* a window rather than a thing you could fall into.
    static let waterAccent = SKColor(srgbRed: 0.10, green: 0.52, blue: 0.95, alpha: 0.95)

    /// Two hues, not three. A third, dimmer, desaturated "cool white" used to
    /// sit here, and across a facade of small panes it averaged the whole grid
    /// toward grey — the opposite of what a neon look wants. Cool and warm
    /// alone still say "different tenants, different bulbs" while keeping every
    /// pane fully saturated.
    static let windowPalette: [SKColor] = [
        litAccent,
        SKColor(srgbRed: 1.0, green: 0.86, blue: 0.48, alpha: 0.98),  // warm incandescent
    ]

    /// Which window colour a given pane takes — a fixed formula on its own
    /// row/column (plus `salt`, so two grids on one building don't repeat the
    /// same pattern), not real randomness, for the same "a lot must look the
    /// same on every launch" reason `BuildingRandom` documents.
    static func windowColor(row: Int, column: Int, salt: Int = 0) -> SKColor {
        windowPalette[abs(row * 11 + column * 7 + salt) % windowPalette.count]
    }

    /// Doors, loading bays, recesses — anything that should read as the
    /// darkest, most recessed part of a shape, darker even than
    /// `silhouetteFill`.
    static let recessedAccent = SKColor.black.withAlphaComponent(0.75)

    /// Warm orange, for hazard marks and nothing else — a fixed "attention"
    /// colour rather than a zone accent.
    /// The red of an aviation beacon, on industry's stacks.
    static let beaconColor = SKColor(srgbRed: 1.0, green: 0.12, blue: 0.16, alpha: 0.95)

    /// Sodium work light: industry's yards, which are lit to work in rather
    /// than to be looked at.
    static let sodiumColor = SKColor(srgbRed: 1.0, green: 0.7, blue: 0.3, alpha: 0.95)

    static let emberColor = SKColor(srgbRed: 1.0, green: 0.45, blue: 0.15, alpha: 0.95)

    /// Sodium-lamp amber, for construction scaffolding and nothing else.
    /// Warmer and dimmer than `emberColor` on purpose: a building site is a
    /// "this is happening" mark, not a "something is wrong" one, and the two
    /// have to be distinguishable at a glance from across the map.
    static let scaffoldColor = SKColor(srgbRed: 1.0, green: 0.78, blue: 0.32, alpha: 0.95)

    /// The mixed-neon-signage look a dense night skyline has: plaques and
    /// marquees in a handful of hot colours, not one fixed hue the way every
    /// window already reads.
    static let signPalette: [SKColor] = [
        SKColor(srgbRed: 0.0, green: 0.95, blue: 1.0, alpha: 0.95),   // electric cyan
        SKColor(srgbRed: 1.0, green: 0.15, blue: 0.55, alpha: 0.95),  // hot magenta
        SKColor(srgbRed: 1.0, green: 0.75, blue: 0.20, alpha: 0.95),  // amber
    ]

    /// Which sign colour a plaque glows, mixed deterministically off the
    /// building's own anchor position, plus a `salt` so a building with more
    /// than one sign doesn't repeat itself.
    static func signColor(for seed: GridPosition, salt: Int = 0) -> SKColor {
        signPalette[abs(seed.x &* 17 &+ seed.y &* 13 &+ salt) % signPalette.count]
    }

    // MARK: - Cladding

    /// **A wall is made of something**, and until now every wall in this game
    /// was made of the same thing.
    ///
    /// Stripped of hue, a built-out city came back as exactly two values: one
    /// near-black face and one white window, on every building in it. The
    /// zones tell apart — commerce's continuous bands against housing's
    /// punched grid is a distinction that survives greyscale, which was the
    /// whole point of the massing port — but *within* a zone every tower was
    /// the same tower. Variety was all in the outline and none of it in the
    /// surface.
    ///
    /// Two looks per zone rather than three, and no more: this is a mid-value
    /// mark on a wall the value ladder wants dark, so a little of it goes a
    /// long way and a lot of it is the grey speckle `minimumDetailSize` exists
    /// to delete.
    enum Cladding {
        /// Glass: an unbroken wall with nothing on it but its windows. What
        /// every building in this game looked like before there was a choice.
        case curtainWall
        /// A concrete or masonry frame: broad vertical piers running the
        /// building's full height, with the glazing recessed between them.
        case piers
        /// Precast panel: the floor slabs showing as horizontal bands.
        case panel
    }

    /// The wall material, seeded from the lot so it is stable and its
    /// neighbour's is different — the rule `BuildingRandom` documents.
    static func cladding(for seed: GridPosition, options: [Cladding], salt: Int) -> Cladding {
        var random = BuildingRandom(seed: seed, salt: 700 + salt)
        return random.pick(options)
    }

    /// Lays the material onto a volume's two visible walls.
    ///
    /// **Call it before the windows.** Panels sort with the volume they sit on
    /// and ties break on insertion order, so cladding added first draws under
    /// the glazing — which is the way round a building is actually built, and
    /// the way round that keeps the lit marks on top where the value ladder
    /// wants them.
    static func clad(
        _ box: Box, as cladding: Cladding,
        into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        switch cladding {
        case .curtainWall:
            return
        case .piers:
            // Three, and broad. Five thinner ones would be the speckle this
            // palette cannot afford — `minimumDetailSize`'s rule applied to a
            // surface rather than to a mark.
            let count = 3
            let width: CGFloat = 0.22
            for face in [Panel.Face.right, .left] {
                for index in 0 ..< count {
                    let centre = (CGFloat(index) + 0.5) / CGFloat(count)
                    massing.panels.append(Panel(
                        box: box, face: face,
                        u0: max(0, centre - width / 2), u1: min(1, centre + width / 2),
                        v0: 0, v1: 1, color: claddingAccent
                    ))
                }
            }
        case .panel:
            // One band per storey, at the slab line.
            //
            // **Thickness in world units, not in a fraction of the box.** The
            // first version asked for 7% of the height and a residential
            // volume is nine-tenths of a tile tall, so the slab lines arrived
            // two screen points thick — invisible, on every variant, with
            // nothing failing. A `Panel`'s `v` range is a *proportion*, which
            // is exactly the trap: the same number means a different mark on
            // every box it is applied to. Converting once here is the whole
            // fix, and it is the same lesson as the near-detail mullion, whose
            // pane count comes from a panel's projected width rather than from
            // its width in tile units.
            let bands = max(2, Int((box.height / slabSpacing).rounded()))
            guard bands <= 14 else { return }
            let half = slabThickness / box.height / 2
            for face in [Panel.Face.right, .left] {
                for band in 1 ..< bands {
                    let v = CGFloat(band) / CGFloat(bands)
                    massing.panels.append(Panel(
                        box: box, face: face, u0: 0.04, u1: 0.96,
                        v0: max(0, v - half), v1: min(1, v + half), color: claddingAccent
                    ))
                }
            }
        }
    }

    /// **Rooftop plant: the biggest surface a building shows here, and it was
    /// empty.**
    ///
    /// In elevation a roof was a single line at the top of a silhouette. This
    /// projection shows the whole plane — on a 2×2 lot it is the largest
    /// single face in the drawing — and `IndustrialMassing` worked that out
    /// when it landed: *"a flat roof is the quiet option, not a blank one"*,
    /// so its halls got rooftop plant. Commerce and housing never did. Their
    /// roofs carried a crown in the middle and nothing else, which greyscale
    /// shows as a large grey diamond per building, repeated across the city.
    ///
    /// **Placed in the outer band, never the middle.** The crown is the centre
    /// feature and this is the rest of the roof — keeping them apart is what
    /// stops a stair head and a lit band arriving at the same spot with tied
    /// sort keys, which is how a hospital's cross once collapsed into a single
    /// bar.
    ///
    /// Sized against `minimumDetailSize` rather than against the roof: a box a
    /// third of a tile across is ten screen points at the resting camera, and
    /// four smaller ones would be the speckle this palette cannot afford.
    static func rooftopPlant(
        on box: Box, into massing: inout BuildingMassing, random: inout BuildingRandom
    ) {
        let roof = box.z + box.height
        let span = min(box.width, box.depth)
        // Below about a tile across there is no outer band left to stand
        // anything in once the crown has the middle.
        guard span >= 0.7 else { return }
        let size = max(0.3, span * CGFloat(random.value(in: 0.17 ... 0.24)))

        for _ in 0 ..< random.int(in: 1 ... 3) {
            // Outer band: pick a side, then a position along it.
            let along = CGFloat(random.value(in: 0.1 ... 0.9))
            let edge = CGFloat(random.value(in: 0.04 ... 0.16))
            let (u, v): (CGFloat, CGFloat) = random.chance(0.5)
                ? (along, random.chance(0.5) ? edge : 1 - edge)
                : (random.chance(0.5) ? edge : 1 - edge, along)
            let x = box.x + (box.width - size) * u
            let y = box.y + (box.depth - size) * v
            massing.add(.box(Box(x: x, y: y, z: roof, width: size, depth: size,
                                 height: CGFloat(random.value(in: 0.1 ... 0.22)))))
        }
    }

    /// The one mid tone on a facade.
    ///
    /// Between `silhouetteFill` and anything lit, and much nearer the former:
    /// the value ladder puts a building's own surface in the mid tones and
    /// reserves the top for windows and signage, so a material that competed
    /// with a lit pane would be saying the wall is a light source.
    static let claddingAccent = SKColor(srgbRed: 0.20, green: 0.14, blue: 0.30, alpha: 1.0)

    /// How thick a slab band is, in tile units — about four screen points at
    /// the resting camera, which is what a band has to be to read at all
    /// against a wall this dark.
    static let slabThickness: CGFloat = 0.13

    /// And how far apart they sit. Roughly a storey.
    static let slabSpacing: CGFloat = 0.4
}
