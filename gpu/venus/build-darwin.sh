#!/bin/bash
# On a Mac: build Mesa's Venus Vulkan driver for the hosted macOS, its renderer talking to the Linux host's GPU over the
# DRM bridge (gpu/xnu-drm: libxnudrm in the driver, kexts/XnuDrm in the hosted kernel, xnudrmd on Linux). Patches as for
# the Linux guest (patches/), plus libxnudrm copied into the tree. Also builds test/compute.c against it.
# Output: $OUT/lib/libvulkan_virtio.dylib, $OUT/share/vulkan/icd.d/virtio_icd.*.json, $OUT/bin/venus-compute.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MESA=26.3.1
ARCH=${ARCH:-arm64}	# arm64e for system processes (Metal plugin); arm64 for a test program
W=${W:-$HOME/w/venus-darwin}; OUT=${OUT:-$W/out-$ARCH}; mkdir -p "$W"; cd "$W"
export PATH=$W/venv/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
# Mesa wants Python >= 3.10 (macOS ships 3.9): uv's own when there is uv, else Homebrew's
if ! { [ -x venv/bin/meson ] && venv/bin/python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))'; }; then
  rm -rf venv
  if command -v uv >/dev/null; then uv venv -q -p 3.13 venv && VIRTUAL_ENV=$W/venv uv pip install -q meson ninja mako pyyaml packaging
  else /opt/homebrew/bin/python3 -m venv venv && venv/bin/pip -q install meson ninja mako pyyaml packaging; fi
fi
[ -f mesa-$MESA.tar.xz ] || curl -sSLo mesa-$MESA.tar.xz https://archive.mesa3d.org/mesa-$MESA.tar.xz
rm -rf mesa && mkdir mesa && tar -C mesa --strip-components=1 -xf mesa-$MESA.tar.xz
for p in "$HERE"/patches/*.patch; do patch -d mesa -p1 --no-backup-if-mismatch -s < "$p"; done
mkdir -p mesa/src/virtio/vulkan/xnudrm
cp "$HERE"/../xnu-drm/darwin/* "$HERE"/../xnu-drm/xnudrm_proto.h mesa/src/virtio/vulkan/xnudrm/
cat > cross-$ARCH.txt <<X
[binaries]
c = ['/usr/bin/clang', '-arch', '$ARCH']
cpp = ['/usr/bin/clang++', '-arch', '$ARCH']
objc = ['/usr/bin/clang', '-arch', '$ARCH']
ar = '/usr/bin/ar'
strip = '/usr/bin/strip'
[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = '$ARCH'
endian = 'little'
X
meson setup mesa/build-$ARCH mesa --cross-file cross-$ARCH.txt --prefix="$OUT" --buildtype=release \
  -Dvulkan-drivers=virtio -Dgallium-drivers= -Dplatforms= -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dllvm=disabled \
  -Dopengl=false -Dgles1=disabled -Dgles2=disabled -Dvideo-codecs= -Dzstd=disabled -Dxmlconfig=disabled \
  -Dbuild-tests=false >/dev/null || { tail -40 mesa/build-$ARCH/meson-logs/meson-log.txt; exit 1; }
ninja -C mesa/build-$ARCH install > ninja-$ARCH.log 2>&1 || { grep -E "error|FAILED|Undefined" ninja-$ARCH.log | head -30; exit 1; }
ls -la "$OUT"/lib/libvulkan_virtio.dylib
mkdir -p "$OUT"/bin
# the test talks to the driver directly (no loader in the hosted system): vk_icdGetInstanceProcAddr
/usr/bin/clang -arch $ARCH -O2 -I mesa/include "$HERE"/test/compute.c -o "$OUT"/bin/venus-compute
