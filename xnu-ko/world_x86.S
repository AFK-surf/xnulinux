// SPDX-License-Identifier: APSL-2.0
/*
 * x86_64 world switch for hosted XNU.
 *
 * XNU owns IDT/GDT/TSS, CR3 and %gs (cpu_data) while it runs. Linux's copies are saved
 * in struct xnu_world on entry and restored before every upcall, because Linux reads
 * `current` through %gs and its kernel #PF path must never see XNU's descriptors.
 * The save-area offsets below mirror world.h (checked with _Static_assert there).
 *
 * No CR3 handoff: XNU uses its own page tables. The host only maps the image temporarily
 * to copy it into place and to give vstart a boot-args address.
 */
#include <linux/linkage.h>
#include <asm/linkage.h>
#include <asm/unwind_hints.h>

#define W_RBX 0
#define W_RBP 8
#define W_R12 16
#define W_R13 24
#define W_R14 32
#define W_R15 40
#define W_RSP 48
#define W_LGS 56
#define W_LKGS 64
#define W_LCR3 72
#define W_LIDT 80
#define W_LGDT 96
#define W_LTR 112
#define W_FLAGS 120
#define W_KEYS 128
#define W_XRBX 216
#define W_XRBP 224
#define W_XR12 232
#define W_XR13 240
#define W_XR14 248
#define W_XR15 256
#define W_XRSP 264
#define W_XGS 272
#define W_XKGS 280
#define W_XCR3 288
#define W_XIDT 304
#define W_XGDT 320
#define W_XTR 336

#define MSR_GS_BASE 0xc0000101
#define MSR_KERNEL_GS_BASE 0xc0000102

/* Read an MSR into %r9 (clobbers %rax/%rdx/%rcx). */
.macro rdmsr_r9 msr
	movl	$\msr, %ecx
	rdmsr
	shlq	$32, %rdx
	orq	%rdx, %r9
.endm

/* Write %r9 to an MSR (clobbers %rax/%rdx/%rcx, preserves %r9). */
.macro wrmsr_r9 msr
	movl	$\msr, %ecx
	movq	%r9, %rax
	movq	%r9, %rdx
	shrq	$32, %rdx
	wrmsr
.endm

/*
 * Restore all Linux state and return to the caller of xnu_world_switch_in. r8 = this
 * CPU's save area, r12 = result. Expanded inside each function so objtool sees a real
 * return in each and never mistakes a world switch for a noreturn function.
 */
.macro WORLD_EXIT
	movq	W_LCR3(%r8), %r9
	movq	%r9, %cr3
	lidt	W_LIDT(%r8)
	lgdt	W_LGDT(%r8)
	movzwl	W_LTR(%r8), %eax
	ltr	%ax
	movq	W_LGS(%r8), %r9
	wrmsr_r9 MSR_GS_BASE
	movq	W_LKGS(%r8), %r9
	wrmsr_r9 MSR_KERNEL_GS_BASE
	movq	W_FLAGS(%r8), %rdi
	leaq	W_KEYS(%r8), %rsi
	movq	%r12, W_FLAGS(%r8)	/* stash result across fki_leave */
	call	fki_leave
	movq	W_RSP(%r8), %rsp
	addq	$24, %rsp
	movq	W_RBX(%r8), %rbx
	movq	W_RBP(%r8), %rbp
	movq	W_R12(%r8), %r12
	movq	W_R13(%r8), %r13
	movq	W_R14(%r8), %r14
	movq	W_R15(%r8), %r15
	movq	W_FLAGS(%r8), %rax	/* the stashed result */
	popq	%r15
	popq	%r14
	popq	%r13
	popq	%r12
	popq	%rbx
	popq	%rbp
	RET
.endm

/*
 * xnu_world_switch_in(w, fn, arg): %rdi = w, %rsi = fn, %rdx = arg.
 */
SYM_FUNC_START(xnu_world_switch_in)
	ENDBR
	pushq	%rbp
	pushq	%rbx
	pushq	%r12
	pushq	%r13
	pushq	%r14
	pushq	%r15
	subq	$24, %rsp
	movq	%rdi, 0(%rsp)
	movq	%rsi, 8(%rsp)
	movq	%rdx, 16(%rsp)
	movq	%rdi, %r8

	movq	%rbx, W_RBX(%r8)
	movq	%rbp, W_RBP(%r8)
	movq	%r12, W_R12(%r8)
	movq	%r13, W_R13(%r8)
	movq	%r14, W_R14(%r8)
	movq	%r15, W_R15(%r8)
	movq	%rsp, W_RSP(%r8)

	xorq	%r9, %r9
	rdmsr_r9 MSR_GS_BASE
	movq	%r9, W_LGS(%r8)
	xorq	%r9, %r9
	rdmsr_r9 MSR_KERNEL_GS_BASE
	movq	%r9, W_LKGS(%r8)
	movq	%cr3, %r9
	movq	%r9, W_LCR3(%r8)
	sidt	W_LIDT(%r8)
	sgdt	W_LGDT(%r8)
	str	%ax
	movzwl	%ax, %eax
	movq	%rax, W_LTR(%r8)

	xorl	%edi, %edi			/* x86 has no PAC keys */
	leaq	W_KEYS(%r8), %rsi
	call	fki_enter			/* IRQs and preemption off; returns saved flags in %rax */
	movq	%rax, W_FLAGS(%r8)
	movq	0(%rsp), %r8

	/* XNU state is zero on the first call: vstart installs it before its first upcall. */
	movq	W_XGS(%r8), %r9
	testq	%r9, %r9
	jz	1f
	wrmsr_r9 MSR_GS_BASE
