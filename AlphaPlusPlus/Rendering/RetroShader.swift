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
            SKUniform(name: "u_bloomStrength", float: 0),
            SKUniform(name: "u_bloomThreshold", float: 0.62),
            SKUniform(name: "u_bloomRadius", float: 0.012),
            SKUniform(name: "u_grainStrength", float: 0),
            SKUniform(name: "u_liftShadows", float: 0),
        ]
        applyStyle(shader)
        return shader
    }

    /// Pushes the current `VisualStyle`'s bloom settings into `shader`.
    ///
    /// Read from the style rather than fixed here so the Classic/Cinematic
    /// toggle can turn bloom *off* — which is the only way to answer whether
    /// it is an improvement, and the same argument that switch was built on.
    static func applyStyle(_ shader: SKShader) {
        let style = VisualStyle.current
        shader.uniforms.first { $0.name == "u_bloomStrength" }?
            .floatValue = Float(style.bloomStrength)
        shader.uniforms.first { $0.name == "u_bloomThreshold" }?
            .floatValue = Float(style.bloomThreshold)
        shader.uniforms.first { $0.name == "u_grainStrength" }?
            .floatValue = Float(style.grainStrength)
        shader.uniforms.first { $0.name == "u_liftShadows" }?
            .floatValue = Float(style.liftShadows)
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

        // **Bloom, and the one place this game's light is not faked.**
        //
        // Every glow on the map until now was *baked*: a blurred copy of each
        // building rasterised into its texture once, which is why it costs
        // nothing per tile and why it can never respond to anything. Two
        // towers side by side do not brighten where they overlap, because
        // each one's halo was drawn before the other existed.
        //
        // This does it in the frame instead. A bright-pass keeps only what is
        // already near white, and a ring of taps around each pixel sums what
        // it finds, so overlapping neon genuinely adds up and a dense
        // district blazes the way a dense district should.
        //
        // **Sixteen taps on a golden-angle spiral, not a grid.** A regular
        // ring at this tap count bands visibly — you can count the samples in
        // a wide glow. Rotating each tap by the golden angle and growing the
        // radius with its index scatters them evenly at every scale, which is
        // what buys a smooth falloff out of sixteen reads instead of the
        // several hundred a separable two-pass blur would want. A second pass
        // is not available here: `SKShader` is one fragment function over one
        // texture, and adding render targets means nesting effect nodes,
        // which this project already knows silently stops servicing past a
        // budget.
        if (u_bloomStrength > 0.0) {
            vec3 bloom = vec3(0.0);
            float angle = 2.39996323;  // golden angle, radians
            // **The spiral is rotated per pixel, and it has to be.**
            //
            // Without this every pixel in the frame samples the same sixteen
            // directions, so a bright source is not blurred — it is *copied*,
            // sixteen times, to sixteen fixed offsets. With a source a few
            // pixels across those copies overlap into something that passes
            // for a halo, which is why this looked right when it was built
            // and reviewed on a whole-city frame.
            //
            // Zoom in and it falls apart: a lit window is forty pixels across
            // at the closest camera, so each copy is a plainly readable
            // forty-pixel rectangle landing on whatever stands next door.
            // Reported from play as buildings looking *translucent* when they
            // crowd together — which is exactly what a ghost of the window
            // behind, printed across the wall in front, looks like.
            //
            // A per-pixel rotation turns those sixteen copies into sixteen
            // *different* offsets per pixel, which is noise rather than
            // structure — and this frame already ends in grain, so noise is
            // the one artefact it can absorb. The hash is the standard
            // sin-dot-fract one: cheap, and its quality does not matter when
            // all it has to do is decorrelate neighbours.
            float jitter = fract(sin(dot(uv, vec2(12.9898, 78.233))) * 43758.5453);
            float spin = jitter * 6.28318531;
            // **The rotation is applied with an angle-addition identity, not
            // by rotating inside the loop**, and the difference is a third of
            // the frame.
            //
            // `cos(angle * float(i))` is a *loop constant* — the compiler
            // unrolls sixteen iterations and folds all thirty-two sines and
            // cosines away to literals. Writing `cos(angle * float(i) + spin)`
            // quietly un-folds every one of them, because `spin` varies per
            // pixel: thirty-two transcendentals per pixel over the whole
            // frame, which measured as the post-process going from about 12 ms
            // to 34 at 64×64.
            //
            // Rotating the *result* costs two. The constants survive folding,
            // `cos(spin)`/`sin(spin)` are computed once, and the output is
            // identical arithmetic.
            float cosSpin = cos(spin), sinSpin = sin(spin);
            for (int i = 0; i < 16; i++) {
                float t = (float(i) + 0.5) / 16.0;
                float r = u_bloomRadius * sqrt(t);
                float ca = cos(angle * float(i)), sa = sin(angle * float(i));
                vec2 tap = vec2(ca * cosSpin - sa * sinSpin,
                                sa * cosSpin + ca * sinSpin) * r;
                tap.x /= max(u_aspect, 0.0001);
                vec3 sampled = texture2D(u_texture, uv + tap).rgb;
                // Keep only what is already bright. Without the bright-pass
                // this is a blur, and a blurred city is a smeared city.
                float luma = dot(sampled, vec3(0.2126, 0.7152, 0.0722));
                bloom += sampled * smoothstep(u_bloomThreshold, 1.0, luma);
            }
            color.rgb += bloom / 16.0 * u_bloomStrength;
        }

        // Scanlines: a faint, repeating horizontal darkening band -- the
        // classic CRT/VHS texture sitting behind every synthwave still
        // frame, not just its color palette.
        float scan = sin(uv.y * u_scanlineCount * 3.14159265);
        color.rgb *= 1.0 - u_scanlineStrength * (0.5 + 0.5 * scan) * 0.5;

        // Vignette: darken the corners so the neon glow at screen center
        // reads as the brightest thing in frame, not the edges of it.
        float vignette = smoothstep(0.9, 0.25, distanceFromCenter);
        color.rgb *= mix(1.0 - u_vignetteStrength, 1.0, vignette);

        // **A lifted, tinted shadow — the one grade this palette wants.**
        //
        // Every dark pixel in this game sits at almost exactly the same
        // near-black, because that is what the ground/light split decided
        // years of commits ago. That is right for contrast and slightly wrong
        // for *film*: a photographed night is never truly black, it is a
        // shade of whatever is lighting the sky. Lifting the shadows toward
        // the sunset's magenta costs one mix and is most of what separates
        // "dark screen" from "shot at night".
        //
        // Applied after the vignette so the corners lift too — otherwise the
        // grade would fight exactly the part of the frame it most helps.
        float shadow = 1.0 - smoothstep(0.0, 0.35, dot(color.rgb, vec3(0.2126, 0.7152, 0.0722)));
        color.rgb = mix(color.rgb, color.rgb + vec3(0.09, 0.02, 0.13), shadow * u_liftShadows);

        // **Grain, and it goes last on purpose.** It is the top layer of a
        // photographic frame — emulsion, or a sensor's noise floor — so
        // anything applied after it would be grading the grain rather than
        // the picture.
        //
        // Static rather than animated: this project has no per-frame uniform
        // to drive it from here, and a *still* grain reads as film stock
        // where a crawling one reads as video noise. The hash is the usual
        // sin-fract trick, which is cheap and has no visible pattern at this
        // amplitude.
        if (u_grainStrength > 0.0) {
            float grain = fract(sin(dot(uv, vec2(12.9898, 78.233))) * 43758.5453);
            // Weighted toward the shadows, where film grain actually lives —
            // uniform noise over a bright neon sign just looks like dirt.
            color.rgb += (grain - 0.5) * u_grainStrength * (0.4 + 0.6 * shadow);
        }

        gl_FragColor = color;
    }
    """
}
