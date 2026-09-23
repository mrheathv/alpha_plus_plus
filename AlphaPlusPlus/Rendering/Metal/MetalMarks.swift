import SpriteKit
import simd

/// **What SpriteKit still drew over the Metal city** (M8): the placement
/// cursor, the flashes that answer a click, and the route diagram with the
/// vehicles running it. All of it is traces of light, drawn over everything,
/// because each is something the player is looking for rather than part of
/// the city.
///
/// The decisions are made elsewhere: what the cursor says is
/// `MapInteraction`'s (`MapMarks.Cursor`), which stops a route calls at is
/// `Transit.workingStops`, and the colours are `RenderPalette`'s, the same
/// ones SpriteKit used. This file only turns those answers into light.
enum MetalMarks {

    static func trace(_ a: SIMD3<Float>, _ b: SIMD3<Float>, width: Float, color: SIMD3<Float>,
                      alpha: Float = 1) -> [Float] {
        MetalMotion.trace(from: a, to: b, width: width, mode: 1, color: color, alpha: alpha)
    }

    // MARK: - The cursor

    /// The footprint cursor: the ground outline and a riser at each corner,
    /// `Isometric.footprintCursor`'s shape. The risers are what make it read
    /// as a volume about to be placed rather than one more diagonal on a map
    /// made of diagonals.
    static func cursor(_ cursor: MapMarks.Cursor) -> [Float] {
        let color = MetalCityMesh.linear(cursor.blocked ? RenderPalette.placementPreviewBlockedStroke
                                                        : RenderPalette.placementPreviewClearStroke) * 2.4
        let x = Float(cursor.origin.x), y = Float(cursor.origin.y), s = Float(cursor.size)
        let z: Float = 0.04, riser: Float = 0.35
        let corners = [SIMD2(x, y), SIMD2(x + s, y), SIMD2(x + s, y + s), SIMD2(x, y + s)]
        var traces: [Float] = []
        for (index, c) in corners.enumerated() {
            let next = corners[(index + 1) % 4]
            traces += trace(SIMD3(c.x, c.y, z), SIMD3(next.x, next.y, z), width: 0.05, color: color)
            traces += trace(SIMD3(c.x, c.y, z), SIMD3(c.x, c.y, z + riser), width: 0.05, color: color)
        }
        return traces
    }

    // MARK: - Flashes

    /// How long each flash lasts, SpriteKit's numbers: a hazard lingers a
    /// little longer than a refused click, being news rather than an answer.
    static func duration(of kind: MapMarks.Flash.Kind) -> Double {
        if case .hazard = kind { return 0.55 }
        return 0.35
    }

    static func color(of kind: MapMarks.Flash.Kind) -> SKColor {
        switch kind {
        case .insufficientFunds: return RenderPalette.insufficientFundsFlash
        case .blocked: return RenderPalette.blockedPlacementFlash
        case .hazard(let service):
            return service == .fireStation ? RenderPalette.fireHazardFlash : RenderPalette.crimeHazardFlash
        }
    }

    /// How bright a flash is `age` seconds in: full for the first quarter,
    /// then fading, as SpriteKit's wait-then-fade did. Zero once it is over.
    static func strength(of kind: MapMarks.Flash.Kind, age: Double) -> Float {
        let duration = duration(of: kind)
        guard age >= 0, age < duration else { return 0 }
        let hold = duration * 0.25
        return age < hold ? 1 : Float(1 - (age - hold) / (duration - hold))
    }

    /// One flash at `strength`: a pool of its colour spilling past the lot,
    /// which reads around a building standing on it, and the lot's outline
    /// over everything, which reads even when a tower hides the pool.
    static func flash(_ flash: MapMarks.Flash, strength: Float) -> (tiles: [Float], traces: [Float]) {
        let color = MetalCityMesh.linear(color(of: flash.kind))
        let x = Float(flash.origin.x), y = Float(flash.origin.y), s = Float(flash.size)
        let pool: [Float] = [x + s / 2, y + s / 2, 1.8 * s, 0.05,
                             color.x * strength, color.y * strength, color.z * strength, 1]
        let corners = [SIMD2(x, y), SIMD2(x + s, y), SIMD2(x + s, y + s), SIMD2(x, y + s)]
        var traces: [Float] = []
        for (index, c) in corners.enumerated() {
            let next = corners[(index + 1) % 4]
            traces += trace(SIMD3(c.x, c.y, 0.04), SIMD3(next.x, next.y, 0.04), width: 0.07,
                            color: color * (2.5 * strength))
        }
        return (pool, traces)
    }

    // MARK: - The route diagram

    /// A route's stops as points on the diagram: the centre of each station's
    /// footprint, on the ground.
    static func points(of stops: [GridPosition], mode: TransitRoute.Mode) -> [SIMD3<Float>] {
        let size = Float(mode.stationZone.footprintSize)
        return stops.map { SIMD3(Float($0.x) + size / 2, Float($0.y) + size / 2, 0.08) }
    }

