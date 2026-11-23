// SPDX-License-Identifier: GPL-2.0-only
/*
 * Foreign kernel interface, version 1: L4H AArch64 (EL0) backend.
 */
#include "fki.h"
#include "fki_internal.h"
#include <linux/errno.h>
#include <linux/gfp.h>
#include <linux/io.h>
#include <linux/irqflags.h>
#include <linux/list.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/preempt.h>
#include <linux/printk.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/smp.h>
#include <linux/spinlock.h>
#include <linux/xarray.h>
#include <asm/neon.h>
#include <l4h_sys.h>
#include <l4h_caps.h>
#include <l4h_vspace.h>
#include <l4h/provider-registers.h>

#define FKI_L4H_ERR_ILLEGAL_OP	3
#define FKI_L4H_REGION_VA	0xffffffe000000000ULL
#define FKI_L4H_REGION_PA	0x800000000ULL

/* SCTLR_EL1 PAC enable bit positions (ABI of struct fki_pac_keys.sctlr_en). */
#define FKI_SCTLR_ENIA		(1ULL << 31)
#define FKI_SCTLR_ENIB		(1ULL << 30)
#define FKI_SCTLR_ENDA		(1ULL << 27)
#define FKI_SCTLR_ENDB		(1ULL << 13)

static bool pac_unsupported;
static DEFINE_PER_CPU(struct fki_pac_keys, l4h_cur_pac);

unsigned long fki_caps(void)
{
	unsigned long features = l4h_provider_features();
	unsigned long caps = FKI_CAP_EL0;

	if ((features & L4H_PROVIDER_ARM_HIGH_VSPACE) &&
	    (l4h_bootinfo->flags & L4H_BOOT_HIGH_VSPACE))
		caps |= FKI_CAP_HIGH_WINDOW;
	if ((features & L4H_PROVIDER_ARM_PAC) && !pac_unsupported)
		caps |= FKI_CAP_PAC;
	return caps;
}
EXPORT_SYMBOL(fki_caps);

int fki_cpu_id(void)
{
	return smp_processor_id();
}
EXPORT_SYMBOL(fki_cpu_id);

int fki_cpu_mpidr(int cpu, fki_u64 *mpidr)
{
	if (cpu < 0 || cpu >= nr_cpu_ids || !cpu_online(cpu))
		return -EINVAL;
	/* Encodes Aff1:Aff0 so LINUX64_CPU_SLOT(mpidr) == cpu. */
	*mpidr = ((u64)(cpu & 0xf)) | (((u64)((cpu >> 4) & 0xf)) << 8);
	return 0;
}
EXPORT_SYMBOL(fki_cpu_mpidr);

fki_u64 fki_counter_frequency(void)
{
	u64 v;

	asm volatile("mrs %0, cntfrq_el0" : "=r"(v));
	return v;
}
EXPORT_SYMBOL(fki_counter_frequency);

fki_u64 fki_counter(void)
{
	u64 v;

	asm volatile("isb\n\tmrs %0, cntvct_el0" : "=r"(v));
	return v;
}
EXPORT_SYMBOL(fki_counter);

void fki_fpsimd_forget(void)
{
	if (l4h_neon_usable()) {
		kernel_neon_begin();
		kernel_neon_end();
	}
}

static unsigned long sctlr_to_l4h_pac_en(fki_u64 sctlr_en)
{
	unsigned long en = 0;

	if (sctlr_en & FKI_SCTLR_ENIA)
		en |= L4H_PAC_EN_IA;
	if (sctlr_en & FKI_SCTLR_ENIB)
		en |= L4H_PAC_EN_IB;
	if (sctlr_en & FKI_SCTLR_ENDA)
		en |= L4H_PAC_EN_DA;
	if (sctlr_en & FKI_SCTLR_ENDB)
		en |= L4H_PAC_EN_DB;
	return en;
}

static void keys_apply(const struct fki_pac_keys *k)
{
	unsigned long words[L4H_PAC_KEY_WORDS];
	unsigned long en;
	int err;

	*this_cpu_ptr(&l4h_cur_pac) = *k;
	if (pac_unsupported || !(l4h_provider_features() & L4H_PROVIDER_ARM_PAC))
		return;
	en = sctlr_to_l4h_pac_en(k->sctlr_en);
	if (!en) {
		l4h_tcb_set_pac(0, 0, NULL);
		return;
	}
	words[0] = k->ia[0]; words[1] = k->ia[1];
	words[2] = k->ib[0]; words[3] = k->ib[1];
	words[4] = k->da[0]; words[5] = k->da[1];
	words[6] = k->db[0]; words[7] = k->db[1];
	words[8] = k->ga[0]; words[9] = k->ga[1];
	err = l4h_tcb_set_pac(0, en, words);
	if (err == FKI_L4H_ERR_ILLEGAL_OP) {
		pac_unsupported = true;
		l4h_tcb_set_pac(0, 0, NULL);
	}
}

