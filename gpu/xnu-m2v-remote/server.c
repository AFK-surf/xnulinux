// SPDX-License-Identifier: GPL-2.0-or-later
// xm2v-server: the renderer's end of proto.h. Takes libxnu_m2v's calls from a connection and makes them on the real
// library, on this machine's Vulkan driver. A process for each connection (each is one Metal device of one process on
// the other machine).
//
// usage: xm2v-server [ADDRESS:]PORT LOADER ICD_JSON [CACHE_DIR]
//
// It listens on 127.0.0.1 unless told an address: whoever can connect draws on this machine's GPU and reads what the
// others' frames hold, and nothing on the way is encrypted. For a network where every machine is trusted.
//
// Calls are made in the order they arrive, on one thread; the two that wait for the GPU (wait_until_completed, a shared
// event's wait) run on a thread of their own, so that what they wait for can still arrive.
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include "xnu_m2v.h"
#include "proto.h"

struct sbuf { Xm2vBuffer *buf; uint8_t *mem; uint64_t len, opts, *hash; int refs; bool released; };	// what the client has of a buffer
struct sarg { uint64_t buf_id, base; };	// an argument encoder's argument buffer

static int fd;
static const char *loader, *icd, *cache = "/tmp/m2v-cache";
static void **obj; static struct sbuf **sbufs; static struct sarg *sargs; static size_t nobj;
static pthread_mutex_t wr_mu = PTHREAD_MUTEX_INITIALIZER;	// answers
static pthread_mutex_t buf_mu = PTHREAD_MUTEX_INITIALIZER;	// buffers' contents and fingerprints
static unsigned long st_msgs, st_bytes, st_answers, st_op[OP_COUNT], st_fail, st_changed, st_whole;
static bool stats;

static uint8_t rbuf[1 << 20]; static size_t rpos, rlen;
static void rd(void *p, size_t n) {
    while (n) {
        if (rpos < rlen) { size_t k = rlen - rpos < n ? rlen - rpos : n; memcpy(p, rbuf + rpos, k); rpos += k; p = (char *)p + k; n -= k; continue; }
        ssize_t r = n >= sizeof rbuf ? recv(fd, p, n, 0) : recv(fd, rbuf, sizeof rbuf, 0);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) _exit(0);	// the client is gone
        st_bytes += r;
        if (n >= sizeof rbuf) { p = (char *)p + r; n -= r; } else { rpos = 0; rlen = r; }
    }
}
static void answer2(uint64_t req, const void *a, uint64_t an, const void *b, uint64_t bn) {
    struct xr_ans h = { req, an + bn };
    struct iovec iov[3] = { { &h, sizeof h }, { (void *)a, an }, { (void *)b, bn } };
    pthread_mutex_lock(&wr_mu);
    for (int i = 0; i < 3; i++) {
        const char *p = iov[i].iov_base; size_t n = iov[i].iov_len;
        while (n) { ssize_t r = send(fd, p, n, MSG_NOSIGNAL); if (r < 0 && errno == EINTR) continue; if (r <= 0) _exit(0); p += r; n -= r; }
    }
    st_answers++;
    pthread_mutex_unlock(&wr_mu);
}
static void sv_answer(uint64_t req, const void *p, uint64_t n) { answer2(req, p, n, 0, 0); }
static void sv_answer_u64(uint64_t req, uint64_t v) { sv_answer(req, &v, 8); }
// What a message holds is read through these: nothing past its end (sv_end). A message that is too short for what it
// says sets sv_bad, reads as zeroes, and its call is not made.
static uint8_t *sv_end; static bool sv_bad;
static uint8_t sv_zero[4096];
static uint64_t sv_left(uint8_t *m) { return (uint64_t)(sv_end - m); }
static void *sv_blob(uint8_t **m, uint64_t n) {
    uint64_t padded = (n + 7) & ~7ull;
    if (n > sv_left(*m)) { sv_bad = true; return n <= sizeof sv_zero ? sv_zero : 0; }
    void *p = *m; *m += padded <= sv_left(*m) ? padded : n; return p;
}
static uint64_t sv_u64(uint8_t **m) { uint64_t v = 0; if (sv_left(*m) < 8) { sv_bad = true; return 0; } memcpy(&v, *m, 8); *m += 8; return v; }
static double sv_f64(uint8_t **m) { double v = 0; if (sv_left(*m) < 8) { sv_bad = true; return 0; } memcpy(&v, *m, 8); *m += 8; return v; }
static const char *sv_str(uint8_t **m) {
    uint64_t n = sv_u64(m);
    if (n == ~0ull || sv_bad) return 0;
    if (!n || n > sv_left(*m) || (*m)[n - 1]) { sv_bad = true; return ""; }
    return sv_blob(m, n);
}
// A count of things of `each` bytes that the rest of the message can hold.
static uint64_t sv_count(uint8_t **m, uint64_t each) { uint64_t n = sv_u64(m); if (n > sv_left(*m) / each) { sv_bad = true; return 0; } return n; }
static void *sv_obj(uint64_t id) { return id < nobj ? obj[id] : 0; }
enum { SV_MAX_ID = 1 << 24 };	// the client reuses the ids of what it releases: more live objects than this is not a client
static void sv_set(uint64_t id, void *p) {
    if (id >= SV_MAX_ID) { if (p) fprintf(stderr, "[%d] object id %llu\n", getpid(), (unsigned long long)id); return; }
    if (id >= nobj) {
        size_t n = nobj ? nobj : 4096; while (n <= id) n *= 2;
        obj = realloc(obj, n * sizeof *obj); sbufs = realloc(sbufs, n * sizeof *sbufs); sargs = realloc(sargs, n * sizeof *sargs);
        memset(obj + nobj, 0, (n - nobj) * sizeof *obj); memset(sbufs + nobj, 0, (n - nobj) * sizeof *sbufs); memset(sargs + nobj, 0, (n - nobj) * sizeof *sargs);
        nobj = n;
    }
    obj[id] = p;
}
static void sv_fail(uint32_t op) { if (st_fail++ < 200) fprintf(stderr, "[%d] %s failed: %s\n", getpid(), op_names[op], xm2v_last_error()); }
static void sv_short(uint32_t op) { if (st_fail++ < 200) fprintf(stderr, "[%d] %s: the message is shorter than what it says\n", getpid(), op_names[op]); }
static void sv_null(uint32_t op, int arg) { if (st_fail++ < 200) fprintf(stderr, "[%d] %s: argument %d is not an object\n", getpid(), op_names[op], arg); }

