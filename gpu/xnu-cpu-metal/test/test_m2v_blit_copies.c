// SPDX-License-Identifier: GPL-2.0-or-later
// The blit encoder's copies the CPU device did not make, through libxnu_m2v alone (no plugin, no shaders):
// 1. copyFromTexture:toTexture: over five pairs of textures: which level and slice of the source each level and slice of
//    the destination holds afterwards (the pairs and the answers are Metal's, measured on an Apple GPU).
// 2. copyFromTexture:sourceSlice:sourceLevel:toTexture:destinationSlice:destinationLevel:sliceCount:levelCount:.
// 3. The copies between a buffer and a texture with MTLBlitOptionNone.
// 4. MTLBlitOptionStencilFromDepthStencil and DepthFromDepthStencil: the stencil of a Depth32Float_Stencil8 texture read
//    into a buffer and written from one, the depth read beside it.
// 5. An option Metal does not have is refused.
//
//   clang -O2 -Idist/m2v/include test/test_m2v_blit_copies.c -Ldist/m2v/lib -lxnu_m2v -Wl,-rpath,dist/m2v/lib -o build/t
//   build/t dist/lavapipe/lib/libvulkan.1.dylib dist/lavapipe/share/vulkan/icd.d/lvp_icd.aarch64.json
//
// Arguments: [Vulkan loader] [ICD JSON] [shader cache directory], each optional or "" (then the system's loader and drivers).
#include <stdio.h>
#include <string.h>
#include "xnu_m2v.h"

enum { T2D = 2, T2D_ARRAY = 3, TCUBE = 5, RGBA8 = 70, DEPTH32F_STENCIL8 = 260 };
enum { STORE = 1, CLEAR = 2, OPT_NONE = 0, OPT_DEPTH = 1, OPT_STENCIL = 2 };

static Xm2vDevice *dev;
static Xm2vQueue *q;
static int fails;

