# Hosted XNU on several CPUs

Today the hosted XNU runs on one CPU: xnu.ko's loading task, bound to Linux CPU 0, enters the XNU world and stays
there (`hw.ncpu` 1). A desktop session alone keeps that CPU busy, and 4K video decodes in software (no Apple video
decoder in the hosted system), which needs several cores. This is the plan for N CPUs.

## What is single-CPU today

| Where | State | For N CPUs |
|---|---|---|
| XNU, `linux64_tpidr` (`osfmk/arm/arm_init.c`, ~45 uses in `locore.s`, `cswitch.s`, `asm.h`, `cpu_data.h`, ...) | The current thread: on hardware `TPIDR_EL1`, which is Linux's per-CPU base while hosted | One slot per CPU, found from `MPIDR_EL1` (`READ_THREAD`/`WRITE_THREAD` macros, one implementation); xnu.ko checks at load that the CPUs it uses map to distinct slots |
| xnu.ko, `xnu_W` (`world.S`) | The world-switch save area: Linux's and XNU's callee-saved registers, keys, TTBR0/TCR, TLS | One per CPU, found the same way in `world.S` |
| xnu.ko, `in_xnu`, `kcount`, the console line buffer, statics in `xnu_hook_body` | Per-run state | Per CPU where it is per CPU (`in_xnu`); a spinlock where it is shared (the console buffer) |
| fki, `fki_hostcall` | One request slot | A small table of slots (xnudrmd serves them in order) or a mutex; the GPU bridge already opens one connection per process |
| The ADT (`/cpus`) | `cpu0` only | One node per CPU with its MPIDR, `cluster-type` P |
| `ml_wait_max_cpus` patch | One CPU, known at once | N |

## Starting CPUs

On a Mac, the platform's CPU kext (an `IOCPU` subclass, AppleARMCPU) calls `ml_processor_register` for each CPU and
starts them through its `PE_cpu_start` callback (it writes the core's reset vector). We keep Apple's CPU kext out
(it drives the AIC), so `kexts/XnuCPU` takes its place: one `IOCPU` per `/cpus` node, `ml_processor_register` with
callbacks whose start is a host call (`LINUX64_CALL_CPU_START`, a1 = the CPU's MPIDR, a2 = XNU's entry for it).
xnu.ko then starts a kernel thread bound to that Linux CPU, which enters the XNU world (its own save area) at the
entry XNU gave (`start_cpu` → `arm_init_cpu`).

## Interrupts between CPUs

`ml_cpu_signal` (an AIC register write on hardware) becomes a host call `LINUX64_CALL_IPI` (a1 = target MPIDR):
xnu.ko marks the target pending and, if it is asleep in its idle call, wakes it; if it is running XNU code, sends it a
Linux IPI. A CPU in XNU's kernel runs with hardware interrupts masked, so it takes a pending XNU IPI where XNU's
virtual interrupt flag is turned back on (`ml_set_interrupts_enabled(TRUE)`, already the place where host interrupts are
let in every 2 ms), on return to user space and at idle. User code runs with host interrupts on: the Linux IPI ends
it at once (as a host interrupt does today, `LINUX64_CALL_PREEMPTED`), and the pending XNU IPI is delivered as
`sleh_fiq`/`sleh_irq` would.

TLB maintenance needs no IPI: XNU's pmap uses broadcast `TLBI ...IS` on its own ASIDs. Each CPU still drops its local
TLB at every world switch (`TO_XNU_MM`/`TO_LINUX_MM`): Linux's and XNU's ASIDs are unrelated.

## Steps, each verified on a running system

1. Per-CPU state with one CPU: the thread-pointer slots, per-CPU save areas in xnu.ko, the hostcall table. Boots and
   runs as today (`hw.ncpu` 1).
2. `kexts/XnuCPU`, `LINUX64_CALL_CPU_START`, `LINUX64_CALL_IPI`; two CPUs (`cpus=2`). Check: `hw.ncpu` 2, both CPUs'
   idle counters move, a CPU-bound process on each CPU (`yes > /dev/null` twice) shows 200% in `top`.
3. N CPUs (`cpus=` defaults to the Linux CPUs less one for Linux), then the workloads: build a project, 4K playback.
