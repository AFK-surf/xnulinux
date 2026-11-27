// SPDX-License-Identifier: APSL-2.0
/*
 * xnu.ko's loader in user space: xnu_main.c, macho.c and adt.c as they are, loading images this test makes, as insmod
 * with the same parameters would. run.sh builds it with AddressSanitizer and runs it.
 *
 * In place of the rest of the kernel: linux/module.h (next to this file) for <linux/module.h>; below, the fki_*
 * functions (fki_region_alloc is calloc of the page-rounded size, so a write past the region is reported where the
 * kernel has the guard page after a vmalloc area; a firmware file is a copy of exactly the image's size) and world.S
 * (XNU is not run: entering it comes back as if its first call into the host were a halt).
 * The three files' inline AArch64 statements (system registers, PAC, cache maintenance, the stop state's
 * compare-and-swap) are compiled out and what they would have set reads as 0, so the test runs on any host; nothing it
 * checks depends on them.
 *
 * A case is one insmod, in a process of its own: the module's state is static, and a bad access ends the process.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define __asm__
#define asm
#define volatile(...)		/* of `__asm__ volatile(...)`: the qualifier is never followed by a parenthesis */
#define target(...) unused	/* __attribute__((target("branch-protection=none"))) is AArch64's */
#include "../xnu_main.c"
#include "../macho.c"
#include "../adt.c"

/* ---- the host (fki.h) ---- */
static struct { const char *name; const void *data; unsigned long size; } firmware[2];
static int held;			/* regions and firmware files the module has and has not given back */
static char last_log[200], cc_sha[65];

