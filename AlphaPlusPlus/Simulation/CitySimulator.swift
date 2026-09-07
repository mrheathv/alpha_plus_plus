import Foundation

/// The time-driven rules that grow a city, as opposed to `GameController`'s
/// player-driven rules (click to place/bulldoze). Splitting them this way
/// keeps `CityMap`/`Tile` as pure data with two separate rule engines acting
/// on it — one triggered by the player, one triggered by advancing time —
/// rather than either kind of rule ending up bolted onto the data model
/// itself.
///
/// A stateless `enum` (never instantiated) because growth is a pure
/// function of the current map: same input map in, same output map out,
/// every time — no randomness here. Random, service-gated risk to already
/// -developed tiles lives separately, in `CityHazards`, precisely so this
/// type can stay simple and deterministic to test.
enum CitySimulator {

    /// One simulation step: every zoned *building* (processed once at its
    /// anchor — see `Tile.isBuildingAnchor` — regardless of whether it's a
    /// 1×1 road-side lot or a 2×2 block) with access (a road or transit stop
    /// at any of its cells' edges) grows by one density level, *if* the best
    /// land value across its cells clears the bar `requiredLandValue(toReach:)`
    /// sets for that level — a building with only bare-minimum access can
    /// stall a level or two short of full density until something (another
    /// road, a nearby station) raises its land value further. A building
    /// that's *lost* access decays by one level instead, down to 0. It never
    /// does both in the same step — access means grow-or-hold, no access
    /// means decay-or-hold — so `.empty`/`.road`/service tiles (incapable of
    /// density in the first place) are the only ones skipped outright.
    /// Whatever the result, it's applied to *every* cell the building
    /// covers, so all of them always agree on density.
    ///
    /// Takes a `CityMap` and returns a new one rather than mutating in
    /// place — `CityMap` is already a value type, so "advance the
    /// simulation" reads the same way "place a zone" does on
    /// `GameController`: compute the next state, hand it back, let the
    /// caller decide what to do with it (here, `GameController.advanceSimulation()`
    /// just assigns it to `map`).
    static func advance(_ map: CityMap) -> CityMap {
        var next = map
        for tile in map.tiles where tile.isBuildingAnchor {
            guard tile.zone.maxDensity > 0 else { continue }
            let footprint = map.footprintCells(origin: tile.position, size: tile.zone.footprintSize)
            let isConnected = footprint.contains { hasAccess(at: $0, in: map) }

            if isConnected {
                let nextLevel = tile.density + 1
                guard nextLevel <= tile.zone.maxDensity else { continue }
                let bestLandValue = footprint.map { LandValue.value(at: $0, in: map) }.max() ?? 0
                guard bestLandValue >= requiredLandValue(toReach: nextLevel) else { continue }
                if nextLevel >= Self.waterRequiredFromLevel {
                    guard footprint.contains(where: { Water.hasSupply(at: $0, in: map) }) else { continue }
                }
                for cell in footprint { next[cell].density = nextLevel }
            } else if tile.density > 0 {
                let previousLevel = tile.density - 1
                for cell in footprint { next[cell].density = previousLevel }
            }
        }
        return next
    }

    /// Is any tile sharing an edge with `position` a road, a highway, a
    /// transit stop, or a subway? All four count equally as "connected" for
    /// growth purposes — `.highway`/`.subway` are pricier, higher-capacity
    /// versions of `.road`/`.publicTransit` (see `ZoneType`'s own doc
    /// comment), not a *different kind* of access.
    static func hasAccess(at position: GridPosition, in map: CityMap) -> Bool {
        position.orthogonalNeighbors().contains { neighbor in
            guard map.contains(neighbor) else { return false }
            let zone = map[neighbor].zone
            return zone == .road || zone == .publicTransit || zone == .highway || zone == .subway
        }
    }

    /// The land value a tile needs to advance *to* density level `level`.
    /// A tile touching exactly one road and nothing else sits at land value
    /// 0.75 (see `LandValue.roadFalloffDistance`) — comfortably past every
    /// threshold except the last, so bare road access alone carries a zone
    /// to density 4 but not the full 5; reaching 5 needs something more to
    /// push land value past 0.8. A second nearby road doesn't do it —
    /// `LandValue.value(at:in:)` takes the *nearest* road's own falloff,
    /// not a sum across every road in reach, so more roads alone can't
    /// climb past the same 0.75 ceiling one road already gives. A real
    /// station, subway stop, or stadium within about a road's width can:
    /// see `LandValue.serviceFalloffDistance`'s doc comment for the
    /// playtesting that pinned down exactly how close "within reach" needs
    /// to be. Level 2–4's thresholds are still a first guess, not a tuned
    /// balance — easy to revisit once growth-with-a-ceiling has been played
    /// with more.
    private static func requiredLandValue(toReach level: Int) -> Double {
        switch level {
        case ...1: return 0.0
        case 2: return 0.3
        case 3: return 0.5
        case 4: return 0.65
        default: return 0.8
        }
    }

    /// Below this level, a zone only needs today's road access + land
    /// value — a starter lot doesn't need city utilities yet. At this
    /// level and above, it *additionally* needs a real, connected water
    /// supply (`Water.hasSupply(at:in:)`), not just land value clearing
    /// the bar `requiredLandValue(toReach:)` already sets. Same "one more
    /// threshold, not a bolted-on second system" shape as the land-value
    /// gate itself: losing water later doesn't cause decay, exactly like
    /// insufficient land value doesn't — it just holds growth where it
    /// is until the supply comes back. A first guess like every other
    /// number in this file.
    private static let waterRequiredFromLevel = 3
}
