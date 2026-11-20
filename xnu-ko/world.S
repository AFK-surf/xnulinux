/* World switch, see world.h. No PAC instructions here: keys change under our feet.
 * TPIDR_EL1 stays Linux's: the LINUX64 XNU keeps its thread pointer in memory (linux64_tpidr),
 * so a fault taken in XNU code reaches Linux with a sane per-cpu base and becomes a normal oops. */
#define W(reg) adrp reg, xnu_W; add reg, reg, :lo12:xnu_W

	.text
	.globl	xnu_world_call
	.type	xnu_world_call, %function
xnu_world_call:
	W(x9)
	stp	x19, x20, [x9, #0]
	stp	x21, x22, [x9, #16]
	stp	x23, x24, [x9, #32]
	stp	x25, x26, [x9, #48]
	stp	x27, x28, [x9, #64]
	stp	x29, x30, [x9, #80]
	mov	x10, sp
	str	x10, [x9, #96]
	mov	x19, x0
	mov	x20, x1
	add	x0, x9, #328		/* load XNU keys */
	add	x1, x9, #240		/* save Linux keys */
	bl	fki_enter		/* no preemption, no IRQs */
	W(x9)
	str	x0, [x9, #104]
	msr	daifset, #0xf		/* XNU's kernel runs with debug exceptions masked (PSTATE.D) */
	mrs	x10, tpidr_el0		/* XNU writes the user TLS registers of the thread it believes current */
	str	x10, [x9, #216]
	mrs	x10, tpidrro_el0
	str	x10, [x9, #224]
	/* XNU runs on the Linux task stack: Linux's entry code treats any other stack as overflow. */
	mov	x0, x20
	blr	x19
	/* fn returned: XNU keys and thread pointer are live */
	W(x9)
	mov	x19, #0
	b	2f
xnu_world_abort:			/* from the upcall: Linux keys and TPIDR are live */
	W(x9)
	mov	x19, #1
2:	ldr	x10, [x9, #216]
	msr	tpidr_el0, x10
	ldr	x10, [x9, #224]
	msr	tpidrro_el0, x10
	ldr	x10, [x9, #96]
	mov	sp, x10
	ldr	x0, [x9, #104]
	add	x1, x9, #240
	bl	fki_leave		/* Linux keys, IRQs, preemption back */
	mov	x0, x19
	W(x9)
	ldp	x19, x20, [x9, #0]
	ldp	x21, x22, [x9, #16]
	ldp	x23, x24, [x9, #32]
	ldp	x25, x26, [x9, #48]
	ldp	x27, x28, [x9, #64]
	ldp	x29, x30, [x9, #80]
	ret
	.size	xnu_world_call, . - xnu_world_call

	.globl	xnu_world_fault_abort
	.type	xnu_world_fault_abort, %function
xnu_world_fault_abort:			/* exception return here: XNU keys live, XNU stack */
	W(x9)
	add	x0, x9, #240		/* load Linux keys */
	add	x1, x9, #328		/* save XNU keys */
	bl	fki_pac_swap
	b	xnu_world_abort
	.size	xnu_world_fault_abort, . - xnu_world_fault_abort

	.globl	xnu_world_upcall
	.type	xnu_world_upcall, %function
xnu_world_upcall:			/* x0 = stage, called by XNU with blr */
	hint	#34			/* bti c: module text may be guarded */
	W(x9)
	stp	x19, x20, [x9, #112]
	stp	x21, x22, [x9, #128]
	stp	x23, x24, [x9, #144]
	stp	x25, x26, [x9, #160]
	stp	x27, x28, [x9, #176]
	stp	x29, x30, [x9, #192]
	mov	x10, sp
	str	x10, [x9, #208]
	mov	x19, x0
	mov	x20, x1
	mov	x21, x2
	add	x0, x9, #240		/* load Linux keys */
	add	x1, x9, #328		/* save XNU keys */
	bl	fki_pac_swap
	mov	x0, x19
	mov	x1, x20
	mov	x2, x21
	bl	xnu_hook
	cbnz	x0, xnu_world_abort
	W(x9)
	add	x0, x9, #328		/* load XNU keys */
	add	x1, x9, #240		/* save Linux keys */
	bl	fki_pac_swap
	W(x9)
	ldr	x10, [x9, #208]
	mov	sp, x10
	ldp	x19, x20, [x9, #112]
	ldp	x21, x22, [x9, #128]
	ldp	x23, x24, [x9, #144]
	ldp	x25, x26, [x9, #160]
	ldp	x27, x28, [x9, #176]
	ldp	x29, x30, [x9, #192]
	ret
	.size	xnu_world_upcall, . - xnu_world_upcall