void test_bug(void) { printf("BUG()\n"); abort(); }
int fki_version(void) { return FKI_VERSION; }
unsigned long fki_caps(void) { return FKI_CAP_EXEC_ONLY | FKI_CAP_PAC; }	/* fki_arm64.c's */
void fki_log(const char *s, unsigned long len)
{
	static const char sha[] = "xnu: EL0 corecrypto unpatched sha256: ";

	printf("fki: %.*s\n", (int)len, s);
	snprintf(last_log, sizeof(last_log), "%.*s", (int)len, s);
	if (len >= sizeof(sha) - 1 + 64 && !memcmp(s, sha, sizeof(sha) - 1))
		snprintf(cc_sha, sizeof(cc_sha), "%.64s", s + sizeof(sha) - 1);
}
void fki_log_alert(const char *s, unsigned long len) { fki_log(s, len); }
int fki_region_alloc(unsigned long size, struct fki_region *r)
{
	unsigned long n = (size + 4095) & ~4095UL;	/* fki_arm64.c: vzalloc of PAGE_ALIGN(size) */

	if (n < size || n > 1UL << 30 || !(r->va = calloc(1, n))) return -12;	/* 1 GB: all a test's host has */
	r->pa = 0x100000000ULL; r->size = n; r->handle = 0; held++;
	return 0;
}
void fki_region_free(struct fki_region *r) { free(r->va); held--; }
int fki_blob_get(const char *name, const void **data, unsigned long *size, void **handle)
{
	for (unsigned i = 0; i < 2; i++)
		if (firmware[i].name && !strcmp(firmware[i].name, name)) {
			*data = *handle = memcpy(malloc(firmware[i].size), firmware[i].data, firmware[i].size);
			*size = firmware[i].size; held++;
			return 0;
		}
	return -2;
}
void fki_blob_put(void *handle) { free(handle); held--; }
unsigned long fki_enter(const struct fki_pac_keys *foreign, struct fki_pac_keys *saved) { return 0; }
void fki_leave(unsigned long cookie, const struct fki_pac_keys *saved) {}
int fki_pac_swap(const struct fki_pac_keys *load, struct fki_pac_keys *save) { return 0; }
fki_u64 fki_counter_frequency(void) { return 24000000; }
fki_u64 fki_counter(void) { static fki_u64 c; return c += 1000; }
void fki_random(void *buf, unsigned long len) { memset(buf, 0x5a, len); }
int fki_random_wait(void) { return 0; }
void fki_realtime(fki_u64 *sec, fki_u64 *nsec) { *sec = *nsec = 0; }
int fki_bind_cpu(int cpu) { return 0; }
int fki_num_cpus(void) { return 4; }
int fki_cpu_mpidr(int cpu, fki_u64 *mpidr) { *mpidr = cpu; return 0; }	/* its slot: the CPU's number */
void fki_kick_cpu(int cpu) {}
void fki_idle_until(fki_u64 deadline, fki_u64 max_ns, const volatile unsigned int *wake) {}
void fki_yield(void) {}
void fki_msleep(unsigned int ms) {}
void fki_icache_flush(unsigned long va, unsigned long size) {}
int fki_fault_register(unsigned long lo, unsigned long hi, int (*h)(unsigned long, unsigned long, void *)) { return 0; }
void fki_fault_unregister(void) {}
unsigned long fki_regs_pc(void *regs) { return 0; }
unsigned long fki_regs_lr(void *regs) { return 0; }
unsigned long fki_regs_pstate(void *regs) { return 0; }
unsigned long fki_regs_reg(void *regs, unsigned int n) { return 0; }
void fki_regs_set_pc(void *regs, unsigned long pc) {}
void fki_regs_set_reg(void *regs, unsigned int n, unsigned long v) {}
/* no helper threads, host files, network or host calls in a test; the rest as fki_arm64.c answers for an EL0 host's calls */
void *fki_thread_start(int (*fn)(void *), void *arg, int cpu, const char *name) { return 0; }
void fki_thread_stop(void *thread) {}
int fki_thread_should_stop(void) { return 1; }
void fki_thread_wait(const volatile unsigned long *flag) {}
void fki_thread_wake(void *thread) {}
void *fki_file_open(const char *path, int writable, fki_u64 *size) { return 0; }
long fki_file_rw(void *file, int write, void *buf, unsigned long len, fki_u64 off) { return -9; }
long fki_file_pwrite(void *file, const void *buf, unsigned long len, fki_u64 off) { return -9; }
void fki_file_close(void *file) {}
long fki_net_send(const void *frame, unsigned long len) { return -19; }
long fki_net_recv(void *buf, unsigned long len) { return 0; }
long fki_hostcall(const void *req, unsigned long len, void *reply, unsigned long max) { return -19; }
int fki_contig_alloc(unsigned long size, struct fki_region *r) { return -95; }
void fki_contig_free(struct fki_region *r) {}
int fki_window_l1(unsigned long va, unsigned long long **l1_va, fki_u64 *l1_pa) { return -95; }
void fki_window_set(unsigned long long *slot, fki_u64 desc) {}
int fki_kmem_alloc(unsigned long size, unsigned long high_va, fki_u64 pa_base, struct fki_region *r) { return -95; }
int fki_kmem_alias(struct fki_region *r, unsigned long va, unsigned long size) { return -95; }
void fki_kmem_free(struct fki_region *r) {}
int fki_high_map(unsigned long va, fki_u64 xpa, unsigned long size, int prot) { return -95; }
void fki_high_unmap(unsigned long va, unsigned long size) {}
void fki_high_flush(void) {}
int fki_high_txn_begin(unsigned long va, unsigned long size, void **handle_out) { *handle_out = 0; return -95; }
void fki_high_txn_restore(void *txn) {}
void fki_high_txn_end(void *txn) {}
int fki_high_read_u64x2(unsigned long va, fki_u64 *out0, fki_u64 *out1) { return -14; }
void *fki_as_create(void) { return 0; }
void fki_as_destroy(void *as) {}
int fki_as_map(void *as, unsigned long va, fki_u64 xpa, unsigned long size, int prot) { return -95; }
void fki_as_unmap(void *as, unsigned long va, unsigned long size) {}
void fki_as_flush(void *as) {}
void *fki_utcb_create(void *as) { return 0; }
void fki_utcb_destroy(void *utcb) {}
int fki_utcb_set_as(void *utcb, void *as) { return -95; }
int fki_utcb_set_pac(void *utcb, const struct fki_pac_keys *keys) { return -95; }
int fki_utcb_run(void *utcb, struct fki_utcb_regs *regs, struct fki_utcb_stop *stop) { return -95; }
int fki_utcb_resume(void *utcb, struct fki_utcb_regs *regs, struct fki_utcb_stop *stop) { return -38; }
int fki_utcb_sync_regs(void *utcb, struct fki_utcb_regs *regs) { return -38; }
int fki_utcb_fpu_read(void *utcb, void *buf, unsigned long len) { return -95; }
int fki_utcb_fpu_write(void *utcb, const void *buf, unsigned long len) { return -95; }

