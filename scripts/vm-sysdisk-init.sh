#!/bin/bash
# In the VM: rebuild tools/init and put /sbin/launchd and /sbin/hello into the existing system disk image.
set -euo pipefail
IMG=${IMG:-/var/tmp/sys.img}
cd ~/w/poc/tools/init; TC=~/w/dvm/toolchains/linux/bin26
for f in start:init hello:hello; do
  $TC/target-clang -target arm64-apple-macos14.0 -c ${f%%:*}.s -o ${f%%:*}.o
  $TC/target-clang -target arm64-apple-macos14.0 -nostdlib -static -e _start -Wl,-adhoc_codesign ${f%%:*}.o -o ${f##*:} 2>&1 | grep -v "directory not found" || true
done
sudo fsck.hfsplus -fy $IMG 2>&1 | tail -1
sudo mkdir -p /mnt/sys; sudo mount -o loop,rw -t hfsplus $IMG /mnt/sys
sudo cp init /mnt/sys/sbin/launchd; sudo cp hello /mnt/sys/sbin/hello; sudo chmod 755 /mnt/sys/sbin/launchd /mnt/sys/sbin/hello
ls -la /mnt/sys/sbin /mnt/sys/private/var/select; sudo umount /mnt/sys
