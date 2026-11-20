#!/bin/bash
# Inside the VM: build fki.ko (GPL) and xnu.ko (non-GPL) against the stock Ubuntu kernel, load the source-built XNU.
set -x
cd ~/w/poc
make -s -C /lib/modules/$(uname -r)/build M=$PWD/fki-ko modules || exit 1
make -s -C /lib/modules/$(uname -r)/build M=$PWD/xnu-ko KBUILD_EXTRA_SYMBOLS=$PWD/fki-ko/Module.symvers modules || exit 1
modinfo -F license fki-ko/fki.ko xnu-ko/xnu.ko
sudo mkdir -p /lib/firmware/xnu && sudo cp ~/w/dvm/out/k27/kernel-k27.macho /lib/firmware/xnu/kernel.macho
grep -m1 Features /proc/cpuinfo | grep -o 'pac[ag]'
sudo dmesg -C
sudo rmmod xnu 2>/dev/null; sudo rmmod fki 2>/dev/null
sudo insmod fki-ko/fki.ko && sudo insmod xnu-ko/xnu.ko; echo "insmod rc=$?"
sudo dmesg | grep -v "^\[.*\] *\(x[0-9]\|Modules\)" | head -60
cat /proc/sys/kernel/tainted