/* ---- world.S ---- */
long xnu_world_call(unsigned long fn, unsigned long arg)
{
	stop_state |= STOP_COMMIT;	/* a call that ends the run commits the stop: by the compare-and-swap, here */
	return xnu_hook(LINUX64_CALL_HALT, 0, 0);
}
long xnu_world_call_el0(unsigned long fn, unsigned long arg) { return xnu_world_call(fn, arg); }
void xnu_world_upcall(void) {}
void xnu_world_upcall_el0(void) {}
void xnu_world_fault_abort(void) {}
void xnu_fault_tramp(void) {}

/* ---- images: file offset = address - KV ---- */
#define KV 0xfffffff007004000ULL	/* where a kernel is linked */
#define PG 0x4000UL
static unsigned char file[6 * PG];	/* the image being made */
static struct mh64 *mh;			/* its Mach-O header being filled, and where that header's next load command goes */
static unsigned char *lc;
static struct symtab_lc *st;

static void header(unsigned long off, u32_t filetype)
{
	mh = (void *)(file + off); lc = (void *)(mh + 1);
	mh->magic = MH_MAGIC_64; mh->cputype = 0x0100000c; mh->filetype = filetype;
}
static void *cmd(u32_t c, u32_t size)
{
	struct lc *l = (void *)lc;

	l->cmd = c; l->cmdsize = size; lc += size; mh->ncmds++; mh->sizeofcmds += size;
	return l;
}
static struct seg64 *seg(const char *name, unsigned long off, unsigned long size, u32_t prot)
{
	struct seg64 *s = cmd(LC_SEGMENT_64, sizeof(*s));

	strncpy(s->segname, name, 16); s->vmaddr = KV + off; s->vmsize = s->filesize = size; s->fileoff = off;
	s->maxprot = s->initprot = prot;
	return s;
}
static void sect(struct seg64 *s, const char *name, u64_t addr, u64_t size, u32_t flags)	/* right after its segment */
{
	struct sect64 *c = (void *)lc;

	strncpy(c->sectname, name, 16); memcpy(c->segname, s->segname, 16); c->addr = addr; c->size = size; c->flags = flags;
	lc += sizeof(*c); s->cmdsize += sizeof(*c); s->nsects++; mh->sizeofcmds += sizeof(*c);
}
static void entry(const char *id, unsigned long off)
{
	struct fileset_entry_lc *e = cmd(LC_FILESET_ENTRY, sizeof(*e) + 32);

	e->vmaddr = KV + off; e->fileoff = off; e->entry_id = sizeof(*e); strcpy((char *)(e + 1), id);
}
static void symtab(unsigned long off)	/* the symbols at off, their names 1 KB later */
{
	st = cmd(LC_SYMTAB, sizeof(*st)); st->symoff = off; st->stroff = off + 0x400; st->strsize = 1;
}
static void sym(const char *name, u64_t value)
{
	struct nlist64 *n = (struct nlist64 *)(file + st->symoff) + st->nsyms++;

	n->n_strx = st->strsize; n->n_type = 0x0f; n->n_sect = 1; n->n_value = value;	/* N_SECT | N_EXT */
	strcpy((char *)file + st->stroff + st->strsize, name); st->strsize += strlen(name) + 1;
}

/*
 * A bare kernel as xnu.ko boots one in mode 2: __TEXT (the header, __thread_starts at ts_addr, code), __DATA (the
 * linux64_* variables, and three pointers to rebase: a chain of two, and one in the image's last 8 bytes) and its symbols.
 * fixup: the first threaded fixup's offset. Installed as the default image.
 */
