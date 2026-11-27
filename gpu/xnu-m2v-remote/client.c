// SPDX-License-Identifier: GPL-2.0-or-later
// libxnu_m2v with the renderer on another machine: every function of xnu_m2v.h, sent as a message to xm2v-server there
// (proto.h). The address is $XM2V_REMOTE or the first line of /etc/xnu-m2v-remote ("host:port").
//
// Objects: the caller's handle is a struct xh here, with the id the server knows the object by. Buffers keep their
// contents in this process; a command buffer remembers the buffers its encoders name, and at commit the pages of those
// that changed since they were last sent go first. Buffers the GPU may have written come back with the answer to
// wait_until_completed.
#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>
#ifdef XR_SWITCH	// built into the library that is either (switch.c): these are the remote ones, under other names
#include "gen_rename.h"
#endif
#include "xnu_m2v.h"
#include "proto.h"
#ifdef __APPLE__
#include <IOKit/IOKitLib.h>
#include "xnudrm_proto.h"
static io_connect_t xr_conn;	// the bridge's user client, when that is the way to the renderer (a sandbox has no sockets)
static uint8_t *xr_kout, *xr_kin; static size_t xr_kpos, xr_klen;
enum { XR_KCHUNK = 4 << 20 };
// One message through kexts/XnuDrm to xm2v-relay: arg0 1 sends n bytes, 2 receives into xr_kin. The reply's payload length, or -1.
static long xr_kcall(uint8_t *buf, uint64_t nr, uint64_t arg1, const void *p, size_t n) {
    struct xnudrm_hdr *h = (void *)buf;
    *h = (struct xnudrm_hdr){ .magic = XNUDRM_MAGIC, .op = XNUDRM_IOCTL, .arg0 = nr, .arg1 = arg1 };
    if (n) memcpy(h + 1, p, n);
    uint64_t in[4] = { (uintptr_t)buf, sizeof *h + n, (uintptr_t)buf, sizeof *h + XNUDRM_MAX_MSG }, out = 0; uint32_t nout = 1;
    if (IOConnectCallScalarMethod(xr_conn, 0, in, 4, &out, &nout) != KERN_SUCCESS || h->status) return -1;
    return (long)h->payload_len;
}
#endif

struct xh {
    uint64_t id;
    uint32_t kind;
    struct xh *parent;	// an encoder's command buffer
    struct xh *buf;	// a texture's buffer; an argument encoder's argument buffer
    // a buffer
    uint8_t *mem; uint64_t len; uint64_t *hash; uint64_t opts; bool mapped;
    struct xh *last_cb; uint32_t last_idx;
    uint64_t cached[2]; bool have[2];	// gpu address / resource id
    // a command buffer
    struct xh **ref; uint8_t *refw; uint32_t nref, capref;
    bool committed, final, asked; uint32_t status; char *err;
};

static pthread_mutex_t xr_mu = PTHREAD_MUTEX_INITIALIZER;	// the stream out, the handles
static int xr_fd = -1;
static bool xr_dead;
static uint8_t *xr_out; static size_t xr_outn; enum { XR_OUT = 1 << 20, XR_ROOM = 1 << 16 };
static uint8_t *xr_msg;	// the message being written
static uint64_t xr_next_id = 1, *xr_free_ids; static size_t xr_nfree, xr_capfree;
static struct xh **xr_tab; static size_t xr_ntab;
static uint64_t xr_next_req = 1, xr_cur_req;
static pthread_cond_t xr_pending = PTHREAD_COND_INITIALIZER;
unsigned long xm2v_remote_answers, xm2v_remote_bytes_out, xm2v_remote_bytes_in, xm2v_remote_buffer_bytes, xm2v_remote_hashed;

struct waiter { uint64_t req; uint8_t *data; uint64_t len; bool done; pthread_cond_t cv; struct waiter *next; uint64_t status_of; };	// status_of: nobody waits, the answer is a command buffer's status
static pthread_mutex_t rp_mu = PTHREAD_MUTEX_INITIALIZER;
static struct waiter *rp_waiters;
static int xr_nwait;	// answers being waited for
struct notify { uint64_t token; Xm2vSharedEventNotifyFn fn; void *ctx; uint64_t value; struct notify *next; };
static struct notify *rp_notifies; static uint64_t rp_next_token = 1;

static void xr_die(const char *what) {
    if (!xr_dead) fprintf(stderr, "xm2v remote: %s: %s; the renderer is gone\n", what, strerror(errno));
    xr_dead = true;
    pthread_mutex_lock(&rp_mu);
    for (struct waiter *w = rp_waiters; w; w = w->next) { w->done = true; pthread_cond_signal(&w->cv); }
    pthread_mutex_unlock(&rp_mu);
}
static void xr_write(const void *p, size_t n) {
#ifdef __APPLE__
    while (xr_conn && n && !xr_dead) {
        size_t k = n < XR_KCHUNK ? n : XR_KCHUNK;
        if (xr_kcall(xr_kout, 1, 0, p, k) < 0) { errno = EPIPE; xr_die("send through the bridge"); return; }
        p = (const char *)p + k; n -= k; xm2v_remote_bytes_out += k;
    }
    if (xr_conn) return;
#endif
    while (n && !xr_dead) {
#ifdef MSG_NOSIGNAL
        ssize_t r = send(xr_fd, p, n, MSG_NOSIGNAL);
#else
        ssize_t r = send(xr_fd, p, n, 0);
#endif
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) { xr_die("send"); return; }
        p = (const char *)p + r; n -= r; xm2v_remote_bytes_out += r;
    }
}
static void xr_flush(void) { if (xr_outn) { xr_write(xr_out, xr_outn); xr_outn = 0; } }
static void xr_lock(void) { pthread_mutex_lock(&xr_mu); }
static void xr_unlock(void) { pthread_mutex_unlock(&xr_mu); }
#define XID(p) ((p) ? ((const struct xh *)(p))->id : 0)

