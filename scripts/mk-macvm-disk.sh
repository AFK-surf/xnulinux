#!/bin/bash
# On the macOS host (tokyo): the hosted system's disk from a macOS VM disk installed by Apple's own installer, then sent to
# the xnupoc VM as /var/tmp/mac.img (xnu.ko disk=, kexts/XnuDisk; boot-arg rd=<its system volume>).
#
# `tart create NAME --from-ipsw latest` installs macOS with Virtualization.framework, as Apple's own VMs are installed: the
# whole Apple Silicon layout (iBootSystemContainer with xART and Hardware, the main container with the System and Data
# volume group and Preboot with the cryptexes, the Recovery container). The sealed System volume stays as installed; what the
# hosted system needs is added to the Data volume only:
#  - the local user, automatic login, Setup Assistant done (tools/hosted/gui-user.py)
#  - the CPU Metal plugin in /Library/GPUBundles (the GPU line's dist/XnuCpuMetal.bundle)
#  - a root shell on /dev/console (xnulinux.shell), the hosted system's console
#  - launchd's disabled list for daemons of hardware the hosted system has not (watchdog, audio, ...) and Rosetta's
# and the static trust cache of that macOS build, for xnu.ko trustcache=. Apple's files stay on this host and in the VM.
set -euo pipefail
cd "$(dirname "$0")/.."
V="bash scripts/vm.sh"
SRC=${SRC:-$HOME/.tart/vms/xnumac/disk.img}; W=${W:-$PWD/../macvm}; IMG=$W/mac.img
GPU=${GPU:-/Users/admin/.stillfail/sessions/chat/c-73ef26e7b6/workspace/src/xnulinux/gpu/xnu-cpu-metal/dist/XnuCpuMetal.bundle}
DISABLE="com.apple.watchdogd com.apple.iomfb_bics_daemon com.apple.audiomxd com.apple.audio.coreaudiod com.apple.PerfPowerServices
 com.apple.PerfPowerServicesExtended com.apple.oahd com.apple.oahd-root-helper ${DISABLE:-}"
# images of ours left attached by an earlier run
for d in $(hdiutil info -plist | python3 -c 'import plistlib,sys,os
for i in plistlib.loads(sys.stdin.buffer.read()).get("images", []):
    if os.path.basename(i.get("image-path", "")) in ("disk.img", "mac.img"):
        print(*[e["dev-entry"] for e in i.get("system-entities", []) if "content-hint" in e and e["content-hint"] == "GUID_partition_scheme"])'); do
  hdiutil detach "$d" -force >/dev/null 2>&1 || true
done
mkdir -p "$W"; rm -f "$IMG"; cp -c "$SRC" "$IMG"	# an APFS clone of the installed disk: the installed one stays pristine
DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$IMG" 2>/dev/null | awk '/GUID_partition_scheme/{print $1}')
sleep 3	# the containers' synthesized disks appear after the attach returns
cleanup() { for m in "$W/cx" "$W/sysrw" "$W/data" "$W/sys" "$W/preboot"; do diskutil unmount force "$m" >/dev/null 2>&1 || true; done; hdiutil detach "$DEV" -force >/dev/null 2>&1 || true; }
trap cleanup EXIT
vol() {	# the APFS volume named $1 in the main container of this image (the names the installer gives)
  for v in $(diskutil list | awk '/APFS Volume/ {print $NF}'); do
    diskutil info "$v" | grep -q "APFS Physical Store: *$(basename "$DEV")s2$" || continue
    diskutil info "$v" | grep -q "Volume Name: *$1$" && { echo "$v"; return; }
  done
}
DATA=$(vol Data); SYS=$(vol "Macintosh HD"); PRE=$(vol Preboot)
echo "image on $DEV: system $SYS, data $DATA, preboot $PRE"
mkdir -p "$W/data" "$W/sys" "$W/preboot"
diskutil mount -mountPoint "$W/data" "$DATA" >/dev/null; sudo -n diskutil enableOwnership "$W/data" >/dev/null
diskutil mount readOnly -mountPoint "$W/sys" "$SYS" >/dev/null
diskutil mount -mountPoint "$W/preboot" "$PRE" >/dev/null; sudo -n diskutil enableOwnership "$W/preboot" >/dev/null
D=$W/data
# The system keybag the installer and the first boot made is sealed to the keys of the VM it ran in (Apple's virtual
# platform keystore, xART in that VM's auxiliary storage); the hosted keystore (kexts/XnuEAN) has its own, so
# applekeystored would wait on a bag it cannot open. Without one it makes a new bag on first boot, as after a restore.
echo "keybags: $(sudo -n ls "$D/private/var/keybags" 2>/dev/null | tr '\n' ' ')"
sudo -n rm -f "$D"/private/var/keybags/*
sudo -n python3 tools/hosted/gui-user.py "$D" "$W/sys/System/Library/User Template"
sudo -n mkdir -p "$D/Library/GPUBundles" "$D/Library/LaunchDaemons" "$D/private/var/db/com.apple.xpc.launchd"
sudo -n rm -rf "$D/Library/GPUBundles/XnuCpuMetal.bundle"; sudo -n ditto "$GPU" "$D/Library/GPUBundles/XnuCpuMetal.bundle"
sudo -n chown -R root:wheel "$D/Library/GPUBundles"
sudo -n D="$D" DISABLE="$DISABLE" python3 - <<'PY'
import os, plistlib
D = os.environ["D"]
shell = {"Label": "xnulinux.shell", "ProgramArguments": ["/bin/bash", "-i"], "RunAtLoad": True,
         "StandardInPath": "/dev/console", "StandardOutPath": "/dev/console", "StandardErrorPath": "/dev/console",
         "EnvironmentVariables": {"HOME": "/var/root", "LOGNAME": "root", "USER": "root", "SHELL": "/bin/bash", "TERM": "dumb",
                                  "PATH": "/bin:/usr/bin:/sbin:/usr/sbin", "PS1": "xnulinux# "}}
p = D + "/Library/LaunchDaemons/xnulinux.shell.plist"
plistlib.dump(shell, open(p, "wb")); os.chown(p, 0, 0); os.chmod(p, 0o644)
p = D + "/private/var/db/com.apple.xpc.launchd/disabled.plist"
disabled = plistlib.load(open(p, "rb")) if os.path.exists(p) else {}
disabled.update({label: True for label in os.environ["DISABLE"].split()})
plistlib.dump(disabled, open(p, "wb")); os.chown(p, 0, 0); os.chmod(p, 0o644)
print("console shell job, %d daemons disabled" % len(disabled))
PY
# The boot cryptexes' contents where dyld finds them without a graft: on a Mac, dyld in launchd grafts the OS and App
# cryptexes (Preboot/<group>/cryptex1/current/{os,app}.dmg) onto Preboot/Cryptexes/{OS,App} from the ignition blob
# AppleImage4 makes out of iBoot's boot object manifests; a hosted boot has neither, so the images' trees are copied in.
CX=$(ls -d "$W"/preboot/*/cryptex1/current | head -1)
for c in OS:os App:app; do
  mkdir -p "$W/cx"; hdiutil attach -readonly -nobrowse -mountpoint "$W/cx" "$CX/${c#*:}.dmg" >/dev/null
  sudo -n rm -rf "$W/preboot/Cryptexes/${c%%:*}"; sudo -n mkdir -p "$W/preboot/Cryptexes/${c%%:*}"
  sudo -n ditto "$W/cx" "$W/preboot/Cryptexes/${c%%:*}"
  hdiutil detach "$W/cx" >/dev/null
  echo "cryptex ${c%%:*}: $(sudo -n du -sh "$W/preboot/Cryptexes/${c%%:*}" | cut -f1)"
