// SPDX-License-Identifier: APSL-2.0
/*
 * xnu.ko: hosts an XNU kernel image inside Linux. Talks to Linux only
 * through FKI (fki.h); <linux/module.h> provides the module ABI.
 *
 * mode=1 (M1): load, slide and sign the image, call two XNU functions.
 * mode=2 (M2a, default): hand XNU boot args and an ADT and run arm_init in
 *        the XNU world; XNU reports stages through linux64_hook, and the run
 *        ends at stage `stop`.
 */
#include <linux/module.h>
#include "../fki-ko/fki.h"
#include "xrt.h"
#include "macho.h"
#include "adt.h"
#include "world.h"

static char *image = "xnu/kernel.macho";
module_param(image, charp, 0444);
static int mode = 2;
module_param(mode, int, 0444);
static int stop = 199;
module_param(stop, int, 0444);
static int ram_mb = 256;
module_param(ram_mb, int, 0444);
static int kmax;	/* end the run after this many XNU kprintf lines (0: no limit) */
module_param(kmax, int, 0444);
static int kcount;
static int idle_max = 200;	/* end the run after this many XNU idle rounds (0: never) */
module_param(idle_max, int, 0444);
static int quiet_console = 1;	/* drop the known high-volume console and kprintf lines (see quiet_line) */
module_param(quiet_console, int, 0444);
static int quiet_line(const char *l, unsigned n)
{
	static const char *const pfx[] = { "com.apple.xpc.launchd|", "kmutil: AppleImage4", "cryptexd: AppleImage4", "ACMTRM", "ACM:",
		"AppleCredentialManagerUserClient", "hfs: set hardlink bit", "Couldn't alloc class", "  dynamic: platformVersion" };
	for (unsigned i = 0; i < sizeof(pfx) / sizeof(pfx[0]); i++) {
		unsigned k = 0;
		while (pfx[i][k] && k < n && l[k] == pfx[i][k]) k++;
		if (!pfx[i][k]) return 1;
	}
	for (unsigned k = 0; k + 18 <= n; k++)	/* "... triggered unnest of range ..." */
		if (!x_strncmp(l + k, "triggered unnest", 16)) return 1;
	return 0;
}
static int assert_fatal;	/* 1: a failed XNU assert() ends the run; 0: report it and let XNU continue */
module_param(assert_fatal, int, 0444);

static struct xnu_image img;
static struct fki_region l2page;
static unsigned long long *window_slot, *window_l1;
static unsigned char window_owned[512];
static u64_t diag_va[6];
#define XNU_L1_FIRST 384	/* VM_MIN_KERNEL_ADDRESS 0xffffffe000000000 */
#define XNU_L1_LAST 495	/* VM_MAX_KERNEL_ADDRESS 0xfffffffbffffffff */
static void *blob;
/* A root RAM disk (firmware blob): placed in XNU's DRAM after the ADT, /chosen/memory-map RAMDisk, boot-arg rd=md0. */
static char *ramdisk;
/* Extra XNU boot arguments, appended to the built-in command line */
static char *bootargs;
module_param(bootargs, charp, 0444);
module_param(ramdisk, charp, 0444);
static const void *rd_data; static unsigned long rd_size; static void *rd_blob;
/* A root disk backed by a host file (an HFS+ image): XNU's memdev md0 in host mode, stages 995 (size) and 994 (I/O). */
static char *hostdisk;
static int hostdisk_rw;
module_param(hostdisk, charp, 0444);
module_param(hostdisk_rw, int, 0444);
static void *hd_file; static fki_u64 hd_size;
/* Console input for XNU's /dev/console: bytes appended to this host file are typed in (stage 993) */
static char *console_in;
module_param(console_in, charp, 0444);
static void *ci_file; static fki_u64 ci_off;
struct xnu_cons_req { void *buf; u64_t len; long result; };
/* hook returns must be 0 (nonzero ends the run): results come back through the request */
struct xnu_hostdisk_req { u64_t write, off, len; void *buf; long result; };
struct xnu_world xnu_W;

static void logs(const char *s) { fki_log(s, x_strlen(s)); }
static void logkv(const char *k, u64_t v)
{
	char buf[96]; char *p = buf;
	while (*k) *p++ = *k++;
	*p++ = ' '; *p++ = '0'; *p++ = 'x';
	for (int i = 60; i >= 0; i -= 4) *p++ = "0123456789abcdef"[(v >> i) & 15];
	*p = 0;
	logs(buf);
}

/* ---- M1 ---- */
typedef unsigned long (*strlen_fn)(const char *);
typedef unsigned int (*crc32_fn)(unsigned int, const void *, unsigned long);

static int run_m1(void)
{
	struct fki_pac_keys saved; unsigned long c;
	c = fki_enter(&xnu_W.xnu_keys, &saved);
	int n = macho_rebase(&img);
	fki_leave(c, &saved);
	logkv("xnu: threaded fixups applied", (u64_t)n);
	if (n < 0) return n;
	u64_t v = macho_sym(&img, "_version"), sl = macho_sym(&img, "_strlen"), cr = macho_sym(&img, "_crc32");
	if (!v || !sl || !cr) { logs("xnu: symbols missing"); return 0; }
	c = fki_enter(&xnu_W.xnu_keys, &saved);
	unsigned long len = ((strlen_fn)sl)((const char *)v);
	unsigned int crc = ((crc32_fn)cr)(0, (const void *)v, len);
	fki_leave(c, &saved);
	logs("xnu: XNU code ran inside Linux; XNU's version string:");
	fki_log((const char *)v, len);
	logkv("xnu: strlen(version) computed by XNU", len);
	logkv("xnu: crc32(version) computed by XNU", crc);
	return 0;
}

