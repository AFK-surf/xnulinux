# xnulinux on an NVIDIA DGX Spark (GB10)

What was set on that machine (Ubuntu 24.04.5, Linux `7.0.0-1025-nvidia`), bare metal and in a KVM guest. The addresses
and CPU numbers are that machine's.

## Bare metal

- Secure Boot off: with it the kernel is locked down, which refuses unsigned modules and the kprobes fki needs.
- Kernel command line: `kvm-arm.mode=nvhe mem=112G nokaslr log_buf_len=128M`. `nvhe` keeps Linux at EL1; `mem=` leaves
  the RAM above it for the carve-out; with `nokaslr` the kernel image stays out of it.
- `insmod fki.ko carve_base=0x1E00000000 carve_mb=8156 cpu_list=5,6,7,8,9`. The NVMe has 15 I/O queues for 20 CPUs, so
  some CPUs share a queue's interrupt, and two XNU CPUs on such a pair deadlock: `cpu_list` gives XNU CPUs that each
  have a queue of their own (here the X925 cores; the one after the last XNU CPU is the monitor thread's).
- NetworkManager takes `xnu0` and removes its address unless told not to:
  `unmanaged-devices=interface-name:xnu0` in `/etc/NetworkManager/conf.d/`.
- The counter runs at 1 GHz: xnu.ko has XNU scale it to 24 MHz, which Apple's user space assumes.

## GPU

The render node is NVIDIA's driver, not virtio-gpu, so `xnudrmd` serves the hosted system's Venus driver from
virglrenderer on the machine's Vulkan driver (`gpu/xnu-drm/xnudrmd_virgl.c`). Ubuntu 24.04's virglrenderer 1.0.0 fails
`vkCreateDevice` there; `gpu/build-virglrenderer.sh` builds and installs 1.2.0 with Venus. With `GPU=auto` and the
Venus driver in `/Library/GPUBundles/XnuCpuMetal.bundle`, Metal and WindowServer run on `Virtio-GPU Venus (NVIDIA GB10)`.

The backend's shared memory is Linux's 4 KB pages, not contiguous, and XnuDrm cannot map those into a task with 16 KB VM
pages (`map handle ...: 0xe00002bd`; every client then falls back to the software renderer): `xnulinux-boot.sh` starts
XNU with `vm16k=0` when xnudrmd serves this backend.

## In a KVM guest

`guest/`: an arm64 Ubuntu guest under KVM, QEMU run from a container (`Dockerfile`, `run-vm.sh`, `vm.sh`); KVM on the
GB10 gives the guest pointer authentication. `hcmd.sh` runs commands in the hosted system's console shell and returns
their output over the `xnu0` link, for when the kernel log is flooded.

## Open

- Without the GPU bridge `iconservicesagent` crashes in lavapipe (a JIT-compiled fragment shader reads a missing
  sampler entry); the Dock then has no icons.
- A system disk restored by a virtual Mac has its Data volume encrypted with that VM's keys: the hosted system cannot
  open it, and the volume has to be made again unencrypted.
