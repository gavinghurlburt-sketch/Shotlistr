// Custom effects, written as Core Image shaders. Each function here shows up under Custom in
// the effects sheet once it has an entry in CustomFX.all (Effects.swift).
//
// They are "stitchable" Core Image kernels. The target links them against Core Image
// (Other Metal Linker Flags: -framework CoreImage).

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>

extern "C" {
namespace coreimage {

/// Splits red and blue apart sideways, like a cheap lens or a glitchy screen.
[[ stitchable ]] float4 rgbSplit(sampler src, float shift, destination dest) {
    float2 at = dest.coord();
    float4 middle = src.sample(src.transform(at));
    float red = src.sample(src.transform(at + float2(shift, 0))).r;
    float blue = src.sample(src.transform(at - float2(shift, 0))).b;
    return float4(red, middle.g, blue, middle.a);
}

/// A round fisheye lens. Inside the circle the picture bulges out from the middle, gets color
/// fringes, an out of focus blur and a blue tint toward the rim, with a thin bright blue rim line.
/// Outside it, a dark matte with a soft blue glow. `center` and `radius` are in frame pixels;
/// `amount` (0...1) is how strong. Matches the mockup's math (it runs on sRGB colors).
[[ stitchable ]] float4 fisheye(sampler src, float2 center, float radius, float amount, destination dest) {
    float2 px = dest.coord();
    float2 d = (px - center) / radius;
    float r = length(d);
    float2 dir = r > 0.0001 ? d / r : float2(0.0);
    float k = 0.2 + 0.45 * amount;
    float rim = 1.0 + 0.45 * amount;
    float rr = min(r, 1.03);
    float f = rr * (1.0 - k + k * rr * rr) * rim;
    float ca = 0.02 * amount * smoothstep(0.62, 1.0, r);
    float spread = (2.0 + 26.0 * amount) * smoothstep(0.7, 1.0, r) * radius / 380.0;
    float3 col = float3(0.0);
    for (int i = 0; i < 9; i++) {
        float a = float(i) * 0.7854;
        float2 o = i == 8 ? float2(0.0) : float2(cos(a), sin(a)) * spread;
        float rch = src.sample(src.transform(center + dir * f * (1.0 + ca) * radius + o)).r;
        float gch = src.sample(src.transform(center + dir * f * radius + o)).g;
        float bch = src.sample(src.transform(center + dir * f * (1.0 - ca) * radius + o)).b;
        col += float3(rch, gch, bch);
    }
    col /= 9.0;
    float3 blue = float3(0.22, 0.5, 1.0);
    float tint = smoothstep(0.72, 1.0, r) * (0.45 + 0.55 * amount);
    col = mix(col, col * 0.5 + blue * 0.45, tint * 0.75);
    col *= 1.0 - 0.3 * smoothstep(0.55, 1.0, r);
    float ringAt = (r - 0.995) / 0.018;
    col += blue * 0.55 * exp(-ringAt * ringAt);
    float3 bg = float3(0.012, 0.016, 0.04) + blue * (0.18 + 0.2 * amount) * exp(-max(r - 1.0, 0.0) * 9.0);
    float inside = 1.0 - smoothstep(0.99, 1.008, r);
    return float4(mix(bg, col, inside), 1.0);
}

}
}

// Lyrics: Lyric Sync's chromatic aberration. Red is taken from one side, blue from the other, and
// the text keeps the widest outline of the three.
extern "C" { namespace coreimage {
[[ stitchable ]] float4 lyricSplit(sampler src, float2 shift, destination dest) {
    float2 at = dest.coord();
    float4 r = src.sample(src.transform(at + shift));
    float4 g = src.sample(src.transform(at));
    float4 b = src.sample(src.transform(at - shift));
    return float4(r.r, g.g, b.b, max(max(r.a, g.a), b.a));
}
}}
