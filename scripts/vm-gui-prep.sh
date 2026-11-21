#!/bin/bash
# In the VM: make the golden full disk boot into a graphical session.
#  - loginwindow back in /System/Library/LaunchDaemons (earlier disks parked it). logind starts it when it opens the console
#    session at boot; with loginwindow absent then, logind's SOStartSessionWithOptions dies (_xpc_api_misuse) and no
#    later restart of logind or WindowServer opens the session again.
#  - one local administrator made here (never copied from the host): name GUI_USER (xnu), password GUI_PASSWORD (xnulinux),
#    uid 501, home from the system's own user template, member of admin and staff
#  - automatic login as that user (loginwindow's autoLoginUser plus /etc/kcpassword), and Setup Assistant marked done
#    for the system (.AppleSetupDone) and for the user, so the session goes straight to the desktop
set -e -o pipefail
cd "$(dirname "$0")/.."
IMG=${IMG:-/var/tmp/full.img}
USERNAME=${GUI_USER:-xnu}; PASSWORD=${GUI_PASSWORD:-xnulinux}; UID_=${GUI_UID:-501}
sudo dmsetup remove xnusys 2>/dev/null || true; for l in $(losetup -j $IMG -O NAME -n); do sudo losetup -d $l; done
sudo fsck.hfsplus -fy $IMG 2>&1 | tail -1
sudo mkdir -p /mnt/sys; sudo mount -o loop,rw,force -t hfsplus $IMG /mnt/sys
M=/mnt/sys
[ -e $M/private/var/xnulinux-parked/com.apple.loginwindow.plist ] && sudo mv $M/private/var/xnulinux-parked/com.apple.loginwindow.plist $M/System/Library/LaunchDaemons/
sudo python3 tools/hosted/gui-user.py $M "$M/System/Library/User Template" "$USERNAME" "$PASSWORD" "$UID_"
H=$M/Users/$USERNAME
echo "gui-prep: loginwindow $(ls $M/System/Library/LaunchDaemons/com.apple.loginwindow.plist 2>/dev/null | wc -l), user $USERNAME ($UID_), home $(sudo du -sh $H | cut -f1), autologin set"
sudo umount /mnt/sys; sudo fsck.hfsplus -fy $IMG 2>&1 | tail -1; sync
