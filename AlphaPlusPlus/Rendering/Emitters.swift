import SpriteKit

/// **The first particles in the project.**
///
/// `SKEmitterNode` appeared nowhere until now — every moving mark was a
/// handful of sprites each running its own `SKAction`. That works, and it is
/// what the fire's four embers were, but it has a hard ceiling: the cost is
/// per *particle*, paid on the CPU in the scene graph, so "a few more sparks"
/// means a few more nodes and a few more action evaluations every frame. An
/// emitter is one node whose particles are simulated and drawn on the GPU, so
/// the honest count goes from four to fifty for less than the four cost.
///
/// **Why the embers were four in the first place**, and why that reasoning
/// changes here: `NeonStyle.minimumDetailSize` says a mark too small to
/// resolve is noise, and four sparks each carrying real weight beat a cloud
/// of specks averaging into haze. That is still true of *static* marks. A
/// rising spark is not static — it is legible by its motion rather than its
/// size, which is exactly the property a still frame cannot show and the
/// reason this had to be judged in the running app.
enum Emitters {

    /// Embers off a burning block.
    ///
    /// Additive, like every other lit thing in this game, and coloured from
    /// the same sunset the plume is drawn in rather than a new orange.
    static func embers(scale: CGFloat) -> SKEmitterNode {
        let node = SKEmitterNode()
        node.particleTexture = NeonStyle.glowTexture
        node.particleBlendMode = .add
        node.particleBirthRate = 26
        node.particleLifetime = 1.5
        node.particleLifetimeRange = 0.8

        // Up, with a spread — a fire throws sparks, it does not fountain them
        // in a column.
        node.emissionAngle = .pi / 2
        node.emissionAngleRange = .pi / 3
        node.particleSpeed = scale * 0.9
        node.particleSpeedRange = scale * 0.5
        // A gentle drift rather than real gravity: these are embers on a
        // thermal, not debris falling.
        node.yAcceleration = scale * 0.25

        node.particleSize = CGSize(width: scale * 0.14, height: scale * 0.14)
        node.particleScaleRange = 0.5
        node.particleScaleSpeed = -0.35

        node.particleAlpha = 0.9
        node.particleAlphaSpeed = -0.75
        node.particleColorBlendFactor = 1
        node.particleColorSequence = nil
        // Magenta at the top of the sunset ramp through to the ember orange
        // at its middle — the two ends the plume already runs between, so a
        // spark reads as having come off *that* fire.
        node.particleColor = NeonStyle.emberColor
        node.particleColorBlendFactorSequence = nil
        return node
    }

    /// The plume off a working factory.
    ///
    /// **Industry is the one zone that should look like it is doing
    /// something**, and until now a factory at density 5 differed from one at
    /// density 1 only in size and how hard it glowed. Smoke is the first mark
    /// in the game that says a building is *running* rather than merely
    /// standing there.
    ///
    /// Deliberately dark and slow: this is soot against a night sky, not a
    /// special effect. It is also the one particle here that is **not**
    /// additive — smoke occludes, and adding it would make a chimney look
    /// like it was firing a beam.
    static func smoke(scale: CGFloat, density: Int) -> SKEmitterNode {
        let node = SKEmitterNode()
        node.particleTexture = NeonStyle.glowTexture
        node.particleBlendMode = .alpha
        // Scaled by how hard the factory is working, which is the whole
        // point: a busy industrial district should visibly be one.
        node.particleBirthRate = 2 + CGFloat(density) * 1.6
        node.particleLifetime = 3.4
        node.particleLifetimeRange = 1.4

        node.emissionAngle = .pi / 2
        node.emissionAngleRange = .pi / 7
        node.particleSpeed = scale * 0.45
        node.particleSpeedRange = scale * 0.2
        node.xAcceleration = scale * 0.12   // a prevailing wind, so plumes lean together

        node.particleSize = CGSize(width: scale * 0.38, height: scale * 0.38)
        node.particleScaleRange = 0.4
        node.particleScaleSpeed = 0.5       // spreading as it rises, like smoke

        // Subtle, but not *invisible* — the first pass at 0.20 read as a
        // smudge at the zoom the game is played at, which is the only zoom
        // that counts. Soot against a night sky is still something you can
        // see.
        node.particleAlpha = 0.30
        node.particleAlphaSpeed = -0.09
        node.particleColorBlendFactor = 1
        node.particleColor = RenderPalette.smoke
        return node
    }
}

extension Emitters {

    /// Rain, as a sheet in front of the camera.
    ///
    /// **Parented to the camera rather than to the map**, which is the whole
    /// reason this is affordable: weather covers the *view*, so one emitter
    /// sized to the viewport does the entire city at any zoom, where one per
    /// tile would be thousands of nodes to draw the same thing.
    ///
    /// It falls very slightly off vertical. Dead-straight rain reads as
    /// static — a drawn texture rather than weather — and the same prevailing
    /// lean that makes a row of factory chimneys read as one district under
    /// one wind does the same job here.
    ///
    /// Thin, bright, short-lived streaks rather than droplets: at the zoom
    /// this game is played at a round drop is a single pixel of noise, and
    /// `minimumDetailSize`'s argument applies to a particle exactly as it does
    /// to a window. What reads as rain is the *streak*.
    static func rain(size: CGSize, intensity: CGFloat) -> SKEmitterNode {
        let emitter = SKEmitterNode()
        emitter.particleTexture = streak
        emitter.particleBirthRate = 1_600 * intensity
        emitter.particleLifetime = 1.1
        emitter.particleLifetimeRange = 0.3

        // Born along a line above the view, falling across it.
        emitter.particlePositionRange = CGVector(dx: size.width * 1.4, dy: 0)
        emitter.position = CGPoint(x: 0, y: size.height * 0.75)
        emitter.particleSpeed = size.height * 1.5
        emitter.particleSpeedRange = size.height * 0.25
        emitter.emissionAngle = -.pi / 2 + 0.16
        emitter.emissionAngleRange = 0.02

        emitter.particleAlpha = 0.5 * intensity
        emitter.particleAlphaRange = 0.12
        emitter.particleScale = 1.5
        emitter.particleScaleRange = 0.5
        // Cool and pale rather than white: it is lit by the city under it,
        // and the city is magenta and cyan.
        emitter.particleColor = SKColor(srgbRed: 0.74, green: 0.86, blue: 1.0, alpha: 1)
        emitter.particleColorBlendFactor = 1
        emitter.particleBlendMode = .add

        // **Deliberately not advanced here.** Pre-rolling the simulation only
        // works once the emitter is in the scene graph with its `targetNode`
        // set — particles are emitted into that node's space, and advancing
        // before either exists produces a handful of drops in the wrong
        // coordinate system. The caller does it after adding. The first render
        // of this came back with about ten visible streaks for a birth rate
        // that should have put well over a thousand on screen.
        return emitter
    }

    /// One raindrop: a soft vertical streak, drawn once and reused by every
    /// particle.
    private static let streak: SKTexture = {
        let size = CGSize(width: 2, height: 22)
        let renderer = NSImage(size: size, flipped: false) { rect in
            let gradient = NSGradient(colors: [
                NSColor(white: 1, alpha: 0),
                NSColor(white: 1, alpha: 1),
                NSColor(white: 1, alpha: 0),
            ])
            gradient?.draw(in: NSBezierPath(rect: rect), angle: 90)
            return true
        }
        return SKTexture(image: renderer)
    }()
}
