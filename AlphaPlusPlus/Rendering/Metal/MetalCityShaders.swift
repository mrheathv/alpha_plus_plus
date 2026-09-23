import Foundation

/// The spike renderer's shaders, compiled at runtime.
///
/// **A string rather than a `.metal` file**, and on purpose for now. This
/// Xcode install has no Metal toolchain — newer Xcodes download it separately
/// (`xcodebuild -downloadComponent MetalToolchain`) — so a `.metal` file in the
/// target fails the whole build. `MTLDevice.makeLibrary(source:)` compiles
/// through the OS's own Metal framework instead, which is exactly how the
/// game's `SKShader`s already work. If the migration goes ahead, precompiling
/// is worth the toolchain; for a spike it is not.
enum MetalCityShaders {
    static let source = #"""
// The spike renderer's shaders — see `MetalCityRenderer`.
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
    uint4 counts;             // x: lights
};

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
float3 lighting(float3 world, float3 normal, constant Uniforms &u,
                const device Light *lights) {
    // **Night comes from dim light, not from black paint.** The first pass
    // gave the ground a near-black colour, and nothing — not a lamp, not a
    // sign — could show up on it. Surfaces carry real albedo; the dark is a
    // low ambient and a weak moon.
    float3 moonColor = float3(0.20, 0.19, 0.34);
    float3 light = float3(0.035, 0.03, 0.06)
        + moonColor * max(0.0, dot(normal, u.moonAndTime.xyz)) * 0.6;
    for (uint i = 0; i < u.counts.x; i++) {
        Light l = lights[i];
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

/// Neon on the creases: how close this fragment is to the edge of its face,
/// measured in tile units so a rim is the same width on a tower and a kerb.
float rimAmount(float2 uv, float2 size) {
    if (size.x <= 0 || size.y <= 0) return 0;
    float2 fromEdge = min(uv, 1 - uv) * size;
    float d = min(fromEdge.x, fromEdge.y);
    float width = 0.022;
    float aa = fwidth(d);
    return 1 - smoothstep(width - aa, width + aa, d);
}

fragment float4 sceneFragment(Varyings in [[stage_in]],
                              constant Uniforms &u [[buffer(1)]],
                              const device Light *lights [[buffer(2)]],
                              texture2d<float> reflection [[texture(0)]]) {
    // Nothing below the street in the mirrored pass — a reflection of
    // something that is itself underground is not a reflection of anything.
    if (u.frame.w > 0.5 && in.ground > 0.5) discard_fragment();

    float3 n = normalize(in.normal);
    float3 color = in.albedo * lighting(in.world, n, u, lights);

    // Walls darken toward their feet: the soft contact shadow Mini Motorways
    // leans on for depth, bought here for a multiply.
    if (in.ground < 0.5 && abs(n.z) < 0.5) {
        color *= 0.55 + 0.45 * smoothstep(0.0, 0.7, in.world.z);
    }

    color += in.emissive;
    color += in.rim * rimAmount(in.uv, in.size);

    if (in.ground > 0.5 && u.frame.w < 0.5 && u.frame.z > 0) {
        // **The wet street.** The mirrored city, sampled where this pixel is,
        // pushed about by ripples and softened with a few taps — wet asphalt
        // is a rough mirror, not a polished one. Puddles come and go with a
        // low-frequency noise so the street is patchy rather than glass.
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 screen = in.clip.xy / u.frame.xy;
        float ripple = valueNoise(in.world.xy * 9 + float2(0, u.moonAndTime.w * 0.6)) - 0.5;
        // Small ripples, mostly sideways: the first pass pushed the image
        // down the screen by a lot, and the reflections read as paint
        // dripping off the buildings rather than light lying in water.
        float2 offset = float2(ripple * 0.003, ripple * 0.004);
        float3 mirrored = 0;
        for (int i = -3; i <= 3; i++) {
            mirrored += reflection.sample(s, screen + offset + float2(i * 0.0012, i * 0.0022)).rgb;
        }
        mirrored /= 7;
        float puddles = smoothstep(0.35, 0.75, valueNoise(in.world.xy * 0.9));
        // The street is what gets wet enough to mirror; the land beside it
        // only catches the light in its puddles.
        bool road = in.ground > 1.5;
        float strength = u.frame.z * (road ? (0.35 + 0.35 * puddles) : 0.22 * puddles);
        color = color * (1 - 0.3 * u.frame.z * (road ? 1.0 : 0.3)) + mirrored * strength;
    }

    // Grain in the ground, so a field of it is a surface and not plastic.
    if (in.ground > 0.5) {
        color *= 0.9 + 0.2 * valueNoise(in.world.xy * 3.1);
    }
    return float4(color, 1);
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
"""#
}
