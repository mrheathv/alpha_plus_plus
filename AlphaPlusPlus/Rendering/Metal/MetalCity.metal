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
    uint4 counts;             // x: lights · y: tiles across · z: tile size in pixels · w: map width | height << 16
    float4 overlay;           // x: 1 when a view washes buildings toward its colours · y: motion clock · z: rainfall 0…1
    float4 fog;               // x: low fog · y: its height in tiles · z: distance haze · w: street gloss
    float4 zenith;            // rgb: the air overhead, near the viewer · w: how far out the camera is, 0…1
    float4 horizon;           // rgb: the far air and the sky past the map · w: gloss on open ground
};

// The colour of the air at a point on screen: the sky's colour toward the
// top of the frame, which in this projection is the far side of the city,
// and the overhead colour toward the bottom, which is nearest.
static float3 airColor(float screenY, constant Uniforms &u) {
    return mix(u.horizon.rgb, u.zenith.rgb, smoothstep(0.0, 1.0, screenY));
}

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
    // Never thinner than 1.4 pixels, and — since the camera can now come
    // close to street level — never wider than about five: held at its world
    // width, an edge up close was fourteen pixels across and read as a bar
    // rather than a tube of light.
    float width = min(max(0.022, aa * 1.4), aa * 5.0);
    // **Where the pixel floor has taken over, the rim gives back energy.**
    // The floor keeps an edge visible as the camera pulls back — but at the
    // widest camera a face is a few pixels across, a 1.4-pixel rim covers
    // most of it, and every building came out the colour of its outline: a
    // city of pastel lavender. The edge stays; its light scales with how much
    // wider than its real width it is being drawn.
    float energy = clamp(0.022 / width, 0.3, 1.0);
    return (1 - smoothstep(width - aa, width + aa, d)) * energy;
}

/// **Rain rings on the wet street**: small circles spreading and fading
/// where drops land, the signature of a neon street in the rain. A grid of
/// cells a quarter of a tile across, each landing one drop per cycle at its
/// own place and moment; returns how bright the ring is here and which way
/// it bends the reflection. Runs on the motion clock, so it stops with the
/// city like the drops that make it.
static float3 rainRings(float2 p, float t, float rainfall) {
    const float cells = 4.0;
    float2 cell = floor(p * cells);
    float3 result = 0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            float2 c = cell + float2(dx, dy);
            float seed = hash21(c);
            float rate = 0.9 + 0.6 * seed;
            float cycle = t * rate + seed * 7.0;
            float phase = fract(cycle);
            // Not every cell rains every cycle: heavier rain, more rings.
            if (hash21(c + floor(cycle) * 1.37) > rainfall * 0.85) continue;
            float2 centre = (c + 0.2 + 0.6 * float2(hash21(c + floor(cycle)), hash21(c.yx + floor(cycle) + 3.1))) / cells;
            float2 to = p - centre;
            float d = length(to);
            float radius = phase * 0.15;
            float ring = exp(-pow((d - radius) / 0.011, 2.0)) * pow(1.0 - phase, 1.5);
            result.x += ring;
            result.yz += (d > 1e-4 ? to / d : float2(0)) * ring;
        }
    }
    return result;
}

