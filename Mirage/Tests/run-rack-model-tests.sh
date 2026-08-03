#!/bin/sh

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$HERE/MirageRackModelTests.m"
CORE_HEADERS="$HERE/../Mirage/Plugin/Core"
KIT="$HERE/../../KeyframelessKit/KeyframelessKit"
KIT_TIMING="$KIT/Math/Timing"
KIT_GEOMETRY="$KIT/Math/Geometry"
OUTPUT="${TMPDIR:-/tmp}/mirage-rack-model-tests"

# MirageRack.h (like its neighbours) imports the kit as
# `#import <KeyframelessKit/...>`, which only resolves inside Xcode's own
# header maps. Fake that one level of nesting with a throwaway symlink shim
# so a plain clang invocation resolves it too, without needing a built
# KeyframelessKit.framework - one symlink per top-level/Math/Timing/Math/
# Geometry header actually reachable from MirageRack.h's dependency graph.
SHIM="${TMPDIR:-/tmp}/mirage-rack-model-tests-shim"
rm -rf "$SHIM"
mkdir -p "$SHIM/KeyframelessKit"
for dir in "$KIT" "$KIT_TIMING" "$KIT_GEOMETRY"; do
  for h in "$dir"/*.h; do
    ln -s "$h" "$SHIM/KeyframelessKit/$(basename "$h")"
  done
done

# The kit's own .m files use plain-quote `#import "KKLog.h"` internally, which
# resolves via -I rather than the shim above. Standing in front of the real
# KKLog.h with a no-op stub (same trick as
# ThirdParty/format-tests/stub/KeyframelessKit/KKLog.h) means the harness
# links KKTimeline.m's REAL logic without dragging in KKLog's CocoaLumberjack
# backend.
STUB="${TMPDIR:-/tmp}/mirage-rack-model-tests-stub"
rm -rf "$STUB"
mkdir -p "$STUB"
cat >"$STUB/KKLog.h" <<'EOF'
#pragma once
// No-op stand-in for the real KeyframelessKit/KKLog.h so this harness can
// link KKTimeline.m's real logic without the CocoaLumberjack-backed logger.
#define KKLogVerbose(...) ((void)0)
#define KKLogDebug(...) ((void)0)
#define KKLogInfo(...) ((void)0)
#define KKLogWarn(...) ((void)0)
#define KKLogError(...) ((void)0)
#define KKLogFlush() ((void)0)
EOF

# MirageRack.h's own dependency graph, pulled in as REAL sources (not
# fixtures) so the model behaves exactly as the shipping plugin will use it:
# KKTimeline.m (KKTimeline/KKLane) and everything IT needs to link -
# KKBezierPath/KKCurveDefaults/KKEasing/KKPathMorph/KKShape/KKScopedDefaults/
# KKLocalized - plus KKSlotInstances.m, the layer MirageRack.h is built on.
xcrun clang -fobjc-arc -framework Foundation \
  -I"$SHIM" -I"$STUB" \
  -I"$KIT" -I"$KIT_TIMING" -I"$KIT_GEOMETRY" \
  -I"$CORE_HEADERS" \
  "$SOURCE" \
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
