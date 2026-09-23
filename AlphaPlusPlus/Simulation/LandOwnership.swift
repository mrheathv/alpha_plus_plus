import Foundation

/// **Which of the map the city owns, and what the rest costs.**
///
/// The map a player founds is the *region*; the city starts on the middle of
/// it and buys the rest in square parcels, the way Cities: Skylines sells land.
/// Two problems answered by one mechanic:
///
/// - **Money had nowhere to go.** A settled city banks without limit — a
///   default 64×64 city holds $1.25M after 1,500 days and a max-tax one $15M
///   (`MilestoneCalibrationTests`) — and every sink added so far has been an
///   upkeep, which a big tax base simply outruns. Land is a purchase whose
///   price climbs with every parcel bought, so expansion itself is what the
///   treasury is for.
/// - **The ladder rewarded nothing.** Each rank now permits more land, so
///   earning one is what lets the city grow.
///
/// **Rank decides whether you may buy; money decides whether you can.** The
/// allowance is sized so each rank's land can hold the *next* rank's
/// population: measured cities reach 50–70 residents per parcel
/// (`MilestoneCalibrationTests`, 960 on the 16 parcels of a 32×32 map at the
/// top end), so Village's 400 needs about 8 parcels and is allowed 10, Town's
/// 900 needs about 18 and Village permits 20, and so on. An allowance smaller
/// than that would be a deadlock — a rank you can only reach with land that
/// rank unlocks — and `LandOwnershipTests` pins it.
///
/// Lives in `Simulation/` and rides on `CityMap` as an `Optional`, where `nil`
/// means the whole map is owned. That is what every save written before this
/// decodes to, and what every test fixture and playtest harness city is:
/// they measure the city's own economics, and a land budget would turn every
/// one of them into a measurement of how much map the fixture happened to
/// start with.
struct LandOwnership: Codable, Equatable {

    /// A parcel's position in parcel units — (1, 2) is the second parcel
    /// across and the third down.
    struct Parcel: Codable, Hashable, Comparable {
        let x: Int
        let y: Int

        static func < (lhs: Parcel, rhs: Parcel) -> Bool {
            (lhs.y, lhs.x) < (rhs.y, rhs.x)
        }

        var orthogonalNeighbours: [Parcel] {
            [Parcel(x: x + 1, y: y), Parcel(x: x - 1, y: y),
             Parcel(x: x, y: y + 1), Parcel(x: x, y: y - 1)]
        }
    }

    /// Tiles along one side of a parcel. Every map size the founding panel
    /// offers divides by it: 32, 48 and 64 are four, six and eight parcels
    /// across. Eight because a parcel should hold a couple of streets of
    /// blocks — a decision about *where* to grow, not a click per lot.
    static let parcelSize = 8

    let parcelsAcross: Int
    let parcelsDown: Int
    private(set) var owned: Set<Parcel>
    /// How many parcels the city started with, so the price counts only what
    /// was bought.
    let startingParcels: Int

    /// The middle of the map: the central two by two parcels, sixteen tiles
    /// square. A quarter of the smallest map, a sixteenth of the largest.
    static func starting(width: Int, height: Int) -> LandOwnership {
        let across = Swift.max(1, width / parcelSize)
        let down = Swift.max(1, height / parcelSize)
        var owned: Set<Parcel> = []
        let startX = Swift.max(0, across / 2 - 1)
        let startY = Swift.max(0, down / 2 - 1)
        for y in startY ..< Swift.min(down, startY + 2) {
            for x in startX ..< Swift.min(across, startX + 2) {
                owned.insert(Parcel(x: x, y: y))
            }
        }
        return LandOwnership(parcelsAcross: across, parcelsDown: down,
                             owned: owned, startingParcels: owned.count)
    }

    func parcel(containing position: GridPosition) -> Parcel {
        Parcel(x: position.x / Self.parcelSize, y: position.y / Self.parcelSize)
    }