static uint64_t pages(uint64_t len) { return (len + XR_PAGE - 1) / XR_PAGE; }
static uint64_t page_len(const struct sbuf *b, uint64_t p) { uint64_t o = p * XR_PAGE; return b->len - o < XR_PAGE ? b->len - o : XR_PAGE; }
static void sbuf_unref(struct sbuf *b) {	// with buf_mu
    if (--b->refs > 0) return;
    if (b->released) { xm2v_buffer_release(b->buf); free(b->hash); free(b); }
}
// Appends the pages of a buffer that are not what the client has: (id, offset, length, bytes).
static void changed_pages(uint64_t id, struct sbuf *b, uint8_t **out, size_t *n, size_t *cap) {
    if (!b->mem) return;
    for (uint64_t i = 0, np = pages(b->len); i < np; i++) {
        uint64_t l = page_len(b, i), hsh = xr_hash(b->mem + i * XR_PAGE, l);
        if (hsh == b->hash[i]) continue;
        b->hash[i] = hsh;
        size_t need = 24 + ((l + 7) & ~7ull);
        if (*n + need > *cap) { *cap = (*cap + need) * 2; *out = realloc(*out, *cap); }
        uint64_t rec[3] = { id, i * XR_PAGE, l };
        memcpy(*out + *n, rec, 24); memcpy(*out + *n + 24, b->mem + i * XR_PAGE, l); memset(*out + *n + 24 + l, 0, -l & 7);
        *n += need;
    }
}
// The answer to a wait or a status: status, the error's text, the changed buffers.
static void answer_status(uint64_t req, Xm2vCommandBuffer *cb, uint64_t *ids, struct sbuf **bufs, uint64_t nb) {
    uint64_t head[2 + 32] = { xm2v_command_buffer_status(cb), 0 };
    if (head[0] == 5) { char *e = (char *)(head + 2); size_t l = xm2v_command_buffer_error(cb, e, 250); head[1] = l < 249 ? l : 249; }
    uint8_t *out = 0; size_t n = 0, cap = 0;
    pthread_mutex_lock(&buf_mu);
    for (uint64_t i = 0; i < nb; i++) { if (!bufs[i]->released) changed_pages(ids[i], bufs[i], &out, &n, &cap); sbuf_unref(bufs[i]); }
    pthread_mutex_unlock(&buf_mu);
    answer2(req, head, 16 + ((head[1] + 7) & ~7ull), out, n);
    free(out);
}
struct wait_job { uint64_t req, timeout, nb, *ids; struct sbuf **bufs; Xm2vCommandBuffer *cb; const Xm2vSharedEvent *ev; uint64_t value; };
static void *wait_thread(void *p) {
    struct wait_job *j = p;
    if (j->cb) { xm2v_command_buffer_wait_until_completed(j->cb, j->timeout); answer_status(j->req, j->cb, j->ids, j->bufs, j->nb); }
    else sv_answer_u64(j->req, xm2v_shared_event_wait_until(j->ev, j->value, j->timeout));
    free(j->ids); free(j->bufs); free(j);
    return 0;
}
static void start_wait(struct wait_job *j) {
    pthread_t t; pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 256 << 10); pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&t, &a, wait_thread, j)) wait_thread(j);
    pthread_attr_destroy(&a);
}
static void notified(void *ctx, uint64_t value) { uint64_t d[2] = { (uint64_t)(uintptr_t)ctx, value }; sv_answer(XR_CALLBACK, d, sizeof d); }
static Xm2vFunction **fn_list(uint8_t **m, uint32_t *n) {	// the caller's to free
    *n = (uint32_t)sv_count(m, 8);
    Xm2vFunction **f = calloc((size_t)*n + 1, sizeof *f);
    for (uint32_t i = 0; i < *n; i++) f[i] = sv_obj(sv_u64(m));
    return f;
}
static void *stats_thread(void *unused) {
    (void)unused;
    for (;;) {
        sleep(10);
        fprintf(stderr, "[%d] %lu messages, %lu bytes in, %lu answers:", getpid(), st_msgs, st_bytes, st_answers);
        for (int k = 0; k < 12; k++) { int best = 0; for (int i = 1; i < OP_COUNT; i++) if (st_op[i] > st_op[best]) best = i; if (!st_op[best]) break; fprintf(stderr, " %s %lu", op_names[best], st_op[best]); st_op[best] = 0; }
        if (st_whole) fprintf(stderr, "; read back %lu of %lu KB", st_changed >> 10, st_whole >> 10);
        fprintf(stderr, "\n"); st_msgs = st_bytes = st_answers = st_changed = st_whole = 0;
    }
    return 0;
}

