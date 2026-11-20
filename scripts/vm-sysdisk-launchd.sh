#!/bin/bash
# In the VM: MODE=launchd puts macOS's own launchd (from /var/tmp/launchd.tar, made on the macOS host; Apple binaries stay
# local) at /sbin/launchd of the system disk; MODE=test puts the test init back.
set -euo pipefail
IMG=${IMG:-/var/tmp/sys.img}
sudo mkdir -p /mnt/sys; sudo mount -o loop -t hfsplus $IMG /mnt/sys
if [ "${MODE:-launchd}" = launchd ]; then
  sudo tar xf /var/tmp/launchd.tar -C /mnt/sys --warning=no-unknown-keyword
  sudo mkdir -p /mnt/sys/private/var/db /mnt/sys/private/var/run /mnt/sys/private/var/log /mnt/sys/private/etc /mnt/sys/Library
  [ -e /mnt/sys/etc ] || sudo ln -s private/etc /mnt/sys/etc
else
  sudo cp ~/w/poc/tools/init/init /mnt/sys/sbin/launchd
fi
ls -la /mnt/sys/sbin; sudo umount /mnt/sys
