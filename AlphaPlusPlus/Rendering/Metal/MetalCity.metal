// The city renderer's shaders — see `MetalCityRenderer`. Compiled with the
// app now that the Metal toolchain is installed, so a mistake here fails the
// build rather than failing silently at launch.
//
// Four stages: the scene (drawn twice, once mirrored under the street for the
// reflection and once for real), a bloom chain, and a composite. Everything is
// in linear HDR until the composite, which is what lets neon be *brighter than
// white* and bloom because of it, rather than being clamped into paint.

#include <metal_stdlib>
using namespace metal;

// MARK: - Shared

struct Vertex {
    packed_float3 position;   // world, in tile units
    packed_float3 normal;
    packed_float3 albedo;     // lit by the lights
    packed_float3 emissive;   // light the surface gives off itself
    packed_float3 rim;        // neon on the face's edges
    packed_float2 uv;         // 0…1 across the face, for the rim
    packed_float2 size;       // the face's size in tile units, for the rim
    float ground;             // 1 on the street and land, 0 on buildings
};

struct Light {
    packed_float3 position;
    float radius;
    packed_float3 color;
    float pad;
};

// Every member a 16-byte vector or a matrix, so the Swift mirror of this
// (`MetalCityRenderer.Uniforms`) cannot disagree with it about padding — a
// mismatch there produces no error, just a wrong picture.
struct Uniforms {
    float4x4 viewProjection;
    float4 frame;             // x, y: viewport in pixels · z: wetness 0…1 · w: 1 when mirrored
    float4 moonAndTime;       // xyz: direction moonlight comes from · w: seconds
    uint4 counts;             // x: lights · y: tiles across · z: tile size in pixels
};

// Most lights a single screen tile can carry. A tile over the densest block
// on Apex sees about twenty; the rest is headroom.
constant uint maxLightsPerTile = 64;

struct Varyings {
    float4 clip [[position]];
    float3 world;
    float3 normal;
    float3 albedo;
    float3 emissive;
    float3 rim;
    float2 uv;
    float2 size;
    float ground;
};

