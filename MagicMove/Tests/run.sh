#!/bin/sh
# Compile current production sources; only the shared FxPlug/Kit runtime is reused.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
build="$root/DerivedData/Keyframeless/Build"
core="$root/MagicMove/MagicMove/Plugin/Core"
render="$root/MagicMove/MagicMove/Plugin/Render"
runtime="$build/Products/Debug/MagicMove.app/Contents/PlugIns/MagicMove XPC Service.pluginkit/Contents/Frameworks"
if [ ! -d "$runtime/KeyframelessKit.framework" ]; then
  echo "Build the MagicMove workspace scheme in DerivedData/Keyframeless first (see MagicMove/Tests/README.md)." >&2
  exit 1
fi
test_tmp=$(mktemp -d -t magicmove-tests)
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM
printf 'module MotionTiming { umbrella header "%s/MotionTiming/Sources/MotionTiming/include/MotionTiming.h" export * }\n' "$root" > "$test_tmp/MotionTiming.modulemap"
for source in MotionTiming MTDurationRecords; do
  xcrun clang -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -I "$root/MotionTiming/Sources/MotionTiming/include" \
    -c "$root/MotionTiming/Sources/MotionTiming/$source.c" -o "$test_tmp/$source.o"
done
for suite in LinkedPosesTests ModelTests MatchEndpointsTests CombinedPoseTests EasingTests; do
  xcrun clang -fobjc-arc -fmodules -Wno-protocol -fsanitize=address,undefined \
    -I "$core" -I "$render" -I "$root/MagicMove/Tests" \
    -fmodule-map-file="$test_tmp/MotionTiming.modulemap" \
    -F /Library/Developer/SDKs/FxPlug.sdk/Library/Frameworks \
    -F "$build/Products/Debug" \
    -framework AppKit -framework Foundation -framework CoreGraphics -framework CoreMedia -framework Metal -framework FxPlug -framework KeyframelessKit \
    -Wl,-rpath,"$build/Products/Debug" \
    "$root/MagicMove/Tests/$suite.m" "$root/MagicMove/Tests/MockHost.m" \
    "$core/Plugin.m" "$core/Plugin+CustomRow.m" "$core/Plugin+Links.m" "$core/Plugin+Parameters.m" \
    "$core/MMCombinedPose.m" "$core/MMDestinations.m" "$render/Plugin+Render.m" \
    "$test_tmp/MotionTiming.o" "$test_tmp/MTDurationRecords.o" -o "$test_tmp/$suite"
  DYLD_FRAMEWORK_PATH="$runtime" "$test_tmp/$suite"
done
