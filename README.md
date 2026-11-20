# xnulinux

XNU, built from source, running as a loadable kernel module inside an arm64 Linux kernel, to give Linux a macOS personality.
The design is in [losfair/l4h#201](https://github.com/losfair/l4h/issues/201).

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
- **M2b (done, 2026-11-20).** XNU runs at its own link address on physically contiguous memory with real PAs. `arm_vm_init` builds its kernel page tables, `xnu.ko` installs XNU's 48 kernel L1 entries into Linux's top-level L1 (the free `L1[384..495]` of `L0[511]`), and the hardware walks XNU's own tables. `pmap_bootstrap` runs, and XNU prints `kprintf initialized` to dmesg. Next: M2c (rtclock on FKI timers, `machine_startup` → `kernel_bootstrap`).

## Running M1

The host is an arm64 Linux with PAC (for example an Apple Silicon VM under Virtualization.framework).

1. `scripts/vm-xnu-build.sh` builds the kernel with the macOS-DroidVM Linux toolchain, natively on arm64 and without Darling.
2. `scripts/vm-m1.sh` builds both modules against the running kernel, installs the image as firmware `xnu/kernel.macho`, and loads them.