/* ---- M2a ---- */
#define XNU_FAKE_PHYS 0x800000000ULL	/* XNU's view of the region's first byte */
#define BOOT_LINE 1024

struct boot_args_v2 {			/* pexpert/arm64/boot.h layout */
	unsigned short Revision, Version;
	u64_t virtBase, physBase, memSize, topOfKernelData;
	struct { u64_t v_baseAddr, v_display, v_rowBytes, v_width, v_height, v_depth; } Video;
	unsigned int machineType;
	void *deviceTreeP;
	unsigned int deviceTreeLength;
	char CommandLine[BOOT_LINE];
	u64_t bootFlags, memSizeActual;
};

static const char *cmdline = "debug=0x8 -v -noprogress serial=0 startup_debug=1 vm_compression_limit=1572864";


/* Walk XNU's kernel tables (inside its contiguous DRAM) for va and log the descriptors. */
static unsigned long long *tbl_va(u64_t desc)
{
	u64_t pa = desc & 0x0000fffffffff000ULL;
	if (pa < img.region.pa || pa >= img.region.pa + img.region.size) return 0;
	return (unsigned long long *)((char *)img.region.va + (pa - img.region.pa));
}

static void walk_log(const char *what, u64_t va, const unsigned long long *l1)
{
	u64_t d1 = l1[(va >> 30) & 511], d2 = 0, d3 = 0;
	logs(what);
	logkv("xnu:   va", va);
	logkv("xnu:   L1", d1);
	if ((d1 & 3) == 3) {
		unsigned long long *t2 = tbl_va(d1);
		if (!t2) { logs("xnu:   L2 table outside XNU DRAM"); return; }
		d2 = t2[(va >> 21) & 511];
		logkv("xnu:   L2", d2);
		if ((d2 & 3) == 3) {
			unsigned long long *t3 = tbl_va(d2);
			if (!t3) { logs("xnu:   L3 table outside XNU DRAM"); return; }
			d3 = t3[(va >> 12) & 511];
			logkv("xnu:   L3", d3);
		}
	}
}

/*
 * Kernel page faults on XNU addresses, taken in Linux's vectors while XNU runs (XNU's keys and stack live), go to
 * XNU's own linux64_kernel_fault (vm_fault on the kernel map). in_xnu is 0 while host code runs (upcalls, monitor).
 */
static volatile int in_xnu;
static unsigned long (*xnu_kfault)(unsigned long far, unsigned long esr);
static unsigned long (*xnu_kfault_recover)(unsigned long pc, unsigned long far, unsigned long esr);
static unsigned long kfaults;

#define XNU_VA_LO 0xffffffe000000000ULL
#define XNU_VA_HI 0xfffffffc00000000ULL
/*
 * A kernel fault XNU's vm_fault should resolve is not resolved here, inside Linux's exception handler (a kprobe: no
 * sleeping, no rescheduling, and a nested fault in it is a missed kprobe and an oops), because vm_fault may page in
 * from disk (a file I/O upcall that lets Linux schedule) or block the thread. The exception instead returns into
 * xnu_fault_tramp (world.S) with every register as it was; the trampoline calls xnu_fault_deferred in XNU's own
 * context, then returns (eret) to the faulting instruction, to the copyio recovery path, or to the abort.
 */
static struct { unsigned long far, esr, pc, pstate; } xnu_deferred;
extern void xnu_fault_tramp(void);
extern void xnu_world_fault_abort(void);

unsigned long xnu_fault_deferred(unsigned long *frame);
unsigned long xnu_fault_deferred(unsigned long *frame)
{
	unsigned long far = xnu_deferred.far, esr = xnu_deferred.esr, pc = xnu_deferred.pc;
	static unsigned long last_far, repeats;

	frame[31] = xnu_deferred.pstate;	/* the SPSR the trampoline returns with */
	repeats = (far == last_far) ? repeats + 1 : 0;
	last_far = far;
	/*
	 * The same address faulting again is normal (libmalloc's MADV_FREE_REUSABLE clears a page's referenced and
	 * modified state, so each reuse takes one fault). Only report it, rarely, when it looks endless.
	 */
	if (xnu_kfault(far, esr) == 0) {
		if (repeats && (repeats & (repeats - 1)) == 0 && repeats >= 1024) {
			logkv("xnu: one address keeps taking resolved kernel faults, repeats", repeats);
			logkv("xnu:   far", far);
			logkv("xnu:   esr", esr);
			logkv("xnu:   pc ", pc);
			logkv("xnu:   lr ", frame[30]);
		}
		/* a fault loop runs with interrupts masked: let Linux take its interrupts now and then (RCU, network) */
		if ((repeats & 63) == 63)
			((void (*)(unsigned long, unsigned long, unsigned long))xnu_world_upcall)(811, 0, 0);
		return pc;
	}
	/* inside copyin/copyout: the routine's recovery path returns EFAULT to its caller, as XNU's own abort handler does */
	if (xnu_kfault_recover) {
		unsigned long rpc = xnu_kfault_recover(pc, far, esr);
		if (rpc) {
			frame[0] = 14;	/* EFAULT */
			return rpc;
		}
	}
	in_xnu = 0;
	logs("xnu: XNU took a fault vm_fault cannot resolve; ending the run");
	logkv("xnu:   pc ", pc);
	logkv("xnu:   lr ", frame[30]);
	logkv("xnu:   far", far);
	logkv("xnu:   esr", esr);
	return (unsigned long)xnu_world_fault_abort;
}

