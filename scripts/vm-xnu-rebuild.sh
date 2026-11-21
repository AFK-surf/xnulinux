#!/bin/bash
# Inside the VM: apply xnulinux's XNU patches to the k27 tree, rebuild the kernel incrementally, and (when the macOS 27.2
# kernelcache is there) relink the kernel collection with Apple's kexts. The kernel's segment slots inside the collection
# (k27/segaddrs.sh) follow the kernel's size: when kc27-layout.py moves them, the kernel is linked again.
set -e -o pipefail	# a failed kernel build stops here: never repackage the previous kernel
cd ~/w/dvm
export PATH=$PATH:/usr/lib/llvm-21/bin
T=out/k27/xnu
for p in ~/w/poc/xnu-patches/*.patch; do
  for f in $(grep '^+++ b/' $p | sed 's|^+++ b/||'); do git -C $T checkout -q -- $f 2>/dev/null || rm -f $T/$f; done
done
for p in ~/w/poc/xnu-patches/*.patch; do git -C $T apply $p; echo "applied $(basename $p)"; done
JOBS=12 bash k27/build-kernel27.sh 2>&1 | tail -15
if [ -e out/kc/kc27.bin ]; then
  # the hosted system's extra Apple kexts (in kc27, not kept by default): IOSurface for actool, CoreImage and friends
  for id in $(grep -v '^#' ~/w/poc/xnu-patches/kc-keep-extra.txt); do grep -qx "$id" configs/kc-keep.txt || echo "$id" >> configs/kc-keep.txt; done
  cp k27/segaddrs.sh /tmp/segaddrs.before
  python3 k27/kc27-layout.py out/kc/kc27.bin out/k27/kernel-k27.macho --write k27/segaddrs.sh | tail -2
  if ! cmp -s /tmp/segaddrs.before k27/segaddrs.sh; then
    echo "kernel slots moved: linking the kernel again"
    JOBS=12 bash k27/build-kernel27.sh 2>&1 | tail -3
  fi
  K27_NO_BOOT=1 NATIVE= bash k27/try.sh 0 2>&1 | tail -3
  sudo cp out/k27/kc-k27.bin /lib/firmware/xnu/kc.bin
fi
ls -la out/k27/kernel-k27.macho
sudo cp out/k27/kernel-k27.macho /lib/firmware/xnu/kernel.macho