unsigned long fki_enter(const struct fki_pac_keys *foreign, struct fki_pac_keys *saved)
{
	unsigned long flags;

	fki_fpsimd_forget();
	preempt_disable();
	local_irq_save(flags);
	*saved = *this_cpu_ptr(&l4h_cur_pac);
	keys_apply(foreign);
	return flags;
}
EXPORT_SYMBOL(fki_enter);

void fki_leave(unsigned long cookie, const struct fki_pac_keys *saved)
{
	keys_apply(saved);
	local_irq_restore(cookie);
	preempt_enable();
}
EXPORT_SYMBOL(fki_leave);

void fki_pac_swap(const struct fki_pac_keys *load, struct fki_pac_keys *save)
{
	*save = *this_cpu_ptr(&l4h_cur_pac);
	keys_apply(load);
}
EXPORT_SYMBOL(fki_pac_swap);

/* ---- alternate stack for Linux calls from hosted kernel stacks ---- */

static void *fki_alt_stack[NR_CPUS];
#define FKI_ALT_STACK_ORDER get_order(2 * THREAD_SIZE)

asm(
"	.pushsection .text\n"
"	.type	fki_run_on_stack, %function\n"
"fki_run_on_stack:\n"
"	stp	x29, x30, [sp, #-16]!\n"
"	mov	x29, sp\n"
"	mov	x9, sp\n"
"	mov	sp, x2\n"
"	stp	x9, xzr, [sp, #-16]!\n"
"	mov	x9, x0\n"
"	mov	x0, x1\n"
"	blr	x9\n"
"	ldp	x9, xzr, [sp], #16\n"
"	mov	sp, x9\n"
"	ldp	x29, x30, [sp], #16\n"
"	ret\n"
"	.size	fki_run_on_stack, . - fki_run_on_stack\n"
"	.popsection\n");
void fki_run_on_stack(void (*fn)(void *), void *arg, void *top);

void fki_arch_linux_runs(void (*fn)(void *), void *arg)
{
	unsigned long sp;
	int cpu = smp_processor_id();

	asm volatile("mov %0, sp" : "=r"(sp));
	if (sp >= 0xffffffe000000000ULL && fki_alt_stack[cpu])
		fki_run_on_stack(fn, arg, (char *)fki_alt_stack[cpu] + THREAD_SIZE);
	else
		fn(arg);
}

/* ---- high-window kernel memory & dynamic 4 KiB mappings ---- */

struct fki_pt_node {
	struct list_head list;
	struct l4h_obj pt;
};

struct fki_kmem_chunk {
	bool is_large;
	struct page *large_pg;
	unsigned long large_gpa;
	unsigned long large_slot;
	struct page **small_pgs;	/* 512 entries when !is_large */
	unsigned long *small_slots;	/* 512 entries when !is_large */
};

struct fki_kmem {
	unsigned long high_va;
	fki_u64 pa_base;
	unsigned long size;
	unsigned long nchunks;
	struct fki_kmem_chunk *chunks;
	struct list_head pts;
	struct xarray dyn_slots;	/* (va >> PAGE_SHIFT) -> xa_mk_value(cptr) */
	spinlock_t lock;
};

static struct fki_kmem *active_kmem;

static void bind_high_vspace_cpu(void *arg)
{
	unsigned long vs = (unsigned long)arg;
	int err = l4h_tcb_set_high_vspace(0, vs);

	if (err)
		pr_err("fki: cpu %d: l4h_tcb_set_high_vspace(%#lx) failed: %d\n",
		       smp_processor_id(), vs, err);
}

