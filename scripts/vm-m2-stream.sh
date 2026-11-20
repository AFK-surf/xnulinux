#!/bin/bash
# On the Mac host: stream the VM's kernel log over ssh while XNU runs, so the last lines survive a VM hang.
# Usage: KMAX=100000 IDLE_MAX=300 bash scripts/vm-m2-stream.sh OUT
OUT=${1:-../stream.out}
bash scripts/vm.sh 'sudo dmesg -C' >/dev/null 2>&1
bash scripts/vm.sh 'sudo dmesg -w' > "$OUT" 2>&1 &
SP=$!
sleep 2
timeout ${TMO:-150} bash scripts/vm.sh "IDLE_MAX=${IDLE_MAX:-300} SHOW=${SHOW:-1} bash ~/w/poc/scripts/vm-m2-kbisect.sh ${KMAX:-100000}" 2>&1 | tee "$OUT.run"
echo "run rc=$?"
sleep 3; kill $SP 2>/dev/null
