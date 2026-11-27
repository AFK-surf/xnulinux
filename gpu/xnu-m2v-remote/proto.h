// SPDX-License-Identifier: GPL-2.0-or-later
// libxnu_m2v's C interface (xnu_m2v.h) over a byte stream.
//
// A call is a message: struct xr_hdr, then its arguments in 8-byte slots (a handle is the id the caller gave the object
// when it made it, so making an object needs no answer), strings and structures padded to 8 bytes, and for some a raw
// tail. A message with req != 0 is answered: struct xr_ans with the same req, then the answer's bytes. The server also
// sends answers nobody asked for: req == XR_CALLBACK, a shared event's notification (token, value).
#ifndef XR_PROTO_H
#define XR_PROTO_H
#include <stdint.h>
#include "gen_ops.h"
struct xr_hdr { uint32_t op; uint32_t pad; uint64_t len; uint64_t req; };	// len: the bytes after the header
struct xr_ans { uint64_t req; uint64_t len; };
#define XR_CALLBACK (~0ull)
#define XR_PAGE 4096ull	// the unit a buffer's changes are found and sent in
#define XR_VERSION 3
#define XR_MAX_MSG ((4ull << 30) + (1 << 20))	// a buffer's first contents are one message, and a buffer is 4 GB at most
// A page's fingerprint: what changed since it was last sent is found by comparing these.
static inline uint64_t xr_hash(const uint8_t *p, uint64_t n) {
    uint64_t h0 = 0x9e3779b97f4a7c15ull, h1 = 0xc2b2ae3d27d4eb4full, h2 = 0x165667b19e3779f9ull, h3 = 0x27d4eb2f165667c5ull, v[4];
    while (n >= 32) {
        __builtin_memcpy(v, p, 32);
        h0 = (h0 ^ v[0]) * 0x9fb21c651e98df25ull; h0 ^= h0 >> 29;
        h1 = (h1 ^ v[1]) * 0x9fb21c651e98df25ull; h1 ^= h1 >> 29;
        h2 = (h2 ^ v[2]) * 0x9fb21c651e98df25ull; h2 ^= h2 >> 29;
        h3 = (h3 ^ v[3]) * 0x9fb21c651e98df25ull; h3 ^= h3 >> 29;
        p += 32; n -= 32;
    }
    while (n) { h0 = (h0 ^ *p++) * 0x100000001b3ull; n--; }
    h0 ^= h1 * 3 + (h2 << 7 | h2 >> 57) + (h3 << 19 | h3 >> 45);
    h0 ^= h0 >> 32; h0 *= 0xd6e8feb86659fd93ull; h0 ^= h0 >> 32;
    return h0;
}
#endif