static int map_high_frame(struct fki_kmem *km, unsigned long frame_slot,
			  unsigned long va, int prot)
{
	unsigned long high_vs = L4H_CPTR(L4H_SLOT_HIGH_VSPACE);
	int err;

	while ((err = l4h_page_map(frame_slot, high_vs, va, prot)) == L4H_ERR_FAILED_LOOKUP) {
		struct fki_pt_node *node = kzalloc(sizeof(*node), GFP_ATOMIC);

		if (!node)
			return -ENOMEM;
		if (l4h_obj_alloc(L4H_OBJ_PT, 0, &node->pt)) {
			kfree(node);
			return -ENOMEM;
		}
		err = l4h_pt_map(L4H_OBJ_PT, node->pt.cptr, high_vs, va);
		if (err) {
			l4h_obj_free(&node->pt);
			kfree(node);
			return -EIO;
		}
		list_add(&node->list, &km->pts);
	}
	return err ? -EIO : 0;
}

static int xpa_to_gpa(struct fki_kmem *km, fki_u64 xpa, unsigned long *gpa_out)
{
	unsigned long off, ci, coff;
	struct fki_kmem_chunk *ch;

	if (!km || xpa < km->pa_base || xpa >= km->pa_base + km->size)
		return -EINVAL;
	off = (unsigned long)(xpa - km->pa_base);
	ci = off >> 21;
	coff = off & (SZ_2M - 1);
	ch = &km->chunks[ci];
	if (ch->is_large) {
		*gpa_out = ch->large_gpa + coff;
		return 0;
	}
	*gpa_out = page_to_phys(ch->small_pgs[coff >> PAGE_SHIFT]) + (coff & ~PAGE_MASK);
	return 0;
}

static void kmem_cleanup(struct fki_kmem *km)
{
	struct fki_pt_node *node, *tmp;
	unsigned long idx;
	void *entry;
	unsigned long i, j;

	if (!km)
		return;
	xa_for_each(&km->dyn_slots, idx, entry) {
		unsigned long slot = xa_to_value(entry);

		if (slot)
			l4h_slot_delete(slot);
	}
	xa_destroy(&km->dyn_slots);

	if (km->chunks) {
		for (i = 0; i < km->nchunks; i++) {
			struct fki_kmem_chunk *ch = &km->chunks[i];

			if (ch->is_large) {
				if (ch->large_slot)
					l4h_slot_delete(ch->large_slot);
				if (ch->large_pg)
					__free_pages(ch->large_pg, 9);
			} else {
				if (ch->small_slots) {
					for (j = 0; j < 512; j++) {
						if (ch->small_slots[j])
							l4h_slot_delete(ch->small_slots[j]);
					}
					kfree(ch->small_slots);
				}
				if (ch->small_pgs) {
					for (j = 0; j < 512; j++) {
						if (ch->small_pgs[j])
							__free_page(ch->small_pgs[j]);
					}
					kfree(ch->small_pgs);
				}
			}
		}
		kvfree(km->chunks);
	}

	list_for_each_entry_safe(node, tmp, &km->pts, list) {
		list_del(&node->list);
		l4h_obj_free(&node->pt);
		kfree(node);
	}
	kfree(km);
}

