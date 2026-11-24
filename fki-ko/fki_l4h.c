// SPDX-License-Identifier: GPL-2.0-only
/*
 * Foreign kernel interface, version 1: L4H AArch64 (EL0) backend.
 */
#include "fki.h"
#include "fki_internal.h"
#include <linux/atomic.h>
#include <linux/errno.h>
#include <linux/gfp.h>
#include <linux/io.h>
#include <linux/irqflags.h>
#include <linux/list.h>
#include <linux/minmax.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/preempt.h>
#include <linux/printk.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/smp.h>
#include <linux/spinlock.h>
#include <linux/string.h>
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
static DEFINE_PER_CPU(struct l4h_uctx *, fki_cur_utcb);

static void fki_utcb_release_sc(void)
{
	struct l4h_uctx *u = this_cpu_read(fki_cur_utcb);

	if (u) {
		if (u->sc_vcpu >= 0)
			l4h_user_deschedule(u);
		this_cpu_write(fki_cur_utcb, NULL);
	}
}

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
	fki_utcb_release_sc();
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

	fki_utcb_release_sc();
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

static int fki_vs_pool_init(void);
static void fki_vs_pool_fini(void);

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

	err = fki_vs_pool_init();
	if (err)
		goto fail;

	active_kmem = km;
	on_each_cpu(bind_high_vspace_cpu, (void *)L4H_CPTR(L4H_SLOT_HIGH_VSPACE), 1);

	r->va = (void *)high_va;
	r->pa = pa_base;
	r->size = aligned;
	r->handle = km;
	return 0;

fail:
	fki_vs_pool_fini();
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
	fki_vs_pool_fini();
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
	if (err)
		pr_err_ratelimited("fki: high_map va=0x%lx xpa=0x%llx size=0x%lx prot=0x%x failed: %d\n",
				   va, xpa, size, prot, err);
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

/* ---- User address space & uTCB primitives ---- */

#define FKI_AS_SLOT_BITS	30
#define FKI_AS_SLOT_MASK	((1UL << FKI_AS_SLOT_BITS) - 1)
#define FKI_AS_PROT_SHIFT	FKI_AS_SLOT_BITS
#define FKI_AS_PROT_MASK	7UL
#define FKI_AS_PFN_SHIFT	(FKI_AS_SLOT_BITS + 3)

static inline unsigned long fki_eff_prot(int lprot)
{
	lprot &= FKI_AS_PROT_MASK;
	return (lprot & L4H_PROT_WRITE) ? (lprot | L4H_PROT_READ) : lprot;
}

static inline void *fki_as_mk_entry(unsigned long cptr, unsigned long pfn, unsigned long lprot)
{
	return xa_mk_value((pfn << FKI_AS_PFN_SHIFT) |
			   ((lprot & FKI_AS_PROT_MASK) << FKI_AS_PROT_SHIFT) |
			   (cptr & FKI_AS_SLOT_MASK));
}

static inline unsigned long fki_as_entry_cptr(void *e)
{
	return xa_to_value(e) & FKI_AS_SLOT_MASK;
}

static inline unsigned long fki_as_entry_pfn(void *e)
{
	return xa_to_value(e) >> FKI_AS_PFN_SHIFT;
}

static inline unsigned long fki_as_entry_prot(void *e)
{
	return (xa_to_value(e) >> FKI_AS_PROT_SHIFT) & FKI_AS_PROT_MASK;
}

struct fki_as {
	int vs_idx;
	u64 gen;
	atomic_t active_cpus;
	spinlock_t lock;
};

struct fki_vs_slot {
	unsigned long root;
	struct fki_as *owner;
	struct list_head lru;
	struct list_head pts;
	struct xarray slots;
};

static struct fki_vs_slot *fki_vs_pool;
static int fki_vs_cap;
static LIST_HEAD(fki_vs_free);
static LIST_HEAD(fki_vs_lru);
static DEFINE_SPINLOCK(fki_vs_lock);
static int fki_vs_resetting;
static atomic64_t fki_vs_gen = ATOMIC64_INIT(1);