static int xnu_fault(unsigned long far, unsigned long esr, void *regs)
{
	if (!in_xnu)
		return 1;
	unsigned long fpc = fki_regs_pc(regs);
	if (far && ((far >= XNU_VA_LO && far < XNU_VA_HI) || far < 0x0001000000000000ULL) && xnu_kfault &&
	    fpc >= XNU_VA_LO && fpc < XNU_VA_HI) {
		kfaults++;
		xnu_deferred.far = far;
		xnu_deferred.esr = esr;
		xnu_deferred.pc = fpc;
		xnu_deferred.pstate = fki_regs_pstate(regs);
		fki_regs_set_pc(regs, (unsigned long)xnu_fault_tramp);
		return 0;
	}
	/*
	 * An XNU fault nothing resolves (a bug, or a NULL dereference): report it and end the run instead of letting Linux
	 * oops with XNU's keys and stack live (which takes the machine with it). The exception returns into
	 * xnu_world_fault_abort, which puts Linux's keys back and leaves through xnu_world_abort.
	 */
	unsigned long pc = fki_regs_pc(regs);
	if (pc < XNU_VA_LO || pc >= XNU_VA_HI)
		return 1;
	/* inside copyin/copyout: the routine's recovery path returns EFAULT to its caller, as XNU's own abort handler does */
	if (xnu_kfault_recover) {
		unsigned long rpc = xnu_kfault_recover(pc, far, esr);
		if (rpc) {
			fki_regs_set_reg(regs, 0, 14);	/* EFAULT */
			fki_regs_set_pc(regs, rpc);
			return 0;
		}
	}
	in_xnu = 0;
	logs("xnu: XNU took a fault it cannot handle; ending the run");
	logkv("xnu:   pc ", pc);
	logkv("xnu:   lr ", fki_regs_lr(regs));
	logkv("xnu:   far", far);
	logkv("xnu:   esr", esr);
	fki_regs_set_pc(regs, (unsigned long)xnu_world_fault_abort);
	return 0;
}

static long xnu_hook_body(unsigned long stage, unsigned long a1, unsigned long a2);
long xnu_hook(unsigned long stage, unsigned long a1, unsigned long a2)
{
	{
		/* debugging: an XNU stack Linux's overflow check would reject (bit 14 of sp set) */
		static int told;
		unsigned long sp;
		__asm__ volatile("mov %0, sp" : "=r"(sp));
		if ((sp & 0x4000) && told < 3) {
			told++;
			logkv("xnu: upcall on an XNU stack with sp bit 14 set, sp", sp);
			logkv("xnu:   stage", stage);
		}
	}
	in_xnu = 0;
	long r = xnu_hook_body(stage, a1, a2);
	if (!r) in_xnu = 1;
	return r;
}

