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
 com.apple.endpointsecurity.endpointsecurityd com.apple.MobileSoftwareUpdate.CleanupPreparePathService ${PARK_MORE:-}"
sudo mount -o loop,rw,force -t hfsplus "$IMG" /mnt/sys || exit 1
D=/mnt/sys/System/Library/LaunchDaemons; P=/mnt/sys/private/var/xnulinux-parked
sudo mkdir -p $P
n=0; for j in $PARK; do if [ -e $D/$j.plist ]; then sudo mv $D/$j.plist $P/ && n=$((n+1)); fi; done
echo "parked $n now; $(ls $P | wc -l) parked in all; $(ls $D | wc -l) jobs left"
sudo umount /mnt/sys
sudo fsck.hfsplus -fy "$IMG" 2>&1 | tail -1; sync
