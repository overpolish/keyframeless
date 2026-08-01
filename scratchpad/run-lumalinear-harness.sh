#!/bin/sh

# Builds and runs scratchpad/lumalinearharness.m: the numeric proof for
# `pick=luma-linear` plus a read of the two templates on disk.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
MIRAGE="$HERE/../Mirage/Mirage/Plugin"
OUTPUT="${TMPDIR:-/tmp}/mirage-lumalinear-harness"

xcrun clang -fobjc-arc -g -O0 -framework Foundation \
  -I"$MIRAGE/Render" -I"$MIRAGE/Render/Surface" \
  "$HERE/lumalinearharness.m" -o "$OUTPUT"
"$OUTPUT"
