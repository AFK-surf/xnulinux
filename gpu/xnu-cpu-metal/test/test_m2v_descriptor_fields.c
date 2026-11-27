// SPDX-License-Identifier: GPL-2.0-or-later
// Descriptor fields Metal honours that the bridge's structs did not carry, through libxnu_m2v alone (no plugin):
// 1. depthAttachment.slice: one slice of a depth array (a shadow cascade), one face of a depth cube.
// 2. depthAttachment.level: one mip level of a depth texture.
// 3. stencilAttachment.level and .slice.
// 4. colorAttachments[0].depthPlane: one plane of a 3D texture.
// 5. MTLSamplerDescriptor.borderColor: what ClampToBorderColor samples outside the texture (needs border_probe.metallib).
//    Metal makes a sampler of any raw value: 3, which names no colour, samples transparent black.
// Each pass only clears its attachment; the other subresources must keep what they held.
//
//   xcrun -sdk macosx metal -c test/border_probe.metal -o build/border_probe.air
//   xcrun -sdk macosx metallib build/border_probe.air -o build/border_probe.metallib
//   clang -O2 -Idist/m2v/include test/test_m2v_descriptor_fields.c -Ldist/m2v/lib -lxnu_m2v -Wl,-rpath,dist/m2v/lib -o build/t
//   build/t dist/lavapipe/lib/libvulkan.1.dylib dist/lavapipe/share/vulkan/icd.d/lvp_icd.aarch64.json "" build/border_probe.metallib
//
// Arguments: [Vulkan loader] [ICD JSON] [shader cache directory] [border_probe.metallib], each optional or "" (the system's
// loader and drivers, no cache, test 5 skipped).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "xnu_m2v.h"

enum { T2D = 2, T2D_ARRAY = 3, TCUBE = 5, T3D = 7, RGBA8 = 70, DEPTH32F = 252, STENCIL8 = 253 };
enum { STORE = 1, CLEAR = 2, CLAMP_TO_BORDER_COLOR = 5, OPAQUE_BLACK = 1, OPAQUE_WHITE = 2 };

static Xm2vDevice *dev;
static Xm2vQueue *q;
static int fails;

static void result(int n, int ok, const char *what) {
    printf("%s [%d/5]: %s", ok ? "PASS" : "FAIL", n, what);
    if (!ok && xm2v_last_error()[0]) printf(" (the bridge's last error: %s)", xm2v_last_error());
    printf("\n");
    fails += !ok;
}
static Xm2vTexture *texture(uint64_t type, uint64_t format, uint64_t depth, uint64_t levels, uint64_t layers) {
    Xm2vTextureDesc td = {0};
    td.texture_type = type; td.pixel_format = format; td.width = td.height = 4; td.depth = depth;
    td.mipmap_level_count = levels; td.sample_count = 1; td.array_length = layers; td.usage = 1 | 4;   // ShaderRead | RenderTarget
    return xm2v_texture_new(dev, &td);
}
static bool pass(const Xm2vRenderPassDesc *rd) {
    Xm2vCommandBuffer *cb = xm2v_command_buffer_new(q);
    Xm2vRenderEncoder *enc = xm2v_render_encoder_new(cb, rd);
    bool ok = enc && xm2v_render_encoder_end(enc) && xm2v_command_buffer_commit(cb)
        && xm2v_command_buffer_wait_until_completed(cb, 0) && xm2v_command_buffer_status(cb) == 4;
    xm2v_command_buffer_release(cb);
    return ok;
}
// Every texel of one level of one slice, as floats (a depth) or bytes (a stencil).
static bool fill_depth(Xm2vTexture *t, uint64_t level, uint64_t slice, float v) {
    float px[16]; for (int i = 0; i < 16; i++) px[i] = v;
    return xm2v_texture_replace_region(t, 0, 0, 0, 4 >> level, 4 >> level, 1, level, slice, px, (4 >> level) * 4, 0);
}
static float depth_of(Xm2vTexture *t, uint64_t level, uint64_t slice) {
    float px[16]; for (int i = 0; i < 16; i++) px[i] = -1;
    return xm2v_texture_get_bytes(t, px, (4 >> level) * 4, 0, 0, 0, 0, 4 >> level, 4 >> level, 1, level, slice) ? px[0] : -2;
}
static int stencil_of(Xm2vTexture *t, uint64_t level, uint64_t slice) {
    uint8_t px[16]; memset(px, 0xEE, sizeof px);
    return xm2v_texture_get_bytes(t, px, 4 >> level, 0, 0, 0, 0, 4 >> level, 4 >> level, 1, level, slice) ? px[0] : -2;
}
// Clears the depth of d at (level, slice) to 0.25 where every subresource holds 0.5: only that one may change.
static bool depth_pass_writes_only(Xm2vTexture *d, uint64_t levels, uint64_t slices, uint64_t level, uint64_t slice) {
    bool ok = d != NULL;
    for (uint64_t s = 0; ok && s < slices; s++) for (uint64_t l = 0; ok && l < levels; l++) ok = fill_depth(d, l, s, 0.5f);
    Xm2vRenderPassDesc rd; memset(&rd, 0, sizeof rd);
    rd.color_attachment_count = 8;
    rd.depth_texture = d; rd.depth_level = level; rd.depth_slice = slice;
    rd.depth_load_action = CLEAR; rd.depth_store_action = STORE; rd.clear_depth = 0.25;
    ok = ok && pass(&rd);
    for (uint64_t s = 0; ok && s < slices; s++) for (uint64_t l = 0; ok && l < levels; l++)
        if (depth_of(d, l, s) != (l == level && s == slice ? 0.25f : 0.5f)) {
            printf("    level %llu slice %llu holds %.2f after a pass that cleared level %llu slice %llu to 0.25\n",
                   (unsigned long long)l, (unsigned long long)s, depth_of(d, l, s), (unsigned long long)level, (unsigned long long)slice);
            ok = false;
        }
    if (d) xm2v_texture_release(d);
    return ok;
}
static void *slurp(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(2); }
    fseek(f, 0, SEEK_END); *len = (size_t)ftell(f); fseek(f, 0, SEEK_SET);
    void *p = malloc(*len);
    if (fread(p, 1, *len, f) != *len) exit(2);
    fclose(f);
    return p;
}

