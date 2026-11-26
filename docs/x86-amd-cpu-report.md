# Ryzen 7 250: CPU observations for the x86 port

Measurements from Windows on an AMD Ryzen 7 250, for the investigation in
[#10](https://github.com/AFK-surf/xnulinux/issues/10). This is CPU feature data
and a comparison with the upstream XNU source, not an XNU boot result or a claim
of AMD support. xnulinux's hosted kernel currently targets arm64.

## Reproduce the CPU report

[`tools/cpu-probe.c`](../tools/cpu-probe.c) reads CPUID and, only when XSAVE and
OSXSAVE are advertised, XCR0 with `XGETBV(0)`. It does not need administrator
privileges, install a driver, load a kernel module or write control registers.
Its feature labels mean **advertised in the current execution environment**;
they do not check whether every instruction is usable in userspace or whether
XNU can use it.

The source uses a GCC-compatible `<cpuid.h>` and x86 inline assembly. Tested on
Windows with LLVM-MinGW Clang 22.1.7, target `x86_64-w64-windows-gnu`. From the
repository root in PowerShell:

```powershell
clang -std=c11 -O2 -Wall -Wextra -Werror tools/cpu-probe.c -o "$env:TEMP\xnulinux-cpu-probe.exe"
if ($LASTEXITCODE -ne 0) { throw 'CPU probe build failed' }
& "$env:TEMP\xnulinux-cpu-probe.exe"
```

For an x86-64 Linux host with GCC or Clang, the corresponding command is:

```sh
cc -std=c11 -O2 -Wall -Wextra -Werror tools/cpu-probe.c -o /tmp/xnulinux-cpu-probe && /tmp/xnulinux-cpu-probe
```

The Linux command is provided for comparison; the measurements below were taken
on Windows, without booting Linux. MSVC's `cl` is not a supported compiler for
this source.

## Measured environment

- Date: 2026-11-26.
- OS: Windows 11 Pro, build 26300.
- CPU vendor: `AuthenticAMD`.
- Brand: `AMD Ryzen 7 250 w/ Radeon 780M Graphics`.
- Signature: `0x00a70f52`; family `25` (`0x19`), model `117` (`0x75`), stepping `2`.
- CPUID hypervisor-present bit: set; hypervisor vendor: `Microsoft Hv`.

An independent query through .NET's `X86Base.CpuId(1, 0)` returned the same
signature. `.NET Avx2.IsSupported` was also `True`. The other instruction sets
below were identified from CPUID, not exercised individually.

| Observation | Current Windows execution environment |
|---|---|
| SSE2, SSSE3, SSE4.1, SSE4.2, CMPXCHG16B | Advertised |
| XSAVE, OSXSAVE, XSAVEOPT, XSAVEC, XSAVES | Advertised |
| AVX, AVX2, AVX512F | Advertised |
| FSGSBASE, INVPCID, SMEP, SMAP | Advertised |
| SYSCALL/SYSRET, NX, RDTSCP, invariant TSC | Advertised |
| CET shadow stack | Advertised |
| PCID, CET IBT, AMD SVM, Intel VMX | Not advertised |
| XCR0-supported mask, CPUID `0xd:0` EDX:EAX | `0xe7` |
| Enabled XCR0, read with `XGETBV(0)` | `0xe7` |
| XSAVE size for enabled components, CPUID `0xd:0` EBX | 2,432 bytes |
| XSAVE size for all supported XCR0 components, CPUID `0xd:0` ECX | 2,432 bytes |

The hypervisor matters: these are the features exposed to this Windows
environment. In particular, an absent SVM or PCID bit is not evidence that the
physical CPU lacks it, that firmware virtualization is disabled, or that Linux
would report the same result. Linux may also enable a different XCR0 mask and
therefore require a different XSAVE area size.

## Comparison with XNU

The project's XNU revision, `xnu-12377.121.6`, has two relevant conditions in
[`osfmk/i386/cpuid.c`](https://github.com/apple-oss-distributions/xnu/blob/xnu-12377.121.6/osfmk/i386/cpuid.c#L880-L965):

- `cpuid_set_info` checks the vendor against `CPUID_VID_INTEL` and panics with
  `Unsupported CPU` when it differs, or when the CPU family classification is
  unknown.
- `cpuid_set_cpufamily` classifies selected Intel models under family `6`.
  The measured AMD family `25` has no entry in that switch.

If a hosted x86 port reaches this unmodified path with the measured AMD
identity, the CPU support check would reject it. This is a source-level
observation; no XNU kernel was executed on this machine. Earlier initialization
also accesses Intel MSRs, so changing the identity check alone would not establish
AMD compatibility. MSR handling, cache/topology discovery, timers and the host
CPU-state transition still need architecture-appropriate treatment.

The XSAVE mask and size give a concrete input for reviewing future context
save/restore code. They should be queried in the execution environment rather
than copied from this report or inferred from an Intel model. The CPU report
does not test XSAVE/XRSTOR preservation, kernel exception handling, Linux KVM,
the FKI backend, or macOS applications.

## Raw CPUID sample

Taken with the probe on the environment above. The initial APIC ID in leaf 1's
EBX can vary when the process runs on another logical processor.

```text
CPUID 00000000:00 EAX=0000000d EBX=68747541 ECX=444d4163 EDX=69746e65
CPUID 00000001:00 EAX=00a70f52 EBX=06100800 ECX=fed8320b EDX=178bfbff
CPUID 00000007:00 EAX=00000001 EBX=f1bf97a9 ECX=00405fc6 EDX=00000010
CPUID 0000000d:00 EAX=000000e7 EBX=00000980 ECX=00000980 EDX=00000000
CPUID 0000000d:01 EAX=0000000f EBX=00000990 ECX=00001800 EDX=00000000
CPUID 80000000:00 EAX=80000027 EBX=68747541 ECX=444d4163 EDX=69746e65
CPUID 80000001:00 EAX=00a70f52 EBX=10000000 ECX=20c023f3 EDX=2fd3fbff
CPUID 80000007:00 EAX=00000000 EBX=0000001b ECX=00000000 EDX=0000e789
CPUID 80000008:00 EAX=00003030 EBX=7912d215 ECX=0000400f EDX=00010000
```

Feature-bit definitions can be cross-checked against Linux's
[`cpufeatures.h`](https://github.com/torvalds/linux/blob/master/arch/x86/include/asm/cpufeatures.h).
The hypervisor detection follows Microsoft's
[feature discovery documentation](https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/tlfs/feature-discovery).
