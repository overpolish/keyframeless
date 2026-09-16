#!/bin/sh
# Standalone pure-C geometry tests; no plugin build required.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
binary=$(mktemp -t osc-controls-tests)
trap 'rm -f "$binary"' EXIT
xcrun clang -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -I "$root/Sources/OSCControls/include" \
    "$root/Sources/OSCControls/OSCBoxGeometry.c" "$root/Tests/OSCBoxGeometryTests.c" \
    -framework CoreGraphics \
    -o "$binary"
"$binary"
