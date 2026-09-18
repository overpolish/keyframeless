#!/bin/sh
# Compiles the package sources directly against the FxPlug SDK headers. The
# framework itself is only needed at runtime, where Apple installs it.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
sources="$root/PoseLanes/Sources/PoseLanes"
host="$root/PluginHost/Sources/PluginHost"
inspector="$root/InspectorControls/Sources/InspectorControls"
support="$root/RenderSupport/Sources/RenderSupport"
preferences="$root/PluginPreferences/Sources/PluginPreferences"
viewer="$root/OSCViewer/Sources/OSCViewer"
sdk=/Library/Developer/SDKs/FxPlug.sdk/Library/Frameworks
runtime=/Library/Developer/Frameworks
if [ ! -d "$sdk/FxPlug.framework" ]; then
  echo "Install the FxPlug SDK at $sdk to run the PoseLanes tests." >&2
  exit 1
fi
test_tmp=$(mktemp -d -t poselanes-tests)
export KF_PREFERENCES_SUITE="co.overpolish.poselanes.tests.$(uuidgen)"
trap 'defaults delete "$KF_PREFERENCES_SUITE" >/dev/null 2>&1 || true; rm -rf "$test_tmp"' EXIT HUP INT TERM
printf 'module MotionTiming { umbrella header "%s/MotionTiming/Sources/MotionTiming/include/MotionTiming.h" export * }\n' "$root" > "$test_tmp/MotionTiming.modulemap"
printf 'module InspectorControls { umbrella header "%s/include/InspectorControls.h" export * }\n' "$inspector" > "$test_tmp/InspectorControls.modulemap"
printf 'module RenderSupport { umbrella header "%s/include/RenderSupport.h" export * }\n' "$support" > "$test_tmp/RenderSupport.modulemap"
printf 'module PluginPreferences { umbrella header "%s/include/PluginPreferences.h" export * }\n' "$preferences" > "$test_tmp/PluginPreferences.modulemap"
printf 'module OSCViewer { umbrella header "%s/include/OSCViewer.h" export * }\n' "$viewer" > "$test_tmp/OSCViewer.modulemap"
printf 'module OSCControls { umbrella header "%s/OSCControls/Sources/OSCControls/include/OSCControls.h" export * }\n' "$root" > "$test_tmp/OSCControls.modulemap"
printf 'module PluginHost { umbrella header "%s/include/PluginHost.h" export * }\n' "$host" > "$test_tmp/PluginHost.modulemap"
printf 'module PoseLanes { umbrella header "%s/include/PoseLanes.h" export * }\n' "$sources" > "$test_tmp/PoseLanes.modulemap"
xcrun clang -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined \
  -I "$root/MotionTiming/Sources/MotionTiming/include" \
  -c "$root/MotionTiming/Sources/MotionTiming/MotionTiming.c" -o "$test_tmp/MotionTiming.o"
xcrun clang -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined \
  -I "$viewer/include" -c "$viewer/OSCPlayheadMotion.c" -o "$test_tmp/OSCPlayheadMotion.o"
for suite in ${KF_TEST_SUITES:-PoseTests LaneTests DefaultsTests NativeLinksTests PropertyMatchTests ResetParameterTests RowTests TimingEditorTests KeyposeMapTests}; do
  xcrun clang -fobjc-arc -fmodules -Wall -Wno-protocol -fsanitize=address,undefined \
    -I "$sources/include" -fmodule-map-file="$test_tmp/PoseLanes.modulemap" \
    -I "$host/include" -fmodule-map-file="$test_tmp/PluginHost.modulemap" \
    -I "$inspector/include" -fmodule-map-file="$test_tmp/InspectorControls.modulemap" \
    -I "$support/include" -fmodule-map-file="$test_tmp/RenderSupport.modulemap" \
    -I "$preferences/include" -fmodule-map-file="$test_tmp/PluginPreferences.modulemap" \
    -I "$viewer/include" -fmodule-map-file="$test_tmp/OSCViewer.modulemap" \
    -fmodule-map-file="$test_tmp/MotionTiming.modulemap" \
    -fmodule-map-file="$test_tmp/OSCControls.modulemap" \
    -I "$sources" -I "$root/PoseLanes/Tests" -I "$root/PluginHost/Tests" \
    -F "$sdk" \
    -framework AppKit -framework Foundation -framework ApplicationServices \
    -framework CoreGraphics -framework CoreMedia -framework Metal \
    -framework MetalPerformanceShaders -framework IOSurface -framework CoreVideo -framework FxPlug \
    "$root/PoseLanes/Tests/$suite.m" "$root/PoseLanes/Tests/TestLanes.m" \
    "$root/PluginHost/Tests/MockHost.m" \
    "$sources"/*.m "$host"/*.m \
    "$inspector"/*.m "$preferences"/*.m \
    "$support/RenderSupport.m" "$support/RSMetalResources.m" "$support/RSOSCDrawing.m" \
    "$test_tmp/MotionTiming.o" "$test_tmp/OSCPlayheadMotion.o" \
    -o "$test_tmp/$suite"
  DYLD_FRAMEWORK_PATH="$runtime" "$test_tmp/$suite" "$@"
done