// Cheap value noise, for the grain of the ground and the ripples in the wet.
float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float valueNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float a = hash21(i), b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
    float2 u = f * f * (3 - 2 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// MARK: - Scene

vertex Varyings sceneVertex(uint id [[vertex_id]],
                            const device Vertex *vertices [[buffer(0)]],
                            constant Uniforms &u [[buffer(1)]]) {
    Vertex v = vertices[id];
    float3 world = float3(v.position);
    // The reflection is the city mirrored in the street's plane, drawn with
    // the same camera — for a flat mirror and a fixed camera, that is exactly
    // what a reflection *is*, not an approximation of one.
    float3 drawn = u.frame.w > 0.5 ? float3(world.xy, -world.z) : world;
    Varyings out;
    out.clip = u.viewProjection * float4(drawn, 1);
    out.world = world;
    out.normal = float3(v.normal);
    out.albedo = float3(v.albedo);
    out.emissive = float3(v.emissive);
    out.rim = float3(v.rim);
    out.uv = float2(v.uv);
    out.size = float2(v.size);
    out.ground = v.ground;
    return out;
}

/// Light a point: dim moonlight, a floor of ambient, and every neon source
/// near enough to reach it. The neon is the whole look — a wall is dark until
/// something lit stands near it.
///
/// **Only the lights `cullLights` found for this pixel's screen tile.** Every
/// pixel checking every light cost 57 ms a frame on Apex at Retina size; a
/// tile's list is a handful long.
float3 lighting(float3 world, float3 normal, constant Uniforms &u,
                const device Light *lights, uint2 pixel,
                const device uint *tileCounts, const device uint *tileLights) {
    // **Night comes from dim light, not from black paint.** The first pass
    // gave the ground a near-black colour, and nothing — not a lamp, not a
    // sign — could show up on it. Surfaces carry real albedo; the dark is a
    // low ambient and a weak moon.
    float3 moonColor = float3(0.20, 0.19, 0.34);
    float3 light = float3(0.035, 0.03, 0.06)
        + moonColor * max(0.0, dot(normal, u.moonAndTime.xyz)) * 0.6;
    uint tile = (pixel.y / u.counts.z) * u.counts.y + pixel.x / u.counts.z;
    uint count = tileCounts[tile];
    for (uint k = 0; k < count; k++) {
        Light l = lights[tileLights[tile * maxLightsPerTile + k]];
        float3 toLight = float3(l.position) - world;
        float d = length(toLight);
        if (d > l.radius) continue;
        float falloff = 1 - d / l.radius;
        falloff *= falloff;
        // Wrapped a little, so a light just past a wall's edge still grazes
        // it rather than cutting off in a hard line.
        float facing = saturate((dot(normal, toLight / max(d, 1e-3)) + 0.25) / 1.25);
        light += float3(l.color) * falloff * facing;
    }
    return light;
}

/// Neon on the creases: how close this fragment is to the edge of its face.
///
/// **Never thinner than about a pixel and a half.** The first version held
/// the rim at a fixed width in tile units, which is right up close and
/// disappears zoomed out — at a whole-city view 0.022 of a tile is a fraction
/// of a pixel, the outlines faded to nothing, and small dark buildings could
/// not be seen at all (reported from play). SpriteKit strokes its outlines at
/// a fixed width *on screen*, which is what keeps a building findable at any
/// zoom; `fwidth` is how many tile units one pixel spans here, so the rim
/// takes whichever is wider.
float rimAmount(float2 uv, float2 size) {
    if (size.x <= 0 || size.y <= 0) return 0;
    float2 fromEdge = min(uv, 1 - uv) * size;
    float d = min(fromEdge.x, fromEdge.y);
    float aa = fwidth(d);
    float width = max(0.022, aa * 1.4);
    return 1 - smoothstep(width - aa, width + aa, d);
}

fragment float4 sceneFragment(Varyings in [[stage_in]],
                              constant Uniforms &u [[buffer(1)]],
                              const device Light *lights [[buffer(2)]],
                              const device uint *tileCounts [[buffer(3)]],
                              const device uint *tileLights [[buffer(4)]],
                              texture2d<float> reflection [[texture(0)]]) {
    // Nothing below the street in the mirrored pass — a reflection of
    // something that is itself underground is not a reflection of anything.
    if (u.frame.w > 0.5 && in.ground > 0.5) discard_fragment();

    float3 n = normalize(in.normal);
    // The reflection gets moonlight and neon but no point lights: it is
    // blurred by the street and mostly emissive anyway, and its fragments sit
    // at mirrored screen positions the tile lists were not built for.
    float3 color;
    if (u.frame.w > 0.5) {
        color = in.albedo * (float3(0.035, 0.03, 0.06)
            + float3(0.20, 0.19, 0.34) * max(0.0, dot(n, u.moonAndTime.xyz)) * 0.6);
    } else {
        color = in.albedo * lighting(in.world, n, u, lights, uint2(in.clip.xy), tileCounts, tileLights);
    }

    // Walls darken toward their feet: the soft contact shadow Mini Motorways
    // leans on for depth, bought here for a multiply.
    if (in.ground < 0.5 && abs(n.z) < 0.5) {
        color *= 0.55 + 0.45 * smoothstep(0.0, 0.7, in.world.z);
    }

    color += in.emissive;
    color += in.rim * rimAmount(in.uv, in.size);

    // Grain in the ground, so a field of it is a surface and not plastic —
    // applied before the reflection, so the mirrored city stays clean.
    if (in.ground > 0.5) {
        color *= 0.9 + 0.2 * valueNoise(in.world.xy * 3.1);
    }

    // **The wet street**, done the way wet asphalt actually behaves.
    //
    // - It is a *rough* mirror whose blur grows with height: the foot of a
    //   tower reflects sharply and its top dissolves. The mirrored pass
    //   stores each fragment's height in alpha, so the blur is read per
    //   reflected point rather than applied to the whole image at one size.
    // - It streaks *vertically*: light on wet tarmac stretches toward the
    //   viewer into long bands — the image every rainy neon street is known
    //   by — so the taps run mostly down the screen, not in a round blur.
    // - Streets shine a little even dry (`dryGloss`), because a Cyberpunk
    //   street always looks slick; rain turns that into a mirror.
    // - Water mirrors the city always, with ripples, and harder than tarmac.
    bool road = in.ground > 1.5 && in.ground < 2.5;
    bool water = in.ground > 2.5;
    float dryGloss = road ? 0.16 : 0.0;

    // **Water has a surface of its own**, even where nothing is reflected in
    // it. The first render left the river pure black with reflections
    // floating on nothing — nothing said "water". Night water carries a faint
    // tint of the sky and moving bands where the ripples catch the light.
    if (water && u.frame.w < 0.5) {
        float t = u.moonAndTime.w;
        float bands = valueNoise(in.world.xy * float2(1.6, 7.0) + float2(t * 0.25, -t * 0.4));
        float glints = valueNoise(in.world.xy * float2(3.0, 14.0) + float2(-t * 0.5, t * 0.3));
        color = float3(0.018, 0.024, 0.06)
            + float3(0.028, 0.02, 0.065) * smoothstep(0.55, 0.95, bands)
            + float3(0.07, 0.055, 0.13) * smoothstep(0.88, 0.99, glints);
    }
    float wet = max(u.frame.z, dryGloss);
    // Strength first, sampling only where it is worth something: most land
    // in rain has no puddle under it, and nine taps of a texture for a
    // reflection weighted zero was measured costing Apex 4 ms a frame.
    float puddles = smoothstep(0.35, 0.75, valueNoise(in.world.xy * 0.9));
    float strength = 0;
    if (in.ground > 0.5 && u.frame.w < 0.5) {
        if (water) {
            strength = 0.75;
        } else if (road) {
            strength = wet * (0.4 + 0.4 * puddles);
        } else {
            // Land only catches the light in its puddles, and only in rain.
            strength = u.frame.z * 0.22 * puddles;
        }
    }
    if (strength > 0.01) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 screen = in.clip.xy / u.frame.xy;
        float t = u.moonAndTime.w;
        float ripple = valueNoise(in.world.xy * (water ? 5.0 : 9.0) + float2(t * 0.35, t * 0.6)) - 0.5;
        float2 offset = float2(ripple * 0.003, ripple * (water ? 0.008 : 0.004));

        // How high the reflected point stands decides how blurred it is.
        float height = reflection.sample(s, screen + offset).a;
        float spread = (water ? 0.0008 : 0.0016) + height * (water ? 0.0012 : 0.0028);
        float3 mirrored = 0;
        float total = 0;
        for (int i = -4; i <= 4; i++) {
            float w = 1.0 - abs(float(i)) / 5.0;
            // Mostly down the screen, a little across: a streak, not a disc.
            float2 tap = float2(float(i) * spread * 0.18, float(i) * spread);
            mirrored += reflection.sample(s, screen + offset + tap).rgb * w;
            total += w;
        }
        mirrored /= total;
        float darken = water ? 0.5 : 0.3 * u.frame.z * (road ? 1.0 : 0.3);
        color = color * (1 - darken) + mirrored * strength;
    }

    // The reflection pass keeps each fragment's height in alpha, which is
    // what the street reads to decide how blurred that point's reflection is.
    return float4(color, u.frame.w > 0.5 ? max(in.world.z, 0.0) : 1.0);
}

