import XCTest
@testable import AlphaPlusPlus

/// Covers `GridPosition.line(to:)`, the Bresenham interpolation that backs
/// `MapInteraction`'s drag-to-paint — it's what turns a fast mouse drag (which
/// only reports a handful of sampled points) into a gap-free stroke.
final class GridPositionTests: XCTestCase {

    func testLineToSelfIsJustThatOnePosition() {
        let position = GridPosition(x: 3, y: 3)
        XCTAssertEqual(position.line(to: position), [position])
    }

    func testHorizontalLineIncludesEveryTileBetween() {
        let line = GridPosition(x: 0, y: 0).line(to: GridPosition(x: 3, y: 0))
        XCTAssertEqual(line, [
            GridPosition(x: 0, y: 0),
            GridPosition(x: 1, y: 0),
            GridPosition(x: 2, y: 0),
            GridPosition(x: 3, y: 0),
        ])
    }

    func testLineIsReversibleEndToEnd() {
        // Not necessarily the same tiles in the same order pixel-for-pixel
        // on a diagonal (Bresenham can break ties differently depending on
        // direction), but it must start and end at the two positions either
        // way — a drag stroke should connect regardless of which end the
        // gesture started from.
        let a = GridPosition(x: 1, y: 5)
        let b = GridPosition(x: 6, y: 2)

        XCTAssertEqual(a.line(to: b).first, a)
        XCTAssertEqual(a.line(to: b).last, b)
        XCTAssertEqual(b.line(to: a).first, b)
        XCTAssertEqual(b.line(to: a).last, a)
    }

    /// The property that actually matters for gap-free painting: every
    /// consecutive pair of tiles in the line must be adjacent (including
    /// diagonally) — never a jump of two or more tiles, which is exactly
    /// what would still leave a hole in a fast-dragged road.
    func testConsecutiveTilesInALineAreAlwaysAdjacent() {
        let line = GridPosition(x: 0, y: 0).line(to: GridPosition(x: 5, y: 9))
        for (previous, current) in zip(line, line.dropFirst()) {
            XCTAssertLessThanOrEqual(abs(current.x - previous.x), 1)
            XCTAssertLessThanOrEqual(abs(current.y - previous.y), 1)
        }
    }

    // MARK: - manhattanDistance

    func testManhattanDistanceToSelfIsZero() {
        let position = GridPosition(x: 4, y: 4)
        XCTAssertEqual(position.manhattanDistance(to: position), 0)
    }

    func testManhattanDistanceSumsBothAxesRegardlessOfDirection() {
        // (2,3) -> (5,1): 3 across, 2 down = 5, independent of the signs
        // involved — this is the case a naive `x - other.x + y - other.y`
        // (no `abs`) would get wrong.
        let a = GridPosition(x: 2, y: 3)
        let b = GridPosition(x: 5, y: 1)
        XCTAssertEqual(a.manhattanDistance(to: b), 5)
        XCTAssertEqual(b.manhattanDistance(to: a), 5) // symmetric
    }
}
