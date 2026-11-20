// A minimal static arm64 Mach-O for /sbin/launchd on a test root, BSD syscalls through svc #0x80 only:
// open("/dev/console", O_WRONLY), write a line to it, exit(42).
// Darwin reports a failed syscall with the carry flag set and errno in x0: open failing exits 64+errno,
// write failing exits 128+errno, a short write exits 3.
	.text
	.globl	_start
	.p2align 2
_start:
	adr	x0, Lpath
	mov	x1, #1			// O_WRONLY
	mov	x2, #0
	mov	x16, #5			// SYS_open
	svc	#0x80
	b.cs	Lopen_failed
	mov	x19, x0			// fd
	mov	x0, x19
	adr	x1, Lmsg
	mov	x2, #(Lmsg_end - Lmsg)
	mov	x16, #4			// SYS_write
	svc	#0x80
	b.cs	Lwrite_failed
	cmp	x0, #(Lmsg_end - Lmsg)
	b.ne	Lshort
	mov	x0, #42
Lexit:
	mov	x16, #1			// SYS_exit
	svc	#0x80
1:	b	1b
Lopen_failed:
	add	x0, x0, #64
	b	Lexit
Lwrite_failed:
	add	x0, x0, #128
	b	Lexit
Lshort:
	mov	x0, #3
	b	Lexit
Lpath:
	.asciz	"/dev/console"
Lmsg:
	.ascii	"hello from Darwin user space on Linux (pid 1, /sbin/launchd)\n"
Lmsg_end:
