# xnu-m2v-remote: the Metal device's renderer on another machine

The hosted macOS draws on a GPU that is not in its machine: an arm64 host without one, and an x86_64 machine with one
beside it. The cut is the C interface between the Metal plugin and metal2vulkan (`xnu_m2v.h`, 145 functions, in
`gpu/xnu-cpu-metal/src/xnu-m2v-bridge`): the bridge itself builds and runs unchanged on Linux x86_64 with the machine's
Vulkan driver, and in the hosted system `libxnu_m2v.dylib` sends each call there. The plugin is not changed.

It is an option, chosen on the host: `GPU=remote` and `GPU_REMOTE=host:port` for `scripts/xnulinux-boot.sh` (or in
`/etc/xnulinux.conf`). The library in the bundle is then one that is either (`switch.c`): without the boot-arg the boot
script adds (`xm2v-remote=1`) every call goes to the real library beside it, as before. If that library is missing the process
gets no Metal device (and the reason from `xm2v_last_error`); it never turns to the remote one by itself.

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
- `server.c`: `xm2v-server [ADDRESS:]PORT LOADER ICD_JSON`, a process for each connection (one Metal device of one
  process). It listens on 127.0.0.1 unless given an address.
- `relay.c`: `xm2v-relay HOST PORT` on the Linux host, as root, in `xnudrmd`'s place on `/dev/xnu-hostcall`.
- `t2.c`, `t2.metal`: buffers both ways, textures and pipelines, against the real library or the remote one.
  `mt.m`: a triangle through Metal in the hosted system (with `gpu/xnu-cpu-metal/test/tri.metal`'s library).

## Build

On the machine with the GPU (Rust 1.100.0; a checkout of this repository with metal2vulkan fetched and patched as
`gpu/xnu-cpu-metal/scripts/fetch-sources.sh` does):

    cargo build --release --manifest-path ../xnu-cpu-metal/src/xnu-m2v-bridge/Cargo.toml
    ./build.sh server && ./xm2v-server 10.0.0.2:7001 libvulkan.so.1 /usr/share/vulkan/icd.d/nvidia_icd.json

(the address to listen on: the one the host with the macOS reaches this machine by).

On a Mac, into the bundle that goes on the system disk (the real library becomes `libxnu_m2v_local.dylib`, the one
that is either takes its name, the bundle is signed again):

    ./into-bundle.sh path/to/XnuCpuMetal.bundle

On the Linux host: `GPU=remote GPU_REMOTE=GPU_HOST:7001 scripts/xnulinux-boot.sh` (it builds and starts `xm2v-relay`).

## Only between machines that trust each other

There is no authentication and no encryption. Whoever can connect to `xm2v-server` uses the machine's GPU, and the
calls carry what is on the screen (window contents, the frames read back) in the clear. The server checks that a
message holds what it says before it acts on it, but it is not hardened against a hostile client. Give it an address
of a private network between the two machines, never a public one.

## Measured (c4a-standard-4 hosting, g2-standard-8 with an NVIDIA L4 in the same zone, 0.4 ms apart)

- A Metal triangle at 1280x800 in the hosted system: 6.1 ms a frame on lavapipe, 0.10 ms here.
- A window moving on the desktop, a Screen Sharing viewer attached: 6.7 frames a second on lavapipe, 20.4 here.
  With no viewer: 57 to 59 (the same scene on a DGX Spark's own GPU: 104 to 107). WindowServer's main thread is then
  idle a third of the time and waits for the renderer's answers 13% of it; the frame's pixels coming back set the pace.
- 1000 frames of 100 draws that are not waited for: 0.11 ms and 8.5 KB each.

## Open

- Every display frame's pixels are still read back into the hosted system, and with a Screen Sharing viewer a second
  copy of the frame for it: two command buffers a swap, each waited for and read back. A read-back sends only the 4 KB
  pages that differ from what the destination holds (71% of a 4 MB frame while a window moves), which did not change
  the frame rate: 33 to 36 a second with a viewer either way, 57 to 61 without one.
- The library polls for answers (the bridge makes one host call at a time and none may wait): every 30 to 200 us while
  a call waits for one, and every 4 ms otherwise, for a shared event's notification. That is 250 host calls a second
  for each process with a Metal device that does nothing: about 5000 a second on a desktop of 20 such processes.
- Buffers a shader writes come back only where the call says so: a blit's destination, everything bound to a compute
  pass, a render pass's `useResource` with write. A buffer a vertex or fragment function writes through
  `setVertexBuffer`/`setFragmentBuffer` alone does not come back.
- A shared event's handle means something only in the server process that made it.
- A page the GPU wrote replaces the whole page in the process: a CPU write elsewhere on it since the last commit is lost.
- A failed call that is not answered is only logged by the server.
- `xm2v-server` is started by hand on the machine with the GPU.