static struct xh *xr_new(uint32_t kind, struct xh *first) {
    struct xh *h = calloc(1, sizeof *h);
    h->kind = kind;
    if (xr_nfree) h->id = xr_free_ids[--xr_nfree]; else h->id = xr_next_id++;
    if (h->id >= xr_ntab) { size_t n = xr_ntab ? xr_ntab * 2 : 4096; xr_tab = realloc(xr_tab, n * sizeof *xr_tab); memset(xr_tab + xr_ntab, 0, (n - xr_ntab) * sizeof *xr_tab); xr_ntab = n; }
    xr_tab[h->id] = h;
    if (kind == K_Xm2vComputeEncoder || kind == K_Xm2vRenderEncoder || kind == K_Xm2vBlitEncoder) h->parent = first;
    return h;
}
static void xr_free(struct xh *h) {
    if (!h) return;
    if (xr_nfree == xr_capfree) { xr_capfree = xr_capfree ? xr_capfree * 2 : 1024; xr_free_ids = realloc(xr_free_ids, xr_capfree * sizeof *xr_free_ids); }
    xr_free_ids[xr_nfree++] = h->id;
    xr_tab[h->id] = 0;
    if (h->mem) { if (h->mapped) munmap(h->mem, (h->len + 16383) & ~16383ull); else free(h->mem); }
    free(h->hash); free(h->ref); free(h->refw); free(h->err);
    h->id = 0; h->kind = 0;
    free(h);
}
static void xr_retain(struct xh *h) { (void)h; }	// the caller keeps a texture's buffer for as long as the texture

static uint8_t *xr_begin(uint32_t op, uint64_t req) {
    if (xr_outn + XR_ROOM > XR_OUT) xr_flush();
    if (!xr_outn) pthread_cond_signal(&xr_pending);
    xr_msg = xr_out + xr_outn;
    struct xr_hdr h = { op, 0, 0, req };
    memcpy(xr_msg, &h, sizeof h);
    return xr_msg + sizeof h;
}
static uint8_t *xr_u64(uint8_t *m, uint64_t v) { memcpy(m, &v, 8); return m + 8; }
static uint8_t *xr_f64(uint8_t *m, double v) { memcpy(m, &v, 8); return m + 8; }
static uint8_t *xr_bytes(uint8_t *m, const void *p, size_t n) {	// small ones only (XR_ROOM)
    if (m + n + 8 > xr_out + XR_OUT) { fprintf(stderr, "xm2v remote: a message too long\n"); abort(); }
    memcpy(m, p, n); memset(m + n, 0, -n & 7); return m + ((n + 7) & ~7ul);
}
static uint8_t *xr_str(uint8_t *m, const char *s) {
    if (!s) return xr_u64(m, ~0ull);
    size_t n = strlen(s) + 1; m = xr_u64(m, n); return xr_bytes(m, s, n);
}
static void xr_end_raw(uint8_t *m, const void *raw, uint64_t n) {	// the message ends with n bytes from elsewhere
    uint64_t len = (uint64_t)(m - xr_msg) - sizeof(struct xr_hdr) + n;
    memcpy(xr_msg + 8, &len, 8);
    xr_outn = m - xr_out;
    if (!n) return;
    if (n <= 4096 && xr_outn + n <= XR_OUT) { memcpy(xr_out + xr_outn, raw, n); xr_outn += n; return; }
    xr_flush(); xr_write(raw, n);
}
static void xr_end(uint8_t *m) { xr_end_raw(m, 0, 0); }
static uint64_t xr_req(void) {
    struct waiter *w = calloc(1, sizeof *w);
    pthread_cond_init(&w->cv, 0);
    pthread_mutex_lock(&rp_mu);
    w->req = xr_cur_req = xr_next_req++;
    w->next = rp_waiters; rp_waiters = w; xr_nwait++;
    pthread_mutex_unlock(&rp_mu);
    return w->req;
}
// Sends what is written, lets go of the stream and waits for the answer. The answer is the caller's to free.
static uint8_t *xr_wait(uint64_t req, uint64_t *len) {
    xr_flush(); xr_unlock();
    pthread_mutex_lock(&rp_mu);
    struct waiter **pw = &rp_waiters, *w;
    while ((w = *pw) && w->req != req) pw = &w->next;
    while (!w->done && !xr_dead) pthread_cond_wait(&w->cv, &rp_mu);
    for (pw = &rp_waiters; *pw != w; pw = &(*pw)->next) ;
    *pw = w->next; xr_nwait--;
    pthread_mutex_unlock(&rp_mu);
    uint8_t *d = w->data; if (len) *len = d ? w->len : 0;
    pthread_cond_destroy(&w->cv); free(w);
    xm2v_remote_answers++;
    return d;
}
static uint64_t xr_wait_u64(uint64_t req) {
    uint64_t len, v = 0; uint8_t *d = xr_wait(req, &len);
    if (d && len >= 8) memcpy(&v, d, 8);
    free(d); return v;
}

static void xr_took_status_id(uint64_t id, uint8_t *d, uint64_t len);
static void *xr_notify_thread(void *p) { struct notify *n = p; n->fn(n->ctx, n->value); free(n); return 0; }
static bool xr_read(void *p, size_t n) {
#ifdef __APPLE__
    unsigned idle = 0;
    while (xr_conn && n) {
        if (xr_kpos < xr_klen) { size_t k = xr_klen - xr_kpos < n ? xr_klen - xr_kpos : n; memcpy(p, xr_kin + sizeof(struct xnudrm_hdr) + xr_kpos, k); xr_kpos += k; p = (char *)p + k; n -= k; xm2v_remote_bytes_in += k; idle = 0; continue; }
        long r = xr_kcall(xr_kin, 2, XNUDRM_MAX_MSG - 4096, 0, 0);
        if (r < 0) return false;
        xr_kpos = 0; xr_klen = r;
        // nothing there: ask again soon while somebody waits for an answer, now and then otherwise (a shared event's notification)
        if (!r) { if (xr_nwait || idle < 20) { usleep(idle++ < 50 ? 30 : 200); } else usleep(4000); }
    }
    if (xr_conn) return true;
#endif
    while (n) { ssize_t r = recv(xr_fd, p, n, 0); if (r < 0 && errno == EINTR) continue; if (r <= 0) return false; p = (char *)p + r; n -= r; xm2v_remote_bytes_in += r; }
    return true;
}
static void *xr_reader(void *unused) {
    (void)unused;
    for (;;) {
        struct xr_ans a;
        if (!xr_read(&a, sizeof a)) break;
        uint8_t *d = malloc(a.len + 8);
        if (!xr_read(d, a.len)) break;
        pthread_mutex_lock(&rp_mu);
        if (a.req == XR_CALLBACK) {
            uint64_t token, value; memcpy(&token, d, 8); memcpy(&value, d + 8, 8); free(d);
            struct notify **pn = &rp_notifies, *n;
            while ((n = *pn) && n->token != token) pn = &n->next;
            if (n) { *pn = n->next; n->value = value; pthread_t t; pthread_create(&t, 0, xr_notify_thread, n); pthread_detach(t); }
        } else {
            struct waiter **pw = &rp_waiters, *w;
            while ((w = *pw) && w->req != a.req) pw = &w->next;
            if (w && w->status_of) {	// asked without waiting (xm2v_command_buffer_status)
                uint64_t id = w->status_of; *pw = w->next; pthread_cond_destroy(&w->cv); free(w);
                pthread_mutex_unlock(&rp_mu);
                xr_took_status_id(id, d, a.len); free(d);
                continue;
            }
            if (w) { w->data = d; w->len = a.len; w->done = true; pthread_cond_signal(&w->cv); } else free(d);
        }
        pthread_mutex_unlock(&rp_mu);
    }
    xr_die("recv");
    return 0;
}
// What is written and not sent goes within a millisecond, whatever the caller does next.
static void *xr_flusher(void *unused) {
    (void)unused;
    for (;;) {
        xr_lock();
        while (!xr_outn && !xr_dead) pthread_cond_wait(&xr_pending, &xr_mu);
        xr_unlock();
        if (xr_dead) return 0;
        usleep(1000);
        xr_lock(); xr_flush(); xr_unlock();
    }
}

