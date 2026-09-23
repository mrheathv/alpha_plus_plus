import SwiftUI

/// **The first thing anybody sees.**
///
/// The app booted straight into a city, which is what a prototype does. A
/// game opens on something that tells you what it is — and for the App Store
/// it is also the one screen that has to survive being a thumbnail.
///
/// **Drawn rather than photographed.** The obvious move is to put a live
/// `GameScene` behind the title, and it was tempting: the game already
/// renders a city and it looks good. But a title screen has to be *composed*
/// — a horizon at a chosen height, a sun in a chosen place — and a real city
/// is an isometric diamond that sits wherever the map is. This is the one
/// picture in the project that gets to be a poster instead of a simulation,
/// so it is a `Canvas`: a synthwave sun over a receding grid, which is the
/// image the whole art direction has been quoting from since the beginning.
///
/// It reuses `NeonStyle`'s actual colours rather than picking new ones, so
/// the title and the game are unmistakably the same thing.
struct TitleScreen: View {
    @ObservedObject var document: CityDocument
    let start: () -> Void

    var body: some View {
        ZStack {
            backdrop
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RetroUITheme.background)
        // **The sheet has to be attached here too.** `GameView` presents it
        // for the cockpit's button, and the title screen is a different view
        // entirely — so without this the button sets a flag nobody reads and
        // is exactly the dead control this project keeps writing down.
        .sheet(isPresented: Binding(
            get: { document.controller.isShowingSettingsPanel },
            set: { document.controller.isShowingSettingsPanel = $0 }
        )) {
            SettingsPanel(controller: document.controller) {
                document.controller.isShowingSettingsPanel = false
            }
        }
    }

    // MARK: - The poster

    private var backdrop: some View {
        Canvas { context, size in
            Self.drawSky(&context, size)
            Self.drawSun(&context, size)
            Self.drawGrid(&context, size)
        }
        .ignoresSafeArea()
    }

    /// Indigo overhead to magenta at the horizon — the gradient every
    /// reference image this project has pulled from opens with.
    private static func drawSky(_ context: inout GraphicsContext, _ size: CGSize) {
        let horizon = size.height * Self.horizonFraction
        context.fill(
            Path(CGRect(origin: .zero, size: CGSize(width: size.width, height: horizon))),
            with: .linearGradient(
                Gradient(colors: [
                    Color(nsColor: RenderPalette.background),
                    Color(red: 0.16, green: 0.04, blue: 0.30),
                    Color(red: 0.55, green: 0.08, blue: 0.42),
                ]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: horizon)
            )
        )
    }