static long xnu_hook_body(unsigned long stage, unsigned long a1, unsigned long a2)
{
	if (stage == 993) {		/* console input: new bytes of console_in */
		struct xnu_cons_req *q = (struct xnu_cons_req *)a1;
		if (!q) return 0;
		q->result = 0;
		if (ci_file) {
			long n = fki_file_rw(ci_file, 0, q->buf, (unsigned long)q->len, ci_off);
			if (n > 0) { ci_off += n; q->result = n; }
		}
		return 0;
	}
	if (stage == 812) {		/* the host's wall clock for XNU's calendar: a1 -> u64[2] {seconds, nanoseconds} UTC */
		if (a1) fki_realtime(&((fki_u64 *)a1)[0], &((fki_u64 *)a1)[1]);
		return 0;
	}
	if (stage == 995) {		/* host disk size in bytes into *a1, 0 when there is none */
		if (a1) *(u64_t *)a1 = hd_file ? hd_size : 0;
		return 0;
	}
	if (stage == 994) {		/* host disk I/O: q->result = bytes moved or -errno */
		struct xnu_hostdisk_req *q = (struct xnu_hostdisk_req *)a1;
		if (!q) return 0;
		if (!hd_file) q->result = -6;
		else if (q->write && !hostdisk_rw) q->result = -30;
		else q->result = fki_file_rw(hd_file, (int)q->write, q->buf, (unsigned long)q->len, q->off);
		return 0;
	}
	if (stage == 996) {		/* XNU console bytes (/dev/console): line-buffered into the host log */
		static char line[1000]; static unsigned n;
		const char *b = (const char *)a1; unsigned long i;
		for (i = 0; b && i < a2; i++) {
			char c = b[i];
			if (c == '\r') continue;
			if (c != '\n') line[n++] = c;
			if (c == '\n' || n == sizeof(line) - 1) {
				static char m[1024]; unsigned j = 0, k;
				const char *p = "darwin console: ";
				while (*p) m[j++] = *p++;
				for (k = 0; k < n; k++) m[j++] = line[k];
				m[j] = 0;
				/* quiet_console: launchd's and AppleImage4's chatter (thousands of lines a second) stays out */
				if (!(quiet_console && quiet_line(line, n)))
					logs(m);
				n = 0;
			}
		}
		/* a prompt (a write that ends in "# ", "$ " or "> " without a newline): show it now */
		if (n >= 2 && line[n - 1] == ' ' && (line[n - 2] == '#' || line[n - 2] == '$' || line[n - 2] == '>')) {
			static char m[1024]; unsigned j = 0, k;
			const char *p = "darwin console: ";
			while (*p) m[j++] = *p++;
			for (k = 0; k < n; k++) m[j++] = line[k];
			m[j] = 0; n = 0;
			logs(m);
		}
		return 0;
	}
	if (stage == 998) {		/* XNU kprintf */
		char m[260]; const char *f = (const char *)a1; unsigned i = 0, j = 0;
		m[j++] = 'x'; m[j++] = 'n'; m[j++] = 'u'; m[j++] = ']'; m[j++] = ' ';
		while (f && f[i] && j < sizeof(m) - 1) { if (f[i] != '\n') m[j++] = f[i]; i++; }
		m[j] = 0;
		/* the per-entry startup trace is thousands of lines: count it, do not print it */
		if (!(f && !x_strncmp(f, "kernel_startup_initialize_upto[", 31)) && !(quiet_console && quiet_line(m + 5, j - 5)))
			logs(m);
		if (kmax && ++kcount >= kmax) { logs("xnu: kprintf budget reached"); return 1; }
		return 0;
	}
	if (stage == 210 && window_l1) {	/* install XNU's kernel L1 entries (the kernel VA range only) */
		const unsigned long long *tte = (const unsigned long long *)a1;
		walk_log("xnu: XNU table walk for arm_init (text)", diag_va[0], tte);
		walk_log("xnu: XNU table walk for the Mach-O header", diag_va[1], tte);
		walk_log("xnu: XNU table walk for boot args", diag_va[2], tte);
		walk_log("xnu: XNU table walk for the cpu_tte page", a1, tte);
		int n = 0, last = -1;
		for (int i = XNU_L1_FIRST; i <= XNU_L1_LAST; i++) {
			if (!(tte[i] & 1)) continue;
			if (window_l1[i] && &window_l1[i] != window_slot) { logkv("xnu: L1 slot in use by Linux, refusing:", i); return 1; }
			window_l1[i] = tte[i]; window_owned[i] = 1; n++; last = i;
		}
		if (last >= 0) fki_window_set(&window_l1[last], tte[last]);	/* barrier + TLB flush */
		logkv("xnu: XNU L1 entries installed", n);
		/* Touch XNU memory through XNU's own tables now (Linux context: a fault here is a readable oops). */
		logkv("xnu: probe text word", *(volatile unsigned int *)diag_va[0]);
		logkv("xnu: probe Mach-O magic", *(volatile unsigned int *)diag_va[1]);
		logkv("xnu: probe boot args Version", ((volatile struct boot_args_v2 *)diag_va[2])->Version);
		logkv("xnu: probe ADT word", *(volatile unsigned int *)diag_va[3]);
		if (diag_va[4]) { volatile unsigned int *pc = (void *)diag_va[4]; unsigned v = *pc; *pc = v; logkv("xnu: probe port_crumb (rw)", v); }
		if (diag_va[5]) { unsigned long l = ((unsigned long (*)(const char *))diag_va[5])("xnulinux"); logkv("xnu: probe exec strlen through XNU tables", l); }
		logs("xnu: probes done");
	}
	if (stage == 811) {		/* XNU busy: a host IRQ preempted its user code; let Linux handle it */
		fki_yield();
		return 0;
	}
	if (stage == 810) {		/* XNU idle: let Linux run until XNU's next timer deadline */
		static unsigned long idles;
		if ((++idles & (idles - 1)) == 0) logkv("xnu: XNU idle, count", idles);
		fki_idle_until(a1, 20000000ULL);	/* at most 20 ms per round */
		return idle_max && idles >= (unsigned long)idle_max;
	}
	if (stage == 997) {		/* XNU assert() failed */
		const struct { const char *file; long line; const char *expr; } *a = (const void *)a1;
		char m[240]; unsigned j = 0, i;
		const char *parts[3] = { "xnu: XNU assert failed: ", a->file, ": " };
		for (int p = 0; p < 3; p++)
			for (i = 0; parts[p] && parts[p][i] && j < sizeof(m) - 1; i++) m[j++] = parts[p][i];
		for (i = 0; a->expr && a->expr[i] && j < sizeof(m) - 1; i++) m[j++] = a->expr[i];
		m[j] = 0;
		logs(m);
		logkv("xnu:   at line", a->line);
		return assert_fatal;
	}
	if (stage == 9100) {		/* the first entry into user space (linux64_el0_run follows) */
		logkv("xnu: XNU enters user space (EL0); user pc", a1);
		return 0;
	}
	if (stage == 999) {
		char m[500]; const char *f = (const char *)a1; unsigned i = 0;
		while (f && f[i] && i < sizeof(m) - 1) { m[i] = f[i]; i++; }
		m[i] = 0;
		logs("xnu: XNU panic:");
		logs(m);
		logkv("xnu: panic caller", a2);
		return 1;
	}
	static const struct { unsigned long s; const char *what; } names[] = {
		{ 101, "image slid, structors signed" }, { 110, "PE_init_platform: ADT parsed" },
		{ 120, "ml_parse_cpu_topology" }, { 130, "kernel_startup_bootstrap returned" },
		{ 140, "timer_call_init" }, { 150, "cpu_init" }, { 160, "processor_bootstrap" },
		{ 170, "boot-arg parsing" }, { 175, "nanoseconds_to_absolutetime" }, { 180, "/chosen dram-base/size" },
		{ 199, "arm_init reached arm_vm_init" },
		{ 201, "arm_vm_init: memory sizes" }, { 202, "arm_vm_init: physmap placed" }, { 203, "arm_vm_init: invalid_tte" },
		{ 204, "arm_vm_init: kernel tables (init_ptpages)" }, { 205, "arm_vm_init: segments, page size" },
		{ 206, "arm_vm_prot_init" }, { 207, "arm_vm_init: dynamic tables" }, { 208, "arm_vm_physmap_init" },
		{ 210, "arm_vm_init: XNU's kernel L1 entries installed in Linux's table" },
		{ 215, "arm_vm_init: running on XNU's own page tables" }, { 220, "pmap_bootstrap returned" },
		{ 230, "arm_vm_init returned" }, { 300, "kprintf initialized" },
		{ 360, "PE_create_console" }, { 370, "PE_init_printf" }, { 380, "cpu_machine_idle_init" },
		{ 390, "PE_init_platform(TRUE)" }, { 400, "ml_map_cpu_pio" }, { 410, "cpu_timebase_init" },
		{ 420, "PE_init_cpu" }, { 490, "about to call machine_startup" },
	};
	if (stage >= 1000) {
		logkv("xnu: XNU sub-stage", stage);
		return stop >= 1000 && (long)stage >= stop;
	}
	const char *what = "?";
	for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++)
		if (names[i].s == stage) what = names[i].what;
	char buf[96]; char *p = buf; const char *q = "xnu: XNU stage ";
	while (*q) *p++ = *q++;
	p[0] = '0' + stage / 100; p[1] = '0' + stage / 10 % 10; p[2] = '0' + stage % 10; p += 3;
	*p++ = ':'; *p++ = ' ';
	while (*what && p < buf + 94) *p++ = *what++;
	*p = 0;
	logs(buf);
	if (stop >= 1000)		/* sub-stage ids: stop exactly there */
		return (long)stage == stop;
	return (long)stage >= stop && stage < 900;
}