done
# ... and on the system volume too: dyld looks for a library outside the shared cache at its install name (e.g.
# /usr/lib/libLaunchServicesSupport.dylib, which loginwindow and the Dock link) and adds the OS cryptex's prefix only
# when the cryptex is grafted. The cryptex's files are merged into the system volume (nothing of the system's own is
# replaced), as the libraries sat before macOS moved them into the cryptex. This unseals the system volume; the hosted
# kernel mounts an unsealed root when SIP allows it (lp-sip0 0x800).
if [ "${MERGE_OS_CRYPTEX:-1}" = 1 ]; then
  diskutil unmount "$W/sys" >/dev/null
  mkdir -p "$W/sysrw" "$W/cx"
  if sudo -n mount -t apfs -o rw,nobrowse "/dev/$SYS" "$W/sysrw"; then
    hdiutil attach -readonly -nobrowse -mountpoint "$W/cx" "$CX/os.dmg" >/dev/null
    for d in usr/lib usr/libexec usr/bin usr/sbin usr/share System/iOSSupport; do
      [ -d "$W/cx/$d" ] && sudo -n mkdir -p "$W/sysrw/$d" && sudo -n cp -Rpn "$W/cx/$d/." "$W/sysrw/$d/" 2>/dev/null || true	# cp -n exits 1 when it skips files
    done
    for e in "$W"/cx/System/Library/*; do
      n=$(basename "$e"); [ "$n" = dyld ] && continue
      if [ -d "$e" ]; then
        sudo -n mkdir -p "$W/sysrw/System/Library/$n"; sudo -n cp -Rpn "$e/." "$W/sysrw/System/Library/$n/" 2>/dev/null || true
      else
        sudo -n cp -pn "$e" "$W/sysrw/System/Library/" 2>/dev/null || true
      fi
    done
    hdiutil detach "$W/cx" >/dev/null
    echo "OS cryptex merged into the system volume: $(ls "$W/sysrw/usr/lib/libLaunchServicesSupport.dylib" 2>&1)"
    sync; sudo -n umount "$W/sysrw"
  else
    echo "cannot mount the system volume read-write"
  fi
  diskutil mount readOnly -mountPoint "$W/sys" "$SYS" >/dev/null
fi
sudo -n python3 scripts/extract-trustcache.py "$W/trustcache.bin" "$W/preboot"
grep -h -A1 ProductVersion "$W/sys/System/Library/CoreServices/SystemVersion.plist" | tr -d '\t\n'; echo
cleanup; trap - EXIT
t0=$(date +%s)
$V "rm -f /var/tmp/apfs.img /var/tmp/apfs.cow"
tar -C "$W" -cSf - mac.img | $V "rm -f /var/tmp/mac.img; tar -C /var/tmp -xSf -; ls -ls /var/tmp/mac.img; df -h /var/tmp | tail -1"
$V -put "$W/trustcache.bin" /var/tmp/trustcache-mac.bin; $V "sudo mv /var/tmp/trustcache-mac.bin /lib/firmware/xnu/trustcache-mac.bin; ls -la /lib/firmware/xnu/trustcache-mac.bin"
echo "sent in $(( $(date +%s) - t0 ))s"
