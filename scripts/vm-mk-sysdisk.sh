#!/bin/bash
# In the VM: an HFS+ system disk image for the host-disk root (/var/tmp/sys.img): Apple's dyld, the dyld shared cache,
# a few /bin tools (from /var/tmp/sys.tar, made on the macOS host; Apple binaries stay local, never in the repo) and the test init.
set -euo pipefail
IMG=${IMG:-/var/tmp/sys.img}
cd ~/w/poc/tools/init && bash vm-install.sh >/dev/null 2>&1 || true
sudo umount /mnt/sys 2>/dev/null || true
rm -f $IMG; truncate -s ${SIZE:-16G} $IMG
mkfs.hfsplus -v xnulinux-sys $IMG >/dev/null
sudo mkdir -p /mnt/sys; sudo mount -o loop -t hfsplus $IMG /mnt/sys
sudo tar xf /var/tmp/sys.tar -C /mnt/sys --warning=no-unknown-keyword
sudo mkdir -p /mnt/sys/sbin /mnt/sys/dev /mnt/sys/private/var/select /mnt/sys/private/tmp /mnt/sys/System/Library /mnt/sys/usr/lib
sudo ln -sf private/var /mnt/sys/var; sudo ln -sf private/tmp /mnt/sys/tmp
sudo ln -sf /bin/bash /mnt/sys/private/var/select/sh
[ -e /mnt/sys/System/Library/dyld ] || sudo ln -sf /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld /mnt/sys/System/Library/dyld
sudo cp ~/w/poc/tools/init/init /mnt/sys/sbin/launchd; sudo cp ~/w/poc/tools/init/hello /mnt/sys/sbin/hello
sudo chmod 755 /mnt/sys/sbin/launchd /mnt/sys/sbin/hello
sudo du -sh /mnt/sys; ls -la /mnt/sys /mnt/sys/bin
sudo umount /mnt/sys
