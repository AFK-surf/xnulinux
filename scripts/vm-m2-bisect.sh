#!/bin/bash
# Inside the VM: run M2a with stop=S for each S given; report the last stage that came back cleanly.
cd ~/w/poc
make -s -C /lib/modules/$(uname -r)/build M=$PWD/fki-ko modules >/dev/null 2>&1
make -s -C /lib/modules/$(uname -r)/build M=$PWD/xnu-ko clean >/dev/null 2>&1
make -s -C /lib/modules/$(uname -r)/build M=$PWD/xnu-ko KBUILD_EXTRA_SYMBOLS=$PWD/fki-ko/Module.symvers modules >/dev/null 2>&1
sudo rmmod xnu 2>/dev/null; sudo rmmod fki 2>/dev/null; sudo insmod fki-ko/fki.ko
for S in "$@"; do
  sudo dmesg -C
  echo ">>> stop=$S"; sync
  sudo insmod xnu-ko/xnu.ko mode=${MODE:-2} stop=$S ram_mb=${RAM_MB:-128}
  sudo dmesg | grep -a "XNU stage\|XNU sub-stage\|run ended\|panic\|returned" | tail -3
  sudo rmmod xnu
done