int fki_kmem_alloc(unsigned long size, unsigned long high_va, fki_u64 pa_base, struct fki_region *r)
{
	unsigned long aligned = ALIGN(size, SZ_2M);
	unsigned long nchunks = aligned >> 21;
	struct fki_kmem *km;
	unsigned long i, j;
	int err = 0;

	if (!(fki_caps() & FKI_CAP_HIGH_WINDOW))
		return -EOPNOTSUPP;
	if (active_kmem)
		return -EBUSY;
	if ((high_va & (SZ_2M - 1)) || (pa_base & (SZ_2M - 1)) || !aligned)
		return -EINVAL;

	km = kzalloc(sizeof(*km), GFP_KERNEL);
	if (!km)
		return -ENOMEM;
	km->high_va = high_va;
	km->pa_base = pa_base;
	km->size = aligned;
	km->nchunks = nchunks;
	INIT_LIST_HEAD(&km->pts);
	xa_init_flags(&km->dyn_slots, XA_FLAGS_LOCK_IRQ);
	spin_lock_init(&km->lock);

	km->chunks = kvcalloc(nchunks, sizeof(*km->chunks), GFP_KERNEL);
	if (!km->chunks) {
		kfree(km);
		return -ENOMEM;
	}

	for (i = 0; i < nchunks; i++) {
		struct fki_kmem_chunk *ch = &km->chunks[i];
		unsigned long cva = high_va + (i << 21);
		struct page *pg = alloc_pages(GFP_KERNEL | __GFP_ZERO | __GFP_NOWARN, 9);
		unsigned long lf = 0;

		if (pg) {
			unsigned long gpa = page_to_phys(pg);

			lf = l4h_large_frame(gpa);
			if (lf) {
				unsigned long slot = l4h_cap_copy(lf, L4H_RIGHTS_ALL);

				if (!slot) {
					__free_pages(pg, 9);
					err = -ENOMEM;
					goto fail;
				}
				err = map_high_frame(km, slot, cva,
						     L4H_PROT_READ | L4H_PROT_WRITE |
						     L4H_PROT_EXEC | L4H_PROT_LARGE);
				if (err) {
					l4h_slot_delete(slot);
					__free_pages(pg, 9);
					goto fail;
				}
				ch->is_large = true;
				ch->large_pg = pg;
				ch->large_gpa = gpa;
				ch->large_slot = slot;
				continue;
			}
			__free_pages(pg, 9);
		}

		/* Fallback: 512 x 4 KiB pages. */
		ch->small_pgs = kcalloc(512, sizeof(*ch->small_pgs), GFP_KERNEL);
		ch->small_slots = kcalloc(512, sizeof(*ch->small_slots), GFP_KERNEL);
		if (!ch->small_pgs || !ch->small_slots) {
			err = -ENOMEM;
			goto fail;
		}
		for (j = 0; j < 512; j++) {
			unsigned long gpa, slot;

			ch->small_pgs[j] = alloc_page(GFP_KERNEL | __GFP_ZERO);
			if (!ch->small_pgs[j]) {
				err = -ENOMEM;
				goto fail;
			}
			gpa = page_to_phys(ch->small_pgs[j]);
			slot = l4h_cap_copy(L4H_FRAME_CPTR(gpa), L4H_RIGHTS_ALL);
			if (!slot) {
				err = -ENOMEM;
				goto fail;
			}
			err = map_high_frame(km, slot, cva + (j << PAGE_SHIFT),
					     L4H_PROT_READ | L4H_PROT_WRITE | L4H_PROT_EXEC);
			if (err) {
				l4h_slot_delete(slot);
				goto fail;
			}
			ch->small_slots[j] = slot;
		}
	}

	active_kmem = km;
	on_each_cpu(bind_high_vspace_cpu, (void *)L4H_CPTR(L4H_SLOT_HIGH_VSPACE), 1);

	r->va = (void *)high_va;
	r->pa = pa_base;
	r->size = aligned;
	r->handle = km;
	return 0;

fail:
	kmem_cleanup(km);
	return err;
}
EXPORT_SYMBOL(fki_kmem_alloc);

void fki_kmem_free(struct fki_region *r)
{
	struct fki_kmem *km = r ? r->handle : NULL;

	if (!km)
		return;
	on_each_cpu(bind_high_vspace_cpu, (void *)0UL, 1);
	if (active_kmem == km)
		active_kmem = NULL;
	kmem_cleanup(km);
	r->va = NULL;
	r->handle = NULL;
}
EXPORT_SYMBOL(fki_kmem_free);

static int prot_to_l4h(int prot)
{
	int p = 0;

	if (prot & FKI_PROT_READ)
		p |= L4H_PROT_READ;
	if (prot & FKI_PROT_WRITE)
		p |= L4H_PROT_WRITE;
	if (prot & FKI_PROT_EXEC)
		p |= L4H_PROT_EXEC;
	return p;
}

