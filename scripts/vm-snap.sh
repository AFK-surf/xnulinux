#!/bin/bash
# In the VM: a fresh copy-on-write view of the golden system disk for one hosted run, /dev/mapper/xnusys.
# A hosted XNU that dies mid-write (or takes the host with it) leaves HFS+ corrupt; the golden image stays clean.
set -e
IMG=${IMG:-/var/tmp/full.img}; COW=${COW:-/var/tmp/full.cow}
sudo dmsetup remove xnusys 2>/dev/null || true
for l in $(losetup -j "$IMG" -O NAME -n) $(losetup -j "$COW" -O NAME -n 2>/dev/null); do sudo losetup -d "$l"; done
rm -f "$COW"; truncate -s ${COW_SIZE:-40G} "$COW"
B=$(sudo losetup -f -r --show "$IMG"); C=$(sudo losetup -f --show "$COW")
sudo dmsetup create xnusys --table "0 $(sudo blockdev --getsz "$B") snapshot $B $C N 16"
sudo chmod 666 /dev/mapper/xnusys 2>/dev/null || true
echo "xnusys over $B (cow $C): $(sudo blockdev --getsize64 /dev/mapper/xnusys) bytes"
