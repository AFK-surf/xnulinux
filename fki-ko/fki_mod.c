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
#include <linux/timekeeping.h>
#include <linux/sched.h>
#include <linux/cpumask.h>
#include <linux/vmalloc.h>
#include <asm/arch_timer.h>
#include <asm/sysreg.h>
#include <asm/tlbflush.h>
#include <asm/barrier.h>
#include <linux/kprobes.h>
#include <linux/hrtimer.h>
#include <linux/kthread.h>
#include <linux/delay.h>
#include <linux/err.h>
#include <linux/sched.h>
#include <linux/fs.h>
#include <asm/stacktrace.h>

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
typedef struct page *(*alloc_contig_fn)(unsigned long nr_pages, gfp_t gfp, int nid, nodemask_t *nodemask);
typedef void (*free_contig_fn)(unsigned long pfn, unsigned long nr_pages);
static alloc_contig_fn p_alloc_contig;
static free_contig_fn p_free_contig;
struct cma;
static struct cma **p_cma_area;	/* the default CMA area (cma= on the command line), if any */
static struct page *(*p_cma_alloc)(struct cma *, unsigned long, unsigned int, bool);	/* not exported on every kernel */
static bool (*p_cma_release)(struct cma *, const struct page *, unsigned long);
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
	p_alloc_contig = (alloc_contig_fn)lookup("alloc_contig_pages_noprof");
	if (!p_alloc_contig)
		p_alloc_contig = (alloc_contig_fn)lookup("alloc_contig_pages");
	p_free_contig = (free_contig_fn)lookup("free_contig_range");
	p_cma_area = (struct cma **)lookup("dma_contiguous_default_area");
	p_cma_alloc = (void *)lookup("cma_alloc");
	p_cma_release = (void *)lookup("cma_release");
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

int fki_bind_cpu(int cpu)
{
	if (cpu < 0 || cpu >= nr_cpu_ids || !cpu_online(cpu))
		return -EINVAL;
	return set_cpus_allowed_ptr(current, cpumask_of(cpu));
}
EXPORT_SYMBOL(fki_bind_cpu);

void *fki_thread_start(int (*fn)(void *), void *arg, int cpu, const char *name)
{
	struct task_struct *t;

	if (cpu < 0 || cpu >= nr_cpu_ids || !cpu_online(cpu))
		return NULL;
	t = kthread_create(fn, arg, "%s", name);
	if (IS_ERR(t))
		return NULL;
	kthread_bind(t, cpu);
	get_task_struct(t);
	wake_up_process(t);
	return t;
}
EXPORT_SYMBOL(fki_thread_start);

void fki_thread_stop(void *thread)
{
	if (thread) {
		kthread_stop(thread);
		put_task_struct(thread);
	}
}
EXPORT_SYMBOL(fki_thread_stop);

int fki_thread_should_stop(void)
{
	return kthread_should_stop();
}
EXPORT_SYMBOL(fki_thread_should_stop);

void fki_msleep(unsigned int ms)
{
	msleep(ms);
}
EXPORT_SYMBOL(fki_msleep);

/*
 * Foreign kernel faults. Out of tree, the hook is a kprobe on __do_kernel_fault(far, esr, regs), where Linux's abort path
 * goes for a kernel address it has no mapping for (do_mem_abort and do_translation_fault cannot be probed). When
 * the handler resolves the fault, __do_kernel_fault is skipped (return to its caller), and the exception returns to retry
 * the access. The in-tree patch calls the hook from do_translation_fault/do_page_fault directly.
 */
static unsigned long fki_fault_lo, fki_fault_hi;
static int (*fki_fault_handler)(unsigned long far, unsigned long esr, void *regs);

static int fki_fault_pre(struct kprobe *p, struct pt_regs *kregs)
{
	unsigned long far = kregs->regs[0], esr = kregs->regs[1];
	struct pt_regs *regs = (struct pt_regs *)kregs->regs[2];
	int (*h)(unsigned long, unsigned long, void *) = READ_ONCE(fki_fault_handler);

	if (!h || user_mode(regs))
		return 0;
	if ((far < fki_fault_lo || far >= fki_fault_hi) &&
	    (instruction_pointer(regs) < fki_fault_lo || instruction_pointer(regs) >= fki_fault_hi))
		return 0;
	if (h(far, esr, regs))
		return 0;
	instruction_pointer_set(kregs, kregs->regs[30]);	/* __do_kernel_fault returns at once */
	return 1;
}
NOKPROBE_SYMBOL(fki_fault_pre);