/// The city, shaded. Shared by both passes; the entry points below decide
/// what each one discards.
static float4 shadeScene(Varyings in, constant Uniforms &u, const device Light *lights,
                         const device uint *tileCounts, const device uint *tileLights,
                         texture2d<float> reflection, texture2d<float> overlayTint) {
    float3 n = normalize(in.normal);
    // The reflection gets moonlight and neon but no point lights: it is
    // blurred by the street and mostly emissive anyway, and its fragments sit
    // at mirrored screen positions the tile lists were not built for.
    float3 color;
    if (u.frame.w > 0.5) {
        color = in.albedo * (float3(0.035, 0.03, 0.06)
            + float3(0.20, 0.19, 0.34) * max(0.0, dot(n, u.moonAndTime.xyz)) * 0.6);
    } else if (max(in.albedo.r, max(in.albedo.g, in.albedo.b)) <= 0.0) {
        // **A lit surface has no albedo, so light falling on it is multiplied
        // by zero.** Windows, lit volumes and neon are all such surfaces, and
        // the level-6 skyline is mostly lit glass: running the tile's light
        // loop only to throw the answer away was what put Apex over budget.
        color = float3(0);
    } else {
        color = in.albedo * lighting(in.world, n, u, lights, uint2(in.clip.xy), tileCounts, tileLights);
    }

    // Walls darken toward their feet: the soft contact shadow Mini Motorways
    // leans on for depth, bought here for a multiply.
    if (in.ground < 0.5 && abs(n.z) < 0.5) {
        color *= 0.55 + 0.45 * smoothstep(0.0, 0.7, in.world.z);
    }

    // Windows (tagged 0.25) calm as the camera pulls back: from afar a
    // facade of lit panels is speckle, and the neon outline is what carries
    // the form. Full strength at rest, half from the widest camera.
    float farAway = saturate((u.zenith.w - 0.5) * 2.0);
    bool window = in.ground > 0.2 && in.ground < 0.3;
    float3 glow = in.emissive * (window ? mix(1.0, 0.5, farAway) : 1.0)
        + in.rim * rimAmount(in.uv, in.size);

    // **A view recolours each building's light toward its answer** —
    // supplied, wanting, safe, served — and leaves its walls dark. The first
    // Metal version repainted the whole building in the answer's colour, and
    // it came back as a city of plastic blocks that were simply on or off
    // (reported from play: "they just light up or they don't"). SpriteKit
    // never did that: its buildings stayed night silhouettes whose *neon*
    // changed colour. So the walls are only dimmed, and the neon edges and
    // lit windows take the answer's hue at their own brightness, with a floor
    // so a dark facade still says something.
    if (u.overlay.x > 0.5 && in.ground < 0.5) {
        uint2 mapSize = uint2(u.counts.w & 0xFFFF, u.counts.w >> 16);
        uint2 cell = uint2(clamp(floor(in.world.xy), float2(0), float2(mapSize) - 1));
        float4 wash = overlayTint.read(cell);
        if (wash.a > 0) {
            float l = dot(glow, float3(0.2126, 0.7152, 0.0722));
            color *= mix(1.0, 0.3, wash.a);
            color += wash.rgb * 0.06 * wash.a;
            glow = mix(glow, wash.rgb * (0.15 + 1.4 * min(l, 1.5)), wash.a);
        }
    }
    color += glow;

    // Grain in the ground, so a field of it is a surface and not plastic —
    // applied before the reflection, so the mirrored city stays clean.
    if (in.ground > 0.5) {
        color *= 0.9 + 0.2 * valueNoise(in.world.xy * 3.1);
    }
    // And on open land, large faint patches of lighter and darker earth, so
    // a field reads as terrain rather than a flat colour. Large and almost
    // valueless on purpose: fine detail repeated across a field is a
    // pattern, the lesson the Classic renderer's bare land already taught.
    if (in.ground > 0.5 && in.ground < 1.5) {
        color *= 0.85 + 0.3 * valueNoise(in.world.xy * 0.37 + 11.0);
    }

    // **The land beyond the map** carries on past the edge, ruled every four
    // tiles and fading into the night — so the city sits somewhere rather
    // than floating in a void, and the light it throws has ground to land
    // on. The same idea as the Classic backdrop, lit instead of painted.
    if (in.ground > 3.5) {
        float2 mapSize = float2(u.counts.w & 0xFFFF, u.counts.w >> 16);
        float2 p = in.world.xy;
        float2 outside = max(max(-p, p - mapSize), float2(0));
        float d = length(outside);
        float2 cell = abs(fract(p / 4.0 + 0.5) - 0.5) * 4.0;
        float lineWidth = fwidth(p.x) * 1.2 + 0.015;
        float line = 1 - smoothstep(0.0, lineWidth, min(cell.x, cell.y));
        color += float3(0.045, 0.032, 0.085) * line * 0.7;
        // Into the sky within a few tiles, so the land has become sunset by
        // the time the sun's horizon arrives; fading over thirty left the sun
        // hovering above a band of dark ground. A few tiles because the
        // camera stops two tiles past the map, so the sky a player can reach
        // is a thin strip above the far corner.
        float fade = 1 - smoothstep(1.5, 7.0, d);
        // Past the map the land fades into the sky's colour rather than into
        // black: in a retrowave frame the edge of the world is a sunset.
        color = mix(airColor(in.clip.y / u.frame.y, u), color, fade);
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
    bool water = in.ground > 2.5 && in.ground < 3.5;
    bool beyond = in.ground > 3.5;
    float dryGloss = road ? u.fog.w : 0.0;

    // **Water is a dark mirror moved by waves**, not a colour with noise on
    // it. The first version painted lavender noise over the river and it
    // read as fabric. Real water shows almost nothing of its own: what makes
    // it look alive is waves bending what it reflects, and the odd glint
    // where a wave catches the moon. So four layered waves give a surface
    // normal, the normal bends the reflection below, and the only colour the
    // water adds is a deep base and those glints.
    float3 waveNormal = float3(0, 0, 1);
    if (water && u.frame.w < 0.5) {
        float t = u.moonAndTime.w;
        float2 p = in.world.xy;
        const float2 directions[4] = { float2(1, 0.3), float2(-0.4, 1), float2(0.7, -0.8), float2(-1, -0.2) };
        const float frequencies[4] = { 3.1, 4.7, 7.3, 11.0 };
        const float amplitudes[4] = { 0.05, 0.035, 0.02, 0.012 };
        const float speeds[4] = { 0.9, 1.3, 1.7, 2.3 };
        float2 slope = 0;
        for (int i = 0; i < 4; i++) {
            float2 d = normalize(directions[i]);
            float phase = dot(d, p) * frequencies[i] + t * speeds[i];
            slope += d * cos(phase) * frequencies[i] * amplitudes[i];
        }
        waveNormal = normalize(float3(-slope, 1));
        float3 view = normalize(float3(0.58, 0.58, 0.57));
        float3 bounced = reflect(-view, waveNormal);
        float glint = pow(saturate(dot(bounced, normalize(u.moonAndTime.xyz))), 90.0);
        color = float3(0.006, 0.011, 0.028)
            + float3(0.02, 0.018, 0.045) * (1 - waveNormal.z) * 10
            + float3(0.55, 0.5, 0.8) * glint;
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
        } else if (!beyond) {
            // Land catches the light in its puddles in rain, and — when the
            // look asks for it — a faint polished sheen when dry.
            strength = max(u.frame.z * 0.22 * puddles, u.horizon.w * (0.4 + 0.6 * puddles));
        }
    }
    if (strength > 0.01) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 screen = in.clip.xy / u.frame.xy;
        float t = u.moonAndTime.w;
        // Rain on the puddles is weather, and weather stops with the city;
        // the river below keeps the wall clock because it is not part of it.
        float rain = u.overlay.y;
        float ripple = valueNoise(in.world.xy * 9.0 + float2(rain * 0.35, rain * 0.6)) - 0.5;
        float2 offset = float2(ripple * 0.003, ripple * 0.004);
        float3 rings = u.overlay.z > 0.01 && !beyond ? rainRings(in.world.xy, rain, u.overlay.z) : float3(0);
        // A ring bends what the street reflects outward from where the drop
        // landed, the projection laying x and y out as it does the waves'.
        offset += float2(rings.y - rings.z, rings.y + rings.z) * 0.004;
        if (water) {
            // The waves bend the mirror: the surface normal, carried into
            // screen space the way the projection lays x and y out.
            float2 n = waveNormal.xy;
            offset = float2(n.x - n.y, n.x + n.y) * float2(0.005, 0.007);
        }

        // How high the reflected point stands decides how blurred it is.
        float height = reflection.sample(s, screen + offset).a;
        float spread = (water ? 0.0008 : 0.0016) + height * (water ? 0.0012 : 0.0028);
        // Wet tarmac is a sharper mirror than a dry sheen.
        spread *= mix(1.0, 0.7, u.frame.z);
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
        // Wet asphalt is darker than dry, which is what lets the reflections
        // in it read as reflections rather than as a brighter street.
        float darken = water ? 0.5 : 0.45 * u.frame.z * (road ? 1.0 : 0.3);
        color = color * (1 - darken) + mirrored * strength;
        // The rings themselves catch light: brightest where the street is
        // already reflecting something bright, so they sparkle under neon
        // and all but vanish in the dark.
        float lit = dot(mirrored, float3(0.2126, 0.7152, 0.0722));
        color += (mirrored * 2.4 + airColor(in.clip.y / u.frame.y, u) * 0.35) * rings.x
            * (0.35 + min(lit, 1.0)) * saturate(strength * 2.0);
    }

    // **The air.** Low fog pooling in the streets, thinning with height so
    // the towers rise out of it, and a distance haze toward the far side of
    // the frame that grows as the camera pulls back — both tinted with the
    // sky, so depth reads as colour rather than as grey. Light still cuts
    // through: fog takes at most two thirds of what is behind it.
    if (u.frame.w < 0.5 && !beyond) {
        float screenY = in.clip.y / u.frame.y;
        float low = u.fog.x * exp(-max(in.world.z, 0.0) / max(u.fog.y, 0.01));
        // Half as much on open ground: from the widest camera an empty map
        // turned into one mauve slab.
        float far = u.fog.z * u.zenith.w * (1.0 - screenY) * (in.ground > 0.5 ? 0.5 : 1.0);
        float haze = min(0.66, low + far);
        color = mix(color, airColor(screenY, u), haze);
    }

    // The reflection pass keeps each fragment's height in alpha, which is
    // what the street reads to decide how blurred that point's reflection is.
    return float4(color, u.frame.w > 0.5 ? max(in.world.z, 0.0) : 1.0);
}