// MARK: - Light culling

struct CullParams {
    float4x4 viewProjection;
    float4 viewportAndExtent;   // xy: viewport in pixels · zw: pixels one tile of radius covers
    uint4 counts;               // x: lights · y: tiles across · z: tiles down · w: tile size
};

/// **Which lights can reach each 32-pixel screen tile.** One thread a tile,
/// testing every light's screen-space box against its own. A few thousand
/// tiles by a few thousand lights is nothing for the GPU — and it turns the
/// per-pixel light loop from "every light in view" into "the few that reach
/// here", which is the whole difference between 57 ms and a playable frame.
kernel void cullLights(const device Light *lights [[buffer(0)]],
                       constant CullParams &p [[buffer(1)]],
                       device uint *tileCounts [[buffer(2)]],
                       device uint *tileLights [[buffer(3)]],
                       uint gid [[thread_position_in_grid]]) {
    uint tilesX = p.counts.y, tilesY = p.counts.z, size = p.counts.w;
    if (gid >= tilesX * tilesY) return;
    float2 low = float2(gid % tilesX, gid / tilesX) * float(size);
    float2 high = low + float(size);
    uint n = 0;
    for (uint i = 0; i < p.counts.x && n < maxLightsPerTile; i++) {
        float4 clip = p.viewProjection * float4(float3(lights[i].position), 1);
        float2 centre = float2((clip.x * 0.5 + 0.5) * p.viewportAndExtent.x,
                               (0.5 - clip.y * 0.5) * p.viewportAndExtent.y);
        float2 extent = lights[i].radius * p.viewportAndExtent.zw;
        if (centre.x + extent.x < low.x || centre.x - extent.x > high.x ||
            centre.y + extent.y < low.y || centre.y - extent.y > high.y) continue;
        tileLights[gid * maxLightsPerTile + n] = i;
        n++;
    }
    tileCounts[gid] = n;
}