static void fki_vs_slot_reset(struct fki_vs_slot *slot)
{
	struct fki_pt_node *node, *tmp;
	unsigned long vpn;
	void *e;

	/* Free page tables in reverse order (highest level first) to avoid per-frame shootdowns. */
	list_for_each_entry_safe_reverse(node, tmp, &slot->pts, list) {
		list_del(&node->list);
		l4h_obj_free(&node->pt);
		kfree(node);
	}
	xa_for_each(&slot->slots, vpn, e) {
		unsigned long cptr = fki_as_entry_cptr(e);

		if (cptr)
			l4h_slot_delete(cptr);
	}
	xa_destroy(&slot->slots);
	xa_init(&slot->slots);
	l4h_vspace_flush(slot->root);
}

static int fki_vs_pool_init(void)
{
	int nr, cap, i;

	if (fki_vs_pool)
		return 0;
	nr = (int)l4h_bootinfo->nr_vspaces;
	cap = nr > 80 ? clamp(nr - 48, 32, 192) : (nr > 16 ? nr / 2 : 0);
	if (cap <= 0)
		return -ENOMEM;

	fki_vs_pool = kcalloc(cap, sizeof(*fki_vs_pool), GFP_KERNEL);
	if (!fki_vs_pool)
		return -ENOMEM;

	INIT_LIST_HEAD(&fki_vs_free);
	INIT_LIST_HEAD(&fki_vs_lru);
	fki_vs_resetting = 0;

	for (i = 0; i < cap; i++) {
		unsigned long root = l4h_vspace_get();

		if (!root) {
			fki_vs_cap = i;
			fki_vs_pool_fini();
			return -ENOMEM;
		}
		fki_vs_pool[i].root = root;
		fki_vs_pool[i].owner = NULL;
		INIT_LIST_HEAD(&fki_vs_pool[i].lru);
		INIT_LIST_HEAD(&fki_vs_pool[i].pts);
		xa_init(&fki_vs_pool[i].slots);
		list_add_tail(&fki_vs_pool[i].lru, &fki_vs_free);
	}
	fki_vs_cap = cap;
	pr_info("fki: reserved %d/%d user VSpaces for hosted user spaces\n", cap, nr);
	return 0;
}

static void fki_vs_pool_fini(void)
{
	int i;

	if (!fki_vs_pool)
		return;
	for (i = 0; i < fki_vs_cap; i++) {
		struct fki_vs_slot *slot = &fki_vs_pool[i];

		if (slot->owner) {
			slot->owner->vs_idx = -1;
			slot->owner->gen++;
			slot->owner = NULL;
		}
		fki_vs_slot_reset(slot);
		if (slot->root)
			l4h_vspace_put(slot->root);
	}
	kfree(fki_vs_pool);
	fki_vs_pool = NULL;
	fki_vs_cap = 0;
	INIT_LIST_HEAD(&fki_vs_free);
	INIT_LIST_HEAD(&fki_vs_lru);
}

void *fki_as_create(void)
{
	struct fki_as *as = kzalloc(sizeof(*as), GFP_ATOMIC);

	if (!as)
		return NULL;
	as->vs_idx = -1;
	as->gen = 0;
	atomic_set(&as->active_cpus, 0);
	spin_lock_init(&as->lock);
	return as;
}
EXPORT_SYMBOL(fki_as_create);

void fki_as_destroy(void *as_ptr)
{
	struct fki_as *as = as_ptr;
	struct fki_vs_slot *slot = NULL;
	unsigned long flags;

	if (!as)
		return;
	spin_lock_irqsave(&fki_vs_lock, flags);
	spin_lock(&as->lock);
	if (as->vs_idx >= 0 && fki_vs_pool) {
		slot = &fki_vs_pool[as->vs_idx];
		as->vs_idx = -1;
		as->gen++;
		slot->owner = NULL;
		list_del_init(&slot->lru);
		fki_vs_resetting++;
	}
	spin_unlock(&as->lock);
	spin_unlock_irqrestore(&fki_vs_lock, flags);

	if (slot) {
		fki_vs_slot_reset(slot);
		spin_lock_irqsave(&fki_vs_lock, flags);
		fki_vs_resetting--;
		list_add(&slot->lru, &fki_vs_free);
		spin_unlock_irqrestore(&fki_vs_lock, flags);
	}
	kfree(as);
}
EXPORT_SYMBOL(fki_as_destroy);