/// **The main pass never discards**, and that is a performance rule rather
/// than a style one. Apple's GPUs skip shading any pixel a nearer opaque
/// surface will cover — hidden surface removal — but only for shaders that
/// cannot discard. With the reflection pass's `discard` sharing this shader,
/// every wall hidden behind another building was lit in full and thrown
/// away: Apex spent 14.4 ms a frame at the resting camera.
fragment float4 sceneFragment(Varyings in [[stage_in]],
                              constant Uniforms &u [[buffer(1)]],
                              const device Light *lights [[buffer(2)]],
                              const device uint *tileCounts [[buffer(3)]],
                              const device uint *tileLights [[buffer(4)]],
                              texture2d<float> reflection [[texture(0)]],
                              texture2d<float> overlayTint [[texture(1)]]) {
    return shadeScene(in, u, lights, tileCounts, tileLights, reflection, overlayTint);
}

/// The mirrored pass: nothing below the street — a reflection of something
/// that is itself underground is not a reflection of anything.
fragment float4 reflectionFragment(Varyings in [[stage_in]],
                                   constant Uniforms &u [[buffer(1)]],
                                   const device Light *lights [[buffer(2)]],
                                   const device uint *tileCounts [[buffer(3)]],
                                   const device uint *tileLights [[buffer(4)]],
                                   texture2d<float> reflection [[texture(0)]],
                                   texture2d<float> overlayTint [[texture(1)]]) {
    if (in.ground > 0.5) discard_fragment();
    return shadeScene(in, u, lights, tileCounts, tileLights, reflection, overlayTint);
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
    float saturation;   // 1 leaves colour alone
    float toe;          // how hard the shadows are pressed toward black
    float scanlines;    // 0 for none; a light tube texture otherwise
    float pad1;
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
    // **The grade**: shadows pressed down and colour pushed a little, in
    // that order. A lit city at night went milky — pale windows, lavender
    // haze — where the brief is deep black with saturated neon in it. The
    // toe darkens only what is already dark, so a sign stays a sign.
    c = c * (1 - settings.toe) + c * c * settings.toe;
    float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
    c = max(0.0, mix(float3(luma), c, settings.saturation));
    // Back from linear light to the screen's gamma. Everything upstream is
    // linear, because lighting maths is; the output image is sRGB.
    c = pow(c, float3(1.0 / 2.2));
    // Vignette, lighter than the SpriteKit one: the haze already frames it.
    float2 centred = uv - 0.5;
    c *= 1 - 0.45 * dot(centred, centred);
    // A light tube texture, alternate rows of two pixels, when the look asks.
    c *= 1 - settings.scanlines * step(0.5, fract(float(gid.y) * 0.25));
    // Grain, strongest in the shadows where film grain lives.
    float g = hash21(float2(gid) * 0.731) - 0.5;
    c += g * settings.grain * (1 - saturate(dot(c, float3(0.33))));
    output.write(float4(saturate(c), 1), gid);
}

