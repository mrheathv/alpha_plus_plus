import XCTest
@testable import AlphaPlusPlus

/// The toolbar groups tools by `ToolCategory`. These guard the property that
/// actually matters: a tool that belongs to no group is a tool the player
/// cannot reach at all.
final class ToolCategoryTests: XCTestCase {

    /// Every placeable zone has to appear in exactly one group. Adding a new
    /// `ZoneType` without adding it to a category would make it unreachable
    /// from the toolbar, with nothing to say so — which is precisely the
    /// failure the flat row could not have.
    func testEveryZoneIsReachableFromExactlyOneGroup() {
        // `.empty` is the bulldozer: deliberately outside the groups, shown at
        // all times so undo never needs a category change.
        let grouped = ToolCategory.allTools
        for zone in ZoneType.allCases where zone != .empty {
            let containing = ToolCategory.allCases.filter { $0.tools.contains(zone) }
            XCTAssertEqual(
                containing.count, 1,
                "\(zone) appears in \(containing.count) tool groups; it must appear in exactly one"
            )
        }
        XCTAssertFalse(grouped.contains(.empty), "the bulldozer should not be inside a group")
        XCTAssertEqual(Set(grouped).count, grouped.count, "a zone is listed in more than one group")
    }

    func testTheBulldozerBelongsToNoGroup() {
        XCTAssertNil(ToolCategory.containing(.empty))
    }

    func testContainingFindsTheGroupForEveryOtherZone() {
        for zone in ZoneType.allCases where zone != .empty {
            XCTAssertNotNil(ToolCategory.containing(zone), "\(zone) has no group")
        }
    }

    /// No group should grow back to the size the flat row was — the point was
    /// to fit on screen.
    func testNoGroupIsUnreasonablyLarge() {
        for category in ToolCategory.allCases {
            XCTAssertLessThanOrEqual(
                category.tools.count, 6,
                "\(category.displayName) has \(category.tools.count) tools and is drifting back toward one long row"
            )
            XCTAssertFalse(category.tools.isEmpty, "\(category.displayName) is empty")
        }
    }

    /// Within a group, tools appear in the order the city earns them, so each
    /// group reads as its own small progression.
    func testGroupsAreOrderedByWhenTheyUnlock() {
        for category in ToolCategory.allCases {
            let thresholds = category.tools.map { Unlocks.requiredPopulation(for: $0) }
            XCTAssertEqual(
                thresholds, thresholds.sorted(),
                "\(category.displayName) lists its tools out of unlock order: \(thresholds)"
            )
        }
    }
}