/* ---- buffers ---- */

static uint64_t xr_pages(uint64_t len) { return (len + XR_PAGE - 1) / XR_PAGE; }
static uint64_t xr_page_len(const struct xh *b, uint64_t page) { uint64_t o = page * XR_PAGE; return b->len - o < XR_PAGE ? b->len - o : XR_PAGE; }
static void xr_hash_all(struct xh *b) { for (uint64_t i = 0, n = xr_pages(b->len); i < n; i++) b->hash[i] = xr_hash(b->mem + i * XR_PAGE, xr_page_len(b, i)); }
static bool xr_cpu_visible(const struct xh *b) { return ((b->opts >> 4) & 15) != 2; }	// not MTLStorageModePrivate
// Sends the pages of a buffer that are not what the server has.
static void xr_sync_buffer(struct xh *b) {
    if (!b->mem || !xr_cpu_visible(b)) return;
    uint64_t n = xr_pages(b->len), run = ~0ull;
    xm2v_remote_hashed += b->len;
    for (uint64_t i = 0; i <= n; i++) {
        bool dirty = false;
        if (i < n) { uint64_t h = xr_hash(b->mem + i * XR_PAGE, xr_page_len(b, i)); if (h != b->hash[i]) { b->hash[i] = h; dirty = true; } }
        if (dirty) { if (run == ~0ull) run = i; continue; }
        if (run == ~0ull) continue;
        uint64_t off = run * XR_PAGE, len = (i < n ? i * XR_PAGE : b->len) - off;
        uint8_t *m = xr_begin(OP_BUFFER_WRITE, 0);
        m = xr_u64(m, b->id); m = xr_u64(m, off); m = xr_u64(m, len);
        xr_end_raw(m, b->mem + off, len);
        xm2v_remote_buffer_bytes += len;
        run = ~0ull;
    }
}
static void xr_ref_buffer(struct xh *owner, struct xh *b, bool write) {
    struct xh *cb = owner && owner->kind == K_Xm2vCommandBuffer ? owner : owner ? owner->parent : 0;
    if (!cb || !b || !b->mem) return;
    if (b->last_cb == cb && b->last_idx < cb->nref && cb->ref[b->last_idx] == b) { cb->refw[b->last_idx] |= write; return; }
    for (uint32_t i = 0; i < cb->nref; i++) if (cb->ref[i] == b) { cb->refw[i] |= write; b->last_cb = cb; b->last_idx = i; return; }
    if (cb->nref == cb->capref) { cb->capref = cb->capref ? cb->capref * 2 : 16; cb->ref = realloc(cb->ref, cb->capref * sizeof *cb->ref); cb->refw = realloc(cb->refw, cb->capref); }
    b->last_cb = cb; b->last_idx = cb->nref; cb->ref[cb->nref] = b; cb->refw[cb->nref++] = write;
}
static void xr_ref_texture(struct xh *owner, struct xh *t) { if (t && t->buf) xr_ref_buffer(owner, t->buf, true); }
// Takes changed ranges of buffers from an answer: (id, offset, length, bytes) until the end.
static void xr_take_ranges(const uint8_t *d, const uint8_t *end, struct xh *only) {
    while (d + 24 <= end) {
        uint64_t id, off, len; memcpy(&id, d, 8); memcpy(&off, d + 8, 8); memcpy(&len, d + 16, 8); d += 24;
        struct xh *b = only ? only : id < xr_ntab ? xr_tab[id] : 0;
        if (len > (uint64_t)(end - d)) break;
        if (b && b->kind == K_Xm2vBuffer && b->mem && off <= b->len && len <= b->len - off) {
            memcpy(b->mem + off, d, len);
            if (!only) for (uint64_t p = off / XR_PAGE; p * XR_PAGE < off + len; p++) b->hash[p] = xr_hash(b->mem + p * XR_PAGE, xr_page_len(b, p));
        }
        d += (len + 7) & ~7ull;
    }
}

