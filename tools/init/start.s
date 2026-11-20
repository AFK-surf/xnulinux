// A minimal static arm64 Mach-O for /sbin/launchd on a test root, BSD syscalls through svc #0x80 only:
// open("/dev/console", O_WRONLY), write a line, fork; the child writes its own line and exits 7,
// the child then execve()s /sbin/hello (which writes its line and exits 7); the parent wait4()s for it, writes a closing line and exits 42.
// Darwin reports a failed syscall with the carry flag set and errno in x0. Exit codes on failure:
// open 64+errno, write 128+errno, short write 3, fork 4, wait4 5, child status not 7 6 (8: execve failed, 9: /sbin/hello failed).
	.text
	.globl	_start
	.p2align 2
_start:
	mov	x9, sp			// the kernel hands over sp at the Mach-O stack's argc slot (8-aligned); EL0 checks SP alignment
	and	sp, x9, #~15
	adr	x0, Lpath
	mov	x1, #1			// O_WRONLY
	mov	x2, #0
	mov	x16, #5			// SYS_open
	svc	#0x80
	b.cs	Lopen_failed
	mov	x19, x0			// fd
	adr	x1, Lmsg
	mov	x2, #(Lmsg_end - Lmsg)
	bl	Lwrite
	mov	x16, #2			// SYS_fork: parent x0 = child pid, x1 = 0; child x1 = 1
	svc	#0x80
	b.cs	Lfork_failed
	cbnz	x1, Lchild
	mov	x20, x0			// child pid
	sub	sp, sp, #16
	mov	x0, x20
	mov	x1, sp			// &status
	mov	x2, #0
	mov	x3, #0
	mov	x16, #7			// SYS_wait4
	svc	#0x80
	b.cs	Lwait_failed
	ldr	w0, [sp]
	lsr	w0, w0, #8		// WEXITSTATUS
	and	w0, w0, #0xff
	cmp	w0, #7
	b.ne	Lbad_status
	adr	x1, Lmsg3
	mov	x2, #(Lmsg3_end - Lmsg3)
	bl	Lwrite
	mov	x0, #42
Lexit:
	mov	x16, #1			// SYS_exit
	svc	#0x80
1:	b	1b
Lchild:
	adr	x1, Lmsg2
	mov	x2, #(Lmsg2_end - Lmsg2)
	bl	Lwrite
	adr	x0, Lhello		// execve("/sbin/hello", {"/sbin/hello", NULL}, {NULL}); /sbin/hello exits 7
	stp	x0, xzr, [sp, #-16]!
	mov	x1, sp
	add	x2, sp, #8
	mov	x16, #59		// SYS_execve
	svc	#0x80
	mov	x0, #8			// execve returned: failed
	b	Lexit
// write(x19, x1, x2), exits on failure
Lwrite:
	mov	x21, x2
	mov	x0, x19
	mov	x16, #4			// SYS_write
	svc	#0x80
	b.cs	Lwrite_failed
	cmp	x0, x21
	b.ne	Lshort
	ret
Lopen_failed:
	add	x0, x0, #64
	b	Lexit
Lwrite_failed:
	add	x0, x0, #128
	b	Lexit
Lshort:
	mov	x0, #3
	b	Lexit
Lfork_failed:
	mov	x0, #4
	b	Lexit
Lwait_failed:
	mov	x0, #5
	b	Lexit
Lbad_status:
	mov	x0, #6
	b	Lexit
Lpath:
	.asciz	"/dev/console"
Lmsg:
	.ascii	"hello from Darwin user space on Linux (pid 1, /sbin/launchd)\n"
Lmsg_end:
Lmsg2:
	.ascii	"hello from the forked child\n"
Lmsg2_end:
Lhello:
	.asciz	"/sbin/hello"
Lmsg3:
	.ascii	"parent: child exited with 7\n"
Lmsg3_end:
