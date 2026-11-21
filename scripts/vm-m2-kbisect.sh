#!/bin/bash
# Inside the VM: run M2 with stop=999 (no stage stop) and kmax=K XNU kprintf lines, for each K.
cd ~/w/poc
make -s -C /lib/modules/$(uname -r)/build M=$PWD/fki-ko modules >/dev/null 2>&1
make -s -C /lib/modules/$(uname -r)/build M=$PWD/xnu-ko clean >/dev/null 2>&1
make -s -C /lib/modules/$(uname -r)/build M=$PWD/xnu-ko KBUILD_EXTRA_SYMBOLS=$PWD/fki-ko/Module.symvers modules >/dev/null 2>&1
sudo dmesg -n ${CONLEVEL:-8}
sudo rmmod xnu 2>/dev/null; sudo rmmod fki 2>/dev/null; sudo insmod fki-ko/fki.ko
bash scripts/vm-net-up.sh	# the hosted macOS's en0: xnu0, NAT, DHCP/DNS
# a hosted XNU never unmounts its read-write root: check the host disk before each boot
if [ -n "$HOSTDISK" ] && [ "${HOSTDISK#/dev/}" = "$HOSTDISK" ]; then
  for t in 1 2 3; do r=$(sudo fsck.hfsplus -fy "$HOSTDISK" 2>&1 | tail -1); echo "fsck: $r"; case "$r" in *"appears to be OK"*) break;; esac; done
fi
# XNU's DRAM is one physically contiguous block (GBs): free the page cache and compact first, or the allocation fails
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null; echo 1 | sudo tee /proc/sys/vm/compact_memory >/dev/null
[ -n "${FB_DUMP:-}" ] && { : > "$FB_DUMP"; }   # xnu.ko writes the framebuffer into this existing file
for K in "$@"; do
  sudo dmesg -C
  echo ">>> kmax=$K"; sync
  sudo insmod xnu-ko/xnu.ko mode=3 stop=899 kmax=$K idle_max=${IDLE_MAX:-200} ram_mb=${RAM_MB:-128} ${IMAGE:+image=$IMAGE} ${RAMDISK:+ramdisk=$RAMDISK} ${TRUSTCACHE:+trustcache=$TRUSTCACHE} ${HOSTDISK:+hostdisk=$HOSTDISK hostdisk_rw=1} ${CONSOLE_IN:+console_in=$CONSOLE_IN} ${FB_DUMP:+fb_dump=$FB_DUMP} ${BOOTARGS:+bootargs=\"$BOOTARGS\"}
  echo "lines: $(sudo dmesg | grep -ac 'xnu\]')"
  sudo dmesg | grep -a "xnu\]\|XNU stage 4\|budget\|panic\|run ended" | tail -${SHOW:-4}
  sudo rmmod xnu
done