static Xm2vBuffer *xr_buffer_new(Xm2vDevice *dev, uint64_t length, uint64_t opts, const void *bytes, uint64_t aligned) {
    if (!length) return 0;
    xr_lock();
    struct xh *b = xr_new(K_Xm2vBuffer, 0);
    b->len = length; b->opts = opts;
    if (length >= 16384) { b->mem = mmap(0, (length + 16383) & ~16383ull, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); b->mapped = true; if (b->mem == MAP_FAILED) b->mem = 0; }
    else b->mem = calloc(1, (length + 63) & ~63ull);
    if (!b->mem) { xr_free(b); xr_unlock(); return 0; }
    b->hash = malloc(xr_pages(length) * 8);
    uint8_t *m = xr_begin(OP_xm2v_buffer_new, 0);
    m = xr_u64(m, b->id); m = xr_u64(m, XID(dev)); m = xr_u64(m, length); m = xr_u64(m, opts); m = xr_u64(m, aligned); m = xr_u64(m, bytes != 0);
    if (bytes) {
        memcpy(b->mem, bytes, length); xr_hash_all(b);
        xr_end_raw(m, b->mem, length); xm2v_remote_buffer_bytes += length;
    } else {
        uint64_t z = 0, zl = 0;	// the server's copy starts as zeroes too
        static uint8_t zero[XR_PAGE];
        for (uint64_t i = 0, n = xr_pages(length); i < n; i++) { uint64_t l = xr_page_len(b, i); if (l != zl) { z = xr_hash(zero, l); zl = l; } b->hash[i] = z; }
        xr_end(m);
    }
    xr_unlock();
    return (Xm2vBuffer *)b;
}
Xm2vBuffer *xm2v_buffer_new(Xm2vDevice *dev, uint64_t length, uint64_t opts, const void *bytes) { return xr_buffer_new(dev, length, opts, bytes, 0); }
Xm2vBuffer *xm2v_buffer_new_page_aligned(Xm2vDevice *dev, uint64_t length, uint64_t opts, const void *bytes) { return xr_buffer_new(dev, length, opts, bytes, 1); }
// The caller's memory cannot be the GPU's here: no such buffer, and the caller copies (or maps this one's contents over its own).
Xm2vBuffer *xm2v_buffer_new_no_copy(Xm2vDevice *dev, void *ptr, uint64_t length, uint64_t opts) { (void)dev; (void)ptr; (void)length; (void)opts; return 0; }
Xm2vBuffer *xm2v_buffer_new_no_copy_dealloc(Xm2vDevice *dev, void *ptr, uint64_t length, uint64_t opts, Xm2vDeallocatorFn fn, void *ctx) {
    (void)dev; (void)ptr; (void)length; (void)opts; (void)fn; (void)ctx; return 0;
}
void xm2v_buffer_release(Xm2vBuffer *buf) {
    if (!buf) return;
    xr_lock();
    uint8_t *m = xr_begin(OP_xm2v_buffer_release, 0); m = xr_u64(m, XID(buf)); xr_end(m);
    xr_free((struct xh *)buf);
    xr_unlock();
}
void *xm2v_buffer_contents(const Xm2vBuffer *buf) { return buf ? ((const struct xh *)buf)->mem : 0; }
uint64_t xm2v_buffer_length(const Xm2vBuffer *buf) { return buf ? ((const struct xh *)buf)->len : 0; }
void xm2v_buffer_did_modify_range(const Xm2vBuffer *buf, uint64_t location, uint64_t length) { (void)buf; (void)location; (void)length; }	// found at commit
static uint64_t xr_cached_u64(struct xh *h, int which, uint32_t op) {
    if (!h) return 0;
    xr_lock();
    if (h->have[which]) { uint64_t v = h->cached[which]; xr_unlock(); return v; }
    uint8_t *m = xr_begin(op, xr_req()); uint64_t req = xr_cur_req; m = xr_u64(m, h->id); xr_end(m);
    uint64_t v = xr_wait_u64(req);
    xr_lock(); if (xr_tab[XID(h)] == h) { h->cached[which] = v; h->have[which] = true; } xr_unlock();
    return v;
}
uint64_t xm2v_buffer_gpu_address(const Xm2vBuffer *buf) { return xr_cached_u64((struct xh *)buf, 0, OP_xm2v_buffer_gpu_address); }
uint64_t xm2v_texture_gpu_resource_id(const Xm2vTexture *tex) { return xr_cached_u64((struct xh *)tex, 1, OP_xm2v_texture_gpu_resource_id); }
uint64_t xm2v_sampler_gpu_resource_id(const Xm2vSampler *s) { return xr_cached_u64((struct xh *)s, 1, OP_xm2v_sampler_gpu_resource_id); }

/* ---- device ---- */

static char xr_err[1024];
const char *xm2v_last_error(void) {
    if (xr_fd < 0 || xr_dead) return xr_err[0] ? xr_err : "no renderer";
    xr_lock();
    uint8_t *m = xr_begin(OP_xm2v_last_error, xr_req()); uint64_t req = xr_cur_req; xr_end(m);
    uint64_t len; uint8_t *d = xr_wait(req, &len);
    if (len >= sizeof xr_err) len = sizeof xr_err - 1;
    if (d) memcpy(xr_err, d, len);
    xr_err[d ? len : 0] = 0; free(d);
    return xr_err;
}
static void xr_start_threads(void) {
    xr_out = malloc(XR_OUT);
    pthread_t t; pthread_create(&t, 0, xr_reader, 0); pthread_detach(t); pthread_create(&t, 0, xr_flusher, 0); pthread_detach(t);
}
static bool xr_connect(void) {
    char addr[256] = "";
    const char *e = getenv("XM2V_REMOTE");
#ifdef __APPLE__
    if (!e) {	// through the bridge: xm2v-relay on the host knows where the renderer is
        io_service_t sv = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("XnuCpuMetalAccelerator"));
        if (!sv) sv = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("XnuDrm"));
        kern_return_t kr = sv ? IOServiceOpen(sv, mach_task_self(), XNUDRM_CONNECT_TYPE, &xr_conn) : KERN_FAILURE;
        if (sv) IOObjectRelease(sv);
        if (kr != KERN_SUCCESS) { xr_conn = 0; snprintf(xr_err, sizeof xr_err, "no way to the renderer: the bridge's user client did not open (%#x)", kr); return false; }
        xr_kout = malloc(sizeof(struct xnudrm_hdr) + XNUDRM_MAX_MSG); xr_kin = malloc(sizeof(struct xnudrm_hdr) + XNUDRM_MAX_MSG);
        xr_fd = 0;	// "connected"
        xr_start_threads();
        return true;
    }
#endif
    if (e) snprintf(addr, sizeof addr, "%s", e);
    else { FILE *f = fopen("/etc/xnu-m2v-remote", "r"); if (f) { if (!fgets(addr, sizeof addr, f)) addr[0] = 0; fclose(f); } addr[strcspn(addr, "\r\n ")] = 0; }
    char *c = strrchr(addr, ':');
    if (!c) { snprintf(xr_err, sizeof xr_err, "no renderer address (XM2V_REMOTE or /etc/xnu-m2v-remote: host:port)"); return false; }
    *c = 0;
    struct addrinfo hints = { .ai_socktype = SOCK_STREAM }, *ai = 0;
    if (getaddrinfo(addr, c + 1, &hints, &ai) || !ai) { snprintf(xr_err, sizeof xr_err, "renderer address %s: not found", addr); return false; }
    int fd = socket(ai->ai_family, SOCK_STREAM, 0);
    if (fd < 0 || connect(fd, ai->ai_addr, ai->ai_addrlen)) { snprintf(xr_err, sizeof xr_err, "renderer %s:%s: %s", addr, c + 1, strerror(errno)); if (fd >= 0) close(fd); freeaddrinfo(ai); return false; }
    freeaddrinfo(ai);
    int one = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
