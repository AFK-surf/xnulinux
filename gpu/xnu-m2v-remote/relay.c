// SPDX-License-Identifier: GPL-2.0-or-later
// xm2v-relay: on the Linux that hosts the macOS, in xnudrmd's place. The hosted system's libxnu_m2v reaches it through
// kexts/XnuDrm (the only door a sandboxed process has: no sockets there), and it carries each client's bytes to and from
// xm2v-server on the machine with the GPU.
//
// usage: xm2v-relay HOST PORT        (as root: /dev/xnu-hostcall is 0600)
//
// The bridge's messages (xnudrm_proto.h): XNUDRM_OPEN connects, XNUDRM_CLOSE closes, XNUDRM_IOCTL with arg0 = 1 sends
// the payload, with arg0 = 2 answers with what has arrived (at most arg1 bytes, none if nothing has: the hosted CPU that
// asks waits in the host call, and one call is made at a time).
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include "xnudrm_proto.h"
#define MAX_CLIENTS 1024
static int clients[MAX_CLIENTS];	// socket + 1
static const char *host, *port;
static int verbose;
// A connection to the renderer, or -errno. The hosted CPU that opens a Metal device waits in its host call for this, and
// every other host call behind it: at most CONNECT_MS, and after a failure the next tries within RETRY_MS fail at once.
enum { CONNECT_MS = 1000, RETRY_MS = 3000 };
static struct addrinfo *renderer;
static int dial(void) {
    static struct timespec failed; static int failure;
    struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    if (failure && (now.tv_sec - failed.tv_sec) * 1000 + (now.tv_nsec - failed.tv_nsec) / 1000000 < RETRY_MS) return failure;
    int fd = socket(renderer->ai_family, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0), one = 1, sz = 8 << 20, e = 0;
    if (fd < 0) return -errno;
    if (connect(fd, renderer->ai_addr, renderer->ai_addrlen)) {
        struct pollfd p = { .fd = fd, .events = POLLOUT }; socklen_t el = sizeof e;
        if (errno != EINPROGRESS) e = errno;
        else if (poll(&p, 1, CONNECT_MS) != 1) e = ETIMEDOUT;
        else getsockopt(fd, SOL_SOCKET, SO_ERROR, &e, &el);
    }
    if (e) { close(fd); failure = -e; failed = now; return -e; }
    failure = 0;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK);
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sz, sizeof sz); setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &sz, sizeof sz);
    return fd;
}
int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s HOST PORT [-v]\n", argv[0]); return 2; }
    host = argv[1]; port = argv[2]; verbose = argc > 3;
    struct addrinfo hints = { .ai_socktype = SOCK_STREAM };
    if (getaddrinfo(host, port, &hints, &renderer) || !renderer) { fprintf(stderr, "xm2v-relay: %s:%s: no such address\n", host, port); return 1; }
    int probe = dial();	// before any hosted system waits on it
    if (probe < 0) { fprintf(stderr, "xm2v-relay: renderer %s:%s: %s\n", host, port, strerror(-probe)); return 1; }
    close(probe);
    int hc = open("/dev/xnu-hostcall", O_RDWR | O_CLOEXEC);
    if (hc < 0) { perror("/dev/xnu-hostcall"); return 1; }
    size_t cap = 8 + XNUDRM_MAX_MSG + sizeof(struct xnudrm_hdr);
    uint8_t *msg = malloc(cap), *rep = malloc(cap);
    fprintf(stderr, "xm2v-relay: serving, renderer %s:%s\n", host, port);
    unsigned long calls = 0, sent = 0, got = 0, empty = 0;
    for (;;) {
        ssize_t n = read(hc, msg, cap);
        if (n < 0) { if (errno == EINTR || errno == EAGAIN) continue; perror("read"); return 1; }
        struct xnudrm_hdr *h = (void *)(msg + 8), *rh = (void *)(rep + 8);
        uint8_t *payload = (uint8_t *)(h + 1), *rpayload = (uint8_t *)(rh + 1);
        uint32_t rlen = 0; int st = 0;
        memcpy(rep, msg, 8);
        if ((size_t)n < 8 + sizeof *h || h->magic != XNUDRM_MAGIC || h->payload_len > (size_t)n - 8 - sizeof *h) {
            *rh = (struct xnudrm_hdr){ .magic = XNUDRM_MAGIC, .status = -EINVAL };
            if (write(hc, rep, 8 + sizeof *rh) < 0) perror("write");
            continue;
        }
        *rh = *h; rh->payload_len = 0;
        int fd = h->client && h->client < MAX_CLIENTS ? clients[h->client] - 1 : -1;
        switch (h->op) {
        case XNUDRM_OPEN: {
            int c;
            if (h->arg0 != XNUDRM_VERSION) { st = -EPROTO; break; }
            for (c = 1; c < MAX_CLIENTS && clients[c]; c++) ;
            if (c == MAX_CLIENTS) { st = -EMFILE; break; }
            int s = dial();
            if (s < 0) { st = s; fprintf(stderr, "xm2v-relay: renderer %s:%s: %s\n", host, port, strerror(-s)); break; }
            clients[c] = s + 1; rh->client = c;
            if (verbose) fprintf(stderr, "open: client %d\n", c);
            break; }
        case XNUDRM_CLOSE:
            if (fd < 0) { st = -EBADF; break; }
            close(fd); clients[h->client] = 0;
            if (verbose) fprintf(stderr, "close: client %u\n", h->client);
            break;
        case XNUDRM_IOCTL:
            if (fd < 0) { st = -EBADF; break; }
            if (h->arg0 == 1) {
                const uint8_t *p = payload; size_t left = h->payload_len;
                while (left) { ssize_t w = send(fd, p, left, MSG_NOSIGNAL); if (w < 0 && errno == EINTR) continue; if (w <= 0) { st = -EPIPE; break; } p += w; left -= w; }
                sent += h->payload_len;
            } else if (h->arg0 == 2) {
                size_t max = h->arg1 < XNUDRM_MAX_MSG - 4096 ? h->arg1 : XNUDRM_MAX_MSG - 4096;
                ssize_t r = recv(fd, rpayload, max, MSG_DONTWAIT);
                if (r > 0) { rlen = r; got += r; } else if (r == 0) st = -EPIPE; else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) st = -EPIPE; else empty++;
            } else st = -ENOSYS;
            break;
        default: st = -ENOSYS;
        }
        rh->status = st; rh->payload_len = rlen;
        if (write(hc, rep, 8 + sizeof *rh + rlen) < 0 && errno != ESTALE) perror("write");
        if (verbose && !(++calls % 100000)) fprintf(stderr, "%lu calls, %lu bytes sent, %lu received, %lu receives with nothing\n", calls, sent, got, empty);
    }
}
