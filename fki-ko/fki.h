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
/*
 * Physically contiguous memory with real physical addresses (for a foreign kernel whose own page tables
 * the hardware walks). va is a kernel linear-map address (RW, not executable). size rounds up to a power of two.
 */
int fki_contig_alloc(unsigned long size, struct fki_region *r);
void fki_contig_free(struct fki_region *r);
/*
 * The top foreign window: the L1 table that Linux's TTBR1 L0 entry for va points to. A foreign kernel may
 * own L1 entries Linux leaves empty in that table; fki_window_set installs one (then a full TLB flush).
 */
int fki_window_l1(unsigned long va, unsigned long long **l1_va, fki_u64 *l1_pa);
void fki_window_set(unsigned long long *slot, fki_u64 desc);
/*
 * Called from inside fki_enter() (preemption and IRQs off): let Linux run (IRQs and preemption on)
 * until the counter reaches deadline or max_ns pass, then return with them off again.
 */
void fki_idle_until(fki_u64 counter_deadline, fki_u64 max_ns);
/* Keep the calling task on one CPU (the hosted kernel sees that CPU's MPIDR). */
int fki_bind_cpu(int cpu);
/*
 * A helper kernel thread bound to one CPU: fn(arg) runs until it returns or fki_thread_stop() is called;
 * fn should loop on !fki_thread_should_stop() and sleep with fki_msleep().
 */
void *fki_thread_start(int (*fn)(void *), void *arg, int cpu, const char *name);
void fki_thread_stop(void *thread);
int fki_thread_should_stop(void);
void fki_msleep(unsigned int ms);
/*
 * Foreign kernel faults: a kernel-mode data or instruction abort whose address is in [lo, hi) is offered to handler
 * (far, esr, the faulting pt_regs) before Linux's own handling; handler returns 0 when it made the access retryable
 * (the faulting instruction then runs again), nonzero to let Linux handle it as usual. One registration at a time.
 */
int fki_fault_register(unsigned long lo, unsigned long hi, int (*handler)(unsigned long far, unsigned long esr, void *regs));
void fki_fault_unregister(void);
#ifdef __cplusplus
}
#endif
#endif