    func contains(_ parcel: Parcel) -> Bool {
        parcel.x >= 0 && parcel.y >= 0 && parcel.x < parcelsAcross && parcel.y < parcelsDown
    }

    func owns(_ position: GridPosition) -> Bool {
        owned.contains(parcel(containing: position))
    }

    /// The tile at a parcel's minimum corner — where its cursor is drawn from.
    func origin(of parcel: Parcel) -> GridPosition {
        GridPosition(x: parcel.x * Self.parcelSize, y: parcel.y * Self.parcelSize)
    }

    /// Land has to touch land you own. A city is one place, not scattered
    /// holdings — and the rule is what makes *which* parcel you buy next a
    /// decision about direction: toward the river, the coast, the edge the
    /// rail line needs to reach.
    func touchesOwnedLand(_ parcel: Parcel) -> Bool {
        parcel.orthogonalNeighbours.contains { owned.contains($0) }
    }

    var boughtCount: Int { owned.count - startingParcels }

    var isComplete: Bool { owned.count >= parcelsAcross * parcelsDown }

    /// What the next parcel costs.
    ///
    /// Linear in how many have been bought: $2,500, then $5,000, then $7,500.
    /// The first is a quarter of a new city's starting treasury, so buying
    /// land is something an early city does rather than saves up for; the
    /// sixtieth, on the largest map, is $150,000 — about 150 days of a
    /// settled city's surplus. Buying out a 64×64 region costs about $4.6M in
    /// all, which is the size of problem the "money accumulates" finding
    /// describes.
    ///
    /// **Sized by argument, not yet measured**, the way `capacityPerStop` and
    /// the port upkeeps were first sized. The playtest harness zones a whole
    /// map at once and owns all of it, so it cannot see an expanding city;
    /// measuring this needs a scenario that buys as it grows.
    var nextPrice: Int { Self.basePrice * (boughtCount + 1) }

    static let basePrice = 2_500

    /// How many parcels in total a city at `rank` may own.
    ///
    /// Each rank's allowance holds the *next* rank's population with room to
    /// spare — see the type's doc comment for the arithmetic, and
    /// `LandOwnershipTests` for the check that it never deadlocks. City and
    /// above may own everything: Metropolis needs 3,500 residents, which takes
    /// most of a 64×64 region, and the top of the ladder should not be a
    /// cage.
    static func allowance(for rank: Milestone?) -> Int {
        switch rank {
        case nil: return 6
        case .hamlet: return 10
        case .village: return 20
        case .town: return 42
        case .city, .metropolis: return Int.max
        }
    }

    enum Refusal: Equatable {
        case offTheMap
        case alreadyOwned
        case notTouchingOwnedLand
        /// The rank allows no more land yet. Carries the rank that would.
        case needsRank(Milestone?)
    }

    /// Why `parcel` cannot be bought by a city at `rank`, or `nil` if it can
    /// (money aside — the treasury is the controller's).
    func refusal(for parcel: Parcel, rank: Milestone?) -> Refusal? {
        guard contains(parcel) else { return .offTheMap }
        guard !owned.contains(parcel) else { return .alreadyOwned }
        guard touchesOwnedLand(parcel) else { return .notTouchingOwnedLand }
        guard owned.count < Self.allowance(for: rank) else {
            // The lowest rank above this one that would permit one more.
            let next = Milestone.allCases.first { candidate in
                (rank.map { candidate > $0 } ?? true) && Self.allowance(for: candidate) > owned.count
            }
            return .needsRank(next)
        }
        return nil
    }

    mutating func buy(_ parcel: Parcel) {
        owned.insert(parcel)
    }
}

extension CityMap {
    /// Does the city own the ground at `position`? Always true on a map with
    /// no land budget — see `LandOwnership`.
    func isOwned(_ position: GridPosition) -> Bool {
        land?.owns(position) ?? true
    }
}
