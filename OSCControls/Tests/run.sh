#!/bin/sh
# Standalone pure-C geometry tests; no plugin build required.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
sources="$root/Sources/OSCControls/OSCBoxGeometry.c $root/Sources/OSCControls/OSCRotationGeometry.c"
binary=$(mktemp -t osc-controls-tests)
trap 'rm -f "$binary"' EXIT
for suite in OSCBoxGeometryTests OSCRotationGeometryTests; do
  # shellcheck disable=SC2086 # the source list is intentionally word split
  xcrun clang -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined \
      -I "$root/Sources/OSCControls/include" \
      $sources "$root/Tests/$suite.c" \
      -framework CoreGraphics \
      -o "$binary"
  "$binary"
done