static void serve(void) {
    size_t cap = 1 << 20; uint8_t *msg = aligned_alloc(64, cap);
    if (stats) { pthread_t t; pthread_create(&t, 0, stats_thread, 0); }
    for (;;) {
        struct xr_hdr h; rd(&h, sizeof h);
        if (h.len > XR_MAX_MSG) { fprintf(stderr, "[%d] a message of %llu bytes\n", getpid(), (unsigned long long)h.len); _exit(1); }
        if (h.len + 16 > cap) { free(msg); cap = (h.len + 4096 + 63) & ~63ull; msg = aligned_alloc(64, cap); if (!msg) { fprintf(stderr, "[%d] a message of %lu bytes\n", getpid(), (unsigned long)h.len); _exit(1); } }
        rd(msg, h.len); memset(msg + h.len, 0, 8);
        uint8_t *m = msg, *end = msg + h.len;
        sv_end = end; sv_bad = false;
        st_msgs++; if (h.op < OP_COUNT) st_op[h.op]++;
        switch (h.op) {
        case OP_xm2v_device_open: {
            uint64_t nid = sv_u64(&m), ver = sv_u64(&m);
            void *d = ver == XR_VERSION && !sv_bad ? xm2v_device_open(loader, icd, cache) : 0;
            if (!d) fprintf(stderr, "[%d] device_open (client version %lu): %s\n", getpid(), (unsigned long)ver, ver == XR_VERSION ? xm2v_last_error() : "version");
            sv_set(nid, d); sv_answer_u64(h.req, d != 0); break; }
        case OP_xm2v_last_error: { const char *e = xm2v_last_error(); sv_answer(h.req, e, e ? strlen(e) : 0); break; }
        case OP_xm2v_device_name: case OP_xm2v_library_function_name_at: case OP_xm2v_library_extern_function_name_at: {
            void *o = sv_obj(sv_u64(&m)); uint64_t i = sv_u64(&m); char s[1024]; size_t l = 0;
            if (o) l = h.op == OP_xm2v_device_name ? xm2v_device_name(o, s, sizeof s) : h.op == OP_xm2v_library_function_name_at ? xm2v_library_function_name_at(o, i, s, sizeof s) : xm2v_library_extern_function_name_at(o, i, s, sizeof s);
            sv_answer(h.req, s, l < sizeof s ? l : sizeof s - 1); break; }
        case OP_xm2v_device_max_threads_per_threadgroup: { uint64_t r[4] = { 0 }; void *o = sv_obj(sv_u64(&m)); r[0] = o && xm2v_device_max_threads_per_threadgroup(o, r + 1); sv_answer(h.req, r, sizeof r); break; }
        case OP_xm2v_pixel_format_is_ycbcr: sv_answer_u64(h.req, xm2v_pixel_format_is_ycbcr(sv_u64(&m))); break;
        case OP_xm2v_buffer_gpu_address: { void *o = sv_obj(sv_u64(&m)); sv_answer_u64(h.req, o ? xm2v_buffer_gpu_address(o) : 0); break; }
        case OP_xm2v_texture_gpu_resource_id: { void *o = sv_obj(sv_u64(&m)); sv_answer_u64(h.req, o ? xm2v_texture_gpu_resource_id(o) : 0); break; }
        case OP_xm2v_sampler_gpu_resource_id: { void *o = sv_obj(sv_u64(&m)); sv_answer_u64(h.req, o ? xm2v_sampler_gpu_resource_id(o) : 0); break; }

        case OP_xm2v_buffer_new: {
            uint64_t nid = sv_u64(&m), dev = sv_u64(&m), len = sv_u64(&m), opts = sv_u64(&m), aligned = sv_u64(&m), has = sv_u64(&m);
            void *d = sv_obj(dev);
            if (has && sv_left(m) < len) sv_bad = true;
            Xm2vBuffer *b = !d || sv_bad || nid >= SV_MAX_ID ? 0 : aligned ? xm2v_buffer_new_page_aligned(d, len, opts, has ? m : 0) : xm2v_buffer_new(d, len, opts, has ? m : 0);
            sv_set(nid, b);
            if (!b) { sv_fail(h.op); break; }
            struct sbuf *s = calloc(1, sizeof *s);
            s->buf = b; s->len = len; s->opts = opts; s->refs = 1; s->mem = ((opts >> 4) & 15) == 2 ? 0 : xm2v_buffer_contents(b);
            if (s->mem) {
                if (!has) memset(s->mem, 0, len);
                s->hash = malloc(pages(len) * 8);
                for (uint64_t i = 0, np = pages(len); i < np; i++) s->hash[i] = xr_hash(s->mem + i * XR_PAGE, page_len(s, i));
            }
            sbufs[nid] = s; break; }
        case OP_xm2v_buffer_release: {
            uint64_t id = sv_u64(&m); struct sbuf *s = id < nobj ? sbufs[id] : 0;
            if (!s) break;
            pthread_mutex_lock(&buf_mu); s->released = true; sbuf_unref(s); pthread_mutex_unlock(&buf_mu);
            sbufs[id] = 0; sv_set(id, 0); break; }
        case OP_BUFFER_WRITE: {
            uint64_t id = sv_u64(&m), off = sv_u64(&m), len = sv_u64(&m); struct sbuf *s = id < nobj ? sbufs[id] : 0;
            if (sv_bad || !s || !s->mem || off > s->len || len > s->len - off || sv_left(m) < len) { sv_null(h.op, 0); break; }
            pthread_mutex_lock(&buf_mu);
            memcpy(s->mem + off, m, len);
            for (uint64_t p = off / XR_PAGE; p * XR_PAGE < off + len; p++) s->hash[p] = xr_hash(s->mem + p * XR_PAGE, page_len(s, p));
            pthread_mutex_unlock(&buf_mu);
            if (((s->opts >> 4) & 15) == 1) xm2v_buffer_did_modify_range(s->buf, off, len);
            break; }

        case OP_xm2v_texture_replace_region: {
            uint64_t *a = sv_blob(&m, 88); void *t = sv_obj(a[0]);
            uint64_t n = a[10] ? a[10] * (a[6] ? a[6] : 1) : a[9] * (a[5] ? a[5] : 1) * (a[6] ? a[6] : 1);
            if (sv_bad || !t || sv_left(m) < n) { sv_null(h.op, 0); break; }
            if (!xm2v_texture_replace_region(t, a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], m, a[9], a[10])) sv_fail(h.op);
            break; }
        case OP_xm2v_texture_get_bytes: {
            uint64_t *a = sv_blob(&m, 88); void *t = sv_bad ? 0 : sv_obj(a[0]);
            uint64_t n = a[2] ? a[2] * (a[8] ? a[8] : 1) : a[1] * (a[7] ? a[7] : 1) * (a[8] ? a[8] : 1), ok = 0;
            uint8_t *px = t && n < (1ull << 31) ? malloc(n + 8) : 0;
            if (px) ok = xm2v_texture_get_bytes(t, px, a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10]);
            if (!ok) sv_fail(h.op);
            answer2(h.req, &ok, 8, px, ok ? n : 0); free(px); break; }

        case OP_GET_BYTES_CHANGED: {	// the texture's bytes where they are not what the client says it has
            uint64_t *a = sv_blob(&m, 88); void *t = sv_bad ? 0 : sv_obj(a[0]);
            uint64_t n = a[2] ? a[2] * (a[8] ? a[8] : 1) : a[1] * (a[7] ? a[7] : 1) * (a[8] ? a[8] : 1), ok = 0, np = (n + XR_PAGE - 1) / XR_PAGE;
            static uint8_t *px, *out; static uint64_t cap;
            if (!t || !n || n > (1ull << 31) || sv_left(m) < np * 8) { sv_null(h.op, 0); sv_answer(h.req, &ok, 8); break; }
            if (n > cap) { free(px); free(out); cap = n; px = malloc(n + 8); out = malloc(n + np * 24 + 64); }
            if (px && out) ok = xm2v_texture_get_bytes(t, px, a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10]);
            if (!ok) { sv_fail(h.op); sv_answer(h.req, &ok, 8); break; }
            uint64_t on = 0, run = ~0ull; const uint64_t *have = (const uint64_t *)m;
            for (uint64_t i = 0; i <= np; i++) {
                uint64_t l = i < np ? (n - i * XR_PAGE < XR_PAGE ? n - i * XR_PAGE : XR_PAGE) : 0;
                if (i < np && xr_hash(px + i * XR_PAGE, l) != have[i]) { if (run == ~0ull) run = i; continue; }
                if (run == ~0ull) continue;
                uint64_t rec[2] = { run * XR_PAGE, (i < np ? i * XR_PAGE : n) - run * XR_PAGE };
                memcpy(out + on, rec, 16); memcpy(out + on + 16, px + rec[0], rec[1]); memset(out + on + 16 + rec[1], 0, -rec[1] & 7);
                on += 16 + ((rec[1] + 7) & ~7ull); run = ~0ull;
            }
            st_changed += on; st_whole += n;
            answer2(h.req, &ok, 8, out, on); break; }

        case OP_xm2v_library_new_with_data: {
            uint64_t nid = sv_u64(&m); void *d = sv_obj(sv_u64(&m));
            void *l = d && !sv_bad ? xm2v_library_new_with_data(d, m, sv_left(m)) : 0;
            sv_set(nid, l); if (!l) sv_fail(h.op);
            sv_answer_u64(h.req, l != 0); break; }
        case OP_xm2v_library_new_function_with_descriptor: {
            uint64_t nid = sv_u64(&m); void *lib = sv_obj(sv_u64(&m)); uint64_t variant = sv_u64(&m), options = sv_u64(&m), count = sv_count(&m, 32);
            const char *name = sv_str(&m), *special = sv_str(&m);
            Xm2vConstant *c = calloc(count + 1, sizeof *c);
            for (uint64_t i = 0; i < count; i++) { c[i].data_type = sv_u64(&m); c[i].index = (uint32_t)sv_u64(&m); c[i].name = sv_str(&m); c[i].length = sv_u64(&m); c[i].bytes = sv_blob(&m, c[i].length); if (!c[i].bytes) sv_bad = true; }
            void *f = !lib || sv_bad ? 0 : variant == 0 ? xm2v_library_new_function_specialized(lib, name, c, count) :
                      variant == 1 ? xm2v_library_new_function_specialized_zero_rest(lib, name, c, count) :
                                     xm2v_library_new_function_with_descriptor(lib, name, special, c, count, options);
            free(c); sv_set(nid, f); if (!f) sv_fail(h.op);
            sv_answer_u64(h.req, f != 0); break; }
        case OP_xm2v_compute_pipeline_new_with_linked: {
            uint64_t nid = sv_u64(&m); void *d = sv_obj(sv_u64(&m)), *fn = sv_obj(sv_u64(&m)); uint32_t nl, np;
            Xm2vFunction **l = fn_list(&m, &nl), **p = fn_list(&m, &np);
            void *o = d && fn && !sv_bad ? xm2v_compute_pipeline_new_with_linked(d, fn, l, nl, p, np) : 0;
            free(l); free(p); sv_set(nid, o); if (!o) sv_fail(h.op);
            sv_answer_u64(h.req, o != 0); break; }
        case OP_xm2v_render_pipeline_new: {
            uint64_t nid = sv_u64(&m); void *d = sv_obj(sv_u64(&m));
            Xm2vRenderPipelineDesc *pd = sv_blob(&m, sizeof *pd);
            if (sv_bad) { sv_short(h.op); sv_set(nid, 0); sv_answer_u64(h.req, 0); break; }
            pd->vertex_function = sv_obj(sv_u64(&m)); pd->fragment_function = sv_obj(sv_u64(&m));
            Xm2vFunction **l0 = fn_list(&m, &pd->vertex_linked_function_count), **l1 = fn_list(&m, &pd->vertex_private_linked_function_count);
            Xm2vFunction **l2 = fn_list(&m, &pd->fragment_linked_function_count), **l3 = fn_list(&m, &pd->fragment_private_linked_function_count);
            pd->vertex_linked_functions = l0; pd->vertex_private_linked_functions = l1; pd->fragment_linked_functions = l2; pd->fragment_private_linked_functions = l3;
            pd->vertex_attribute_count = (uint32_t)sv_count(&m, sizeof(Xm2vVertexAttribute));
            pd->vertex_attributes = pd->vertex_attribute_count ? sv_blob(&m, pd->vertex_attribute_count * sizeof(Xm2vVertexAttribute)) : 0;
            pd->vertex_layout_count = (uint32_t)sv_count(&m, sizeof(Xm2vVertexLayout));
            pd->vertex_layouts = pd->vertex_layout_count ? sv_blob(&m, pd->vertex_layout_count * sizeof(Xm2vVertexLayout)) : 0;
            if (pd->color_attachment_count > 8) sv_bad = true;
            void *o = d && !sv_bad ? xm2v_render_pipeline_new(d, pd) : 0;
            free(l0); free(l1); free(l2); free(l3); sv_set(nid, o); if (!o) sv_fail(h.op);
            sv_answer_u64(h.req, o != 0); break; }

        case OP_xm2v_argument_encoder_set_argument_buffer: case OP_xm2v_argument_encoder_set_argument_buffer_array_element:
        case OP_xm2v_argument_encoder_set_buffer: case OP_xm2v_argument_encoder_set_texture: case OP_xm2v_argument_encoder_set_sampler:
        case OP_xm2v_argument_encoder_set_compute_pipeline: case OP_xm2v_argument_encoder_set_render_pipeline: {
            uint64_t eid = sv_u64(&m), a = sv_u64(&m), b = sv_u64(&m), c = sv_u64(&m), ok = 0; void *e = sv_obj(eid), *o = sv_obj(a);
            uint8_t *out = 0; size_t n = 0;
            if (e && o && !sv_bad) {
                uint64_t el = xm2v_argument_encoder_encoded_length(e);
                if (h.op == OP_xm2v_argument_encoder_set_argument_buffer) { sargs[eid].buf_id = a; sargs[eid].base = b; }
                if (h.op == OP_xm2v_argument_encoder_set_argument_buffer_array_element) { sargs[eid].buf_id = a; sargs[eid].base = b + c * el; }
                struct sbuf *s = sargs[eid].buf_id < nobj ? sbufs[sargs[eid].buf_id] : 0; uint64_t base = sargs[eid].base;
                bool span = s && s->mem && base + el <= s->len;
                uint8_t *before = span ? malloc(el + 1) : 0;
                if (before) memcpy(before, s->mem + base, el);
                switch (h.op) {
                case OP_xm2v_argument_encoder_set_argument_buffer: ok = xm2v_argument_encoder_set_argument_buffer(e, o, b); break;
                case OP_xm2v_argument_encoder_set_argument_buffer_array_element: ok = xm2v_argument_encoder_set_argument_buffer_array_element(e, o, b, c); break;
                case OP_xm2v_argument_encoder_set_buffer: ok = xm2v_argument_encoder_set_buffer(e, o, b, (uint32_t)c); break;
                case OP_xm2v_argument_encoder_set_texture: ok = xm2v_argument_encoder_set_texture(e, o, (uint32_t)b); break;
                case OP_xm2v_argument_encoder_set_sampler: ok = xm2v_argument_encoder_set_sampler(e, o, (uint32_t)b); break;
                case OP_xm2v_argument_encoder_set_compute_pipeline: ok = xm2v_argument_encoder_set_compute_pipeline(e, o, (uint32_t)b); break;
                default: ok = xm2v_argument_encoder_set_render_pipeline(e, o, (uint32_t)b); break;
                }
                if (before) {	// what the call wrote, by byte: the client has the rest of these pages
                    out = malloc(el * 4 + 64);
                    for (uint64_t i = 0; i < el; ) {
                        if (before[i] == s->mem[base + i]) { i++; continue; }
                        uint64_t j = i; while (j < el && (before[j] != s->mem[base + j] || (j + 8 < el && memcmp(before + j, s->mem + base + j, 8)))) j++;
                        uint64_t rec[3] = { sargs[eid].buf_id, base + i, j - i };
                        memcpy(out + n, rec, 24); memcpy(out + n + 24, s->mem + base + i, j - i); memset(out + n + 24 + (j - i), 0, -(j - i) & 7);
                        n += 24 + ((j - i + 7) & ~7ull); i = j;
                    }
                    free(before);
                }
            }
            if (!ok) sv_fail(h.op);
            answer2(h.req, &ok, 8, out, n); free(out); break; }
        case OP_xm2v_argument_encoder_constant_data: {
            uint64_t eid = sv_u64(&m), index = sv_u64(&m), r = 0; void *e = sv_obj(eid);
            struct sbuf *s = e && sargs[eid].buf_id < nobj ? sbufs[sargs[eid].buf_id] : 0;
            uint8_t *p = s && s->mem && !sv_bad ? xm2v_argument_encoder_constant_data(e, (uint32_t)index) : 0;
            if (p && p >= s->mem && p < s->mem + s->len) r = (uint64_t)(p - s->mem) + 1;
            sv_answer_u64(h.req, r); break; }

        case OP_xm2v_command_buffer_new: { uint64_t nid = sv_u64(&m); void *q = sv_obj(sv_u64(&m)); void *o = q && !sv_bad ? xm2v_command_buffer_new(q) : 0; sv_set(nid, o); if (!o) sv_fail(h.op); break; }
        case OP_xm2v_command_buffer_release: { uint64_t id = sv_u64(&m); void *o = sv_obj(id); if (o) xm2v_command_buffer_release(o); sv_set(id, 0); break; }
        case OP_xm2v_command_buffer_commit: { void *o = sv_obj(sv_u64(&m)); if (!o) sv_null(h.op, 0); else if (!xm2v_command_buffer_commit(o)) sv_fail(h.op); break; }
        case OP_xm2v_command_buffer_status: { void *o = sv_obj(sv_u64(&m)); if (o) answer_status(h.req, o, 0, 0, 0); else { uint64_t r[2] = { 5, 0 }; sv_answer(h.req, r, 16); } break; }
        case OP_xm2v_command_buffer_wait_until_completed: {
            struct wait_job *j = calloc(1, sizeof *j);
            j->req = h.req; j->cb = sv_obj(sv_u64(&m)); j->timeout = sv_u64(&m); uint64_t n = sv_count(&m, 8);
            if (!j->cb || sv_bad) { uint64_t r[2] = { 5, 0 }; sv_answer(h.req, r, 16); free(j); break; }
            j->ids = malloc((n + 1) * 8); j->bufs = malloc((n + 1) * sizeof *j->bufs);
            pthread_mutex_lock(&buf_mu);
            for (uint64_t i = 0; i < n; i++) { uint64_t id = sv_u64(&m); struct sbuf *s = id < nobj ? sbufs[id] : 0; if (s && s->mem) { s->refs++; j->ids[j->nb] = id; j->bufs[j->nb++] = s; } }
            pthread_mutex_unlock(&buf_mu);
            start_wait(j); break; }
        case OP_xm2v_shared_event_wait_until: {
            struct wait_job *j = calloc(1, sizeof *j);
            j->req = h.req; j->ev = sv_obj(sv_u64(&m)); j->value = sv_u64(&m); j->timeout = sv_u64(&m);
            if (!j->ev || sv_bad) { sv_answer_u64(h.req, 0); free(j); break; }
            start_wait(j); break; }
        case OP_xm2v_shared_event_notify: {
            void *ev = sv_obj(sv_u64(&m)); uint64_t value = sv_u64(&m), token = sv_u64(&m);
            if (!ev || sv_bad || !xm2v_shared_event_notify(ev, value, notified, (void *)(uintptr_t)token)) sv_fail(h.op);
            break; }

        case OP_xm2v_render_encoder_new: {
            uint64_t nid = sv_u64(&m); void *cb = sv_obj(sv_u64(&m));
            Xm2vRenderPassDesc *d = sv_blob(&m, sizeof *d);
            if (sv_bad) { sv_short(h.op); sv_set(nid, 0); break; }
            for (int i = 0; i < 8; i++) d->color_attachments[i].texture = sv_obj(sv_u64(&m));
            d->depth_texture = sv_obj(sv_u64(&m)); d->stencil_texture = sv_obj(sv_u64(&m));
            void *o = cb && !sv_bad && d->color_attachment_count <= 8 ? xm2v_render_encoder_new(cb, d) : 0;
            sv_set(nid, o); if (!o) sv_fail(h.op);
            break; }
        case OP_xm2v_compute_encoder_set_bytes: case OP_xm2v_render_encoder_set_vertex_bytes: case OP_xm2v_render_encoder_set_fragment_bytes: {
            void *e = sv_obj(sv_u64(&m)); uint64_t index = sv_u64(&m), len = sv_u64(&m);
            if (sv_bad || !e || sv_left(m) < len) { sv_null(h.op, 0); break; }
            bool ok = h.op == OP_xm2v_compute_encoder_set_bytes ? xm2v_compute_encoder_set_bytes(e, m, len, (uint32_t)index) :
                      h.op == OP_xm2v_render_encoder_set_vertex_bytes ? xm2v_render_encoder_set_vertex_bytes(e, m, len, (uint32_t)index) :
                                                                        xm2v_render_encoder_set_fragment_bytes(e, m, len, (uint32_t)index);
            if (!ok) sv_fail(h.op);
            break; }

