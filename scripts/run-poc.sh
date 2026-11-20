#!/bin/bash
# Build xnu.ko against the host kernel, pack an initramfs (busybox + xnu.ko + the XNU image), boot it in QEMU TCG.
set -euo pipefail
P=$(cd "$(dirname "$0")/.." && pwd); W=${W:-/data/station/remote/sessions/bb931bdb925f109d18e36b92ae3422802e35c0a46561ce911a41789790c989b6/work}
O=$W/out/linux; R=$W/out/initrd; KIMG=${KIMG:-$W/dvm/out/k27/kernel-k27.macho}
make -s -C $W/src/linux ARCH=arm64 LLVM=-19 O=$O M=$P/xnu-ko modules
if [ ! -x $W/out/busybox ]; then
  sudo dpkg --add-architecture arm64; sudo apt-get update -qq
  (cd $W/out && apt-get download busybox-static:arm64 && dpkg-deb -x busybox-static_*_arm64.deb bb && cp bb/usr/bin/busybox busybox)
fi
rm -rf $R; mkdir -p $R/{bin,proc,sys,dev,lib/firmware/xnu,tmp}
cp $W/out/busybox $R/bin/busybox; for a in sh mount insmod rmmod dmesg cat poweroff sleep uname lsmod; do ln -s busybox $R/bin/$a; done
cp $P/xnu-ko/xnu.ko $R/xnu.ko
cp $KIMG $R/lib/firmware/xnu/kernel.macho
cat > $R/init <<'EOI'
#!/bin/sh
mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs dev /dev
echo "=== host: $(uname -a)"; echo "=== page size: $(getconf PAGESIZE 2>/dev/null || echo ?)"
grep -m1 Features /proc/cpuinfo
echo "=== insmod xnu.ko"; insmod /xnu.ko; echo "insmod rc=$?"
lsmod
echo "=== done"; poweroff -f
EOI
chmod +x $R/init
(cd $R && find . | cpio -o -H newc 2>/dev/null | gzip -1) > $W/out/initrd.gz
timeout ${QTIMEOUT:-900} qemu-system-aarch64 -M virt -cpu max,pauth-impdef=on -smp 2 -m 4G -nographic -no-reboot \
  -kernel $O/arch/arm64/boot/Image -initrd $W/out/initrd.gz -append "console=ttyAMA0 rdinit=/init panic=-1 cma=256M" | tee $W/out/poc-boot.log
