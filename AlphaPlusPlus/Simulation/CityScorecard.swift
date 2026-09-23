import Foundation

/// **How well a city is run, as a handful of numbers.**
///
/// The milestones ladder asks questions like "does this city get water to the
/// blocks that want it" and "is it choking on its own traffic", and those are
/// questions about the whole map rather than about one lot. Every answer here
/// is *called* from the system that owns it rather than restated — supply from
/// `Water`/`PowerGrid`, need from `CitySimulator.needsWater`, reach from
/// `ServiceCoverage`, congestion from `Traffic` — for the reason
/// `CityHazards.isExposed` exists: a second copy of a rule drifts from the
/// first the day either changes, and a milestone asking a different question
/// from the one the simulation gates on would reward the wrong city.
///
/// Every fraction is measured over *lots*, by building anchor, never over
/// tiles — a 3×3 plant is one building, and a threshold written in tiles
/// would quietly weigh every footprint differently.
struct CityScorecard: Equatable {

    /// Residents, the same figure the cockpit shows.
    var population = 0

    /// Growable lots with at least one level built. The denominator for most
    /// of what follows, and zero on an empty map — every ratio below then
    /// reads as perfect, which is right: an empty city has no unserved blocks.
    var builtLots = 0

    /// Of the lots that want water to grow or to keep what they have, the
    /// share that have it. `needsWater` is the gate the simulation itself
    /// uses, so a house too small to need water never counts against you.
    var waterServed = 1.0
    var powerServed = 1.0

    /// Of built housing, the share a school reaches. Housing only: a school is
    /// what opens the top tier, and the player's question is whether their
    /// *residents* can reach the ceiling.
    var schooled = 1.0

    /// Mean pollution under built housing, 0…1. Housing only because it is the
    /// zone `LandValue` weights pollution heaviest for — factories barely mind
    /// their own smoke, and that asymmetry is the whole planning mechanic.
    var homePollution = 0.0

    /// Mean congestion over road and highway tiles, 0…1.
    var congestion = 0.0

    /// Share of built growable lots in rubble.
    var rubble = 0.0

    /// Of housing whose residents found work, the share that commute by
    /// transit rather than by car.
    ///
    /// **Employment is deliberately not here.** It was, and measured across
    /// eight strategies on three map sizes it read 88–100% in every one — a
    /// city that has zoned any jobs at all employs nearly everybody. A figure
    /// that does not move cannot tell a good city from a bad one, and a
    /// milestone built on it would be a mechanic that never binds.
    var transitShare = 0.0

    init() {}

    static func measure(_ map: CityMap, population: Int) -> CityScorecard {
        var card = CityScorecard()
        card.population = population

        var wantWater = 0, haveWater = 0
        var wantPower = 0, havePower = 0
        var homes = 0, schooledHomes = 0, pollution = 0.0
        var commutes = 0, riding = 0
        var damaged = 0
        var roads = 0, congestion = 0.0
        let distances = ZoneDistanceField.compute(for: map)

        for tile in map.tiles {
            if tile.zone == .road || tile.zone == .highway {
                roads += 1
                congestion += Traffic.congestion(at: tile.position, in: map)
                continue
            }
            guard tile.isBuildingAnchor, tile.zone.maxDensity > 0 else { continue }
            let footprint = map.footprintCells(origin: tile.position, size: tile.zone.footprintSize)

            if CitySimulator.needsWater(tile) {
                wantWater += 1
                if footprint.contains(where: { Water.hasSupply(at: $0, in: map) }) { haveWater += 1 }
            }
            if CitySimulator.needsPower(tile) {
                wantPower += 1
                if footprint.contains(where: { PowerGrid.hasSupply(at: $0, in: map) }) { havePower += 1 }
            }

            guard tile.density > 0 else { continue }
            card.builtLots += 1
            if tile.isDamaged { damaged += 1 }

            guard tile.zone == .residential else { continue }
            homes += 1
            if CitySimulator.hasSchooling(footprint, in: map, using: distances) { schooledHomes += 1 }
            pollution += footprint.map { map.pollution.level(at: $0) }.reduce(0, +) / Double(footprint.count)

            if let commute = map.trafficLoad.commute(at: tile.position) {
                commutes += 1
                if commute.boarding != nil { riding += 1 }
            }
        }

        func share(_ part: Int, of whole: Int, empty: Double = 1) -> Double {
            whole == 0 ? empty : Double(part) / Double(whole)
        }
        card.waterServed = share(haveWater, of: wantWater)
        card.powerServed = share(havePower, of: wantPower)
        card.schooled = share(schooledHomes, of: homes)
        card.homePollution = homes == 0 ? 0 : pollution / Double(homes)
        card.congestion = roads == 0 ? 0 : congestion / Double(roads)
        card.rubble = share(damaged, of: card.builtLots, empty: 0)
        card.transitShare = share(riding, of: commutes, empty: 0)
        return card
    }
}