    /// The lines of `mode` in service, and the one being drawn: SpriteKit's
    /// `transitDiagram`, in light. Schematic, a straight run from station to
    /// station, because that is what a route here is. A wide faint halo under
    /// a narrower core, kept dim enough that the two added together still
    /// read as the line's own colour rather than white, which is the mistake
    /// the first conduits and the first route lines both made.
    static func diagram(for mode: TransitRoute.Mode, in map: CityMap, drawing draft: TransitRouteDraft?) -> [Float] {
        let color = MetalCityMesh.linear(RenderPalette.transitLineColor(for: mode))
        let draft = draft?.mode == mode ? draft : nil
        var traces: [Float] = []
        for route in map.transit.routes(mode: mode) {
            // A line being edited is drawn as the draft, not twice.
            if let draft, draft.editing == route.id { continue }
            let working = Transit.workingStops(of: route, in: map)
            guard working.count >= TransitRoute.minimumStops else { continue }
            let points = points(of: working, mode: mode)
            for (a, b) in zip(points, points.dropFirst()) {
                traces += trace(a, b, width: 0.16, color: color * 0.5, alpha: 0.5)
                traces += trace(a, b, width: 0.05, color: color * 1.6)
            }
            // A station: a dark ring round a lit centre, the way a transit map
            // draws a stop, which survives being small. Drawn as a small
            // diamond: a circle is not a shape a trace makes, and a diamond
            // is the shape of everything on this map.
            for p in points { traces += stop(at: p, color: color * 1.8, radius: 0.2) }
        }
        // The draft: dashed, in the amber a scaffold already uses for "not
        // finished", above the finished lines.
        if let stops = draft?.stops, !stops.isEmpty {
            let amber = MetalCityMesh.linear(NeonStyle.scaffoldColor)
            let points = points(of: stops, mode: mode)
            for (a, b) in zip(points, points.dropFirst()) { traces += dashes(from: a, to: b, color: amber * 1.8) }
            for (index, p) in points.enumerated() {
                // The stop a second click would take off stands out.
                traces += stop(at: p, color: amber * (index == points.count - 1 ? 2.6 : 1.8), radius: 0.16)
            }
        }
        return traces
    }

    static func stop(at p: SIMD3<Float>, color: SIMD3<Float>, radius: Float) -> [Float] {
        let corners = [SIMD3(p.x - radius, p.y, p.z), SIMD3(p.x, p.y - radius, p.z),
                       SIMD3(p.x + radius, p.y, p.z), SIMD3(p.x, p.y + radius, p.z)]
        var traces: [Float] = []
        for (index, c) in corners.enumerated() {
            traces += trace(c, corners[(index + 1) % 4], width: 0.05, color: color)
        }
        traces += trace(SIMD3(p.x - radius * 0.35, p.y, p.z), SIMD3(p.x + radius * 0.35, p.y, p.z),
                        width: radius * 0.6, color: color)
        return traces
    }

    static func dashes(from a: SIMD3<Float>, to b: SIMD3<Float>, color: SIMD3<Float>) -> [Float] {
        let length = simd_length(b - a)
        guard length > 0 else { return [] }
        let dash: Float = 0.35, gap: Float = 0.25
        var traces: [Float] = []
        var start: Float = 0
        while start < length {
            let end = min(start + dash, length)
            traces += trace(a + (b - a) * (start / length), a + (b - a) * (end / length), width: 0.05, color: color)
            start = end + gap
        }
        return traces
    }

    /// A vehicle on each working line, running out and back over the
    /// diagram, paced off the mode's own `minutesPerTile` as SpriteKit's
    /// were: the same constant the router weighs journeys with, so a subway
    /// visibly outruns a bus over the same stations. A function of the motion
    /// clock, so it stops when the city does.
    static func vehicles(for mode: TransitRoute.Mode, in map: CityMap, clock: Double) -> [Float] {
        let color = MetalCityMesh.linear(RenderPalette.transitLineColor(for: mode)) * 3
        var traces: [Float] = []
        for route in map.transit.routes(mode: mode) {
            let stops = Transit.workingStops(of: route, in: map)
            guard stops.count >= 2 else { continue }
            let points = points(of: stops, mode: mode).map { $0 + SIMD3(0, 0, 0.02) }
            let tiles = zip(stops, stops.dropFirst()).reduce(0.0) { total, pair in
                total + Double(abs(pair.1.x - pair.0.x) + abs(pair.1.y - pair.0.y))
            }
            let duration = max(2.0, tiles * mode.minutesPerTile * 0.55)
            let phase = clock.truncatingRemainder(dividingBy: duration * 2) / duration
            let along = Float(phase < 1 ? phase : 2 - phase)
            guard let (position, heading) = point(along: along, of: points) else { continue }
            let half = heading * 0.45
            traces += trace(position - half, position + half, width: 0.09, color: color, alpha: 0.8)
        }
        return traces
    }

    /// The point a fraction `t` of the way along a polyline, and the unit
    /// direction it is heading.
    static func point(along t: Float, of points: [SIMD3<Float>]) -> (SIMD3<Float>, SIMD3<Float>)? {
        let lengths = zip(points, points.dropFirst()).map { simd_length($1 - $0) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return nil }
        var remaining = t * total
        for (index, length) in lengths.enumerated() {
            if remaining <= length || index == lengths.count - 1 {
                let a = points[index], b = points[index + 1]
                let direction = length > 0 ? (b - a) / length : SIMD3(1, 0, 0)
                return (a + direction * min(remaining, length), direction)
            }
            remaining -= length
        }
        return nil
    }
}
