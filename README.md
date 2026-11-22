# xnulinux

XNU, built from source, running as a loadable kernel module inside an arm64 Linux kernel, to give Linux a macOS personality.

## Layout and licenses

The two sides are kept apart by license and only meet at the FKI (foreign kernel interface, `include/linux/fki.h`):

| Path | License | What |
|---|---|---|
| `linux/` | GPL-2.0 | In-tree FKI patch for Linux (`drivers/fki`, `include/linux/fki.h`) |
| `fki-ko/` | GPL-2.0 | The same FKI v0 as an out-of-tree module, for stock distro kernels |
| `xnu-ko/` | APSL-2.0 side | `xnu.ko`: loads the XNU kernel collection and calls into it; uses only FKI |
| `xnu-patches/` | APSL-2.0 | The LINUX64 machine layer and hosted-kernel changes, applied to XNU's sources |
| `kexts/` | BSD-2-Clause | Our kexts in the kernel collection: disk, display, input, Ethernet, keystore stand-ins, Metal accelerator, DRM bridge |
| `gpu/` | per directory | Metal plugin (`xnu-cpu-metal`), the DRM bridge's user-space ends (`xnu-drm`), Mesa Venus patches (`venus`) |
| `scripts/`, `tools/` | | Build, disk, boot and test tools |

`xnu.ko` must not include Linux headers beyond the module ABI, call Linux functions other than `fki_*`, or carry Linux code.
Upstream code (Mesa, metal2vulkan, the Vulkan loader, Apple's open source) is fetched at pinned revisions and patched at
build time; it is never committed.

## Status (2026-11-22)

- A stock Ubuntu kernel (`7.0.0-43-generic`, 4K pages, PAC) loads `xnu.ko`, which boots a source-built XNU
  (`xnu-12377.121.6` with the LINUX64 machine layer) inside it, with a kernel collection of our kernel and Apple's macOS
  27.2 kexts. XNU uses the host CPU and MMU directly; Linux gives it memory (CMA), timers, files, a network link and a
  message channel through FKI.
- The system disk is one Apple's own installer made (APFS, sealed system volume, Preboot, Data; `scripts/mk-macvm-disk.sh`)
  with a simulated SEP (AppleVPKeyStore over `kexts/XnuEAN`). macOS 27.2.1 boots to the desktop with auto-login: Dock,
  Finder, Safari and Chrome load web pages.
- Rendering: `gpu/xnu-cpu-metal` is a Metal device (metal2vulkan) over Mesa lavapipe on the CPU. The DRM bridge
  (`fki-ko/fki_hostcall.c`, `kexts/XnuDrm`, `gpu/xnu-drm`) gives hosted processes the Linux host's GPU through Mesa Venus:
  on an Apple Silicon host the Linux VM runs under krunkit (`scripts/krun-vm.sh`) and Vulkan in the hosted macOS runs on the
  host's GPU (`Virtio-GPU Venus (Apple M5 Max)`). Moving the Metal plugin onto it is in progress.
- From PoC to production: [`docs/production.md`](docs/production.md).

## Running

The host is an arm64 Linux VM with PAC on an Apple Silicon Mac (`scripts/krun-vm.sh`; tart works without the GPU), 24 GB:
`scripts/vm-install-fki-service.sh` gives Linux 15 GB (`mem=15G`) and the 8 GB above to the hosted kernel (fki's carve-out).

1. `scripts/vm-xnu-build.sh` (once) sets up the macOS-DroidVM Linux toolchain and builds XNU natively on arm64.
2. `scripts/vm-xnu-rebuild.sh` applies `xnu-patches/`, rebuilds the kernel, builds `kexts/` and links the kernel collection.
3. `scripts/mk-macvm-disk.sh` (on the Mac) makes the system disk with Apple's installer and puts it in the VM.
4. `scripts/xnulinux-boot.sh` (in the VM) builds `fki.ko` and `xnu.ko`, brings up the network and, with a render node, the
   GPU bridge (`xnudrmd`), and boots the hosted system from the disk and its `/var/tmp/mac.conf`; its console is
   `scripts/xnu-console.sh`, its screen `tools/hosted/fb2png.py`.
5. `gpu/venus/build-darwin.sh` (on the Mac) builds the hosted Vulkan driver that the Metal plugin uses on a real GPU.

Debugging: the VM console is captured on the host (`scripts/serial-pty.py`), a monitor thread on another CPU prints XNU's
counters every 2 s, and XNU dumps its threads with their saved frames after 20000 idle rounds.