static int map_user_frame(struct fki_vs_slot *slot, unsigned long cptr,
			  unsigned long va, unsigned long lprot)
{
	int err;

	while ((err = l4h_page_map(cptr, slot->root, va, (int)lprot)) == L4H_ERR_FAILED_LOOKUP) {
		struct fki_pt_node *node = kzalloc(sizeof(*node), GFP_ATOMIC);

		if (!node)
			return -ENOMEM;
		if (l4h_obj_alloc(L4H_OBJ_PT, 0, &node->pt)) {
			kfree(node);
			return -ENOMEM;
		}
		err = l4h_pt_map(L4H_OBJ_PT, node->pt.cptr, slot->root, va);
		if (err) {
			l4h_obj_free(&node->pt);
			kfree(node);
			return -EIO;
		}
		list_add(&node->list, &slot->pts);
	}
	return err ? -EIO : 0;
}

int fki_as_map(void *as_ptr, unsigned long va, fki_u64 xpa, unsigned long size, int prot)
{
	struct fki_as *as = as_ptr;
	struct fki_kmem *km = active_kmem;
	unsigned long lprot = fki_eff_prot(prot_to_l4h(prot));
	unsigned long flags, off;
	int changed = 0, err = 0;

	if (!as || !km)
		return -ENODEV;
	if ((va | xpa | size) & ~PAGE_MASK)
		return -EINVAL;
	if (!size)
		return 0;
	if (!lprot) {
		fki_as_unmap(as, va, size);
		return 0;
	}

	spin_lock_irqsave(&as->lock, flags);
	if (as->vs_idx < 0 || !fki_vs_pool) {
		spin_unlock_irqrestore(&as->lock, flags);
		return 0;
	}
	{
		struct fki_vs_slot *slot = &fki_vs_pool[as->vs_idx];

		for (off = 0; off < size; off += PAGE_SIZE) {
			unsigned long cur_va = va + off;
			fki_u64 cur_xpa = xpa + off;
			unsigned long vpn = cur_va >> PAGE_SHIFT;
			unsigned long gpa, pfn, cptr;
			void *e;

			err = xpa_to_gpa(km, cur_xpa, &gpa);
			if (err)
				break;
			pfn = gpa >> PAGE_SHIFT;
			e = xa_load(&slot->slots, vpn);
			if (e && fki_as_entry_pfn(e) == pfn) {
				if (fki_as_entry_prot(e) == lprot)
					continue;
				cptr = fki_as_entry_cptr(e);
				if (l4h_page_map(cptr, slot->root, cur_va, (int)lprot) == 0) {
					xa_store(&slot->slots, vpn,
						 fki_as_mk_entry(cptr, pfn, lprot), GFP_ATOMIC);
					changed = 1;
					continue;
				}
				/* Remap failed: delete and recreate below. */
			}
			if (e) {
				unsigned long old_cptr = fki_as_entry_cptr(e);

				xa_erase(&slot->slots, vpn);
				if (old_cptr)
					l4h_slot_delete(old_cptr);
			}
			cptr = l4h_cap_copy(L4H_FRAME_CPTR(gpa), L4H_RIGHTS_ALL);
			if (!cptr) {
				err = -ENOMEM;
				break;
			}
			err = map_user_frame(slot, cptr, cur_va, lprot);
			if (err) {
				l4h_slot_delete(cptr);
				break;
			}
			if (xa_err(xa_store(&slot->slots, vpn,
					    fki_as_mk_entry(cptr, pfn, lprot), GFP_ATOMIC))) {
				l4h_slot_delete(cptr);
				err = -ENOMEM;
				break;
			}
			changed = 1;
		}
	}
	spin_unlock_irqrestore(&as->lock, flags);
	return err ? err : changed;
}
EXPORT_SYMBOL(fki_as_map);

void fki_as_unmap(void *as_ptr, unsigned long va, unsigned long size)
{
	struct fki_as *as = as_ptr;
	unsigned long flags, off;

	if (!as || !size)
		return;
	spin_lock_irqsave(&as->lock, flags);
	if (as->vs_idx >= 0 && fki_vs_pool) {
		struct fki_vs_slot *slot = &fki_vs_pool[as->vs_idx];

		for (off = 0; off < size; off += PAGE_SIZE) {
			unsigned long vpn = (va + off) >> PAGE_SHIFT;
			void *e = xa_erase(&slot->slots, vpn);

			if (e) {
				unsigned long cptr = fki_as_entry_cptr(e);

				if (cptr)
					l4h_slot_delete(cptr);
			}
		}
	}
	spin_unlock_irqrestore(&as->lock, flags);
}
EXPORT_SYMBOL(fki_as_unmap);

void fki_as_flush(void *as_ptr)
{
	struct fki_as *as = as_ptr;
	unsigned long flags;

	if (!as)
		return;
	spin_lock_irqsave(&as->lock, flags);
	if (as->vs_idx >= 0 && fki_vs_pool)
		l4h_vspace_flush(fki_vs_pool[as->vs_idx].root);
	spin_unlock_irqrestore(&as->lock, flags);
}
EXPORT_SYMBOL(fki_as_flush);

/* Caller must have incremented as->active_cpus before calling. */
static struct fki_vs_slot *fki_vs_activate(struct fki_as *as, u64 *gen_out)
{
	struct fki_vs_slot *slot, *victim;
	unsigned long flags;

	if (!fki_vs_pool)
		return NULL;

	for (;;) {
		spin_lock_irqsave(&fki_vs_lock, flags);
		if (as->vs_idx >= 0) {
			slot = &fki_vs_pool[as->vs_idx];
			list_move_tail(&slot->lru, &fki_vs_lru);
			*gen_out = as->gen;
			spin_unlock_irqrestore(&fki_vs_lock, flags);
			return slot;
		}
		if (!list_empty(&fki_vs_free)) {
			slot = list_first_entry(&fki_vs_free, struct fki_vs_slot, lru);
			list_del_init(&slot->lru);
			spin_lock(&as->lock);
			slot->owner = as;
			as->vs_idx = (int)(slot - fki_vs_pool);
			as->gen = (u64)atomic64_inc_return(&fki_vs_gen);
			*gen_out = as->gen;
			spin_unlock(&as->lock);
			list_add_tail(&slot->lru, &fki_vs_lru);
			spin_unlock_irqrestore(&fki_vs_lock, flags);
			return slot;
		}
		victim = NULL;
		list_for_each_entry(slot, &fki_vs_lru, lru) {
			if (slot->owner && atomic_read(&slot->owner->active_cpus) == 0) {
				victim = slot;
				break;
			}
		}
		if (victim) {
			struct fki_as *vas = victim->owner;

			spin_lock(&vas->lock);
			vas->vs_idx = -1;
			vas->gen++;
			victim->owner = NULL;
			list_del_init(&victim->lru);
			fki_vs_resetting++;
			spin_unlock(&vas->lock);
			spin_unlock_irqrestore(&fki_vs_lock, flags);

			fki_vs_slot_reset(victim);

			spin_lock_irqsave(&fki_vs_lock, flags);
			fki_vs_resetting--;
			list_add(&victim->lru, &fki_vs_free);
			spin_unlock_irqrestore(&fki_vs_lock, flags);
			continue;
		}
		if (!fki_vs_resetting) {
			spin_unlock_irqrestore(&fki_vs_lock, flags);
			pr_err("fki: all %d user VSpaces are pinned by active CPUs\n", fki_vs_cap);
			return NULL;
		}
		spin_unlock_irqrestore(&fki_vs_lock, flags);
		cpu_relax();
	}
}

struct fki_utcb {
	struct l4h_uctx u;
	struct l4h_obj tcb_obj;
	struct l4h_obj reply_obj;
	struct fki_as *as;
	u64 as_gen;
	int cpu;
	bool have_tls;
	u64 last_tpidr;
	u64 last_tpidrro;
	bool have_pac;
	struct fki_pac_keys last_pac;
};

void *fki_utcb_create(void *as_ptr)
{
	struct fki_utcb *utcb;
	struct l4h_uctx *u;
	int cpu = smp_processor_id();

	utcb = kzalloc(sizeof(*utcb), GFP_ATOMIC);
	if (!utcb)
		return NULL;
	u = &utcb->u;

	if (l4h_obj_alloc(L4H_OBJ_TCB, 0, &utcb->tcb_obj))
		goto fail_free;
	if (l4h_obj_alloc(L4H_OBJ_REPLY, 0, &utcb->reply_obj))
		goto fail_tcb;
	u->fault_ep = l4h_slot_alloc();
	if (!u->fault_ep)
		goto fail_reply;

	u->tcb = utcb->tcb_obj.cptr;
	u->reply = utcb->reply_obj.cptr;
	u->badge = l4h_uctx_alloc_badge();
	if (l4h_cnode_mint(u->fault_ep, 64, L4H_SLOT_VCPU(cpu) + L4H_VCPU_EP,
			   L4H_ROOT_DEPTH, L4H_RIGHTS_ALL, u->badge))
		goto fail_ep;
	if (l4h_tcb_set_flags(u->tcb, 1 /* fpuDisabled */, 2 /* trapSyscalls */))
		goto fail_ep;

	u->fault_ep_vcpu = cpu;
	u->sc_vcpu = -1;
	u->vspace = 0;
	u->state = L4H_UCTX_FRESH;
	u->regs_valid = 1;
	utcb->cpu = cpu;
	utcb->as = as_ptr;
	return utcb;

fail_ep:
	l4h_slot_delete(u->fault_ep);
fail_reply:
	l4h_obj_free(&utcb->reply_obj);
fail_tcb:
	l4h_obj_free(&utcb->tcb_obj);
fail_free:
	kfree(utcb);
	return NULL;
}
EXPORT_SYMBOL(fki_utcb_create);

void fki_utcb_destroy(void *utcb_ptr)
{
	struct fki_utcb *utcb = utcb_ptr;
	struct l4h_uctx *u;

	if (!utcb)
		return;
	u = &utcb->u;
	if (u->sc_vcpu >= 0) {
		if (u->sc_vcpu == smp_processor_id()) {
			if (this_cpu_read(fki_cur_utcb) == u)
				this_cpu_write(fki_cur_utcb, NULL);
			l4h_user_deschedule(u);
		}
	}
	if (u->fault_ep)
		l4h_slot_delete(u->fault_ep);
	l4h_obj_free(&utcb->reply_obj);
	l4h_obj_free(&utcb->tcb_obj);
	kfree(utcb);
}
EXPORT_SYMBOL(fki_utcb_destroy);

int fki_utcb_set_as(void *utcb_ptr, void *as_ptr)
{
	struct fki_utcb *utcb = utcb_ptr;

	if (!utcb || !as_ptr)
		return -EINVAL;
	utcb->as = as_ptr;
	return 0;
}
EXPORT_SYMBOL(fki_utcb_set_as);

int fki_utcb_set_pac(void *utcb_ptr, const struct fki_pac_keys *keys)
{
	struct fki_utcb *utcb = utcb_ptr;
	unsigned long words[L4H_PAC_KEY_WORDS];
	unsigned long en;
	int err;

	if (!utcb || !keys)
		return -EINVAL;
	if (pac_unsupported || !(l4h_provider_features() & L4H_PROVIDER_ARM_PAC))
		return 0;
	if (utcb->have_pac && memcmp(&utcb->last_pac, keys, sizeof(*keys)) == 0)
		return 0;

	en = sctlr_to_l4h_pac_en(keys->sctlr_en);
	if (!en) {
		err = l4h_tcb_set_pac(utcb->u.tcb, 0, NULL);
	} else {
		words[0] = keys->ia[0]; words[1] = keys->ia[1];
		words[2] = keys->ib[0]; words[3] = keys->ib[1];
		words[4] = keys->da[0]; words[5] = keys->da[1];
		words[6] = keys->db[0]; words[7] = keys->db[1];
		words[8] = keys->ga[0]; words[9] = keys->ga[1];
		err = l4h_tcb_set_pac(utcb->u.tcb, en, words);
	}
	if (err == FKI_L4H_ERR_ILLEGAL_OP) {
		pac_unsupported = true;
		return 0;
	}
	if (err)
		return -EIO;
	utcb->last_pac = *keys;
	utcb->have_pac = true;
	return 0;
}
EXPORT_SYMBOL(fki_utcb_set_pac);