#include "gen_server.inc"
        default:
            fprintf(stderr, "[%d] message %u is not a call\n", getpid(), h.op);
            if (h.req) sv_answer_u64(h.req, 0);
        }
    }
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: %s [ADDRESS:]PORT LOADER ICD_JSON [CACHE_DIR]\n", argv[0]); return 2; }
    char addr[64] = "127.0.0.1"; const char *port = argv[1], *colon = strrchr(argv[1], ':');
    if (colon) { snprintf(addr, sizeof addr, "%.*s", (int)(colon - argv[1]), argv[1]); port = colon + 1; }
    loader = argv[2]; icd = argv[3]; if (argc > 4) cache = argv[4];
    stats = getenv("XM2V_STATS") != 0;
    signal(SIGCHLD, SIG_IGN);	// no zombies
    int ls = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in sa = { .sin_family = AF_INET, .sin_port = htons(atoi(port)) };
    if (inet_pton(AF_INET, addr, &sa.sin_addr) != 1) { fprintf(stderr, "%s is not an IPv4 address\n", addr); return 2; }
    if (bind(ls, (void *)&sa, sizeof sa) || listen(ls, 64)) { perror("bind"); return 1; }
    fprintf(stderr, "xm2v-server: %s port %s, %s\n", addr, port, icd);
    for (;;) {
        fd = accept(ls, 0, 0);
        if (fd < 0) continue;
        pid_t p = fork();
        if (p) { close(fd); continue; }
        close(ls);
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        int sz = 4 << 20; setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sz, sizeof sz); setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &sz, sizeof sz);
        serve();
    }
}