// MARK: - Things that move (migration M3)
//
// Traces are segments of light with a width: a car, a tram, an engine, a
// flame, an ember, a raindrop. Drawn instanced — six vertices per instance,
// no vertex buffer — additively, depth-tested against the city but never
// writing depth, so a trace behind a tower is hidden and two traces crossing
// simply add up, which is what light does.

struct Trace {
    packed_float3 a;       // tail, world tile units
    float width;           // in tiles; floored in pixels below
    packed_float3 b;       // head
    float mode;            // 0 streak · 1 even line · 2 flame
    packed_float3 color;   // linear, may exceed 1
    float alpha;
};

// Every member a 16-byte vector, for the reason `Uniforms` is.
struct MotionUniforms {
    float4x4 viewProjection;
    float4 frame;    // xy: viewport in pixels · z: pixels per tile · w: 1 when mirrored
    float4 area;     // rain: the ground rectangle drops fall over, x0 y0 width height
    float4 params;   // x: motion clock · y: rainfall 0…1 · z: smoke particles per emitter · w: unused
};

struct TraceVaryings {
    float4 clip [[position]];
    float2 uv;       // x: 0 at the tail, 1 at the head · y: -1…1 across
    float3 color;
    float alpha;
    float mode;
};

static float3 mirrorIfNeeded(float3 p, constant MotionUniforms &u) {
    return u.frame.w > 0.5 ? float3(p.xy, -p.z) : p;
}

