#!/bin/sh

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$HERE/MirageDirectiveCommonTests.m"
RENDER_HEADERS="$HERE/../Mirage/Plugin/Render"
SURFACE_HEADERS="$RENDER_HEADERS/Surface"
OSC_HEADERS="$HERE/../Mirage/Plugin/OSC"
OUTPUT="${TMPDIR:-/tmp}/mirage-directive-common-tests"

xcrun clang -fobjc-arc -framework Foundation \
  -I"$RENDER_HEADERS" -I"$SURFACE_HEADERS" -I"$OSC_HEADERS" "$SOURCE" \
  -o "$OUTPUT"
"$OUTPUT"
