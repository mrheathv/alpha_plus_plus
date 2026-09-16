import SwiftUI

/// The cockpit's parts.
///
/// **Why a component library rather than more `HStack`s.** `GameView` grew to
/// four hundred lines of hand-rolled rows, and adding anything meant editing
/// one of them — which is how the toolbar overflowed twice and how ordinances
/// and bonds ended up with no home in the UI at all. These are the pieces a
/// panel is assembled from, so a new control is a line of data rather than a
/// line of layout.
///
/// **And why they are shaped like a dashboard.** A city builder's readouts
/// *are* its gameplay: demand, utility load and treasury are the signals the
/// whole simulation exists to produce, and they were being squeezed into
/// whatever width was left over on a single row. A cockpit gives them room,
/// and it is also a far better home for the theme than a thin strip of chrome —
/// meters, bezels and scanlines are what retrowave is *made of*.
enum RetroMetrics {
    /// Corners are cut, not rounded. A 45° chamfer is the 80s tech-panel
    /// corner, and it distinguishes this chrome from every rounded-rect
    /// default macOS would otherwise make it look like.
    static let chamfer: CGFloat = 5
    static let chipPaddingH: CGFloat = 10
    static let chipPaddingV: CGFloat = 6
    static let gutter: CGFloat = 10
    static let panelPadding: CGFloat = 10
}

/// A rectangle with its corners cut off at 45°.
struct ChamferedRectangle: Shape {
    var cut: CGFloat = RetroMetrics.chamfer

    func path(in rect: CGRect) -> Path {
        let c = min(cut, min(rect.width, rect.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + c, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - c, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + c))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - c))
        path.addLine(to: CGPoint(x: rect.maxX - c, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + c, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - c))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + c))
        path.closeSubpath()
        return path
    }
}

/// A section label: small, uppercase, letterspaced.
struct RetroSectionLabel: View {
    let text: String
    var accent: Color = RetroUITheme.textSecondary

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(1.4)
            .foregroundStyle(accent)
            .lineLimit(1)
    }
}

/// A bezelled container — the cockpit's basic unit.
struct RetroPanel<Content: View>: View {
    var title: String?
    var accent: Color = RetroUITheme.primaryAccent
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                RetroSectionLabel(text: title, accent: accent.opacity(0.75))
            }
            content
        }
        .padding(RetroMetrics.panelPadding)
        .background(
            ChamferedRectangle()
                .fill(RetroUITheme.panel.opacity(0.55))
                .overlay(Scanlines().clipShape(ChamferedRectangle()))
        )
        .overlay(
            ChamferedRectangle()
                .stroke(accent.opacity(0.35), lineWidth: 1)
        )
    }
}

/// Faint horizontal lines, the way a CRT has them.
///
/// The map already runs through `RetroShader`, which scanlines the whole
/// scene; the chrome around it did not, so the panels read as flat modern
/// surfaces bolted onto a city that visibly lives on a cathode-ray tube.
/// Deliberately very low contrast — at any strength you actually notice, it
/// stops being texture and starts being stripes.
struct Scanlines: View {
    var spacing: CGFloat = 3
    var opacity: Double = 0.16

    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            while y < size.height {
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                    with: .color(.black.opacity(opacity))
                )
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

/// A tool button, including the states a tool button actually has.
///
/// **The locked state earns its own treatment.** `Unlocks` gates most of the
/// toolbar behind a population high-water mark, and the old toolbar expressed
/// that as `.disabled` plus 35% opacity — which reads as "broken", not as
/// "not yet". A locked chip shows the gate instead, which turns a dead button
/// into the thing it was always meant to be: something to aim at.
struct RetroToolChip: View {
    let title: String
    var cost: Int?
    var accent: Color
    var isSelected: Bool = false
    /// What the player still needs, when the tool is not yet available.
    var lockedBy: String?
    let action: () -> Void

