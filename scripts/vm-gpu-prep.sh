#!/bin/bash
# in the VM: Metal plugin bundle onto the golden system disk, kernel collection with XnuCpuMetal + IOGraphicsFamily
set -e -o pipefail
IMG=/var/tmp/full.img
sudo dmsetup remove xnusys 2>/dev/null || true; for l in $(losetup -j $IMG -O NAME -n); do sudo losetup -d $l; done
sudo fsck.hfsplus -fy $IMG 2>&1 | tail -1
sudo mkdir -p /mnt/sys; sudo mount -o loop,rw,force -t hfsplus $IMG /mnt/sys
sudo mkdir -p /mnt/sys/Library/GPUBundles
sudo rm -rf /mnt/sys/Library/GPUBundles/XnuCpuMetal.bundle
sudo tar -C /mnt/sys/Library/GPUBundles --no-same-owner -xzf /var/tmp/XnuCpuMetal.bundle.tgz
sudo chown -R 0:0 /mnt/sys/Library/GPUBundles
sudo du -sh /mnt/sys/Library/GPUBundles/XnuCpuMetal.bundle
df -h /mnt/sys | tail -1
sudo umount /mnt/sys; sudo fsck.hfsplus -fy $IMG | tail -1
[ -n "${SKIP_REBUILD:-}" ] || bash ~/w/poc/scripts/vm-xnu-rebuild.sh 2>&1 | tail -25
