#!/bin/bash
# Inside the VM: apply xnulinux's XNU patches to the k27 tree and rebuild the kernel incrementally.
set -e
cd ~/w/dvm
T=out/k27/xnu
for p in ~/w/poc/xnu-patches/*.patch; do
  for f in $(grep '^+++ b/' $p | sed 's|^+++ b/||'); do git -C $T checkout -q -- $f; done
done
for p in ~/w/poc/xnu-patches/*.patch; do git -C $T apply $p; echo "applied $(basename $p)"; done
JOBS=12 bash k27/build-kernel27.sh 2>&1 | tail -15
ls -la out/k27/kernel-k27.macho
sudo cp out/k27/kernel-k27.macho /lib/firmware/xnu/kernel.macho
