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

static struct xnu_image img;
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

static const char *cmdline = "debug=0x8 -v serial=0 startup_debug=1 vm_compression_limit=1572864";

long xnu_hook(unsigned long stage, unsigned long a1, unsigned long a2)
{
	if (stage == 998) {		/* XNU kprintf */
		char m[260]; const char *f = (const char *)a1; unsigned i = 0, j = 0;
		m[j++] = 'x'; m[j++] = 'n'; m[j++] = 'u'; m[j++] = ']'; m[j++] = ' ';
		while (f && f[i] && j < sizeof(m) - 1) { if (f[i] != '\n') m[j++] = f[i]; i++; }
		m[j] = 0;
		logs(m);
		return 0;
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
	};
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
	return (long)stage >= stop;
}

static int run_m2a(void)
{
	u64_t image_size = img.vmhigh - img.vmlow;
	unsigned char *base = img.region.va;
	unsigned long region = img.region.size;
	/* region: [image][boot args][ADT][free "DRAM" ...] */
	u64_t off_args = (image_size + 0x3fff) & ~0x3fffULL;
	struct boot_args_v2 *ba = (void *)(base + off_args);
	u64_t off_dt = off_args + 0x4000;
	struct adt a;
	static unsigned char seed[256];

	fki_random(seed, sizeof(seed));
	adt_init(&a, base + off_dt, 0x10000);
	adt_node(&a, 3, 3);				/* / */
	adt_prop_str(&a, "name", "device-tree");
	adt_prop_str(&a, "compatible", "xnulinux,linux64");
	adt_prop_str(&a, "model", "xnulinux");
	adt_node(&a, 6, 0);				/* /chosen */
	adt_prop_str(&a, "name", "chosen");
	adt_prop_u64(&a, "dram-base", XNU_FAKE_PHYS);
	adt_prop_u64(&a, "dram-size", region);
	adt_prop(&a, "random-seed", seed, sizeof(seed));
	adt_prop_str(&a, "firmware-version", "xnulinux-m2a");
	adt_prop_u32(&a, "debug-enabled", 1);
	adt_node(&a, 1, 1);				/* /cpus */
	adt_prop_str(&a, "name", "cpus");
	adt_node(&a, 5, 0);				/* /cpus/cpu0 */
	adt_prop_str(&a, "name", "cpu0");
	adt_prop_str(&a, "device_type", "cpu");
	adt_prop_str(&a, "state", "running");
	adt_prop_u32(&a, "reg", 0);
	adt_prop_u64(&a, "timebase-frequency", fki_counter_frequency());
	adt_node(&a, 3, 0);				/* /arm-io: no devices; XNU needs a nonzero SoC base */
	adt_prop_str(&a, "name", "arm-io");
	adt_prop_str(&a, "device_type", "linux64-io");
	{ u64_t ranges[3] = { 0, 0x7000000000ULL, 0x10000000ULL }; adt_prop(&a, "ranges", ranges, sizeof(ranges)); }
	if (a.err) { logs("xnu: ADT overflow"); return -12; }
	u64_t dt_len = adt_size(&a);

	ba->Revision = 2; ba->Version = 2;
	ba->virtBase = (u64_t)base;
	ba->physBase = XNU_FAKE_PHYS;
	ba->memSize = region;
	ba->memSizeActual = region;
	ba->topOfKernelData = XNU_FAKE_PHYS + ((off_dt + dt_len + 0x3fff) & ~0x3fffULL);
	ba->deviceTreeP = base + off_dt;
	ba->deviceTreeLength = (unsigned)dt_len;
	x_memcpy(ba->CommandLine, cmdline, x_strlen(cmdline) + 1);
	logkv("xnu: boot args at", (u64_t)ba);
	logkv("xnu: ADT bytes", dt_len);
	logkv("xnu: topOfKernelData (XNU phys)", ba->topOfKernelData);

	/* Slide and sign here (XNU skips its own rebase when hosted). */
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

	logs("xnu: entering arm_init");
	long r = xnu_world_call(a_init, (unsigned long)ba);
	logkv(r ? "xnu: run ended by stage hook, r =" : "xnu: arm_init returned (unexpected), r =", (u64_t)r);
	return 0;
}

static int __init xnu_init(void)
{
	const void *data; unsigned long size;
	int err;

	if (fki_version() != 0)
		return -22;
	err = fki_blob_get(image, &data, &size, &blob);
	if (err) { logkv("xnu: cannot read image, err", (u64_t)err); return err; }
	err = macho_load(&img, data, size, mode == 2 ? (unsigned long)ram_mb << 20 : 0);
	if (err) { logkv("xnu: load failed", (u64_t)err); fki_blob_put(blob); blob = 0; return err; }
	logkv("xnu: image vmlow", img.vmlow);
	logkv("xnu: image size", img.vmhigh - img.vmlow);
	logkv("xnu: region at", (u64_t)img.region.va);
	logkv("xnu: region size", img.region.size);

	fki_random(&xnu_W.xnu_keys, sizeof(xnu_W.xnu_keys));
	xnu_W.xnu_keys.sctlr_en = ~0ULL;

	return mode == 1 ? run_m1() : run_m2a();
}

static void __exit xnu_exit(void)
{
	if (img.region.va) fki_region_free(&img.region);
	if (blob) fki_blob_put(blob);
}

module_init(xnu_init);
module_exit(xnu_exit);
MODULE_LICENSE("Proprietary");	/* APSL-2.0 side: not GPL-compatible; taints the kernel like ZFS */
MODULE_DESCRIPTION("XNU personality (PoC)");
