// SPDX-License-Identifier: GPL-2.0-or-later
// Arguments Metal takes that the bridge refused, through libxnu_m2v alone (no plugin, no shaders):
// 1. replaceRegion: and getBytes: of one row with bytesPerRow 0.
// 2. A PVRTC level, which Metal takes at no bytesPerRow but 0, written and read back (the first level and the 1 x 1 one).
// 3. A render pass whose descriptor leaves its store actions MTLStoreActionUnknown: the encoder sets them before it ends.
// 4. MTLStoreActionCustomSampleDepthStore on a depth attachment, which stores as Store does.
// 5. What stays refused: a store action Metal does not have, CustomSampleDepthStore on a colour attachment (Metal asserts),
//    and Unknown set on the encoder.
//
//   clang -O2 -Idist/m2v/include test/test_m2v_refused_arguments.c -Ldist/m2v/lib -lxnu_m2v -Wl,-rpath,dist/m2v/lib -o build/t
//   build/t dist/lavapipe/lib/libvulkan.1.dylib dist/lavapipe/share/vulkan/icd.d/lvp_icd.aarch64.json
//
// Arguments: [Vulkan loader] [ICD JSON] [shader cache directory], each optional or "" (then the system's loader and drivers).
#include <stdio.h>
#include <string.h>
#include "xnu_m2v.h"

enum { T2D = 2, RGBA8 = 70, PVRTC_RGBA_4BPP = 166, DEPTH32F = 252, STENCIL8 = 253 };
enum { DONT_CARE = 0, STORE = 1, CLEAR = 2, UNKNOWN = 4, CUSTOM_SAMPLE_DEPTH_STORE = 5 };

static Xm2vDevice *dev;
static Xm2vQueue *q;
static int fails;

static void result(int n, int ok, const char *what) {
    printf("%s [%d/5]: %s", ok ? "PASS" : "FAIL", n, what);
    if (!ok && xm2v_last_error()[0]) printf(" (the bridge's last error: %s)", xm2v_last_error());
    printf("\n");
    fails += !ok;
}
static Xm2vTexture *texture(uint64_t format, uint64_t side, uint64_t levels) {
    Xm2vTextureDesc td = {0};
    td.texture_type = T2D; td.pixel_format = format; td.width = td.height = side; td.depth = 1;
    td.mipmap_level_count = levels; td.sample_count = 1; td.array_length = 1;
    td.usage = format == PVRTC_RGBA_4BPP ? 1 : 1 | 4;   // ShaderRead, and RenderTarget
    return xm2v_texture_new(dev, &td);
}
// One pass over the attachments of rd, nothing drawn; late = the store action the encoder sets where the descriptor says Unknown.
static bool pass(const Xm2vRenderPassDesc *rd, uint64_t late) {
    Xm2vCommandBuffer *cb = xm2v_command_buffer_new(q);
    Xm2vRenderEncoder *enc = xm2v_render_encoder_new(cb, rd);
    bool ok = enc != NULL;
    if (ok && rd->color_attachments[0].store_action == UNKNOWN) ok = xm2v_render_encoder_set_color_store_action(enc, late, 0);
    if (ok && rd->depth_texture && rd->depth_store_action == UNKNOWN) ok = xm2v_render_encoder_set_depth_store_action(enc, late);
    if (ok && rd->stencil_texture && rd->stencil_store_action == UNKNOWN) ok = xm2v_render_encoder_set_stencil_store_action(enc, late);
    if (enc) ok = xm2v_render_encoder_end(enc) && ok;
    ok = ok && xm2v_command_buffer_commit(cb) && xm2v_command_buffer_wait_until_completed(cb, 0) && xm2v_command_buffer_status(cb) == 4;
    xm2v_command_buffer_release(cb);
    return ok;
}

