// SPDX-License-Identifier: GPL-2.0-only
/*
 * Foreign kernel interface, version 0: see include/linux/fki.h.
 *
 * Exports are plain EXPORT_SYMBOL on purpose: this file defines a narrow,
 * stable, semantic interface of its own, and nothing behind it is
 * re-exported.
 */
#include "fki.h"
#include <linux/firmware.h>
#include <linux/gfp.h>
#include <linux/irqflags.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/preempt.h>
#include <linux/printk.h>
#include <linux/random.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
#include <asm/arch_timer.h>
#include <asm/sysreg.h>
#include <linux/kprobes.h>

int fki_version(void)
{
	return FKI_VERSION;
}
EXPORT_SYMBOL(fki_version);

void fki_log(const char *s, unsigned long len)
{
	pr_info("fki: %.*s\n", (int)len, s);
}
EXPORT_SYMBOL(fki_log);


/*
 * Out-of-tree form only: stock kernels do not export set_memory_x(). The in-tree FKI
 * patch calls it directly; here it is found once through kallsyms (via a kprobe).
 */
typedef int (*set_memory_fn)(unsigned long addr, int numpages);
static set_memory_fn p_set_memory_x, p_set_memory_nx;

static int fki_resolve(void)
{
	static unsigned long (*lookup)(const char *);
	struct kprobe kp = { .symbol_name = "kallsyms_lookup_name" };

	if (p_set_memory_x)
		return 0;
	if (!lookup) {
		if (register_kprobe(&kp))
			return -ENOENT;
		lookup = (void *)kp.addr;
		unregister_kprobe(&kp);
	}
	p_set_memory_x = (set_memory_fn)lookup("set_memory_x");
	p_set_memory_nx = (set_memory_fn)lookup("set_memory_nx");
	return p_set_memory_x && p_set_memory_nx ? 0 : -ENOENT;
}

int fki_region_alloc(unsigned long size, struct fki_region *r)
{
	unsigned long n = PAGE_ALIGN(size) >> PAGE_SHIFT;
	void *va;
	int err;

	/* vmap() memory is never executable on current kernels; vmalloc + set_memory_x is (out-of-tree form). */
	err = fki_resolve();
	if (err)
		return err;
	va = vzalloc(n << PAGE_SHIFT);
	if (!va)
		return -ENOMEM;
	err = p_set_memory_x((unsigned long)va, n);
	if (err) {
		vfree(va);
		return err;
	}
	r->va = va;
	r->pa = page_to_phys(vmalloc_to_page(va));
	r->size = n << PAGE_SHIFT;
	r->handle = NULL;
	return 0;
}
EXPORT_SYMBOL(fki_region_alloc);

void fki_region_free(struct fki_region *r)
{
	p_set_memory_nx((unsigned long)r->va, r->size >> PAGE_SHIFT);
	vfree(r->va);
}
EXPORT_SYMBOL(fki_region_free);

int fki_blob_get(const char *name, const void **data, unsigned long *size, void **handle)
{
	const struct firmware *fw;
	int err = request_firmware(&fw, name, NULL);

	if (err)
		return err;
	*data = fw->data;
	*size = fw->size;
	*handle = (void *)fw;
	return 0;
}
EXPORT_SYMBOL(fki_blob_get);

void fki_blob_put(void *handle)
{
	release_firmware(handle);
}
EXPORT_SYMBOL(fki_blob_put);

#define FKI_SCTLR_EN (SCTLR_ELx_ENIA | SCTLR_ELx_ENIB | SCTLR_ELx_ENDA | SCTLR_ELx_ENDB)


static __always_inline void keys_read(struct fki_pac_keys *k)
{
	k->ia[0] = read_sysreg_s(SYS_APIAKEYLO_EL1); k->ia[1] = read_sysreg_s(SYS_APIAKEYHI_EL1);
	k->ib[0] = read_sysreg_s(SYS_APIBKEYLO_EL1); k->ib[1] = read_sysreg_s(SYS_APIBKEYHI_EL1);
	k->da[0] = read_sysreg_s(SYS_APDAKEYLO_EL1); k->da[1] = read_sysreg_s(SYS_APDAKEYHI_EL1);
	k->db[0] = read_sysreg_s(SYS_APDBKEYLO_EL1); k->db[1] = read_sysreg_s(SYS_APDBKEYHI_EL1);
	k->ga[0] = read_sysreg_s(SYS_APGAKEYLO_EL1); k->ga[1] = read_sysreg_s(SYS_APGAKEYHI_EL1);
	k->sctlr_en = read_sysreg(sctlr_el1) & FKI_SCTLR_EN;
}

static __always_inline void keys_write(const struct fki_pac_keys *k)
{
	write_sysreg_s(k->ia[0], SYS_APIAKEYLO_EL1); write_sysreg_s(k->ia[1], SYS_APIAKEYHI_EL1);
	write_sysreg_s(k->ib[0], SYS_APIBKEYLO_EL1); write_sysreg_s(k->ib[1], SYS_APIBKEYHI_EL1);
	write_sysreg_s(k->da[0], SYS_APDAKEYLO_EL1); write_sysreg_s(k->da[1], SYS_APDAKEYHI_EL1);
	write_sysreg_s(k->db[0], SYS_APDBKEYLO_EL1); write_sysreg_s(k->db[1], SYS_APDBKEYHI_EL1);
	write_sysreg_s(k->ga[0], SYS_APGAKEYLO_EL1); write_sysreg_s(k->ga[1], SYS_APGAKEYHI_EL1);
	sysreg_clear_set(sctlr_el1, FKI_SCTLR_EN, k->sctlr_en & FKI_SCTLR_EN);
	isb();
}

__attribute__((target("branch-protection=none"))) unsigned long fki_enter(const struct fki_pac_keys *foreign, struct fki_pac_keys *saved)
{
	unsigned long flags;

	preempt_disable();
	local_irq_save(flags);
	keys_read(saved);
	keys_write(foreign);
	return flags;
}
EXPORT_SYMBOL(fki_enter);

__attribute__((target("branch-protection=none"))) void fki_leave(unsigned long cookie, const struct fki_pac_keys *saved)
{
	keys_write(saved);
	local_irq_restore(cookie);
	preempt_enable();
}
EXPORT_SYMBOL(fki_leave);

__attribute__((target("branch-protection=none"))) void fki_pac_swap(const struct fki_pac_keys *load, struct fki_pac_keys *save)
{
	keys_read(save);
	keys_write(load);
}
EXPORT_SYMBOL(fki_pac_swap);

fki_u64 fki_counter_frequency(void)
{
	return arch_timer_get_cntfrq();
}
EXPORT_SYMBOL(fki_counter_frequency);

fki_u64 fki_counter(void)
{
	return __arch_counter_get_cntvct();
}
EXPORT_SYMBOL(fki_counter);

void fki_random(void *buf, unsigned long len)
{
	get_random_bytes(buf, len);
}
EXPORT_SYMBOL(fki_random);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Foreign kernel interface v0 (out-of-tree form for stock kernels)");
