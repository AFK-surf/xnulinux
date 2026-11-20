#!/bin/bash
# Inside the VM: build fki.ko and xnu.ko, run M2a (XNU's arm_init in the XNU world, stages reported through FKI).
set -x
cd ~/w/poc
make -s -C /lib/modules/$(uname -r)/build M=$PWD/fki-ko modules 2>&1 | grep -v "compiler differs\|built by\|You are using\|pahole\|BTF\|built with" || true
make -s -C /lib/modules/$(uname -r)/build M=$PWD/xnu-ko clean >/dev/null 2>&1
make -s -C /lib/modules/$(uname -r)/build M=$PWD/xnu-ko KBUILD_EXTRA_SYMBOLS=$PWD/fki-ko/Module.symvers modules 2>&1 | grep -v "compiler differs\|built by\|You are using\|pahole\|BTF\|built with" || true
ls xnu-ko/xnu.ko fki-ko/fki.ko || exit 1
sudo dmesg -C
sudo rmmod xnu 2>/dev/null; sudo rmmod fki 2>/dev/null
sudo insmod fki-ko/fki.ko && sudo insmod xnu-ko/xnu.ko mode=2 stop=${STOP:-199}; echo "insmod rc=$?"
sudo dmesg | grep -v "^\[.*\] *\(x[0-9]\|Modules\)" | head -80