int main(int argc, char **argv) {
    const char *arg[3] = {0};
    for (int i = 0; i < 3; i++) arg[i] = argc > i + 1 && argv[i + 1][0] ? argv[i + 1] : NULL;
    dev = xm2v_device_open(arg[0], arg[1], arg[2]);
    if (!dev) { fprintf(stderr, "FAIL: no device: %s\n", xm2v_last_error()); return 1; }
    char name[128] = ""; xm2v_device_name(dev, name, sizeof name);
    printf("Device: %s\n", name);
    q = xm2v_queue_new(dev);
    uint8_t in[64], out[64], zero[64] = {0};
    for (int i = 0; i < 64; i++) in[i] = (uint8_t)(i + 1);

    // 1. [t replaceRegion:MTLRegionMake2D(0, 2, 4, 1) mipmapLevel:0 withBytes:in bytesPerRow:0], and the row read back the same way
    Xm2vTexture *t = texture(RGBA8, 4, 1);
    bool ok = t && xm2v_texture_replace_region(t, 0, 0, 0, 4, 4, 1, 0, 0, zero, 16, 0)
        && xm2v_texture_replace_region(t, 0, 2, 0, 4, 1, 1, 0, 0, in, 0, 0);
    memset(out, 0xEE, sizeof out);
    ok = ok && xm2v_texture_get_bytes(t, out, 16, 0, 0, 0, 0, 4, 4, 1, 0, 0) && !memcmp(out + 32, in, 16) && !memcmp(out, zero, 32);
    memset(out, 0xEE, sizeof out);
    ok = ok && xm2v_texture_get_bytes(t, out, 0, 0, 0, 2, 0, 4, 1, 1, 0, 0) && !memcmp(out, in, 16) && out[16] == 0xEE;
    result(1, ok, "one row written and read with bytesPerRow 0");
    xm2v_texture_release(t);

    // 2. PVRTC_RGBA_4BPP 8 x 8, 4 levels: 2 x 2 blocks of 8 bytes, then one block a level. bytesPerRow 0, bytesPerImage 0.
    t = texture(PVRTC_RGBA_4BPP, 8, 4);
    ok = t && xm2v_texture_replace_region(t, 0, 0, 0, 8, 8, 1, 0, 0, in, 0, 0)
        && xm2v_texture_replace_region(t, 0, 0, 0, 1, 1, 1, 3, 0, in + 32, 0, 0);
    memset(out, 0xEE, sizeof out);
    ok = ok && xm2v_texture_get_bytes(t, out, 0, 0, 0, 0, 0, 8, 8, 1, 0, 0) && !memcmp(out, in, 32) && out[32] == 0xEE;
    memset(out, 0xEE, sizeof out);
    ok = ok && xm2v_texture_get_bytes(t, out, 0, 0, 0, 0, 0, 1, 1, 1, 3, 0) && !memcmp(out, in + 32, 8) && out[8] == 0xEE;
    result(2, ok, "a PVRTC level written and read (bytesPerRow 0, the only one Metal takes for it)");
    xm2v_texture_release(t);

    // 3. Colour cleared to white, depth to 0.25, stencil to 7, every store action Unknown in the descriptor and Store on the encoder.
    Xm2vTexture *c = texture(RGBA8, 4, 1), *d = texture(DEPTH32F, 4, 1), *s = texture(STENCIL8, 4, 1);
    float half[16], depth[16];
    for (int i = 0; i < 16; i++) half[i] = 0.5f;
    ok = c && d && s && xm2v_texture_replace_region(c, 0, 0, 0, 4, 4, 1, 0, 0, zero, 16, 0)
        && xm2v_texture_replace_region(d, 0, 0, 0, 4, 4, 1, 0, 0, half, 16, 0)
        && xm2v_texture_replace_region(s, 0, 0, 0, 4, 4, 1, 0, 0, zero, 4, 0);
    Xm2vRenderPassDesc rd; memset(&rd, 0, sizeof rd);
    rd.color_attachment_count = 8;
    rd.color_attachments[0].texture = c; rd.color_attachments[0].load_action = CLEAR; rd.color_attachments[0].store_action = UNKNOWN;
    rd.color_attachments[0].clear_r = rd.color_attachments[0].clear_g = rd.color_attachments[0].clear_b = rd.color_attachments[0].clear_a = 1.0;
    rd.depth_texture = d; rd.depth_load_action = CLEAR; rd.depth_store_action = UNKNOWN; rd.clear_depth = 0.25;
    ok = ok && pass(&rd, STORE);
    memset(out, 0, sizeof out); memset(depth, 0, sizeof depth);
    ok = ok && xm2v_texture_get_bytes(c, out, 16, 0, 0, 0, 0, 4, 4, 1, 0, 0) && out[0] == 255 && out[63] == 255
        && xm2v_texture_get_bytes(d, depth, 16, 0, 0, 0, 0, 4, 4, 1, 0, 0) && depth[0] == 0.25f && depth[15] == 0.25f;
    memset(&rd, 0, sizeof rd);
    rd.color_attachment_count = 8;
    rd.stencil_texture = s; rd.stencil_load_action = CLEAR; rd.stencil_store_action = UNKNOWN; rd.clear_stencil = 7;
    ok = ok && pass(&rd, STORE);
    memset(out, 0, sizeof out);
    ok = ok && xm2v_texture_get_bytes(s, out, 4, 0, 0, 0, 0, 4, 4, 1, 0, 0) && out[0] == 7 && out[15] == 7;
    result(3, ok, "store actions left Unknown by the descriptor and set to Store on the encoder: colour, depth and stencil kept");

    // 4. depthAttachment.storeAction = MTLStoreActionCustomSampleDepthStore: Metal stores the depth as Store does.
    memset(&rd, 0, sizeof rd);
    rd.color_attachment_count = 8;
    rd.depth_texture = d; rd.depth_load_action = CLEAR; rd.depth_store_action = CUSTOM_SAMPLE_DEPTH_STORE; rd.clear_depth = 0.75;
    ok = d && pass(&rd, STORE);
    memset(depth, 0, sizeof depth);
    ok = ok && xm2v_texture_get_bytes(d, depth, 16, 0, 0, 0, 0, 4, 4, 1, 0, 0) && depth[0] == 0.75f && depth[15] == 0.75f;
    result(4, ok, "a depth attachment stored with CustomSampleDepthStore");

    // 5. Still refused, each with an error and without a crash.
    Xm2vCommandBuffer *cb = xm2v_command_buffer_new(q);
    memset(&rd, 0, sizeof rd);
    rd.color_attachment_count = 8;
    rd.color_attachments[0].texture = c; rd.color_attachments[0].load_action = CLEAR; rd.color_attachments[0].store_action = 6;
    Xm2vRenderEncoder *enc = xm2v_render_encoder_new(cb, &rd);
    ok = !enc;
    if (enc) xm2v_render_encoder_end(enc);
    rd.color_attachments[0].store_action = CUSTOM_SAMPLE_DEPTH_STORE;
    enc = xm2v_render_encoder_new(cb, &rd);
    ok = ok && !enc;
    if (enc) xm2v_render_encoder_end(enc);
    rd.color_attachments[0].store_action = UNKNOWN;
    enc = xm2v_render_encoder_new(cb, &rd);
    ok = ok && enc && !xm2v_render_encoder_set_color_store_action(enc, UNKNOWN, 0) && xm2v_render_encoder_set_color_store_action(enc, DONT_CARE, 0);
    if (enc) ok = xm2v_render_encoder_end(enc) && ok;
    xm2v_command_buffer_release(cb);
    // (the last error is one of the refusals asked for, so it is not printed here)
    printf("%s [5/5]: a store action Metal does not have, CustomSampleDepthStore on colour and a late Unknown are refused\n", ok ? "PASS" : "FAIL");
    fails += !ok;

    xm2v_texture_release(c); xm2v_texture_release(d); xm2v_texture_release(s);
    if (!fails) printf("ALL BRIDGE ARGUMENT TESTS PASSED\n");
    return fails ? 1 : 0;
}