#ifdef SO_NOSIGPIPE
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
    int sz = 4 << 20; setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sz, sizeof sz); setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &sz, sizeof sz);
    xr_fd = fd;
    xr_start_threads();
    return true;
}
Xm2vDevice *xm2v_device_open_direct(const char *loader, void *pfn, const char *icd, const char *cache) {
    (void)loader; (void)pfn; (void)icd; (void)cache;
    xr_lock();
    if (xr_fd >= 0 || !xr_connect()) { if (xr_fd >= 0) snprintf(xr_err, sizeof xr_err, "one device a process"); xr_unlock(); return 0; }
    struct xh *d = xr_new(K_Xm2vDevice, 0);
    uint8_t *m = xr_begin(OP_xm2v_device_open, xr_req()); uint64_t req = xr_cur_req;
    m = xr_u64(m, d->id); m = xr_u64(m, XR_VERSION); xr_end(m);
    if (!xr_wait_u64(req)) { snprintf(xr_err, sizeof xr_err, "the renderer could not open its device"); return 0; }
    return (Xm2vDevice *)d;
}
Xm2vDevice *xm2v_device_open(const char *loader, const char *icd, const char *cache) { return xm2v_device_open_direct(loader, 0, icd, cache); }
void xm2v_device_release(Xm2vDevice *dev) { (void)dev; }
// An answer that is a string, as the functions with (out, size) give it.
static size_t xr_string(uint8_t *d, uint64_t len, char *out, size_t size) {
    if (!d) return 0;
    if (out && size) { size_t n = len < size - 1 ? len : size - 1; memcpy(out, d, n); out[n] = 0; }
    free(d); return len;
}
static size_t xr_ask_string(uint32_t op, uint64_t a, uint64_t b, char *out, size_t size) {
    xr_lock();
    uint8_t *m = xr_begin(op, xr_req()); uint64_t req = xr_cur_req; m = xr_u64(m, a); m = xr_u64(m, b); xr_end(m);
    uint64_t len; uint8_t *d = xr_wait(req, &len);
    return xr_string(d, len, out, size);
}
size_t xm2v_device_name(const Xm2vDevice *dev, char *out, size_t size) { return xr_ask_string(OP_xm2v_device_name, XID(dev), 0, out, size); }
size_t xm2v_library_function_name_at(const Xm2vLibrary *lib, size_t i, char *out, size_t size) { return xr_ask_string(OP_xm2v_library_function_name_at, XID(lib), i, out, size); }
size_t xm2v_library_extern_function_name_at(const Xm2vLibrary *lib, size_t i, char *out, size_t size) { return xr_ask_string(OP_xm2v_library_extern_function_name_at, XID(lib), i, out, size); }
bool xm2v_device_max_threads_per_threadgroup(const Xm2vDevice *dev, uint64_t out[3]) {
    xr_lock();
    uint8_t *m = xr_begin(OP_xm2v_device_max_threads_per_threadgroup, xr_req()); uint64_t req = xr_cur_req; m = xr_u64(m, XID(dev)); xr_end(m);
    uint64_t len; uint8_t *d = xr_wait(req, &len); bool ok = d && len >= 32 && d[0];
    if (ok) memcpy(out, d + 8, 24);
    free(d); return ok;
}
bool xm2v_pixel_format_is_ycbcr(uint64_t pf) {
    static uint8_t known[1024];	// 0 not asked, 1 no, 2 yes
    if (pf < 1024 && known[pf]) return known[pf] == 2;
    if (xr_fd < 0) return false;
    xr_lock();
    uint8_t *m = xr_begin(OP_xm2v_pixel_format_is_ycbcr, xr_req()); uint64_t req = xr_cur_req; m = xr_u64(m, pf); xr_end(m);
    bool r = xr_wait_u64(req) != 0;
    if (pf < 1024 && !xr_dead) known[pf] = r ? 2 : 1;
    return r;
}

/* ---- textures ---- */

static uint64_t xr_image_bytes(uint64_t bpr, uint64_t bpi, uint64_t h, uint64_t d) { return bpi ? bpi * (d ? d : 1) : bpr * (h ? h : 1) * (d ? d : 1); }
bool xm2v_texture_replace_region(const Xm2vTexture *tex, uint64_t x, uint64_t y, uint64_t z, uint64_t w, uint64_t h, uint64_t d,
                                 uint64_t mip, uint64_t slice, const void *bytes, uint64_t bpr, uint64_t bpi) {
    if (!tex || !bytes) return false;
    xr_lock();
    uint8_t *m = xr_begin(OP_xm2v_texture_replace_region, 0);
    uint64_t a[11] = { XID(tex), x, y, z, w, h, d, mip, slice, bpr, bpi };
    m = xr_bytes(m, a, sizeof a);
    xr_end_raw(m, bytes, xr_image_bytes(bpr, bpi, h, d));
    xr_unlock();
    return true;
}
// A read-back of a page or more says what the destination holds now (a fingerprint for each XR_PAGE of it), and only the
// pages that differ come back: a frame read into the surface it was read into before is mostly what is already there.
bool xm2v_texture_get_bytes(const Xm2vTexture *tex, void *out, uint64_t bpr, uint64_t bpi, uint64_t x, uint64_t y, uint64_t z,
                            uint64_t w, uint64_t h, uint64_t d, uint64_t mip, uint64_t slice) {
    if (!tex || !out) return false;
    uint64_t n = xr_image_bytes(bpr, bpi, h, d), a[11] = { XID(tex), bpr, bpi, x, y, z, w, h, d, mip, slice };
    // To compare: while the file /var/tmp/xm2v-read-whole exists, every read-back comes whole.
    static unsigned calls; static bool whole;
    if (!(calls++ & 63)) whole = access("/var/tmp/xm2v-read-whole", F_OK) == 0;
    if (whole || n < 16 * XR_PAGE || n > (1ull << 31)) {
        xr_lock();
        uint8_t *m = xr_begin(OP_xm2v_texture_get_bytes, xr_req()); uint64_t req = xr_cur_req;
        m = xr_bytes(m, a, sizeof a); xr_end(m);
        uint64_t len; uint8_t *p = xr_wait(req, &len);
        bool ok = p && len == 8 + n && p[0];
        if (ok) memcpy(out, p + 8, n);
        free(p); return ok;
    }
    uint64_t pages = (n + XR_PAGE - 1) / XR_PAGE, *have = malloc(pages * 8);
    for (uint64_t i = 0; i < pages; i++) have[i] = xr_hash((uint8_t *)out + i * XR_PAGE, n - i * XR_PAGE < XR_PAGE ? n - i * XR_PAGE : XR_PAGE);
    xr_lock();
    uint8_t *m = xr_begin(OP_GET_BYTES_CHANGED, xr_req()); uint64_t req = xr_cur_req;
    m = xr_bytes(m, a, sizeof a); xr_end_raw(m, have, pages * 8);
    free(have);
    uint64_t len; uint8_t *p = xr_wait(req, &len);
    bool ok = p && len >= 8 && p[0];
    for (uint8_t *q = p + 8, *end = p + len; ok && q + 16 <= end; ) {	// (offset, length, bytes) until the end
        uint64_t off, l; memcpy(&off, q, 8); memcpy(&l, q + 8, 8); q += 16;
        if (off > n || l > n - off || l > (uint64_t)(end - q)) { ok = false; break; }
        memcpy((uint8_t *)out + off, q, l); q += (l + 7) & ~7ull;
    }
    free(p); return ok;
}

