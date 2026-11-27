#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# On a Mac: into-bundle.sh XnuCpuMetal.bundle. Gives a built bundle the libxnu_m2v that is either (switch.c): the real
# library stays, as libxnu_m2v_local.dylib, and is what runs unless the host boots the system with GPU=remote.
set -euo pipefail
B=${1:?usage: into-bundle.sh XnuCpuMetal.bundle}; F="$B/Contents/Frameworks"
cd "$(dirname "$0")"
[ -e "$F/libxnu_m2v_local.dylib" ] || mv "$F/libxnu_m2v.dylib" "$F/libxnu_m2v_local.dylib"	# a second run keeps the real one
python3 gen.py >/dev/null
xcrun clang -O2 -arch arm64 -arch arm64e -mmacosx-version-min=14.0 -dynamiclib -DXR_SWITCH -I. \
  -I../xnu-cpu-metal/src/xnu-m2v-bridge/include -I../xnu-drm client.c switch.c -framework IOKit -framework CoreFoundation \
  -install_name @rpath/libxnu_m2v.dylib -Wno-incompatible-pointer-types-discards-qualifiers -o "$F/libxnu_m2v.dylib"
codesign -f -s - "$F/libxnu_m2v_local.dylib" "$F/libxnu_m2v.dylib"
codesign -f -s - "$B"
codesign -v "$B" && echo "$B: libxnu_m2v.dylib is the one that is either"
