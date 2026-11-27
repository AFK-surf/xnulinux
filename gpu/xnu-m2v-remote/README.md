# xnu-m2v-remote: the Metal device's renderer on another machine

The hosted macOS draws on a GPU that is not in its machine: an arm64 host without one, and an x86_64 machine with one
beside it. The cut is the C interface between the Metal plugin and metal2vulkan (`xnu_m2v.h`, 145 functions, in
`gpu/xnu-cpu-metal/src/xnu-m2v-bridge`): the bridge itself builds and runs unchanged on Linux x86_64 with the machine's
Vulkan driver, and in the hosted system `libxnu_m2v.dylib` sends each call there. The plugin is not changed.

It is an option, chosen on the host: `GPU=remote` and `GPU_REMOTE=host:port` for `scripts/xnulinux-boot.sh` (or in
`/etc/xnulinux.conf`). The library in the bundle is then one that is either (`switch.c`): without the boot-arg the boot
script adds (`xm2v-remote=1`) every call goes to the real library beside it, as before.

```
 hosted macOS (arm64 host)                                        the machine with the GPU
 Metal -> XnuCpuMetal plugin -> libxnu_m2v.dylib (client.c)       xm2v-server (server.c) -> libxnu_m2v.so
            |  kexts/XnuDrm's user client (a sandbox has no sockets)        ^            (metal2vulkan) -> Vulkan
            v                                                               |
 Linux host: /dev/xnu-hostcall -> xm2v-relay (relay.c) ---- TCP ------------+
```

- `proto.h`: the messages. A call is a header and its arguments; the caller names the objects it makes, so making one
  needs no answer, and a frame's calls go out without waiting for the renderer. Only calls that return something are
  answered.
- `gen.py`: reads `xnu_m2v.h` and writes both ends of the regular functions (`gen_client.inc`, `gen_server.inc`,
  `gen_ops.h`); the rest are by hand in `client.c` and `server.c`.
- `client.c`: the stand-in library. A buffer's contents stay in the calling process. A command buffer remembers the
  buffers its encoders name; at commit the 4 KB pages that changed since they were last sent go first. Buffers the GPU
  may have written come back with the answer to `wait_until_completed`. On macOS it reaches the renderer through the
  DRM bridge's user client (WindowServer's sandbox denies every socket); with `XM2V_REMOTE=host:port` it connects
  itself (tests outside a sandbox, and on Linux).
- `switch.c`: the library that is either: the real one (`libxnu_m2v_local.dylib`, loaded when it is the choice) or
  `client.c`'s functions. `into-bundle.sh` puts it into a built `XnuCpuMetal.bundle`.
- `server.c`: `xm2v-server PORT LOADER ICD_JSON`, a process for each connection (one Metal device of one process).
- `relay.c`: `xm2v-relay HOST PORT` on the Linux host, as root, in `xnudrmd`'s place on `/dev/xnu-hostcall`.
- `t2.c`, `t2.metal`: buffers both ways, textures and pipelines, against the real library or the remote one.
  `mt.m`: a triangle through Metal in the hosted system (with `gpu/xnu-cpu-metal/test/tri.metal`'s library).

## Build

On the machine with the GPU (Rust 1.100.0; a checkout of this repository with metal2vulkan fetched and patched as
`gpu/xnu-cpu-metal/scripts/fetch-sources.sh` does):

    cargo build --release --manifest-path ../xnu-cpu-metal/src/xnu-m2v-bridge/Cargo.toml
    ./build.sh server && ./xm2v-server 7001 libvulkan.so.1 /usr/share/vulkan/icd.d/nvidia_icd.json

On a Mac, into the bundle that goes on the system disk (the real library becomes `libxnu_m2v_local.dylib`, the one
that is either takes its name, the bundle is signed again):

    ./into-bundle.sh path/to/XnuCpuMetal.bundle

On the Linux host: `GPU=remote GPU_REMOTE=GPU_HOST:7001 scripts/xnulinux-boot.sh` (it builds and starts `xm2v-relay`).

## Measured (c4a-standard-4 hosting, g2-standard-8 with an NVIDIA L4 in the same zone, 0.4 ms apart)

- A Metal triangle at 1280x800 in the hosted system: 6.1 ms a frame on lavapipe, 0.10 ms here.
- A window moving on the desktop, a Screen Sharing viewer attached: 6.7 frames a second on lavapipe, 20.4 here.
- 1000 frames of 100 draws that are not waited for: 0.11 ms and 8.5 KB each.

## Open

- Every display frame's pixels are still read back into the hosted system (4 MB a frame; 6 to 9 ms through the bridge).
- The library polls for answers (the bridge makes one host call at a time and none may wait).
- A shared event's handle means something only in the server process that made it.
- A page the GPU wrote replaces the whole page in the process: a CPU write elsewhere on it since the last commit is lost.
- A failed call that is not answered is only logged by the server.
- `xm2v-server` is started by hand on the machine with the GPU.