/* ---- libraries, functions, pipelines ---- */

static Xm2vLibrary *xr_sync_new(struct xh *nh, uint64_t req) {	// with the stream held; lets go of it
    if (xr_wait_u64(req)) return (Xm2vLibrary *)nh;
    xr_lock(); xr_free(nh); xr_unlock(); return 0;
}
Xm2vLibrary *xm2v_library_new_with_data(Xm2vDevice *dev, const void *bytes, size_t len) {
    xr_lock();
    struct xh *nh = xr_new(K_Xm2vLibrary, 0);
    uint8_t *m = xr_begin(OP_xm2v_library_new_with_data, xr_req()); uint64_t req = xr_cur_req;
    m = xr_u64(m, nh->id); m = xr_u64(m, XID(dev)); xr_end_raw(m, bytes, len);
    return xr_sync_new(nh, req);
}
static Xm2vFunction *xr_function_special(uint64_t variant, Xm2vLibrary *lib, const char *name, const char *special,
                                         const Xm2vConstant *c, uint32_t count, uint64_t options) {
    xr_lock();
    struct xh *nh = xr_new(K_Xm2vFunction, 0);
    xr_flush();	// room for the constants
    uint8_t *m = xr_begin(OP_xm2v_library_new_function_with_descriptor, xr_req()); uint64_t req = xr_cur_req;
    m = xr_u64(m, nh->id); m = xr_u64(m, XID(lib)); m = xr_u64(m, variant); m = xr_u64(m, options); m = xr_u64(m, count);
    m = xr_str(m, name); m = xr_str(m, special);
    for (uint32_t i = 0; i < count; i++) {
        m = xr_u64(m, c[i].data_type); m = xr_u64(m, c[i].index); m = xr_str(m, c[i].name);
        m = xr_u64(m, c[i].length); m = xr_bytes(m, c[i].bytes, c[i].length);
    }
    xr_end(m);
    return (Xm2vFunction *)xr_sync_new(nh, req);
}
Xm2vFunction *xm2v_library_new_function_specialized(Xm2vLibrary *lib, const char *name, const Xm2vConstant *c, uint32_t n) { return xr_function_special(0, lib, name, 0, c, n, 0); }
Xm2vFunction *xm2v_library_new_function_specialized_zero_rest(Xm2vLibrary *lib, const char *name, const Xm2vConstant *c, uint32_t n) { return xr_function_special(1, lib, name, 0, c, n, 0); }
Xm2vFunction *xm2v_library_new_function_with_descriptor(Xm2vLibrary *lib, const char *name, const char *special, const Xm2vConstant *c, uint32_t n, uint64_t options) {
    return xr_function_special(2, lib, name, special, c, n, options);
}
static uint8_t *xr_ids(uint8_t *m, Xm2vFunction *const *f, uint32_t n) { m = xr_u64(m, f ? n : 0); for (uint32_t i = 0; f && i < n; i++) m = xr_u64(m, XID(f[i])); return m; }
Xm2vComputePipeline *xm2v_compute_pipeline_new_with_linked(Xm2vDevice *dev, Xm2vFunction *fn, Xm2vFunction *const *linked, uint32_t nl,
                                                           Xm2vFunction *const *priv, uint32_t np) {
    xr_lock();
    struct xh *nh = xr_new(K_Xm2vComputePipeline, 0);
    xr_flush();
    uint8_t *m = xr_begin(OP_xm2v_compute_pipeline_new_with_linked, xr_req()); uint64_t req = xr_cur_req;
    m = xr_u64(m, nh->id); m = xr_u64(m, XID(dev)); m = xr_u64(m, XID(fn)); m = xr_ids(m, linked, nl); m = xr_ids(m, priv, np); xr_end(m);
    return (Xm2vComputePipeline *)xr_sync_new(nh, req);
}
Xm2vRenderPipeline *xm2v_render_pipeline_new(Xm2vDevice *dev, const Xm2vRenderPipelineDesc *d) {
    xr_lock();
    struct xh *nh = xr_new(K_Xm2vRenderPipeline, 0);
    xr_flush();
    uint8_t *m = xr_begin(OP_xm2v_render_pipeline_new, xr_req()); uint64_t req = xr_cur_req;
    m = xr_u64(m, nh->id); m = xr_u64(m, XID(dev)); m = xr_bytes(m, d, sizeof *d);
    m = xr_u64(m, XID(d->vertex_function)); m = xr_u64(m, XID(d->fragment_function));
    m = xr_ids(m, d->vertex_linked_functions, d->vertex_linked_function_count);
    m = xr_ids(m, d->vertex_private_linked_functions, d->vertex_private_linked_function_count);
    m = xr_ids(m, d->fragment_linked_functions, d->fragment_linked_function_count);
    m = xr_ids(m, d->fragment_private_linked_functions, d->fragment_private_linked_function_count);
    uint32_t na = d->vertex_attributes ? d->vertex_attribute_count : 0, nl = d->vertex_layouts ? d->vertex_layout_count : 0;
    m = xr_u64(m, na); if (na) m = xr_bytes(m, d->vertex_attributes, na * sizeof *d->vertex_attributes);
    m = xr_u64(m, nl); if (nl) m = xr_bytes(m, d->vertex_layouts, nl * sizeof *d->vertex_layouts);
    xr_end(m);
    return (Xm2vRenderPipeline *)xr_sync_new(nh, req);
}