int fki_high_map(unsigned long va, fki_u64 xpa, unsigned long size, int prot)
{
	struct fki_kmem *km = active_kmem;
	unsigned long flags, off;
	int lprot = prot_to_l4h(prot);
	int err = 0;

	if (!km)
		return -ENODEV;
	if ((va | xpa | size) & ~PAGE_MASK)
		return -EINVAL;
	/* Initial linear aperture is already mapped RWX (often with 2 MiB large frames). */
	if (va >= km->high_va && va + size <= km->high_va + km->size &&
	    xpa >= km->pa_base && (va - km->high_va) == (unsigned long)(xpa - km->pa_base))
		return 0;

	spin_lock_irqsave(&km->lock, flags);
	for (off = 0; off < size; ) {
		unsigned long cur_va = va + off;
		fki_u64 cur_xpa = xpa + off;
		unsigned long pfn = cur_va >> PAGE_SHIFT;
		unsigned long gpa, slot;
		void *old;

		/* Fast path: 2 MiB aligned VA/PA/size backed by a large frame. */
		if (((cur_va | cur_xpa) & (SZ_2M - 1)) == 0 && (size - off) >= SZ_2M &&
		    cur_xpa >= km->pa_base && cur_xpa + SZ_2M <= km->pa_base + km->size) {
			unsigned long ci = (unsigned long)(cur_xpa - km->pa_base) >> 21;
			struct fki_kmem_chunk *ch = &km->chunks[ci];

			if (ch->is_large) {
				unsigned long lf = l4h_large_frame(ch->large_gpa);
				unsigned long sub;

				if (lf) {
					for (sub = 0; sub < 512; sub++) {
						old = xa_erase(&km->dyn_slots, pfn + sub);
						if (old) {
							unsigned long old_slot = xa_to_value(old);

							if (old_slot)
								l4h_slot_delete(old_slot);
						}
					}
					slot = l4h_cap_copy(lf, L4H_RIGHTS_ALL);
					if (!slot) {
						err = -ENOMEM;
						break;
					}
					err = map_high_frame(km, slot, cur_va,
							     lprot | L4H_PROT_LARGE);
					if (err) {
						l4h_slot_delete(slot);
						break;
					}
					if (xa_err(xa_store(&km->dyn_slots, pfn,
							    xa_mk_value(slot), GFP_ATOMIC))) {
						l4h_slot_delete(slot);
						err = -ENOMEM;
						break;
					}
					off += SZ_2M;
					continue;
				}
			}
		}

		err = xpa_to_gpa(km, cur_xpa, &gpa);
		if (err)
			break;
		old = xa_erase(&km->dyn_slots, pfn);
		if (old) {
			unsigned long old_slot = xa_to_value(old);

			if (old_slot)
				l4h_slot_delete(old_slot);
		}
		slot = l4h_cap_copy(L4H_FRAME_CPTR(gpa), L4H_RIGHTS_ALL);
		if (!slot) {
			err = -ENOMEM;
			break;
		}
		err = map_high_frame(km, slot, cur_va, lprot);
		if (err) {
			l4h_slot_delete(slot);
			break;
		}
		if (xa_err(xa_store(&km->dyn_slots, pfn, xa_mk_value(slot), GFP_ATOMIC))) {
			l4h_slot_delete(slot);
			err = -ENOMEM;
			break;
		}
		off += PAGE_SIZE;
	}
	spin_unlock_irqrestore(&km->lock, flags);
	return err;
}
EXPORT_SYMBOL(fki_high_map);

void fki_high_unmap(unsigned long va, unsigned long size)
{
	struct fki_kmem *km = active_kmem;
	unsigned long flags, off;

	if (!km)
		return;
	spin_lock_irqsave(&km->lock, flags);
	for (off = 0; off < size; off += PAGE_SIZE) {
		unsigned long pfn = (va + off) >> PAGE_SHIFT;
		void *old = xa_erase(&km->dyn_slots, pfn);

		if (old) {
			unsigned long old_slot = xa_to_value(old);

			if (old_slot)
				l4h_slot_delete(old_slot);
		}
	}
	spin_unlock_irqrestore(&km->lock, flags);
}
EXPORT_SYMBOL(fki_high_unmap);

void fki_high_flush(void)
{
	if (fki_caps() & FKI_CAP_HIGH_WINDOW)
		l4h_vspace_flush(L4H_CPTR(L4H_SLOT_HIGH_VSPACE));
}
EXPORT_SYMBOL(fki_high_flush);

/* Use high window for fki_region_alloc so mode=1 smoke tests have executable memory. */
int fki_region_alloc(unsigned long size, struct fki_region *r)
{
	return fki_kmem_alloc(size, FKI_L4H_REGION_VA, FKI_L4H_REGION_PA, r);
}
EXPORT_SYMBOL(fki_region_alloc);

void fki_region_free(struct fki_region *r)
{
	fki_kmem_free(r);
}
EXPORT_SYMBOL(fki_region_free);

fki_u64 fki_phys_peek(fki_u64 pa)
{
	unsigned long gpa;

	if (xpa_to_gpa(active_kmem, pa & ~7ULL, &gpa) == 0)
		return READ_ONCE(*(u64 *)phys_to_virt(gpa));
	return ~0ULL;
}
EXPORT_SYMBOL(fki_phys_peek);

/* ---- EL1-only primitives (unsupported on EL0 host) ---- */

