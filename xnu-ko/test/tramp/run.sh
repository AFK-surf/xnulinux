#!/bin/bash
# SPDX-License-Identifier: APSL-2.0
# xnu.ko's fault trampoline on a real kernel: a small module (main.c, context.S) enters xnu_fault_tramp, cut out of
# ../../world.S as it is, the way Linux's exception return enters it, with every FP/SIMD register, FPSR and FPCR set;
# a stand-in for xnu_fault_deferred writes all of them, and the context reports what it finds after the eret.
# On an arm64 Linux host of the project: root (sudo), fki.ko loaded and built in ../../../fki-ko, the kernel's
# headers. No hosted system is needed, and one must not be running (the module enters and leaves through fki as
# xnu.ko does). Exit status 0: every register came back; 1: not; 2: could not run.
set -u
D=$(cd "$(dirname "$0")" && pwd); P=$(cd "$D/../../.." && pwd); K=${KDIR:-/lib/modules/$(uname -r)/build}
[ -d /sys/module/fki ] || { echo "fki.ko is not loaded (sudo insmod fki-ko/fki.ko)" >&2; exit 2; }
[ ! -d /sys/module/xnu ] || { echo "a hosted system is running: not beside it" >&2; exit 2; }
[ -f "$P/fki-ko/Module.symvers" ] || { echo "no fki-ko/Module.symvers: build fki-ko first (make -C $K M=$P/fki-ko modules)" >&2; exit 2; }
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
cp "$D/main.c" "$D/context.S" "$D/Makefile" "$W/"; mkdir "$W/fki-ko"; cp "$P/fki-ko/fki.h" "$W/fki-ko/"
{ echo '/* SPDX-License-Identifier: APSL-2.0 */'; echo '	.text'
  awk '/^\t\.globl\txnu_fault_tramp/{f=1} f{print} /\.size\txnu_fault_tramp/{f=0}' "$P/xnu-ko/world.S"; } > "$W/tramp.S"
grep -q 'eret' "$W/tramp.S" || { echo "xnu_fault_tramp not found in xnu-ko/world.S" >&2; exit 2; }
log=$(make -s -C "$K" M="$W" KBUILD_EXTRA_SYMBOLS="$P/fki-ko/Module.symvers" modules 2>&1) && [ -e "$W/tramptest.ko" ] ||
  { echo "$log" | grep -iE "error|\*\*\*" | head -10 >&2; echo "the test module did not build" >&2; exit 2; }
sudo dmesg -C
sudo insmod "$W/tramptest.ko" 2>/dev/null	# (its init reports and returns an error: it never stays loaded)
out=$(sudo dmesg | grep -a "tramptest: " | sed 's/^\[[^]]*\] *//')
[ -n "$out" ] || { echo "the test module did not run (dmesg has no line of it)" >&2; exit 2; }
echo "$out"
echo "$out" | grep -q '^tramptest: ok$'
