#!/bin/bash
# On the macOS host (tokyo): build the full (non-GUI) userland system disk in the xnupoc VM, /var/tmp/full.img.
# The macOS system files and Xcode are streamed from this host straight into the VM's mounted HFS+ image; they stay
# on this host and that VM only (never in the repo). No host user data: no /Users, no /private/var (a pristine
# /private/var comes from Apple's data-volume template), no keychains, no host SSH keys, no host preferences.
set -euo pipefail
cd "$(dirname "$0")/.."
SIZE=${SIZE:-80G}
XCODE=${XCODE:-/Applications/Xcode_27.app}
V="bash scripts/vm.sh"

$V "set -e; sudo umount /mnt/full 2>/dev/null || true; rm -f /var/tmp/full.img; truncate -s $SIZE /var/tmp/full.img
    mkfs.hfsplus -v xnulinux-full /var/tmp/full.img >/dev/null; sudo mkdir -p /mnt/full
    sudo mount -o loop,rw -t hfsplus /var/tmp/full.img /mnt/full; df -h /mnt/full | tail -1"

# bsdtar --exclude patterns are not anchored ("Library/Preferences" also drops System/Library/Preferences), so the
# top-level choices are made by listing what goes in; the exclusions left are unique paths.
EXCL=(
  --exclude 'System/Library/AssetsV2' --exclude 'System/Library/Desktop Pictures' --exclude 'System/Library/Caches/com.apple.*'
  --exclude 'Library/Application Support/com.apple.TCC'
  --exclude 'private/etc/ssh/ssh_host_*' --exclude 'private/etc/master.passwd' --exclude 'private/etc/kcpassword'
  --exclude 'xcuserdata' --exclude '.Spotlight-V100' --exclude '.fseventsd'
)
pick() {	# the entries of directory $1 except the names given after it
  local d=$1; shift
  for e in "/$d"/*; do
    n=${e##*/}; skip=0
    for x in "$@"; do [ "$n" = "$x" ] && skip=1; done
    [ $skip = 1 ] || echo "$d/$n"
  done
}
SRC=(System/Library bin sbin private/etc System/Volumes/Preboot/Cryptexes/OS "${XCODE#/}")
while IFS= read -r l; do SRC+=("$l"); done < <(
  pick usr local
  pick Library Caches Logs Keychains Preferences 'Managed Preferences' LaunchDaemons LaunchAgents PrivilegedHelperTools Developer Bluetooth Tailscale
  pick Library/Developer CoreSimulator DeveloperDiskImages CommandLineTools)
t0=$(date +%s)
cd /
sudo -n tar -c -f - --no-mac-metadata --no-xattrs --no-acls "${EXCL[@]}" \
  -s ",^${XCODE#/},Applications/Xcode.app," "${SRC[@]}" 2> /tmp/mk-fulldisk-tar.err \
  | bash ~-/scripts/vm.sh "sudo tar -x -p -f - -C /mnt/full --warning=no-unknown-keyword 2>&1 | tail -5" \
  || echo "host tar ended nonzero (SIP-protected entries such as Library/Bluetooth cannot be read; they are not needed)"
cd ~-
echo "streamed in $(( $(date +%s) - t0 ))s; host tar warnings: $(wc -l < /tmp/mk-fulldisk-tar.err)"; tail -5 /tmp/mk-fulldisk-tar.err
$V "df -h /mnt/full | tail -1; ls /mnt/full /mnt/full/Applications; sudo umount /mnt/full"