/* ---- argument encoders: the server writes the buffer; what it wrote comes back with the answer ---- */

static bool xr_arg_set(uint32_t op, const Xm2vArgumentEncoder *enc, uint64_t a, uint64_t b, uint64_t c) {
    struct xh *e = (struct xh *)enc;
    if (!e) return false;
    xr_lock();
    uint8_t *m = xr_begin(op, xr_req()); uint64_t req = xr_cur_req;
    m = xr_u64(m, e->id); m = xr_u64(m, a); m = xr_u64(m, b); m = xr_u64(m, c); xr_end(m);
    uint64_t len; uint8_t *d = xr_wait(req, &len);
    bool ok = d && len >= 8 && d[0];
    xr_lock();
    if (ok && xr_tab[XID(e)] == e && e->buf) xr_take_ranges(d + 8, d + len, e->buf);
    xr_unlock();
    free(d); return ok;
}
bool xm2v_argument_encoder_set_argument_buffer(Xm2vArgumentEncoder *enc, Xm2vBuffer *buf, uint64_t offset) {
    if (!enc) return false;
    xr_lock(); ((struct xh *)enc)->buf = (struct xh *)buf; xr_unlock();
    return xr_arg_set(OP_xm2v_argument_encoder_set_argument_buffer, enc, XID(buf), offset, 0);
}
bool xm2v_argument_encoder_set_argument_buffer_array_element(Xm2vArgumentEncoder *enc, Xm2vBuffer *buf, uint64_t start, uint64_t element) {
    if (!enc) return false;
    xr_lock(); ((struct xh *)enc)->buf = (struct xh *)buf; xr_unlock();
    return xr_arg_set(OP_xm2v_argument_encoder_set_argument_buffer_array_element, enc, XID(buf), start, element);
}
bool xm2v_argument_encoder_set_buffer(const Xm2vArgumentEncoder *enc, Xm2vBuffer *buf, uint64_t offset, uint32_t index) { return xr_arg_set(OP_xm2v_argument_encoder_set_buffer, enc, XID(buf), offset, index); }
bool xm2v_argument_encoder_set_texture(const Xm2vArgumentEncoder *enc, Xm2vTexture *t, uint32_t index) { return xr_arg_set(OP_xm2v_argument_encoder_set_texture, enc, XID(t), index, 0); }
bool xm2v_argument_encoder_set_sampler(const Xm2vArgumentEncoder *enc, Xm2vSampler *s, uint32_t index) { return xr_arg_set(OP_xm2v_argument_encoder_set_sampler, enc, XID(s), index, 0); }
bool xm2v_argument_encoder_set_compute_pipeline(const Xm2vArgumentEncoder *enc, Xm2vComputePipeline *p, uint32_t index) { return xr_arg_set(OP_xm2v_argument_encoder_set_compute_pipeline, enc, XID(p), index, 0); }
bool xm2v_argument_encoder_set_render_pipeline(const Xm2vArgumentEncoder *enc, Xm2vRenderPipeline *p, uint32_t index) { return xr_arg_set(OP_xm2v_argument_encoder_set_render_pipeline, enc, XID(p), index, 0); }
void *xm2v_argument_encoder_constant_data(const Xm2vArgumentEncoder *enc, uint32_t index) {
    struct xh *e = (struct xh *)enc;
    if (!e || !e->buf) return 0;
    xr_lock();
    uint8_t *m = xr_begin(OP_xm2v_argument_encoder_constant_data, xr_req()); uint64_t req = xr_cur_req; m = xr_u64(m, e->id); m = xr_u64(m, index); xr_end(m);
    uint64_t off = xr_wait_u64(req) - 1;	// 0: none
    return off < e->buf->len ? e->buf->mem + off : 0;
}

/* ---- command buffers ---- */

