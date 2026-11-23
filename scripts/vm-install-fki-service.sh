#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# In the VM (once): the hosted kernel's DRAM as RAM Linux never manages, and fki.ko loaded with it early in every boot.
# The VM has 24 GB; Linux's command line says mem=15G (RAM from 0x40000000 to 0x400000000), and the 8 GB above, below
# the firmware's holes near the top, are fki's carve-out (carve_base/carve_mb). A CMA area was not enough: one page Linux
# pins in it during the boot (a buffer-head page of the block device) splits it, and the 8 GB block does not fit.
set -euo pipefail
P=$(cd "$(dirname "$0")/.." && pwd)
CARVE_BASE=${CARVE_BASE:-0x400000000}; CARVE_MB=${CARVE_MB:-8156}
G=/etc/default/grub.d/99-xnulinux.cfg
# nokaslr: arm64's EFI stub randomises the Linux kernel's physical load address across all EFI memory before mem=15G
# takes effect, which otherwise places the kernel image inside the 0x400000000 carve-out on ~1/3 of boots.
echo 'GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX mem=15G nokaslr log_buf_len=128M"' | sudo tee $G >/dev/null
sudo update-grub >/dev/null 2>&1
sudo tee /etc/systemd/system/xnulinux-fki.service >/dev/null <<UNIT
[Unit]
Description=xnulinux: fki.ko with the hosted kernel's DRAM reserved
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/insmod $P/fki-ko/fki.ko carve_base=$CARVE_BASE carve_mb=$CARVE_MB

[Install]
WantedBy=sysinit.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable xnulinux-fki.service
sync
echo "after a reboot: Linux on 15 GB, fki.ko loaded with the $CARVE_MB MB carve-out at $CARVE_BASE (rebuild fki-ko before a reboot when it changes)"
