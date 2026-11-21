#!/bin/bash
# On the macOS host (tokyo), with no hosted XNU running from the disk: add what a graphical session needs to the golden
# full disk (/var/tmp/full.img in the xnupoc VM) that scripts/mk-fulldisk.sh leaves out. Apple's files stream from this
# host into the VM's image and stay there (never in the repo).
#  - the App cryptex (Safari and its helpers: /System/Volumes/Preboot/Cryptexes/App)
#  - /System/Applications (Finder's and the Dock's apps: System Settings, Terminal, Preview, ...)
#  - /System/Cryptexes/{OS,App}: the links a real Mac has to the cryptexes in Preboot. dyld finds the OS cryptex's own
#    dylibs (/System/Cryptexes/OS/usr/lib, e.g. libLaunchServicesSupport.dylib, which loginwindow and the Dock link)
#    only through this graft point; without it loginwindow stops at launch ("Library not loaded").
#  - /Applications/Safari.app, the link into the App cryptex
set -euo pipefail
cd "$(dirname "$0")/.."
V="bash scripts/vm.sh"
IMG=/var/tmp/full.img
$V "set -e; sudo dmsetup remove xnusys 2>/dev/null || true; for l in \$(losetup -j $IMG -O NAME -n); do sudo losetup -d \$l; done
    sudo fsck.hfsplus -fy $IMG 2>&1 | tail -1; sudo mkdir -p /mnt/full; sudo mount -o loop,rw,force -t hfsplus $IMG /mnt/full"
t0=$(date +%s)
cd /
sudo -n tar -c -f - --no-mac-metadata --no-xattrs --no-acls System/Volumes/Preboot/Cryptexes/App System/Applications 2> /tmp/mk-gui-extras.err \
  | bash ~-/scripts/vm.sh "sudo tar -x -p -f - -C /mnt/full --warning=no-unknown-keyword 2>&1 | tail -5" \
  || echo "host tar ended nonzero (see /tmp/mk-gui-extras.err)"
cd ~-
echo "streamed in $(( $(date +%s) - t0 ))s; host tar warnings: $(wc -l < /tmp/mk-gui-extras.err)"
LINKS="OS App"	# not Rosetta: the hosted system has no x86_64 support and presents itself as a Mac without Rosetta
$V "set -e; sudo mkdir -p /mnt/full/System/Cryptexes /mnt/full/Applications
    for c in $LINKS; do [ -e /mnt/full/System/Cryptexes/\$c ] || sudo ln -s ../../System/Volumes/Preboot/Cryptexes/\$c /mnt/full/System/Cryptexes/\$c; done
    [ -e /mnt/full/Applications/Safari.app ] || sudo ln -s ../System/Cryptexes/App/System/Applications/Safari.app /mnt/full/Applications/Safari.app
    ls -la /mnt/full/System/Cryptexes | tail -n +2; ls /mnt/full/System/Cryptexes/OS/usr/lib | head -3; ls -d /mnt/full/Applications/Safari.app/Contents/MacOS/Safari
    echo \"\$(ls /mnt/full/System/Applications | wc -l) apps in /System/Applications\"; df -h /mnt/full | tail -1
    sudo umount /mnt/full; sudo fsck.hfsplus -fy $IMG 2>&1 | tail -1; sync"
