import Foundation

/// Which tools a city has earned the right to place, by population.
///
/// **Why this exists.** Everything was available from tick one, which cost the
/// game two things. There was nothing to aim at — an open-ended city builder
/// has no ending, but the genre's answer to "why keep playing" is a ladder of
/// unlocks rather than a win condition, and there was no ladder. And the early
/// game had no shape: a new city could paint every tool it would ever have
/// across the whole map immediately, which is a large part of why a fully
/// zoned map filled in within a handful of ticks.
///
/// **Thresholds are shaped by the gates that already exist**, not picked
/// freely. `CitySimulator.waterRequiredFromLevel` means water is needed to pass
/// density 2, so the tower has to arrive while a city can still only reach
/// density 2 — thirteen lots at that density clears 100 residents.
/// `powerRequiredFromLevel` gates density 4, so the plant lands just past where
/// water-only growth tops out. The cheap/upgraded pairs keep their existing
/// relationship (`.road` before `.highway`, `.publicTransit` before
/// `.subway`), and the stadium sits at the top where its 2,500 cost and 3×3
/// footprint already put it.
///
/// Calibrated so a 32×32 map, which tops out near 800 residents, earns
/// everything but the stadium, and a 64×64 earns the lot.
enum Unlocks {

    /// How many residents a city must have *ever* had before `zone` can be
    /// placed. 0 for the starting tools.
    ///
    /// Measured against a high-water mark rather than current population (see
    /// `GameController.peakPopulation`): a city knocked back by fire or a bad
    /// tax decision keeps the tools it earned. Losing access to the fire
    /// station *because* your city burned down would be precisely backwards.
    static func requiredPopulation(for zone: ZoneType) -> Int {
        switch zone {
        // The core loop, available from tick one. `.empty` is the bulldozer,
        // which must never be locked — it is the only way out of a mistake.
        case .empty, .residential, .commercial, .industrial, .road:
            return 0
        // The starter utilities are part of the core loop, not a reward.
        // Buildings warn about missing water from density 2, so a city that
        // could not build *any* water supply until 100 residents showed
        // errors for a problem the player was not allowed to fix. These are
        // the answer to that warning from tick one; the tower and plant
        // become upgrades rather than prerequisites.
        case .waterPump, .generator:
            return 0
        // Unlocked from the start, and deliberately so. A park is the cheapest
        // answer to "this block is grim", and the land-value gate it helps
        // with bites from density 2 — which a city reaches long before any
        // service unlocks. Holding it back would repeat the mistake the
        // starter utilities exist to fix: a problem the game shows you and
        // does not let you solve.
        case .park:
            return 0
        // Once there is something standing, there is something to protect.
        case .policeStation, .fireStation:
            return 40
        // Arrives while growth is still capped at density 2 by
        // `CitySimulator.waterRequiredFromLevel`.
        case .waterTower:
            return 100
        case .publicTransit:
            return 200
        // Mid-game, and in this order because a school is what unlocks the
        // top density tier: it has to arrive comfortably before a city is
        // pressing against that ceiling, while a hospital is the later,
        // wider-reaching civic building.
        case .school:
            return 250
        case .hospital:
            return 600
        // Just past where water-only growth tops out, since
        // `powerRequiredFromLevel` gates density 4.
        case .powerPlant:
            return 300
        case .highway:
            return 500
        case .subway:
            return 700
        case .stadium:
            return 1_000
        }
    }

    /// A peak high enough to have earned every tool.
    ///
    /// For callers that want a city which has already grown up — the playtest
    /// harness, and tests about placement rules rather than about the ladder
    /// itself. Derived from the table rather than written down separately, so
    /// adding a rung above the stadium can't leave this stale.
    static var everythingUnlocked: Int {
        ZoneType.allCases.map(requiredPopulation(for:)).max() ?? 0
    }

    /// Has a city that peaked at `peakPopulation` earned `zone`?
    static func isUnlocked(_ zone: ZoneType, peakPopulation: Int) -> Bool {
        peakPopulation >= requiredPopulation(for: zone)
    }

    /// Every zone a city earns at exactly `population`, for announcing it.
    /// Empty on almost every tick.
    static func newlyUnlocked(crossing population: Int, from previousPeak: Int) -> [ZoneType] {
        guard population > previousPeak else { return [] }
        return ZoneType.allCases.filter { zone in
            let required = requiredPopulation(for: zone)
            return required > previousPeak && required <= population
        }
    }
}
