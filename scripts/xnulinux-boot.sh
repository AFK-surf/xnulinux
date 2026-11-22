#!/bin/bash
# In the VM: boot the hosted macOS. Builds fki.ko and xnu.ko against the running kernel (stops on a compile error, never
# boots stale modules), brings up the hosted system's network (xnu0) and GPU bridge (xnudrmd, when there is a render node),
# and loads xnu.ko on the disk mk-macvm-disk.sh made. Returns once XNU is running; xnu.ko stays loaded until the hosted
# system halts (or `sudo rmmod xnu`).
#
# Configuration: /var/tmp/mac.conf (written by mk-macvm-disk.sh: ROOT_UUID, BOOT_UUID), then the environment:
#   DISK (/var/tmp/mac.img)  RAM_MB (7900)  BOOTARGS  CONSOLE_IN (/var/tmp/console-in)  INPUT_IN (/var/tmp/xnu-input)
#   FB_DUMP (/var/tmp/xnu-fb.raw)  KEYSTORE (/var/tmp/xnu-keystore.bin)  TRUSTCACHE (xnu/trustcache-mac.bin)
#   IMAGE (xnu/kc.bin: the kernel collection under /lib/firmware)  GPU (auto|off)
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f /var/tmp/mac.conf ] && . /var/tmp/mac.conf
DISK=${DISK:-/var/tmp/mac.img}; RAM_MB=${RAM_MB:-7900}; GPU=${GPU:-auto}
CONSOLE_IN=${CONSOLE_IN:-/var/tmp/console-in}; INPUT_IN=${INPUT_IN:-/var/tmp/xnu-input}; FB_DUMP=${FB_DUMP:-/var/tmp/xnu-fb.raw}
KEYSTORE=${KEYSTORE:-/var/tmp/xnu-keystore.bin}; TRUSTCACHE=${TRUSTCACHE:-xnu/trustcache-mac.bin}; IMAGE=${IMAGE:-xnu/kc.bin}
BOOTARGS=${BOOTARGS:-amfi_get_out_of_my_way=1 lp-sip0=2050}
: "${ROOT_UUID:?no ROOT_UUID (/var/tmp/mac.conf from mk-macvm-disk.sh)}" "${BOOT_UUID:?no BOOT_UUID}"
lsmod | grep -q '^xnu ' && { echo "xnu.ko is loaded: a hosted system is running (sudo rmmod xnu first)" >&2; exit 1; }

K=/lib/modules/$(uname -r)/build
build() {	# a module; its compiler errors on failure
  local log; log=$(make -s -C "$K" M="$PWD/$1" ${2:-} modules 2>&1) || { echo "$log" | grep -E "error|Error" | head -20 >&2; exit 1; }
}
build fki-ko
build xnu-ko "KBUILD_EXTRA_SYMBOLS=$PWD/fki-ko/Module.symvers"
sudo dmesg -n "${CONLEVEL:-8}"
sudo systemctl stop xnudrmd 2>/dev/null || true	# it holds fki's /dev/xnu-hostcall
sudo rmmod fki 2>/dev/null || true
sudo insmod fki-ko/fki.ko
bash scripts/vm-net-up.sh

# the hosted system's files on the host: console and input queues, the framebuffer xnu.ko writes, the keystore
: > "$CONSOLE_IN"; : > "$INPUT_IN"; : > "$FB_DUMP"
rm -f "$KEYSTORE"; truncate -s 1M "$KEYSTORE"	# fresh each boot, as the disk was made (persisting it: production.md)
# XNU's DRAM is one physically contiguous block (GBs, from CMA): free the page cache and compact first. Right after the VM
# boots the allocation can still fail with the area free (pages not yet migratable): wait and try again.
# mode=3: the kernel collection; the run lasts until the hosted system halts (no stage stop, no line or idle budget).
# insmod returns when the run ends: it runs detached, its output in /var/tmp/xnu-insmod.log.
for try in 1 2 3 4; do
  sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null; echo 1 | sudo tee /proc/sys/vm/compact_memory >/dev/null
  sudo dmesg -C
  sudo setsid nohup insmod xnu-ko/xnu.ko mode=3 stop=899 kmax=1000000000 idle_max=2000000000 ram_mb="$RAM_MB" image="$IMAGE" \
    trustcache="$TRUSTCACHE" disk="$DISK" root_uuid="$ROOT_UUID" boot_uuid="$BOOT_UUID" preboot_uuid="$BOOT_UUID" \
    console_in="$CONSOLE_IN" input_in="$INPUT_IN" fb_dump="$FB_DUMP" keystore="$KEYSTORE" bootargs="\"$BOOTARGS\"" \
    > /var/tmp/xnu-insmod.log 2>&1 < /dev/null &
  sleep 5
  sudo dmesg | grep -aq "contiguous allocation failed" || break
  [ $try = 4 ] && { echo "no contiguous memory for XNU (CMA: $(grep CmaFree /proc/meminfo))" >&2; exit 1; }
  echo "no contiguous memory for XNU yet: trying again in 20 s"; sleep 20
done
if [ "$GPU" != off ] && [ -e /dev/dri/renderD128 ]; then
  make -s -C gpu/xnu-drm >/dev/null
  sudo systemctl stop xnudrmd 2>/dev/null || true
  sudo systemd-run -q --unit xnudrmd --collect "$PWD/gpu/xnu-drm/xnudrmd"
  echo "gpu: xnudrmd on /dev/dri/renderD128 (journalctl -u xnudrmd)"
fi
echo "booting: console scripts/xnu-console.sh, screen tools/hosted/fb2png.py $FB_DUMP"
