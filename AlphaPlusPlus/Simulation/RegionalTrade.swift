import Foundation

/// **The city's two freight connections to the outside world.**
///
/// Regional rail already connects a city to the region for *people*: run a
/// line to the map edge and its stops become a way out, so residents can work
/// somewhere this simulation does not model. That raises residential demand
/// and lowers the other two, which is the bedroom-community trade.
///
/// A **seaport** and an **airport** are the same idea for trade, and they
/// pull the other way. Neither moves a commuter; what they move is goods and
/// business, so each raises the demand of the sector it serves — industry for
/// the docks, commerce for the airport. A city with all three has a reason to
/// be large in every direction at once, which is the shape a late-game wants.
///
/// **The seaport is the first building in this game that needs the terrain.**
/// It has to touch water, so a Flat map cannot have one — which is what turns
/// the choice at founding from a look into a strategy. Rivers and coasts were
/// a picture until something depended on them.
///
/// Both are deliberately **buildings, not networks**. Rail earns its
/// connection by being routed to the edge, which is a thing you draw; a port
/// earns its connection by existing somewhere it can. One mechanic of each
/// kind is enough — a second drawn network would be the transit module again
/// with different nouns.
enum RegionalTrade {

    /// How much demand one working port adds to its own sector.
    ///
    /// Sized against `Demand.taxDemandSensitivity` (0.5) and
    /// `RegionalEconomy.amplitude` (0.25): a port is worth more than a swing
    /// of the regional cycle and less than the tax lever, so it is a
    /// substantial investment that cannot on its own overrule how the city is
    /// run. Two of the same kind add, but with diminishing returns — a second
    /// dock is worth about half the first, because the first one already
    /// connected the city and the second only widens the quay.
    static let boostPerPort = 0.34

    /// Is this port working — built, and paid for?
    ///
    /// Funding scales it rather than gating it, the same way it scales
    /// everything else a service does. A mothballed dock connects nothing.
    private static func workingPorts(_ zone: ZoneType, in map: CityMap) -> Double {
        let count = map.tiles.filter { $0.isBuildingAnchor && $0.zone == zone }.count
        guard count > 0 else { return 0 }
        return Double(count) * map.serviceFunding.level(for: zone)
    }

    /// Diminishing returns on however many are working.
    ///
    /// `1 - 0.5^n` rather than a flat multiple: the first port is the one
    /// that connects the city at all, and every one after it is widening a
    /// connection that already exists. Without this, ports are simply a
    /// demand slider a large treasury can hold down.
    private static func boost(_ zone: ZoneType, in map: CityMap) -> Double {
        let working = workingPorts(zone, in: map)
        guard working > 0 else { return 0 }
        return boostPerPort * (1 - pow(0.5, working))
    }

    /// What the docks do for industry.
    static func industrialBoost(in map: CityMap) -> Double {
        boost(.seaport, in: map)
    }

    /// What the airport does for commerce.
    static func commercialBoost(in map: CityMap) -> Double {
        boost(.airport, in: map)
    }

    /// Can a seaport go here — does this footprint touch water?
    ///
    /// Touching rather than standing in it: a dock is on the shore, and the
    /// *shore* is the thing a coastal or river map has that a flat one does
    /// not. Checked against the footprint's neighbours, so a 3×3 quay needs
    /// water along one of its edges rather than at one particular corner.
    static func canBerth(_ footprint: [GridPosition], in map: CityMap) -> Bool {
        footprint.contains { cell in
            cell.orthogonalNeighbors().contains { map.contains($0) && map[$0].isWater }
        }
    }
}
