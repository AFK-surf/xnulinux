#!/bin/bash
# In the VM: MODE=launchd puts macOS's own launchd (from /var/tmp/launchd.tar, made on the macOS host; Apple binaries stay
# local) at /sbin/launchd of the system disk; MODE=test puts the test init back.
set -euo pipefail
IMG=${IMG:-/var/tmp/sys.img}
sudo mkdir -p /mnt/sys; sudo mount -o loop -t hfsplus $IMG /mnt/sys
if [ "${MODE:-launchd}" = launchd ]; then
  sudo tar xf /var/tmp/launchd.tar -C /mnt/sys --warning=no-unknown-keyword
  sudo mkdir -p /mnt/sys/private/var/db /mnt/sys/private/var/run /mnt/sys/private/var/log /mnt/sys/private/etc /mnt/sys/Library
  [ -e /mnt/sys/etc ] || sudo ln -s private/etc /mnt/sys/etc
  # ONLY_OURS=1: none of Apple's daemons (their binaries are not on this disk), only a job of ours that launchd runs
  if [ "${ONLY_OURS:-1}" = 1 ]; then
    sudo mkdir -p /mnt/sys/private/var/xnulinux-apple-daemons
    sudo sh -c 'mv /mnt/sys/System/Library/LaunchDaemons/*.plist /mnt/sys/private/var/xnulinux-apple-daemons/ 2>/dev/null || true'
  fi
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
		<string>echo "hello from a launchd job (pid $$, parent $PPID)"; uname -sr; for i in 1 2 3; do echo "tick $i"; sleep 1; done; echo "job done"</string>
	</array>
	<key>RunAtLoad</key><true/>
	<key>StandardOutPath</key><string>/dev/console</string>
	<key>StandardErrorPath</key><string>/dev/console</string>
</dict>
</plist>
PL
else
  sudo cp ~/w/poc/tools/init/init /mnt/sys/sbin/launchd
fi
ls -la /mnt/sys/sbin; sudo umount /mnt/sys
