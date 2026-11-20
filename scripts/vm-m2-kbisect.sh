#!/bin/bash
# Inside the VM: run M2 with stop=999 (no stage stop) and kmax=K XNU kprintf lines, for each K.
cd ~/w/poc
make -s -C /lib/modules/$(uname -r)/build M=$PWD/fki-ko modules >/dev/null 2>&1
make -s -C /lib/modules/$(uname -r)/build M=$PWD/xnu-ko clean >/dev/null 2>&1
make -s -C /lib/modules/$(uname -r)/build M=$PWD/xnu-ko KBUILD_EXTRA_SYMBOLS=$PWD/fki-ko/Module.symvers modules >/dev/null 2>&1
sudo dmesg -n ${CONLEVEL:-8}
sudo rmmod xnu 2>/dev/null; sudo rmmod fki 2>/dev/null; sudo insmod fki-ko/fki.ko
# a hosted XNU never unmounts its read-write root: check the host disk before each boot
[ -n "$HOSTDISK" ] && sudo fsck.hfsplus -fy "$HOSTDISK" 2>&1 | tail -1
# XNU's DRAM is one physically contiguous block (GBs): free the page cache and compact first, or the allocation fails
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null; echo 1 | sudo tee /proc/sys/vm/compact_memory >/dev/null
for K in "$@"; do
  sudo dmesg -C
  echo ">>> kmax=$K"; sync
  sudo insmod xnu-ko/xnu.ko mode=3 stop=899 kmax=$K idle_max=${IDLE_MAX:-200} ram_mb=${RAM_MB:-128} ${IMAGE:+image=$IMAGE} ${RAMDISK:+ramdisk=$RAMDISK} ${HOSTDISK:+hostdisk=$HOSTDISK hostdisk_rw=1} ${CONSOLE_IN:+console_in=$CONSOLE_IN} ${BOOTARGS:+bootargs=\"$BOOTARGS\"}
  echo "lines: $(sudo dmesg | grep -ac 'xnu\]')"
  sudo dmesg | grep -a "xnu\]\|XNU stage 4\|budget\|panic\|run ended" | tail -${SHOW:-4}
  sudo rmmod xnu
done
