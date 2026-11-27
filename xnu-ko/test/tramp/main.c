// SPDX-License-Identifier: APSL-2.0
/*
 * xnu.ko's fault trampoline (xnu_fault_tramp, cut out of the tree's xnu-ko/world.S as it is) entered as Linux's
 * exception return enters it: every register as the faulting context had it, here all 32 FP/SIMD registers, FPSR and
 * FPCR holding known values. The stand-in for xnu_fault_deferred does to them what resolving a fault may do (writes
 * all of them) and returns where to go on; what the context finds in them after the trampoline's eret is reported.
 * Loading the module is the test; it never stays loaded. Like xnu.ko it calls Linux only through fki (run.sh).
 */
#include <linux/module.h>
#include "fki.h"

struct tramptest_out { unsigned char q[32][16]; unsigned long fpsr, fpcr; };
unsigned long tramptest_resume, tramptest_spsr;
void tramptest_run(struct tramptest_out *out);
void tramptest_clobber(void);

/* (no pointer authentication in the two functions that run with the test's keys loaded, as in fki's own entry) */
#define NO_PAC __attribute__((target("branch-protection=none")))
static struct fki_pac_keys keys = { .sctlr_en = ~0ULL };

unsigned long xnu_fault_deferred(unsigned long *frame);
NO_PAC unsigned long xnu_fault_deferred(unsigned long *frame)
{
	frame[31] = tramptest_spsr;	/* the SPSR the trampoline returns with */
	tramptest_clobber();
	return tramptest_resume;
}

static NO_PAC int __init tramptest_init(void)
{
	static struct tramptest_out out;
	struct fki_pac_keys saved;
	unsigned long c;
	int i, j, changed = 0;

	c = fki_enter(&keys, &saved);	/* as xnu.ko enters XNU: interrupts off, the CPU's FP/SIMD registers no longer Linux's */
	tramptest_run(&out);
	fki_leave(c, &saved);
	for (i = 0; i < 32; i++) {
		for (j = 0; j < 16; j++)
			if (out.q[i][j] != 0x40 + i)
				break;
		if (j < 16)
			changed++;
	}
	pr_info("tramptest: after the trampoline %d of 32 vector registers are not what the context left in them (v0 = %02x..., v2 = %02x..., v31 = %02x...; set to 40, 42, 5f); FPSR %#lx (set to 0x1f), FPCR %#lx (set to 0xc00000)\n",
		changed, out.q[0][0], out.q[2][0], out.q[31][0], out.fpsr, out.fpcr);
	pr_info("tramptest: %s\n", changed || out.fpsr != 0x1f || out.fpcr != 0xc00000 ? "FAIL" : "ok");
	return -EAGAIN;
}
module_init(tramptest_init);
MODULE_LICENSE("Proprietary");	/* as xnu.ko: it carries xnu-ko/world.S's trampoline */