int fki_contig_alloc(unsigned long size, struct fki_region *r) { return -EOPNOTSUPP; }
EXPORT_SYMBOL(fki_contig_alloc);
void fki_contig_free(struct fki_region *r) {}
EXPORT_SYMBOL(fki_contig_free);
int fki_window_l1(unsigned long va, unsigned long long **l1_va, fki_u64 *l1_pa) { return -EOPNOTSUPP; }
EXPORT_SYMBOL(fki_window_l1);
void fki_window_set(unsigned long long *slot, fki_u64 desc) {}
EXPORT_SYMBOL(fki_window_set);
unsigned long fki_regs_pc(void *regs) { return 0; }
EXPORT_SYMBOL(fki_regs_pc);
unsigned long fki_regs_lr(void *regs) { return 0; }
EXPORT_SYMBOL(fki_regs_lr);
unsigned long fki_regs_pstate(void *regs) { return 0; }
EXPORT_SYMBOL(fki_regs_pstate);
void fki_regs_set_pc(void *regs, unsigned long pc) {}
EXPORT_SYMBOL(fki_regs_set_pc);
void fki_regs_set_reg(void *regs, unsigned int n, unsigned long v) {}
EXPORT_SYMBOL(fki_regs_set_reg);
unsigned long fki_regs_reg(void *regs, unsigned int n) { return 0; }
EXPORT_SYMBOL(fki_regs_reg);
int fki_fault_register(unsigned long lo, unsigned long hi, int (*handler)(unsigned long far, unsigned long esr, void *regs)) { return -EOPNOTSUPP; }
EXPORT_SYMBOL(fki_fault_register);
void fki_fault_unregister(void) {}
EXPORT_SYMBOL(fki_fault_unregister);

/* ---- User address space & uTCB primitives (Phase 4) ---- */

void *fki_as_create(void) { return NULL; }
EXPORT_SYMBOL(fki_as_create);
void fki_as_destroy(void *as) {}
EXPORT_SYMBOL(fki_as_destroy);
int fki_as_map(void *as, unsigned long va, fki_u64 xpa, unsigned long size, int prot) { return -EOPNOTSUPP; }
EXPORT_SYMBOL(fki_as_map);
void fki_as_unmap(void *as, unsigned long va, unsigned long size) {}
EXPORT_SYMBOL(fki_as_unmap);
void fki_as_flush(void *as) {}
EXPORT_SYMBOL(fki_as_flush);
void *fki_utcb_create(void *as) { return NULL; }
EXPORT_SYMBOL(fki_utcb_create);
void fki_utcb_destroy(void *utcb) {}
EXPORT_SYMBOL(fki_utcb_destroy);
int fki_utcb_set_as(void *utcb, void *as) { return -EOPNOTSUPP; }
EXPORT_SYMBOL(fki_utcb_set_as);
int fki_utcb_set_pac(void *utcb, const struct fki_pac_keys *keys) { return -EOPNOTSUPP; }
EXPORT_SYMBOL(fki_utcb_set_pac);
int fki_utcb_run(void *utcb, struct fki_utcb_regs *regs, struct fki_utcb_stop *stop) { return -EOPNOTSUPP; }
EXPORT_SYMBOL(fki_utcb_run);
int fki_utcb_fpu_read(void *utcb, void *buf, unsigned long len) { return -EOPNOTSUPP; }
EXPORT_SYMBOL(fki_utcb_fpu_read);
int fki_utcb_fpu_write(void *utcb, const void *buf, unsigned long len) { return -EOPNOTSUPP; }
EXPORT_SYMBOL(fki_utcb_fpu_write);

/* ---- arch init / exit ---- */

static void fki_free_alt_stacks(void)
{
	int cpu;

	for_each_possible_cpu(cpu) {
		if (fki_alt_stack[cpu])
			free_pages((unsigned long)fki_alt_stack[cpu], FKI_ALT_STACK_ORDER);
		fki_alt_stack[cpu] = NULL;
	}
}

int fki_arch_init(void)
{
	int cpu;

	for_each_possible_cpu(cpu) {
		struct page *pg = alloc_pages(GFP_KERNEL, FKI_ALT_STACK_ORDER);

		if (!pg) {
			fki_free_alt_stacks();
			return -ENOMEM;
		}
		fki_alt_stack[cpu] = page_address(pg);
	}
	return 0;
}

void fki_arch_exit(void)
{
	fki_free_alt_stacks();
}
