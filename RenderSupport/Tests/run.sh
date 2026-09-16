#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d -t render-support-tests)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
sources="$root/Sources/RenderSupport"
xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Wno-unused-parameter -fsanitize=address,undefined \
  -I "$sources/include" -framework Foundation -framework CoreMedia -framework Metal \
  -framework MetalPerformanceShaders "$sources/RenderSupport.m" "$sources/RSMetalResources.m" "$sources/RSOSCDrawing.m" \
  "$root/Tests/RenderSupportTests.m" -o "$tmp/tests"
if [ "${1:-}" = --cpu-only ]; then
  "$tmp/tests"
else
  bundle="$tmp/RenderSupportTests.bundle"
  mkdir -p "$bundle/Contents/Resources"
  cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.keyframeless.RenderSupportTests</string><key>CFBundlePackageType</key><string>BNDL</string></dict></plist>
PLIST
  xcrun metal -c "$root/Shaders/RenderSupport.metal" -o "$tmp/blur.air"
  xcrun metal -c "$root/Shaders/OSC.metal" -o "$tmp/osc.air"
  xcrun metallib "$tmp/blur.air" "$tmp/osc.air" -o "$bundle/Contents/Resources/default.metallib"
  "$tmp/tests" "$bundle"
fi