#define FIXUP (2 * PG + 0x100)
#define TARGET (KV + PG)
static void kernel(u64_t ts_addr, u32_t fixup)
{
	const u64_t ptr = 0xffULL << 43 | (TARGET & 0x7ffffffffffULL);	/* a rebase of TARGET, the chain's last */
	const u32_t ts[4] = { 0, fixup, 3 * PG - 8, 0xffffffff };	/* 4-byte stride; the fixups; the end */
	struct seg64 *text;

	header(0, 2);	/* MH_EXECUTE */
	text = seg("__TEXT", 0, 2 * PG, 5);
	sect(text, "__text", KV + PG, PG, S_ATTR_PURE_INSTRUCTIONS);
	sect(text, "__thread_starts", ts_addr, sizeof(ts), 0);
	seg("__DATA", 2 * PG, PG, 3);
	symtab(3 * PG);
	sym("_arm_init", TARGET);
	sym("_linux64_abi_version", KV + PG + 0x100);
	sym("_linux64_hook", KV + 2 * PG);
	sym("_linux64_slide", KV + 2 * PG + 8);
	sym("_linux64_host_abi_version", KV + 2 * PG + 16);
	memcpy(file + 0x1000, ts, sizeof(ts));
	*(u32_t *)(file + PG + 0x100) = LINUX64_ABI_VERSION;
	*(u64_t *)(file + FIXUP) = ptr | 2ULL << 51;	/* the next one two strides on */
	*(u64_t *)(file + FIXUP + 8) = *(u64_t *)(file + 3 * PG - 8) = ptr;
	firmware[0].name = image; firmware[0].data = file; firmware[0].size = st->stroff + st->strsize;
}

/*
 * A kernel collection: the kernel's entry (only its symbol table matters here) and com.apple.kec.corecrypto's, whose
 * text reads an ID register three times. Returns the file's size.
 */
static unsigned long collection(void)
{
	header(0, MH_FILESET);
	seg("__TEXT", 0, 3 * PG, 5);
	seg("__TEXT_EXEC", 3 * PG, PG, 5);
	entry("com.apple.kernel", PG);
	entry("com.apple.kec.corecrypto", 2 * PG);
	header(2 * PG, 11);	/* MH_KEXT_BUNDLE */
	sect(seg("__TEXT_EXEC", 3 * PG, PG, 5), "__text", KV + 3 * PG, PG, S_ATTR_PURE_INSTRUCTIONS);
	for (int i = 0; i < 3; i++)
		*(u32_t *)(file + 3 * PG + 16 + 4 * i) = 0xd5380600 + i;	/* mrs x<i>, ID_AA64ISAR0_EL1 */
	header(PG, 2);
	symtab(4 * PG);
	sym("_arm_init", KV + 3 * PG);
	return st->stroff + st->strsize;
}

/* ---- the cases ---- */

/* insmod: xnu_init() returns `want`; then, unloaded again (or the load having failed), the module holds nothing */
static int insmod(int want, int (*loaded)(void))
{
	int err = xnu_init(), bad = err != want;

	if (bad) printf("test: xnu_init returned %d, not %d\n", err, want);
	if (!err && loaded) bad |= loaded();
	if (!err) xnu_exit();
	if (held) { printf("test: %d regions or firmware files still held\n", held); bad = 1; }
	return bad;
}

static int rebased(void)
{
	const u64_t *d = (const u64_t *)((const char *)img.region.va + FIXUP), want = TARGET + img.slide;
	int bad = d[0] != want || d[1] != want || d[(PG - 0x100) / 8 - 1] != want;

	if (bad) printf("test: the three pointers are not TARGET's address in the region\n");
	return bad;
}
static int c_defaults(void) { kernel(KV + 0x1000, FIXUP); return insmod(0, rebased); }

/* The boot data build_boot puts after the image (boot args, device tree, RAM disk, trust cache, framebuffer) is in the region */
static int c_ram4(void) { kernel(KV + 0x1000, FIXUP); ram_mb = 4; return insmod(0, 0); }	/* 4 MB of framebuffer by default */
static int c_ramdisk(void)
{
	kernel(KV + 0x1000, FIXUP);
	ramdisk = "rd"; firmware[1].name = ramdisk; firmware[1].size = 9 << 20; firmware[1].data = calloc(1, 9 << 20);
	ram_mb = 8; fb_width = 0;
	return insmod(0, 0);
}
static int c_mode0(void) { kernel(KV + 0x1000, FIXUP); mode = 0; return insmod(0, 0); }
static int c_wrap(void)		/* 16 EiB of framebuffer and 16 GiB of RAM: the sum is 400 KB */
{
	kernel(KV + 0x1000, FIXUP); fb_width = fb_height = 0x7fffffff; ram_mb = 16384;
	return insmod(-22, 0);
}

/* A bare kernel's threaded fixups stay inside the image: -ENOEXEC otherwise */
static int c_fixup(void)	/* at the region's end: the image, the boot data's room, 1 MB */
{
	kernel(KV + 0x1000, 3 * PG + 0x60000 + (1 << 20)); ram_mb = 1; fb_width = 0;
	return insmod(-8, 0);
}
static int c_starts(void) { kernel(0x4141414141414000ULL, FIXUP); return insmod(-8, 0); }

