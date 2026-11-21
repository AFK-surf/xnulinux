#!/bin/bash
# On the macOS host (tokyo): the hosted system's APFS disk, /var/tmp/apfs.img in the xnupoc VM (xnu.ko disk=, kexts/XnuDisk).
# A whole disk as macOS makes one, made with Apple's own tools on this host: a GUID partition table and an APFS container
# with the system volume, filled with the golden full disk's tree (/var/tmp/full.img in the VM, HFS+, made by
# mk-fulldisk.sh, vm-gui-prep.sh and friends). Linux has no APFS writer; the hosted XNU's own apfs.kext mounts it.
# The image is sparse: built in a host file, then sent to the VM keeping its holes. Apple's files stay on this host and in
# that VM (never in the repo).
set -euo pipefail
cd "$(dirname "$0")/.."
V="bash scripts/vm.sh"
SIZE=${SIZE:-96g}; W=${W:-$PWD/../apfs-build}; IMG=$W/apfs.img; NAME=${VOLNAME:-xnulinux}
mkdir -p "$W"; rm -f "$IMG"; mkfile -n "$SIZE" "$IMG"
DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$IMG" | awk 'NR==1{print $1}')
cleanup() { sudo -n umount "$W/mnt" 2>/dev/null || true; hdiutil detach "$DEV" -force >/dev/null 2>&1 || true; }
trap cleanup EXIT
echo "image on $DEV"
diskutil partitionDisk "$DEV" GPT APFS "$NAME" 100% >/dev/null
diskutil list "$DEV"
VOL=$(diskutil list | awk -v n="$NAME" '$0 ~ "APFS Volume" && $0 ~ n {print $NF}' | tail -1)
CONTAINER=$(diskutil info "$VOL" | awk -F': *' '/APFS Container:/{print $2}')
echo "volume $VOL in container $CONTAINER"
diskutil unmount "$VOL" >/dev/null
mkdir -p "$W/mnt"; diskutil mount -mountPoint "$W/mnt" "$VOL" >/dev/null
sudo -n diskutil enableOwnership "$W/mnt" >/dev/null
t0=$(date +%s)
# the golden tree as the VM's Linux sees it (owners, modes, links; mk-fulldisk.sh wrote it without Mac metadata)
$V "set -e; sudo dmsetup remove xnusys 2>/dev/null || true; for l in \$(losetup -j /var/tmp/full.img -O NAME -n); do sudo losetup -d \$l; done
    sudo mkdir -p /mnt/fullro; sudo mount -o loop,ro -t hfsplus /var/tmp/full.img /mnt/fullro
    sudo tar -C /mnt/fullro --numeric-owner -cf - . ; sudo umount /mnt/fullro" \
  | sudo -n tar -C "$W/mnt" --numeric-owner -xpf - 2> "$W/tar.err" || echo "tar ended nonzero ($(wc -l < "$W/tar.err") lines in $W/tar.err)"
echo "copied in $(( $(date +%s) - t0 ))s"; tail -3 "$W/tar.err" || true
df -h "$W/mnt" | tail -1; ls "$W/mnt" | tr '\n' ' '; echo
sudo -n umount "$W/mnt"; hdiutil detach "$DEV" >/dev/null; trap - EXIT
t0=$(date +%s)
tar -C "$W" -cSf - apfs.img | $V "rm -f /var/tmp/apfs.img; tar -C /var/tmp -xSf -; ls -ls /var/tmp/apfs.img"
echo "sent in $(( $(date +%s) - t0 ))s"
