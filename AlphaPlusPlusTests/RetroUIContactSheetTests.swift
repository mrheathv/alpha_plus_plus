import XCTest
import SwiftUI
@testable import AlphaPlusPlus

/// Renders the cockpit's components to a PNG.
///
/// **Why the UI needs this as much as the buildings did.** Every art decision
/// in this project is reviewed on a render rather than argued about, because
/// "look at the art, don't imagine it" has caught something every single time.
/// The chrome had no such render — it was only ever checked by running the app,
/// which on this machine means a remote desktop session that does not reliably
/// hand back a screenshot.
///
/// `ImageRenderer` turns a SwiftUI view into a bitmap with no window involved,
/// so the toolbar gets the same treatment the map already has: change it, look
/// at it, then decide.
@MainActor
final class RetroUIContactSheetTests: XCTestCase {

    func testRenderComponentSheet() throws {
        try render(name: "retro-ui", content: componentSheet)
    }

    /// The cockpit as the player sees it: tools above, dashboard below.
    ///
    /// Assembled from the same components the live view uses, so this is a
    /// picture of the real chrome rather than a mock of it — which is what
    /// makes it worth looking at before deciding anything.
    func testRenderCockpit() throws {
        let cockpit = VStack(spacing: 0) {
            HStack(spacing: RetroMetrics.gutter) {
                RetroToolChip(title: "Bulldoze", accent: .red, action: {})
                Rectangle().fill(RetroUITheme.textSecondary.opacity(0.3)).frame(width: 1, height: 20)
                HStack(spacing: 4) {
                    ForEach(ToolCategory.allCases) { category in
                        RetroBadge(text: category.displayName,
                                   accent: RetroUITheme.primaryAccent,
                                   isUrgent: category == .utilities)
                    }
                }
                Rectangle().fill(RetroUITheme.textSecondary.opacity(0.3)).frame(width: 1, height: 20)
                ForEach(ToolCategory.utilities.entries) { entry in
                    RetroToolChip(title: entry.title, cost: entry.cost,
                                  accent: RetroUITheme.accent(for: entry.accentZone),
                                  isSelected: entry.zone == .waterPump,
                                  lockedBy: entry.zone == .powerPlant ? "184 more residents" : nil,
                                  action: {})
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, RetroMetrics.gutter)
            .padding(.vertical, 8)

            Rectangle().fill(RetroUITheme.panel).frame(height: 150)
                .overlay(Text("— map —").foregroundStyle(RetroUITheme.textSecondary))

            HStack(alignment: .top, spacing: RetroMetrics.gutter) {
                RetroPanel(title: "Simulation", accent: RetroUITheme.primaryAccent) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Pause") {}.buttonStyle(RetroButtonStyle(accent: .orange, isSelected: true))
                        HStack(spacing: 4) {
                            ForEach(["Normal", "Land Value", "Traffic"], id: \.self) {
                                RetroBadge(text: $0, accent: RetroUITheme.primaryAccent, isUrgent: $0 == "Normal")
                            }
                        }
                    }
                }
                RetroPanel(title: "City", accent: RetroUITheme.primaryAccent) {
                    HStack(alignment: .top, spacing: 16) {
                        RetroStatTile(label: "Population", value: "3,984",
                                      history: [10, 220, 900, 2600, 3984], accent: .green)
                        RetroStatTile(label: "Jobs", value: "2,140",
                                      history: [4, 140, 700, 1800, 2140], accent: .cyan)
                        RetroStatTile(label: "Treasury", value: "$1,482,910", detail: "+$1,798/tick",
                                      history: [100, 900, 1400, 1300, 1482], accent: .yellow)
                    }
                }
                RetroPanel(title: "Utilities", accent: RetroUITheme.accent(for: .waterTower)) {
                    VStack(alignment: .leading, spacing: 8) {
                        RetroMeter(label: "Water", fill: 0.6, detail: "120/200",
                                   accent: RetroUITheme.accent(for: .waterTower))
                        RetroMeter(label: "Power", fill: 1.3, detail: "520/400",
                                   accent: RetroUITheme.accent(for: .powerPlant))
                    }
                    .frame(width: 104)
                }
                RetroPanel(title: "Alerts", accent: .orange) {
                    VStack(alignment: .leading, spacing: 5) {
                        RetroBadge(text: "⚠ Outage — grid unpowered", accent: .red, isUrgent: true)
                        RetroBadge(text: "Next: Subway at 700", accent: RetroUITheme.primaryAccent)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(RetroMetrics.gutter)
        }
        .frame(width: 1180)
        .background(RetroUITheme.background)

        try render(name: "retro-cockpit", content: cockpit)
    }

    private var componentSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("RETRO UI — COCKPIT PARTS")
                .font(.system(size: 13, weight: .bold)).tracking(2)
                .foregroundStyle(RetroUITheme.textPrimary)

            RetroPanel(title: "Tools", accent: RetroUITheme.secondaryAccent) {
                HStack(spacing: RetroMetrics.gutter) {
                    RetroToolChip(title: "Bulldoze", accent: .red, action: {})
                    RetroToolChip(title: "Residential", cost: 100,
                                  accent: RetroUITheme.accent(for: .residential),
                                  isSelected: true, action: {})
                    RetroToolChip(title: "Road", cost: 10,
                                  accent: RetroUITheme.accent(for: .road), action: {})
                    RetroToolChip(title: "Stadium", cost: 5000,
                                  accent: RetroUITheme.accent(for: .stadium),
                                  lockedBy: "740 more residents", action: {})
                }
            }

            HStack(alignment: .top, spacing: RetroMetrics.gutter) {
                RetroPanel(title: "Utilities", accent: RetroUITheme.accent(for: .waterTower)) {
                    VStack(alignment: .leading, spacing: 8) {
                        RetroMeter(label: "Water", fill: 0.6, detail: "120/200",
                                   accent: RetroUITheme.accent(for: .waterTower))
                        RetroMeter(label: "Power", fill: 1.3, detail: "520/400",
                                   accent: RetroUITheme.accent(for: .powerPlant))
                    }
                    .frame(width: 150)
                }
                RetroPanel(title: "City", accent: RetroUITheme.primaryAccent) {
                    HStack(spacing: 16) {
                        RetroStatTile(label: "Population", value: "3,984",
                                      history: [10, 220, 900, 2600, 3984], accent: .green)
                        RetroStatTile(label: "Treasury", value: "$1,482,910", detail: "+$1,798/tick",
                                      history: [100, 900, 1400, 1300, 1482], accent: .yellow)
                    }
                }
                RetroPanel(title: "Alerts", accent: .orange) {
                    VStack(alignment: .leading, spacing: 6) {
                        RetroBadge(text: "⚠ Outage — grid unpowered", accent: .red, isUrgent: true)
                        RetroBadge(text: "Unlocked: Hospital", accent: .green)
                    }
                }
            }
        }
        .padding(20)
        .background(RetroUITheme.background)
    }

    private func render(name: String, content: some View) throws {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "ImageRenderer produced nothing")
        let data = try XCTUnwrap(
            NSBitmapImageRep(data: image.tiffRepresentation ?? Data())?.representation(using: .png, properties: [:]),
            "failed to encode \(name)"
        )
        let destination = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ContactSheet/\(name).png")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: destination)
        print("🎛  \(name): \(destination.path) (\(data.count) bytes)")
        XCTAssertGreaterThan(data.count, 0)
    }
}
