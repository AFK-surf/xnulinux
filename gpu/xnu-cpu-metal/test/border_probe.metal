// SPDX-License-Identifier: GPL-2.0-or-later
#include <metal_stdlib>
using namespace metal;

// For test_m2v_descriptor_fields.c: samples src left of, inside and right of [0, 1] through the sampler bound at 0.
kernel void border_probe(
    texture2d<float, access::sample> src [[texture(0)]],
    sampler smp                          [[sampler(0)]],
    device float4 *out                   [[buffer(0)]],
    uint id                              [[thread_position_in_grid]])
{
    const float u[3] = { -0.5f, 0.5f, 1.5f };
    out[id] = src.sample(smp, float2(u[id], 0.5f), level(0.0f));
}
