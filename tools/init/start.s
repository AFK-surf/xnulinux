// A minimal static arm64 Mach-O for /sbin/launchd on a test root: exit(42) through the BSD syscall trap.
	.text
	.globl	_start
	.p2align 2
_start:
	mov	x0, #42
	mov	x16, #1		// SYS_exit
	svc	#0x80
1:	b	1b