unsigned long fki_regs_pc(void *regs) { return instruction_pointer((struct pt_regs *)regs); }
EXPORT_SYMBOL(fki_regs_pc);
unsigned long fki_regs_lr(void *regs) { return ((struct pt_regs *)regs)->regs[30]; }
EXPORT_SYMBOL(fki_regs_lr);
unsigned long fki_regs_pstate(void *regs) { return ((struct pt_regs *)regs)->pstate; }
EXPORT_SYMBOL(fki_regs_pstate);
void fki_regs_set_pc(void *regs, unsigned long pc) { instruction_pointer_set((struct pt_regs *)regs, pc); }
EXPORT_SYMBOL(fki_regs_set_pc);
void fki_regs_set_reg(void *regs, unsigned int n, unsigned long v) { if (n < 31) ((struct pt_regs *)regs)->regs[n] = v; }
EXPORT_SYMBOL(fki_regs_set_reg);

static struct kprobe fki_fault_kp = { .symbol_name = "__do_kernel_fault", .pre_handler = fki_fault_pre };
static int fki_fault_registered;

/*
 * Other kernel-mode exceptions the foreign kernel takes (an FPAC authentication failure, an undefined instruction, a
 * BTI fault) end in die(str, regs, err): offered to the same handler with far 0 and the ESR, before Linux oopses.
 */
static int fki_die_pre(struct kprobe *p, struct pt_regs *kregs)
{
	struct pt_regs *regs = (struct pt_regs *)kregs->regs[1];
	unsigned long esr = kregs->regs[2];
	int (*h)(unsigned long, unsigned long, void *) = READ_ONCE(fki_fault_handler);

	if (!h || !regs || user_mode(regs))
		return 0;
	if (instruction_pointer(regs) < fki_fault_lo || instruction_pointer(regs) >= fki_fault_hi)
		return 0;
	if (h(0, esr, regs))
		return 0;
	instruction_pointer_set(kregs, kregs->regs[30]);	/* die returns at once */
	return 1;
}
NOKPROBE_SYMBOL(fki_die_pre);
static struct kprobe fki_die_kp = { .symbol_name = "die", .pre_handler = fki_die_pre };
static int fki_die_registered;

int fki_fault_register(unsigned long lo, unsigned long hi, int (*handler)(unsigned long far, unsigned long esr, void *regs))
{
	int err;

	if (fki_fault_registered)
		return -EBUSY;
	fki_fault_lo = lo;
	fki_fault_hi = hi;
	WRITE_ONCE(fki_fault_handler, handler);
	err = register_kprobe(&fki_fault_kp);
	if (err) {
		WRITE_ONCE(fki_fault_handler, NULL);
		return err;
	}
	fki_fault_registered = 1;
	fki_die_registered = register_kprobe(&fki_die_kp) == 0;	/* best effort */
	if (!fki_die_registered)
		pr_warn("fki: no die() probe: foreign non-abort exceptions oops\n");
	return 0;
}
EXPORT_SYMBOL(fki_fault_register);

void fki_fault_unregister(void)
{
	if (!fki_fault_registered)
		return;
	unregister_kprobe(&fki_fault_kp);
	if (fki_die_registered) {
		unregister_kprobe(&fki_die_kp);
		fki_die_registered = 0;
		memset(&fki_die_kp, 0, sizeof(fki_die_kp));
		fki_die_kp.symbol_name = "die";
		fki_die_kp.pre_handler = fki_die_pre;
	}
	WRITE_ONCE(fki_fault_handler, NULL);
	fki_fault_registered = 0;
	/* a fresh kprobe struct for the next registration */
	memset(&fki_fault_kp, 0, sizeof(fki_fault_kp));
	fki_fault_kp.symbol_name = "__do_kernel_fault";
	fki_fault_kp.pre_handler = fki_fault_pre;
}
EXPORT_SYMBOL(fki_fault_unregister);

fki_u64 fki_phys_peek(fki_u64 pa)
{
	if (!pfn_valid(PHYS_PFN(pa)))
		return ~0ULL;
	return READ_ONCE(*(u64 *)phys_to_virt(pa & ~7ULL));
}
EXPORT_SYMBOL(fki_phys_peek);

/* ---- contiguous memory and the top foreign window ---- */