// One corner of a segment's quad, expanded on screen so its width is a
// number of pixels: at least `minPixels`, so a trace survives the camera
// pulling back — the same floor the neon rims got in M1.
static TraceVaryings segmentCorner(uint vid, float3 a, float3 b, float widthTiles, float minPixels,
                                   constant MotionUniforms &u) {
    const float2 corners[6] = { float2(0, -1), float2(1, -1), float2(1, 1),
                                float2(0, -1), float2(1, 1), float2(0, 1) };
    float2 c = corners[vid];
    float4 ca = u.viewProjection * float4(mirrorIfNeeded(a, u), 1);
    float4 cb = u.viewProjection * float4(mirrorIfNeeded(b, u), 1);
    float2 halfView = u.frame.xy * 0.5;
    float2 pa = ca.xy * halfView, pb = cb.xy * halfView;
    float2 along = pb - pa;
    float len = length(along);
    float2 dir = len > 1e-4 ? along / len : float2(0, 1);
    float2 perp = float2(-dir.y, dir.x);
    float widthPx = max(minPixels, widthTiles * u.frame.z);
    // Grow the ends by half a width, so a short trace is never a sliver.
    float2 p = mix(pa - dir * widthPx * 0.5, pb + dir * widthPx * 0.5, c.x) + perp * c.y * widthPx * 0.5;
    TraceVaryings out;
    out.clip = float4(p / halfView, mix(ca.z, cb.z, c.x), 1);
    out.uv = c;
    return out;
}

vertex TraceVaryings traceVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 const device Trace *traces [[buffer(0)]],
                                 constant MotionUniforms &u [[buffer(1)]]) {
    Trace t = traces[iid];
    TraceVaryings out = segmentCorner(vid, float3(t.a), float3(t.b), t.width, 1.6, u);
    out.color = float3(t.color);
    out.alpha = t.alpha;
    out.mode = t.mode;
    return out;
}

// Neon signs: a quad in the world carrying one word from the sign atlas,
// added to the frame as light. `MetalSigns` plans them; see its doc comment.
struct Sign {
    float4 origin;   // xyz: bottom-left corner in world tiles
    float4 u;        // xyz: along the text
    float4 v;        // xyz: up the text
    float4 tint;     // rgb: the tube's colour
    float4 rect;     // the word in the atlas: u0, v top, u1, v bottom
};

struct SignVaryings {
    float4 clip [[position]];
    float2 uv;
    float3 color;
};

vertex SignVaryings signVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                               const device Sign *signs [[buffer(0)]],
                               constant MotionUniforms &u [[buffer(1)]]) {
    const float2 corners[6] = { float2(0, 0), float2(1, 0), float2(1, 1),
                                float2(0, 0), float2(1, 1), float2(0, 1) };
    Sign sign = signs[iid];
    float2 c = corners[vid];
    float3 world = sign.origin.xyz + sign.u.xyz * c.x + sign.v.xyz * c.y;
    SignVaryings out;
    out.clip = u.viewProjection * float4(mirrorIfNeeded(world, u), 1);
    out.uv = float2(mix(sign.rect.x, sign.rect.z, c.x), mix(sign.rect.w, sign.rect.y, c.y));
    out.color = sign.tint.rgb;
    return out;
}

fragment float4 signFragment(SignVaryings in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float glow = atlas.sample(s, in.uv).r;
    // The tube's core burns past white so it blooms; the halo around it keeps
    // the colour.
    float3 light = in.color * glow * 3.2 + float3(1.0) * pow(glow, 6.0) * 0.8;
    return float4(light, 0);
}

