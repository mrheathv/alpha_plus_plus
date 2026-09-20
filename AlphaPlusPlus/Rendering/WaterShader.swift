import SpriteKit

/// **Water that moves.**
///
/// Terrain landed with water as a flat fill — correct, legible, and
/// completely still, which on a map where the streets pulse and the traffic
/// runs makes a river read as painted floor rather than as water.
///
/// This is the second thing in the project the GPU actually does, and unlike
/// `RetroShader` it runs **per tile rather than over the finished frame**.
/// That distinction is the whole design problem: a fragment shader on a
/// sprite only knows its own texture and its own `v_tex_coord`, which runs
/// 0…1 across *every* water tile identically — so a wave written in local
/// coordinates would restart at every tile edge and the river would look
/// quilted.
///
/// `SKAttribute` is the way out. Each water sprite carries its own tile
/// position, the shader adds it to the local coordinate, and the waves are
/// computed in **map space**: one continuous surface across however many
/// tiles it happens to be cut into.
///
/// **One shader instance, shared by every water tile.** An `SKShader` is the
/// batching unit here, so a per-tile instance would be a draw call per tile
/// — the exact cost `IsoTextureCache` exists to avoid. The per-tile part is
/// the attribute, which is what attributes are for.
///
/// **Not reflections, and worth saying why.** The obvious retrowave move is
/// the city mirrored in the water, and it is not reachable from here: a tile
/// shader can see its own texture and nothing else, so a reflection needs the
/// scene rendered to a texture first. That is a second render target, which
/// in SpriteKit means nesting effect nodes — something this project already
/// knows silently stops being serviced past a budget. It belongs with the
/// light-accumulation work, not here.
enum WaterShader {

    /// The attribute each water sprite sets to its own tile coordinate.
    static let tileAttribute = "a_tile"

    static func make() -> SKShader {
        let shader = SKShader(source: source)
        shader.attributes = [SKAttribute(name: tileAttribute, type: .vectorFloat2)]
        shader.uniforms = [
            SKUniform(name: "u_shimmer", float: 0.55),
            SKUniform(name: "u_speed", float: 0.55),
        ]
        return shader
    }

    /// Pushes the current style's settings in — `classic` keeps the still
    /// water terrain shipped with, so the switch answers this too.
    static func applyStyle(_ shader: SKShader) {
        shader.uniforms.first { $0.name == "u_shimmer" }?
            .floatValue = Float(VisualStyle.current.waterShimmer)
    }

    private static let source = """
    void main() {
        vec4 base = texture2D(u_texture, v_tex_coord);

        // **Map space, not tile space.** `v_tex_coord` runs 0…1 across every
        // tile alike, so a wave written in it restarts at each tile edge and
        // the river comes out quilted. The attribute is this tile's own
        // position, which stitches the surface back into one piece.
        vec2 world = a_tile + v_tex_coord;

        // Two crossing waves of different wavelength and opposite drift.
        // One alone is a corrugated sheet — the interference between two is
        // what stops the pattern repeating anywhere the eye can catch it,
        // the same reason `RegionalEconomy` sums two sines rather than
        // running one.
        float t = u_time * u_speed;
        float wave = sin(world.x * 5.3 + t)
                   + sin((world.x + world.y * 1.7) * 3.1 - t * 0.77);

        // Only the crests light. A smooth remap would brighten the whole
        // surface and just make the water paler; what reads as water is a
        // few moving highlights on something otherwise dark.
        float crest = smoothstep(0.75, 1.65, wave);

        // Multiplied by the source alpha so the shimmer stays inside the
        // tile's diamond instead of spilling into the square around it.
        base.rgb += crest * u_shimmer * vec3(0.10, 0.33, 0.62) * base.a;
        gl_FragColor = base;
    }
    """
}
