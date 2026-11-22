# Hosted XNU on several CPUs

Today the hosted XNU runs on one CPU: xnu.ko's loading task, bound to Linux CPU 0, enters the XNU world and stays
there (`hw.ncpu` 1). A desktop session alone keeps that CPU busy, and 4K video decodes in software (no Apple video
decoder in the hosted system), which needs several cores. This is the plan for N CPUs.

## What is single-CPU today

| Where | State | For N CPUs |
|---|---|---|
| XNU, the current thread (on hardware `TPIDR_EL1`, which is Linux's per-CPU base while hosted) | A global (`linux64_tpidr`) | Done: `TPIDRRO_EL0` in XNU's kernel (the user TSD is swapped in on return to user space), per CPU by nature |
| XNU, the virtual interrupt flag, pending IPI, host-yield clock | Globals | One slot per CPU, found from `MPIDR_EL1` (`LINUX64_CPU_SLOT`); xnu.ko checks at load that its CPUs map to distinct slots. A slot read before code that can block (an urgent AST) is read again after it: the thread can resume on another CPU |
| xnu.ko, `xnu_W` (`world.S`) | The world-switch save area: Linux's and XNU's callee-saved registers, keys, TTBR0/TCR, TLS | One per CPU, found the same way in `world.S` |
| xnu.ko, `in_xnu`, the deferred kernel-fault record, `kcount`, the console line buffer, statics in `xnu_hook_body` | Per-run state | Per CPU where it is per CPU (`in_xnu`, the fault record the exception handler leaves for `xnu_fault_tramp`); a spinlock where it is shared (the console buffer) |
| fki, `fki_hostcall` | One request slot | A small table of slots (xnudrmd serves them in order) or a mutex; the GPU bridge already opens one connection per process |
| The ADT (`/cpus`) | `cpu0` only | One node per CPU with its MPIDR, `cluster-type` P |
| `ml_wait_max_cpus` patch | One CPU, known at once | N |

## Starting CPUs

On a Mac, the platform's CPU kext (an `IOCPU` subclass, AppleARMCPU) calls `ml_processor_register` for each CPU and
starts them through its `PE_cpu_start` callback (it writes the core's reset vector). We keep Apple's CPU kext out
(it drives the AIC), so `kexts/XnuCPU` takes its place: one `IOCPU` per `/cpus` node. In XNU 12377
`ml_processor_register` boots the processor itself (`processor_boot` → `cpu_start`), so the kext only registers; the boot
CPU registers first (other CPUs send it IPIs as soon as they run, AppleARMSMP's order), a secondary matched before it
waits and is registered from the boot CPU's `start`. `cpu_start` asks the host (`LINUX64_CALL_CPU_START`, a1 = the CPU's
MPIDR, a2 = its `cpu_data`). An upcall runs with preemption off and must not sleep, so xnu.ko makes each secondary's
kernel thread, bound to its Linux CPU, before XNU runs; the call only hands it the argument and wakes it. The thread
enters the XNU world (its own save area) at `linux64_cpu_entry` → `arm_init_cpu` (`start_cpu`'s hardware setup is the
host's). xnu.ko's helper threads (monitor, framebuffer) run on the first Linux CPU XNU does not use.

## Interrupts between CPUs

`IOCPU::signalCPU` (an AIC register write on hardware) becomes `linux64_cpu_signal`, a host call `LINUX64_CALL_IPI` (a1 = target MPIDR):
xnu.ko marks the target pending and, if it is asleep in its idle call, wakes it; if it is running XNU code, sends it a
Linux IPI (`smp_call_function_single_async`). A CPU in XNU's kernel runs with hardware interrupts masked, so it takes a pending XNU IPI where XNU's
virtual interrupt flag is turned back on (`ml_set_interrupts_enabled(TRUE)`, already the place where host interrupts are
let in every 2 ms), on return to user space and at idle. User code runs with host interrupts on: the Linux IPI ends
it at once (as a host interrupt does today, `LINUX64_CALL_PREEMPTED`), and the pending XNU IPI is delivered as
`sleh_fiq`/`sleh_irq` would.

TLB maintenance needs no IPI: XNU's pmap uses broadcast `TLBI ...IS` on its own ASIDs. Each CPU still drops its local
TLB at every world switch (`TO_XNU_MM`/`TO_LINUX_MM`): Linux's and XNU's ASIDs are unrelated.

## What follows the CPU, not the thread

An XNU thread can block on one CPU and resume on another; what belongs to the Linux task under the CPU must not travel
with it. Linux's shadow call stack pointer (x18, `CONFIG_SHADOW_CALL_STACK`) is the Linux task's: XNU's context switch
never saves x18, so the register stays with the CPU, and `world.S` saves and restores it at world entry and exit. Two
places used to carry it across a move and corrupted both tasks' shadow stacks (FPAC in Linux interrupt handlers,
"corrupted shadow stack detected inside scheduler"): `xnu_fault_deferred` itself (built without the shadow stack, as
`vm_fault` may block inside it) and `xnu_fault_tramp`'s `eret`, which restores the faulting context's registers: when the
thread moved, its frame's x18 is replaced with the current CPU's. The monitor's `moved=` counts those resumes.

A CPU spinning in XNU (`wait_for_event()`, every hardware lock's wait) may wait for a CPU the host holds; every ~1 ms of
spinning lets the host take the spinning CPU's interrupts (`linux64_spin_relax`, nothing of XNU's runs there).

## Steps, each verified on a running system

1. Per-CPU state with one CPU: the thread-pointer slots, per-CPU save areas in xnu.ko, the hostcall table. Boots and
   runs as today (`hw.ncpu` 1).
2. `kexts/XnuCPU`, `LINUX64_CALL_CPU_START`, `LINUX64_CALL_IPI`; two CPUs (`cpus=2`). Check: `hw.ncpu` 2, both CPUs'
   idle counters move, a CPU-bound process on each CPU (`yes > /dev/null` twice) shows 200% in `top`.
   Done: `hw.ncpu` and `hw.activecpu` 2; two `yes` plus the login's own work reach about 170% (more than one CPU can);
   the desktop comes up; minutes of running with a hundred cross-CPU fault resumes and no fault. Kernel fault counts
   are of one CPU's order (7.6 and 5.6 million in the first 8 minutes).
3. N CPUs (`cpus=` defaults to the Linux CPUs less one for Linux), then the workloads: build a project, 4K playback.
