# x86_64 port: feasibility and work plan

Started 2026-11-24 on the SteamOS desktop in `/home/deck/Documents/Default Project/xnulinux`.
This is a working plan, not a claim that the port works. Status of every claim below is marked
by what was actually checked.

## Verified starting state

- Host (checked live, 2026-11-24): `uname -m` = `x86_64`; `lscpu` = Intel Core i9-12900K, 24
  logical CPUs, VT-x; `free -h` = 62 GiB RAM; `/etc/os-release` = SteamOS 3.9.5 (holo),
  kernel `7.2.7-valve2-2-neptune-72-g31504582a073`. The `steamdeck` hostname and `valve2`
  kernel are SteamOS conventions, not ARM hardware.
- Space: 1.6 TiB free on `/home`, so user-local source trees and toolchains are fine.
- Host tools: `gcc 16.1.1`, `make`, `git` present. No system `clang-21`, no `qemu-aarch64`,
  no `aarch64-linux-gnu-gcc`. `/usr/lib/modules/$(uname -r)/build` is absent, so the
  running kernel's build tree had to be staged user-locally.
- Phase 0 result (2026-11-24): the exact headers package exists in SteamOS's own repo:
  `jupiter-3.9/linux-neptune-72-headers 7.2.7.valve2-2`. Downloaded from
  `https://steamdeck-packages.steamos.cloud/archlinux-mirror/jupiter-3.9/os/x86_64/linux-neptune-72-headers-7.2.7.valve2-2-x86_64.pkg.tar.zst`,
  extracted under `toolchain/kdir/`, copied to the space-free path
  `/home/deck/xnulinux-build/kdir` (the kernel make rejects paths containing spaces).
  A trivial module compiled and linked with `modinfo` reporting
  `vermagic: 7.2.7-valve2-2-neptune-72-g31504582a073 SMP preempt mod_unload`.
  BTF needs `pahole` 131; staged user-locally from the cached
  `pahole-1:1.31-2-x86_64.pkg.tar.zst` under `toolchain/pahole/`, with
  `LD_LIBRARY_PATH=.../toolchain/pahole/usr/lib`. No system files were changed.
- LLVM 21.1.8 x86_64 release asset `LLVM-21.1.8-Linux-X64.tar.xz` (1.87 GiB) downloaded
  and extracted under `toolchain/llvm/`; `clang --version` reports 21.1.8. `ld.lld` from
  that tarball fails with `libxml2.so.2: cannot open shared object file` on SteamOS:
  stage libxml2 user-locally if lld is needed.
- macOS SDK: DroidVM's pinned public `MacOSX26.1.sdk.tar.xz` downloaded, SHA-256
  `beee7212d265a6d2867d0236cc069314b38d5fb3486a6515734e76fa210c784c` matches the lock,
  extracted at `toolchain/sdks/MacOSX26.1.sdk`; `SDKSettings.json` reports version 26.1
  and `macosx` in `SupportedTargets`. XNU's README says the KDK is only required for
  Apple-silicon builds, so Intel should not need it.
- DroidVM's `compat/xnu-linux/scripts/setup-linux.py` builds cctools with
  `--target=aarch64-apple-darwin` and x86_64 tool prefixes are just a string change.
  A copy adapted to `x86_64-apple-darwin` + the macOS SDK is at
  `toolchain/setup-linux-x86_64.py`. `unifdef` 2.12 staged user-locally under
  `toolchain/unifdef/` for the XNU makefiles.
- Mach-O toolchain build (2026-11-24, complete for the host tools): `mig` (bootstrap_cmds
  138) and `cctools-port` at DroidVM's pinned commit (`e101a694...`) both built and
  installed for `--target=x86_64-apple-darwin` under
  `/home/deck/xnulinux-build/macho-out/toolchain`. The assembler, `ld64`, `otool`, `nm`,
  `lipo`, etc. are present. `x86_64-apple-darwin-ld -arch x86_64` successfully linked a
  smoke-test object into a Mach-O 64 header (`cputype 16777223`). `-lSystem` cannot be
  used because the SDK ships `.tbd` stubs and this build configured `--disable-tapi-support`
  (DroidVM does the same); link with explicit objects/dylibs instead.
  SteamOS-specific build fixes, all in `toolchain/setup-linux-x86_64.py`:
  the kernel make rejects paths with spaces → all make/configure work uses the symlinked
  space-free tree `/home/deck/xnulinux-build`; `autoreconf`/`configure` cannot quote a
  `-I` path with spaces → UAPI headers staged under `/home/deck/xnulinux-build/api`;
  adding `api/asm` as a top-level include shadowed glibc's `<errno.h>` and broke `mig`
  with "errno undeclared" → removed; `/usr/include/linux/errno.h` is absent on this
  immutable-root install → `linux-api-headers 7.1-1` staged user-locally; glibc has no
  `reallocf()` and libbsd headers are absent → `libbsd 0.12.2-2` headers staged
  user-locally; cctools' autoconf C++ sanity check needs `/lib/cpp`, absent here →
  `CPP=<llvm>/clang++ -E`; `ld64` built against system GCC 16's libstdc++ aborted on an
  `stl_vector.h` assertion → `libc++/libc++abi 22.1.8-1` staged and the C++ tools built
  with `-stdlib=libc++` (the LLVM tarball's duplicate bundled libc++ headers had to be
  moved aside so `include_next <math.h>` reaches glibc). `args.*.resolve()` was replaced
  with `.absolute()` so the space-free paths survive into configure command lines.
- Initial XNU blocker analysis (superseded by the local workarounds recorded below): the
  pinned XNU source uses AppleClang typed-allocation builtins/attributes, needs an `iig`
  for DriverKit interfaces, and links Apple kernel runtimes. LLVM 21.1.8 has no such
  builtins, no Linux-runnable `iig` was staged, and the base SDK has no macOS kernel
  runtimes. These were worked around locally; they are no longer compile gates.