/*
 * Boot handoff. The XNU "DRAM" region is described by (virtBase, physBase, size): XNU sees base_va as the
 * kernel virtual address of physBase. The image's vmlow sits at base_va + image_off.
 */
static struct boot_args_v2 *build_boot(unsigned char *base_va, u64_t phys, u64_t size, u64_t image_off, u64_t image_size)
{
	u64_t off_args = (image_off + image_size + 0x3fff) & ~0x3fffULL;
	struct boot_args_v2 *ba = (void *)(base_va + off_args);
	u64_t off_dt = off_args + 0x4000;
	struct adt a;
	static unsigned char seed[256];

	fki_random(seed, sizeof(seed));
	/* XNU identifies its CPU by MPIDR: run on CPU 0 and describe exactly that CPU. */
	int berr = fki_bind_cpu(0);
	if (berr) { logkv("xnu: cannot bind to cpu0, err", (u64_t)berr); return 0; }
	u64_t mpidr; __asm__ volatile("mrs %0, mpidr_el1" : "=r"(mpidr));
	mpidr &= 0xffff;	/* XNU compares Aff1:Aff0 */
	logkv("xnu: running on MPIDR Aff1:Aff0", mpidr);

	adt_init(&a, base_va + off_dt, 0x40000);
	adt_node(&a, 3, 6);				/* / */
	adt_prop_str(&a, "name", "device-tree");
	adt_prop_str(&a, "compatible", "xnulinux,linux64");
	adt_prop_str(&a, "model", "xnulinux");
	adt_node(&a, 22, 3);				/* /chosen */
	adt_prop_str(&a, "name", "chosen");
	adt_prop_u64(&a, "dram-base", phys);
	adt_prop_u64(&a, "dram-size", size);
	adt_prop(&a, "random-seed", seed, sizeof(seed));
	adt_prop_str(&a, "firmware-version", "xnulinux-m2");
	adt_prop_u32(&a, "debug-enabled", 1);
	{
		/* the SHA-384 of the boot manifest a bootloader would pass; there is none, so zeros (27's Image4 needs the property) */
		static const unsigned char zero48[48];
		adt_prop(&a, "boot-manifest-hash", zero48, sizeof(zero48));
	}
	{
		/* NVRAM as iBoot hands it over: the bank size and the image (blank: IODTNVRAM formats it as a CHRP store) */
		static unsigned char nvram[0x10000];
		adt_prop_u32(&a, "nvram-bank-size", sizeof(nvram));
		adt_prop_u32(&a, "nvram-bank-count", 1);
		adt_prop_u32(&a, "nvram-current-bank", 0);
		adt_prop(&a, "nvram-proxy-data", nvram, sizeof(nvram));
	}
	/*
	 * The identity a bootloader states for the AP, which Image4 reads: Apple's VM platform (chip 0xFE00, board 0x20)
	 * in an insecure, non-production mode, as a development VM boots.
	 */
	adt_prop_str(&a, "crypto-hash-method", "sha2-384");
	adt_prop_u32(&a, "chip-id", 0xfe00);
	adt_prop_u32(&a, "board-id", 0x20);
	adt_prop_u64(&a, "unique-chip-id", 0x0000584e554c4e58ULL);
	adt_prop_u32(&a, "chip-epoch", 0);
	adt_prop_u32(&a, "security-domain", 1);
	adt_prop_u32(&a, "certificate-production-status", 0);
	adt_prop_u32(&a, "certificate-security-mode", 0);
	adt_prop_u32(&a, "effective-production-status-ap", 0);
	adt_prop_u32(&a, "effective-security-mode-ap", 0);
	adt_prop_u32(&a, "mix-n-match-prevention-status", 0);
	u64_t off_rd = (off_dt + 0x40000 + 0x3fff) & ~0x3fffULL;	/* the RAM disk, after the ADT's room */
	adt_node(&a, rd_size ? 2 : 1, 0);		/* /chosen/memory-map: no trust caches, no AuxKC */
	adt_prop_str(&a, "name", "memory-map");
	if (rd_size) {
		u64_t rd[2] = { phys + off_rd, rd_size };
		adt_prop(&a, "RAMDisk", rd, sizeof(rd));
	}
	adt_node(&a, 1, 0);				/* /chosen/manifest-properties: AppleImage4 reads it (empty: no manifest) */
	adt_prop_str(&a, "name", "manifest-properties");
	adt_node(&a, 3, 0);				/* /chosen/asmb: the SIP configuration a bootloader passes (csr_bootstrap) */
	adt_prop_str(&a, "name", "asmb");
	adt_prop_u64(&a, "lp-sip0", 0x2);		/* CSR_ALLOW_UNTRUSTED_KEXTS, as DroidVM boots */
	adt_prop_u32(&a, "lp-sip1", 1);			/* CSR_ALLOW_UNAUTHENTICATED_ROOT */
	adt_node(&a, 1, 1);				/* /cpus */
	adt_prop_str(&a, "name", "cpus");
	/*
	 * /cpus/cpu0, without device_type "cpu": that would match Apple's CPU driver (AppleARMCPU, IONameMatch "cpu"),
	 * which drives the AIC interrupts and IPIs of real hardware. While hosted, the CPU is Linux's.
	 */
	adt_node(&a, 5, 0);
	adt_prop_str(&a, "name", "cpu0");
	adt_prop_str(&a, "state", "running");
	adt_prop_u32(&a, "reg", (unsigned)mpidr);
	adt_prop_u64(&a, "timebase-frequency", fki_counter_frequency());
	adt_prop_u32(&a, "cluster-type", 'P');	/* the AMP scheduler wants E/M/P, not SMP */
	adt_node(&a, 1, 0);				/* /defaults: XNU looks these up without checking */
	adt_prop_str(&a, "name", "defaults");
	adt_node(&a, 1, 0);				/* /product */
	adt_prop_str(&a, "name", "product");
	adt_node(&a, 1, 0);				/* /options: NVRAM's node (AppleImage4 keeps its nonce seeds there) */
	adt_prop_str(&a, "name", "options");
	adt_node(&a, 3, 0);				/* /arm-io: no devices; XNU needs a nonzero SoC base */
	adt_prop_str(&a, "name", "arm-io");
	adt_prop_str(&a, "device_type", "linux64-io");
	{ u64_t ranges[3] = { 0, 0x7000000000ULL, 0x10000000ULL }; adt_prop(&a, "ranges", ranges, sizeof(ranges)); }
	if (a.err) { logs("xnu: ADT overflow"); return 0; }
	u64_t dt_len = adt_size(&a);

