import XCTest
import SwiftUI
@testable import AlphaPlusPlus

/// The list of views, and the menu that has to keep working as it grows.
@MainActor
final class OverlayModeTests: XCTestCase {

    /// **The Overlay menu used to crash the app on its tenth entry.** It built
    /// each shortcut as `Character("\(index)")`, which is a fatal error the
    /// moment an index reaches two digits — and `CommandMenu` problems in this
    /// project have a history of failing silently, so nothing would have
    /// pointed at the menu.
    ///
    /// Asserted over `allCases` rather than against a fixed number, because
    /// the thing that breaks it is somebody adding an overlay, which is
    /// exactly the change that will not think to come here.
    func testEveryOverlayGetsAValidShortcutOrNoneAtAll() {
        for (index, mode) in OverlayMode.allCases.enumerated() {
            // The assertion is that this does not trap. `nil` is a fine
            // answer — past the digits there is no key left to claim.
            let shortcut = AlphaPlusPlusApp.overlayShortcut(for: index)
            if index <= 9 {
                XCTAssertNotNil(shortcut, "\(mode.displayName) lost its shortcut")
            } else {
                XCTAssertNil(shortcut, "\(mode.displayName) claimed a two-digit shortcut")
            }
        }
    }

    /// A picker renders `displayName`, so two overlays sharing one would be
    /// two identical chips — the trap the Speed and View rows already hit once
    /// with two adjacent buttons both reading "Normal".
    func testEveryOverlayIsNamedAndNamedDistinctly() {
        let names = OverlayMode.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count, "two overlays share a name: \(names)")
        XCTAssertFalse(names.contains { $0.isEmpty })
    }

    /// Bus and subway are separate views on purpose — see `OverlayMode.bus`.
    func testTransitGetsAViewPerMode() {
        for mode in TransitRoute.Mode.allCases {
            let overlay: OverlayMode = mode == .bus ? .bus : .subway
            XCTAssertTrue(OverlayMode.allCases.contains(overlay), "\(mode) has no overlay")
        }
    }
}
