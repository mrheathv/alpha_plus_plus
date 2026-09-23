import XCTest
@testable import AlphaPlusPlus

/// **Does the live renderer hold what a fresh one would?** Migration phase M5.
///
/// The question every playtest step asks: is the renderer
/// that has been updated change by change — chunks rebuilt only where a
/// signature moved, a motion plan rebuilt only when its key moved, a view
/// rebuilt on each new revision — holding exactly what a renderer built
/// fresh from this city right now would hold? Every chunk's triangles and
/// lights, byte for byte; the motion plan; the view.
///
/// It compares **what was handed to the GPU**, not pixels: two renderers
/// holding the same buffers draw the same frame, and a buffer names the
/// chunk that fell behind where a pixel diff would only say "somewhere".
@MainActor
enum MetalAgreement {

    static func violations(in live: MetalCityRenderer, controller: GameController) -> [String] {
        guard let fresh = MetalCityRenderer() else { return ["no Metal device"] }
        fresh.showsTraffic = live.showsTraffic
        fresh.overlayMode = live.overlayMode
        fresh.update(controller.map, revision: nil)

        var problems: [String] = []
        let a = live.chunksForTesting(), b = fresh.chunksForTesting()
        if a.count != b.count {
            problems.append("\(a.count) chunks drawn, \(b.count) expected")
        }
        for (mine, theirs) in zip(a, b) where mine != theirs {
            let region = "chunk (\(theirs.x0),\(theirs.y0))–(\(theirs.x1),\(theirs.y1))"
            if mine.vertices.count != theirs.vertices.count {
                problems.append("\(region): \(mine.vertices.count / 20) vertices drawn, \(theirs.vertices.count / 20) expected")
            } else if mine.vertices != theirs.vertices {
                problems.append("\(region) is stale: same size, different triangles")
            }
            if mine.lights != theirs.lights { problems.append("\(region): its lights are stale") }
            if mine.groundCount != theirs.groundCount { problems.append("\(region): ground and buildings split wrong") }
        }

        let plan = live.motion.planForTesting, expected = fresh.motion.planForTesting
        if plan.cars != expected.cars {
            problems.append("traffic is stale: \(plan.cars.count / 13) cars planned, \(expected.cars.count / 13) expected")
        }
        if plan.runs != expected.runs { problems.append("a tram, ship or engine is on a stale route") }
        if plan.airports != expected.airports { problems.append("an aircraft is flying from an airport that moved") }
        if plan.fires != expected.fires { problems.append("the flames are stale: \(plan.fires.count / 4) drawn, \(expected.fires.count / 4) burning") }
        if plan.smoke != expected.smoke { problems.append("factory smoke is stale") }

        let view = live.overlay, reference = fresh.overlay
        if view.tiles != reference.tiles { problems.append("the \(live.overlayMode) view is stale on the ground") }
        if view.tint != reference.tint { problems.append("the \(live.overlayMode) view's building wash is stale") }
        if view.hidesBuildings != reference.hidesBuildings { problems.append("buildings shown/hidden wrongly under \(live.overlayMode)") }
        if view.traces != reference.traces { problems.append("a scaffold is stale") }
        if view.schematic != reference.schematic { problems.append("a pipe, power line or rail is stale") }
        if view.billboards != reference.billboards { problems.append("a badge is stale") }
        return problems
    }
}
