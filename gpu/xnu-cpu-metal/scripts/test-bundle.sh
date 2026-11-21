#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --show-sdk-path)"
ARCH="${1:-arm64}"

/usr/bin/clang++ -arch "$ARCH" -O2 -fobjc-arc -isysroot "$SDK" \
  "$ROOT/test/test_bundle.mm" \
  -framework Foundation -framework Metal \
  -o "$ROOT/build/test_bundle_${ARCH}"

file "$ROOT/build/test_bundle_${ARCH}"
"$ROOT/build/test_bundle_${ARCH}" "$ROOT/dist/XnuCpuMetal.bundle" "$ROOT/build/vecadd.metallib"