- Upstream requirement: arm64 host with `FEAT_PAuth` (PAC), 4K pages, 8 GiB reserved for the
  hosted kernel, plus a Mac with Xcode to make the system disk and build GPU parts.
- Upstream position (issue #10, 2026-11-24): maintainer says "no fundamental reason why
  xnulinux should not work for x86_64 macOS", not a priority. So a port is welcome in
  principle, but unsupported.
- Apple's pinned `xnu-12377.121.6` tag **does** contain `osfmk/i386/` and `osfmk/x86_64/`
  (GitHub API listing checked 2026-11-24). The x86_64 kernel itself is not the obstacle.
- Upstream CI (`modules.yml`) builds `fki.ko` and `xnu.ko` only on `ubuntu-24.04-arm`
  against generic ARM64 headers. There is no x86_64 module build path today.
- DroidVM's `scripts/setup-env.py`, which the project uses to build the kernel, is
  arm64e-specific: `XNU_ARCH=arm64e`, iPhoneOS 26.5 SDK, KDK headers, `ArmCpu`/`ArmDTPlatform`,
  `gunyah-linux.mk`, a Darling container for `ld-classic`. The `vm-xnu-build.sh` script
  patches it only for an **aarch64 host running an arm64 target**; it does not make an
  x86_64 target.

## Compile-port status (2026-11-24, verified)

Work is on branch `x86_64-port` in this repo; nothing has been pushed or loaded into the
kernel. Both modules now compile and link against the exact running Valve kernel headers.
The build command used the space-free copy under `/home/deck/xnulinux-build/modules` and
user-local `pahole` 1.31 on `PATH`:

```
make -C /home/deck/xnulinux-build/kdir M=/home/deck/xnulinux-build/modules/fki-ko modules
make -C /home/deck/xnulinux-build/kdir M=/home/deck/xnulinux-build/modules/xnu-ko \
     KBUILD_EXTRA_SYMBOLS=/home/deck/xnulinux-build/modules/fki-ko/Module.symvers modules
```

Result: `fki.ko` and `xnu.ko` both link with `BTF [M]` and no compile errors. The only
remaining compiler diagnostic is the pre-existing warning about calling
`xnu_world_upcall` through a non-compatible function type. The in-tree
`linux/drivers/fki/fki.c` was also compiled as an object against the same headers
(`make -C ... M=... fki.o`); it has no module metadata by design, so a full module link
is not applicable. After the final XNU-side repairs, `sync.sh` and both module builds
were rerun successfully; the log is
`/home/deck/xnulinux-build/modules-rebuild-after-link.log`.

What was changed, and what it means:

- `fki-ko/fki_mod.c`: ARM-only includes, PAC key switching, FP/SIMD and generic-timer
  calls are guarded by `CONFIG_ARM64`. On x86_64 the PAC key blob stays ABI-sized but is
  zeroed/inert; FPU state is flushed with `kernel_fpu_begin/end()`, the counter is
  `ktime_get_ns()` at 1 GHz, `flush_tlb_all()` is resolved through `kallsyms` (x86 hides
  and does not export it to modules), and fault kprobes read x86 `pt_regs` SysV argument
  registers. The ARM alternate stack is not needed; Linux code runs on the current task
  stack. `fki_cpu_mpidr()` returns the Linux CPU id as the stable slot identity.
- `xnu-ko/world_x86.S` plus `xnu-ko/Makefile`: on x86_64 the AArch64 `world.S` is replaced
  by assembly stubs with `ENDBR`/return-thunk annotations. `xnu_world_call()` is a C stub
  in `xnu_main.c` so the compiler applies retpolines. This is a **compile-only** world;
  it does not switch CR3/PCID, GS/FS, or PAC keys and cannot host XNU.
- `xnu-ko/macho.c`: pointer-authentication signing is a no-op on x86_64; the rest of the
  chained-fixup parser is unchanged.
- `xnu-ko/xnu_main.c`: inline AArch64 system-register and `x18`/SCS access is guarded;
  per-CPU slots come from `smp_processor_id()`. Mode 2's ARM L1/L2 bootstrap window now
  returns `-ENOSYS` on x86_64 instead of installing ARM page-table descriptors.
- `xnu-patches/include/linux64_abi.h`: `LINUX64_CPU_SLOT()` has an x86_64 branch that
  masks the CPU id. All enum values and struct layouts are unchanged.
- `linux/drivers/fki/fki.c`: the in-tree driver got the same PAC/timer guards, inert
  x86 key blob, `ktime_get_ns()` counter, and `kernel_fpu_begin/end()` call on entry.

This is a **compile port, not a boot port**. The XNU-side LINUX64 machine-layer patch is
still AArch64, the fault trampoline has no x86 IRET path, and `world_x86.S` does not switch
CR3/PCID, GS/FS or PAC state. Phase 1 did produce an x86_64 XNU Mach-O kernel, but only
with the local shims described next.

## Phase 1 result (2026-11-24, verified build with local shims)

XNU itself has the x86_64 path: `makedefs/MakeInc.def` lists `X86_64`, `config/MASTER.x86_64`
exists, and `osfmk/i386/` plus `osfmk/x86_64/` are populated. The upstream command from
`xnu-src/README.md` is `make SDKROOT=macosx ARCH_CONFIGS=X86_64 KERNEL_CONFIGS=RELEASE`.
DroidVM's `build-linux.py` is **not** reusable for this target: it pins
`arm64-apple-ios17.0`, `XNU_ARCH=arm64e`, `ARM64` and `BCM2837`.

The reproducible local path is `/home/deck/xnulinux-build/prepare-xnu-tree.sh` followed
by `JOBS=1 /home/deck/xnulinux-build/build-xnu.sh`. The wrapper sets the x86_64 Apple
target (`GUNYAH_APPLE_TARGET=x86_64-apple-macos26.1`) and passes `MAKEJOBS="--jobs=$JOBS"`
so `JOBS=1` serializes XNU's nested makes. Earlier failures are kept in
`xnu-phase1.log` through `xnu-phase1s.log`; the final green log is `xnu-phase1u.log`.

Local repairs collected in `prepare-xnu-tree.sh` and `xnu-linux.mk`:

- `build_setup`: added an `availability.pl` shim, restored XNU's own `bsd/uuid/uuid.h`,
  staged libbsd include paths, `CodeSignature/Entitlements.h`,
  `os/firehose_buffer_private.h`, CoreEntitlements browser-engine defines, and the
  entitlement/TrustCache headers DroidVM normally takes from a KDK.
- Typed allocations: local `kalloc.h` macros bypass `__builtin_xnu_type_signature`,
  `__builtin_xnu_type_summary`, `__builtin_xnu_types_compatible` and
  `xnu_usage_semantics`. LLVM 21.1.8 still has none of them; this is a bypass, not an
  AppleClang-equivalent compiler.
- DriverKit/IIG: staged the SDK's `Kernel.framework/Headers/DriverKit` generated headers
  plus DroidVM's generated `IOUserServer.h`/`.iig.cpp`, used an `IIG` override, disabled
  the test-only `TestDextRematch`, and removed a duplicate standalone `Panic_Impl`
  declaration.
- Stale objects: deleted objects whose `LC_BUILD_VERSION` platform was not `1` (macOS);
  earlier attempts had left platform-7 iOS-simulator objects behind.
- Link-only runtime stubs: built local `libfirehose_kernel.a` (`__firehose_buffer_create`,
  tracepoint reserve/flush, configuration validation, update merge) and `libcc_kext.a`
  (`___cxa_atexit`, `___llvm_profile_get_size_for_buffer_internal`,
  `___llvm_profile_write_buffer_internal`). Clang's Darwin driver drops `-lcc_kext` under
  `-nostdlib`, so `LD_KERNEL_LIBS` now names the archive by absolute path. These are
  link-only shims; no runtime correctness is claimed.
- Post-link checks: `kextsymboltool` writes via `rename(2)`, which failed against
  `/dev/null`; `config/Makefile` now writes `$(TARGET)/allsymbols.check` for the two
  export checks.

Verified result:

```
$ file BUILD/obj/DEVELOPMENT_X86_64/kernel.development
Mach-O 64-bit x86_64 executable, flags:<NOUNDEFS|PIE>
$ stat -c %s BUILD/obj/DEVELOPMENT_X86_64/kernel.development
24739064
$ otool -l ... | grep -A4 LC_BUILD_VERSION
platform 1
   minos 26.1
```

`grep -a -c 'error:' /home/deck/xnulinux-build/xnu-phase1u.log` reports `0`, and make
exits `0` after the kernel link, dSYM generation and all symbol-set checks. This proves
the pinned XNU source can be built for x86_64 on this host. It is **not** a pristine
Apple-toolchain build and says nothing about booting: the runtime libraries are stubs and
the hosted machine layer is still ARM64.

## Golden Gate disk source (2026-11-24, verified inventory)

Donnie has two downloads:

- `/home/deck/Downloads/InstallAssistant.pkg` — Apple flat package, identifier
  `com.apple.pkg.InstallAssistant.macOSGoldenGate`, version `26.1.131`, containing
  `Install macOS 27 Golden Gate.app`. This is the useful one.
- `/home/deck/Downloads/InstallOS.dmg` — Sierra 10.12 installer (`Install macOS`), XNU
  3789/Darwin 16. This is too old and is not being used.

The Golden Gate package was extracted user-locally to
`/home/deck/xnulinux-build/macos-installer/` with `bsdtar` (no sudo, no system install).
Its `SharedSupport.dmg` contains a `com_apple_MobileAsset_MacSoftwareUpdate` asset; the
large asset was extracted to `asset.zip`. Inside it,
`AssetData/boot/SystemVersion.plist` reports `ProductVersion 27.2.1` and
`ProductBuildVersion 26B131`, and `AssetData/boot/` has `kernelcache.release.mac15j` and
`kernelcache.release.mac16j`. Verified 2026-11-24 by unwrapping their IM4P payloads: both
are Mach-O 64-bit **arm64e**, filetype 12 (FILESET), not x86_64. The installer is still the
correct generation for the `xnu-12377.121.6` source, but its kernelcaches are
Apple-silicon. This corrects the earlier note that called them Intel kernelcaches.

This is **not yet a bootable system disk**, and there is **no proven Linux-only path** to
make one from this installer. Two independent blockers were verified on 2026-11-24:

1. **The payload cannot be decoded on Linux.** `AssetData/payloadv2/payload.*` is PBZM /
   LZRaven, not PBZX. Linux `ipsw` v3.1.751 (staged user-locally at
   `/home/deck/xnulinux-build/tools/ipsw`) refuses it with "this OTA uses LZRaven (pbzm)
   compression, which this host cannot decode; extract it on macOS 27 or newer". Decoding
   needs macOS 27's `aa` / `libParallelCompression`.
2. **Nothing on Linux yet assembles a bootable macOS disk — narrowed, not eliminated.**
   `go-apfs-v2/pkg/apfswrite` creates only a static single-volume container. On 2026-11-24
   Donnie pointed to `https://github.com/NSSpiral/libdmg-apfs`; it was staged at
   `/home/deck/xnulinux-build/tools/libdmg-apfs`, built user-locally against staged
   zlib/json-c headers, and its suite passed 221/221 tests. It creates multi-volume APFS
   containers with system/data/preboot roles, reads UDIF/IMG4/AEA and writes
   UDIF/IMG4/raw, verifies real images, and can generate trust caches, mtree and root
   hashes. The decrypted BaseSystem and main OS DMGs both verify OK; a generated BaseSystem
   trust cache matched Apple's byte-for-byte after the 20-byte UUID header. The tool itself
   supplies no boot files and cannot decode PBZM/LZRaven installer payloads or export native
   manifests from Apple volumes that use `lzbitmap` resource forks. Golden Gate has
   **no verified usable x86_64 kext/boot set** — Tahoe 25G342 donor kexts remain mandatory.
   The verified Tahoe Intel files are recorded separately below.

`hao-patcher` is the only documented end-to-end route, but it still needs a Mac and is
blocked upstream right now: both `hao-assets` and `hao-patcher` releases are empty, the
documented `hao` URL 404s, and issue #1 reports missing `embed/stubs/*.stub`.

The IPSW alternative (`UniversalMac_27.2.1_26B131_Restore.ipsw`, SHA256
`233e85a09887579d47d0b195e7db72be7f204261059c6946f719acf6b300814f`) is a universal restore
image with 180 build identities. Verified 2026-11-24:
- `BuildManifest.plist` maps its nine DMGs to `OS`, `BaseSystem`, `Cryptex1,SystemOS`,
  `Cryptex1,AppOS`, `Cryptex1,RosettaOS`, `RestoreRamDisk`, and `Ap,ExclaveOS`; it includes
  `VirtualMac2,1` in `SupportedProductTypes`.
- `ipsw extract --fcs-key` and `ipsw fw aea` decrypted the AEA-encrypted
  `141-12293-176.dmg` SystemOS cryptex and the 10.5 GiB `141-12228-174.dmg.aea` OS DMG on
  SteamOS without sudo. The decrypted OS DMG is APFS and `7z` can enumerate its files, so
  Linux can read the payload contents locally.
- The `022-22150-178.dmg.aea` BaseSystem also decrypts with `ipsw fw aea --key`. The result is
  a 1.7 GiB GPT/APFS installer recovery disk containing `Install macOS 27 Golden Gate.app`.
  Its `com.apple.recovery.boot/PlatformSupport.plist` lists `VMM-x86_64`, but the extracted
  `InstallAssistant` is arm64, kext binaries are arm64e, and the dyld shared caches are
  `dyld_shared_cache_arm64e`; there is no `boot.efi` or kernelcache in the image.
- All 14 `kernelcache.release.*` IM4P payloads are Mach-O arm64/arm64e FILESET images, not
  x86_64. The `Cryptex1,SystemOS` payload likewise has only `dyld_shared_cache_arm64e` and
  ARM-named GPU bundles. The main OS DMG contains Intel-named kext paths but still lacks a
  verified x86_64 boot chain.
- This does not contradict hao-patcher's Darwin 27 x86_64 kernel input:
  `pipeline/inputs/25G342/darwin27_kernel` describes it as a Golden Gate 27.0 x86_64 kernel
  made by `tools/kernel-foundation make kernel`, not as a raw `kernelcache.release.*` file.
  Tahoe 25G342 is the pinned Intel donor for `BaseSystem-x86_64.dmg`, Intel kexts,
  Preboot/Recovery files and kernel-collection tools.
- Donnie's Tahoe donor package is `/home/deck/Downloads/InstallAssistant (1).pkg`. As of
  18:35 on 2026-11-24 its SHA256 is exactly hao's pinned
  `3d9551b7a18c1fa2f86e7002a132ec3db34d7915fa842cb1e890480b51be4ef3`. It is not itself a
  boot file, but it contains the Intel boot material. `PackageInfo` identifies
  `com.apple.pkg.InstallAssistant.macOSTahoe` version `25.6.342`; the embedded software
  update catalog reports OSVersion `26.7.3`, build `25G342`.
- User-local extraction of that package produced `SharedSupport.dmg` (SHA256
  `c621a5067b95395910c78ec47075dd00cf50849d763bff93e0da9c72b4cc7001`) and its embedded
  mobileasset zip `20a2020f65175d83a4598927ebfd1ddf399f2276.zip`. From the zip,
  `boot.efi` and `apfs.efi` are PE32+ x86_64 EFI executables; `BootKernelExtensions.kc` is
  a Mach-O 64-bit x86_64 FILESET with 204 entries including `com.apple.kernel`, AppleVirtIO,
  DiskImages, IONVMeFamily, networking and storage kexts. The extracted kernel entry is
  `Darwin Kernel Version 25.6.0 ... root:xnu-12377.161.15.701.48~2/RELEASE_X86_64`.
  The named `kernelcache.release.mac15j`/`mac16j`/`mac13j`/`mac16g`/`mac17j` payloads are
  still arm64e, so the useful Intel kernel is inside the x86_64 BootKC, not those files.
  The zip's `x86_64SURamDisk.dmg` is an APFS ramdisk carrying the same
  `BootKernelExtensions.kc`. This means Tahoe **does** supply a verified x86_64 boot chain
  and kernel/kext collection; the remaining disk blocker is assembling and finalizing a
  Golden Gate/Tahoe hybrid image, not finding Intel boot files.
- The decrypted DMGs are restore payloads, not a finalized APFS disk. There is no signed x86_64
  boot chain or complete Linux-side disk assembler in the IPSW. It supplies readable Apple
  inputs but does **not** remove the Mac-side step. A Mac must still produce or finalize a raw
  GPT/APFS image plus `mac.conf` and `trustcache.bin` (or provide an independently rehosted
  boot path).

## What has to change (ARM -> x86_64)

| ARM path in this repo | x86_64 replacement |
| --- | --- |
| `xnu-ko/world.S`: `pacia`/`pacib` keys, `ttbr0_el1`/`tcr_el1`, `mpidr_el1` slot, `tpidr_el0`/`tpidrro_el0`, `x18` SCS | New `world_x86_64.S`: callee-saved GPRs, `CR3`, `swapgs`/GS base, kernel stack, FPU/XSTATE, CET shadow stack if enabled; per-CPU slot from `smp_processor_id()`/GS, not MPIDR |
| `fki-ko/fki_mod.c` PAC swap and ARM exception-vector forwarding | x86_64 IDT entries (`#PF`, `#GP`, `#UD`, `#DB`, NMI) and x86 world-switch entry; remove PAC key handling or make it a no-op ABI field |
| `xnu-ko/macho.c` inline `pacia`/`pacib`/`pacda`/`pacdb` | Remove; x86_64 kernel collection has no PAC |
| `xnu-patches/0001-...patch` (2428 lines): ARM `pmap`, boot args, EL0 path, timers, traps | Port to `osfmk/x86_64/{pmap,trap,seg,i386_init,...}`; synthesize x86 boot args / memory map instead of ARM `boot_args_v2` |
| `linux64_el0_run` / user exception return | `sysret`/`swapgs` entry and syscalls via x86 MSR/IDT interception on the Linux side |
| CMA carve-out + `mem=` + `nokaslr` (arm64 EFI stub) | x86_64 boot-mem carve-out via `memmap=`/CMA; needs boot-parameter changes (root) and a kernel that keeps a contiguous block |
| arm64e kexts and kernel collection from an Apple Silicon macOS install | x86_64 kexts and collection from an **Intel** macOS install whose XNU version matches the kernel tree |
| `GPU=auto` virtio-gpu Venus path | Optional; x86 has real DRM, but `xnudrmd` currently only forwards virtio-gpu ioctls, so start with CPU rendering |

The ABI itself (`linux64_abi.h`, named host calls, one request struct per call) is
architecture-neutral and should be kept. That is the seam to preserve.

Status (2026-11-24): the host-call ABI, x86 `boot_args`, CR3/PML4 handoff, virtual
interrupt/idle stubs, console/upcall and the real x86 world switch are now implemented as
described below. The kernel-side IDT/GDT/TSS/GS setup is native on x86; Linux saves and restores
its own `CR3`/`IDT`/`GDT`/`TR`/GS state at each world transition. `xnu_ko` and `fki_ko` build
cleanly, but none of it has been loaded or runtime-verified. Fault trampoline scaffolding is
still an x86 stub and user entry is deferred.

## Hard blockers before a boot can be attempted

1. **Kernel build tree for the running Valve kernel.** Done for module builds: the exact
   headers package and `Module.symvers` for `7.2.7-valve2-2-neptune-...` are staged
   user-local. Do not modify the SteamOS root image or boot a different kernel on this daily
   driver without Donnie's say-so.
2. **Apple compiler/IIG/runtime fidelity.** Phase 1 is no longer blocked: local shims produce
   a Mach-O kernel. For boot, however, the typed-allocation builtins are bypassed rather than
   implemented, no real `iig` is used, and `cc_kext`/firehose are link-only stubs. A bootable
   build needs real Apple-compatible compiler/runtime pieces or validation of the stubs. The
   base-SDK gaps are bridged locally, not fixed in the SDK.
3. **An Intel macOS system disk.** Everything userland (kexts from Apple, trust cache,
   loginwindow) comes from Donnie's own installation. The repo's disk script assumes an
   Apple Virtualization macOS 27 VM; confirm an Intel-capable macOS release and installer
   exist for the chosen XNU tag. Without this, the last phase cannot be verified here.
   Donnie has `/home/deck/Downloads/InstallAssistant.pkg`, which is macOS 27 Golden Gate
   27.2.1 build 26B131 — the generation that uses `xnu-12377.121.6`. He also has
   `InstallOS.dmg`, which is Sierra 10.12 and is rejected as XNU 3789/Darwin 16.
4. **Loading modules.** `insmod` needs root; that is Donnie's step, not the agent's.

## Phases and exit criteria

- Phase 0 - user-local environment: stage LLVM 21, get a full kernel build tree for the
  running kernel, clone the pinned XNU tree. Exit: `make -C <KDIR> M=... modules` produces a
  trivial x86_64 test module that `modinfo` can read.
- Phase 1 - XNU x86_64 build feasibility: adapt the DroidVM toolchain pins to an x86_64
  target and bridge SDK gaps locally. Exit: a pinned `xnu-12377.121.6` x86_64 Mach-O kernel
  links and completes post-link symbol checks. Achieved 2026-11-24 (`xnu-phase1u.log`), with
  local shims; not a pristine Apple-toolchain build and not boot-tested.
- Phase 2 - hosted machine layer: port `xnu-patches/0001` to x86_64, keep `linux64_call`
  ABI. Compile exit achieved 2026-11-24: the x86 machine-layer patch builds and the linked
  kernel still exports `linux64_hook`. Runtime exit (reaching it under `insmod`) is pending.
- Phase 3 - Linux side: `fki.ko` x86_64 traps/world switch, `xnu.ko` x86_64 `world_x86.S`,
  PAC-free `macho.c`. Compile exit achieved 2026-11-24: both modules build cleanly against
  the exact Valve headers with zero warnings. Runtime exit (a test load reaching the first
  host call and producing a clean panic trace or idle) is pending and is Donnie's manual step.
- Phase 4 - devices and userland: x86_64 kexts, Intel macOS disk, framebuffer/input/network;
  GPU stays off. Exit: loginwindow on the hosted framebuffer.
- Phase 5 - optional: upstream a patch series if it reaches a stable early boot.

## Decision trail

- Checked the host first because the premise was ARM-only: `uname -m`/`lscpu` disproved ARM,
  so the choice became port-vs-ARM-target; Donnie chose the x86_64 port on 2026-11-24.
- Checked Apple's tag before writing a plan so the plan does not depend on a missing x86_64
  source tree; both `i386` and `x86_64` exist.
- Checked the module CI and DroidVM setup script; both are ARM-only, which is why phase 0 is
  toolchain work, not a one-line script change.
- Initial LLVM tarball URL (`llvmorg-21.1.0`, ubuntu-22.04) 404s; the working asset was found
  and staged as LLVM 21.1.8. The cctools/libbsd/libc++ fixes are documented above rather than
  hidden in the setup script.
- Phase 1 started with `build_setup` errors for `availability.pl` and `uuid/uuid.h`; probes
  then showed the typed-allocation builtins, `iig`, and kernel runtimes were also absent. The
  decisive path was to shim each gap in the space-free build tree instead of installing
  Apple CLT/Docker. Verification was the final Mach-O link plus zero `error:` lines and
  successful post-link export checks; the caveat remains that the stubs are link-only.

## x86_64 early-boot map (implemented 2026-11-24)

The map below was derived from read-only inspection, then implemented in the build tree.
ABI v3 in `xnu-patches/include/linux64_abi.h` stays unchanged (call numbers, struct
layouts, x86 slot branch). Hosted execution is no longer ARM64-shaped on x86:
`xnu_world_call()` resolves `xnu_worlds[this_slot()]`, `world_x86.S` performs a real
save/restore of Linux state and enters XNU through `fki_enter()`, and `world.h` has a
352-byte x86 save area beside the ARM64 one. The XNU side owns its IDT/GDT/TSS/CR3/%gs
while it runs; there is no Linux GS-dependent forwarded-fault path on x86.

First milestone — one CPU reaches XNU kernel init, installs kernel page tables, emits host
calls, then idles or panics cleanly:

1. **Host-call ABI**: rewrite `xnu-patches/include/linux64.h:38-73` — x86 CPU slot instead
   of `mrs MPIDR_EL1`, and a SysV indirect call (`rdi/rsi/rdx`, return in `rax`) instead of
   `blr`/x0-x2.
2. **x86 `boot_args`**: replace the ARM `boot_args_v2` builder at `xnu-ko/xnu_main.c:205-214,
   734-938` with the 4096-byte layout in `pexpert/pexpert/i386/boot.h:150-221`; populate
   `MemoryMap`, `kaddr/ksize/kslide`, `deviceTreeP`, `CommandLine`. Replace the `_arm_init`
   lookup at `xnu_main.c:1123-1128` with an x86 hosted entry feeding `vstart`/`i386_init`.
3. **Kernel-table handoff**: at `osfmk/x86_64/pmap.c:504-510` where `kernel_pmap->pm_cr3` is
   known, call `LINUX64_CALL_KERNEL_TABLES`; the host side (`xnu_main.c:621-649`) copies XNU
   PML4/PGD kernel-range entries via the existing x86 `fki_window_l1()` path in
   `fki-ko/fki_mod.c:725-765`, with a full TLB flush.
4. **Virtual interrupts / host yielding**: replace ARM `DAIF` handling with EFLAGS.IF in
   `osfmk/i386/machine_routines.c:367-401`; keep IF masked while XNU runs, track intent in
   `linux64_vint[slot]`, and call `LINUX64_CALL_PREEMPTED`.
5. **Idle/timer**: add a `linux64_cpu_idle()` analogue around `osfmk/i386/pmCPU.c:103-219`,
   calling `LINUX64_CALL_IDLE` then `rtclock_intr(FALSE)`.
6. **Console/KPRINTF/ASSERT/PANIC**: keep the existing host upcalls in `xnu_hook_body()`
   (`xnu_main.c:615-620,668-701`); success at this stage is a clean panic trace, not a hang.
7. **Faults**: implemented as native XNU handling on x86, not forwarding. `vstart` calls
   `vstart_idt_init(TRUE)` and XNU owns `IDT`/`GDT`/`TSS` while it runs; Linux's state is
   saved and restored by `world_x86.S` at every transition. `xnu_world_fault_abort` and
   `xnu_fault_tramp` remain x86 stubs until a real fault/trampoline path is needed.
8. **User entry** (`sysret`/`iretq`, `swapgs`, XSTATE) only after the kernel stage is stable.

Defer for the first pass: SMP/IPI, PV ticket locks, host devices, AMFI/SIP/trust cache,
macOS 27 syscalls, real x86 fault trampoline and GPU. `world_x86.S` and `world.h` now carry
the real x86 save area (callee-saved GPRs, `rsp`, Linux/XNU `CR3`, `IDT`/`GDT`/`TR`, both GS
bases, EFLAGS/return value); FPU/XSTATE is forgotten by `fki_enter()` rather than saved. Root
`insmod` remains Donnie's step; signature enforcement is off but root is still required.

## Immediate next actions

1. Keep `prepare-xnu-tree.sh` + `build-xnu.sh` as the reproducible phase 1 path. Do not call
   the result pristine or bootable; the builtins bypass, generated-header staging and link
   stubs are local workarounds.
2. The x86_64 machine layer has been applied through step 6 of the map above; the native
   IDT/GDT/TSS path replaces forwarded faults. Next, review the actual world-transition
   state and attempt a controlled first host call only after Donnie chooses to load the
   built modules. Keep rebuilding `fki.ko`/`xnu.ko` after each change.
3. Disk work now has a validated prototype but not a final Golden Gate system disk. Linux
   cannot decode PBZM/LZRaven payloads or create Apple's signed sealed volume-group metadata,
   and hao-patcher's releases are missing. A user-local Tahoe-x86_64-root disk boots to
   `launchd` in QEMU TCG, which proves the GPT/APFS/OpenCore path; the Golden Gate tree is still
   arm64-only. A macOS-side step is still needed for a finalized GG x86_64 disk, `mac.conf` and
   `trustcache.bin`.
4. Keep rebuilding `fki.ko` and `xnu.ko` after each XNU-side change. The latest builds are
   clean, with no warnings. Loading them is Donnie's manual root step; nothing here has been
   inserted into the running kernel.

## Disk/boot validation in user-local QEMU (2026-11-24)

QEMU 11.0.2 TCG was used **only** as a disposable sandbox to validate the GPT/APFS/OpenCore
path. It is not the port target: the target remains `fki.ko` + `xnu.ko` on the Intel SteamOS
host, with `insmod` left to Donnie. No sudo, host mount, module load, commit or push was used.

Built entirely under `/home/deck/xnulinux-build/disk-build`: an 80 GiB sparse GPT disk (ESP
EF00 at sectors 2048..526335, APFS AF0A at 526336..159909887), an OpenCore 1.0.5 ESP, a
five-volume APFS container (system/data/preboot/recovery/VM), and Tahoe 25G342 x86_64 boot
donors (`boot.efi`, `apfs.efi`, `BootKernelExtensions.kc`). `sgdisk -v`, `fsck.fat -n` and
`apfs-tool verify` are clean. OpenCore DEBUG binaries were used only while capturing the serial
log; the RELEASE binaries were restored afterward and both disk images were reassembled from
the verified ESP.

Failure chain and exact fixes:

1. **Wrong APFS partition type** `AF00` (HFS/HFS+) → changed to `AF0A` in `assemble_disk.sh`;
   `sgdisk -i 2` now reports GUID `7C3457EF-0000-11AA-AA11-00306543ECAC`.
2. **`OCB: System has no boot entries`**: OpenCore's AppleBootPolicy looks for
   `Preboot/<UPPERCASE-VolumeUUID>/System/Library/CoreServices/boot.efi`; Preboot is
   case-sensitive and our folders were lowercase. `add_preboot_volume_dirs.sh` now creates the
   uppercase System-UUID folder. The DEBUG log then showed `Found APFS booter` for all volumes
   and `OCB: Registering entry Macintosh HD`.
3. **Wrong root volume**: putting `boot.efi` in every volume folder made OpenCore boot the first
   (Preboot-UUID) entry, so boot.efi set `boot-uuid` to the Preboot volume. Keeping `boot.efi`
   only in the System-UUID folder fixed it: `rooting via boot-uuid from /chosen:
   368C57E1-2C56-4EE3-8238-AA5CA2E8187D`.
4. **`EBADARCH` on `/sbin/launchd` (errno 86)**: Golden Gate's userland is arm64e+arm64 only.
   Linux cannot extract x86_64 userland from the OTA payload (PBZM/LZRaven). Tahoe's
   `x86_64SURamDisk.dmg` does contain a self-contained x86_64 root (979 files; x86_64 `launchd`,
   `dyld` and `libSystem`). `populate_apfs_x86.sh` + `assemble_disk_x86.sh` built a separate
   `apfs-container-x86.raw` with that tree as the System volume, the same UUIDs and boot donors;
   the Golden Gate container is untouched.

**Result with the x86_64 root:** the Tahoe 25G342 x86_64 kernel boots from our disk, APFS
2811.160.7 loads, the System volume mounts RO as the root filesystem (`ROSV ... creating the
shadow fs_root`), and `/sbin/launchd` runs: `Darwin Ignition Sequence`, `hello from launchd.1`.
There is **no kernel panic**; the ramdisk's launchd shuts down cleanly at `preboot: failed to
open preboot mount point` because that tree has no firmlink for `/System/Volumes/Preboot`.

Still unresolved on Linux: no real APFS volume-groups B-tree (`nx_get_volume_group: volume groups
tree is not setup yet`), no forwarded root hash/manifest
(`apfs_extract_root_hash_and_manifest_x86 ... error 22`) and no sealed snapshot (`failed to find
named root snapshot: Need authenticator (81)`). `csr-active-config 0x843` includes
`CSR_ALLOW_UNAUTHENTICATED_ROOT`, but the kernel still probes the forwarded hash. The Golden Gate
system tree needs an x86_64 dyld shared cache and userland before it can replace the ramdisk root.

## Hosted x86 machine layer (2026-11-24, build-verified only)

The x86_64 machine layer is now applied in both halves of the project. `fki.ko` and `xnu.ko`
build from `/home/deck/xnulinux-build` against the exact `7.2.7-valve2-2-neptune-...` headers
with **zero warnings and zero errors**, and `xnu12377/BUILD/obj/DEVELOPMENT_X86_64/kernel.development`
rebuilds cleanly (`BUILD_RC=0`) with the generated patch matching the staged tree.

### XNU side

- Applied by `/home/deck/xnulinux-build/apply-linux64-x86.py`; generated patch:
  `xnu-patches/0006-linux64-x86-machine-layer.patch` (idempotent `/* LINUX64-X86 */` markers).
- `osfmk/i386/i386_init.c`: `vstart` keeps its own CR3, calls `vstart_idt_init(TRUE)`,
  installs GS magic, and calls `cpu_desc_init()`/`cpu_desc_load()`/`cpu_syscall_init()`.
- `osfmk/i386/trap.c`: native x86 trap/IDT path; `linux64_kernel_fault` interposition was
  removed after Donnie chose XNU-owned IDT.
- `osfmk/x86_64/pmap.c`: PML4/PDPT/kernel-table handoff area for the host copy.
- ABI v3 is unchanged: call numbers, struct layouts and `LINUX64_CPU_SLOTS 256` are preserved.
  ARM64 branches remain beside every x86 branch.

### Host side

- `xnu-ko/world.h`: 352-byte x86 `struct xnu_world`; offsets mirrored in assembly:
  `linux_cr3` 72, `linux_idt` 80, `linux_gdt` 96, `linux_tr` 112, `irq_flags` 120,
  `keys_saved` 128, `xnu_rbx` 216, `xnu_cr3` 288, `xnu_idt` 304, `xnu_gdt` 320, `xnu_tr` 336.
- `xnu-ko/world_x86.S`: saves Linux GPRs/RSP, `GS_BASE`, `KERNEL_GS_BASE`, `CR3`, `IDT`,
  `GDT` and `TR`, calls `fki_enter()`/`fki_leave()`, then enters XNU through the retpoline
  thunk. Each world-switch routine has its own expanded exit path so objtool sees a real
  return; the non-standard saved-frame functions are annotated.
- `xnu-ko/xnu_main.c`: x86 `boot_args` from the 4096-byte Apple i386 layout, `_vstart`
  virtual-address entry, x86 fileset/slide rejection, `run_m2b()` bootstrap window using
  `fki_window_l1()` and 2 MiB pages, CPU 0 binding via `fki_bind_cpu(0)`, and
  `xnu_world_call()`/`xnu_world_upcall()` resolving `xnu_worlds[this_slot()]`.
- `xnu_world_upcall()` must not call `this_slot()`: XNU's `%gs` is live when it invokes the
  host hook, so the boot CPU's `xnu_W` is used until secondary CPUs are supported.
- x86 DRAM must stay below 4 GiB because `boot_args::kaddr`/`MemoryMap` are 32-bit physical
  fields; `build_boot_x86()` rejects a region above that limit.
- PAC is a no-op on x86: `fki_enter()` ignores the keys pointer and `xnu_x86_no_keys` is the
  dummy. `xnu_world_fault_abort` and `xnu_fault_tramp` are stubs; no Linux GS-dependent fault
  forwarding exists.

### State and caveats

- Build artifacts: `fki.ko` 1.1 MiB, `xnu.ko` 560 KiB, XNU kernel 24,739,064 bytes.
- The last objtool warning (`return with modified stack frame`) was resolved by expanding the
  shared exit into each world-switch routine, adding a `ud2` after the noreturn abort call,
  and annotating only the two routines with the genuinely non-standard return frame.
- Nothing has been loaded. No IDT/GDT/TR write, `CR3` switch, `wrmsr` or `ltr` has executed on
  the host. Runtime verification of the world switch, upcall path and XNU early boot is the
  next real milestone and requires Donnie's manual `insmod` decision.

## First host run procedure (2026-11-24, ready for Donnie)

This is a bare phase-1 `kernel.development` smoke test, not a macOS disk boot. Do **not** use
`scripts/xnulinux-boot.sh` (arm64 full-system path). Every `sudo`/`insmod` step is Donnie's.

### Memory: no boot parameter, no reboot

The earlier `memmap=384M$312M` carve-out was dropped: it needed an edit to `/etc/default/grub`
and broke boot on this SteamOS box. fki now allocates the DRAM at load time with
`alloc_contig_pages(..., GFP_DMA32)` (x86 only), which places a power-of-two block below 4 GiB
(512 MiB for `ram_mb=256`, 2 MiB aligned) and migrates movable page cache out of the way.
`/proc/iomem` and the kernel command line are left alone. Load fki **without** `carve_base`/`carve_mb`.
If the allocation fails (`contiguous allocation failed`), free memory (`sync; echo 3 | sudo tee
/proc/sys/vm/drop_caches`) and retry; a fresh boot is the most reliable.

### Steps, in order

1. Stage the image and the firmware search path (the sysfs path resets every boot):

```bash
mkdir -p /home/deck/xnulinux-build/firmware
cp /home/deck/xnulinux-build/xnu12377/BUILD/obj/DEVELOPMENT_X86_64/kernel.development \
   /home/deck/xnulinux-build/firmware/kernel.development
printf '%s' /home/deck/xnulinux-build/firmware | \
  sudo tee /sys/module/firmware_class/parameters/path
lsmod | grep -E '^(fki|xnu) ' || echo 'fki/xnu not loaded'
```

2. Terminal A — clear and watch kernel logs:

```bash
sudo dmesg -C
sudo dmesg -w
```

3. Terminal B — load the helper, then the hosted kernel:

```bash
sudo insmod /home/deck/xnulinux-build/modules/fki-ko/fki.ko
```

```bash
sudo insmod /home/deck/xnulinux-build/modules/xnu-ko/xnu.ko \
  mode=2 image=kernel.development ram_mb=256 cpus=1 \
  kmax=200 idle_max=2000 assert_fatal=1 monitor_cpu=-1
```

`insmod xnu.ko` blocks while XNU runs; `kmax`/`idle_max` are the bounded-run guardrails.
Expected log fragments: `xnu: contiguous DRAM at phys 0x...` (below 0x100000000), `xnu: x86 bootstrap window mapped`,
`xnu: entering kernel`, then `xnu:`-prefixed XNU `kprintf` lines.

4. If it does not end itself, Terminal C:

```bash
echo 1 | sudo tee /sys/module/xnu/parameters/stop_run
```

`stop_run` is observed only at the next host call; if XNU hangs without one, reboot.

5. After `insmod` returns, unload and clear the firmware path:

```bash
sudo rmmod xnu
sudo rmmod fki
: | sudo tee /sys/module/firmware_class/parameters/path
```

### Failure signatures

- `cannot read image, err -2` — firmware path or `image=` name wrong.
- `contiguous allocation failed` — no free 512 MiB contiguous block in ZONE_DMA32; drop caches or reboot and retry.
- `x86 DRAM must be below 4 GiB` — the allocation did not land in DMA32; stop and report.
- `x86 window slot in use by Linux: 0` — stop; do not force it.
- Hang with no further `xnu:` lines — reboot; `stop_run` needs a host call to be seen.