	ba->Revision = 2; ba->Version = 2;
	ba->virtBase = (u64_t)base_va;
	ba->physBase = phys;
	ba->memSize = size;
	ba->memSizeActual = size;
	ba->topOfKernelData = phys + ((off_dt + dt_len + 0x3fff) & ~0x3fffULL);
	if (rd_size) {
		x_memcpy(base_va + off_rd, rd_data, rd_size);
		ba->topOfKernelData = phys + ((off_rd + rd_size + 0x3fff) & ~0x3fffULL);
		logkv("xnu: root RAM disk bytes", rd_size);
	}
	ba->deviceTreeP = base_va + off_dt;
	ba->deviceTreeLength = (unsigned)dt_len;
	x_memcpy(ba->CommandLine, cmdline, x_strlen(cmdline) + 1);
	if (rd_size || hd_file) {
		const char *rd = " rd=md0";
		x_memcpy(ba->CommandLine + x_strlen(ba->CommandLine), rd, x_strlen(rd) + 1);
	}
	if (bootargs && x_strlen(ba->CommandLine) + 1 + x_strlen(bootargs) < sizeof(ba->CommandLine)) {
		char *e = ba->CommandLine + x_strlen(ba->CommandLine);
		*e++ = ' ';
		x_memcpy(e, bootargs, x_strlen(bootargs) + 1);
	}
	logkv("xnu: boot args at", (u64_t)ba);
	logkv("xnu: ADT bytes", dt_len);
	logkv("xnu: topOfKernelData (phys)", ba->topOfKernelData);
	return ba;
}


/*
 * Monitor: XNU runs with interrupts masked on its CPU, so when it spins nothing reaches Linux. A helper
 * thread on another CPU prints XNU's debug counters (linux64_dbg, see the XNU patch) every 2 s.
 */
static volatile const unsigned long *xnu_dbg;
static void *monitor;
static int monitor_cpu = 1;
module_param(monitor_cpu, int, 0444);

static char *put_dec(char *p, unsigned long v)
{
	char t[24]; int n = 0;
	do { t[n++] = '0' + v % 10; v /= 10; } while (v);
	while (n) *p++ = t[--n];
	return p;
}

static int monitor_fn(void *arg)
{
	static const char *const names[] = { "idleloop", "machine_idle", "cpu_idle", "host_idle", "invoke",
		"-", "stage", "rtclock" };
	int lines = 0;
	(void)arg;
	while (!fki_thread_should_stop()) {
		fki_msleep(2000);
		/* every 2 s for the first 3 minutes, then every 20 s */
		static unsigned long ticks;
		if (!xnu_dbg || (lines >= 90 && (++ticks % 10) != 0))
			continue;
		char buf[420]; char *p = buf;
		const char *h = "xnu: monitor";
		while (*h) *p++ = *h++;
		for (int i = 0; i < 8; i++) {
			if (i == 5) continue;
			*p++ = ' ';
			for (const char *n = names[i]; *n; n++) *p++ = *n;
			*p++ = '=';
			p = put_dec(p, xnu_dbg[i]);
		}
		h = " el0exc=";
		while (*h) *p++ = *h++;
		p = put_dec(p, xnu_dbg[10]);
		h = " kfaults=";
		while (*h) *p++ = *h++;
		p = put_dec(p, kfaults);
		{
			static const char *const k[] = { " esr=0x", " far=0x", " pc=0x", " bad_esr=0x", " step=0x" };
			for (int j = 0; j < 5; j++) {
				for (h = k[j]; *h; h++) *p++ = *h;
				for (int i = 44; i >= 0; i -= 4) *p++ = "0123456789abcdef"[(xnu_dbg[11 + j] >> i) & 15];
			}
		}
		h = " thread=0x";
		while (*h) *p++ = *h++;
		for (int i = 44; i >= 0; i -= 4) *p++ = "0123456789abcdef"[(xnu_dbg[9] >> i) & 15];
		*p = 0;
		logs(buf);
		lines++;
	}
	return 0;
}

static int enter_arm_init(struct boot_args_v2 *ba)
{
	if (img.filetype == MH_FILESET) {
		/* kernel collection at its link address: XNU applies the chained fixups itself; nothing slides */
		if (img.slide) { logs("xnu: a kernel collection must not slide"); return -22; }
		logs("xnu: kernel collection: XNU applies its chained fixups (kernel_collection_slide)");
	} else {
		struct fki_pac_keys saved; unsigned long c = fki_enter(&xnu_W.xnu_keys, &saved);
		int n = macho_rebase(&img);
		fki_leave(c, &saved);
		logkv("xnu: threaded fixups applied", (u64_t)n);
		if (n < 0) return n;

		u64_t mh_unslid = 0;
		int segs = macho_slide_header(&img, &mh_unslid);
		logkv("xnu: load commands slid (segments)", (u64_t)segs);
	}
	u64_t a_init = macho_sym(&img, "_arm_init"), a_hook = macho_sym(&img, "_linux64_hook"),
	      a_slide = macho_sym(&img, "_linux64_slide");
	logkv("xnu: arm_init at", a_init);
	if (!a_init || !a_hook || !a_slide) { logs("xnu: arm_init or linux64_hook missing (kernel without the LINUX64 patch?)"); return -2; }
	*(u64_t *)a_hook = (u64_t)xnu_world_upcall;
	*(u64_t *)a_slide = img.slide;

	diag_va[0] = a_init; diag_va[1] = img.vmlow; diag_va[2] = (u64_t)ba; diag_va[3] = (u64_t)ba->deviceTreeP;
	diag_va[4] = macho_sym(&img, "_port_crumb");
	diag_va[5] = macho_sym(&img, "_strlen");
	xnu_dbg = (const unsigned long *)macho_sym(&img, "_linux64_dbg");
	if (xnu_dbg && monitor_cpu >= 0)
		monitor = fki_thread_start(monitor_fn, 0, monitor_cpu, "xnu-monitor");
	xnu_kfault = (void *)macho_sym(&img, "_linux64_kernel_fault");
	xnu_kfault_recover = (void *)macho_sym(&img, "_linux64_kernel_fault_recover");
	if (xnu_kfault && fki_fault_register(0xffffffe000000000ULL, 0xfffffffc00000000ULL, xnu_fault) == 0)
		logs("xnu: kernel faults on XNU addresses go to XNU's vm_fault");
	{
		/*
		 * XNU's user half starts as Linux's TTBR0. Its TCR stays Linux's (T0SZ 16, 4-level): a 4K XNU user pmap's
		 * hardware root (hw_ttep) is an L0 table whose first entry points at its L1 (ttep), as the walk showed.
		 */
		unsigned long long tcr, ttbr0;
		__asm__ volatile("mrs %0, tcr_el1" : "=r"(tcr));
		__asm__ volatile("mrs %0, ttbr0_el1" : "=r"(ttbr0));
		/*
		 * TCR.A1 off in XNU's world: Linux takes the ASID from TTBR1 (A1 = 1), XNU's pmaps put theirs in TTBR0. With
		 * Linux's A1 every XNU user pmap ran under Linux's one ASID, so XNU's per-ASID TLB flushes missed and a freed
		 * pmap's cached table walk (the exec'd child's stack L2) served the parent: a translation fault that repeats
		 * after vm_fault. The world switch drops the local TLB both ways, so the two ASID spaces never mix.
		 */
		xnu_W.xnu_tcr = tcr & ~(1ULL << 22);
		xnu_W.xnu_ttbr0 = ttbr0;
	}
	logs("xnu: entering arm_init");
	in_xnu = 1;
	long r = xnu_world_call(a_init, (unsigned long)ba);
	in_xnu = 0;
	fki_fault_unregister();
	logkv("xnu: kernel faults forwarded to XNU", kfaults);
	fki_thread_stop(monitor);
	monitor = 0;
	logkv(r ? "xnu: run ended by stage hook, r =" : "xnu: arm_init returned (unexpected), r =", (u64_t)r);
	return 0;
}

/* M2a: the image in a vmalloc region with synthetic physical addresses. */
static int run_m2a(void)
{
	u64_t image_size = img.vmhigh - img.vmlow;
	struct boot_args_v2 *ba = build_boot(img.region.va, XNU_FAKE_PHYS, img.region.size, 0, image_size);
	if (!ba) return -22;
	return enter_arm_init(ba);
}

/*
 * M2b: XNU at its own link address in the top foreign window, on physically contiguous memory with real
 * physical addresses, so that the page tables XNU builds can be walked by the hardware.
 */
#define XNU_WINDOW_BASE (img.vmlow & ~0x1fffffULL)	/* 2 MiB aligned, at or below the image's vmlow */

