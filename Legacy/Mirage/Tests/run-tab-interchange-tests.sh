#!/bin/sh

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$HERE/MirageTabInterchangeTests.m"
KIT_SPLIT="$HERE/../../KeyframelessKit/KeyframelessKit/Views/Controls/CodeEditor/KKCodeTabInterchange.m"
KIT_HEADERS="$(dirname "$KIT_SPLIT")"
SCHEMA_HEADERS="$HERE/../Mirage/Plugin/Core"
OUTPUT="${TMPDIR:-/tmp}/mirage-tab-interchange-tests"

xcrun clang -fobjc-arc -framework Foundation \
  -I"$KIT_HEADERS" -I"$SCHEMA_HEADERS" \
  "$SOURCE" "$KIT_SPLIT" -o "$OUTPUT"
MIRAGE_TESTS_DIR="$HERE" "$OUTPUT"
