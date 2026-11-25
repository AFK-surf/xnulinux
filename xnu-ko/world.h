// SPDX-License-Identifier: APSL-2.0
/* World switch between Linux and the hosted XNU (see world.S / world_x86.S for the layouts). */
#pragma once
#include "../fki-ko/fki.h"

#ifdef CONFIG_X86_64
/*
 * x86_64: XNU owns IDT/GDT/TSS/CR3 and %gs (cpu_data) while it runs. Linux's state is
 * saved here on entry and restored before every upcall into xnu_hook, because Linux's
 * `current` is read through %gs and its #PF path must never see XNU's descriptors.
 * Layout offsets are mirrored in world_x86.S and checked with _Static_assert below.
 */
struct xnu_dtreg {
	unsigned short limit;
	unsigned long long base;
} __attribute__((packed, aligned(16)));

struct xnu_world {
	/* Linux state, saved by xnu_world_call */
	unsigned long long linux_rbx, linux_rbp, linux_r12, linux_r13, linux_r14, linux_r15, linux_rsp;
	unsigned long long linux_gs_base, linux_kernel_gs_base, linux_cr3;
	struct xnu_dtreg linux_idt, linux_gdt;
	unsigned long long linux_tr;
	unsigned long long irq_flags;
	struct fki_pac_keys keys_saved;
	/* XNU state, saved by xnu_world_upcall (zero until XNU's vstart has run) */
	unsigned long long xnu_rbx, xnu_rbp, xnu_r12, xnu_r13, xnu_r14, xnu_r15, xnu_rsp;
	unsigned long long xnu_gs_base, xnu_kernel_gs_base, xnu_cr3;
	struct xnu_dtreg xnu_idt, xnu_gdt;
	unsigned long long xnu_tr;
};
_Static_assert(__builtin_offsetof(struct xnu_world, linux_rbx) == 0, "x86 world layout");
_Static_assert(__builtin_offsetof(struct xnu_world, linux_gs_base) == 56, "x86 world layout");
_Static_assert(__builtin_offsetof(struct xnu_world, linux_cr3) == 72, "x86 world layout");
_Static_assert(__builtin_offsetof(struct xnu_world, linux_idt) == 80, "x86 world layout");
_Static_assert(__builtin_offsetof(struct xnu_world, linux_gdt) == 96, "x86 world layout");
_Static_assert(__builtin_offsetof(struct xnu_world, linux_tr) == 112, "x86 world layout");
_Static_assert(__builtin_offsetof(struct xnu_world, irq_flags) == 120, "x86 world layout");
_Static_assert(__builtin_offsetof(struct xnu_world, keys_saved) == 128, "x86 world layout");
_Static_assert(__builtin_offsetof(struct xnu_world, xnu_rbx) == 216, "x86 world layout");
_Static_assert(__builtin_offsetof(struct xnu_world, xnu_gs_base) == 272, "x86 world layout");
_Static_assert(__builtin_offsetof(struct xnu_world, xnu_cr3) == 288, "x86 world layout");
_Static_assert(sizeof(struct fki_pac_keys) == 88, "fki_pac_keys layout");
_Static_assert(__builtin_offsetof(struct xnu_world, xnu_idt) == 304, "x86 world layout");
_Static_assert(__builtin_offsetof(struct xnu_world, xnu_gdt) == 320, "x86 world layout");
_Static_assert(__builtin_offsetof(struct xnu_world, xnu_tr) == 336, "x86 world layout");
_Static_assert(sizeof(struct xnu_world) == 352, "x86 world layout");
#else
struct xnu_world {
	unsigned long long linux_regs[14];	/* 0: x19..x28, x29, x30, sp, irq cookie */
	unsigned long long xnu_regs[13];	/* 112: x19..x28, x29, x30, sp */
	unsigned long long linux_tpidr0;		/* 216: TPIDR_EL0 */
	unsigned long long linux_tpidrro0;	/* 224: TPIDRRO_EL0 */
	unsigned long long xnu_stack_top;	/* 232 */
	struct fki_pac_keys linux_keys;		/* 240 */
	struct fki_pac_keys xnu_keys;		/* 328 */
	unsigned long long linux_ttbr0, linux_tcr;	/* 416, 424: Linux's user address space while XNU runs */
	unsigned long long xnu_ttbr0, xnu_tcr;		/* 432, 440: XNU's (its user pmaps, its T0SZ) */
	unsigned long long xnu_tpidr, xnu_tpidrro;	/* 448, 456: XNU's user TLS registers across an upcall */
	unsigned long long linux_scs;		/* 464: x18, the shadow call stack of the Linux task that entered */
};
_Static_assert(__builtin_offsetof(struct xnu_world, linux_scs) == 464, "xnu_world layout");
_Static_assert(__builtin_offsetof(struct xnu_world, xnu_tpidrro) == 456, "xnu_world layout");
_Static_assert(__builtin_offsetof(struct xnu_world, linux_ttbr0) == 416, "xnu_world layout");
_Static_assert(sizeof(struct fki_pac_keys) == 88, "fki_pac_keys layout");
_Static_assert(__builtin_offsetof(struct xnu_world, xnu_keys) == 328, "xnu_world layout");
#endif

extern struct xnu_world xnu_W;		/* the boot CPU's */
extern struct xnu_world *xnu_worlds[];	/* each CPU's, by slot (LINUX64_CPU_SLOT) */
/* Run fn(arg) in the XNU world. 0: fn returned; 1: an upcall ended the run. */
long xnu_world_call(unsigned long fn, unsigned long arg);
/* The address XNU calls (linux64_hook): SysV rdi/rsi/rdx, answer in rax. */
long xnu_world_upcall(unsigned long stage, unsigned long a1, unsigned long a2);
/* Where an XNU fault that cannot be handled returns to (still with XNU's keys): back to Linux's, then xnu_world_abort. */
void xnu_world_fault_abort(void);
/* Linux-world handler: return 0 to resume XNU, nonzero to end the run. */
long xnu_hook(unsigned long stage, unsigned long a1, unsigned long a2);

#ifdef CONFIG_X86_64
/* Assembly primitives; the wrappers above resolve this CPU's save area. */
long xnu_world_switch_in(struct xnu_world *w, unsigned long fn, unsigned long arg);
long xnu_world_abort(struct xnu_world *w);
long xnu_world_upcall_asm(struct xnu_world *w, unsigned long stage, unsigned long a1, unsigned long a2);
#endif
