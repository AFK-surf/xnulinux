/* SPDX-License-Identifier: APSL-2.0 */
/* The faulting context and the fault handler's side of tramptest (main.c). */
	.text

/* void tramptest_run(struct tramptest_out *out): inside fki_enter (interrupts off) */
	.globl	tramptest_run
	.type	tramptest_run, %function
tramptest_run:
	stp	x29, x30, [sp, #-32]!
	mov	x29, sp
	mrs	x9, fpsr
	mrs	x10, fpcr
	stp	x9, x10, [sp, #16]		/* the caller's, put back at the end */
	/* the PSTATE to come back with: this one (EL1h, the interrupt masks as they are, PAN as the kernel has it) */
	mrs	x9, daif
	mrs	x10, currentel
	orr	x9, x9, x10
	mrs	x10, spsel
	orr	x9, x9, x10
	mrs	x10, s3_0_c4_c2_3		/* PAN */
	orr	x9, x9, x10
	adrp	x10, tramptest_spsr
	str	x9, [x10, :lo12:tramptest_spsr]
	adr	x9, 1f
	adrp	x10, tramptest_resume
	str	x9, [x10, :lo12:tramptest_resume]
	/* what the context holds when it "faults" */
	movi	v0.16b, #0x40
	movi	v1.16b, #0x41
	movi	v2.16b, #0x42
	movi	v3.16b, #0x43
	movi	v4.16b, #0x44
	movi	v5.16b, #0x45
	movi	v6.16b, #0x46
	movi	v7.16b, #0x47
	movi	v8.16b, #0x48
	movi	v9.16b, #0x49
	movi	v10.16b, #0x4a
	movi	v11.16b, #0x4b
	movi	v12.16b, #0x4c
	movi	v13.16b, #0x4d
	movi	v14.16b, #0x4e
	movi	v15.16b, #0x4f
	movi	v16.16b, #0x50
	movi	v17.16b, #0x51
	movi	v18.16b, #0x52
	movi	v19.16b, #0x53
	movi	v20.16b, #0x54
	movi	v21.16b, #0x55
	movi	v22.16b, #0x56
	movi	v23.16b, #0x57
	movi	v24.16b, #0x58
	movi	v25.16b, #0x59
	movi	v26.16b, #0x5a
	movi	v27.16b, #0x5b
	movi	v28.16b, #0x5c
	movi	v29.16b, #0x5d
	movi	v30.16b, #0x5e
	movi	v31.16b, #0x5f
	mov	x9, #0x1f			/* FPSR: the cumulative exception flags */
	msr	fpsr, x9
	mov	x9, #0xc00000			/* FPCR: rounding toward zero */
	msr	fpcr, x9
	b	xnu_fault_tramp			/* as Linux's exception return does: every register as at the fault */
1:	/* back from the trampoline's eret: what the context finds */
	stp	q0, q1, [x0, #0]
	stp	q2, q3, [x0, #32]
	stp	q4, q5, [x0, #64]
	stp	q6, q7, [x0, #96]
	stp	q8, q9, [x0, #128]
	stp	q10, q11, [x0, #160]
	stp	q12, q13, [x0, #192]
	stp	q14, q15, [x0, #224]
	stp	q16, q17, [x0, #256]
	stp	q18, q19, [x0, #288]
	stp	q20, q21, [x0, #320]
	stp	q22, q23, [x0, #352]
	stp	q24, q25, [x0, #384]
	stp	q26, q27, [x0, #416]
	stp	q28, q29, [x0, #448]
	stp	q30, q31, [x0, #480]
	mrs	x9, fpsr
	mrs	x10, fpcr
	str	x9, [x0, #512]
	str	x10, [x0, #520]
	ldp	x9, x10, [sp, #16]
	msr	fpsr, x9
	msr	fpcr, x10
	ldp	x29, x30, [sp], #32
	ret
	.size	tramptest_run, . - tramptest_run

/* void tramptest_clobber(void): what resolving the fault may do to the FP/SIMD registers */
	.globl	tramptest_clobber
	.type	tramptest_clobber, %function
tramptest_clobber:
	movi	v0.16b, #0xc0
	movi	v1.16b, #0xc1
	movi	v2.16b, #0xc2
	movi	v3.16b, #0xc3
	movi	v4.16b, #0xc4
	movi	v5.16b, #0xc5
	movi	v6.16b, #0xc6
	movi	v7.16b, #0xc7
	movi	v8.16b, #0xc8
	movi	v9.16b, #0xc9
	movi	v10.16b, #0xca
	movi	v11.16b, #0xcb
	movi	v12.16b, #0xcc
	movi	v13.16b, #0xcd
	movi	v14.16b, #0xce
	movi	v15.16b, #0xcf
	movi	v16.16b, #0xd0
	movi	v17.16b, #0xd1
	movi	v18.16b, #0xd2
	movi	v19.16b, #0xd3
	movi	v20.16b, #0xd4
	movi	v21.16b, #0xd5
	movi	v22.16b, #0xd6
	movi	v23.16b, #0xd7
	movi	v24.16b, #0xd8
	movi	v25.16b, #0xd9
	movi	v26.16b, #0xda
	movi	v27.16b, #0xdb
	movi	v28.16b, #0xdc
	movi	v29.16b, #0xdd
	movi	v30.16b, #0xde
	movi	v31.16b, #0xdf
	msr	fpsr, xzr
	msr	fpcr, xzr
	ret
	.size	tramptest_clobber, . - tramptest_clobber
