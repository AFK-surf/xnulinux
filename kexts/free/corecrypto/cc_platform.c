// SPDX-License-Identifier: APSL-2.0
/*
 * Copyright (c) 2026 xnulinux contributors. All rights reserved.
 *
 * @APPLE_OSREFERENCE_LICENSE_HEADER_START@
 * This file contains Original Code and/or Modifications of Original Code as defined in and that are subject to the Apple
 * Public Source License Version 2.0 (the 'License'). You may not use this file except in compliance with the License.
 * @APPLE_OSREFERENCE_LICENSE_HEADER_END@
 */
/* Memory for Mbed TLS (RSA's big numbers), and the random numbers: the host's. */
#include "cc_internal.h"
#if !CC_TEST_USERSPACE
#include <IOKit/IOLib.h>
#endif

/* each block carries its size, which IOFreeData needs */
struct block {
	size_t size;
	uint64_t data[];
};

void *
xnulinux_cc_calloc(size_t n, size_t size)
{
	struct block *b;
	size_t bytes;

	if (n != 0 && size > (SIZE_MAX - sizeof(struct block)) / n) {
		return NULL;
	}
	bytes = sizeof(struct block) + n * size;
#if CC_TEST_USERSPACE
	b = calloc(1, bytes);
#else
	b = IOMallocZeroData(bytes);
#endif
	if (b == NULL) {
		return NULL;
	}
	b->size = bytes;
	return b->data;
}

void
xnulinux_cc_free(void *p)
{
	struct block *b;

	if (p == NULL) {
		return;
	}
	b = (struct block *)((uint8_t *)p - offsetof(struct block, data));
	cc_clear(b->size, b);
#if CC_TEST_USERSPACE
	free(b);
#else
	IOFreeData(b, b->size);
#endif
}

/* Mbed TLS formats OIDs as text only for display, which nothing here asks for */
int
xnulinux_cc_snprintf(char *s, size_t n, const char *format, ...)
{
	(void)format;
	if (n > 0) {
		s[0] = 0;
	}
	return -1;
}

/* the generator every ccrng caller gets: the host's */
static int
host_generate(struct ccrng_state *rng, size_t outlen, void *out)
{
	(void)rng;
	xc_random(out, outlen);
	return 0;
}

static struct ccrng_state host_rng = { .generate = host_generate };

struct ccrng_state *
xc_rng(int *error)
{
	if (error != NULL) {
		*error = 0;
	}
	return &host_rng;
}

/* uniform in [0, bound), by rejection (no modulo bias) */
int
xc_rng_uniform(struct ccrng_state *rng, uint64_t bound, uint64_t *rand)
{
	uint64_t v, limit;

	if (bound == 0) {
		return CCERR_PARAMETER;
	}
	limit = -bound % bound;
	do {
		int rc = ccrng_generate(rng, sizeof(v), &v);
		if (rc != 0) {
			return rc;
		}
	} while (v < limit);
	*rand = v % bound;
	return 0;
}
