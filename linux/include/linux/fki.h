/* SPDX-License-Identifier: GPL-2.0-only WITH Linux-syscall-note */
/*
 * Foreign kernel interface (FKI), version 0.
 *
 * The only interface between Linux and a foreign-kernel module. It is
 * semantic and shaped like a hypervisor interface: plain integer types and
 * opaque handles, no Linux structure crosses it. A foreign module includes
 * this header only.
 */
#ifndef _LINUX_FKI_H
#define _LINUX_FKI_H

#define FKI_VERSION 0

#ifndef __KERNEL__
#include <stdint.h>
typedef uint64_t fki_u64;
#else
#include <linux/types.h>
typedef u64 fki_u64;
#endif

/* Physically contiguous memory, mapped contiguously and executable. */
struct fki_region {
	void *va;
	fki_u64 pa;
	fki_u64 size;
	void *handle;
};

/* Pointer authentication keys (each 128 bits: lo, hi). */
struct fki_pac_keys {
	fki_u64 ia[2], ib[2], da[2], db[2], ga[2];
	fki_u64 sctlr_en;	/* SCTLR_EL1 EnIA|EnIB|EnDA|EnDB bits */
};

#ifdef __cplusplus
extern "C" {
#endif
int fki_version(void);
void fki_log(const char *s, unsigned long len);
int fki_region_alloc(unsigned long size, struct fki_region *r);
void fki_region_free(struct fki_region *r);
/* A named blob from the firmware search path. */
int fki_blob_get(const char *name, const void **data, unsigned long *size, void **handle);
void fki_blob_put(void *handle);
/* Enter and leave a foreign context on this CPU: no preemption, no interrupts, foreign PAC keys. */
unsigned long fki_enter(const struct fki_pac_keys *foreign, struct fki_pac_keys *saved);
void fki_leave(unsigned long cookie, const struct fki_pac_keys *saved);
/* Swap PAC keys only (caller already in a foreign context): save current into *save, load *load. */
void fki_pac_swap(const struct fki_pac_keys *load, struct fki_pac_keys *save);
fki_u64 fki_counter_frequency(void);
fki_u64 fki_counter(void);
void fki_random(void *buf, unsigned long len);
#ifdef __cplusplus
}
#endif
#endif