1:	movq	W_XKGS(%r8), %r9
	testq	%r9, %r9
	jz	2f
	wrmsr_r9 MSR_KERNEL_GS_BASE
2:	movq	W_XCR3(%r8), %r9
	testq	%r9, %r9
	jz	3f
	movq	%r9, %cr3
3:	cmpw	$0, W_XIDT(%r8)
	je	4f
	lidt	W_XIDT(%r8)
4:	cmpw	$0, W_XGDT(%r8)
	je	5f
	lgdt	W_XGDT(%r8)
5:	cmpw	$0, W_XTR(%r8)
	je	6f
	ltr	W_XTR(%r8)
6:
	movq	8(%rsp), %r11			/* fn */
	movq	16(%rsp), %rdi			/* arg */
	movq	%r8, %r12			/* r12 is callee-saved across fn and xnu_hook */
	call	__x86_indirect_thunk_r11
	movq	%r12, %r8			/* w */
	xorl	%r12d, %r12d			/* fn returned normally */
	WORLD_EXIT
SYM_FUNC_END(xnu_world_switch_in)
	/* Objtool cannot describe a return onto the saved stack frame. */
	.pushsection .discard.func_stack_frame_non_standard,"a"
	.quad	xnu_world_switch_in
	.quad	xnu_world_abort
	.popsection

/*
 * xnu_world_abort(w): entered from an upcall that asked to end the run. Never returns
 * to XNU; unwinds straight to xnu_world_switch_in's caller with result 1.
 */
SYM_FUNC_START(xnu_world_abort)
	ENDBR
	movq	%rdi, %r8
	movl	$1, %r12d
	WORLD_EXIT
SYM_FUNC_END(xnu_world_abort)

/*
 * xnu_world_upcall_asm(w, stage, a1, a2): the address in XNU's linux64_hook.
 */
SYM_FUNC_START(xnu_world_upcall_asm)
	ENDBR
	pushq	%rbp
	pushq	%rbx
	pushq	%r12
	pushq	%r13
	pushq	%r14
	pushq	%r15
	subq	$24, %rsp
	movq	%rdi, 0(%rsp)
	movq	%rsi, 8(%rsp)
	movq	%rdx, 16(%rsp)
	movq	%rcx, 20(%rsp)
	movq	%rdi, %r8

	movq	%rbx, W_XRBX(%r8)
	movq	%rbp, W_XRBP(%r8)
	movq	%r12, W_XR12(%r8)
	movq	%r13, W_XR13(%r8)
	movq	%r14, W_XR14(%r8)
	movq	%r15, W_XR15(%r8)
	movq	%rsp, W_XRSP(%r8)

	xorq	%r9, %r9
	rdmsr_r9 MSR_GS_BASE
	movq	%r9, W_XGS(%r8)
	xorq	%r9, %r9
	rdmsr_r9 MSR_KERNEL_GS_BASE
	movq	%r9, W_XKGS(%r8)
	movq	%cr3, %r9
	movq	%r9, W_XCR3(%r8)
	sidt	W_XIDT(%r8)
	sgdt	W_XGDT(%r8)
	str	%ax
	movzwl	%ax, %eax
	movq	%rax, W_XTR(%r8)

	/* Hand Linux its own machine state back before any C code here touches `current`. */
	movq	W_LCR3(%r8), %r9
	movq	%r9, %cr3
	lidt	W_LIDT(%r8)
	lgdt	W_LGDT(%r8)
	movzwl	W_LTR(%r8), %eax
	ltr	%ax
	movq	W_LGS(%r8), %r9
	wrmsr_r9 MSR_GS_BASE
	movq	W_LKGS(%r8), %r9
	wrmsr_r9 MSR_KERNEL_GS_BASE

	movq	8(%rsp), %rdi			/* stage */
	movq	16(%rsp), %rsi			/* a1 */
	movq	20(%rsp), %rdx			/* a2 */
	movq	%r8, %r12
	call	xnu_hook
	testq	%rax, %rax
	jnz	9f
	movq	%r12, %r8

	/* Resume XNU with exactly the machine state it left with. */
	movq	W_XCR3(%r8), %r9
	movq	%r9, %cr3
	lidt	W_XIDT(%r8)
	lgdt	W_XGDT(%r8)
	movzwl	W_XTR(%r8), %eax
	ltr	%ax
	movq	W_XGS(%r8), %r9
	wrmsr_r9 MSR_GS_BASE
	movq	W_XKGS(%r8), %r9
	wrmsr_r9 MSR_KERNEL_GS_BASE
	movq	W_XRSP(%r8), %rsp
	addq	$24, %rsp
	movq	W_XRBX(%r8), %rbx
	movq	W_XRBP(%r8), %rbp
	movq	W_XR12(%r8), %r12
	movq	W_XR13(%r8), %r13
	movq	W_XR14(%r8), %r14
	movq	W_XR15(%r8), %r15
	xorl	%eax, %eax
	popq	%r15
	popq	%r14
	popq	%r13
	popq	%r12
	popq	%rbx
	popq	%rbp
	RET
9:	movq	%r12, %rdi
	call	xnu_world_abort
	ud2					/* xnu_world_abort never returns */
SYM_FUNC_END(xnu_world_upcall_asm)

SYM_FUNC_START(xnu_world_fault_abort)
	ENDBR
	xorl	%eax, %eax
	RET
SYM_FUNC_END(xnu_world_fault_abort)

SYM_FUNC_START(xnu_fault_tramp)
	ENDBR
	RET
SYM_FUNC_END(xnu_fault_tramp)
