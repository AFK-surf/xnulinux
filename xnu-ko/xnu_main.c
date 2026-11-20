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

static struct xnu_image img;
static struct fki_region l2page;
static unsigned long long *window_slot, *window_l1;
static unsigned char window_owned[512];
static u64_t diag_va[6];
#define XNU_L1_FIRST 384	/* VM_MIN_KERNEL_ADDRESS 0xffffffe000000000 */
#define XNU_L1_LAST 495	/* VM_MAX_KERNEL_ADDRESS 0xfffffffbffffffff */
static void *blob;
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

long xnu_hook(unsigned long stage, unsigned long a1, unsigned long a2)
{
	if (stage == 998) {		/* XNU kprintf */
		char m[260]; const char *f = (const char *)a1; unsigned i = 0, j = 0;
		m[j++] = 'x'; m[j++] = 'n'; m[j++] = 'u'; m[j++] = ']'; m[j++] = ' ';
		while (f && f[i] && j < sizeof(m) - 1) { if (f[i] != '\n') m[j++] = f[i]; i++; }
		m[j] = 0;
		/* the per-entry startup trace is thousands of lines: count it, do not print it */
		if (!(f && !x_strncmp(f, "kernel_startup_initialize_upto[", 31)))
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
	if (stage == 810) {		/* XNU idle: let Linux run until XNU's next timer deadline */
		static unsigned long idles;
		if ((++idles & (idles - 1)) == 0) logkv("xnu: XNU idle, count", idles);
		fki_idle_until(a1, 20000000ULL);	/* at most 20 ms per round */
		return idle_max && idles >= (unsigned long)idle_max;
	}
	if (stage == 999) {
		char m[200]; const char *f = (const char *)a1; unsigned i = 0;
		while (f && f[i] && i < sizeof(m) - 1) { m[i] = f[i]; i++; }
		m[i] = 0;
		logs("xnu: XNU panic, format string:");
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

	adt_init(&a, base_va + off_dt, 0x10000);
	adt_node(&a, 3, 5);				/* / */
	adt_prop_str(&a, "name", "device-tree");
	adt_prop_str(&a, "compatible", "xnulinux,linux64");
	adt_prop_str(&a, "model", "xnulinux");
	adt_node(&a, 6, 1);				/* /chosen */
	adt_prop_str(&a, "name", "chosen");
	adt_prop_u64(&a, "dram-base", phys);
	adt_prop_u64(&a, "dram-size", size);
	adt_prop(&a, "random-seed", seed, sizeof(seed));
	adt_prop_str(&a, "firmware-version", "xnulinux-m2");
	adt_prop_u32(&a, "debug-enabled", 1);
	adt_node(&a, 1, 0);				/* /chosen/memory-map: no trust caches, no AuxKC */
	adt_prop_str(&a, "name", "memory-map");
	adt_node(&a, 1, 1);				/* /cpus */
	adt_prop_str(&a, "name", "cpus");
	adt_node(&a, 6, 0);				/* /cpus/cpu0 */
	adt_prop_str(&a, "name", "cpu0");
	adt_prop_str(&a, "device_type", "cpu");
	adt_prop_str(&a, "state", "running");
	adt_prop_u32(&a, "reg", (unsigned)mpidr);
	adt_prop_u64(&a, "timebase-frequency", fki_counter_frequency());
	adt_prop_u32(&a, "cluster-type", 'P');	/* the AMP scheduler wants E/M/P, not SMP */
	adt_node(&a, 1, 0);				/* /defaults: XNU looks these up without checking */
	adt_prop_str(&a, "name", "defaults");
	adt_node(&a, 1, 0);				/* /product */
	adt_prop_str(&a, "name", "product");
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
	ba->deviceTreeP = base_va + off_dt;
	ba->deviceTreeLength = (unsigned)dt_len;
	x_memcpy(ba->CommandLine, cmdline, x_strlen(cmdline) + 1);
	logkv("xnu: boot args at", (u64_t)ba);
	logkv("xnu: ADT bytes", dt_len);
	logkv("xnu: topOfKernelData (phys)", ba->topOfKernelData);
	return ba;
}

static int enter_arm_init(struct boot_args_v2 *ba)
{
	struct fki_pac_keys saved; unsigned long c = fki_enter(&xnu_W.xnu_keys, &saved);
	int n = macho_rebase(&img);
	fki_leave(c, &saved);
	logkv("xnu: threaded fixups applied", (u64_t)n);
	if (n < 0) return n;

	u64_t mh_unslid = 0;
	int segs = macho_slide_header(&img, &mh_unslid);
	logkv("xnu: load commands slid (segments)", (u64_t)segs);
	u64_t a_init = macho_sym(&img, "_arm_init"), a_hook = macho_sym(&img, "_linux64_hook"),
	      a_slide = macho_sym(&img, "_linux64_slide");
	logkv("xnu: arm_init at", a_init);
	if (!a_init || !a_hook || !a_slide) { logs("xnu: arm_init or linux64_hook missing (kernel without the LINUX64 patch?)"); return -2; }
	*(u64_t *)a_hook = (u64_t)xnu_world_upcall;
	*(u64_t *)a_slide = img.slide;

	diag_va[0] = a_init; diag_va[1] = img.vmlow; diag_va[2] = (u64_t)ba; diag_va[3] = (u64_t)ba->deviceTreeP;
	diag_va[4] = macho_sym(&img, "_port_crumb");
	diag_va[5] = macho_sym(&img, "_strlen");
	logs("xnu: entering arm_init");
	long r = xnu_world_call(a_init, (unsigned long)ba);
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
#define XNU_WINDOW_BASE 0xfffffff007000000ULL	/* 2 MiB aligned, at or below the image's vmlow */

static int run_m2b(void)
{
	u64_t image_size = img.vmhigh - img.vmlow;
	if (img.vmlow < XNU_WINDOW_BASE || img.vmlow - XNU_WINDOW_BASE >= 0x200000) { logs("xnu: unexpected link address"); return -22; }
	u64_t image_off = img.vmlow - XNU_WINDOW_BASE;
	u64_t want = image_off + image_size + 0x20000 + ((u64_t)ram_mb << 20);
	int err = fki_contig_alloc(want, &img.region);
	if (err) { logkv("xnu: contiguous allocation failed, err", (u64_t)err); return err; }
	logkv("xnu: contiguous DRAM at phys", img.region.pa);
	logkv("xnu: contiguous DRAM size", img.region.size);
	if ((img.region.pa & 0x1fffff) || img.region.size > (1ULL << 30)) { logs("xnu: region not 2 MiB aligned or above 1 GiB"); return -22; }

	err = fki_contig_alloc(4096, &l2page);
	if (err) return err;
	unsigned long long *l2 = l2page.va;
	unsigned first = (XNU_WINDOW_BASE >> 21) & 511;
	for (u64_t o = 0; o < img.region.size; o += 0x200000) {
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
}

module_init(xnu_init);
module_exit(xnu_exit);
MODULE_LICENSE("Proprietary");	/* APSL-2.0 side: not GPL-compatible; taints the kernel like ZFS */
MODULE_DESCRIPTION("XNU personality (PoC)");
