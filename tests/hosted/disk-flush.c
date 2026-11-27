// SPDX-License-Identifier: GPL-2.0-only
// A flush the hosted system asks of its disk reaches the Linux file behind it (kexts/XnuDisk doSynchronize ->
// LINUX64_CALL_DISK_SYNC -> fki_file_sync). This is /sbin/launchd for an otherwise empty root, as tools/init's start.s:
// static, BSD system calls through svc #0x80 only. It writes a block to the root partition's raw device and asks the
// disk to flush (DKIOCSYNCHRONIZE: what F_FULLFSYNC and a file system's barriers come down to), five times, says on the
// console what each call returned, and exits, which ends the run. Meanwhile, on the Linux side, count the fsyncs:
//
//   ~/w/dvm/toolchains/linux/bin26/target-clang -target arm64-apple-macos14.0 -O1 -ffreestanding -fno-builtin \
//     -fno-stack-protector -nostdlib -static -e _start -Wl,-adhoc_codesign disk-flush.c -o launchd
//   an HFS+ disk whose root has /dev (a directory) and /sbin/launchd (this), booted with scripts/xnulinux-boot.sh
//   cd /sys/kernel/tracing; echo vfs_fsync > set_ftrace_filter; echo function > current_tracer   (then read trace)
//
// Expected: five "DKIOCSYNCHRONIZE = 0" on the console and at least five vfs_fsync calls by the task that runs the
// hosted kernel (insmod); none with xnu.ko's disk_sync=0, and none (and one "unknown call from XNU" line) with an xnu.ko
// from before the call.
typedef unsigned long u64;
typedef long i64;
typedef unsigned char u8;

static i64 sc(u64 n, u64 a, u64 b, u64 c, u64 d)	/* a failed call: carry set and errno in x0; here -errno */
{
	register u64 x16 __asm__("x16") = n, x0 __asm__("x0") = a, x1 __asm__("x1") = b, x2 __asm__("x2") = c, x3 __asm__("x3") = d;
	u64 failed;

	__asm__ volatile ("svc #0x80\n\tcset %[f], cs" : "+r"(x0), "+r"(x1), [f] "=r"(failed) : "r"(x16), "r"(x2), "r"(x3) : "memory", "cc");
	return failed ? -(i64)x0 : (i64)x0;
}

static i64 con;
static void say(const char *s) { u64 n = 0; while (s[n]) n++; sc(4, con, (u64)s, n, 0); }
static void num(const char *what, i64 v)
{
	char b[24];
	int i = 22, neg = v < 0;
	u64 u = neg ? -v : v;

	b[22] = '\n';
	do { b[--i] = '0' + u % 10; u /= 10; } while (u);
	if (neg) b[--i] = '-';
	say(what);
	sc(4, con, (u64)(b + i), 23 - i, 0);
}

static u8 block[4096] __attribute__((aligned(4096)));

void cmain(void) __asm__("_cmain");
void cmain(void)
{
	u64 req[3];
	i64 fd;

	con = sc(5, (u64)"/dev/console", 2, 0, 0);
	say("disk-flush: start\n");
	fd = sc(5, (u64)"/dev/rdisk0s1", 2, 0, 0);			/* O_RDWR */
	num("disk-flush: open /dev/rdisk0s1 read-write = ", fd);
	for (int i = 0; i < 4096; i++) block[i] = (u8)(i * 7 + 1);
	for (int round = 0; round < 5; round++) {
		num("disk-flush: pwrite of 4096 bytes = ", sc(154, fd, (u64)block, 4096, (128ul << 20) + round * 4096ul));
		req[0] = req[1] = req[2] = 0;
		num("disk-flush: DKIOCSYNCHRONIZE = ", sc(54, fd, 0x80186416ul, (u64)req, 0));
	}
	say("disk-flush: done\n");
	sc(1, 0, 0, 0, 0);
	for (;;) {}
}

__attribute__((naked)) void start(void) __asm__("_start");
void start(void)
{
	__asm__("mov x9, sp\n\tand sp, x9, #~15\n\tbl _cmain");	/* the kernel hands over an sp that is only 8-aligned */
}
