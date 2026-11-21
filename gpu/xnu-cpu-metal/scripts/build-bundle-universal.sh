#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --show-sdk-path)"
BUNDLE="$ROOT/dist/XnuCpuMetal.bundle"
TMP="$ROOT/build/bundle-universal"

rm -rf "$BUNDLE" "$TMP"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Frameworks" "$BUNDLE/Contents/Resources" "$TMP"

cp -f "$ROOT/src/xnu-cpu-metal-bundle/Info.plist" "$BUNDLE/Contents/Info.plist"

# 1. Create universal (arm64 + arm64e) Frameworks dylibs
lipo -create \
  "$ROOT/dist/m2v/lib/libxnu_m2v.dylib" \
  "$ROOT/dist/m2v-arm64e/lib/libxnu_m2v.dylib" \
  -output "$BUNDLE/Contents/Frameworks/libxnu_m2v.dylib"

lipo -create \
  "$ROOT/dist/lavapipe/lib/libvulkan.1.dylib" \
  "$ROOT/build/vkloader-arm64e-install/lib/libvulkan.1.dylib" \
  -output "$BUNDLE/Contents/Frameworks/libvulkan.1.dylib"

lipo -create \
  "$ROOT/dist/lavapipe/lib/libvulkan_lvp.dylib" \
  "$ROOT/dist/lavapipe-arm64e/lib/libvulkan_lvp.dylib" \
  -output "$BUNDLE/Contents/Frameworks/libvulkan_lvp.dylib"

# 2. Relocatable ICD JSON
cat > "$BUNDLE/Contents/Resources/lvp_icd.aarch64.json" <<'EOF'
{
    "ICD": {
        "api_version": "1.4.363",
        "library_arch": "64",
        "library_path": "../Frameworks/libvulkan_lvp.dylib"
    },
    "file_format_version": "1.0.1"
}
EOF

# 3. Compile XnuCpuMetal MH_BUNDLE for both arm64 and arm64e, then lipo
for ARCH in arm64 arm64e; do
  /usr/bin/clang++ -arch "$ARCH" -bundle -O2 -std=c++20 -fobjc-arc \
    -isysroot "$SDK" \
    -F"$SDK/System/Library/PrivateFrameworks" \
    -I"$ROOT/dist/m2v/include" \
    -I"$ROOT/src/xnu-cpu-metal-bundle" \
    "$ROOT/src/xnu-cpu-metal-bundle/XnuCpuMetalPlugin.mm" \
    -L"$BUNDLE/Contents/Frameworks" -lxnu_m2v \
    -Wl,-rpath,@loader_path/../Frameworks \
    -framework Foundation \
    -framework Metal \
    -framework IOKit \
    -framework IOSurface \
    -framework IOGPU \
    -o "$TMP/XnuCpuMetal.${ARCH}"
done

lipo -create "$TMP/XnuCpuMetal.arm64" "$TMP/XnuCpuMetal.arm64e" \
  -output "$BUNDLE/Contents/MacOS/XnuCpuMetal"

# 4. Ad-hoc sign all universal binaries
codesign -s - --force "$BUNDLE/Contents/Frameworks/libxnu_m2v.dylib"
codesign -s - --force "$BUNDLE/Contents/Frameworks/libvulkan.1.dylib"
codesign -s - --force "$BUNDLE/Contents/Frameworks/libvulkan_lvp.dylib"
codesign -s - --force "$BUNDLE/Contents/MacOS/XnuCpuMetal"

echo "=== Built universal (arm64 + arm64e) $BUNDLE ==="
for f in \
  "$BUNDLE/Contents/MacOS/XnuCpuMetal" \
  "$BUNDLE/Contents/Frameworks/libxnu_m2v.dylib" \
  "$BUNDLE/Contents/Frameworks/libvulkan.1.dylib" \
  "$BUNDLE/Contents/Frameworks/libvulkan_lvp.dylib"; do
  lipo -info "$f"
done
ls -lh "$BUNDLE/Contents/MacOS/" "$BUNDLE/Contents/Frameworks/"
