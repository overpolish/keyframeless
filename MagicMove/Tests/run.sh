#!/bin/sh
# Compile current production sources; only Apple's FxPlug runtime is reused.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
derived="${MM_DERIVED_DATA:-$root/DerivedData/Keyframeless}"
build="$derived/Build"
core="$root/MagicMove/MagicMove/Plugin/Core"
render="$root/MagicMove/MagicMove/Plugin/Render"
osc="$root/MagicMove/MagicMove/Plugin/OSC"
inspector="$root/InspectorControls/Sources/InspectorControls"
support="$root/RenderSupport/Sources/RenderSupport"
preferences="$root/PluginPreferences/Sources/PluginPreferences"
viewer="$root/OSCViewer/Sources/OSCViewer"
host="$root/PluginHost/Sources/PluginHost"
lanes="$root/PoseLanes/Sources/PoseLanes"
runtime="$build/Products/Debug/MagicMove.app/Contents/PlugIns/MagicMove XPC Service.pluginkit/Contents/Frameworks"
if [ ! -d "$runtime/FxPlug.framework" ]; then
  echo "Build MagicMove first; MM_DERIVED_DATA must match the build directory (see MagicMove/Tests/README.md)." >&2
  exit 1
fi
test_tmp=$(mktemp -d -t magicmove-tests)
export MM_PREFERENCES_SUITE="co.overpolish.magicmove.tests.$(uuidgen)"
trap 'defaults delete "$MM_PREFERENCES_SUITE" >/dev/null 2>&1 || true; rm -rf "$test_tmp"' EXIT HUP INT TERM
printf 'module MotionTiming { umbrella header "%s/MotionTiming/Sources/MotionTiming/include/MotionTiming.h" export * }\n' "$root" > "$test_tmp/MotionTiming.modulemap"
printf 'module InspectorControls { umbrella header "%s/include/InspectorControls.h" export * }\n' "$inspector" > "$test_tmp/InspectorControls.modulemap"
printf 'module RenderSupport { umbrella header "%s/include/RenderSupport.h" export * }\n' "$support" > "$test_tmp/RenderSupport.modulemap"
printf 'module PluginPreferences { umbrella header "%s/include/PluginPreferences.h" export * }\n' "$preferences" > "$test_tmp/PluginPreferences.modulemap"
printf 'module OSCControls { umbrella header "%s/OSCControls/Sources/OSCControls/include/OSCControls.h" export * }\n' "$root" > "$test_tmp/OSCControls.modulemap"
printf 'module OSCViewer { umbrella header "%s/include/OSCViewer.h" export * }\n' "$viewer" > "$test_tmp/OSCViewer.modulemap"
printf 'module PluginHost { umbrella header "%s/include/PluginHost.h" export * }\n' "$host" > "$test_tmp/PluginHost.modulemap"
printf 'module PoseLanes { umbrella header "%s/include/PoseLanes.h" export * }\n' "$lanes" > "$test_tmp/PoseLanes.modulemap"
xcrun clang -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined \
  -I "$root/MotionTiming/Sources/MotionTiming/include" \
  -c "$root/MotionTiming/Sources/MotionTiming/MotionTiming.c" -o "$test_tmp/MotionTiming.o"
for source in OSCBoxGeometry OSCRotationGeometry; do
  xcrun clang -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -I "$root/OSCControls/Sources/OSCControls/include" \
    -c "$root/OSCControls/Sources/OSCControls/$source.c" -o "$test_tmp/$source.o"
done
xcrun clang -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined \
  -I "$viewer/include" -c "$viewer/OSCPlayheadMotion.c" -o "$test_tmp/OSCPlayheadMotion.o"
for suite in ${MM_TEST_SUITES:-PreferenceTests HostLifecycleTests HeaderTests ModelTests LaneIntegrationTests MotionBlurTests ShortcutTests OSCWriteTests}; do
  xcrun clang -fobjc-arc -fmodules -Wno-protocol -fsanitize=address,undefined \
    -I "$preferences/include" -fmodule-map-file="$test_tmp/PluginPreferences.modulemap" \
    -I "$support/include" -fmodule-map-file="$test_tmp/RenderSupport.modulemap" \
    -I "$inspector/include" -fmodule-map-file="$test_tmp/InspectorControls.modulemap" \
    -I "$core" -I "$render" -I "$osc" -I "$root/MagicMove/Tests" \
    -I "$host/include" -fmodule-map-file="$test_tmp/PluginHost.modulemap" \
    -I "$lanes/include" -fmodule-map-file="$test_tmp/PoseLanes.modulemap" \
    -I "$root/PluginHost/Tests" \
    -fmodule-map-file="$test_tmp/MotionTiming.modulemap" \
    -fmodule-map-file="$test_tmp/OSCControls.modulemap" \
    -I "$viewer/include" -fmodule-map-file="$test_tmp/OSCViewer.modulemap" \
    -F /Library/Developer/SDKs/FxPlug.sdk/Library/Frameworks \
    -F "$build/Products/Debug" \
    -framework MetalPerformanceShaders -framework ApplicationServices -framework IOSurface -framework CoreVideo -framework AppKit -framework Foundation -framework CoreGraphics -framework CoreMedia -framework Metal -framework FxPlug \
    -Wl,-rpath,"$build/Products/Debug" \
    "$root/MagicMove/Tests/$suite.m" "$root/PluginHost/Tests/MockHost.m" \
    "$host"/*.m "$lanes"/*.m \
    "$core/MMDefaults.m" "$preferences/PPDefaultStore.m" "$inspector/ICContextMenu.m" "$inspector/ICDefaultMenu.m" "$core/Plugin.m" "$core/Plugin+CustomRow.m" "$core/Plugin+Parameters.m" \
    "$core/MMInspectorHeader.m" "$inspector/ICInspectorHeader.m" "$inspector/ICPopUpButton.m" "$inspector/ICMenuToggleView.m" "$inspector/InspectorTokens.m" "$inspector/ICValueTextField.m" "$inspector/ICInspectorRow.m" "$inspector/ICSliderView.m" "$inspector/ICSliderRow.m" "$core/MMLanes.m" "$core/MMShortcut.m" "$render/Plugin+Render.m" "$osc/MagicMoveOSC.m" "$viewer/OSCCursor.m" "$viewer/OSCViewerControl.m" "$viewer/OSCViewerControl+Draw.m" "$viewer/OSCViewerControl+Input.m" "$viewer/OSCViewerControl+Rotation.m" "$viewer/OSCViewerControl+Anchor.m" "$support/RenderSupport.m" "$support/RSMetalResources.m" "$support/RSOSCDrawing.m" \
    "$test_tmp/MotionTiming.o" "$test_tmp/OSCPlayheadMotion.o" "$test_tmp/OSCBoxGeometry.o" "$test_tmp/OSCRotationGeometry.o" -o "$test_tmp/$suite"
  DYLD_FRAMEWORK_PATH="$runtime" "$test_tmp/$suite" "$@"
done
