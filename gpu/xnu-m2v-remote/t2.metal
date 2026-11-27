// SPDX-License-Identifier: GPL-2.0-or-later
#include <metal_stdlib>
using namespace metal;
struct VIn { float2 pos [[attribute(0)]]; float3 color [[attribute(1)]]; };
struct VOut { float4 pos [[position]]; float3 color; };
struct U { float4 tint; };
vertex VOut vb_vertex(VIn in [[stage_in]]) { VOut o; o.pos = float4(in.pos, 0, 1); o.color = in.color; return o; }
fragment float4 vb_fragment(VOut in [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
    return float4(in.color, 1) * u.tint + t.sample(s, float2(0.5, 0.5));
}
kernel void vecadd(device const float *a [[buffer(0)]], device const float *b [[buffer(1)]], device float *out [[buffer(2)]], uint id [[thread_position_in_grid]]) {
    out[id] = a[id] + b[id];
}