// Rain: nothing on the CPU but a count. Each drop's place and fall come from
// its index and the clock, so a downpour of thousands costs no more to plan
// than a drizzle. It falls over the ground the camera can see, from a fixed
// height, and a drop behind a tower is hidden by it like anything else.
vertex TraceVaryings rainVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                constant MotionUniforms &u [[buffer(1)]]) {
    float i = float(iid);
    float2 r = float2(hash21(float2(i, 1.7)), hash21(float2(3.1, i)));
    float2 ground = u.area.xy + r * u.area.zw;
    const float ceiling = 7.0;
    float fall = fract(u.params.x * (1.6 + 0.4 * r.x) + hash21(float2(i, i * 0.37)));
    float z = ceiling * (1 - fall);
    float3 head = float3(ground, z);
    float3 tail = head + float3(0.06, 0.03, 0.45);
    TraceVaryings out = segmentCorner(vid, tail, head, 0.008, 0.8, u);
    // Drops catch the city's light rather than being grey scratches on the
    // lens: some pink, some cyan, as a neon street lights falling rain.
    out.color = mix(float3(1.0, 0.25, 0.75), float3(0.25, 0.75, 1.0), step(0.5, r.x)) * 0.9;
    out.alpha = 0.32 * u.params.y;
    out.mode = 1;
    return out;
}

fragment float4 traceFragment(TraceVaryings in [[stage_in]]) {
    float u = saturate(in.uv.x), v = in.uv.y;
    float3 color = in.color;
    float shape;
    if (in.mode < 0.5) {
        // A streak: dark at the tail, brightest just behind the head — the
        // motion blur of something travelling toward the bright end.
        shape = smoothstep(0.0, 0.85, u) * (1 - smoothstep(0.93, 1.0, u));
        shape *= pow(saturate(1 - v * v), 1.5);
    } else if (in.mode < 1.5) {
        shape = sin(u * M_PI_F) * saturate(1 - v * v);
    } else {
        // A flame: white-hot at its root, through ember to hot magenta at the
        // tip, narrowing as it rises — and cut by horizontal slats that widen
        // toward the top, which is the synthwave sun run upside down. That is
        // the SpriteKit fire's own mark (`NeonStyle.sunsetFlameTexture`),
        // carried across rather than reinvented: no zone owns a gradient, and
        // a flame without its slats read as a searchlight beam.
        float taper = max(0.04, 1 - u * 0.92);
        float across = saturate(1 - (v / taper) * (v / taper));
        float slat = step(0.22 * u * u, fract(u * 6.5 + 0.35));
        shape = across * across * pow(1 - u, 0.5) * smoothstep(0.0, 0.06, u) * slat;
        float3 hot = float3(1.0, 0.85, 0.55), ember = float3(1.0, 0.3, 0.04), tip = float3(0.95, 0.05, 0.4);
        // The white core is short: at any length it swallows the ramp, and a
        // flame that reads white is a lamp on a roof, not a fire.
        color *= u < 0.15 ? mix(hot, ember, u / 0.15) : mix(ember, tip, saturate((u - 0.15) / 0.6));
    }
    // Alpha only matters to the flame pass, which is blended over what is
    // behind it; the additive passes ignore it.
    return float4(color * shape * in.alpha, in.mode > 1.5 ? saturate(shape * in.alpha) : 0);
}

// Smoke from a working factory: soft puffs rising and spreading downwind.
// **The one particle that is not additive** — smoke hides what is behind it,
// and adding it would make a chimney look like it was firing a beam.
struct SmokeEmitter {
    float4 place;   // xyz: chimney top · w: density 1…5
};

