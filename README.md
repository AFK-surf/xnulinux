# xnulinux

XNU, built from source, running as a loadable kernel module inside an arm64 Linux kernel, to give Linux a macOS personality.

## Layout and licenses

The two sides are kept apart by license and only meet at the FKI (foreign kernel interface, `include/linux/fki.h`):

| Path | License | What |
|---|---|---|
| `linux/` | GPL-2.0 | In-tree FKI patch for Linux (`drivers/fki`, `include/linux/fki.h`) |
| `fki-ko/` | GPL-2.0 | The same FKI v0 as an out-of-tree module, for stock distro kernels |
| `xnu-ko/` | APSL-2.0 side | `xnu.ko`: loads the XNU Mach-O and calls into it; uses only FKI |
| `scripts/` | | Build and run scripts |

`xnu.ko` must not include Linux headers beyond the module ABI, call Linux functions other than `fki_*`, or carry Linux code.

## Status

- **M1 (done, 2026-11-20).** A source-built XNU (`xnu-12377.121.6` plus the macOS-DroidVM patch series, arm64e) is loaded by `xnu.ko` into a stock Ubuntu 24.04 kernel (`7.0.0-43-generic`, 4K pages, PAC). It is slid and PAC-signed with XNU's own kernel keys, and XNU code runs inside Linux. XNU's `strlen` and `crc32` results match a reference computation.
- **M2a (done, 2026-11-20).** `arm_init` runs inside the module from `xnu.ko`'s boot args and ADT up to `arm_vm_init` (stage 199), with XNU's `kprintf` in dmesg. Next is M2b: a LINUX64 `arm_vm_init` and pmap on FKI.
- **M2b (done, 2026-11-20).** XNU runs at its own link address on physically contiguous memory with real PAs. `arm_vm_init` builds its kernel page tables, `xnu.ko` installs XNU's 48 kernel L1 entries into Linux's top-level L1 (the free `L1[384..495]` of `L0[511]`), and the hardware walks XNU's own tables. `pmap_bootstrap` runs, and XNU prints `kprintf initialized` to dmesg. Then (M2c, 2026-11-20) `machine_startup` → `kernel_bootstrap` runs to the end: zalloc/kalloc, scheduler, Mach IPC, tasks and threads; `load_context` switches to `kernel_bootstrap_thread`, which creates the idle thread, starts the scheduler, thread calls, clock service, kdp and sysctl, and reaches `PE_init_iokit`. Next: IOKit (`PE_init_iokit`), then timers/IPIs on FKI and real kthreads.
- **M2c (done, 2026-11-20).** The bare kernel runs `kernel_bootstrap_thread` through IOKit to `bsd_init` (VFS, mbufs, MAC, audit, aio), with a cooperative timer (XNU idles into the host, which delivers its timer), a virtual interrupt flag (hardware IRQs stay masked on XNU stacks), host-reported `assert`s and panics, and stand-ins for what the kexts would register.
- **M2e (done, 2026-11-20).** `xnu.ko` loads a fileset kernel collection: our kernel plus 53 of Apple's macOS 27.2 kexts (vma2 kernelcache, linked with macOS-DroidVM's `kc-build27.py`; Apple's binaries stay local). XNU applies the collection's chained fixups and signs it itself. Kernel page faults on XNU addresses are forwarded by FKI (`fki_fault_register`) to XNU's `vm_fault`; a fault nothing resolves ends the run cleanly instead of taking the host down. Apple's corecrypto (FIPS POST passes), AppleImage4, AMFI and Sandbox initialize; the ADT carries the `/chosen` a bootloader would pass (boot manifest hash, AP identity, NVRAM, SIP) and `/options`. `bsd_init` runs through networking and Skywalk to `IOFindBSDRoot`, waiting for a root device. Next: a root device (an FKI block endpoint or a RAM disk), NativeAES and AKS for AppleImage4 and AMFI, then `launchd` (M3).
- **M3 (in progress, 2026-11-20).** User space runs under the hosted XNU. EL0 entry and exit go through a LINUX64 path (`linux64_el0_run`, `linux64_el0_vectors`, `linux64_el0_exception` into XNU's own `sleh_synchronous`) that keeps Linux's x18 (shadow call stack), the user's NEON/FP state and XNU's ASIDs (TCR.A1 off in XNU's world); upcalls keep the user TLS registers Linux's scheduler would clobber, and unresolved faults inside copyin/copyout take XNU's copyio recovery. The root can be a host file (`hostdisk=`: FKI `fki_file_open/rw`, XNU `memdev` in host mode). Done so far: static test binaries (`tools/init`) through `open`/`write` on `/dev/console`, `fork`, `execve`, `wait4`, signals; then Apple's own `/bin/echo` from macOS, dynamically linked: dyld maps the 7 GB dyld shared cache system wide from an HFS+ image on the Linux host and echo prints through libSystem (Apple's binaries stay local, never in this repo). Then Apple's `/bin/sh` (bash: builtins, fork/exec of `uname` and `ls`), and macOS's own `launchd` as PID 1: libignition, the boot tasks, LaunchDaemons import and xpcproxy spawns. What launchd needs from hardware that is not there is stood in for inside the hosted XNU: AppleKeyStore's `AKSKernelServices` table (the three entries AMFI calls, PAC-signed with their type discriminators), the SEP `scrd` endpoint, an `IOAESAccelerator` whose AES entry copies (AppleImage4's nonce store). FKI moves Linux-running upcalls (idle, host file I/O) to a Linux-shaped stack and catches the foreign kernel's non-abort exceptions (die()), so XNU problems end the run instead of the host. EL0 tracing: boot-arg `linux64_trace=1` (system calls with the pid, paths of open/stat/exec/posix_spawn).
  Later on 2026-11-20: launchd runs our job files (`xnulinux.hello`: sh, uname, ls, exit 0) and an interactive `bash -i` on `/dev/console`, whose input is typed from the host (`console_in=`, `scripts/xnu-console.sh`); the root mounts read-write (checked with `fsck.hfsplus` before each boot). Apple's core daemons run with it: notifyd (needs the sandbox profiles), logd (needs a writable root), syslogd, configd, opendirectoryd (needs a local node: a generated `dslocal` with root, daemon, wheel). Open: user lookups (`id`) wait on opendirectoryd, which keeps serving Mach messages; `sw_vers` needs `SystemVersion.plist`.

Debugging: the VM console is captured on the host (`scripts/serial-pty.py`), a monitor thread on another CPU prints XNU's counters every 2 s, and XNU dumps its threads with their saved frames after 20000 idle rounds.

## Running M1

The host is an arm64 Linux with PAC (for example an Apple Silicon VM under Virtualization.framework).

1. `scripts/vm-xnu-build.sh` builds the kernel with the macOS-DroidVM Linux toolchain, natively on arm64 and without Darling.
2. `scripts/vm-m1.sh` builds both modules against the running kernel, installs the image as firmware `xnu/kernel.macho`, and loads them.
