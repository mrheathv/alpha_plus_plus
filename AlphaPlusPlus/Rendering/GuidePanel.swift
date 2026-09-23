import SwiftUI

/// **The guide, as one card at a time.**
///
/// One step, one sentence of why, one button that does it. Deliberately not a
/// checklist of all ten: a list of everything left to learn is a syllabus, and
/// a syllabus on screen over a new player's first city is exactly the
/// dashboard noise this chrome keeps trying to get away from. The pips say how
/// far along you are without saying what is coming.
///
/// Floats over the map's bottom-left, which an isometric diamond leaves
/// emptiest, and which the inspector (top-right) and the route editor
/// (top-left) do not use. It carries the inspector's opaque ground for the
/// inspector's reason: it sits over a lit city, and 11-point text over neon
/// at 55% opacity is not text anybody can read.
struct GuidePanel: View {
    let guide: FirstCityGuide
    /// `nil` when the step's shortcut can be taken now; otherwise why not —
    /// in practice the fire station, which the guide asks for before a new
    /// city has usually earned it.
    let lockedReason: String?
    let onShortcut: (FirstCityGuide.Shortcut) -> Void
    let onDismiss: () -> Void

    private let accent = RetroUITheme.primaryAccent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RetroSectionLabel(text: GuideText.progress(guide.completedCount), accent: accent.opacity(0.8))
                Spacer(minLength: 8)
                if !guide.isFinished {
                    Button("Skip guide", action: onDismiss)
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(RetroUITheme.textSecondary)
                }
            }
            pips
            if let step = guide.current {
                Text(GuideText.title(for: step))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(RetroUITheme.textPrimary)
                Text(GuideText.body(for: step))
                    .font(.system(size: 11))
                    .foregroundStyle(RetroUITheme.textPrimary.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                if let shortcut = step.shortcut {
                    shortcutRow(shortcut)
                }
            } else {
                Text(GuideText.finishedTitle)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(RetroUITheme.textPrimary)
                Text(GuideText.finishedBody)
                    .font(.system(size: 11))
                    .foregroundStyle(RetroUITheme.textPrimary.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Done", action: onDismiss)
                    .buttonStyle(RetroButtonStyle(accent: accent, isSelected: true))
                    .padding(.top, 2)
            }
        }
        .padding(RetroMetrics.panelPadding + 2)
        .frame(width: 280, alignment: .leading)
        .background(
            ChamferedRectangle()
                .fill(RetroUITheme.background.opacity(0.93))
                .shadow(color: .black.opacity(0.6), radius: 10)
        )
        .overlay(ChamferedRectangle().stroke(accent.opacity(0.45), lineWidth: 1))
    }

    /// One square per step: lit once done, outlined for the current one.
    ///
    /// Squares rather than dots, for the same reason `DemandBar` stopped
    /// drawing rounded segments — everything else in this cockpit is square.
    private var pips: some View {
        HStack(spacing: 4) {
            ForEach(FirstCityGuide.Step.allCases, id: \.self) { step in
                let done = guide.completed.contains(step)
                Rectangle()
                    .fill(done ? accent : Color.clear)
                    .frame(width: 14, height: 4)
                    .overlay(Rectangle().stroke(
                        step == guide.current ? accent : accent.opacity(done ? 0 : 0.3),
                        lineWidth: 1
                    ))
                    .shadow(color: done ? accent.opacity(0.7) : .clear, radius: 3)
            }
        }
    }

    private func shortcutRow(_ shortcut: FirstCityGuide.Shortcut) -> some View {
        HStack(spacing: 10) {
            Button(GuideText.action(for: shortcut)) { onShortcut(shortcut) }
                .buttonStyle(RetroButtonStyle(accent: accent, isSelected: true))
                .disabled(lockedReason != nil)
            if let lockedReason {
                Text(lockedReason)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(RetroUITheme.textSecondary)
            }
        }
        .padding(.top, 2)
    }
}
