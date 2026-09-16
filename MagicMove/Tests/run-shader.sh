#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
if ! metal=$(xcrun --find metal 2>/dev/null); then
  echo "ShaderTests: skipped (Metal compiler unavailable)"
  exit 0
fi
tmp=$(mktemp -d -t magicmove-shader-tests)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/include"

air="$tmp/MagicMove.air"
library="$tmp/MagicMove.metallib"
binary="$tmp/ShaderTests"
"$metal" -c -I "$root/MagicMove/MagicMove/Plugin/Render" -I "$root/RenderSupport/Sources/RenderSupport/include" \
  "$root/MagicMove/MagicMove/Plugin/Render/MagicMove.metal" -o "$air"
xcrun metallib "$air" -o "$library"
# The on-screen control shaders have no render test, so compile them here to
# catch a broken glyph or gizmo before the plugin build does.
"$metal" -c -I "$root/MagicMove/MagicMove/Plugin/Render" \
  "$root/MagicMove/MagicMove/Plugin/Render/OSC.metal" -o "$tmp/OSC.air"
xcrun clang -fobjc-arc -fmodules -I "$root/MagicMove/MagicMove/Plugin/Render" \
  -I "$root/RenderSupport/Sources/RenderSupport/include" -framework Foundation -framework Metal \
  "$root/MagicMove/Tests/ShaderTests.m" -o "$binary"
"$binary" "$library"
