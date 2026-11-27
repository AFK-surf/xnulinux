#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# On Linux: build.sh server (beside the real libxnu_m2v.so: B, the bridge's crate) | client (the library and its test) | relay
set -e
cd "$(dirname "$0")"
python3 gen.py >/dev/null
B=${B:-../xnu-cpu-metal/src/xnu-m2v-bridge}
W="-O2 -g -Wall -Wno-discarded-qualifiers -Wno-unused-function -I. -I../xnu-cpu-metal/src/xnu-m2v-bridge/include -I../xnu-drm"
case "$1" in
server)
  gcc $W server.c -L$B/target/release -lxnu_m2v -lpthread -Wl,-rpath,"$(cd $B/target/release && pwd)" -o xm2v-server
  gcc $W t2.c -L$B/target/release -lxnu_m2v -Wl,-rpath,"$(cd $B/target/release && pwd)" -o t2-local ;;
client)
  gcc $W -fPIC -shared client.c -lpthread -o libxnu_m2v_remote.so
  gcc $W t2.c -L. -lxnu_m2v_remote -Wl,-rpath,'$ORIGIN' -o t2-remote ;;
relay)
  gcc $W relay.c -o xm2v-relay ;;
*) echo "usage: $0 server|client|relay" >&2; exit 2 ;;
esac