    /// The sun: a disc cut by slats that widen toward the bottom.
    ///
    /// The right way up, here. `NeonStyle.sunsetFlameTexture` runs the same
    /// motif *upside down* for fire, where the gaps widen toward the top
    /// because that is what a flame does as it breaks apart. Same idea, two
    /// readings — which is the sort of thing that makes a look feel authored
    /// rather than assembled.
    private static func drawSun(_ context: inout GraphicsContext, _ size: CGSize) {
        let horizon = size.height * Self.horizonFraction
        let radius = min(size.width * 0.17, horizon * 0.58)
        let centre = CGPoint(x: size.width / 2, y: horizon - radius * 0.34)
        let bounds = CGRect(x: centre.x - radius, y: centre.y - radius,
                            width: radius * 2, height: radius * 2)

        // **The slats are cut out of the path, not blended over it.** The
        // first version punched them with a `.destinationOut` pass inside a
        // `drawLayer`, which silently did nothing at all — the render came
        // back a solid gradient blob, which is a sunset from any decade.
        // Subtracting them from the disc is one call and cannot fail quietly.
        var slats = Path()
        var y = centre.y + radius * 0.02
        var thickness = radius * 0.035
        while y < centre.y + radius {
            slats.addRect(CGRect(x: bounds.minX, y: y, width: bounds.width, height: thickness))
            y += thickness + radius * 0.115
            thickness *= 1.55
        }
        let disc = Path(ellipseIn: bounds).subtracting(slats)

        let sunset = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [
                Color(red: 1.0, green: 0.93, blue: 0.52),
                Color(red: 1.0, green: 0.55, blue: 0.24),
                Color(red: 1.0, green: 0.16, blue: 0.56),
            ]),
            startPoint: CGPoint(x: 0, y: bounds.minY),
            endPoint: CGPoint(x: 0, y: bounds.maxY)
        )

        // The bloom goes *behind* as its own soft copy rather than as a blur
        // on the disc itself — blurring the disc is what turned it to haze,
        // and it took the slats with it. Same split the buildings already
        // use: a crisp shape over a blurred copy of itself.
        context.drawLayer { halo in
            halo.addFilter(.blur(radius: radius * 0.34))
            halo.opacity = 0.75
            halo.fill(Path(ellipseIn: bounds.insetBy(dx: radius * 0.1, dy: radius * 0.1)),
                      with: sunset)
        }
        context.fill(disc, with: sunset)
    }

    /// The ground: a grid running to a vanishing point, with the spacing
    /// closing up toward the horizon so it reads as distance rather than as
    /// a fan of lines.
    private static func drawGrid(_ context: inout GraphicsContext, _ size: CGSize) {
        let horizon = size.height * Self.horizonFraction
        let vanishing = CGPoint(x: size.width / 2, y: horizon)
        let accent = Color(red: 1.0, green: 0.18, blue: 0.69)

        // The ground fades *out* of the horizon rather than starting at it —
        // a flat fill meeting the sky's last gradient stop leaves a hard seam
        // straight across the frame, which the render showed at once.
        context.fill(
            Path(CGRect(x: 0, y: horizon, width: size.width, height: size.height - horizon)),
            with: .linearGradient(
                Gradient(colors: [
                    Color(red: 0.34, green: 0.05, blue: 0.30),
                    Color(nsColor: RenderPalette.background),
                ]),
                startPoint: CGPoint(x: 0, y: horizon),
                endPoint: CGPoint(x: 0, y: horizon + (size.height - horizon) * 0.4)
            )
        )

        var lines = Path()
        for step in -14 ... 14 {
            let spread = CGFloat(step) * size.width * 0.115
            lines.move(to: vanishing)
            lines.addLine(to: CGPoint(x: vanishing.x + spread, y: size.height))
        }
        // Horizontals on a squared progression, which is what perspective
        // does to evenly spaced ground lines.
        for row in 1 ... 13 {
            let t = pow(CGFloat(row) / 13, 2.1)
            let y = horizon + t * (size.height - horizon)
            lines.move(to: CGPoint(x: 0, y: y))
            lines.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(lines, with: .color(accent.opacity(0.55)), lineWidth: 1.2)
    }

    /// Where the horizon sits. High enough that the grid is the larger half,
    /// because the grid is the half that reads as retrowave.
    private static let horizonFraction: CGFloat = 0.52

    // MARK: - The words

    private var content: some View {
        VStack(spacing: 0) {
            Spacer()
            title
            Spacer()
            recoveryNote
            buttons
                .padding(.bottom, 54)
        }
    }

    private var title: some View {
        VStack(spacing: 10) {
            Text("ALPHA++")
                .font(.system(size: 72, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .shadow(color: Color(red: 1.0, green: 0.18, blue: 0.69), radius: 18)
                .shadow(color: Color(red: 0.0, green: 0.90, blue: 1.0), radius: 30)
            Text("BUILD SOMETHING AFTER DARK")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .tracking(6)
                .foregroundStyle(Color(red: 0.0, green: 0.90, blue: 1.0).opacity(0.85))
        }
    }

    private var buttons: some View {
        HStack(spacing: 14) {
            Button("New City") {
                document.controller.rerollTerrainSeed()
                document.controller.isShowingNewCityPanel = true
                start()
            }
            .buttonStyle(RetroButtonStyle(accent: RetroUITheme.primaryAccent))

            Button("Settings…") { document.controller.isShowingSettingsPanel = true }
                .buttonStyle(RetroButtonStyle(accent: RetroUITheme.textSecondary))
            Button("Open City…") {
                document.open()
                start()
            }
            .buttonStyle(RetroButtonStyle(accent: RetroUITheme.secondaryAccent))

            // Only once there is something to go back *to*. On a first launch
            // the map is empty and "Continue" would be a third way of saying
            // "New City".
            //
            // **And on a relaunch, "back to" is the autosave.** Continue used
            // to mean only the city still in memory, which never survives a
            // relaunch — so the one moment a player most wants to pick up
            // where they left off was the one moment it was missing.
            if document.controller.hasACityWorthReturningTo {
                Button("Continue", action: start)
                    .buttonStyle(RetroButtonStyle(accent: RetroUITheme.primaryAccent))
            } else if document.recoverable != nil {
                Button("Continue") { document.resumeAutosave() }
                    .buttonStyle(RetroButtonStyle(accent: RetroUITheme.primaryAccent, isSelected: true))
            }
        }
    }

    /// "3 minutes ago", or "moments ago" for anything under a minute — the
    /// formatter reads a save from a second ago as "in 0 seconds", which the
    /// render caught on its first run.
    static func howLongAgo(_ date: Date, now: Date = Date()) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "moments ago" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
    }

    /// Said once, after a session that did not end cleanly, so a rescued
    /// city is offered as a rescue rather than silently.
    @ViewBuilder private var recoveryNote: some View {
        if document.previousSessionEndedBadly, !document.controller.hasACityWorthReturningTo,
           let saved = document.recoverable {
            Text("Alpha++ closed unexpectedly. Your city was autosaved "
                 + Self.howLongAgo(saved.savedAt) + " — Continue picks it up.")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(red: 1.0, green: 0.75, blue: 0.3))
                .padding(.bottom, 12)
        }
    }
}
