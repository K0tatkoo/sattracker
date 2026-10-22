// The globe's shaders: the three.js scene of the Android page, redrawn in
// Metal. Colours are plain sRGB values computed in sRGB, as three.js r147 does
// with its default (linear-less) output, so the palette lands on screen exactly
// as the hex values in Palette.swift.
#include <metal_stdlib>
using namespace metal;

/// Per-frame values. The Swift twin is GlobeRenderer.FrameUniforms; keep the
/// two in the same order (simd types share Metal's sizes and alignments).
struct Frame {
    float4x4 viewProj;
    float4x4 view;
    float4x4 proj;
    float2 viewport;      // drawable, pixels
    float pxPerPt;        // UIKit points to pixels
    float halfHeight;     // viewport.y / 2
    float3 lampDir;       // to the lamp, view space
    float ambient;
    float lamp;
    float time;
    float plinthScale;
};

// ---- Earth -----------------------------------------------------------------

struct EarthVertex {
    packed_float3 pos;
    packed_float2 uv;
};

struct EarthOut {
    float4 position [[position]];
    float3 normal;
    float2 uv;
};

vertex EarthOut earthVertex(uint vid [[vertex_id]],
                            const device EarthVertex *v [[buffer(0)]],
                            constant Frame &f [[buffer(1)]],
                            constant float &radius [[buffer(2)]]) {
    float3 p = float3(v[vid].pos);
    EarthOut o;
    o.position = f.viewProj * float4(p * radius, 1);
    o.normal = (f.view * float4(p, 0)).xyz;
    o.uv = float2(v[vid].uv);
    return o;
}

/// MeshLambertMaterial: the repainted map under an ambient light and one lamp
/// that rides on the camera, top left.
fragment float4 earthFragment(EarthOut in [[stage_in]],
                              constant Frame &f [[buffer(1)]],
                              texture2d<float> map [[texture(0)]],
                              sampler s [[sampler(0)]]) {
    float3 albedo = map.sample(s, in.uv).rgb;
    float ndl = max(dot(normalize(in.normal), f.lampDir), 0.0);
    return float4(albedo * (f.ambient + f.lamp * ndl), 1);
}

/// The atmosphere: the back of a slightly larger sphere, brightest at the
/// Earth's rim (the page's shader, dark theme only).
fragment float4 atmosphereFragment(EarthOut in [[stage_in]],
                                   constant float4 &color [[buffer(0)]]) {
    float i = pow(max(0.62 - dot(in.normal, float3(0, 0, 1)), 0.0), 3.0);
    return float4(color.rgb * 0.85 * i, i);
}

// ---- The raised globe ------------------------------------------------------

struct PlinthOut {
    float4 position [[position]];
    float2 p;
};

/// A camera-facing square through the Earth's centre, 3.4 across, scaled to the
/// sphere's true silhouette so the shadow rim holds at every zoom.
vertex PlinthOut plinthVertex(uint vid [[vertex_id]], constant Frame &f [[buffer(1)]]) {
    const float2 corners[6] = { {-1, -1}, {1, -1}, {-1, 1}, {-1, 1}, {1, -1}, {1, 1} };
    float2 c = corners[vid] * 1.7;
    float4 centre = f.view * float4(0, 0, 0, 1);
    PlinthOut o;
    o.position = f.proj * float4(centre.xy + c * f.plinthScale, centre.z, 1);
    o.p = c;
    return o;
}

struct PlinthColors {
    float4 dark;     // rgb, and the alpha of the whole shadow
    float4 light;
};

/// The card shadow pair of every n3d surface: dark bottom-right, light top-left.
fragment float4 plinthFragment(PlinthOut in [[stage_in]], constant PlinthColors &c [[buffer(0)]]) {
    const float off = 0.07, blur = 0.15;
    float d = 1.0 - smoothstep(1.0 - blur, 1.0 + blur, length(in.p - float2(off, -off)));
    float l = 1.0 - smoothstep(1.0 - blur, 1.0 + blur, length(in.p - float2(-off, off)));
    float a = d + l * (1.0 - d);
    if (a < 0.002) discard_fragment();
    float3 col = (c.dark.rgb * d + c.light.rgb * l * (1.0 - d)) / a;
    return float4(col, a * c.dark.a);
}

// ---- Lines: the graticule and the selected satellite's orbit ---------------

struct Segment {
    packed_float3 a;
    packed_float3 b;
    packed_float4 ca;
    packed_float4 cb;
};

struct LineOut {
    float4 position [[position]];
    float4 color;
};