int fki_contig_alloc(unsigned long size, struct fki_region *r)
{
	unsigned long n = 1;
	struct page *pg;
	int err = fki_resolve();

	if (err)
		return err;
	/*
	 * Large blocks (a hosted kernel's DRAM, GBs) come from the CMA area when there is one: a long-running host
	 * fragments its memory with unmovable pages and alloc_contig_pages then fails. CMA blocks are 2 MiB aligned
	 * and sized to 2 MiB; a CMA block's handle has bit 0 set.
	 */
	if (size >= (64UL << 20) && p_cma_area && *p_cma_area && p_cma_alloc && p_cma_release) {
		unsigned long cnt = ALIGN(size, SZ_2M) >> PAGE_SHIFT;
		pg = p_cma_alloc(*p_cma_area, cnt, get_order(SZ_2M), true);
		if (pg) {
			r->va = page_address(pg);
			memset(r->va, 0, cnt << PAGE_SHIFT);
			r->pa = page_to_phys(pg);
			r->size = cnt << PAGE_SHIFT;
			r->handle = (void *)((unsigned long)pg | 1);
			return 0;
		}
	}
	if (!p_alloc_contig)
		return -ENOENT;
	while ((n << PAGE_SHIFT) < size)
		n <<= 1;
	pg = p_alloc_contig(n, GFP_KERNEL | __GFP_NOWARN, numa_node_id(), NULL);
	if (!pg)
		return -ENOMEM;
	r->va = page_address(pg);
	memset(r->va, 0, n << PAGE_SHIFT);
	r->pa = page_to_phys(pg);
	r->size = n << PAGE_SHIFT;
	r->handle = pg;
	return 0;
}
EXPORT_SYMBOL(fki_contig_alloc);

void fki_contig_free(struct fki_region *r)
{
	if ((unsigned long)r->handle & 1) {
		p_cma_release(*p_cma_area, (struct page *)((unsigned long)r->handle & ~1UL), r->size >> PAGE_SHIFT);
		return;
	}
	if (p_free_contig)
		p_free_contig(page_to_pfn((struct page *)r->handle), r->size >> PAGE_SHIFT);
}
EXPORT_SYMBOL(fki_contig_free);

int fki_window_l1(unsigned long va, unsigned long long **l1_va, fki_u64 *l1_pa)
{
	u64 ttbr1 = read_sysreg(ttbr1_el1) & GENMASK_ULL(47, 1);
	u64 *l0 = phys_to_virt(ttbr1 & ~0xfffULL);
	u64 e = READ_ONCE(l0[(va >> 39) & 511]);

	if ((e & 3) != 3)
		return -ENOENT;
	*l1_pa = e & GENMASK_ULL(47, 12);
	*l1_va = phys_to_virt(*l1_pa);
	return 0;
}
EXPORT_SYMBOL(fki_window_l1);

void fki_window_set(unsigned long long *slot, fki_u64 desc)
{
	WRITE_ONCE(*slot, desc);
	dsb(ishst);
	__tlbi(vmalle1is);
	dsb(ish);
	isb();
}
EXPORT_SYMBOL(fki_window_set);

/*
 * Letting Linux run (IRQs on, maybe a reschedule) from inside fki_enter() happens on whatever stack the foreign kernel
 * is on. Linux's exception entry takes a stack whose bit THREAD_SHIFT is set at sp for an overflow and panics, so
 * from a stack that is not this task's, the work runs on a stack of our own laid out like Linux's (the lower half of a
 * 2 * THREAD_SIZE aligned block, which the linear map gives an order-aligned page block).
 */
static void *fki_alt_stack[NR_CPUS];