int main(int argc, char **argv) {
    const char *arg[4] = {0};
    for (int i = 0; i < 4; i++) arg[i] = argc > i + 1 && argv[i + 1][0] ? argv[i + 1] : NULL;
    dev = xm2v_device_open(arg[0], arg[1], arg[2]);
    if (!dev) { fprintf(stderr, "FAIL: no device: %s\n", xm2v_last_error()); return 1; }
    char name[128] = ""; xm2v_device_name(dev, name, sizeof name);
    printf("Device: %s\n", name);
    q = xm2v_queue_new(dev);
    Xm2vRenderPassDesc rd;

    // 1. depthAttachment.slice = 1 of a 2-slice array; = 3 (the -x... face order's fourth) of a cube
    bool ok = depth_pass_writes_only(texture(T2D_ARRAY, DEPTH32F, 1, 1, 2), 1, 2, 0, 1);
    ok = depth_pass_writes_only(texture(TCUBE, DEPTH32F, 1, 1, 1), 1, 6, 0, 3) && ok;
    result(1, ok, "a depth attachment's slice: slice 1 of an array, face 3 of a cube");

    // 2. depthAttachment.level = 1 of a 3-level texture
    result(2, depth_pass_writes_only(texture(T2D, DEPTH32F, 1, 3, 1), 3, 1, 1, 0), "a depth attachment's level");

    // 3. stencilAttachment.level = 1, .slice = 1 of a 2-level, 2-slice Stencil8 array, cleared to 7 where all held 0
    Xm2vTexture *s = texture(T2D_ARRAY, STENCIL8, 1, 2, 2);
    uint8_t zero[128] = {0}, px[128];
    ok = s != NULL;
    for (uint64_t sl = 0; ok && sl < 2; sl++) for (uint64_t l = 0; ok && l < 2; l++)
        ok = xm2v_texture_replace_region(s, 0, 0, 0, 4 >> l, 4 >> l, 1, l, sl, zero, 4 >> l, 0);
    memset(&rd, 0, sizeof rd);
    rd.color_attachment_count = 8;
    rd.stencil_texture = s; rd.stencil_level = 1; rd.stencil_slice = 1;
    rd.stencil_load_action = CLEAR; rd.stencil_store_action = STORE; rd.clear_stencil = 7;
    ok = ok && pass(&rd);
    for (uint64_t sl = 0; ok && sl < 2; sl++) for (uint64_t l = 0; ok && l < 2; l++)
        if (stencil_of(s, l, sl) != (l == 1 && sl == 1 ? 7 : 0)) {
            printf("    level %llu slice %llu holds stencil %d after a pass that cleared level 1 slice 1 to 7\n",
                   (unsigned long long)l, (unsigned long long)sl, stencil_of(s, l, sl));
            ok = false;
        }
    result(3, ok, "a stencil attachment's level and slice");
    if (s) xm2v_texture_release(s);

    // 4. colorAttachments[0].depthPlane = 1 of a 4 x 4 x 2 3D texture, cleared to white where both planes held 0
    Xm2vTexture *c = texture(T3D, RGBA8, 2, 1, 1);
    ok = c && xm2v_texture_replace_region(c, 0, 0, 0, 4, 4, 2, 0, 0, zero, 16, 64);
    memset(&rd, 0, sizeof rd);
    rd.color_attachment_count = 8;
    rd.color_attachments[0].texture = c; rd.color_attachments[0].depth_plane = 1;
    rd.color_attachments[0].load_action = CLEAR; rd.color_attachments[0].store_action = STORE;
    rd.color_attachments[0].clear_r = rd.color_attachments[0].clear_g = rd.color_attachments[0].clear_b = rd.color_attachments[0].clear_a = 1.0;
    ok = ok && pass(&rd);
    memset(px, 0x77, sizeof px);
    ok = ok && xm2v_texture_get_bytes(c, px, 16, 64, 0, 0, 0, 4, 4, 2, 0, 0);
    if (ok && (px[0] != 0 || px[63] != 0 || px[64] != 255 || px[127] != 255)) {
        printf("    plane 0 holds red %u, plane 1 red %u after a pass that cleared plane 1 to white\n", px[0], px[64]);
        ok = false;
    }
    result(4, ok, "a colour attachment's depth plane");
    if (c) xm2v_texture_release(c);

    // 5. sAddressMode = tAddressMode = ClampToBorderColor over a texture whose texels are all 0.2: OpaqueBlack, OpaqueWhite, then 3
    if (!arg[3]) {
        printf("SKIP [5/5]: a sampler's border colour (no border_probe.metallib given)\n");
    } else {
        size_t len; void *ml = slurp(arg[3], &len);
        Xm2vLibrary *lib = xm2v_library_new_with_data(dev, ml, len);
        Xm2vFunction *fn = lib ? xm2v_library_new_function(lib, "border_probe") : NULL;
        Xm2vComputePipeline *pso = fn ? xm2v_compute_pipeline_new(dev, fn) : NULL;
        Xm2vTextureDesc td = {0};
        td.texture_type = T2D; td.pixel_format = RGBA8; td.width = td.height = 2; td.depth = 1;
        td.mipmap_level_count = 1; td.sample_count = 1; td.array_length = 1; td.usage = 1;
        Xm2vTexture *t = xm2v_texture_new(dev, &td);
        memset(px, 0x33, 16);
        ok = pso && t && xm2v_texture_replace_region(t, 0, 0, 0, 2, 2, 1, 0, 0, px, 8, 0);
        for (uint64_t color = OPAQUE_BLACK; ok && color <= 3; color++) {
            Xm2vSamplerDesc sd; memset(&sd, 0, sizeof sd);
            sd.s_address_mode = sd.t_address_mode = sd.r_address_mode = CLAMP_TO_BORDER_COLOR;
            sd.border_color = color;
            sd.max_anisotropy = 1; sd.lod_max_clamp = 3.4028235e38f; sd.normalized_coordinates = true;
            Xm2vSampler *smp = xm2v_sampler_new(dev, &sd);
            Xm2vBuffer *out = xm2v_buffer_new(dev, 48, 0, NULL);
            Xm2vCommandBuffer *cb = xm2v_command_buffer_new(q);
            Xm2vComputeEncoder *enc = smp && out && cb ? xm2v_compute_encoder_new(cb) : NULL;
            ok = enc && xm2v_compute_encoder_set_pipeline(enc, pso) && xm2v_compute_encoder_set_texture(enc, t, 0)
                && xm2v_compute_encoder_set_sampler(enc, smp, 0) && xm2v_compute_encoder_set_buffer(enc, out, 0, 0)
                && xm2v_compute_encoder_dispatch_threads(enc, 3, 1, 1, 3, 1, 1) && xm2v_compute_encoder_end(enc)
                && xm2v_command_buffer_commit(cb) && xm2v_command_buffer_wait_until_completed(cb, 0);
            const float *v = ok ? xm2v_buffer_contents(out) : NULL;
            const float rgb = color == OPAQUE_WHITE ? 1.0f : 0.0f, a = color == 3 ? 0.0f : 1.0f;
            const float want[3][4] = { {rgb, rgb, rgb, a}, {0.2f, 0.2f, 0.2f, 0.2f}, {rgb, rgb, rgb, a} };   // left of, in, right of
            for (int i = 0; ok && i < 3; i++) for (int ch = 0; ch < 4; ch++)
                if (v[i * 4 + ch] < want[i][ch] - 0.01f || v[i * 4 + ch] > want[i][ch] + 0.01f) {
                    printf("    border colour %llu: sample %d is %.2f %.2f %.2f %.2f, Metal's is %.2f %.2f %.2f %.2f\n", (unsigned long long)color, i,
                           v[i * 4], v[i * 4 + 1], v[i * 4 + 2], v[i * 4 + 3], want[i][0], want[i][1], want[i][2], want[i][3]);
                    ok = false; break;
                }
            if (cb) xm2v_command_buffer_release(cb);
        }
        result(5, ok, "ClampToBorderColor samples the sampler's border colour (OpaqueBlack, OpaqueWhite, 3 as transparent black)");
    }
    if (!fails) printf("ALL BRIDGE DESCRIPTOR FIELD TESTS PASSED\n");
    return fails ? 1 : 0;
}
