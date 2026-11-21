#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build/vkloader-arm64e"
PREFIX="$ROOT/build/vkloader-arm64e-install"
VK_HDR_DIR="$ROOT/build/vk-deps/vulkan-headers/1.4.363.0"

export PATH="$ROOT/build/pyvenv/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

cmake -G Ninja -S "$ROOT/src/Vulkan-Loader" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=/usr/bin/clang \
  -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
  -DCMAKE_OSX_ARCHITECTURES=arm64e \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DVULKAN_HEADERS_INSTALL_DIR="$VK_HDR_DIR" \
  -DBUILD_TESTS=OFF

ninja -C "$BUILD_DIR" -j"$(sysctl -n hw.ncpu)"
ninja -C "$BUILD_DIR" install
install_name_tool -id "@rpath/libvulkan.1.dylib" "$PREFIX/lib/libvulkan.1.dylib"
codesign -s - --force "$PREFIX/lib/libvulkan.1.dylib" 2>/dev/null || true
file "$PREFIX/lib/libvulkan.1.dylib"
otool -L "$PREFIX/lib/libvulkan.1.dylib"
