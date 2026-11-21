#!/bin/bash
# In the VM: MODE=launchd puts macOS's own launchd (from /var/tmp/launchd.tar, made on the macOS host; Apple binaries stay
# local) at /sbin/launchd of the system disk; MODE=test puts the test init back.
set -euo pipefail
IMG=${IMG:-/var/tmp/sys.img}
sudo fsck.hfsplus -fy $IMG 2>&1 | tail -1
sudo mkdir -p /mnt/sys; sudo mount -o loop,rw,force -t hfsplus $IMG /mnt/sys
if [ "${MODE:-launchd}" = launchd ]; then
  # FULL=1: a full userland disk (scripts/mk-fulldisk.sh) already has launchd and every daemon; /private/var comes
  # from Apple's pristine data-volume template, the root symlinks are made here
  if [ "${FULL:-0}" = 1 ]; then
    ONLY_OURS=0
    T=/mnt/sys/System/Library/Templates/Data
    [ -d /mnt/sys/private/var/db ] || { [ -d $T/private/var ] && sudo cp -a $T/private/var /mnt/sys/private/; }
    [ -d $T/Library ] && sudo cp -an $T/Library/. /mnt/sys/Library/ 2>/dev/null || true
    for l in var:private/var tmp:private/tmp etc:private/etc; do [ -e /mnt/sys/${l%%:*} ] || sudo ln -s ${l#*:} /mnt/sys/${l%%:*}; done
    sudo mkdir -p /mnt/sys/private/tmp /mnt/sys/dev /mnt/sys/Users /mnt/sys/Volumes /mnt/sys/private/var/select
    sudo chmod 1777 /mnt/sys/private/tmp
    [ -e /mnt/sys/System/Library/dyld ] || sudo ln -s /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld /mnt/sys/System/Library/dyld
    [ -e /mnt/sys/private/var/select/sh ] || sudo ln -s /bin/bash /mnt/sys/private/var/select/sh
    [ -e /mnt/sys/private/var/select/developer_dir ] || sudo ln -s /Applications/Xcode.app/Contents/Developer /mnt/sys/private/var/select/developer_dir
    # no third-party software of the host (its own /Library/LaunchDaemons, /usr/local); GUI and hardware-only
    # daemons (no display, no watchdog hardware) are parked in /private/var/xnulinux-parked (DISABLE adds more)
    sudo rm -rf /mnt/sys/usr/local
    sudo find /mnt/sys/Library/LaunchDaemons /mnt/sys/Library/LaunchAgents -name '*.plist' ! -name 'com.apple.*' -delete 2>/dev/null || true
    sudo mkdir -p /mnt/sys/private/var/xnulinux-parked
    for d in com.apple.loginwindow com.apple.WindowServer com.apple.watchdogd com.apple.iomfb_bics_daemon com.apple.audiomxd com.apple.audio.coreaudiod com.apple.PerfPowerServices com.apple.PerfPowerServicesExtended ${DISABLE:-}; do
      [ -e /mnt/sys/System/Library/LaunchDaemons/$d.plist ] && sudo mv /mnt/sys/System/Library/LaunchDaemons/$d.plist /mnt/sys/private/var/xnulinux-parked/
    done
  else
    sudo tar xf /var/tmp/launchd.tar -C /mnt/sys --warning=no-unknown-keyword
  fi
  sudo mkdir -p /mnt/sys/private/var/db /mnt/sys/private/var/run /mnt/sys/private/var/log /mnt/sys/private/etc /mnt/sys/Library
  [ -e /mnt/sys/etc ] || sudo ln -s private/etc /mnt/sys/etc
  # ONLY_OURS=1: none of Apple's daemons (their binaries are not on this disk), only a job of ours that launchd runs
  if [ "${ONLY_OURS:-1}" = 1 ]; then
    sudo mkdir -p /mnt/sys/private/var/xnulinux-apple-daemons
    sudo sh -c 'mv /mnt/sys/System/Library/LaunchDaemons/*.plist /mnt/sys/private/var/xnulinux-apple-daemons/ 2>/dev/null || true'
    # KEEP: Apple daemons put back (their binaries come in /var/tmp/daemons.tar from the macOS host)
    for d in ${KEEP:-}; do
      sudo mv /mnt/sys/private/var/xnulinux-apple-daemons/$d.plist /mnt/sys/System/Library/LaunchDaemons/ 2>/dev/null || echo "no $d.plist"
    done
    [ -s /var/tmp/daemons.tar ] && sudo tar xf /var/tmp/daemons.tar -C /mnt/sys --warning=no-unknown-keyword
  fi
  sudo mkdir -p /mnt/sys/private/var/db/diagnostics /mnt/sys/private/var/db/uuidtext /mnt/sys/private/var/log /mnt/sys/private/var/run /mnt/sys/Library/Preferences
  # a minimal local directory node for opendirectoryd (it panics the system without /Local/Default): root, daemon, wheel
  D=/mnt/sys/private/var/db/dslocal/nodes/Default
  sudo mkdir -p $D/users $D/groups $D/config /mnt/sys/private/var/root
  u() { sudo tee $D/users/$1.plist >/dev/null <<UP
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>name</key><array><string>$1</string></array><key>uid</key><array><string>$2</string></array>
<key>gid</key><array><string>$3</string></array><key>home</key><array><string>$4</string></array>
<key>shell</key><array><string>/bin/sh</string></array><key>realname</key><array><string>$5</string></array>
<key>passwd</key><array><string>*</string></array><key>generateduid</key><array><string>FFFFEEEE-DDDD-CCCC-BBBB-AAAA0000000$2</string></array>
</dict></plist>
UP
  }
  u root 0 0 /var/root "System Administrator"; u daemon 1 1 /var/root "System Services"
  sudo tee $D/groups/wheel.plist >/dev/null <<'GP'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>name</key><array><string>wheel</string></array><key>gid</key><array><string>0</string></array>
<key>users</key><array><string>root</string></array><key>generateduid</key><array><string>ABCDEFAB-CDEF-ABCD-EFAB-CDEF00000000</string></array></dict></plist>
GP
  sudo chmod -R go-rwx /mnt/sys/private/var/db/dslocal
  # flat files for libinfo's file module
  printf 'root:*:0:0:System Administrator:/var/root:/bin/sh\ndaemon:*:1:1:System Services:/var/root:/usr/bin/false\nnobody:*:-2:-2:Unprivileged User:/var/empty:/usr/bin/false\n' | sudo tee /mnt/sys/private/etc/passwd >/dev/null
  printf 'wheel:*:0:root\ndaemon:*:1:root\nnobody:*:-2:\nstaff:*:20:root\n' | sudo tee /mnt/sys/private/etc/group >/dev/null
  sudo tee /mnt/sys/System/Library/LaunchDaemons/xnulinux.hello.plist >/dev/null <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>xnulinux.hello</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string>
		<string>-c</string>
		<string>echo "hello from a launchd job (pid $$, parent $PPID)"; uname -sr; for i in 1 2 3; do echo "tick $i"; done; ls /System/Library/LaunchDaemons; echo "job done"</string>
	</array>
	<key>RunAtLoad</key><true/>
	<key>StandardOutPath</key><string>/dev/console</string>
	<key>StandardErrorPath</key><string>/dev/console</string>
</dict>
</plist>
PL
  sudo tee /mnt/sys/System/Library/LaunchDaemons/xnulinux.shell.plist >/dev/null <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>xnulinux.shell</string>
	<key>ProgramArguments</key>
	<array><string>/bin/bash</string><string>-i</string></array>
	<key>EnvironmentVariables</key>
	<dict><key>PATH</key><string>/bin:/usr/bin:/sbin:/usr/sbin</string><key>PS1</key><string>xnulinux# </string><key>TERM</key><string>dumb</string></dict>
	<key>RunAtLoad</key><true/>
	<key>StandardInPath</key><string>/dev/console</string>
	<key>StandardOutPath</key><string>/dev/console</string>
	<key>StandardErrorPath</key><string>/dev/console</string>
</dict>
</plist>
PL
else
  sudo cp ~/w/poc/tools/init/init /mnt/sys/sbin/launchd
fi
ls -la /mnt/sys/sbin; sudo umount /mnt/sys
