#!/bin/sh
# Compile current production sources; only Apple's FxPlug runtime is reused.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
derived="${MM_DERIVED_DATA:-$root/DerivedData/Keyframeless}"
build="$derived/Build"
core="$root/MagicMove/MagicMove/Plugin/Core"
render="$root/MagicMove/MagicMove/Plugin/Render"
inspector="$root/InspectorControls/Sources/InspectorControls"
support="$root/RenderSupport/Sources/RenderSupport"
preferences="$root/PluginPreferences/Sources/PluginPreferences"
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
for source in MotionTiming MTDurationRecords; do
  xcrun clang -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -I "$root/MotionTiming/Sources/MotionTiming/include" \
    -c "$root/MotionTiming/Sources/MotionTiming/$source.c" -o "$test_tmp/$source.o"
done
for suite in ${MM_TEST_SUITES:-DefaultsTests HostLifecycleTests HeaderTests LinkedPosesTests ModelTests MatchEndpointsTests CombinedPoseTests EasingTests AddedMotionTests MotionBlurTests ShortcutTests CustomRowTests PositionTests ScaleTests TimingEditorTests OpacityTests RotationTests BlurAnchorTests ResetParameterTests NativeLinksTests PropertyMatchTests}; do
  xcrun clang -fobjc-arc -fmodules -Wno-protocol -fsanitize=address,undefined \
    -I "$preferences/include" -fmodule-map-file="$test_tmp/PluginPreferences.modulemap" \
    -I "$support/include" -fmodule-map-file="$test_tmp/RenderSupport.modulemap" \
    -I "$inspector/include" -fmodule-map-file="$test_tmp/InspectorControls.modulemap" \
    -I "$core" -I "$render" -I "$root/MagicMove/Tests" \
    -fmodule-map-file="$test_tmp/MotionTiming.modulemap" \
    -F /Library/Developer/SDKs/FxPlug.sdk/Library/Frameworks \
    -F "$build/Products/Debug" \
    -framework MetalPerformanceShaders -framework ApplicationServices -framework IOSurface -framework CoreVideo -framework AppKit -framework Foundation -framework CoreGraphics -framework CoreMedia -framework Metal -framework FxPlug \
    -Wl,-rpath,"$build/Products/Debug" \
    "$root/MagicMove/Tests/$suite.m" "$root/MagicMove/Tests/MockHost.m" \
    "$core/MMDefaults.m" "$preferences/PPDefaultStore.m" "$inspector/ICContextMenu.m" "$inspector/ICDefaultMenu.m" "$core/MMParameterData.m" "$core/Plugin.m" "$core/Plugin+CustomRow.m" "$core/Plugin+Links.m" "$core/Plugin+Parameters.m" \
    "$core/MMInspectorHeader.m" "$inspector/ICInspectorHeader.m" "$inspector/ICPopUpButton.m" "$inspector/ICMenuToggleView.m" "$inspector/InspectorTokens.m" "$inspector/ICValueTextField.m" "$inspector/ICInspectorRow.m" "$inspector/ICSliderView.m" "$inspector/ICSliderRow.m" "$core/MMPoseTiming.m" "$core/MMTimingEditorModel.m" "$core/MMTimingEditor.m" "$core/MMScalePose.m" "$core/MMScalarPose.m" "$core/MMPropertyLane.m" "$core/MMRotationPose.m" "$core/MMAnchorPose.m" "$core/MMPropertyRow.m" "$core/MMResetParameter.m" "$core/MMMatchEndpoints.m" "$core/MMNativeLinks.m" "$core/MMShortcut.m" "$core/MMCombinedPose.m" "$core/MMDestinations.m" "$render/Plugin+Render.m" "$render/MMRenderHost.m" "$support/RenderSupport.m" "$support/RSMetalResources.m" \
    "$test_tmp/MotionTiming.o" "$test_tmp/MTDurationRecords.o" -o "$test_tmp/$suite"
  DYLD_FRAMEWORK_PATH="$runtime" "$test_tmp/$suite" "$@"
done
