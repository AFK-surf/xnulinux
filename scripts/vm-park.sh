#!/bin/bash
# In the VM: park (move aside) launchd jobs on the golden full disk that need hardware this hosted system does not
# have, or crash-loop and eat its one CPU; then mark the volume clean for XNU (fsck -fy). Names are plist basenames.
set -u
IMG=${IMG:-/var/tmp/full.img}
PARK="com.apple.audiomxd com.apple.audio.coreaudiod com.apple.audio.AudioComponentRegistrar.daemon com.apple.audio.micactivityd
 com.apple.audio.systemsoundserverd com.apple.audioanalyticsd com.apple.historicalaudiod com.apple.usbaudiod
 com.apple.PerfPowerServices com.apple.PerfPowerServicesExtended com.apple.perfpowermetricd
 com.apple.bluetoothd com.apple.mobileactivationd com.apple.xprotectd com.apple.security.xprotectd com.apple.XProtect.daemon.scan com.apple.MRTd
 com.apple.systemstats.daily com.apple.systemstats.analysis com.apple.systemstats.microstackshot_periodic
 com.apple.endpointsecurity.endpointsecurityd com.apple.MobileSoftwareUpdate.CleanupPreparePathService
 com.apple.oahd com.apple.oahd-root-helper ${PARK_MORE:-}"
# Rosetta (oahd): the hosted kernel runs no x86_64 code ("Bad CPU type in executable"), oahd exits at start and launchd
# keeps its Mach service, so PackageKit's Rosetta cache step after every install (PKUpdateCambriaCacheOperation) waits
# on it forever. With the daemon parked the installer fails instead ("Could not connect to AOT daemon", "Translation of
# Intel binaries failed", PKInstallErrorDomain 129); with the Rosetta runtime moved aside too the disk looks like a Mac
# without Rosetta installed, and the installer skips that step.
sudo mount -o loop,rw,force -t hfsplus "$IMG" /mnt/sys || exit 1
D=/mnt/sys/System/Library/LaunchDaemons; P=/mnt/sys/private/var/xnulinux-parked
sudo mkdir -p $P
n=0; for j in $PARK; do for d in $D /mnt/sys/Library/Apple/System/Library/LaunchDaemons; do
  if [ -e $d/$j.plist ]; then sudo mv $d/$j.plist $P/ && n=$((n+1)); fi; done; done
if [ -d /mnt/sys/Library/Apple/usr/libexec/oah ]; then sudo mv /mnt/sys/Library/Apple/usr/libexec/oah $P/oah && n=$((n+1)); fi
echo "parked $n now; $(ls $P | wc -l) parked in all; $(ls $D | wc -l) jobs left"
sudo umount /mnt/sys
sudo fsck.hfsplus -fy "$IMG" 2>&1 | tail -1; sync
