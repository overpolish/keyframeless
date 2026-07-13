#!/usr/bin/env bash
# Compile and run the GLSL formatter regression set. Builds the SHIPPING
# KKGLSLFormatter.mm against a KKLog stub and links libkktranspiler.a (for
# astyle's AStyleMain), so the tests exercise the real formatter.
#
# Usage: ./run-format-tests.sh [arm64|x86_64]   (default: arm64)
# Requires: ./build-transpiler.sh has been run (produces libkktranspiler.a).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ARCH="${1:-arm64}"
LIB="$HERE/build/lib/libkktranspiler.a"
FMT_DIR="$HERE/../Shader/Shader/Plugin/Render"

if [ ! -f "$LIB" ]; then
  echo "error: $LIB not found - run ./build-transpiler.sh first" >&2
  exit 1
fi

BIN="$(mktemp -d)/kk-format-tests"
clang++ -std=gnu++20 -fobjc-arc -arch "$ARCH" \
  -I "$HERE/format-tests/stub" \
  -I "$FMT_DIR" \
  "$HERE/format-tests/KKGLSLFormatterTests.mm" \
  "$FMT_DIR/KKGLSLFormatter.mm" \
  "$LIB" \
  -framework Foundation \
  -o "$BIN"
"$BIN"