static int run_m2b(void)
{
	u64_t image_size = img.vmhigh - img.vmlow;
	if (img.vmlow < 0xffffffe000000000ULL) { logs("xnu: unexpected link address"); return -22; }
	u64_t image_off = img.vmlow - XNU_WINDOW_BASE;
	u64_t want = image_off + image_size + 0x60000 + ((rd_size + 0x3fff) & ~0x3fffULL) + ((u64_t)ram_mb << 20);
	int err = fki_contig_alloc(want, &img.region);
	if (err) { logkv("xnu: contiguous allocation failed, err", (u64_t)err); return err; }
	logkv("xnu: contiguous DRAM at phys", img.region.pa);
	logkv("xnu: contiguous DRAM size", img.region.size);
	if (img.region.pa & 0x1fffff) { logs("xnu: region not 2 MiB aligned"); return -22; }

	err = fki_contig_alloc(4096, &l2page);
	if (err) return err;
	unsigned long long *l2 = l2page.va;
	unsigned first = (XNU_WINDOW_BASE >> 21) & 511;
	/*
	 * One bootstrap L2 table: map what fits in the window's 1 GiB L1 slot. XNU only touches the image, the
	 * boot data and its first bootstrap allocations before it hands us its own kernel L1 entries (stage 210),
	 * which map all of its DRAM, so DRAM beyond the slot needs no bootstrap mapping.
	 */
	u64_t boot_map = img.region.size;
	if (boot_map > ((u64_t)(512 - first) << 21)) boot_map = (u64_t)(512 - first) << 21;
	if (boot_map < image_off + image_size + 0x60000 + ((rd_size + 0x3fff) & ~0x3fffULL) + (64ULL << 20)) {
		logs("xnu: image and boot data do not fit in the bootstrap window"); return -22;
	}
	logkv("xnu: bootstrap window base", XNU_WINDOW_BASE);
	logkv("xnu: bootstrap window bytes", boot_map);
	for (u64_t o = 0; o < boot_map; o += 0x200000) {
		/* 2 MiB block: normal WB (AttrIdx 0 in Linux's MAIR), inner shareable, AF, EL1 RWX, UXN */
		l2[first + (o >> 21)] = (img.region.pa + o) | (1ULL << 54) | (1ULL << 10) | (3ULL << 8) | 1;
	}
	unsigned long long *l1; fki_u64 l1pa;
	err = fki_window_l1(XNU_WINDOW_BASE, &l1, &l1pa);
	if (err) { logs("xnu: no L1 table for the top window"); return err; }
	unsigned idx = (XNU_WINDOW_BASE >> 30) & 511;
	logkv("xnu: top window L1 table at phys", l1pa);
	logkv("xnu: L1 slot", idx);
	if (l1[idx]) { logkv("xnu: L1 slot already used by Linux:", l1[idx]); return -16; }
	window_slot = &l1[idx];
	window_l1 = l1;
	window_owned[idx] = 1;
	fki_window_set(window_slot, l2page.pa | 3);
	logs("xnu: bootstrap window mapped");

	unsigned char *base = (unsigned char *)XNU_WINDOW_BASE;
	macho_copy(&img, base + image_off);
	img.slide = 0;
	struct boot_args_v2 *ba = build_boot(base, img.region.pa, img.region.size, image_off, image_size);
	if (!ba) return -22;
	return enter_arm_init(ba);
}

static int __init xnu_init(void)
{
	const void *data; unsigned long size;
	int err;

	if (fki_version() != 0)
		return -22;
	if (ramdisk) {
		err = fki_blob_get(ramdisk, &rd_data, &rd_size, &rd_blob);
		if (err) { logkv("xnu: cannot read the RAM disk, err", (u64_t)err); return err; }
	}
	if (console_in) {
		fki_u64 sz = 0;
		ci_file = fki_file_open(console_in, 0, &sz);
		ci_off = sz;	/* only what is written after the load */
		if (!ci_file) logs("xnu: cannot open console_in");
	}
	if (hostdisk) {
		hd_file = fki_file_open(hostdisk, hostdisk_rw, &hd_size);
		if (!hd_file) { logs("xnu: cannot open the host disk"); return -2; }
		logkv("xnu: host disk bytes", hd_size);
	}
	err = fki_blob_get(image, &data, &size, &blob);
	if (err) { logkv("xnu: cannot read image, err", (u64_t)err); return err; }
	err = macho_load(&img, data, size, mode == 3 ? ~0UL : mode == 2 ? (unsigned long)ram_mb << 20 : 0);
	if (err) { logkv("xnu: load failed", (u64_t)err); fki_blob_put(blob); blob = 0; return err; }
	logkv("xnu: image vmlow", img.vmlow);
	logkv("xnu: image size", img.vmhigh - img.vmlow);
	if (mode != 3) {
		logkv("xnu: region at", (u64_t)img.region.va);
		logkv("xnu: region size", img.region.size);
	}

	fki_random(&xnu_W.xnu_keys, sizeof(xnu_W.xnu_keys));
	xnu_W.xnu_keys.sctlr_en = ~0ULL;

	return mode == 1 ? run_m1() : mode == 3 ? run_m2b() : run_m2a();
}

static void __exit xnu_exit(void)
{
	if (window_l1) {
		int last = -1;
		for (int i = 0; i < 512; i++) if (window_owned[i]) { window_l1[i] = 0; last = i; }
		if (last >= 0) fki_window_set(&window_l1[last], 0);
	}
	if (mode == 3) {
		if (img.region.va) fki_contig_free(&img.region);
		if (l2page.va) fki_contig_free(&l2page);
	} else if (img.region.va) fki_region_free(&img.region);
	if (blob) fki_blob_put(blob);
	if (rd_blob) fki_blob_put(rd_blob);
	if (hd_file) fki_file_close(hd_file);
	if (ci_file) fki_file_close(ci_file);
}

module_init(xnu_init);
module_exit(xnu_exit);
MODULE_LICENSE("Proprietary");	/* APSL-2.0 side: not GPL-compatible; taints the kernel like ZFS */
MODULE_DESCRIPTION("XNU personality (PoC)");
