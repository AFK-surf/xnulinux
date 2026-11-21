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
# lavapipe's ICD manifest where the Vulkan loader looks in every process: it ignores VK_ICD_FILENAMES (the plugin's own
# pointer to the bundle's manifest) in processes like WindowServer ("Found no drivers!"), and searches only system
# directories such as /usr/local/share/vulkan/icd.d
sudo mkdir -p /mnt/sys/usr/local/share/vulkan/icd.d
printf '{"file_format_version":"1.0.1","ICD":{"library_path":"/Library/GPUBundles/XnuCpuMetal.bundle/Contents/Frameworks/libvulkan_lvp.dylib","api_version":"1.4.363"}}\n' | sudo tee /mnt/sys/usr/local/share/vulkan/icd.d/xnu_lvp_icd.aarch64.json >/dev/null
sudo du -sh /mnt/sys/Library/GPUBundles/XnuCpuMetal.bundle
df -h /mnt/sys | tail -1
sudo umount /mnt/sys; sudo fsck.hfsplus -fy $IMG | tail -1
[ -n "${SKIP_REBUILD:-}" ] || bash ~/w/poc/scripts/vm-xnu-rebuild.sh 2>&1 | tail -25
