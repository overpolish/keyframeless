#!/bin/sh
# Compiles the package sources directly against the FxPlug SDK headers. The
# framework itself is only needed at runtime, where Apple installs it.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
sources="$root/PluginHost/Sources/PluginHost"
inspector="$root/InspectorControls/Sources/InspectorControls"
viewer="$root/OSCViewer/Sources/OSCViewer"
support="$root/RenderSupport/Sources/RenderSupport"
sdk=/Library/Developer/SDKs/FxPlug.sdk/Library/Frameworks
runtime=/Library/Developer/Frameworks
if [ ! -d "$sdk/FxPlug.framework" ]; then
  echo "Install the FxPlug SDK at $sdk to run the PluginHost tests." >&2
  exit 1
fi
test_tmp=$(mktemp -d -t pluginhost-tests)
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM
printf 'module InspectorControls { umbrella header "%s/include/InspectorControls.h" export * }\n' "$inspector" > "$test_tmp/InspectorControls.modulemap"
printf 'module RenderSupport { umbrella header "%s/include/RenderSupport.h" export * }\n' "$support" > "$test_tmp/RenderSupport.modulemap"
printf 'module OSCViewer { umbrella header "%s/include/OSCViewer.h" export * }\n' "$viewer" > "$test_tmp/OSCViewer.modulemap"
printf 'module OSCControls { umbrella header "%s/OSCControls/Sources/OSCControls/include/OSCControls.h" export * }\n' "$root" > "$test_tmp/OSCControls.modulemap"
printf 'module PluginHost { umbrella header "%s/include/PluginHost.h" export * }\n' "$sources" > "$test_tmp/PluginHost.modulemap"
xcrun clang -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined \
  -I "$viewer/include" -c "$viewer/OSCPlayheadMotion.c" -o "$test_tmp/OSCPlayheadMotion.o"
for suite in ${KF_TEST_SUITES:-NudgeTests ClockTests SettingsTests ShortcutTests}; do
  xcrun clang -fobjc-arc -fmodules -Wall -Wno-protocol -fsanitize=address,undefined \
    -I "$sources/include" -fmodule-map-file="$test_tmp/PluginHost.modulemap" \
    -I "$inspector/include" -fmodule-map-file="$test_tmp/InspectorControls.modulemap" \
    -I "$support/include" -fmodule-map-file="$test_tmp/RenderSupport.modulemap" \
    -I "$viewer/include" -fmodule-map-file="$test_tmp/OSCViewer.modulemap" \
    -fmodule-map-file="$test_tmp/OSCControls.modulemap" \
    -I "$root/PluginHost/Tests" \
    -F "$sdk" \
    -framework AppKit -framework Foundation -framework ApplicationServices \
    -framework CoreGraphics -framework CoreMedia -framework Metal \
    -framework MetalPerformanceShaders -framework IOSurface -framework CoreVideo -framework FxPlug \
    "$root/PluginHost/Tests/$suite.m" "$root/PluginHost/Tests/MockHost.m" \
    "$sources"/*.m \
    "$inspector/ICContextMenu.m" "$inspector/ICDefaultMenu.m" "$inspector/InspectorTokens.m" \
    "$support/RenderSupport.m" "$support/RSMetalResources.m" "$support/RSOSCDrawing.m" \
    "$test_tmp/OSCPlayheadMotion.o" \
    -o "$test_tmp/$suite"
  DYLD_FRAMEWORK_PATH="$runtime" "$test_tmp/$suite" "$@"
done