/* The load commands slid are the loaded ones, at the address a __TEXT of file offset 0 names: inside the image as well */
static int c_overlap(void)	/* a segment laid over __TEXT's command in memory gives it 4 billion sections */
{
	struct seg64 *s;

	kernel(KV + 0x1000, FIXUP);
	s = seg("__OVER", 2 * PG + 0x200, 4, 1);
	s->vmaddr = KV + sizeof(struct mh64) + __builtin_offsetof(struct seg64, nsects);
	*(u32_t *)(file + 2 * PG + 0x200) = 0xffffffff;
	return insmod(-8, 0);
}
static int c_header(void)	/* a second, empty __TEXT: the header's address is its, anywhere (and no fixup to refuse first) */
{
	kernel(KV + 0x1000, 0xffffffff);
	seg("__TEXT", 0, 0, 5)->vmaddr = 0x4141414141414000ULL;
	return insmod(-8, 0);
}

/*
 * What an EL0 host's load does to a collection (el0_patch_image) whose corecrypto does not have the two ID register
 * reads it expects, loaded a second time with el0_fips_sha256 set to the digest the first load logged: the line that
 * says why the integrity check stays. (Mode 3 itself needs the kernel's addresses: the image is parsed and placed
 * here, as run_m2b_el0 does it.)
 */
static int c_fips(void)
{
	unsigned long n = collection();
	void *at;

	if (macho_load(&img, memcpy(malloc(n), file, n), n, ~0UL)) return 1;
	at = calloc(1, img.vmhigh - img.vmlow);
	img.slide = (u64_t)at - img.vmlow;
	for (int load = 0; load < 2; load++) {
		if (macho_copy(&img, at)) return 1;
		el0_patch_image(&img);
		el0_fips_sha256 = cc_sha;
	}
	return strcmp(last_log, "xnu: preserving _fipspost_post_integrity (unexpected corecrypto ubsan patches) 0x0000000000000000") != 0;
}
static int c_logkv(void)	/* a key longer than the line is cut: 108 characters of it, then the value */
{
	char key[200];

	memset(key, 'k', sizeof(key) - 1); key[sizeof(key) - 1] = 0;
	logkv(key, 1);
	return strlen(last_log) != 108 + 3 + 16;
}

static const struct { const char *what; int (*run)(void); } cases[] = {
	{ "mode 2 with the defaults: a bare kernel loads, its threaded fixups applied", c_defaults },
	{ "mode 2, ram_mb=4: the framebuffer is inside the region", c_ram4 },
	{ "mode 2, ram_mb=8 and a 9 MiB RAM disk: the RAM disk is inside the region", c_ramdisk },
	{ "mode 0 (every mode but 1 and 3 boots as 2 does): the boot data is inside the region", c_mode0 },
	{ "boot data and RAM whose sizes wrap are refused", c_wrap },
	{ "a threaded fixup past the image is refused", c_fixup },
	{ "a __thread_starts section outside the image is refused", c_starts },
	{ "load commands that a segment laid over them changed are not slid", c_overlap },
	{ "a Mach-O header outside the image is refused", c_header },
	{ "EL0 host: the log line for corecrypto patches that are not the expected two", c_fips },
	{ "a log key longer than the line is cut", c_logkv },
};

int main(void)
{
	unsigned failed = 0;

	for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
		FILE *out = tmpfile();	/* the case's log, shown when it fails */
		int status = 1, c;
		pid_t pid;

		fflush(stdout);
		if (!out || (pid = fork()) < 0) { perror("test"); return 2; }
		if (!pid) {
			dup2(fileno(out), 1); dup2(fileno(out), 2);
			status = cases[i].run();
			fflush(stdout);
			_exit(status);
		}
		waitpid(pid, &status, 0);
		printf("%s %u - %s\n", status ? "not ok" : "ok", i + 1, cases[i].what);
		if (status) {
			failed++;
			for (rewind(out); (c = getc(out)) != EOF;) putchar(c);
		}
		fclose(out);
	}
	if (failed) printf("xnu.ko loader: %u of %u cases FAILED\n", failed, (unsigned)(sizeof(cases) / sizeof(cases[0])));
	else printf("xnu.ko loader: pass\n");
	return failed != 0;
}