asm(
"	.pushsection .text\n"
"	.type	fki_run_on_stack, %function\n"
"fki_run_on_stack:\n"
"	hint	#34\n"
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
void fki_run_on_stack(void (*fn)(void *), void *arg, void *top);	/* x0 = fn, x1 = arg, x2 = stack top */

static void fki_linux_runs(void (*fn)(void *), void *arg)
{
	unsigned long sp = current_stack_pointer;
	int cpu = smp_processor_id();

	if (on_task_stack(current, sp, 1)) {
		fn(arg);
		return;
	}
	if (!fki_alt_stack[cpu]) {
		struct page *pg = alloc_pages(GFP_ATOMIC, get_order(2 * THREAD_SIZE));
		if (!pg) {
			fn(arg);	/* no memory: take the chance */
			return;
		}
		fki_alt_stack[cpu] = page_address(pg);
	}
	fki_run_on_stack(fn, arg, (char *)fki_alt_stack[cpu] + THREAD_SIZE);
}

struct fki_idle_args { fki_u64 ns; };

static void fki_idle_body(void *p)
{
	struct fki_idle_args *a = p;
	ktime_t t = ns_to_ktime(a->ns);

	local_irq_enable();
	preempt_enable();
	set_current_state(TASK_UNINTERRUPTIBLE);
	schedule_hrtimeout_range(&t, 50000, HRTIMER_MODE_REL);
	preempt_disable();
	local_irq_disable();
}

static void fki_yield_body(void *p)
{
	local_irq_enable();
	preempt_enable();
	cond_resched();
	preempt_disable();
	local_irq_disable();
}

void fki_idle_until(fki_u64 counter_deadline, fki_u64 max_ns)
{
	u64 now = __arch_counter_get_cntvct(), freq = arch_timer_get_cntfrq(), ns;
	struct fki_idle_args a;

	if (counter_deadline <= now) {
		/* already due: still let Linux take its interrupts and reschedule (an idle loop that never sleeps starves it) */
		fki_linux_runs(fki_yield_body, NULL);
		return;
	}
	ns = div64_u64((counter_deadline - now) * 1000000ULL, freq) * 1000ULL;
	if (ns > max_ns)
		ns = max_ns;
	a.ns = ns;
	fki_linux_runs(fki_idle_body, &a);
}
EXPORT_SYMBOL(fki_idle_until);

void fki_yield(void)
{
	fki_linux_runs(fki_yield_body, NULL);
}
EXPORT_SYMBOL(fki_yield);

void fki_realtime(fki_u64 *sec, fki_u64 *nsec)
{
	struct timespec64 ts;

	ktime_get_real_ts64(&ts);
	*sec = ts.tv_sec;
	*nsec = ts.tv_nsec;
}
EXPORT_SYMBOL(fki_realtime);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Foreign kernel interface v0 (out-of-tree form for stock kernels)");

void *fki_file_open(const char *path, int writable, fki_u64 *size)
{
	struct file *f = filp_open(path, (writable ? O_RDWR : O_RDONLY) | O_LARGEFILE, 0);

	if (IS_ERR(f))
		return NULL;
	if (size)	/* the mapping's host: a block device's own size (a device node's inode says 0) */
		*size = i_size_read(f->f_mapping->host);
	return f;
}
EXPORT_SYMBOL(fki_file_open);

#define FKI_FILE_CHUNK (256UL << 10)

static long fki_file_rw_body(void *file, int write, void *buf, unsigned long len, fki_u64 off);
struct fki_file_args { void *file; int write; void *buf; unsigned long len; fki_u64 off; long ret; };
static void fki_file_rw_thunk(void *p)
{
	struct fki_file_args *a = p;
	a->ret = fki_file_rw_body(a->file, a->write, a->buf, a->len, a->off);
}

long fki_file_rw(void *file, int write, void *buf, unsigned long len, fki_u64 off)
{
	struct fki_file_args a = { file, write, buf, len, off, -EIO };

	if (!file)
		return -EBADF;
	fki_linux_runs(fki_file_rw_thunk, &a);
	return a.ret;
}
EXPORT_SYMBOL(fki_file_rw);

static long fki_file_rw_body(void *file, int write, void *buf, unsigned long len, fki_u64 off)
{
	struct file *f = file;
	unsigned long done = 0;
	long ret = 0;
	void *bounce;

	local_irq_enable();
	preempt_enable();
	bounce = kvmalloc(min(len, FKI_FILE_CHUNK), GFP_KERNEL);
	if (!bounce)
		ret = -ENOMEM;
	while (bounce && done < len) {
		unsigned long n = min(len - done, FKI_FILE_CHUNK);
		loff_t pos = off + done;
		ssize_t r;

		if (write) {
			preempt_disable(); local_irq_disable();
			memcpy(bounce, (char *)buf + done, n);
			local_irq_enable(); preempt_enable();
			r = kernel_write(f, bounce, n, &pos);
		} else {
			r = kernel_read(f, bounce, n, &pos);
			if (r > 0) {
				preempt_disable(); local_irq_disable();
				memcpy((char *)buf + done, bounce, r);
				local_irq_enable(); preempt_enable();
			}
		}
		if (r < 0) {
			ret = r;
			break;
		}
		done += r;
		if ((unsigned long)r < n)
			break;
	}
	kvfree(bounce);
	preempt_disable();
	local_irq_disable();
	return ret < 0 && !done ? ret : (long)done;
}


void fki_file_close(void *file)
{
	if (file)
		filp_close(file, NULL);
}
EXPORT_SYMBOL(fki_file_close);
