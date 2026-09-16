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
    /// Every entry the toolbar offers appears exactly once across all groups.
    ///
    /// The point of a registry is that adding a control is adding data, and
    /// the risk of one is that data can be added twice or in two places. This
    /// is the guarantee that makes the layout safe to be dumb about what it is
    /// rendering.
    func testEveryToolbarEntryAppearsExactlyOnce() {
        let entries = ToolCategory.allEntries
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count,
                       "a toolbar entry is listed in more than one group")
    }

    /// Pipes and power lines have to be *somewhere*. They are not `ZoneType`s,
    /// so nothing else in the test suite would notice them going missing — and
    /// they were once completely unreachable, with nothing on screen saying
    /// they existed at all.
    func testBothEditableNetworksAreOffered() {
        let overlays = Set(ToolCategory.allEntries.compactMap(\.overlay))
        XCTAssertTrue(overlays.contains(.water), "no way to lay pipe")
        XCTAssertTrue(overlays.contains(.power), "no way to lay power line")
    }

    /// An entry that costs something must say so, or the player finds out by
    /// being charged.
    func testPlaceableEntriesCarryTheirCost() {
        for entry in ToolCategory.allEntries {
            guard let zone = entry.zone else {
                XCTAssertNotNil(entry.cost, "\(entry.title) is a network tool with no cost shown")
                continue
            }
            XCTAssertEqual(entry.cost, zone.placementCost > 0 ? zone.placementCost : nil,
                           "\(entry.title) shows a cost that is not what it charges")
        }
    }

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

/// The toolbar has to be able to do everything on its own — reaching for the
/// menu bar to lay a pipe is not a workflow.
@MainActor
final class NetworkToolTests: XCTestCase {

    /// Pipes and power lines are laid by clicking while their overlay is up,
    /// so the overlay *is* the tool. Picking an ordinary zone has to leave it,
    /// or the player is in an invisible mode where clicks do something other
    /// than what the highlighted tool says.
    func testPickingAZoneToolLeavesTheWaterOverlay() {
        let controller = GameController()
        controller.overlayMode = .water

        controller.selectTool(.residential)

        XCTAssertEqual(controller.selectedTool, .residential)
        XCTAssertEqual(controller.overlayMode, OverlayMode.none)
    }

    func testPickingAZoneToolLeavesThePowerOverlay() {
        let controller = GameController()
        controller.overlayMode = .power

        controller.selectTool(.road)

        XCTAssertEqual(controller.overlayMode, OverlayMode.none)
    }

    /// A view-only overlay is not a mode that changes what a click does, so
    /// picking a tool while it is up must leave it alone.
    func testPickingAToolKeepsAViewOnlyOverlay() {
        for overlay in [OverlayMode.landValue, .traffic, .pollution] {
            let controller = GameController()
            controller.overlayMode = overlay

            controller.selectTool(.commercial)

            XCTAssertEqual(
                controller.overlayMode, overlay,
                "\(overlay.displayName) is a view overlay and should survive picking a tool"
            )
        }
    }

    /// Every overlay the game has must be reachable from the in-game picker,
    /// which renders `OverlayMode.allCases` — this guards against a new
    /// overlay being added to the enum and shown only in the menu bar.
    func testEveryOverlayIsOfferedInGame() {
        XCTAssertTrue(OverlayMode.allCases.contains(.none))
        XCTAssertTrue(OverlayMode.allCases.contains(.water))
        XCTAssertTrue(OverlayMode.allCases.contains(.power))
        XCTAssertGreaterThanOrEqual(OverlayMode.allCases.count, 6)
        for mode in OverlayMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty, "\(mode) has no label to show on a button")
        }
    }
}
