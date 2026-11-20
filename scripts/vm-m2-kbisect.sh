#!/bin/bash
# Inside the VM: run M2 with stop=999 (no stage stop) and kmax=K XNU kprintf lines, for each K.
cd ~/w/poc
make -s -C /lib/modules/$(uname -r)/build M=$PWD/fki-ko modules >/dev/null 2>&1
make -s -C /lib/modules/$(uname -r)/build M=$PWD/xnu-ko clean >/dev/null 2>&1
make -s -C /lib/modules/$(uname -r)/build M=$PWD/xnu-ko KBUILD_EXTRA_SYMBOLS=$PWD/fki-ko/Module.symvers modules >/dev/null 2>&1
sudo dmesg -n ${CONLEVEL:-8}
sudo rmmod xnu 2>/dev/null; sudo rmmod fki 2>/dev/null; sudo insmod fki-ko/fki.ko
for K in "$@"; do
  sudo dmesg -C
  echo ">>> kmax=$K"; sync
  sudo insmod xnu-ko/xnu.ko mode=3 stop=899 kmax=$K idle_max=${IDLE_MAX:-200} ram_mb=${RAM_MB:-128} ${IMAGE:+image=$IMAGE} ${RAMDISK:+ramdisk=$RAMDISK} ${HOSTDISK:+hostdisk=$HOSTDISK hostdisk_rw=1} ${BOOTARGS:+bootargs=\"$BOOTARGS\"}
  echo "lines: $(sudo dmesg | grep -ac 'xnu\]')"
  sudo dmesg | grep -a "xnu\]\|XNU stage 4\|budget\|panic\|run ended" | tail -${SHOW:-4}
  sudo rmmod xnu
done
