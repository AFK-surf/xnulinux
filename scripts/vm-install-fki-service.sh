#!/bin/bash
# In the VM (once): load fki.ko early in every boot, reserving the hosted kernel's DRAM while the CMA area is still clean
# (fki reserve_mb). xnulinux-boot.sh then finds fki loaded with the reservation and uses it.
set -euo pipefail
P=$(cd "$(dirname "$0")/.." && pwd)
RESERVE_MB=${RESERVE_MB:-8156}
sudo tee /etc/systemd/system/xnulinux-fki.service >/dev/null <<UNIT
[Unit]
Description=xnulinux: fki.ko with the hosted kernel's DRAM reserved
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/insmod $P/fki-ko/fki.ko reserve_mb=$RESERVE_MB

[Install]
WantedBy=sysinit.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable xnulinux-fki.service
echo "fki.ko loads at boot with reserve_mb=$RESERVE_MB (rebuild fki-ko before a reboot when it changes)"
