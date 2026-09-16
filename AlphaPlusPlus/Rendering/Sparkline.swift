import SwiftUI

/// A minimal trend line for one stat over recent history — just enough to
/// answer "is this going up, down, or flat?" at a glance, not a full chart
/// (no axes, no labels; `GameController.history` already caps how far back
/// it remembers). Used in `GameView`'s toolbar next to Population/Jobs/
/// Treasury so those numbers show their recent direction, not just their
/// current value.
struct Sparkline: View {
    let values: [Int]
    var color: Color = .accentColor

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let minValue = values.min() ?? 0
            let maxValue = values.max() ?? 0
            // A flat history (including all-zero, e.g. before anything has
            // grown yet) would divide by zero below — draw a flat middle
            // line instead of doing nothing, so an idle sparkline still
            // reads as "nothing's happening" rather than looking broken.
            guard maxValue > minValue else {
                var flat = Path()
                flat.move(to: CGPoint(x: 0, y: size.height / 2))
                flat.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(flat, with: .color(color.opacity(0.4)), lineWidth: 1.5)
                return
            }

            let range = Double(maxValue - minValue)
            let points = values.enumerated().map { index, value -> CGPoint in
                let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
                let normalized = Double(value - minValue) / range
                let y = size.height * (1 - CGFloat(normalized))
                return CGPoint(x: x, y: y)
            }

            var path = Path()
            path.addLines(points)
            // Two passes: a wide faint one that reads as bloom, then the crisp
            // line over it. The same "a stroke over a blurred copy of itself"
            // that makes every building on the map read as neon rather than as
            // a coloured outline — a single hairline was the one graph in the
            // cockpit that did not glow.
            context.stroke(path, with: .color(color.opacity(0.35)),
                           style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}
