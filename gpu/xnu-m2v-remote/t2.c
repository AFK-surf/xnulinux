// SPDX-License-Identifier: GPL-2.0-or-later
// Buffers both ways, textures and pipelines through libxnu_m2v (the real one or the remote one).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "xnu_m2v.h"
#define WK extern unsigned long __attribute__((weak))
WK xm2v_remote_answers; WK xm2v_remote_bytes_out; WK xm2v_remote_bytes_in; WK xm2v_remote_buffer_bytes; WK xm2v_remote_hashed;
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static int fails;
#define CK(x) do { if (!(x)) { fprintf(stderr, "FAILED: %s: %s\n", #x, xm2v_last_error()); return 1; } } while (0)
#define EXPECT(x, ...) do { if (!(x)) { fails++; printf("WRONG: %s: ", #x); printf(__VA_ARGS__); printf("\n"); } } while (0)
static void counters(const char *what) { if (&xm2v_remote_answers) printf("  [%s: %lu answers, %lu bytes out (%lu of buffers), %lu in, %lu hashed]\n", what, xm2v_remote_answers, xm2v_remote_bytes_out, xm2v_remote_buffer_bytes, xm2v_remote_bytes_in, xm2v_remote_hashed); }
int main(int argc, char **argv) {
    Xm2vDevice *dev = xm2v_device_open(argv[1], argv[2], "/tmp/m2v-cache"); CK(dev);
    char name[256]; xm2v_device_name(dev, name, sizeof name); printf("device: %s\n", name);
    uint64_t tg[3]; CK(xm2v_device_max_threads_per_threadgroup(dev, tg)); printf("max threads %lu %lu %lu, max buffer %lu\n", (unsigned long)tg[0], (unsigned long)tg[1], (unsigned long)tg[2], (unsigned long)xm2v_device_max_buffer_length(dev));
    FILE *f = fopen(argv[3], "rb"); CK(f); static unsigned char lb[1 << 20]; size_t ln = fread(lb, 1, sizeof lb, f); fclose(f);
    Xm2vLibrary *lib = xm2v_library_new_with_data(dev, lb, ln); CK(lib);
    size_t nf = xm2v_library_function_count(lib); printf("functions:");
    for (size_t i = 0; i < nf; i++) { char n[128]; xm2v_library_function_name_at(lib, i, n, sizeof n); printf(" %s", n); }
    printf("\n");
    EXPECT(xm2v_library_new_function(lib, "no_such_function") == 0, "a function that is not there was made");
    Xm2vQueue *q = xm2v_queue_new(dev); CK(q);

    // 1. compute: the GPU writes a buffer, the CPU reads it; then the CPU changes one input and it is seen
    enum { N = 100000 };
    Xm2vFunction *kf = xm2v_library_new_function(lib, "vecadd"); CK(kf);
    Xm2vComputePipeline *cp = xm2v_compute_pipeline_new(dev, kf); CK(cp);
    Xm2vBuffer *a = xm2v_buffer_new(dev, N * 4, 0, 0), *b = xm2v_buffer_new(dev, N * 4, 0, 0), *o = xm2v_buffer_new(dev, N * 4, 0, 0); CK(a && b && o);
    float *pa = xm2v_buffer_contents(a), *pb = xm2v_buffer_contents(b), *po = xm2v_buffer_contents(o);
    for (int i = 0; i < N; i++) { pa[i] = i; pb[i] = 2 * i; }
    for (int round = 0; round < 3; round++) {
        if (round == 1) pa[77777] = 5;	// one page
        if (round == 2) po[5] = -1;	// the CPU writes where the GPU will
        Xm2vCommandBuffer *cb = xm2v_command_buffer_new(q); CK(cb);
        Xm2vComputeEncoder *e = xm2v_compute_encoder_new(cb); CK(e);
        CK(xm2v_compute_encoder_set_pipeline(e, cp));
        CK(xm2v_compute_encoder_set_buffer(e, a, 0, 0)); CK(xm2v_compute_encoder_set_buffer(e, b, 0, 1)); CK(xm2v_compute_encoder_set_buffer(e, o, 0, 2));
        CK(xm2v_compute_encoder_dispatch_threads(e, N, 1, 1, 64, 1, 1));
        CK(xm2v_compute_encoder_end(e));
        EXPECT(xm2v_command_buffer_status(cb) == 0, "status before commit %u", xm2v_command_buffer_status(cb));
        CK(xm2v_command_buffer_commit(cb));
        CK(xm2v_command_buffer_wait_until_completed(cb, 0));
        EXPECT(xm2v_command_buffer_status(cb) == 4, "status %u", xm2v_command_buffer_status(cb));
        int bad = 0; for (int i = 0; i < N; i++) { float want = (round && i == 77777 ? 5 : i) + 2.0f * i; if (po[i] != want) bad++; }
        EXPECT(bad == 0, "round %d: %d of %d sums wrong (out[1]=%g out[77777]=%g)", round, bad, N, po[1], po[77777]);
        xm2v_command_buffer_release(cb);
        char w[32]; snprintf(w, sizeof w, "compute round %d", round); counters(w);
    }

    // 2. render: vertices and a tint from buffers, a texture filled from memory, read back
    enum { W = 256, H = 256 };
    Xm2vFunction *vs = xm2v_library_new_function(lib, "vb_vertex"), *fs = xm2v_library_new_function(lib, "vb_fragment"); CK(vs && fs);
    Xm2vVertexAttribute at[2] = { { 0, 29, 0, 1 }, { 1, 30, 8, 1 } };	// float2, float3 in buffer 1
    Xm2vVertexLayout lay[1] = { { 1, 20, 1, 1, false } };
    Xm2vRenderPipelineDesc pd; memset(&pd, 0, sizeof pd);
    pd.vertex_function = vs; pd.fragment_function = fs; pd.color_attachment_count = 1;
    pd.color_attachments[0].pixel_format = 80; pd.color_attachments[0].write_mask = 15; pd.sample_count = 1;
    pd.vertex_attributes = at; pd.vertex_attribute_count = 2; pd.vertex_layouts = lay; pd.vertex_layout_count = 1;
    Xm2vRenderPipeline *pso = xm2v_render_pipeline_new(dev, &pd); CK(pso);
    Xm2vTextureDesc td = { 2, 80, W, H, 1, 1, 1, 1, 16, 5 };
    Xm2vTexture *target = xm2v_texture_new(dev, &td); CK(target);
    Xm2vTextureDesc sd = { 2, 80, 4, 4, 1, 1, 1, 1, 16, 1 };
    Xm2vTexture *src = xm2v_texture_new(dev, &sd); CK(src);
    unsigned char texel[4 * 4 * 4]; for (int i = 0; i < 16; i++) { texel[i * 4] = 64; texel[i * 4 + 1] = 0; texel[i * 4 + 2] = 0; texel[i * 4 + 3] = 0; }	// bgra: blue 64
    CK(xm2v_texture_replace_region(src, 0, 0, 0, 4, 4, 1, 0, 0, texel, 16, 0));
    Xm2vSamplerDesc smd; memset(&smd, 0, sizeof smd); smd.max_anisotropy = 1; smd.lod_max_clamp = 1000; smd.normalized_coordinates = true;
    Xm2vSampler *samp = xm2v_sampler_new(dev, &smd); CK(samp);
    Xm2vBuffer *vb = xm2v_buffer_new(dev, 3 * 20, 0, 0), *ub = xm2v_buffer_new(dev, 16, 0, 0); CK(vb && ub);
    float verts[15] = { -1, -1, 1, 1, 1,   3, -1, 1, 1, 1,   -1, 3, 1, 1, 1 };	// covers the target, white
    memcpy(xm2v_buffer_contents(vb), verts, sizeof verts);
    float *tint = xm2v_buffer_contents(ub);
    static unsigned char px[W * H * 4];
    for (int round = 0; round < 2; round++) {
        tint[0] = round ? 0 : 0.5f; tint[1] = round ? 1 : 0; tint[2] = 0; tint[3] = 1;	// rgb
        Xm2vCommandBuffer *cb = xm2v_command_buffer_new(q); CK(cb);
        Xm2vRenderPassDesc rp; memset(&rp, 0, sizeof rp);
        rp.color_attachment_count = 1; rp.color_attachments[0].texture = target; rp.color_attachments[0].load_action = 2; rp.color_attachments[0].store_action = 1;
        Xm2vRenderEncoder *e = xm2v_render_encoder_new(cb, &rp); CK(e);
        CK(xm2v_render_encoder_set_pipeline(e, pso)); CK(xm2v_render_encoder_set_viewport(e, 0, 0, W, H, 0, 1));
        CK(xm2v_render_encoder_set_vertex_buffer(e, vb, 0, 1));
        if (round == 0) CK(xm2v_render_encoder_set_fragment_buffer(e, ub, 0, 0)); else CK(xm2v_render_encoder_set_fragment_bytes(e, tint, 16, 0));
        CK(xm2v_render_encoder_set_fragment_texture(e, src, 0)); CK(xm2v_render_encoder_set_fragment_sampler(e, samp, 0));
        CK(xm2v_render_encoder_draw_primitives(e, 3, 0, 3, 1, 0));
        CK(xm2v_render_encoder_end(e)); CK(xm2v_command_buffer_commit(cb));
        CK(xm2v_command_buffer_wait_until_completed(cb, 0));
        CK(xm2v_texture_get_bytes(target, px, W * 4, 0, 0, 0, 0, W, H, 1, 0, 0));
        unsigned char *c = px + (H / 2 * W + W / 2) * 4; int wr = round ? 0 : 128, wg = round ? 255 : 0;
        EXPECT(abs(c[2] - wr) <= 2 && abs(c[1] - wg) <= 2 && abs(c[0] - 64) <= 2, "round %d: centre rgb %d %d %d, wanted %d %d 64", round, c[2], c[1], c[0], wr, wg);
        xm2v_command_buffer_release(cb);
    }
    counters("render");

    // 3. many frames, not waited for
    int frames = argc > 4 ? atoi(argv[4]) : 1000; double t0 = now();
    for (int i = 0; i < frames; i++) {
        tint[0] = (i & 255) / 255.0f;
        Xm2vCommandBuffer *cb = xm2v_command_buffer_new(q);
        Xm2vRenderPassDesc rp; memset(&rp, 0, sizeof rp);
        rp.color_attachment_count = 1; rp.color_attachments[0].texture = target; rp.color_attachments[0].load_action = 2; rp.color_attachments[0].store_action = 1;
        Xm2vRenderEncoder *e = xm2v_render_encoder_new(cb, &rp);
        xm2v_render_encoder_set_pipeline(e, pso); xm2v_render_encoder_set_viewport(e, 0, 0, W, H, 0, 1);
        xm2v_render_encoder_set_vertex_buffer(e, vb, 0, 1); xm2v_render_encoder_set_fragment_buffer(e, ub, 0, 0);
        xm2v_render_encoder_set_fragment_texture(e, src, 0); xm2v_render_encoder_set_fragment_sampler(e, samp, 0);
        for (int k = 0; k < 100; k++) xm2v_render_encoder_draw_primitives(e, 3, 0, 3, 1, 0);
        xm2v_render_encoder_end(e); xm2v_command_buffer_commit(cb);
        if (i == frames - 1) CK(xm2v_command_buffer_wait_until_completed(cb, 0));
        xm2v_command_buffer_release(cb);
    }
    printf("%d frames of 100 draws: %.3f ms each\n", frames, (now() - t0) * 1e3 / frames); counters("frames");
    xm2v_buffer_release(a); xm2v_buffer_release(b); xm2v_buffer_release(o); xm2v_texture_release(src);
    printf(fails ? "%d WRONG\n" : "all as expected\n", fails);
    return fails != 0;
}