// MARK: - Bloom
//
// A proper chain, which SpriteKit could never have: threshold and halve,
// halve again four times, then climb back up adding each level. Wide soft
// halos from the small levels, tight hot cores from the large ones — the
// shape real lens bloom has, and what a single blur of one size cannot fake.

kernel void bloomDown(texture2d<float, access::sample> source [[texture(0)]],
                      texture2d<float, access::write> target [[texture(1)]],
                      constant float &threshold [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= target.get_width() || gid.y >= target.get_height()) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 texel = 1.0 / float2(target.get_width(), target.get_height());
    float2 uv = (float2(gid) + 0.5) * texel;
    float3 c = source.sample(s, uv).rgb * 0.5;
    c += source.sample(s, uv + texel * float2(-1, -1)).rgb * 0.125;
    c += source.sample(s, uv + texel * float2( 1, -1)).rgb * 0.125;
    c += source.sample(s, uv + texel * float2(-1,  1)).rgb * 0.125;
    c += source.sample(s, uv + texel * float2( 1,  1)).rgb * 0.125;
    if (threshold > 0) {
        // Soft knee: brightness past the threshold passes, the rest fades
        // out rather than cutting off, so dim neon still blooms a little.
        float brightness = max(c.r, max(c.g, c.b));
        float knee = threshold * 0.5;
        float soft = clamp(brightness - threshold + knee, 0.0, 2 * knee);
        soft = soft * soft / (4 * knee + 1e-4);
        float passed = max(soft, brightness - threshold) / max(brightness, 1e-4);
        c *= passed;
    }
    target.write(float4(c, 1), gid);
}

kernel void bloomUp(texture2d<float, access::sample> smaller [[texture(0)]],
                    texture2d<float, access::read_write> target [[texture(1)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= target.get_width() || gid.y >= target.get_height()) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 texel = 1.0 / float2(smaller.get_width(), smaller.get_height());
    float2 uv = (float2(gid) + 0.5) / float2(target.get_width(), target.get_height());
    float3 c = smaller.sample(s, uv).rgb * 4;
    c += smaller.sample(s, uv + texel * float2(-1, 0)).rgb * 2;
    c += smaller.sample(s, uv + texel * float2( 1, 0)).rgb * 2;
    c += smaller.sample(s, uv + texel * float2(0, -1)).rgb * 2;
    c += smaller.sample(s, uv + texel * float2(0,  1)).rgb * 2;
    c += smaller.sample(s, uv + texel * float2(-1, -1)).rgb;
    c += smaller.sample(s, uv + texel * float2( 1, -1)).rgb;
    c += smaller.sample(s, uv + texel * float2(-1,  1)).rgb;
    c += smaller.sample(s, uv + texel * float2( 1,  1)).rgb;
    c /= 16;
    target.write(float4(target.read(gid).rgb + c, 1), gid);
}

// MARK: - Composite

struct CompositeSettings {
    float bloomStrength;
    float hazeStrength;
    float exposure;
    float grain;
};

// ACES filmic curve (Narkowicz's fit). Highlights roll off rather than clip,
// which is what keeps a saturated neon sign coloured at its core instead of
// burning to white — the failure this project has recorded four times over.
float3 aces(float3 x) {
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

kernel void composite(texture2d<float, access::sample> scene [[texture(0)]],
                      texture2d<float, access::sample> bloom [[texture(1)]],
                      texture2d<float, access::sample> haze [[texture(2)]],
                      texture2d<float, access::write> output [[texture(3)]],
                      constant CompositeSettings &settings [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
    float3 c = scene.sample(s, uv).rgb;
    c += bloom.sample(s, uv).rgb * settings.bloomStrength;
    // Haze: the widest bloom level laid over everything, which reads as light
    // scattered in wet air — the atmosphere half of the Cyberpunk look.
    c += haze.sample(s, uv).rgb * settings.hazeStrength;
    c = aces(c * settings.exposure);
    // Back from linear light to the screen's gamma. Everything upstream is
    // linear, because lighting maths is; the output image is sRGB.
    c = pow(c, float3(1.0 / 2.2));
    // Vignette, lighter than the SpriteKit one: the haze already frames it.
    float2 centred = uv - 0.5;
    c *= 1 - 0.45 * dot(centred, centred);
    // Grain, strongest in the shadows where film grain lives.
    float g = hash21(float2(gid) * 0.731) - 0.5;
    c += g * settings.grain * (1 - saturate(dot(c, float3(0.33))));
    output.write(float4(saturate(c), 1), gid);
}
