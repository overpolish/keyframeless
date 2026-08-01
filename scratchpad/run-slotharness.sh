#!/bin/sh

# Builds and runs scratchpad/slotharness.m against the KeyframelessKit framework
# Xcode has already produced (the GUI build products - the same ones FCP loads).

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# The workspace's own products first (what `xcodebuild -workspace` writes), then
# whatever a GUI build left behind.
FRAMEWORKS="$(dirname "$(find "$ROOT/DerivedData" \
  "$HOME/Library/Developer/Xcode/DerivedData" \
  -path '*/Build/Products/Debug/KeyframelessKit.framework' -maxdepth 5 \
  -print -quit 2>/dev/null)")"
MIRAGE="$ROOT/Mirage/Mirage/Plugin"
OUTPUT="${TMPDIR:-/tmp}/mirage-slot-harness"

xcrun clang -fobjc-arc -g -O0 \
  -framework Foundation -framework AppKit \
  -F"$FRAMEWORKS" -framework KeyframelessKit \
  -rpath "$FRAMEWORKS" \
  -I"$MIRAGE/Core" -I"$MIRAGE/Render" -I"$MIRAGE/Render/Surface" \
  -I"$MIRAGE/OSC" \
  "$HERE/slotharness.m" "$MIRAGE/Render/MirageShaderModel.m" \
  -o "$OUTPUT"
"$OUTPUT"
