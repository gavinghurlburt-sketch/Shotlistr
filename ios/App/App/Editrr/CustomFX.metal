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
