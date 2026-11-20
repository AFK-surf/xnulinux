// SPDX-License-Identifier: APSL-2.0
/*
 * xnu.ko: hosts an XNU kernel image inside Linux. Talks to Linux only
 * through <linux/fki.h>; <linux/module.h> provides the module ABI.
 *
 * PoC milestone M1: load the source-built XNU Mach-O, slide and PAC-sign it
 * with XNU's own kernel keys, and run XNU code inside the Linux kernel.
 */
#include <linux/module.h>
#include "../fki-ko/fki.h"
#include "xrt.h"
#include "macho.h"

static char *image = "xnu/kernel.macho";
module_param(image, charp, 0444);

static struct xnu_image img;
static void *blob;
static struct fki_pac_keys xnu_keys;

static void logs(const char *s) { fki_log(s, x_strlen(s)); }

static char *fmt_hex(char *p, u64_t v)
{
	*p++ = '0'; *p++ = 'x';
	for (int i = 60; i >= 0; i -= 4) *p++ = "0123456789abcdef"[(v >> i) & 15];
	*p = 0;
	return p;
}

static void logkv(const char *k, u64_t v)
{
	char buf[96]; char *p = buf;
	while (*k) *p++ = *k++;
	*p++ = ' ';
	fmt_hex(p, v);
	logs(buf);
}

typedef unsigned long (*strlen_fn)(const char *);
typedef unsigned int (*crc32_fn)(unsigned int, const void *, unsigned long);

static int __init xnu_init(void)
{
	const void *data; unsigned long size; unsigned long c; struct fki_pac_keys saved;
	int err;

	if (fki_version() != 0)
		return -22;
	err = fki_blob_get(image, &data, &size, &blob);
	if (err) { logkv("xnu: cannot read image, err", (u64_t)err); return err; }
	err = macho_load(&img, data, size);
	if (err) { logkv("xnu: load failed", (u64_t)err); fki_blob_put(blob); return err; }
	logkv("xnu: image vmlow", img.vmlow);
	logkv("xnu: image size", img.vmhigh - img.vmlow);
	logkv("xnu: loaded at", (u64_t)img.region.va);
	logkv("xnu: phys", img.region.pa);
	logkv("xnu: entry (unslid)", img.entry);

	fki_random(&xnu_keys, sizeof(xnu_keys));
	xnu_keys.sctlr_en = ~0ULL;	/* all four address keys on */

	c = fki_enter(&xnu_keys, &saved);
	int n = macho_rebase(&img);
	fki_leave(c, &saved);
	logkv("xnu: threaded fixups applied", (u64_t)n);
	if (n < 0)
		return n;

	u64_t a_version = macho_sym(&img, "_version"), a_strlen = macho_sym(&img, "_strlen"), a_crc = macho_sym(&img, "_crc32");
	logkv("xnu: _version at", a_version);
	if (!a_version || !a_strlen || !a_crc) { logs("xnu: symbols missing"); return 0; }
	c = fki_enter(&xnu_keys, &saved);
	unsigned long len = ((strlen_fn)a_strlen)((const char *)a_version);
	unsigned int crc = ((crc32_fn)a_crc)(0, (const void *)a_version, len);
	fki_leave(c, &saved);
	logs("xnu: XNU code ran inside Linux; XNU's version string:");
	fki_log((const char *)a_version, len);
	logkv("xnu: strlen(version) computed by XNU", len);
	logkv("xnu: crc32(version) computed by XNU", crc);
	return 0;
}

static void __exit xnu_exit(void)
{
	if (img.region.va) fki_region_free(&img.region);
	if (blob) fki_blob_put(blob);
}

module_init(xnu_init);
module_exit(xnu_exit);
MODULE_LICENSE("Proprietary");	/* APSL-2.0: not GPL-compatible; taints the kernel like ZFS */
MODULE_DESCRIPTION("XNU personality (PoC)");
