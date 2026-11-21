#!/bin/bash
# In the VM: a fresh copy-on-write view of the golden system disk for one hosted run, /dev/mapper/xnusys.
# A hosted XNU that dies mid-write (or takes the host with it) leaves HFS+ corrupt; the golden image stays clean.
# NAME=xnuapfs IMG=/var/tmp/apfs.img COW=/var/tmp/apfs.cow: the same for the APFS disk (scripts/mk-apfs-disk.sh).
set -e
IMG=${IMG:-/var/tmp/full.img}; COW=${COW:-/var/tmp/full.cow}; NAME=${NAME:-xnusys}
sudo dmsetup remove $NAME 2>/dev/null || true
for l in $(losetup -j "$IMG" -O NAME -n) $(losetup -j "$COW" -O NAME -n 2>/dev/null); do sudo losetup -d "$l"; done
rm -f "$COW"; truncate -s ${COW_SIZE:-40G} "$COW"
B=$(sudo losetup -f -r --show "$IMG"); C=$(sudo losetup -f --show "$COW")
sudo dmsetup create $NAME --table "0 $(sudo blockdev --getsz "$B") snapshot $B $C N 16"
sudo chmod 666 /dev/mapper/$NAME 2>/dev/null || true
echo "$NAME over $B (cow $C): $(sudo blockdev --getsize64 /dev/mapper/$NAME) bytes"
