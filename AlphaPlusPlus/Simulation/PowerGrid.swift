import Foundation

/// Whether a tile is actually served by the power grid — a real line
/// network, not a coverage radius, the exact same shape `Water.swift`
/// already uses for the water/sewage network: a building needs an
/// unbroken chain of powered tiles (`Tile.hasPowerLine`) connecting it
/// back to a `.powerPlant`, the same way a zone needs an actual road
/// (not just "somewhere nearby") for `CitySimulator.hasAccess`. Copied
/// from `Water`'s own shape almost line for line, since it's the same
/// underlying problem a second time: a real network search too
/// expensive to redo per single-tile query, computed once
/// (`computeSupply(for:)`) and cached (`CityMap.powerSupply`).
///
/// The one thing genuinely new here, that `Water` doesn't have: outages.
/// `computeSupply(for:outageActive:)` takes whether the grid is *currently*
/// blacked out as a plain `Bool` rather than rolling its own randomness —
/// `PowerGrid` stays exactly as deterministic as `Water` is, and the one
/// random decision (does an outage happen this tick) lives in
/// `GameController.advanceSimulation()`, alongside `CityHazards`' own
/// randomness, not duplicated here.
enum PowerGrid {

    /// Every powered tile reachable from *some* funded, non-outaged Power
    /// Plant, and whether the power-line neighbors of a given position
    /// are among them — `hasSupply(at:in:)` is the only thing most
    /// callers need.
    ///
    /// `outageActive` short-circuits to "nothing is powered" before doing
    /// any real search — an outage takes the *whole* grid down at once,
    /// not a random subset of it, the simplest version of this that's
    /// still a real, felt consequence (see `GameController`'s own doc
    /// comment on the outage roll for why city-wide rather than
    /// per-plant is this project's deliberate first cut, not an
    /// oversight).
    /// How many density levels one power plant can serve.
    ///
    /// Higher than `Water.capacityPerTower` because a plant is the expensive,
    /// large (3×3) half of the utility pair — a city needs fewer of them, and
    /// each one costs a real amount of space. Against a built-out large map's
    /// 1,500-2,000 total density that is four or five plants.
    static let capacityPerPlant = 400

    /// The starter `.generator`'s output — same reasoning as
    /// `Water.capacityPerPump`: enough to light an early city, not enough to
    /// make the full plant skippable.
    static let capacityPerGenerator = 120

    static func load(in map: CityMap) -> UtilityLoad {
        UtilityLoad(
            demand: UtilityLoad.demand(in: map),
            capacity: UtilityLoad.capacity(
                of: [(.powerPlant, capacityPerPlant), (.generator, capacityPerGenerator)],
                in: map
            )
        )
    }

    static func computeSupply(for map: CityMap, outageActive: Bool) -> PowerSupply {
        guard !outageActive else { return PowerSupply() }

        // Drawing more than the plants can supply browns the grid out, the
        // same city-wide way an outage does — see `Water.computeSupply` for
        // why whole-network rather than partial.
        guard !load(in: map).isOverloaded else { return PowerSupply() }

        // Funding is one city-wide dial per service (`ServiceFunding`'s
        // own design), not per-building — so defunding power takes every
        // plant offline at once, not just some of them, same as `Water`.
        guard map.serviceFunding.level(for: .powerPlant) > 0 else { return PowerSupply() }

        let lines = Set(map.tiles.filter { $0.hasPowerLine }.map(\.position))
        guard !lines.isEmpty else { return PowerSupply() }

        var frontier: [GridPosition] = []
        for tile in map.tiles where tile.isBuildingAnchor && (tile.zone == .powerPlant || tile.zone == .generator) {
            frontier.append(contentsOf: map.footprintCells(origin: tile.position, size: tile.zone.footprintSize)
                .flatMap { $0.orthogonalNeighbors() }
                .filter { lines.contains($0) })
        }
        guard !frontier.isEmpty else { return PowerSupply() }

        var reachable = Set(frontier)
        var queue = frontier
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            for neighbor in current.orthogonalNeighbors() where lines.contains(neighbor) && !reachable.contains(neighbor) {
                reachable.insert(neighbor)
                queue.append(neighbor)
            }
        }
        return PowerSupply(reachableLines: reachable)
    }

    /// Is any tile sharing an edge with `position` a supplied power line?
    /// The exact shape `Water.hasSupply(at:in:)` already uses — a
    /// building doesn't need to *be* a power line, just touch one that's
    /// actually connected.
    static func hasSupply(at position: GridPosition, in map: CityMap) -> Bool {
        position.orthogonalNeighbors().contains { map.powerSupply.isSupplied(at: $0) }
    }
}

/// The result of `PowerGrid.computeSupply(for:outageActive:)` — read-only
/// from the outside, same "one place produces this, everything else just
/// reads it" contract `WaterSupply`/`TrafficLoad`/`CityHazards.Strike`
/// all already use.
struct PowerSupply: Equatable, Codable, Sendable {
    private var reachableLines: Set<GridPosition>

    init() {
        self.reachableLines = []
    }

    fileprivate init(reachableLines: Set<GridPosition>) {
        self.reachableLines = reachableLines
    }

    /// Is `position` a power-line tile actually connected to a funded,
    /// non-outaged Power Plant? False for every tile on a `CityMap` that
    /// never had `computeSupply` run against it (a fresh map, or one
    /// built directly in a test) — same "nothing until computed" default
    /// `WaterSupply` uses.
    func isSupplied(at position: GridPosition) -> Bool {
        reachableLines.contains(position)
    }
}