vertex TraceVaryings smokeVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 const device SmokeEmitter *emitters [[buffer(0)]],
                                 constant MotionUniforms &u [[buffer(1)]]) {
    uint perEmitter = uint(u.params.z);
    SmokeEmitter e = emitters[iid / perEmitter];
    float k = float(iid % perEmitter);
    float seed = hash21(e.place.xy + k);
    float density = e.place.w;
    float age = fract(u.params.x * (0.12 + 0.02 * density) + k / float(perEmitter) + seed);
    float3 at = e.place.xyz + float3(age * 1.3 + (seed - 0.5) * 0.3,
                                     age * 0.4 + (hash21(float2(k, seed)) - 0.5) * 0.3,
                                     age * (1.5 + 0.25 * density));
    const float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(1, 1),
                                float2(-1, -1), float2(1, 1), float2(-1, 1) };
    float2 c = corners[vid];
    float4 clip = u.viewProjection * float4(at, 1);
    float radiusPx = (0.12 + age * 0.55) * u.frame.z;
    TraceVaryings out;
    out.clip = float4(clip.xy + c * radiusPx / (u.frame.xy * 0.5), clip.z, 1);
    out.uv = c;
    out.color = float3(0.12, 0.1, 0.15);
    out.alpha = 0.34 * (1 - age) * smoothstep(0.0, 0.12, age) * (0.5 + density * 0.1);
    out.mode = 0;
    return out;
}

fragment float4 smokeFragment(TraceVaryings in [[stage_in]]) {
    float r2 = dot(in.uv, in.uv);
    float a = in.alpha * pow(saturate(1 - r2), 2.0);
    return float4(in.color * a, a);   // premultiplied
}

// MARK: - What the map tells you (migration M4)

// One tile of a view: its colour as light on the ground. Mode 0 fills the
// tile, with its edge a little darker so a field of them still reads as
// tiles; mode 1 is a soft pool centred on the point, for a lot that must be
// found from across the map.
struct OverlayTile {
    float4 place;   // x, y, size in tiles, z
    float4 color;   // rgb linear · w: mode
};

vertex TraceVaryings overlayTileVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                       const device OverlayTile *tiles [[buffer(0)]],
                                       constant MotionUniforms &u [[buffer(1)]]) {
    const float2 corners[6] = { float2(0, 0), float2(1, 0), float2(1, 1),
                                float2(0, 0), float2(1, 1), float2(0, 1) };
    OverlayTile t = tiles[iid];
    float2 c = corners[vid];
    bool pool = t.color.w > 0.5;
    float2 xy = pool ? t.place.xy + (c - 0.5) * t.place.z : t.place.xy + c * t.place.z;
    TraceVaryings out;
    out.clip = u.viewProjection * float4(mirrorIfNeeded(float3(xy, t.place.w), u), 1);
    out.uv = c * 2 - 1;
    out.color = t.color.rgb;
    out.alpha = 1;
    out.mode = t.color.w;
    return out;
}

fragment float4 overlayTileFragment(TraceVaryings in [[stage_in]]) {
    float shape;
    if (in.mode > 0.5) {
        float r2 = dot(in.uv, in.uv);
        shape = pow(saturate(1 - r2), 2.0);
    } else {
        float edge = max(abs(in.uv.x), abs(in.uv.y));
        shape = 1 - 0.45 * smoothstep(0.82, 1.0, edge);
    }
    return float4(in.color * shape, 0);
}

// A badge: a glyph that stands over its building and faces the camera, a
// fixed number of pixels across however far out the camera is — a warning
// that shrinks with the zoom is a warning nobody sees from across the map.
struct Billboard {
    float4 place;   // xyz world · w: pixels across
    float4 tint;    // rgb · w: which glyph
    float4 offset;  // xy: shift on screen in pixels, so two badges on one roof
                    // sit side by side at any zoom rather than overlapping
};

vertex TraceVaryings billboardVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                     const device Billboard *boards [[buffer(0)]],
                                     constant MotionUniforms &u [[buffer(1)]]) {
    const float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(1, 1),
                                float2(-1, -1), float2(1, 1), float2(-1, 1) };
    Billboard b = boards[iid];
    float2 c = corners[vid];
    float4 clip = u.viewProjection * float4(b.place.xyz, 1);
    TraceVaryings out;
    out.clip = float4(clip.xy + (c * b.place.w * 0.5 + b.offset.xy * float2(1, -1)) / (u.frame.xy * 0.5), 0, 1);
    // Three glyphs across one texture.
    out.uv = float2((b.tint.w + c.x * 0.5 + 0.5) / 3.0, 0.5 - c.y * 0.5);
    out.color = b.tint.rgb;
    out.alpha = 1;
    out.mode = b.tint.w;
    return out;
}

fragment float4 billboardFragment(TraceVaryings in [[stage_in]],
                                  texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 texel = atlas.sample(s, in.uv);
    return float4(texel.rgb * in.color, texel.a);   // premultiplied
}

// MARK: - The sky (retrowave direction)