/// A segment drawn as a screen-space quad `width` points wide (a WebGL line is
/// always one pixel, which on a 3× screen is a hair). Clipped to the near
/// plane first, so an orbit passing behind the camera does not flip.
vertex LineOut lineVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          const device Segment *segs [[buffer(0)]],
                          constant Frame &f [[buffer(1)]],
                          constant float4 &tint [[buffer(2)]],
                          constant float &widthPt [[buffer(3)]]) {
    Segment s = segs[iid];
    float4 a = f.viewProj * float4(float3(s.a), 1);
    float4 b = f.viewProj * float4(float3(s.b), 1);
    float4 ca = float4(s.ca), cb = float4(s.cb);
    const float near = 1e-3;
    LineOut o;
    if (a.w < near && b.w < near) {
        o.position = float4(0, 0, -2, 1);
        o.color = 0;
        return o;
    }
    if (a.w < near) { float t = (near - a.w) / (b.w - a.w); a = mix(a, b, t); ca = mix(ca, cb, t); }
    if (b.w < near) { float t = (near - b.w) / (a.w - b.w); b = mix(b, a, t); cb = mix(cb, ca, t); }

    const float2 corner[6] = { {0, -1}, {1, -1}, {0, 1}, {0, 1}, {1, -1}, {1, 1} };
    float2 k = corner[vid];
    float2 dir = (b.xy / b.w - a.xy / a.w) * f.viewport;
    float len = length(dir);
    float2 n = len > 1e-5 ? float2(-dir.y, dir.x) / len : float2(0, 1);
    float px = widthPt * f.pxPerPt;
    float fade = 1.0;
    if (px < 1.0) { fade = px; px = 1.0; }     // thinner than a pixel: a fainter pixel
    float4 p = k.x < 0.5 ? a : b;
    p.xy += n * k.y * px / f.viewport * p.w;
    o.position = p;
    float4 c = (k.x < 0.5 ? ca : cb) * tint;
    c.a *= fade;
    o.color = c;
    return o;
}

fragment float4 lineFragment(LineOut in [[stage_in]]) {
    return in.color;
}

// ---- Sprites: satellites, the ring, you, the stars -------------------------

struct Sprite {
    packed_float3 pos;
    float size;
    packed_float4 color;
    uint shape;
    uint sizing;
};

enum SpriteShape : uint {
    SHAPE_SOFT = 0,    // the dark theme's satellite dot: solid core, soft edge
    SHAPE_SOLID = 1,   // a plain disc with an anti-aliased edge
    SHAPE_RING = 2,    // the selection ring
    SHAPE_GLOW = 3,    // stars and nebulae: bright core, long halo
};

enum SpriteSizing : uint {
    SIZE_POINTS = 0,       // `size` is in points, whatever the distance
    SIZE_ATTENUATED = 1,   // three.js Points with sizeAttenuation
    SIZE_WORLD = 2,        // three.js Sprite: world units, in perspective
};

struct SpriteOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
    float pxSize;
    uint shape [[flat]];
};

vertex SpriteOut spriteVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              const device Sprite *sprites [[buffer(0)]],
                              constant Frame &f [[buffer(1)]]) {
    Sprite s = sprites[iid];
    float4 c = f.viewProj * float4(float3(s.pos), 1);
    SpriteOut o;
    if (c.w <= 1e-4) {
        o.position = float4(0, 0, -2, 1);
        o.color = 0; o.uv = 0; o.pxSize = 0; o.shape = 0;
        return o;
    }
    float px;
    if (s.sizing == SIZE_POINTS) px = s.size * f.pxPerPt;
    else if (s.sizing == SIZE_ATTENUATED) px = s.size * f.halfHeight / c.w;
    else px = s.size * f.proj[1][1] * f.halfHeight / c.w;
    const float2 corners[6] = { {-1, -1}, {1, -1}, {-1, 1}, {-1, 1}, {1, -1}, {1, 1} };
    float2 k = corners[vid];
    c.xy += k * px / f.viewport * c.w;
    o.position = c;
    o.color = float4(s.color);
    o.uv = k;
    o.pxSize = px;
    o.shape = s.shape;
    return o;
}

/// A radial ramp through (r, alpha) stops, as a canvas gradient draws it.
static float ramp(float r, const float2 stops[5]) {
    for (int i = 1; i < 5; i++) {
        if (r <= stops[i].x) {
            float t = (r - stops[i - 1].x) / (stops[i].x - stops[i - 1].x);
            return mix(stops[i - 1].y, stops[i].y, t);
        }
    }
    return 0;
}

fragment float4 spriteFragment(SpriteOut in [[stage_in]]) {
    float r = length(in.uv);
    if (r > 1.0) discard_fragment();
    float aa = 2.0 / max(in.pxSize, 1.0);    // one pixel, in uv units
    float a;
    if (in.shape == SHAPE_SOFT) {
        const float2 stops[5] = { {0, 1}, {0.42, 1}, {0.55, 0.5}, {0.78, 0.12}, {1, 0} };
        a = ramp(r, stops);
    } else if (in.shape == SHAPE_SOLID) {
        a = 1.0 - smoothstep(0.84375 - aa, 0.84375 + aa * 0.5, r);
    } else if (in.shape == SHAPE_RING) {
        float halfWidth = 0.0625;
        a = 1.0 - smoothstep(halfWidth - aa * 0.5, halfWidth + aa * 0.5, abs(r - 0.875));
    } else {
        const float2 stops[5] = { {0, 1}, {0.18, 1}, {0.32, 0.65}, {0.60, 0.18}, {1, 0} };
        a = ramp(r, stops);
    }
    return float4(in.color.rgb, in.color.a * a);
}