int fki_utcb_run(void *utcb_ptr, struct fki_utcb_regs *regs, struct fki_utcb_stop *stop)
{
	struct fki_utcb *utcb = utcb_ptr;
	struct l4h_uctx *u;
	struct fki_as *as;
	struct fki_vs_slot *slot;
	unsigned long gp[40];
	u64 gen = 0;
	bool as_changed, seg_changed;
	int st, i;

	if (!utcb || !regs || !stop || !utcb->as)
		return -EINVAL;
	u = &utcb->u;
	as = utcb->as;

	atomic_inc(&as->active_cpus);
	slot = fki_vs_activate(as, &gen);
	if (!slot) {
		atomic_dec(&as->active_cpus);
		return -ENOMEM;
	}

	as_changed = (u->vspace != slot->root || utcb->as_gen != gen);
	if (as_changed) {
		int err;

		if (u->state == L4H_UCTX_FRESH && !u->vspace)
			err = l4h_tcb_configure_user(u->tcb, l4h_empty_cnode_cptr(), slot->root);
		else
			err = l4h_tcb_set_space(u->tcb, u->fault_ep, l4h_empty_cnode_cptr(), slot->root);
		if (err) {
			atomic_dec(&as->active_cpus);
			pr_err("fki: binding user TCB to VSpace failed: %d\n", err);
			return -EIO;
		}
		u->vspace = slot->root;
		utcb->as_gen = gen;
	}

	memset(gp, 0, sizeof(gp));
	for (i = 0; i < 31; i++)
		gp[i] = (unsigned long)regs->x[i];
	gp[31] = (unsigned long)regs->sp;
	gp[32] = (unsigned long)regs->pc;
	gp[33] = (unsigned long)(regs->pstate & 0xf0000000UL);
	gp[L4H_GP_TLS] = (unsigned long)regs->tpidr;
	gp[L4H_GP_TLS_RO] = (unsigned long)regs->tpidrro;

	seg_changed = (!utcb->have_tls ||
		       regs->tpidr != utcb->last_tpidr ||
		       regs->tpidrro != utcb->last_tpidrro ||
		       as_changed ||
		       u->state == L4H_UCTX_FRESH);
	l4h_user_mark_dirty(u, seg_changed ? 1 : 0);

	this_cpu_write(fki_cur_utcb, u);
	st = l4h_user_run(u, gp, 1);
	if (!u->regs_valid)
		l4h_user_sync_regs(u, gp);

	atomic_dec(&as->active_cpus);

	for (i = 0; i < 31; i++)
		regs->x[i] = gp[i];
	regs->sp = gp[31];
	regs->pc = gp[32];
	regs->pstate = gp[33];
	regs->tpidr = gp[L4H_GP_TLS];
	regs->tpidrro = gp[L4H_GP_TLS_RO];
	utcb->last_tpidr = regs->tpidr;
	utcb->last_tpidrro = regs->tpidrro;
	utcb->have_tls = true;

	switch (st) {
	case L4H_STOP_SYSCALL:
		stop->kind = FKI_STOP_SYSCALL;
		stop->esr = (0x15ULL << 26) | (1ULL << 25) | 0x80ULL;
		stop->fault_ip = gp[32];
		stop->fault_addr = 0;
		break;
	case L4H_STOP_PAGEFAULT:
		stop->kind = FKI_STOP_PAGEFAULT;
		stop->esr = u->raw_fsr;
		stop->fault_addr = u->fault_addr;
		stop->fault_ip = u->fault_ip;
		break;
	case L4H_STOP_EXCEPTION:
		stop->kind = FKI_STOP_EXCEPTION;
		stop->esr = u->exc_number;
		stop->fault_addr = u->fault_addr;
		stop->fault_ip = u->fault_ip;
		break;
	case L4H_STOP_INTERRUPT:
		stop->kind = FKI_STOP_INTERRUPT;
		stop->esr = ~0ULL;
		stop->fault_addr = 0;
		stop->fault_ip = gp[32];
		break;
	default:
		return -EIO;
	}
	return 0;
}
EXPORT_SYMBOL(fki_utcb_run);

int fki_utcb_fpu_read(void *utcb_ptr, void *buf, unsigned long len)
{
	struct fki_utcb *utcb = utcb_ptr;

	if (!utcb || !buf || !len)
		return -EINVAL;
	if (utcb->u.state == L4H_UCTX_FRESH) {
		memset(buf, 0, len);
		return 0;
	}
	return l4h_fpu_read(&utcb->u, buf, len) ? -EIO : 0;
}
EXPORT_SYMBOL(fki_utcb_fpu_read);

int fki_utcb_fpu_write(void *utcb_ptr, const void *buf, unsigned long len)
{
	struct fki_utcb *utcb = utcb_ptr;

	if (!utcb || !buf || !len)
		return -EINVAL;
	return l4h_fpu_write(&utcb->u, buf, len) ? -EIO : 0;
}
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