    private var isLocked: Bool { lockedBy != nil }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if isLocked {
                        Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold))
                    }
                    Text(title).lineLimit(1)
                }
                if let detail = lockedBy ?? cost.map({ "$\($0)" }) {
                    Text(detail)
                        .font(.system(size: 9, weight: .medium))
                        .opacity(0.8)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(RetroButtonStyle(accent: isLocked ? RetroUITheme.textSecondary : accent,
                                      isSelected: isSelected))
        .disabled(isLocked)
        .help(lockedBy.map { "\(title) — \($0)" } ?? title)
    }
}

/// A segmented load bar.
///
/// **A fraction is a number; a meter is a status.** Utility load was drawn as
/// `Water: 0/0`, which is the one mechanic where "how close am I to the
/// ceiling" is the entire question — capacity is what makes growth create new
/// demands rather than being finished the moment it is first connected. A bar
/// that fills and turns red answers that at a glance; a fraction makes you do
/// arithmetic every tick.
struct RetroMeter: View {
    let label: String
    /// 0 is empty, 1 is at capacity, above 1 is overloaded.
    let fill: Double
    var detail: String
    var accent: Color = RetroUITheme.primaryAccent
    var segments: Int = 10

    private var isOverloaded: Bool { fill > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                RetroSectionLabel(text: label)
                Spacer(minLength: 4)
                Text(detail)
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isOverloaded ? Color.red : RetroUITheme.textPrimary)
                    .lineLimit(1)
            }
            HStack(spacing: 2) {
                ForEach(0 ..< segments, id: \.self) { index in
                    let threshold = Double(index + 1) / Double(segments)
                    let lit = fill >= threshold - 0.0001
                    Rectangle()
                        .fill(lit ? (isOverloaded ? Color.red : accent) : accent.opacity(0.14))
                        .frame(height: 5)
                        .shadow(color: lit ? (isOverloaded ? .red : accent).opacity(0.8) : .clear, radius: 2)
                }
            }
        }
    }
}

/// A small status chip — an alert, or a goal.
struct RetroBadge: View {
    let text: String
    var accent: Color = RetroUITheme.primaryAccent
    var isUrgent: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(isUrgent ? Color.black : accent)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(ChamferedRectangle(cut: 3).fill(isUrgent ? accent : accent.opacity(0.14)))
            .overlay(ChamferedRectangle(cut: 3).stroke(accent.opacity(isUrgent ? 1 : 0.5), lineWidth: 1))
            .shadow(color: accent.opacity(isUrgent ? 0.7 : 0), radius: 4)
    }
}

/// A readout: a label, a number, and where it has been.
struct RetroStatTile: View {
    let label: String
    let value: String
    /// A second, quieter line — a rate, a delta, a unit.
    ///
    /// Not part of `value`: the treasury readout was "$1,482,910 +$1,798/tick"
    /// as one string, and since these numbers grow without bound and the line
    /// must not wrap (see below), it simply truncated to "$1,482,910 +$…" and
    /// silently lost the rate — which is the half a player actually steers by.
    var detail: String?
    var history: [Int] = []
    var accent: Color = RetroUITheme.primaryAccent

    /// Wide enough for the label and the number it carries.
    ///
    /// Without a floor these compress before anything else in the dashboard
    /// does, and because the label and value must not wrap (see below) they
    /// truncate instead — "POPULA…", "$1,48…". A readout that hides its own
    /// number is worse than no readout, so the tile keeps its width and the
    /// row gives up its slack elsewhere.
    var minimumWidth: CGFloat = 104

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            RetroSectionLabel(text: label)
            // `.lineLimit(1)` is load-bearing, and a live playtest is what
            // found it. These numbers grow — treasury reaches seven digits
            // over a long session — and without a limit SwiftUI wraps rather
            // than truncates, which changes this row's height, which changes
            // the SpriteKit view's height, which fires
            // `GameScene.didChangeSize`, which recentres the camera. Every
            // tick the number crossed the wrap threshold, the *whole map*
            // jumped — reading as "the city is shifting", not as a layout bug.
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(RetroUITheme.textPrimary)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(accent.opacity(0.9))
                    .lineLimit(1)
            }
            if !history.isEmpty {
                Sparkline(values: history, color: accent)
                    .frame(height: 14)
            }
        }
        .frame(minWidth: minimumWidth, alignment: .leading)
    }
}