// The sky behind everything, and the synthwave sun in it. Drawn first in the
// main pass at the far plane without writing depth, so the city, the land
// past the map and everything else land on top of it — the sky shows only
// where nothing else is.
struct SkyParams {
    float4 frame;    // xy: viewport in pixels
    float4 sun;      // xy: the sun's centre in pixels · z: its radius · w: the horizon's y
    float4 zenith;   // rgb, as `Uniforms.zenith`
    float4 horizon;  // rgb, as `Uniforms.horizon`
};

struct SkyVaryings {
    float4 clip [[position]];
};

vertex SkyVaryings skyVertex(uint vid [[vertex_id]]) {
    // One triangle that covers the screen.
    const float2 corners[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    SkyVaryings out;
    out.clip = float4(corners[vid], 0.99999, 1);
    return out;
}

fragment float4 skyFragment(SkyVaryings in [[stage_in]], constant SkyParams &sky [[buffer(0)]]) {
    float2 p = in.clip.xy;
    float screenY = p.y / sky.frame.y;
    float3 color = mix(sky.horizon.rgb, sky.zenith.rgb, smoothstep(0.0, 1.0, screenY));

    // A glow along the horizon, the line every retrowave frame is built on.
    float horizonY = sky.sun.w;
    color += sky.horizon.rgb * 0.9 * exp(-abs(p.y - horizonY) / max(1.0, sky.frame.y * 0.04));

    return float4(color, 1);
}

// **The sun**, the title screen's, the right way up: a disc shaded
// yellow → orange → magenta, cut by slats that widen toward the bottom, and
// sitting on the horizon with its lower part below it. Its own pass, drawn
// over the land past the map and under the city, so the city stands in front
// of it — which is the picture: a skyline against a sunset.
// The sun's own quad: its disc and halo, cut at the horizon — never the
// whole screen. Drawn full-screen, it ran its slat loop over millions of
// pixels on every frame, almost all of them with no sun in view, and cost
// Apex four milliseconds.
vertex SkyVaryings sunVertex(uint vid [[vertex_id]], constant SkyParams &sky [[buffer(0)]]) {
    const float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(1, 1),
                                float2(-1, -1), float2(1, 1), float2(-1, 1) };
    float2 c = corners[vid];
    float reach = sky.sun.z * 1.8;
    float2 pixel = float2(sky.sun.x + c.x * reach,
                          c.y < 0 ? sky.sun.y - reach : min(sky.sun.w, sky.sun.y + reach));
    SkyVaryings out;
    out.clip = float4(pixel.x / sky.frame.x * 2 - 1, 1 - pixel.y / sky.frame.y * 2, 0.5, 1);
    return out;
}

fragment float4 sunFragment(SkyVaryings in [[stage_in]], constant SkyParams &sky [[buffer(0)]]) {
    float2 p = in.clip.xy;
    float horizonY = sky.sun.w;
    if (p.y >= horizonY) return float4(0);
    float r = sky.sun.z;
    float2 d = (p - sky.sun.xy) / max(r, 1.0);
    float dist = length(d);
    // The halo, added: premultiplied with no coverage.
    // Faded to nothing inside the quad's edge (1.8 radii), or the quad shows
    // as a lit rectangle around the sun.
    float3 halo = float3(1.0, 0.12, 0.35) * 0.35 * exp(-max(dist - 0.95, 0.0) * 3.0)
        * (1.0 - smoothstep(1.2, 1.75, dist));
    if (dist >= 1.0) return float4(halo, 0);
    float y = 0.02, thickness = 0.035;
    for (int i = 0; i < 8 && y < 1.0; i++) {
        if (d.y >= y && d.y < y + thickness) return float4(halo, 0);
        y += thickness + 0.115;
        thickness *= 1.55;
    }
    float t = saturate((d.y + 1.0) * 0.5);
    float3 yellow = float3(1.0, 0.85, 0.23), orange = float3(1.0, 0.27, 0.044),
           magenta = float3(1.0, 0.018, 0.28);
    float3 sunColor = t < 0.5 ? mix(yellow, orange, t * 2) : mix(orange, magenta, (t - 0.5) * 2);
    float coverage = smoothstep(1.0, 0.985, dist);
    // Bright enough to bloom, not so bright the tone map bleaches it: at 2.2
    // the disc came out near-white and lost the orange and magenta that make
    // it a synthwave sun rather than a light.
    return float4(sunColor * 1.15 * coverage, coverage);
}
