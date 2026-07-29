#!/bin/sh

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$HERE/MirageDirectiveCommonTests.m"
RENDER_HEADERS="$HERE/../Mirage/Plugin/Render"
OUTPUT="${TMPDIR:-/tmp}/mirage-directive-common-tests"

xcrun clang -fobjc-arc -framework Foundation \
  -I"$RENDER_HEADERS" "$SOURCE" -o "$OUTPUT"
"$OUTPUT"