static void result(int n, int ok, const char *what) {
    printf("%s [%d/5]: %s", ok ? "PASS" : "FAIL", n, what);
    if (!ok && xm2v_last_error()[0]) printf(" (the bridge's last error: %s)", xm2v_last_error());
    printf("\n");
    fails += !ok;
}
typedef struct { uint64_t type, side, levels, layers; } Shape;   // layers: array slices, or 1 for a cube (6 slices)
static uint64_t slices_of(const Shape *s) { return s->type == TCUBE ? 6 : s->layers; }
static Xm2vTexture *texture(const Shape *s, uint64_t format) {
    Xm2vTextureDesc td = {0};
    td.texture_type = s->type; td.pixel_format = format; td.width = td.height = s->side; td.depth = 1;
    td.mipmap_level_count = s->levels; td.sample_count = 1; td.array_length = s->layers; td.usage = 1 | 4;   // ShaderRead | RenderTarget
    return xm2v_texture_new(dev, &td);
}
// Every texel of level l of slice s holds (tag, s, l, 255): tag 0xA0 marks a source, 0 an untouched destination.
static bool fill(Xm2vTexture *t, const Shape *sh, uint8_t tag) {
    uint8_t px[8 * 8 * 4];
    for (uint64_t s = 0; s < slices_of(sh); s++) for (uint64_t l = 0; l < sh->levels; l++) {
        uint64_t w = sh->side >> l;
        for (uint64_t i = 0; i < w * w; i++) { px[i * 4] = tag; px[i * 4 + 1] = tag ? (uint8_t)s : 0; px[i * 4 + 2] = tag ? (uint8_t)l : 0; px[i * 4 + 3] = tag ? 255 : 0; }
        if (!xm2v_texture_replace_region(t, 0, 0, 0, w, w, 1, l, s, px, w * 4, 0)) return false;
    }
    return true;
}
// What level l of slice s of t holds: -1 untouched, else source slice * 16 + source level; -2 anything else.
static int holds(Xm2vTexture *t, const Shape *sh, uint64_t s, uint64_t l) {
    uint8_t px[8 * 8 * 4]; memset(px, 0x77, sizeof px);
    uint64_t w = sh->side >> l;
    if (!xm2v_texture_get_bytes(t, px, w * 4, 0, 0, 0, 0, w, w, 1, l, s)) return -2;
    for (uint64_t i = 1; i < w * w; i++) if (memcmp(px, px + i * 4, 4)) return -2;
    if (!px[0] && !px[1] && !px[2] && !px[3]) return -1;
    return px[0] == 0xA0 && px[3] == 255 ? px[1] * 16 + px[2] : -2;
}
static bool run(Xm2vCommandBuffer *cb, Xm2vBlitEncoder *enc, bool ok) {
    if (enc) ok = xm2v_blit_encoder_end(enc) && ok;
    ok = ok && xm2v_command_buffer_commit(cb) && xm2v_command_buffer_wait_until_completed(cb, 0) && xm2v_command_buffer_status(cb) == 4;
    xm2v_command_buffer_release(cb);
    return ok;
}
// [blit copyFromTexture:src toTexture:dst]: the destination's (slice, level) must hold the source's (slice, level + shift)
// for the first `levels` levels from `first` of the first `slices` slices, and be untouched elsewhere.
static bool whole_copy(const char *what, Shape ssh, Shape dsh, uint64_t first, int shift, uint64_t levels, uint64_t slices) {
    Xm2vTexture *src = texture(&ssh, RGBA8), *dst = texture(&dsh, RGBA8);
    bool ok = src && dst && fill(src, &ssh, 0xA0) && fill(dst, &dsh, 0);
    Xm2vCommandBuffer *cb = xm2v_command_buffer_new(q);
    Xm2vBlitEncoder *enc = xm2v_blit_encoder_new(cb);
    ok = run(cb, enc, ok && enc && xm2v_blit_encoder_copy_texture(enc, src, dst));
    for (uint64_t s = 0; ok && s < slices_of(&dsh); s++) for (uint64_t l = 0; ok && l < dsh.levels; l++) {
        int want = s < slices && l >= first && l < first + levels ? (int)(s * 16 + l) + shift : -1, got = holds(dst, &dsh, s, l);
        if (got != want) {
            printf("    %s: the destination's slice %llu level %llu holds %d, Metal's holds %d (-1 untouched, else source slice * 16 + level)\n",
                   what, (unsigned long long)s, (unsigned long long)l, got, want);
            ok = false;
        }
    }
    if (src) xm2v_texture_release(src);
    if (dst) xm2v_texture_release(dst);
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

    // 1. Levels pair from the first two of one size; as many levels and slices as both have; a cube's six faces are slices.
    bool ok = whole_copy("2D 8x8, 3 levels -> the same", (Shape){T2D, 8, 3, 1}, (Shape){T2D, 8, 3, 1}, 0, 0, 3, 1);
    ok = whole_copy("2D array of 3, 2 levels -> array of 2", (Shape){T2D_ARRAY, 8, 2, 3}, (Shape){T2D_ARRAY, 8, 2, 2}, 0, 0, 2, 2) && ok;
    ok = whole_copy("2D 8x8, 4 levels -> 4x4, 2 levels", (Shape){T2D, 8, 4, 1}, (Shape){T2D, 4, 2, 1}, 0, 1, 2, 1) && ok;
    ok = whole_copy("2D 4x4, 2 levels -> 8x8, 4 levels", (Shape){T2D, 4, 2, 1}, (Shape){T2D, 8, 4, 1}, 1, -1, 2, 1) && ok;
    ok = whole_copy("cube 4x4, 2 levels -> the same", (Shape){TCUBE, 4, 2, 1}, (Shape){TCUBE, 4, 2, 1}, 0, 0, 2, 6) && ok;
    result(1, ok, "copyFromTexture:toTexture: copies the levels and slices two textures share");

    // 2. sourceSlice:1 sourceLevel:1 ... destinationSlice:0 destinationLevel:1 sliceCount:2 levelCount:2, arrays of 3 and of 2
    Shape ssh = {T2D_ARRAY, 8, 3, 3}, dsh = {T2D_ARRAY, 8, 3, 2};
    Xm2vTexture *src = texture(&ssh, RGBA8), *dst = texture(&dsh, RGBA8);
    ok = src && dst && fill(src, &ssh, 0xA0) && fill(dst, &dsh, 0);
    Xm2vCommandBuffer *cb = xm2v_command_buffer_new(q);
    Xm2vBlitEncoder *enc = xm2v_blit_encoder_new(cb);
    ok = run(cb, enc, ok && enc && xm2v_blit_encoder_copy_texture_slices(enc, src, 1, 1, dst, 0, 1, 2, 2));
    for (uint64_t s = 0; ok && s < 2; s++) for (uint64_t l = 0; ok && l < 3; l++) {
        int want = l >= 1 ? (int)((s + 1) * 16 + l) : -1, got = holds(dst, &dsh, s, l);
        if (got != want) { printf("    the destination's slice %llu level %llu holds %d, Metal's holds %d\n", (unsigned long long)s, (unsigned long long)l, got, want); ok = false; }
    }
    result(2, ok, "the form with sliceCount: and levelCount: copies those slices and levels");

    // 3. texture -> buffer -> texture with MTLBlitOptionNone (level 0 of slice 2 of the source, into level 0 of slice 1)
    Xm2vBuffer *buf = xm2v_buffer_new(dev, 256, 0, NULL);
    cb = xm2v_command_buffer_new(q);
    enc = xm2v_blit_encoder_new(cb);
    ok = src && dst && buf && enc && xm2v_blit_encoder_copy_texture_to_buffer(enc, src, 2, 0, 0, 0, 0, 8, 8, 1, buf, 0, 32, 256, OPT_NONE)
        && xm2v_blit_encoder_copy_buffer_to_texture(enc, buf, 0, 32, 256, 8, 8, 1, dst, 1, 0, 0, 0, 0, OPT_NONE);
    ok = run(cb, enc, ok) && holds(dst, &dsh, 1, 0) == 2 * 16 + 0 && holds(dst, &dsh, 0, 0) == -1;
    result(3, ok, "texture to buffer to texture with MTLBlitOptionNone");
    if (src) xm2v_texture_release(src);
    if (dst) xm2v_texture_release(dst);

    // 4. A 4x4 Depth32Float_Stencil8 texture cleared to depth 0.25, stencil 7: the two planes into a buffer, 9s into the stencil.
    Shape ds_shape = {T2D, 4, 1, 1};
    Xm2vTexture *ds = texture(&ds_shape, DEPTH32F_STENCIL8);
    Xm2vRenderPassDesc rd; memset(&rd, 0, sizeof rd);
    rd.color_attachment_count = 8;
    rd.depth_texture = ds; rd.depth_load_action = CLEAR; rd.depth_store_action = STORE; rd.clear_depth = 0.25;
    rd.stencil_texture = ds; rd.stencil_load_action = CLEAR; rd.stencil_store_action = STORE; rd.clear_stencil = 7;
    cb = xm2v_command_buffer_new(q);
    Xm2vRenderEncoder *renc = ds ? xm2v_render_encoder_new(cb, &rd) : NULL;
    ok = renc && xm2v_render_encoder_end(renc);
    ok = run(cb, NULL, ok);
    Xm2vBuffer *sb = xm2v_buffer_new(dev, 64, 0, NULL), *db = xm2v_buffer_new(dev, 64, 0, NULL), *nine = xm2v_buffer_new(dev, 16, 0, NULL);
    uint8_t *sp = sb ? xm2v_buffer_contents(sb) : NULL; float *dp = db ? xm2v_buffer_contents(db) : NULL;
    ok = ok && sp && dp && nine;
    if (ok) { memset(sp, 0xEE, 64); memset(dp, 0xEE, 64); memset(xm2v_buffer_contents(nine), 9, 16); }
    cb = xm2v_command_buffer_new(q);
    enc = xm2v_blit_encoder_new(cb);
    ok = ok && enc && xm2v_blit_encoder_copy_texture_to_buffer(enc, ds, 0, 0, 0, 0, 0, 4, 4, 1, sb, 0, 4, 16, OPT_STENCIL)
        && xm2v_blit_encoder_copy_texture_to_buffer(enc, ds, 0, 0, 0, 0, 0, 4, 4, 1, db, 0, 16, 64, OPT_DEPTH);
    ok = run(cb, enc, ok);
    if (ok && (sp[0] != 7 || sp[15] != 7 || sp[16] != 0xEE || dp[0] != 0.25f || dp[15] != 0.25f)) {
        printf("    the stencil plane read %02x %02x (7 7), the byte after it %02x (ee); the depth plane read %.2f (0.25)\n", sp[0], sp[15], sp[16], dp[0]);
        ok = false;
    }
    cb = xm2v_command_buffer_new(q);
    enc = xm2v_blit_encoder_new(cb);
    ok = ok && enc && xm2v_blit_encoder_copy_buffer_to_texture(enc, nine, 0, 4, 16, 4, 4, 1, ds, 0, 0, 0, 0, 0, OPT_STENCIL)
        && xm2v_blit_encoder_copy_texture_to_buffer(enc, ds, 0, 0, 0, 0, 0, 4, 4, 1, sb, 0, 4, 16, OPT_STENCIL)
        && xm2v_blit_encoder_copy_texture_to_buffer(enc, ds, 0, 0, 0, 0, 0, 4, 4, 1, db, 0, 16, 64, OPT_DEPTH);
    ok = run(cb, enc, ok);
    if (ok && (sp[0] != 9 || sp[15] != 9 || dp[0] != 0.25f)) {
        printf("    after 9s were copied into the stencil it reads %02x (9), the depth %.2f (0.25)\n", sp[0], dp[0]);
        ok = false;
    }
    result(4, ok, "the stencil and the depth of a depth/stencil texture read and written by their MTLBlitOption");

    // 5. Not an MTLBlitOption (8), and both aspects at once (Metal's validation: "cannot both be set").
    cb = xm2v_command_buffer_new(q);
    enc = xm2v_blit_encoder_new(cb);
    ok = enc && ds && sb && !xm2v_blit_encoder_copy_texture_to_buffer(enc, ds, 0, 0, 0, 0, 0, 4, 4, 1, sb, 0, 4, 16, 8)
        && !xm2v_blit_encoder_copy_texture_to_buffer(enc, ds, 0, 0, 0, 0, 0, 4, 4, 1, sb, 0, 4, 16, OPT_DEPTH | OPT_STENCIL)
        && !xm2v_blit_encoder_copy_buffer_to_texture(enc, sb, 0, 4, 16, 4, 4, 1, ds, 0, 0, 0, 0, 0, 8);
    ok = run(cb, enc, ok);
    // (the last error is one of the refusals asked for, so it is not printed here)
    printf("%s [5/5]: a blit option Metal does not have is refused\n", ok ? "PASS" : "FAIL");
    fails += !ok;

    if (ds) xm2v_texture_release(ds);
    if (!fails) printf("ALL BRIDGE BLIT COPY TESTS PASSED\n");
    return fails ? 1 : 0;
}
