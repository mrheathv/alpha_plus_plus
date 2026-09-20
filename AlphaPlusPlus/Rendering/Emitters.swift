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
