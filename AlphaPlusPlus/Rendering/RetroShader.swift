import SpriteKit

/// The one Metal-backed effect in this project — a full-scene retro
/// post-process (scanlines, a vignette, a touch of chromatic aberration)
/// applied over the whole rendered map, not to any individual tile or
/// icon. This is the kind of thing CLAUDE.md's "Metal shaders... not
/// until mechanics are solid" note was reserving room for: everything
/// else in `Rendering/` draws individual nodes (colored rects, shape
/// strokes, blurred duplicates for a glow); none of that can re-tint an
/// already-composited frame. An `SKShader` can — SpriteKit compiles and
/// runs it on the GPU via Metal — which is exactly the kind of effect
/// plain node drawing can't reach.
///
/// `SKShader` source is just the body of a fragment shader; SpriteKit
/// supplies `u_texture` (what's being shaded) and `v_tex_coord` (that
/// texture's 0...1 coordinate) automatically. Everything else the shader
/// reads (`u_scanlineCount`, `u_scanlineStrength`, `u_vignetteStrength`,
/// `u_aberrationStrength`, `u_aspect`) is a custom `SKUniform` this file
/// defines and sets from Swift — the shader-parameter equivalent of a
/// tunable constant, with `u_aspect` the one that has to be *kept*
/// current (see `updateAspect`) rather than just set once.
enum RetroShader {

    /// Attach the returned shader to an `SKEffectNode`, not a plain
    /// `SKSpriteNode` — an effect node renders everything *underneath* it
    /// into one offscreen texture first, which is exactly what this
    /// shader needs to operate on: the whole composited map, not one
    /// sprite's own fill.
    static func make() -> SKShader {
        let shader = SKShader(source: source)
        shader.uniforms = [
            SKUniform(name: "u_scanlineCount", float: 240),
            SKUniform(name: "u_scanlineStrength", float: 0.22),
            SKUniform(name: "u_vignetteStrength", float: 0.35),
            SKUniform(name: "u_aberrationStrength", float: 0.2),
            SKUniform(name: "u_aspect", float: 1),
        ]
        return shader
    }

    /// Keeps the vignette and chromatic-aberration math circular rather
    /// than stretched to whatever the window's own aspect ratio happens
    /// to be. `GameScene` calls this once at setup and again from
    /// `didChangeSize` — a plain `u_sprite_size`-style built-in isn't
    /// guaranteed for an `SKEffectNode` the way it is for a sprite, so
    /// this file tracks the aspect ratio itself instead of assuming one.
    static func updateAspect(_ shader: SKShader, size: CGSize) {
        guard size.height > 0 else { return }
        shader.uniforms.first(where: { $0.name == "u_aspect" })?.floatValue = Float(size.width / size.height)
    }

    private static let source = """
    void main() {
        vec2 uv = v_tex_coord;

        vec2 centered = uv - vec2(0.5);
        centered.x *= u_aspect;
        float distanceFromCenter = length(centered);

        // Chromatic aberration: sample red and blue slightly offset away
        // from center, growing with distance -- a VHS-tape color fringe
        // toward the edges of frame, neutral and sharp in the middle.
        vec2 direction = distanceFromCenter > 0.0001 ? normalize(centered) : vec2(0.0);
        vec2 offset = vec2(direction.x / max(u_aspect, 0.0001), direction.y) * 0.004 * distanceFromCenter;
        float redSample = texture2D(u_texture, uv + offset).r;
        float blueSample = texture2D(u_texture, uv - offset).b;

        vec4 color = texture2D(u_texture, uv);
        color.r = mix(color.r, redSample, u_aberrationStrength);
        color.b = mix(color.b, blueSample, u_aberrationStrength);

        // Scanlines: a faint, repeating horizontal darkening band -- the
        // classic CRT/VHS texture sitting behind every synthwave still
        // frame, not just its color palette.
        float scan = sin(uv.y * u_scanlineCount * 3.14159265);
        color.rgb *= 1.0 - u_scanlineStrength * (0.5 + 0.5 * scan) * 0.5;

        // Vignette: darken the corners so the neon glow at screen center
        // reads as the brightest thing in frame, not the edges of it.
        float vignette = smoothstep(0.9, 0.25, distanceFromCenter);
        color.rgb *= mix(1.0 - u_vignetteStrength, 1.0, vignette);

        gl_FragColor = color;
    }
    """
}
