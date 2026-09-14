#!/bin/sh

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$HERE/MirageStateBlobTests.m"
CORE="$HERE/../Mirage/Plugin/Core"
RENDER="$HERE/../Mirage/Plugin/Render"
KIT="$HERE/../../KeyframelessKit/KeyframelessKit"
KIT_TIMING="$KIT/Math/Timing"
KIT_GEOMETRY="$KIT/Math/Geometry"
KIT_METAL="$KIT/Metal"
OUTPUT="${TMPDIR:-/tmp}/mirage-state-blob-tests"

# Same shim trick as run-rack-model-tests.sh: MirageStateBlob.h imports the kit
# as `#import <KeyframelessKit/...>`, which only resolves inside Xcode's own
# header maps. One symlink per header reachable from its dependency graph fakes
# that nesting for a plain clang invocation, so the codec links against the REAL
# KKTimeline/KKLane and the REAL KKMotionBlurState layout - the byte layout this
# harness asserts is only meaningful against those.
SHIM="${TMPDIR:-/tmp}/mirage-state-blob-tests-shim"
rm -rf "$SHIM"
mkdir -p "$SHIM/KeyframelessKit"
for dir in "$KIT" "$KIT_TIMING" "$KIT_GEOMETRY" "$KIT_METAL"; do
  for h in "$dir"/*.h; do
    ln -s "$h" "$SHIM/KeyframelessKit/$(basename "$h")"
  done
done

# No-op stand-in for the CocoaLumberjack-backed logger, so KKTimeline.m links
# without its backend (see run-rack-model-tests.sh).
STUB="${TMPDIR:-/tmp}/mirage-state-blob-tests-stub"
rm -rf "$STUB"
mkdir -p "$STUB"
cat >"$STUB/KKLog.h" <<'EOF'
#pragma once
#define KKLogVerbose(...) ((void)0)
#define KKLogDebug(...) ((void)0)
#define KKLogInfo(...) ((void)0)
#define KKLogWarn(...) ((void)0)
#define KKLogError(...) ((void)0)
#define KKLogFlush() ((void)0)
EOF

xcrun clang -fobjc-arc -framework Foundation \
  -I"$SHIM" -I"$STUB" \
  -I"$KIT" -I"$KIT_TIMING" -I"$KIT_GEOMETRY" -I"$KIT_METAL" \
  -I"$CORE" -I"$RENDER" \
  "$SOURCE" \
  "$RENDER/MirageStateBlob.m" \
  "$KIT_TIMING/KKTimeline.m" \
  "$KIT_GEOMETRY/KKBezierPath.m" \
  "$KIT_TIMING/KKCurveDefaults.m" \
  "$KIT_TIMING/KKEasing.m" \
  "$KIT_GEOMETRY/KKPathMorph.m" \
  "$KIT_GEOMETRY/KKShape.m" \
  "$KIT_TIMING/KKScopedDefaults.m" \
  "$KIT/KKLocalized.m" \
  "$KIT_TIMING/KKSlotInstances.m" \
  -o "$OUTPUT"
"$OUTPUT"