Xm2vCommandBuffer *xm2v_command_buffer_new(Xm2vQueue *q) {
    xr_lock();
    struct xh *cb = xr_new(K_Xm2vCommandBuffer, 0);
    uint8_t *m = xr_begin(OP_xm2v_command_buffer_new, 0); m = xr_u64(m, cb->id); m = xr_u64(m, XID(q)); xr_end(m);
    xr_unlock();
    return (Xm2vCommandBuffer *)cb;
}
void xm2v_command_buffer_release(Xm2vCommandBuffer *cb) {
    if (!cb) return;
    xr_lock();
    uint8_t *m = xr_begin(OP_xm2v_command_buffer_release, 0); m = xr_u64(m, XID(cb)); xr_end(m);
    xr_free((struct xh *)cb);
    xr_unlock();
}
bool xm2v_command_buffer_commit(Xm2vCommandBuffer *c) {
    struct xh *cb = (struct xh *)c;
    if (!cb) return false;
    xr_lock();
    for (uint32_t i = 0; i < cb->nref; i++) if (cb->ref[i]->kind == K_Xm2vBuffer) xr_sync_buffer(cb->ref[i]);
    uint8_t *m = xr_begin(OP_xm2v_command_buffer_commit, 0); m = xr_u64(m, cb->id); xr_end(m);
    cb->committed = true;
    xr_flush();
    xr_unlock();
    return true;
}
// The answer to a wait or a status: status, the error's text, then the buffers the GPU changed.
static void xr_took_status_id(uint64_t id, uint8_t *d, uint64_t len) {
    if (!d || len < 16) return;
    uint64_t status, el; memcpy(&status, d, 8); memcpy(&el, d + 8, 8);
    xr_lock();
    struct xh *cb = id < xr_ntab ? xr_tab[id] : 0;
    if (cb && cb->kind == K_Xm2vCommandBuffer) {
        cb->asked = false;
        cb->status = (uint32_t)status;
        if (status >= 4) cb->final = true;
        if (el) { free(cb->err); cb->err = malloc(el + 1); memcpy(cb->err, d + 16, el); cb->err[el] = 0; }
        xr_take_ranges(d + 16 + ((el + 7) & ~7ull), d + len, 0);
    }
    xr_unlock();
}
static void xr_took_status(struct xh *cb, uint8_t *d, uint64_t len) { xr_took_status_id(XID(cb), d, len); }
bool xm2v_command_buffer_wait_until_completed(Xm2vCommandBuffer *c, uint64_t timeout_ms) {
    struct xh *cb = (struct xh *)c;
    if (!cb) return false;
    xr_lock();
    if (cb->final || !cb->committed) { bool ok = cb->status == 4; xr_unlock(); return ok; }
    xr_flush();
    uint8_t *m = xr_begin(OP_xm2v_command_buffer_wait_until_completed, xr_req()); uint64_t req = xr_cur_req;
    m = xr_u64(m, cb->id); m = xr_u64(m, timeout_ms);
    uint8_t *count = m; uint64_t n = 0; m += 8;
    for (uint32_t i = 0; i < cb->nref && n < 4096; i++)
        if (cb->refw[i] && cb->ref[i]->kind == K_Xm2vBuffer && xr_cpu_visible(cb->ref[i])) { m = xr_u64(m, cb->ref[i]->id); n++; }
    xr_u64(count, n); xr_end(m);
    uint64_t len; uint8_t *d = xr_wait(req, &len);
    xr_took_status(cb, d, len);
    free(d);
    return cb->status == 4;
}
// What is known of it now, without waiting: a committed one that is not done is asked about, and the answer is what a
// later call gives (a caller that goes on to wait gets it from the wait; one that polls sees it a call later).
uint32_t xm2v_command_buffer_status(const Xm2vCommandBuffer *c) {
    struct xh *cb = (struct xh *)c;
    if (!cb) return 5;
    xr_lock();
    uint32_t st = cb->committed && cb->status < 2 ? 2 : cb->status;
    if (!cb->final && cb->committed && !cb->asked) {
        cb->asked = true;
        uint8_t *m = xr_begin(OP_xm2v_command_buffer_status, xr_req());
        pthread_mutex_lock(&rp_mu);
        for (struct waiter *w = rp_waiters; w; w = w->next) if (w->req == xr_cur_req) { w->status_of = cb->id; xr_nwait--; }
        pthread_mutex_unlock(&rp_mu);
        m = xr_u64(m, cb->id); xr_end(m);
    }
    xr_unlock();
    return st;
}
// The status for a caller that must have it (the error's text).
static void xr_status_now(struct xh *cb) {
    xr_lock();
    if (cb->final || !cb->committed) { xr_unlock(); return; }
    uint8_t *m = xr_begin(OP_xm2v_command_buffer_status, xr_req()); uint64_t req = xr_cur_req; m = xr_u64(m, cb->id); xr_end(m);
    uint64_t len; uint8_t *d = xr_wait(req, &len);
    xr_took_status(cb, d, len);
    free(d);
}
size_t xm2v_command_buffer_error(const Xm2vCommandBuffer *c, char *out, size_t size) {
    struct xh *cb = (struct xh *)c;
    if (!cb) return 0;
    if (!cb->final) xr_status_now(cb);
    xr_lock();
    size_t n = cb->err ? strlen(cb->err) : 0;
    if (out && size) { size_t k = n < size - 1 ? n : size - 1; if (k) memcpy(out, cb->err, k); out[k] = 0; }
    xr_unlock();
    return n;
}

/* ---- encoders ---- */

Xm2vRenderEncoder *xm2v_render_encoder_new(Xm2vCommandBuffer *cb, const Xm2vRenderPassDesc *d) {
    xr_lock();
    struct xh *nh = xr_new(K_Xm2vRenderEncoder, (struct xh *)cb);
    uint8_t *m = xr_begin(OP_xm2v_render_encoder_new, 0);
    m = xr_u64(m, nh->id); m = xr_u64(m, XID(cb)); m = xr_bytes(m, d, sizeof *d);
    for (int i = 0; i < 8; i++) { Xm2vTexture *t = (uint32_t)i < d->color_attachment_count ? d->color_attachments[i].texture : 0; m = xr_u64(m, XID(t)); xr_ref_texture((struct xh *)cb, (struct xh *)t); }
    m = xr_u64(m, XID(d->depth_texture)); m = xr_u64(m, XID(d->stencil_texture));
    xr_ref_texture((struct xh *)cb, (struct xh *)d->depth_texture); xr_ref_texture((struct xh *)cb, (struct xh *)d->stencil_texture);
    xr_end(m);
    xr_unlock();
    return (Xm2vRenderEncoder *)nh;
}
static bool xr_set_bytes(uint32_t op, void *enc, const void *bytes, size_t len, uint32_t index) {
    if (!enc || !bytes) return false;
    xr_lock();
    uint8_t *m = xr_begin(op, 0); m = xr_u64(m, XID(enc)); m = xr_u64(m, index); m = xr_u64(m, len); xr_end_raw(m, bytes, len);
    xr_unlock();
    return true;
}
bool xm2v_compute_encoder_set_bytes(Xm2vComputeEncoder *e, const void *b, size_t n, uint32_t i) { return xr_set_bytes(OP_xm2v_compute_encoder_set_bytes, e, b, n, i); }
bool xm2v_render_encoder_set_vertex_bytes(Xm2vRenderEncoder *e, const void *b, size_t n, uint32_t i) { return xr_set_bytes(OP_xm2v_render_encoder_set_vertex_bytes, e, b, n, i); }
bool xm2v_render_encoder_set_fragment_bytes(Xm2vRenderEncoder *e, const void *b, size_t n, uint32_t i) { return xr_set_bytes(OP_xm2v_render_encoder_set_fragment_bytes, e, b, n, i); }

/* ---- shared events ---- */

bool xm2v_shared_event_wait_until(const Xm2vSharedEvent *ev, uint64_t value, uint64_t timeout_ms) {
    xr_lock();
    uint8_t *m = xr_begin(OP_xm2v_shared_event_wait_until, xr_req()); uint64_t req = xr_cur_req;
    m = xr_u64(m, XID(ev)); m = xr_u64(m, value); m = xr_u64(m, timeout_ms); xr_end(m);
    return xr_wait_u64(req) != 0;
}
bool xm2v_shared_event_notify(const Xm2vSharedEvent *ev, uint64_t value, Xm2vSharedEventNotifyFn fn, void *ctx) {
    if (!ev || !fn) return false;
    struct notify *n = calloc(1, sizeof *n);
    n->fn = fn; n->ctx = ctx;
    pthread_mutex_lock(&rp_mu); n->token = rp_next_token++; n->next = rp_notifies; rp_notifies = n; uint64_t token = n->token; pthread_mutex_unlock(&rp_mu);
    xr_lock();
    uint8_t *m = xr_begin(OP_xm2v_shared_event_notify, 0); m = xr_u64(m, XID(ev)); m = xr_u64(m, value); m = xr_u64(m, token); xr_end(m);
    xr_flush();
    xr_unlock();
    return true;
}

#include "gen_client.inc"
